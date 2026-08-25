--[[
https://github.com/fl0l0u
]]
local http = require "resty.http"
local cjson = require "cjson"

local MattermostSslAuth = {
    _VERSION = '0.1'
}

-- Seed once per worker process; worker-unique enough for lock tokens, and
-- ngx.time works in any load context (including init).
math.randomseed(ngx.time() * 1000)

local LOCK_TTL_MS = 30000
local LOCK_WAIT_MS = 15000
local LOCK_POLL_MS = 200
local HTTP_TIMEOUT_MS = 5000
local LOGIN_MAX_ATTEMPTS = 3

local DEFAULT_UPSTREAM = "http://127.0.0.1:8065"
local DEFAULT_REDIS_URI = "unix:/run/redis/redis-server.sock"

local function env_or(name, default)
    local value = os.getenv(name)
    if value == nil or value == "" then
        return default
    end
    return value
end

local function env_bool(name, default)
    local value = os.getenv(name)
    if value == nil then
        return default
    end
    value = value:lower()
    return value == "true" or value == "1" or value == "yes"
end

local function decode_dn_escape(s)
    -- $ssl_client_s_dn is X509_NAME_oneline: comma-separated raw DN bytes in
    -- which high bytes are backslash-escaped. OpenSSL 1.x emits two hex
    -- digits ("Az\c3\A9"), OpenSSL 3.x emits "x" plus two hex digits
    -- ("Az\xC3\xA9"). The forms do not overlap ('x' is not a hex digit), so
    -- plain, quantifier-free gsubs decode both. The result is the raw
    -- (UTF-8) DN bytes; this covers, e.g., AD/ADCS certificates whose name
    -- fields arrive hex-escaped.
    s = (s:gsub("\\[xX]([%x%x][%x%x])", function(h)
        return string.char(tonumber(h, 16))
    end))
    return (s:gsub("\\([%x%x][%x%x])", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function parse_upstream(base)
    -- Strip one trailing "/" so "http://host:8065/" parses identically to
    -- "http://host:8065". Error messages echo the original value.
    local u = base:match("^(.*)/$") or base

    local scheme = u:match("^([%a][%a%d+%-.]*)://")
    if not scheme then
        return nil, nil, "invalid MATTERMOST_UPSTREAM: " .. base
    end
    if scheme == "https" then
        return nil, nil, "MATTERMOST_UPSTREAM must use http:// (TLS " ..
            "termination not supported by the gateway)"
    end
    if scheme ~= "http" then
        return nil, nil, "invalid MATTERMOST_UPSTREAM: " .. base
    end

    -- Patterns are matched separately (no alternation): plain host, then
    -- bracketed IPv6, each with an explicit port and a port-80 fallback.
    -- IPv6 addresses contain ':' (e.g. ::1), so the bracket body is hex
    -- digits plus colons.
    local host, port = u:match("^http://([^:/]+):([1-9][0-9]*)$")
    if not host then
        host, port = u:match("^http://[[]([%x:]+)%]:(%d+)$")
    end
    if not host then
        host, port = u:match("^http://([^:/]+)$"), 80
    end
    if not host then
        host, port = u:match("^http://[[]([%x:]+)%]$"), 80
    end
    if not host then
        return nil, nil, "invalid MATTERMOST_UPSTREAM: " .. base
    end

    return host, tonumber(port)
end

local function redis_connect(uri)
    local redis = require "resty.redis"
    local red = redis:new()
    red:set_timeout(1000)

    local ok, err
    if uri:sub(1, 7) == "unix://" then
        ok, err = red:connect("unix:" .. uri:sub(8))
    elseif uri:sub(1, 5) == "unix:" then
        ok, err = red:connect(uri)
    else
        local host, port = uri:match("^([^:]+):(%d+)$")
        if not host then
            return nil, "invalid REDIS_URI: " .. uri
        end
        ok, err = red:connect(host, port)
    end

    if not ok then
        return nil, tostring(err)
    end

    return red
end

local function session_key(email, what)
    return "x509auth:" .. email .. ":" .. what
end

local function lock_key(email)
    return session_key(email, "lock")
end

-- Release is a compare-and-delete: the lock is deleted only if it still
-- carries the releasing holder's token. A plain DEL would let a stalled
-- holder delete a lock that expired after 30 s and was re-acquired by
-- another request.
local LOCK_RELEASE = "if redis.call('get', KEYS[1]) == ARGV[1] then " ..
    "return redis.call('del', KEYS[1]) else return 0 end"

local function new_lock_owner()
    return ngx.now() .. "-" .. math.random(100000, 999999)
end

local function json_headers(token)
    return {
        ["Authorization"] = "Bearer " .. token,
        ["Content-Type"]  = "application/json",
        ["Accept"]        = "application/json",
    }
end

function MattermostSslAuth:new(fqdn)
    local upstream_host, upstream_port, upstream_err =
        parse_upstream(env_or("MATTERMOST_UPSTREAM", DEFAULT_UPSTREAM))
    if not upstream_host then
        self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, upstream_err)
    end

    -- An explicitly empty CERT_ADMIN_OU disables cert-driven admin, while an
    -- unset one falls back to the default.
    local admin_ou = os.getenv("CERT_ADMIN_OU")
    if admin_ou == nil then
        admin_ou = "Admins"
    end

    local red, err = redis_connect(env_or("REDIS_URI", DEFAULT_REDIS_URI))
    if not red then
        self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, "failed to connect to redis: " .. err)
    end

    local this = {
        upstream_host       = upstream_host,
        upstream_port       = upstream_port,
        redisc              = red,
        provision_token     = env_or("MATTERMOST_PROVISION_TOKEN", ""),
        allow_provision     = env_bool("ALLOW_PROVISION", false),
        default_team_id     = env_or("MM_DEFAULT_TEAM_ID", ""),
        email_field         = env_or("CERT_EMAIL_FIELD", "emailAddress"),
        name_field          = env_or("CERT_NAME_FIELD", "CN"),
        admin_ou            = admin_ou,
        username_from_email = env_bool("USERNAME_FROM_EMAIL", true),
        lock_owner          = nil,
    }
    self.__index = self
    setmetatable(this, self)

    if not fqdn or fqdn == "" then
        self:fail(ngx.HTTP_BAD_REQUEST, "DN header not found")
    end
    local parsed, dn_err = this:parse_dn(fqdn)
    if not parsed then
        self:fail(ngx.HTTP_BAD_REQUEST, dn_err)
    end
    this.email = parsed.email
    this.username = parsed.username
    this.name = parsed.name
    this.admin = parsed.admin
    return this
