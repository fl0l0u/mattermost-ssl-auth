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
    return ssl:rewrite_request(cookies, token, cookies:match("MMCSRF=([^=; ]+)"))
end

-- 2. FETCH SESSION (with proactive renewal)
-- "fresh", "renewed", and "degraded" all mean the stored session is
-- usable: fresh is within the renewal age, renewed was just re-logged
-- in, degraded kept its pre-renewal session after a failed renewal.
local state = ssl:maybe_renew_session()
if state ~= "miss" then
    return inject_session(ssl:get_cookies(), ssl:get_token())
end

-- 2.1. CREATE NEW SESSION (cold path): the agent owns the per-email
-- lock and exits on every failure, so a returned session is stored
-- and fresh
local cookies, token = ssl:establish_session(nil, nil)
return inject_session(cookies, token)
