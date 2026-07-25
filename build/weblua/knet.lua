-- KNet: Lua side of the web multiplayer bridge.
--
-- The WASM build has no sockets, so networking runs in the page's JavaScript
-- (knet.js, using Supabase Realtime). The two sides talk through:
--   Lua -> JS: print("[KNET]<json>") -- intercepted by Module.print in the page
--   JS -> Lua: the page writes <savedir>/knet_in.json; Lua polls it each frame
--
-- IMPORTANT love.js quirks honored here:
--   * love.filesystem.read on a MISSING file freezes the engine, so every
--     read is guarded with getInfo first.
--   * The save directory must exist before JS can write into it, so we write
--     a boot file immediately.

local KNet = { ready = false, last_seq = 0, handlers = {}, frame = 0 }

function KNet.send(t)
    print("[KNET]" .. JSON.encode(t))
end

function KNet.on(event, fn)
    KNet.handlers[event] = fn
end

function KNet.init()
    if KNet.ready then return end
    love.filesystem.write("knet_boot.txt", "1")
    KNet.send({ c = "ready", savedir = love.filesystem.getSaveDirectory() })
    KNet.ready = true
end

function KNet.update()
    if not KNet.ready then return end
    KNet.frame = KNet.frame + 1
    if love.filesystem.getInfo("knet_in.json") then
        local raw = love.filesystem.read("knet_in.json")
        local ok, data = pcall(JSON.decode, raw)
        if ok and type(data) == "table" and type(data.msgs) == "table" then
            for _, m in ipairs(data.msgs) do
                if type(m) == "table" and m.s and m.s > KNet.last_seq then
                    KNet.last_seq = m.s
                    local h = KNet.handlers[m.t]
                    if h then
                        local hok, err = pcall(h, m.d or {})
                        if not hok then print("KNet handler error (" .. tostring(m.t) .. "): " .. tostring(err)) end
                    end
                end
            end
        end
        -- Periodically tell JS what we've consumed so it can prune its queue
        if KNet.frame % 30 == 0 and KNet.last_seq > 0 then
            KNet.send({ c = "ack", s = KNet.last_seq })
        end
    end
end

return KNet
