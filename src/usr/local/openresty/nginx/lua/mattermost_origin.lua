--[[
https://github.com/fl0l0u
]]
-- Pure-Lua same-host Origin helpers for the WebSocket Origin
-- normalization: no `ngx`, no `os.getenv` — loads under stock LuaJIT
-- without OpenResty, so the logic stays unit-testable
-- (test/origin_test.lua).
local M = {}

function M.origin_host(url)
    -- host = the authority of an https?:// URL; after the host only a bare
    -- :port (or nothing) may follow — a trailing path or stray space
    -- rejects the shape. (Userinfo is NOT shape-rejected: the `user@`
    -- prefix stays inside the host capture, since `[^:/?#]+` matches
    -- `@` — such an Origin simply fails the same-host comparison
    -- downstream: "user@host" ~= "host".) Note: this OpenResty's
    -- LuaJIT 2.1.ROLLING pattern engine never matches an optional
    -- capture group ((...)?), so the tail is captured unconditionally
    -- and validated separately.
    local host, rest = url:match("^https?://([^:/?#]+)(.*)$")
    if not host then
        return nil
    end
    if rest ~= "" and rest:match("^:%d+$") == nil then
        return nil
    end
    return host
end

function M.same_host(a, b)
    local ha = M.origin_host(a)
    local hb = M.origin_host(b)
    return ha ~= nil and hb ~= nil and ha:lower() == hb:lower()
end

return M
