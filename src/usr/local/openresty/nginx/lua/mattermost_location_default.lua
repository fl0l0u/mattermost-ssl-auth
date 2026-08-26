--[[
https://github.com/fl0l0u
]]
-- access_by_lua_file, location /
-- 1. INIT
-- 1.1. Agent: upstream/redis setup and DN parsing live in the constructor
-- test ingress (127.0.0.1:18443) seam: pinned empty on the production server
local test_dn = ngx.var.mmssl_test_dn; if test_dn == "" then test_dn = nil end
local ssl = require("mattermost_ssl_auth"):new(test_dn or ngx.var.ssl_client_s_dn)
-- 1.2. The TLS layer must have validated the client certificate
if test_dn == nil and ngx.var.ssl_client_verify ~= "SUCCESS" then
    return ssl:fail(ngx.HTTP_FORBIDDEN, "no valid client certificate")
end

local function inject_session(cookies, token)
    -- Stash the session for the cookie-hydration header filter (pure Lua):
    -- it turns the stored cookie string into the Set-Cookie headers that
    -- populate the browser's jar.
    ngx.ctx.mmssl = { cookie_string = cookies, token = token }
    return ssl:rewrite_request(cookies, token, cookies:match("MMCSRF=([^=; ]+)"))
end

-- 2. HEALTH CHECK (throttled liveness, access phase): a stored session
-- that is over age, or that the probe just found dead (401), is
-- re-established here, before the request is rewritten. Never fails the
-- request: a broken renewal serves whatever is stored.
ssl:health_check()

-- 3. FETCH SESSION — read after the health check so a renewal's freshly
-- stored values are what gets replayed
local cookies = ssl:get_cookies()
local token = ssl:get_token()
if not cookies then
    -- 3.1. CREATE NEW SESSION (cold path): the agent owns the per-email
    -- lock and exits on every failure, so a returned session is stored
    -- and fresh
    cookies, token = ssl:establish_session(nil, nil)
end
return inject_session(cookies, token)
