--[[
https://github.com/fl0l0u
]]
-- log_by_lua_file, proxied locations
-- 401 reactive session renewal (ADR 0002). Runs AFTER the response is
-- sent to the client: if the upstream answered 401 for a
-- session-protected API call, re-establish the session NOW (cosockets
-- are legal in the log phase; the next request then gets a fresh
-- session). The client may have seen that one 401 (the webapp may show
-- its login screen briefly); recovery is automatic on the next request
-- / page refresh / full-page /login.

-- 1. Only the upstream's own 401 (nginx-generated 401s carry no
-- upstream status) on a session-protected API path, never a browser
-- login attempt
local uri = ngx.var.uri
local act =
    ngx.status == 401
    and ngx.var.upstream_status == "401"
    and uri:sub(1, 8) == "/api/v4/"
    and uri ~= "/api/v4/users/login"
if not act then
    return
end

-- Same test-seam DN logic as the hooks; without a DN there is no
-- session to renew
local test_dn = ngx.var.mmssl_test_dn
if test_dn == "" then
    test_dn = nil
end
local dn = test_dn or ngx.var.ssl_client_s_dn
if not dn or dn == "" then
    return
end

-- 2. Renew: lock-serialized, peer-aware — a burst of parallel 401s
-- still costs exactly one login. pcall: this is after-the-fact, a
-- failure can only be logged, never surface; worst case (a burst) the
-- lock wait may take up to ~15 s, but the response is already out.
local ok, renewed, err = pcall(function()
    local ssl = require("mattermost_ssl_auth"):new(dn)
    return ssl:renew_for_401()
end)
if not ok then
    -- pcall caught an error; the error text is the second return value
    ngx.log(ngx.WARN, "[lua] 401 renewal skipped: " .. tostring(renewed))
    return
end
if not renewed then
    -- renew_for_401() gave up (nil + err); the 401 the client saw
    -- stands, the next request retries
    ngx.log(ngx.WARN, "[lua] 401 renewal skipped: " .. tostring(err))
end
