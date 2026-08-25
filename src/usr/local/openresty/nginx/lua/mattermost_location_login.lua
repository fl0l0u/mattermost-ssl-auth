--[[
https://github.com/fl0l0u
]]
-- access_by_lua_file, location = /login (session renewal)
-- 1. INIT
local ssl = require("mattermost_ssl_auth"):new(ngx.var.ssl_client_s_dn)
if ngx.var.ssl_client_verify ~= "SUCCESS" then
    return ssl:fail(ngx.HTTP_FORBIDDEN, "no valid client certificate")
end

-- 2. RENEW CACHED SESSION
ssl:del_session()

-- 2.1. FETCH PASSWORD (the agent owns the per-email lock and exits on
-- every failure, so a returned password is known to log in)
local password = ssl:resolve_password()
if not password then
    return ssl:fail(ngx.HTTP_INTERNAL_SERVER_ERROR,
        "no password resolved for session renewal")
end

-- 2.2. Rebuild the stale cookie string from the incoming request, keeping
-- only the session cookies
local stale = {}
local request_cookies = ngx.req.get_headers()["Cookie"]
if request_cookies then
    for k, v in string.gmatch(request_cookies, "([^=; ]+)=([^=; ]+)") do
        if k == "MMAUTHTOKEN" or k == "MMUSERID" or k == "MMCSRF" then
            stale[#stale + 1] = k .. "=" .. v
        end
    end
end
local stale_csrf = ngx.req.get_headers()["X-CSRF-Token"]
if type(stale_csrf) == "table" then
    stale_csrf = stale_csrf[1]
end
if not stale_csrf then
    stale_csrf = ""
end

-- 2.3. AUTH USER (http_login returns cookies + token on success, and
-- nil + error message on failure — the second value doubles as the error)
local cookies, token = ssl:http_login(password, table.concat(stale, "; "), stale_csrf)
if not cookies then
    return ssl:fail(ngx.HTTP_BAD_REQUEST, token)
end

-- 2.4. CACHE SESSION
ssl:store_cookies(cookies)
ssl:store_token(token)

-- 3. REDIRECT BACK
local referer = ngx.req.get_headers()["Referer"]
if type(referer) == "table" then
    referer = referer[1]
end
if not referer or referer:match("^https?://[^/]+/login$") then
    return ngx.redirect("/")
end
return ngx.redirect(referer)