end

function MattermostSslAuth:parse_dn(fqdn)
    local values = {}
    -- OpenSSL's $ssl_client_s_dn format is comma-separated. This
    -- deliberately follows the same simple mapping strategy as
    -- gitlab-ssl-auth; for certificates with escaped commas or more complex
    -- DNs, replace this parser with a proper X.509 parser.
    for k, v in string.gmatch(fqdn, "([^=,/ ]+)=([^,/]*)") do
        if values[k] == nil then
            values[k] = decode_dn_escape(v)
        end
    end

    local email = values[self.email_field]
    local name = values[self.name_field]

    if not email or email == "" then
        return nil, "DN does not contain an " .. self.email_field .. " attribute"
    end
    if not email:find("@") then
        return nil, "certificate " .. self.email_field .. " is not an email address: " .. email
    end
    email = string.lower(email)

    if not name or name == "" then
        return nil, "DN does not contain a " .. self.name_field .. " attribute"
    end

    local username
    if self.username_from_email then
        username = string.match(email, "([^@]+)@") or email
    else
        username = email
    end
    if not username or username == "" then
        return nil, "failed to parse username from " .. email
    end

    -- Cert-driven admin: an RDN whose key equals CERT_ADMIN_OU and whose
    -- value is "TRUE" (case-insensitive) marks the user as an admin when the
    -- gateway auto-provisions. An explicit empty CERT_ADMIN_OU disables the
    -- feature.
    local admin = false
    if self.admin_ou ~= "" then
        local marker = values[self.admin_ou]
        if marker and marker:upper() == "TRUE" then
            admin = true
        end
    end

    return {
        email = email,
        username = username,
        name = name,
        admin = admin,
    }
