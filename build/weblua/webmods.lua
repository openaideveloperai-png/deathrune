-- Web mod support (Lua side).
--
-- The page (modloader.js) writes uploaded .zip mods into the save directory's
-- mods/ folder. Kristal's own loader already mounts .zip mods when it scans
-- that folder, so all this module does is re-run the scan when a mod is added
-- or removed, and refresh the mod list if the player is looking at it.

if not WEB then return end

local KNet = require("src.web.knet")

WebMods = { loading = false, pending = false }

--- Re-scans the mods folder and refreshes the mod list.
--- Deferred while a mod is actually being played (rescanning mid-game would
--- pull the rug out from under the running project).
function WebMods.rescan()
    if not (Kristal and Kristal.Mods) then return end
    if Game and (Game.world or Game.battle) then
        WebMods.pending = true
        return
    end
    if WebMods.loading then
        WebMods.pending = true
        return
    end

    WebMods.loading = true
    WebMods.pending = false

    Kristal.Mods.clear()
    Kristal.loadAssets("", "mods", "", function()
        WebMods.loading = false
        pcall(Kristal.setDesiredWindowTitleAndIcon)

        local menu = Kristal.States and Kristal.States["MainMenu"]
        if menu and menu.mod_list and menu.mod_list.buildModList then
            pcall(function() menu.mod_list:buildModList() end)
        end

        local n = 0
        for _ in pairs(Kristal.Mods.getMods() or {}) do n = n + 1 end
        print("WebMods: mod list reloaded (" .. n .. " project(s))")
    end)
end

KNet.on("mod_added", function(d)
    if d.removed then
        print("WebMods: removed " .. tostring(d.name))
    else
        print("WebMods: added " .. tostring(d.name))
    end
    WebMods.rescan()
end)

-- If a rescan was requested while a project was running, do it once we're back
-- at the main menu.
Utils.hook(MainMenu, "enter", function(orig, self, ...)
    orig(self, ...)
    -- Reaching the menu means asset + mod loading survived this boot; let the
    -- page clear its "mods may have crashed us" flag.
    KNet.send({ c = "mods_ok" })
    if WebMods.pending then
        WebMods.rescan()
    end
end)

return WebMods
