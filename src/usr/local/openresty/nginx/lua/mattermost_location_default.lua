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

-- 1.3. WEBSOCKET ORIGIN NORMALIZATION (same-host only)
-- Why: Mattermost compares the WS upgrade's Origin to the SiteURL with the
-- port literal, while a browser on a non-default port always sends the
-- explicit port — so such handshakes would be rejected.
-- Security constraint: rewrite ONLY when the incoming Origin's host equals
-- the SiteURL's host (any or absent port). A different host (a cross-origin
-- drive-by: attacker page + the victim's auto-presented cert/cookie) is
-- passed through untouched, so Mattermost still rejects it with 403.
-- Source of truth: MATTERMOST_SITE_URL (declared via `env` in nginx.conf).
local function origin_host(url)
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
local function same_host(a, b)
    local ha = origin_host(a)
    local hb = origin_host(b)
    return ha ~= nil and hb ~= nil and ha:lower() == hb:lower()
end
local site_url = os.getenv("MATTERMOST_SITE_URL")
if ngx.var.uri == "/api/v4/websocket"
    and site_url
    and ngx.var.http_origin
    and same_host(site_url, ngx.var.http_origin) then
    ngx.req.clear_header("Origin")
    ngx.req.set_header("Origin", site_url)
end

local function inject_session(cookies, token)
    -- Stash the session for the cookie-hydration header filter (pure Lua):
    -- it turns the stored cookie string into the Set-Cookie headers that
    -- populate the browser's jar.
    ngx.ctx.mmssl = { cookie_string = cookies, token = token }
    return ssl:rewrite_request(cookies, token, cookies:match("MMCSRF=([^; ]+)"))
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