end

function MattermostSslAuth:get_cookies()
    return self:redis_get(session_key(self.email, "cookies"))
end

function MattermostSslAuth:get_token()
    return self:redis_get(session_key(self.email, "token"))
end

function MattermostSslAuth:get_password()
    return self:redis_get(session_key(self.email, "password"))
end

-- Redis replies are normalized at this boundary: ngx.null, nil and "" all
-- mean "no value", so the rest of the code only ever sees nil or a string.
function MattermostSslAuth:redis_get(key)
    local value, err = self.redisc:get(key)
    if not value then
        self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, "redis GET failed: " .. tostring(err))
    end
    if value == ngx.null or value == "" then
        return nil
    end
    return value
end

-- Session values are persistent (no TTL): the cached password must outlive
-- the session it belongs to.
function MattermostSslAuth:redis_set(key, value)
    local ok, err = self.redisc:set(key, value)
    if not ok then
        self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, "redis SET failed: " .. tostring(err))
    end
end

function MattermostSslAuth:store_cookies(cookies)
    self:redis_set(session_key(self.email, "cookies"), cookies)
end

function MattermostSslAuth:store_token(token)
    self:redis_set(session_key(self.email, "token"), token)
end

function MattermostSslAuth:store_password(password)
    self:redis_set(session_key(self.email, "password"), password)
end

-- Drops the session (cookies + token) but keeps the cached password, so the
-- next request re-logs in instead of re-provisioning.
function MattermostSslAuth:del_session()
    local ok, err = self.redisc:del(
        session_key(self.email, "cookies"),
        session_key(self.email, "token")
    )
    if not ok then
        self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, "redis DEL failed: " .. tostring(err))
    end
end

-- Serializes the first login/provisioning per email. A concurrent request
-- for the same user waits instead of double-provisioning.
function MattermostSslAuth:acquire_lock(email)
    local owner = new_lock_owner()
    local ok, err = self.redisc:set(lock_key(email), owner, "PX", LOCK_TTL_MS, "NX")
    if err then
        self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, "failed to acquire session lock: " .. tostring(err))
    end
    -- lua-resty-redis returns "OK" on success and ngx.null on a SET NX
    -- conflict.
    if ok == "OK" then
        self.lock_owner = owner
        return true
    end
    return false
end

function MattermostSslAuth:wait_for_session(email)
    local waited = 0
    while waited < LOCK_WAIT_MS do
        ngx.sleep(LOCK_POLL_MS / 1000)
        waited = waited + LOCK_POLL_MS

        -- Fast path: the holder published a session while we waited.
        if self:get_cookies() then
            return true
        end

        -- The holder may have released the lock or let it expire (30 s TTL)
        -- without publishing a session. Retry the NX set on every poll so
        -- the waiter proceeds instead of burning the full wait window; the
        -- re-acquired lock carries the waiter's own owner for its release.
        local owner = new_lock_owner()
        local ok, err = self.redisc:set(lock_key(email), owner, "PX", LOCK_TTL_MS, "NX")
        if err then
            self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, "failed to re-acquire session lock while waiting: " .. tostring(err))
        end
        if ok == "OK" then
            self.lock_owner = owner
            return true
        end
    end
    return false
end

-- No-op when we do not hold the lock (e.g. the wait ended in the fast
-- path). Best effort: a failed release is harmless, the 30 s TTL reclaims a
-- stale lock.
function MattermostSslAuth:release_lock(email)
    if not self.lock_owner then
        return
    end
    self.redisc:eval(LOCK_RELEASE, 1, lock_key(email), self.lock_owner)
    self.lock_owner = nil
end

function MattermostSslAuth:random_password()
    local f = io.open("/dev/urandom", "rb")
    if not f then
        self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, "cannot open /dev/urandom")
    end
    local first, second = f:read(16), f:read(16)
    f:close()
    if not first or not second then
        self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, "failed to read 32 bytes from /dev/urandom")
    end
    return ngx.encode_base64(first .. second, true)
