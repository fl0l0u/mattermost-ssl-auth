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
if type(request_cookies) == "table" then
    -- A client may send several Cookie headers; rejoin into one before parsing.
    request_cookies = table.concat(request_cookies, "; ")
end
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
-- Honor the Referer only when it is same-origin: a relative path starting
-- with a single "/" (not "//", which is protocol-relative, and not "/.."),
-- or an absolute https:// URL whose host matches this gateway's host
-- (case-insensitively). Anything else — including a referer that points back
-- at /login, which would re-trigger this hook in a loop — redirects to "/".
local referer = ngx.req.get_headers()["Referer"]
if type(referer) == "table" then
    referer = referer[1]
end

local function is_same_origin(path)
    if not path then
        return false
    end
    if path:sub(1, 1) == "/" and path:sub(1, 2) ~= "//" and path:sub(1, 3) ~= "/.." then
        return true
    end
    local host = path:match("^https://([^/]+)")
    return host ~= nil and string.lower(host) == string.lower(ngx.var.host)
end

if not is_same_origin(referer) or referer:match("/login$") then
    return ngx.redirect("/")
end
return ngx.redirect(referer)
