-- Kristal Web Multiplayer (overworld co-op stage).
--
-- Session model: rooms are Supabase Realtime channels (see knet.js). The first
-- player (room creator) is the host and always plays Kris; joiners are assigned
-- Susie, Ralsei, Noelle, then that trio loops. Only the host can be Kris.
-- Each player controls their own character; remote players appear as
-- independent characters with a name tag in the player's chosen soul color.

if not WEB then return end

local KNet = require("src.web.knet")

MP = {
    state = "idle",          -- idle | connecting | lobby | playing
    room = nil,
    my_key = nil,
    hosting = false,
    players = {},            -- key -> {key, name, color, ts, h}
    order = {},              -- sorted list of keys (index 1 = host = Kris)
    remotes = {},            -- key -> Character
    remote_targets = {},     -- key -> {x, y, f, m, w}
    started = false,
    tick = 0,
    profile = { name = "PLAYER", color = { 1, 0, 0 } },
}

MP.CHAR_SEQ = { "susie", "ralsei", "noelle" }
MP.COLORS = {
    { "RED",    { 1, 0, 0 } },
    { "CYAN",   { 0, 1, 1 } },
    { "GREEN",  { 0, 1, 0 } },
    { "YELLOW", { 1, 1, 0 } },
    { "ORANGE", { 1, 0.6, 0 } },
    { "PURPLE", { 0.8, 0.3, 1 } },
    { "BLUE",   { 0.3, 0.5, 1 } },
    { "PINK",   { 1, 0.5, 0.8 } },
}

-------------------------------------------------------------------------------
-- Profile persistence
-------------------------------------------------------------------------------

function MP.loadProfile()
    if love.filesystem.getInfo("mp_profile.json") then
        local ok, data = pcall(JSON.decode, love.filesystem.read("mp_profile.json"))
        if ok and type(data) == "table" and data.name then
            MP.profile = data
        end
    end
end

function MP.saveProfile()
    love.filesystem.write("mp_profile.json", JSON.encode(MP.profile))
end

-------------------------------------------------------------------------------
-- Session / roster
-------------------------------------------------------------------------------

local function sortedOrder(players)
    local keys = {}
    for k in pairs(players) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
        local pa, pb = players[a], players[b]
        if (pa.h or 0) ~= (pb.h or 0) then return (pa.h or 0) > (pb.h or 0) end
        if (pa.ts or 0) ~= (pb.ts or 0) then return (pa.ts or 0) < (pb.ts or 0) end
        return a < b
    end)
    return keys
end