end

-- One fresh client per request: a lua-resty-http client holds a single
-- connection, and a fresh client per call keeps every failure local.
function MattermostSslAuth:api_request(method, path, body, headers)
    local c = http:new()
    c:set_timeout(HTTP_TIMEOUT_MS)
    local ok, err = c:connect(self.upstream_host, self.upstream_port)
    if not ok then
        return nil, "connection failed to Mattermost: " .. tostring(err)
    end
    local opts = {
        method = method,
        path = path,
        headers = headers,
    }
    if body then
        opts.body = body
    end
    local res, err = c:request(opts)
    if not res then
        return nil, "request to Mattermost failed: " .. tostring(err)
    end
    return res
end

-- Returns the user table, nil when the user does not exist, or nil plus an
-- error message on any other outcome. A missing token is indistinguishable
-- from "absent" to the caller; resolve_password() checks for it first.
function MattermostSslAuth:lookup_user()
    if not self.provision_token then
        return nil
    end
    local path = "/api/v4/users/email/" .. ngx.escape_uri(self.email)
    local res, err = self:api_request("GET", path, nil, json_headers(self.provision_token))
    if not res then
        return nil, err
    end
    local body = res:read_body()
    if res.status == 200 then
        local ok, user = pcall(cjson.decode, body)
        if not ok then
            return nil, "failed to decode user lookup response: " .. body
        end
        return user
    end
    if res.status == 404 then
        return nil
    end
    return nil, "user lookup failed with HTTP " .. res.status .. ": " .. body
end

-- Idempotent post-creation fixes: grant the admin role when the cert says
-- so, and add the user to the default team. Called from create_user() and
-- from self_heal_password(), which is what keeps a manually altered account
-- converging back to the provisioned state.
function MattermostSslAuth:apply_provisioning(user_id)
    if self.admin then
        local res, err = self:api_request(
            "PUT",
            "/api/v4/users/" .. ngx.escape_uri(user_id) .. "/roles",
            cjson.encode({ roles = "system_user system_admin" }),
            json_headers(self.provision_token)
        )
        if not res then
            return nil, err
        end
        local body = res:read_body()
        if res.status ~= 200 then
            return nil, "failed to assign admin roles (HTTP " .. res.status .. "): " .. body
        end
    end

    if self.default_team_id ~= "" then
        local res, err = self:api_request(
            "POST",
            "/api/v4/teams/" .. ngx.escape_uri(self.default_team_id) .. "/members",
            cjson.encode({
                team_id = self.default_team_id,
                user_id = user_id,
            }),
            json_headers(self.provision_token)
        )
        if not res then
            return nil, err
        end
        local body = res:read_body()
        if res.status == 200 or res.status == 201 then
            return true
        end
        -- Mattermost answers 400 when the user is already a team member.
        if res.status == 400 and string.find(body, "already", 1, true) then
            return true
        end
        return nil, "failed to add user to team (HTTP " .. res.status .. "): " .. body
    end

    return true
end

-- Creates the user, applies provisioning, and caches the password only if
-- every step succeeded, so a failed creation never leaves a password
-- pointing at a missing or half-provisioned account.
function MattermostSslAuth:create_user(password)
    if not self.provision_token then
        return nil, "MATTERMOST_PROVISION_TOKEN is not configured"
    end

    -- Split the cert CN on the first space into first/last name.
    local first_name, last_name = string.match(self.name, "^(%S+)%s+(.*)$")
    if not first_name then
        first_name, last_name = self.name, ""
    end

    local res, err = self:api_request(
        "POST",
        "/api/v4/users",
        cjson.encode({
            username = self.username,
            email = self.email,
            password = password,
            first_name = first_name,
            last_name = last_name,
            email_verified = true,
        }),
        json_headers(self.provision_token)
    )
    if not res then
        return nil, err
    end
    local body = res:read_body()
    if res.status ~= 200 and res.status ~= 201 then
        return nil, "user creation failed with HTTP " .. res.status .. ": " .. body
    end
    local ok, user = pcall(cjson.decode, body)
    if not ok then
        return nil, "failed to decode user creation response: " .. body
    end
    local done, prov_err = self:apply_provisioning(user.id)
    if not done then
        return nil, prov_err
    end
    self:store_password(password)
    return user
