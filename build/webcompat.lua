-- Web (love.js / Emscripten) compatibility layer for Kristal.
--
-- Kristal targets LÖVE 11.5 running on LuaJIT. love.js runs the engine on
-- vanilla Lua 5.1 in the browser, which is missing three things LuaJIT
-- provides and Kristal relies on. This module supplies web-safe stand-ins.
--
-- It is required as the very first statement of main.lua. On desktop LÖVE the
-- real LuaJIT `ffi` module exists, so this module detects that and does
-- absolutely nothing -- every desktop code path is left exactly as upstream.
-- The shims below only activate in the browser build.

-- If LuaJIT's FFI is present we are on desktop: leave everything untouched.
if pcall(require, "ffi") then
    return
end

--------------------------------------------------------------------------------
-- 1. `ffi` stand-in
--
-- discordrpc.lua and https.lua `require "ffi"` only to locate and load native
-- libraries (Discord RPC, lua-https) which cannot exist in a browser. Both
-- modules already fall back gracefully when the native library fails to load,
-- so we just need `require "ffi"` to succeed and `ffi.load` to report failure.
--------------------------------------------------------------------------------
local ffi = {
    os = "Web",
    arch = "wasm",
    load = function() return nil end, -- native libs are unavailable in the browser
    cdef = function() end,
    typeof = function() return nil end,
    new = function() return nil end,
    cast = function() return nil end,
    metatype = function() return nil end,
    sizeof = function() return 0 end,
    string = function() return "" end,
}
ffi.C = setmetatable({}, { __index = function() return function() end end })
package.preload["ffi"] = function() return ffi end

--------------------------------------------------------------------------------
-- 2. package.searchpath
--
-- Added in Lua 5.2 and present in LuaJIT, but missing from the vanilla Lua 5.1
-- that love.js runs. Kristal's hotswapper uses it. Standard implementation.
--------------------------------------------------------------------------------
if not package.searchpath then
    function package.searchpath(name, path, sep, rep)
        sep = sep or "."
        rep = rep or "/"
        if sep ~= "" then
            name = name:gsub("%" .. sep, rep)
        end
        local errmsg = ""
        for template in path:gmatch("[^;]+") do
            local filename = template:gsub("%?", name)
            local f = io.open(filename, "r")
            if f then
                f:close()
                return filename
            end
            errmsg = errmsg .. "\n\tno file '" .. filename .. "'"
        end
        return nil, errmsg
    end
end

--------------------------------------------------------------------------------
-- 3. `bit` stand-in
--
-- LuaJIT exposes the `bit` library; vanilla Lua 5.1 does not. Kristal uses it in
-- tiledutils.lua (`bit.band`) to decode Tiled tile-flip flags. This is a small,
-- correct pure-Lua implementation operating on unsigned 32-bit integers.
--------------------------------------------------------------------------------
local MOD = 0x100000000 -- 2^32

local function normalize(x)
    return math.floor(x) % MOD
end

local function bitwise(a, b, op)
    a, b = normalize(a), normalize(b)
    local result, bitval = 0, 1
    for _ = 1, 32 do
        local abit, bbit = a % 2, b % 2
        if op(abit, bbit) == 1 then result = result + bitval end
        a, b = (a - abit) / 2, (b - bbit) / 2
        bitval = bitval * 2
    end
    return result
end

local bit = {}
function bit.band(a, b)  return bitwise(a, b, function(x, y) return (x == 1 and y == 1) and 1 or 0 end) end
function bit.bor(a, b)   return bitwise(a, b, function(x, y) return (x == 1 or y == 1) and 1 or 0 end) end
function bit.bxor(a, b)  return bitwise(a, b, function(x, y) return (x ~= y) and 1 or 0 end) end
function bit.bnot(a)     return normalize(-1 - normalize(a)) end
function bit.lshift(a, n) return normalize(normalize(a) * (2 ^ n)) end
function bit.rshift(a, n) return math.floor(normalize(a) / (2 ^ n)) end
function bit.arshift(a, n) return math.floor(normalize(a) / (2 ^ n)) end
function bit.tobit(a)
    a = normalize(a)
    if a >= 0x80000000 then a = a - MOD end
    return a
end
function bit.tohex(a) return string.format("%08x", normalize(a)) end

---@diagnostic disable-next-line: lowercase-global
bit = bit -- keep luacheck quiet
_G.bit = bit
package.preload["bit"] = function() return bit end

--------------------------------------------------------------------------------
-- 4. love.filesystem.getRealDirectory guard
--
-- In love.js, love.filesystem.getRealDirectory() hangs forever when the path
-- does not exist on disk. discordrpc.lua and https.lua call it with "lib/",
-- which never exists in the web build, deadlocking startup before the main loop
-- runs. getInfo() is safe on missing paths, so short-circuit those.
--------------------------------------------------------------------------------
if love and love.filesystem and love.filesystem.getRealDirectory
        and not love.filesystem.__web_getRealDirectory_guarded then
    local real_getRealDirectory = love.filesystem.getRealDirectory
    love.filesystem.getRealDirectory = function(path)
        if path ~= nil and love.filesystem.getInfo(path) == nil then
            return nil
        end
        return real_getRealDirectory(path)
    end
    love.filesystem.__web_getRealDirectory_guarded = true
end
