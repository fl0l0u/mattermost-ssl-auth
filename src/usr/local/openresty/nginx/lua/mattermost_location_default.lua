--[[
https://github.com/fl0l0u
]]
-- access_by_lua_file, location /
-- 1. INIT
-- 1.1. Agent: upstream/redis setup and DN parsing live in the constructor
-- test ingress (127.0.0.1:8443) seam: undefined on the production server
local test_dn = ngx.var.mmssl_test_dn; if test_dn == "" then test_dn = nil end
local ssl = require("mattermost_ssl_auth"):new(test_dn or ngx.var.ssl_client_s_dn)
-- 1.2. The TLS layer must have validated the client certificate
if test_dn == nil and ngx.var.ssl_client_verify ~= "SUCCESS" then
    return ssl:fail(ngx.HTTP_FORBIDDEN, "no valid client certificate")
end

local function inject_session(cookies, token)
    return ssl:rewrite_request(cookies, token, cookies:match("MMCSRF=([^=; ]+)"))
end

-- 2. FETCH SESSION
local cookies = ssl:get_cookies()
if cookies then
    -- 2.1. CACHED SESSION: forward it as-is
    return inject_session(cookies, ssl:get_token())
end

-- 2.2. CREATE NEW SESSION: the agent owns the per-email lock and exits on
-- every failure, so a returned password is known to log in
local password = ssl:resolve_password()
if not password then
    -- Another worker published the session while we waited
    local fresh = ssl:get_cookies()
    if not fresh then
        return ssl:fail(ngx.HTTP_INTERNAL_SERVER_ERROR,
            "no password resolved for session")
    end
    return inject_session(fresh, ssl:get_token())
end

-- 2.3. AUTH USER (http_login returns cookies + token on success, and
-- nil + error message on failure — the second value doubles as the error)
local session_cookies, token = ssl:http_login(password, nil, nil)
if not session_cookies then
    return ssl:fail(ngx.HTTP_BAD_REQUEST, token)
end

-- 2.4. CACHE SESSION
ssl:store_cookies(session_cookies)
ssl:store_token(token)
return inject_session(session_cookies, token)
