-- Multiplayer battles.
--
-- Design:
--  * The party IS the online roster (see MP.applyParty) -- only real players
--    appear as battlers, in roster order (host/Kris first).
--  * Battle start is broadcast: when any player touches an enemy, everyone
--    enters the same encounter together.
--  * ACTION SELECT is turn-ordered by player: each battler can only be
--    commanded by the player who owns it. Everyone else sees a "waiting"
--    banner. Committed actions are broadcast and replayed on every client, so
--    the shared battle state machine advances in lockstep.
--  * The soul/bullet phase starts only after every player has acted (this is
--    Kristal's own behaviour once all actions are committed). Each player
--    controls their OWN soul in their own color; other players' souls are
--    rendered from 20Hz position updates. A bullet hitting YOUR soul hurts
--    YOUR character, and the damage is mirrored to everyone.
--  * Enemy attack choice is host-deterministic: the battle seed is broadcast
--    at battle start and every client seeds the RNG identically before wave
--    selection, so all players face the same attack.

if not WEB then return end

local KNet = require("src.web.knet")

local MPB = {
    active = false,      -- in a synced multiplayer battle
    seed = 0,
    turn = 0,
    remote_souls = {},   -- key -> Sprite
    applying = false,    -- true while replaying a remote message (no rebroadcast)
}
MP.battle = MPB

local function myIndex()
    if not (Game and Game.battle) then return nil end
    for i, key in ipairs(MP.order) do
        if key == MP.my_key then return i end
    end
    return nil
end

local function ownerKey(ci)
    return MP.order[ci]
end

local function ownedByMe(ci)
    return ownerKey(ci) == MP.my_key
end

-------------------------------------------------------------------------------
-- Serialization helpers
-------------------------------------------------------------------------------

local function serializeTarget(battle, target)
    if target == nil then return nil end
    if type(target) == "number" then return { k = "n", v = target } end
    if type(target) == "string" then return { k = "s", v = target } end
    if isClass(target) then
        if target.includes and target:includes(EnemyBattler) then
            for i, e in ipairs(battle.enemies) do
                if e == target then return { k = "e", v = i } end
            end
        end
        if target.includes and target:includes(PartyBattler) then
            for i, b in ipairs(battle.party) do
                if b == target then return { k = "p", v = i } end
            end
        end
    end
    return nil
end

local function deserializeTarget(battle, t)
    if not t then return nil end
    if t.k == "n" then return t.v end
    if t.k == "s" then return t.v end
    if t.k == "e" then return battle.enemies[t.v] end
    if t.k == "p" then return battle.party[t.v] end
    return nil
end

local function serializeData(data)
    if not data then return nil end
    local out = {}
    for k, v in pairs(data) do
        local tv = type(v)
        if tv == "number" or tv == "string" or tv == "boolean" then
            out[k] = v
        elseif tv == "table" and not isClass(v) then
            -- plain tables (e.g. lists of strings) pass through if JSON-safe
            local ok = pcall(JSON.encode, v)
            if ok then out[k] = v end
        elseif isClass(v) and v.id then
            -- Spells / items / other registry objects: send their id
            if v.includes and Spell and v:includes(Spell) then
                out["__spell"] = v.id
            elseif v.includes and Item and v:includes(Item) then
                out["__item"] = v.id
            end
        end
    end
    return out
end

local function deserializeData(battler, data)
    if not data then return nil end
    local out = {}
    for k, v in pairs(data) do out[k] = v end
    if out.__spell then
        local id = out.__spell
        out.__spell = nil
        for _, spell in ipairs(battler.chara:getSpells()) do
            if spell.id == id then out.spell = spell break end
        end
        if not out.spell and Registry and Registry.createSpell then
            local ok, sp = pcall(Registry.createSpell, id)
            if ok then out.spell = sp end
        end
    end
    if out.__item then
        local id = out.__item
        out.__item = nil
        if Game.inventory and Game.inventory.getItemByID then
            local ok, item = pcall(function() return Game.inventory:getItemByID(id) end)
            if ok and item then out.item = item end
        end
        if not out.item then
            for _, storage in ipairs({ "items", "key_items" }) do
                local stor = Game.inventory and Game.inventory:getStorage(storage)
                if stor then
                    for _, item in ipairs(stor) do
                        if item and item.id == id then out.item = item break end
                    end
                end
                if out.item then break end
            end
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- Battle start sync
-------------------------------------------------------------------------------

local function findWorldEventById(oid)
    if not (oid and Game and Game.world) then return nil end
    local found = nil
    local function walk(obj)
        if found then return end
        if obj.object_id == oid then found = obj return end
        if obj.children then
            for _, c in ipairs(obj.children) do walk(c) end
        end
    end
    walk(Game.world)
    return found
end

Utils.hook(Game, "encounter", function(orig, self, encounter, transition, enemy, context)
    if MP.started and not MPB.applying and not Game.battle then
        MPB.seed = love.math.random(1, 2 ^ 24)
        MPB.turn = 0
        MPB.active = true
        local enc_id = type(encounter) == "string" and encounter or (encounter and encounter.id)
        local oid = nil
        if enemy and type(enemy) == "table" then
            if isClass(enemy) then
                oid = enemy.object_id
            elseif enemy[1] and isClass(enemy[1]) then
                oid = enemy[1].object_id
            end
        end
        KNet.send({ c = "send", e = "benc", d = { enc = enc_id, oid = oid, seed = MPB.seed } })
    end
    return orig(self, encounter, transition, enemy, context)
end)

function MPB.startRemote(d)
    if not MP.started or Game.battle then return end
    MPB.seed = d.seed or 0
    MPB.turn = 0
    MPB.active = true
    MPB.applying = true
    local enemy = findWorldEventById(d.oid)
    local ok, err = pcall(function()
        Game:encounter(d.enc, true, enemy)
    end)
    MPB.applying = false
    if not ok then print("MPB: failed to start remote battle: " .. tostring(err)) end
end

-------------------------------------------------------------------------------
-- Turn-ordered action select
-------------------------------------------------------------------------------

-- Block input for battlers that are not yours during the selection states
local SELECT_STATES = {
    ACTIONSELECT = true, ENEMYSELECT = true, PARTYSELECT = true,
    MENUSELECT = true, XACTENEMYSELECT = true,
}

Utils.hook(Battle, "onKeyPressed", function(orig, self, key)
    if MPB.active and SELECT_STATES[self.state]
        and self.current_selecting >= 1 and not ownedByMe(self.current_selecting) then
        return -- not your turn; wait for that player's action
    end
    return orig(self, key)
end)

-- Broadcast our committed actions; replay remote ones
Utils.hook(Battle, "pushAction", function(orig, self, action_type, target, data, character_id, extra)
    local ci = character_id or self.current_selecting
    if MPB.active and not MPB.applying and ownedByMe(ci) then
        KNet.send({ c = "send", e = "bact", d = {
            ci = ci,
            at = action_type,
            t = serializeTarget(self, target),
            data = serializeData(data),
            extra = serializeData(extra),
        } })
    end
    return orig(self, action_type, target, data, character_id, extra)
end)

-- Seed the RNG identically before any action resolves, so damage rolls and
-- act outcomes are byte-identical on every client.
Utils.hook(Battle, "processAction", function(orig, self, action, ...)
    if MPB.active and action and action.character_id then
        love.math.setRandomSeed(MPB.seed * 31 + MPB.turn * 997 + action.character_id * 101)
    end
    return orig(self, action, ...)
end)

function MPB.applyRemoteAction(d)
    local battle = Game.battle
    if not (MPB.active and battle) then return end
    local battler = battle.party[d.ci]
    if not battler then return end
    if ownedByMe(d.ci) then return end -- never let an echo override our own input
    -- If that battler already has an action this turn, skip (duplicate)
    if battle.character_actions and battle.character_actions[d.ci] then return end
    MPB.applying = true
    local ok, err = pcall(function()
        battle:pushAction(d.at, deserializeTarget(battle, d.t),
            deserializeData(battler, d.data), d.ci, deserializeData(battler, d.extra))
    end)
    MPB.applying = false
    if not ok then print("MPB: failed to apply remote action: " .. tostring(err)) end
end

-- If it's the turn of a player who left the room, auto-defend so the battle
-- never soft-locks waiting for someone who is gone.
Utils.hook(Battle, "update", function(orig, self, ...)
    orig(self, ...)
    if MPB.active and self.state == "ACTIONSELECT" and self.current_selecting >= 1 then
        local key = ownerKey(self.current_selecting)
        if key and key ~= MP.my_key and not MP.players[key] then
            MPB.applying = true
            pcall(function() self:pushAction("DEFEND", nil, nil, self.current_selecting) end)
            MPB.applying = false
        end
    end
end)

-- Cancelling a queued action must be mirrored too, or clients disagree about
-- whose turn it is and the action menu appears to vanish.
Utils.hook(Battle, "removeAction", function(orig, self, character_id, from_defeat)
    if MPB.active and not MPB.applying and SELECT_STATES[self.state] and ownedByMe(character_id) then
        KNet.send({ c = "send", e = "bcancel", d = { ci = character_id } })
    end
    return orig(self, character_id, from_defeat)
end)

function MPB.applyRemoteCancel(d)
    local battle = Game.battle
    if not (MPB.active and battle) then return end
    if ownedByMe(d.ci) then return end
    MPB.applying = true
    pcall(function() battle:removeAction(d.ci) end)
    MPB.applying = false
end

-------------------------------------------------------------------------------
-- Attack minigame: you time YOUR attack; results are mirrored
-------------------------------------------------------------------------------

Utils.hook(Battle, "handleAttackingInput", function(orig, self, key)
    if not MPB.active then return orig(self, key) end
    if not Input.isConfirm(key) then return end
    if self.attack_done or self.cancel_attack or #self.battle_ui.attack_boxes == 0 then return end

    local closest, closest_attacks = math.huge, {}
    for _, attack in ipairs(self.battle_ui.attack_boxes) do
        if not attack.attacked and ownedByMe(self:getPartyIndex(attack.battler.chara.id)) then
            local close = attack:getClose()
            if close < 15 and close > -5 then
                if close == closest then
                    table.insert(closest_attacks, attack)
                elseif close < closest then
                    closest, closest_attacks = close, { attack }
                end
            end
        end
    end
    for _, attack in ipairs(closest_attacks) do
        local points = attack:hit()
        local action = self:getActionBy(attack.battler, true)
        action.points = points
        KNet.send({ c = "send", e = "batk", d = { ci = self:getPartyIndex(attack.battler.chara.id), pts = points } })
        if self:processAction(action) then
            self:finishAction(action)
        end
    end
end)

-- Remote-owned attack bolts wait at the hit line until that player's result
-- arrives instead of racing into an auto-miss (which desynced enemy HP and
-- could end the battle early on one client only).
Utils.hook(AttackBox, "getClose", function(orig, self)
    local v = orig(self)
    if MPB.active and not MPB.attack_timeout and not self.attacked and Game.battle then
        local ci = Game.battle:getPartyIndex(self.battler.chara.id)
        if ci and not ownedByMe(ci) and v <= -2 then
            return -1.9
        end
    end
    return v
end)

Utils.hook(Battle, "onAttackingState", function(orig, self, ...)
    MPB.attack_timeout = false
    MPB._atk_frames = 0
    return orig(self, ...)
end)

function MPB.applyRemoteAttack(d)
    local battle = Game.battle
    if not (MPB.active and battle and battle.battle_ui) then return end
    for _, attack in ipairs(battle.battle_ui.attack_boxes) do
        if not attack.attacked and battle:getPartyIndex(attack.battler.chara.id) == d.ci then
            attack:hit()
            local action = battle:getActionBy(attack.battler, true)
            if action then
                action.points = d.pts
                if battle:processAction(action) then
                    battle:finishAction(action)
                end
            end
            return
        end
    end
end

-------------------------------------------------------------------------------
-- Deterministic enemy attacks (same waves + same seed for everyone)
-------------------------------------------------------------------------------

Utils.hook(Encounter, "getNextWaves", function(orig, self, ...)
    if MPB.active then
        MPB.turn = MPB.turn + 1
        love.math.setRandomSeed(MPB.seed + MPB.turn * 7919)
    end
    return orig(self, ...)
end)

-------------------------------------------------------------------------------
-- Souls: yours is yours (your color); others are mirrored sprites
-------------------------------------------------------------------------------

Utils.hook(Game, "getSoulColor", function(orig, self)
    if MP.started and MP.profile.color then
        local c = MP.profile.color
        return c[1], c[2], c[3], 1
    end
    return orig(self)
end)

local function clearRemoteSouls()
    for _, s in pairs(MPB.remote_souls) do
        if s.remove then pcall(function() s:remove() end) end
    end
    MPB.remote_souls = {}
end

function MPB.updateRemoteSoul(key, d)
    local battle = Game.battle
    -- Clients can be a beat apart in the state machine; only mirror souls
    -- while WE are in the bullet phase so sprites never linger afterwards.
    if not (MPB.active and battle and battle.soul and battle.state == "DEFENDING") then return end
    local s = MPB.remote_souls[key]
    if not s or s:isRemoved() then
        local ok, spr = pcall(function()
            -- Same sprite + size as the real battle soul (Soul uses
            -- "player/heart_dodge" at native scale)
            local spr = Sprite("player/heart_dodge", d.x or 0, d.y or 0)
            spr:setOrigin(0.5, 0.5)
            local info = MP.players[key]
            local col = info and info.color or { 1, 1, 1 }
            spr:setColor(col[1], col[2], col[3], 0.7)
            spr.layer = battle.soul.layer - 1
            battle:addChild(spr)
            return spr
        end)
        if not ok then return end
        s = spr
        MPB.remote_souls[key] = s
    end
    s.mp_tx, s.mp_ty = d.x, d.y
end

Utils.hook(Battle, "onDefendingEndState", function(orig, self, ...)
    clearRemoteSouls()
    return orig(self, ...)
end)

Utils.hook(Battle, "onRemove", function(orig, self, ...)
    clearRemoteSouls()
    MPB.active = false
    if MP.applyParty then MP.applyParty() end
    return orig(self, ...)
end)

-------------------------------------------------------------------------------
-- Damage: a bullet hitting YOUR soul hurts YOUR character, mirrored to all
-------------------------------------------------------------------------------

Utils.hook(Battle, "hurt", function(orig, self, amount, exact, target, swoon)
    if MPB.active and not MPB.applying and self.state == "DEFENDING" then
        local mi = myIndex()
        if mi and self.party[mi] and self.party[mi]:isActive() then
            target = mi
        end
        KNet.send({ c = "send", e = "bhurt", d = {
            a = amount, x = exact and true or false,
            t = type(target) == "number" and target or nil,
            s = swoon and true or false,
        } })
    end
    return orig(self, amount, exact, target, swoon)
end)

function MPB.applyRemoteHurt(d)
    local battle = Game.battle
    if not (MPB.active and battle) then return end
    MPB.applying = true
    pcall(function() battle:hurt(d.a, d.x, d.t or "ANY", d.s) end)
    MPB.applying = false
end

-------------------------------------------------------------------------------
-- Waiting banner + soul position streaming
-------------------------------------------------------------------------------

Utils.hook(Battle, "draw", function(orig, self)
    orig(self)
    if MPB.active and SELECT_STATES[self.state]
        and self.current_selecting >= 1 and not ownedByMe(self.current_selecting) then
        local key = ownerKey(self.current_selecting)
        local info = key and MP.players[key]
        local name = info and info.name or "player"
        local font = Assets.getFont("main", 16)
        love.graphics.setFont(font)
        local text = "Waiting for " .. name .. "..."
        local w = font:getWidth(text)
        love.graphics.setColor(0, 0, 0, 0.7)
        love.graphics.rectangle("fill", 320 - w / 2 - 8, 6, w + 16, 24)
        local col = info and info.color or { 1, 1, 1 }
        love.graphics.setColor(col[1], col[2], col[3], 1)
        love.graphics.print(text, 320 - w / 2, 10)
        love.graphics.setColor(1, 1, 1, 1)
    end
end)

-- called from MP.update every frame
function MPB.tick()
    local battle = Game and Game.battle
    if not (MPB.active and battle) then return end

    if battle.state ~= "DEFENDING" and next(MPB.remote_souls) then
        clearRemoteSouls()
    end

    -- Safety: if a remote player's attack result never arrives (lag, leave),
    -- release their bolt after ~8s so the battle can continue.
    if battle.state == "ATTACKING" then
        MPB._atk_frames = (MPB._atk_frames or 0) + 1
        if MPB._atk_frames > 240 then MPB.attack_timeout = true end
    end

    -- stream my soul position during the bullet phase
    if battle.state == "DEFENDING" and battle.soul and not battle.soul:isRemoved() then
        MPB._t = (MPB._t or 0) + 1
        if MPB._t % 2 == 0 then
            KNet.send({ c = "send", e = "spos", d = {
                x = math.floor(battle.soul.x + 0.5), y = math.floor(battle.soul.y + 0.5),
            } })
        end
    end

    -- smooth remote souls toward their targets
    for _, s in pairs(MPB.remote_souls) do
        if s.mp_tx and not s:isRemoved() then
            s.x = s.x + (s.mp_tx - s.x) * 0.5
            s.y = s.y + (s.mp_ty - s.y) * 0.5
        end
    end
end

-------------------------------------------------------------------------------
-- Network message routing (called from multiplayer.lua)
-------------------------------------------------------------------------------

function MPB.onMessage(from, e, p)
    if e == "benc" then
        MPB.startRemote(p)
    elseif e == "bact" then
        MPB.applyRemoteAction(p)
    elseif e == "batk" then
        MPB.applyRemoteAttack(p)
    elseif e == "bhurt" then
        MPB.applyRemoteHurt(p)
    elseif e == "bcancel" then
        MPB.applyRemoteCancel(p)
    elseif e == "spos" then
        MPB.updateRemoteSoul(from, p)
    end
end

return MPB