end

-- Rotates the user's password (the cached one no longer logs in) and
-- re-asserts the provisioned state. The new password is cached only after
-- the rotation and the provisioning both succeeded.
function MattermostSslAuth:self_heal_password(user_id)
    if not self.provision_token then
        return nil, "MATTERMOST_PROVISION_TOKEN is not configured"
    end
    local new_password = self:random_password()
    local res, err = self:api_request(
        "PUT",
        "/api/v4/users/" .. ngx.escape_uri(user_id) .. "/password",
        cjson.encode({ new_password = new_password }),
        json_headers(self.provision_token)
    )
    if not res then
        return nil, err
    end
    local body = res:read_body()
    if res.status ~= 200 then
        return nil, "failed to rotate user password (HTTP " .. res.status .. "): " .. body
    end
    local done, prov_err = self:apply_provisioning(user_id)
    if not done then
        return nil, prov_err
    end
    self:store_password(new_password)
    return new_password
end

-- Logs in against the Mattermost API. Returns the session cookie string
-- ("MMAUTHTOKEN=..; MMUSERID=..; MMCSRF=..", skipping absent cookies) and
-- the Bearer token, or nil plus an error message.
function MattermostSslAuth:http_login(password, cookies, csrf)
    local host = ngx.var.http_host
    local headers = {
        ["Host"]              = host,
        ["Content-Type"]      = "application/json",
        ["Accept"]            = "application/json",
        ["Origin"]            = "https://" .. host,
        ["X-Requested-With"]  = "XMLHttpRequest",
        ["X-Forwarded-Proto"] = "https",
        ["X-Forwarded-Ssl"]   = "on",
    }
    if cookies and cookies ~= "" then
        headers["Cookie"] = cookies
    end
    if csrf and csrf ~= "" then
        headers["X-CSRF-Token"] = csrf
    end

    local body = cjson.encode({
        login_id = self.email,
        password = password,
    })

    local attempt = 0
    local res, err
    while true do
        attempt = attempt + 1
        res, err = self:api_request("POST", "/api/v4/users/login", body, headers)
        if not res then
            return nil, "login request failed: " .. tostring(err)
        end
        if res.status ~= 429 or attempt >= LOGIN_MAX_ATTEMPTS then
            break
        end
        -- Rate limited; back off before retrying.
        ngx.sleep(0.5 + math.random())
    end

    local response_body = res:read_body()
    if res.status ~= 200 then
        return nil, "login failed with HTTP " .. res.status .. ": " .. response_body
    end

    local token = res.headers["Token"]
    if not token or token == "" then
        return nil, "login succeeded but no Token header was returned"
    end

    local session = {}
    local set_cookies = res.headers["Set-Cookie"]
    if type(set_cookies) == "table" then
        for _, cookie in ipairs(set_cookies) do
            local name, value = string.match(cookie, "^([^=; ]+)=([^; ]+)")
            if name and session[name] == nil then
                session[name] = name .. "=" .. value
            end
        end
    end
    if not session["MMAUTHTOKEN"] then
        return nil, "login succeeded but no MMAUTHTOKEN cookie was returned"
    end

    local parts = {}
    for _, name in ipairs({ "MMAUTHTOKEN", "MMUSERID", "MMCSRF" }) do
        if session[name] then
            parts[#parts + 1] = session[name]
        end
    end
    return table.concat(parts, "; "), token
end

-- Resolves a password that is known to log in: validates the cached one, or
-- repairs/provisions the account until a fresh, verified password exists.
-- Owns the per-email session lock for the duration (the caller re-logs in
-- with the returned password and stores the resulting session).
function MattermostSslAuth:resolve_password()
    -- Fast path: a session already exists, so no locking or provisioning is
    -- needed; the hook re-logs in with the cached password.
    if self:get_cookies() then
        return self:get_password()
    end

    if not self:acquire_lock(self.email) then
        if not self:wait_for_session(self.email) then
            self:fail(ngx.HTTP_GATEWAY_TIMEOUT, "timed out waiting for another request to establish a session")
        end
        if self:get_cookies() then
            -- The session appeared while we waited; release our lock if the
            -- wait ended in a re-acquisition.
            self:release_lock(self.email)
            return self:get_password()
        end
        -- Otherwise we re-acquired the lock and no session exists yet: fall
        -- through to the critical section below.
    end

    local password = self:resolve_password_locked()
    self:release_lock(self.email)
    return password
end

-- Critical section of resolve_password(); the session lock is held.
function MattermostSslAuth:resolve_password_locked()
    local password = self:get_password()
    if password then
        local ok, err = self:http_login(password, nil, nil)
        if ok then
            return password
        end
        ngx.log(ngx.ERR, "[lua][http] login with cached password failed: " .. tostring(err))
        password = self:repair_password("user deleted and provisioning disabled")
        ok, err = self:http_login(password, nil, nil)
        if not ok then
            self:fail(ngx.HTTP_BAD_REQUEST, "login failed after password repair: " .. tostring(err))
        end
        return password
    end

    if not self.provision_token then
        self:fail(ngx.HTTP_BAD_GATEWAY, "no cached password and no provision token")
    end

    return self:repair_password("user not provisioned and ALLOW_PROVISION is false")
end

-- Looks the user up and returns a fresh password for it: rotates the
-- password when the account exists, provisions it when it does not.
-- missing_user_msg is the failure message for the no-account, no-provision
-- case, which differs between the two call sites.
function MattermostSslAuth:repair_password(missing_user_msg)
    local user, err = self:lookup_user()
    if err then
        self:fail(ngx.HTTP_BAD_GATEWAY, "user lookup failed: " .. err)
    end
    if user then
        local password, heal_err = self:self_heal_password(user.id)
        if not password then
            self:fail(ngx.HTTP_BAD_GATEWAY, "failed to rotate user password: " .. tostring(heal_err))
        end
        return password
    end
    if not self.allow_provision then
        self:fail(ngx.HTTP_BAD_GATEWAY, missing_user_msg)
    end
    local password, create_err = self:create_user(self:random_password())
    if not password then
        self:fail(ngx.HTTP_BAD_GATEWAY, "failed to provision user: " .. tostring(create_err))
    end
    return password
end

-- Rebuilds the Cookie header of the proxied request: stored values win per
-- name, other client pairs are forwarded, and stored pairs the client did
-- not send are appended. X-CSRF-Token and Authorization are always
-- rewritten from the stored session so a stale client header cannot break
-- the login.
function MattermostSslAuth:rewrite_request(cookies_string, token, mmcsrf)
    local stored = {}
    for k, v in string.gmatch(cookies_string, "([^=; ]+)=([^=; ]+)") do
        stored[k] = v
    end

    local cookie_header = ""
    local request_cookies = ngx.req.get_headers()["Cookie"]
    if request_cookies then
        for k, v in string.gmatch(request_cookies, "([^=; ]+)=([^=; ]+)") do
            cookie_header = cookie_header .. k .. "=" .. (stored[k] or v) .. ";"
            stored[k] = nil
        end
    end
    for k, v in pairs(stored) do
        cookie_header = cookie_header .. k .. "=" .. v .. ";"
    end

    if cookie_header == "" then
        ngx.req.clear_header("Cookie")
    else
        ngx.req.set_header("Cookie", cookie_header)
    end

    if mmcsrf and mmcsrf ~= "" then
        ngx.req.set_header("X-CSRF-Token", mmcsrf)
    else
        ngx.req.clear_header("X-CSRF-Token")
    end

    if token and token ~= "" then
        ngx.req.set_header("Authorization", "Bearer " .. token)
    else
        ngx.req.clear_header("Authorization")
    end
end

function MattermostSslAuth:fail(status, msg)
    ngx.log(ngx.ERR, "[lua] ", msg)
    ngx.say("[lua] ", msg)
    ngx.exit(status)
end

return MattermostSslAuth