function MP.charForIndex(i)
    if i <= 1 then return "kris" end
    return MP.CHAR_SEQ[((i - 2) % #MP.CHAR_SEQ) + 1]
end

function MP.charForKey(key)
    for i, k in ipairs(MP.order) do
        if k == key then return MP.charForIndex(i) end
    end
    return "susie"
end

function MP.myChar()
    return MP.charForKey(MP.my_key)
end

function MP.host(code)
    MP.room = code
    MP.hosting = true
    MP.state = "connecting"
    KNet.send({ c = "host", room = code, meta = { name = MP.profile.name, color = MP.profile.color } })
end

function MP.join(code)
    MP.room = code
    MP.hosting = false
    MP.state = "connecting"
    KNet.send({ c = "join", room = code, meta = { name = MP.profile.name, color = MP.profile.color } })
end

function MP.leave()
    KNet.send({ c = "leave" })
    MP.state = "idle"
    MP.room = nil
    MP.players = {}
    MP.order = {}
    MP.started = false
    for _, c in pairs(MP.remotes) do
        if c.remove then c:remove() end
    end
    MP.remotes = {}
    MP.remote_targets = {}
end

function MP.beginGame()
    MP.started = true
    MP.state = "playing"
    Kristal.loadMod("example", 1)
end

-------------------------------------------------------------------------------
-- KNet handlers
-------------------------------------------------------------------------------

KNet.on("status", function(d)
    if d.state == "joined" then
        MP.my_key = d.key
        if MP.state == "connecting" then MP.state = "lobby" end
        print("MP: joined room " .. tostring(d.room) .. " as " .. tostring(d.key))
    elseif d.state == "error" or d.state == "closed" then
        print("MP: connection " .. tostring(d.state) .. " (" .. tostring(d.why) .. ")")
        if MP.state ~= "idle" then MP.state = "idle" end
    end
end)

KNet.on("presence", function(d)
    local players = {}
    for _, p in ipairs(d.players or {}) do
        players[p.key] = p
    end
    MP.players = players
    MP.order = sortedOrder(players)
    print("MP: roster now " .. #MP.order .. " player(s)")
    if MP.started and Game and Game.world then
        MP.refreshRemotes()
    end
end)

KNet.on("msg", function(d)
    local from, e, p = d.from, d.e, d.p or {}
    if e == "start" then
        if not MP.started then MP.beginGame() end
    elseif e == "pos" then
        MP.remote_targets[from] = p
    end
end)

-------------------------------------------------------------------------------
-- Overworld sync
-------------------------------------------------------------------------------

function MP.refreshRemotes()
    if not (Game and Game.world and Game.world.player) then return end
    local myMap = Game.world.map and Game.world.map.id or "?"
    for _, key in ipairs(MP.order) do
        if key ~= MP.my_key then
            local info = MP.players[key]
            local c = MP.remotes[key]
            if not c or c:isRemoved() or c.stage ~= Game.world.stage then
                local px, py = Game.world.player.x, Game.world.player.y
                local ok, char = pcall(function()
                    return Character(MP.charForKey(key), px, py)
                end)
                if ok and char then
                    char.layer = Game.world.player.layer
                    char.mp_name = info and info.name or "?"
                    char.mp_color = info and info.color or { 1, 1, 1 }
                    Game.world:addChild(char)
                    MP.remotes[key] = char
                    c = char
                end
            end
            if c then
                c.mp_name = info and info.name or c.mp_name
                c.mp_color = info and info.color or c.mp_color
                local t = MP.remote_targets[key]
                c.visible = not (t and t.m and t.m ~= myMap)
            end
        end
    end
    -- despawn characters for players who left
    for key, c in pairs(MP.remotes) do
        if not MP.players[key] then
            if c.remove then c:remove() end
            MP.remotes[key] = nil
            MP.remote_targets[key] = nil
        end
    end
end

local function round(n) return math.floor(n + 0.5) end

function MP.update(dt)
    KNet.update()
    if not MP.started then return end
    MP.tick = MP.tick + 1

    local inWorld = Game and Game.world and Game.world.player and not Game.battle
    if inWorld then
        -- broadcast my position at ~15Hz
        if MP.tick % 2 == 0 then
            local p = Game.world.player
            local map = Game.world.map and Game.world.map.id or "?"
            local moving = MP._lx ~= nil and (math.abs(p.x - MP._lx) > 0.5 or math.abs(p.y - MP._ly) > 0.5)
            if moving or MP._was_moving or MP.tick % 60 == 0 then
                KNet.send({ c = "send", e = "pos", d = {
                    x = round(p.x), y = round(p.y),
                    f = p.facing, m = map, w = moving and 1 or 0,
                } })
            end
            MP._lx, MP._ly = p.x, p.y
            MP._was_moving = moving
        end

        -- move remote characters toward their targets
        local myMap = Game.world.map and Game.world.map.id or "?"
        for key, c in pairs(MP.remotes) do
            local t = MP.remote_targets[key]
            if t and c and not c:isRemoved() then
                if t.m and t.m ~= myMap then
                    c.visible = false
                else
                    c.visible = true
                    local dx, dy = (t.x or c.x) - c.x, (t.y or c.y) - c.y
                    local dist = math.sqrt(dx * dx + dy * dy)
                    if dist > 120 then
                        c:setPosition(t.x, t.y)
                    elseif dist > 0.5 then
                        c:setPosition(c.x + dx * 0.35, c.y + dy * 0.35)
                    end
                    if t.f then pcall(function() c:setFacing(t.f) end) end
                    pcall(function()
                        if c.sprite and c.sprite.walking ~= nil then
                            c.sprite.walking = (t.w == 1) or dist > 2
                        end
                    end)
                end
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Engine hooks
-------------------------------------------------------------------------------

-- Each client spawns ONLY its own character (no followers trailing Kris);
-- everyone else appears as an independent, network-driven character.
Utils.hook(World, "spawnParty", function(orig, self, marker, party, extra, facing)
    if not MP.started then return orig(self, marker, party, extra, facing) end

    local pm = Game:getPartyMember(MP.myChar())
    if type(marker) == "table" and marker[1] ~= nil and marker[2] ~= nil then
        self:spawnPlayer(marker[1], marker[2], pm:getActor(), pm.id)
    else
        if not self.map:hasMarker(marker) then marker = "spawn" end
        self:spawnPlayer(marker, pm:getActor(), pm.id)
    end
    if facing then self.player:setFacing(facing) end
    self:spawnSoul()

    MP.remotes = {}
    MP.refreshRemotes()
end)

-- Name tags above remote players, tinted with their soul color
Utils.hook(Character, "draw", function(orig, self)
    orig(self)
    if self.mp_name then
        local font = Assets.getFont("main", 16)
        love.graphics.setFont(font)
        local w = font:getWidth(self.mp_name) * 0.5
        local x = self.width / 2 - w / 2
        local y = -14
        love.graphics.setColor(0, 0, 0, 0.6)
        love.graphics.print(self.mp_name, x + 1, y + 1, 0, 0.5, 0.5)
        local col = self.mp_color or { 1, 1, 1 }
        love.graphics.setColor(col[1], col[2], col[3], 1)
        love.graphics.print(self.mp_name, x, y, 0, 0.5, 0.5)
        love.graphics.setColor(1, 1, 1, 1)
    end
end)

-------------------------------------------------------------------------------
-- PARTY button in the C menu (dark world menu)
-------------------------------------------------------------------------------

local function textSprite(text, w, h, color, bg)
    local canvas = love.graphics.newCanvas(w, h)
    local prev = love.graphics.getCanvas()
    love.graphics.push("all")
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    if bg then
        love.graphics.setColor(bg)
        love.graphics.rectangle("fill", 0, 0, w, h)
    end
    local font = Assets.getFont("main", 16)
    love.graphics.setFont(font)
    love.graphics.setColor(color)
    love.graphics.print(text, math.floor(w / 2 - font:getWidth(text) / 2), math.floor(h / 2 - font:getHeight() / 2))
    love.graphics.setCanvas(prev)
    love.graphics.pop()
    return canvas
end

MpPartyBox = Class(Object)

function MpPartyBox:init()
    Object.init(self, 40, 130, 560, 220)
    self.parallax_x = 0
    self.parallax_y = 0
end

function MpPartyBox:draw()
    love.graphics.setColor(0, 0, 0, 0.9)
    love.graphics.rectangle("fill", 0, 0, self.width, self.height)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setLineWidth(3)
    love.graphics.rectangle("line", 0, 0, self.width, self.height)

    local font = Assets.getFont("main", 32)
    love.graphics.setFont(font)
    love.graphics.print("ONLINE PARTY", 20, 10)
    local small = Assets.getFont("main", 16)
    love.graphics.setFont(small)
    love.graphics.setColor(1, 1, 0.5)
    love.graphics.print("ROOM CODE: " .. tostring(MP.room or "----") .. "   (share this code to invite players)", 20, 50)

    local y = 80
    for i, key in ipairs(MP.order) do
        local p = MP.players[key]
        if p then
            local col = p.color or { 1, 1, 1 }
            love.graphics.setColor(col[1], col[2], col[3])
            local label = tostring(p.name or "?") .. "  -  " .. MP.charForIndex(i):upper()
            if i == 1 then label = label .. "  (HOST)" end
            if key == MP.my_key then label = label .. "  (YOU)" end
            love.graphics.print(label, 30, y)
            y = y + 24
        end
    end
    love.graphics.setColor(0.6, 0.6, 0.6)
    love.graphics.print("Press CANCEL to close", 20, self.height - 26)
    love.graphics.setColor(1, 1, 1, 1)
    Object.draw(self)
end

function MpPartyBox:onKeyPressed(key)
    if Input.isCancel(key) then
        self:remove()
        if Game.world and Game.world.menu then
            Game.world.menu.box = nil
            Game.world.menu.state = "MAIN"
        end
    end
end

Utils.hook(DarkMenu, "addButtons", function(orig, self)
    orig(self)
    if MP.started then
        self:addButton({
            ["state"]          = "MP_PARTY",
            ["sprite"]         = textSprite("PARTY", 60, 20, { 0.7, 0.7, 0.7 }),
            ["hovered_sprite"] = textSprite("PARTY", 60, 20, { 1, 1, 0.3 }),
            ["desc_sprite"]    = textSprite("Online party", 90, 30, { 1, 1, 1 }),
            ["callback"]       = function()
                self.box = MpPartyBox()
                self.box.layer = self.layer + 1
                Game.world:addChild(self.box)
                self.ui_select:stop()
                self.ui_select:play()
            end
        })
    end
end)

-------------------------------------------------------------------------------
-- ONLINE screen in the main menu
-------------------------------------------------------------------------------

MainMenuOnline = Class(StateClass)

function MainMenuOnline:init(menu)
    self.menu = menu
    self.substate = "NAME"
    self.name_input = ""
    self.code_input = ""
    self.color_idx = 1
    self.mode_idx = 1
end

function MainMenuOnline:registerEvents()
    self:registerEvent("enter", self.onEnter)
    self:registerEvent("keypressed", self.onKeyPressed)
    self:registerEvent("draw", self.draw)
end

function MainMenuOnline:onEnter()
    MP.loadProfile()
    self.name_input = MP.profile.name ~= "PLAYER" and MP.profile.name or ""
    self.code_input = ""
    self.substate = "NAME"
    -- restore saved color selection
    for i, c in ipairs(MP.COLORS) do
        local pc = MP.profile.color
        if pc and math.abs(c[2][1] - pc[1]) < 0.01 and math.abs(c[2][2] - pc[2]) < 0.01 and math.abs(c[2][3] - pc[3]) < 0.01 then
            self.color_idx = i
        end
    end
end

local KEY_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789"

function MainMenuOnline:onKeyPressed(key, is_repeat)
    local st = self.substate

    if st == "NAME" or st == "CODE" then
        local field = st == "NAME" and "name_input" or "code_input"
        local maxlen = st == "NAME" and 12 or 4
        if #key == 1 and KEY_CHARS:find(key, 1, true) and #self[field] < maxlen then
            self[field] = self[field] .. key:upper()
            return true
        elseif key == "backspace" then
            self[field] = self[field]:sub(1, -2)
            return true
        end
    end

    if Input.isCancel(key) then
        Assets.stopAndPlaySound("ui_move")
        if st == "NAME" then
            self.menu:setState("TITLE")
        elseif st == "COLOR" then
            self.substate = "NAME"
        elseif st == "MODE" then
            self.substate = "COLOR"
        elseif st == "CODE" then
            self.substate = "MODE"
        elseif st == "LOBBY" then
            MP.leave()
            self.substate = "MODE"
        end
        return true
    end

    if Input.isConfirm(key) then
        Assets.stopAndPlaySound("ui_select")
        if st == "NAME" then
            if #self.name_input >= 1 then
                MP.profile.name = self.name_input
                self.substate = "COLOR"
            end
        elseif st == "COLOR" then
            MP.profile.color = MP.COLORS[self.color_idx][2]
            MP.saveProfile()
            self.substate = "MODE"
        elseif st == "MODE" then
            if self.mode_idx == 1 then
                local code = ""
                for _ = 1, 4 do
                    local n = love.math.random(1, 26)
                    code = code .. string.char(64 + n)
                end
                MP.host(code)
                self.substate = "LOBBY"
            else
                self.code_input = ""
                self.substate = "CODE"
            end
        elseif st == "CODE" then
            if #self.code_input == 4 then
                MP.join(self.code_input)
                self.substate = "LOBBY"
            end
        elseif st == "LOBBY" then
            if MP.hosting and MP.state == "lobby" then
                KNet.send({ c = "send", e = "start", d = { mod = "example" } })
                MP.beginGame()
            end
        end
        return true
    end

    if st == "COLOR" then
        if Input.is("left", key) then self.color_idx = ((self.color_idx - 2) % #MP.COLORS) + 1 end
        if Input.is("right", key) then self.color_idx = (self.color_idx % #MP.COLORS) + 1 end
    elseif st == "MODE" then
        if Input.is("up", key) or Input.is("down", key) then
            self.mode_idx = self.mode_idx == 1 and 2 or 1
        end
    end
    return true
end

function MainMenuOnline:draw()
    local font = Assets.getFont("main")
    love.graphics.setFont(font)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("- ONLINE -", 64, 40)

    local small = Assets.getFont("main", 16)
    local st = self.substate

    if st == "NAME" then
        love.graphics.print("Your name:", 64, 110)
        love.graphics.setColor(1, 1, 0.5)
        love.graphics.print(self.name_input .. "_", 64, 150)
        love.graphics.setFont(small)
        love.graphics.setColor(0.7, 0.7, 0.7)
        love.graphics.print("Type A-Z / 0-9, ENTER to continue, CANCEL to go back", 64, 400)
    elseif st == "COLOR" then
        love.graphics.print("Your SOUL color:", 64, 110)
        local c = MP.COLORS[self.color_idx]
        love.graphics.setColor(c[2][1], c[2][2], c[2][3])
        love.graphics.print("< " .. c[1] .. " >", 64, 150)
        love.graphics.rectangle("fill", 300, 150, 28, 28)
        love.graphics.setFont(small)
        love.graphics.setColor(0.7, 0.7, 0.7)
        love.graphics.print("LEFT/RIGHT to change, ENTER to continue", 64, 400)
    elseif st == "MODE" then
        love.graphics.print("Multiplayer:", 64, 110)
        love.graphics.setColor(self.mode_idx == 1 and { 1, 1, 0.5 } or { 0.6, 0.6, 0.6 })
        love.graphics.print((self.mode_idx == 1 and "> " or "  ") .. "HOST A GAME", 64, 160)
        love.graphics.setColor(self.mode_idx == 2 and { 1, 1, 0.5 } or { 0.6, 0.6, 0.6 })
        love.graphics.print((self.mode_idx == 2 and "> " or "  ") .. "JOIN A GAME", 64, 200)
    elseif st == "CODE" then
        love.graphics.print("Enter room code:", 64, 110)
        love.graphics.setColor(1, 1, 0.5)
        love.graphics.print(self.code_input .. "_", 64, 150)
        love.graphics.setFont(small)
        love.graphics.setColor(0.7, 0.7, 0.7)
        love.graphics.print("4 letters, ENTER to join", 64, 400)
    elseif st == "LOBBY" then
        if MP.state == "connecting" then
            love.graphics.print("Connecting...", 64, 110)
        elseif MP.state == "idle" then
            love.graphics.setColor(1, 0.5, 0.5)
            love.graphics.print("Connection failed. CANCEL to go back.", 64, 110)
        else
            love.graphics.print("ROOM CODE: " .. tostring(MP.room), 64, 100)
            love.graphics.setFont(small)
            love.graphics.setColor(0.7, 0.7, 0.7)
            love.graphics.print("Share this code so friends can join!", 64, 135)
            love.graphics.setFont(font)
            local y = 170
            for i, key in ipairs(MP.order) do
                local p = MP.players[key]
                if p then
                    local col = p.color or { 1, 1, 1 }
                    love.graphics.setColor(col[1], col[2], col[3])
                    local label = tostring(p.name or "?") .. " - " .. MP.charForIndex(i):upper()
                    if i == 1 then label = label .. " (HOST)" end
                    if key == MP.my_key then label = label .. " (YOU)" end
                    love.graphics.print(label, 64, y)
                    y = y + 34
                end
            end
            love.graphics.setFont(small)
            love.graphics.setColor(0.7, 0.7, 0.7)
            if MP.hosting then
                love.graphics.print("ENTER: start game for everyone   CANCEL: leave", 64, 400)
            else
                love.graphics.print("Waiting for the host to start...   CANCEL: leave", 64, 400)
            end
        end
    end
    love.graphics.setColor(1, 1, 1)
end

-- Register the ONLINE state and title menu option (states are registered in
-- MainMenu:enter, which also runs when returning from a mod -- guard repeats)
Utils.hook(MainMenu, "enter", function(orig, self)
    orig(self)
    if not self.online_screen then
        self.online_screen = MainMenuOnline(self)
        self.state_manager:addState("ONLINE", self.online_screen)
    end
end)

Utils.hook(MainMenuTitle, "onEnter", function(orig, self, ...)
    orig(self, ...)
    for _, opt in ipairs(self.options) do
        if opt[1] == "online" then return end
    end
    table.insert(self.options, 2, { "online", "Play Online" })
end)

Utils.hook(MainMenuTitle, "onKeyPressed", function(orig, self, key, is_repeat)
    if Input.isConfirm(key) and self.options[self.selected_option]
        and self.options[self.selected_option][1] == "online" then
        Assets.stopAndPlaySound("ui_select")
        self.menu:setState("ONLINE")
        return true
    end
    return orig(self, key, is_repeat)
end)

-------------------------------------------------------------------------------
-- Wire into the game loop
-------------------------------------------------------------------------------

KNet.init()

local orig_update = love.update
love.update = function(dt)
    orig_update(dt)
    local ok, err = pcall(MP.update, dt)
    if not ok and not MP._err_once then
        MP._err_once = true
        print("MP update error: " .. tostring(err))
    end
end

return MP
