--[[
https://github.com/fl0l0u
]]
local http = require "resty.http"
local cjson = require "cjson"

local MattermostSslAuth = {
    _VERSION = '0.1'
}

-- Seed once per worker process (the module loads on the worker's first
-- request, so this runs in worker context). The worker id is mixed in so
-- workers that start in the same instant get different RNG streams, and
-- ngx.now()'s sub-second part spreads the initial sequences further.
math.randomseed(ngx.now() * 1000 + ngx.worker.id())

local LOCK_TTL_MS = 60000
local LOCK_WAIT_MS = 15000
local LOCK_POLL_MS = 200
local HTTP_TIMEOUT_MS = 5000
local LOGIN_MAX_ATTEMPTS = 3
local REPLAY_CONNECT_TIMEOUT_MS = 10000
local REPLAY_TRANSFER_TIMEOUT_MS = 60000

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
        -- Accept the documented "redis://host:port" form as well as a bare
        -- "host:port"; the scheme is stripped before the host:port match.
        local bare = uri:match("^redis://(.+)$") or uri
        local host, port = bare:match("^([^:]+):(%d+)$")
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
-- holder delete a lock that expired after 60 s and was re-acquired by
-- another request.
local LOCK_RELEASE = "if redis.call('get', KEYS[1]) == ARGV[1] then " ..
    "return redis.call('del', KEYS[1]) else return 0 end"

local function new_lock_owner()
    -- Worker id + sub-second timestamp + RNG: collision-resistant across
    -- workers even when they load in the same instant.
    return ngx.worker.id() .. "-" .. ngx.now() .. "-" .. math.random(100000, 999999)
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

    -- The Origin the login is presented from. Empty (the default) keeps
    -- the historical behavior of synthesizing "https://<host>"; set it to
    -- the Mattermost SiteURL when the browser-facing URL differs from the
    -- Host header the request arrives with.
    local site_url = env_or("MATTERMOST_SITE_URL", "")

    local max_age_raw = env_or("SESSION_MAX_AGE_HOURS", "20")
    local max_age_hours = tonumber(max_age_raw)
    if not max_age_hours or max_age_hours < 0 then
        self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR,
            "SESSION_MAX_AGE_HOURS must be a non-negative number of hours: " .. max_age_raw)
    end

    local this = {
        upstream_host       = upstream_host,
        upstream_port       = upstream_port,
        redisc              = red,
        site_url            = site_url,
        session_max_age_s   = max_age_hours * 3600,
        soft_fail           = false,
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

    -- Cert-driven admin: the OU value equal to CERT_ADMIN_OU (default
    -- "Admins") marks the user as an admin when the gateway
    -- auto-provisions. An explicit empty CERT_ADMIN_OU disables the
    -- feature.
    local admin = (self.admin_ou ~= "" and values["OU"] == self.admin_ou) or false

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

-- The stored session's age marker (epoch seconds), or nil when absent or
-- unparseable — a session with no readable marker counts as age-unknown.
function MattermostSslAuth:get_since()
    local value = self:redis_get(session_key(self.email, "since"))
    return value and tonumber(value)
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

-- Epoch seconds (string) when this session was established.
function MattermostSslAuth:store_since(t)
    self:redis_set(session_key(self.email, "since"), tostring(t or ngx.now()))
end

-- The password is only valid once the account has been provisioned or
-- rotated under the session lock, so storing it requires still holding that
-- lock: check_lock() aborts a holder whose lock expired mid-section.
function MattermostSslAuth:store_password(password)
    self:check_lock()
    self:redis_set(session_key(self.email, "password"), password)
end

-- Drops the session (cookies + token + age marker) but keeps the cached
-- password, so the next request re-logs in instead of re-provisioning.
function MattermostSslAuth:del_session()
    local ok, err = self.redisc:del(
        session_key(self.email, "cookies"),
        session_key(self.email, "token"),
        session_key(self.email, "since")
    )
    if not ok then
        self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, "redis DEL failed: " .. tostring(err))
    end
end

-- Serializes the first login/provisioning per email. A concurrent request
-- for the same user waits instead of double-provisioning.
-- Re-entrant: a renewal holds this lock and runs a critical section that
-- acquires it again (resolve_password); without this a holder would
-- SET NX its own key, lose, and wait itself out into a 504.
function MattermostSslAuth:acquire_lock(email)
    if self.lock_owner then
        local value, err = self.redisc:get(lock_key(email))
        if err then
            self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, "failed to verify session lock: " .. tostring(err))
        end
        if value == self.lock_owner then
            return true
        end
    end
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

        -- The holder may have released the lock or let it expire (60 s TTL)
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
-- path). Best effort: a failed release is harmless, the 60 s TTL reclaims a
-- stale lock. The lock is always keyed by self.email — the only email this
-- instance ever locks — so the parameter is gone.
function MattermostSslAuth:release_lock()
    if not self.lock_owner then
        return
    end
    self.redisc:eval(LOCK_RELEASE, 1, lock_key(self.email), self.lock_owner)
    self.lock_owner = nil
end

-- Re-verify that we still hold the session lock. A critical section that
-- outlives the lock TTL loses it: another request can then re-acquire the
-- lock and commit its own state. Call this right before committing state
-- (store_password) so a stale holder aborts instead of overwriting a newer
-- holder's work.
function MattermostSslAuth:check_lock()
    if not self.lock_owner then
        self:fail(ngx.HTTP_SERVICE_UNAVAILABLE, "session lock expired, retry")
    end
    local value, err = self.redisc:get(lock_key(self.email))
    if err then
        self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, "redis GET failed: " .. tostring(err))
    end
    if value ~= self.lock_owner then
        self:fail(ngx.HTTP_SERVICE_UNAVAILABLE, "session lock expired, retry")
    end
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

-- Creates the user, applies provisioning, caches the password, and
-- returns it — only if every step succeeded, so a failed creation never
-- leaves a password pointing at a missing or half-provisioned account.
-- The caller logs in with the returned password to establish the session.
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
    if res.status == 409 then
        return nil, "username '" .. self.username ..
            "' is already taken by another account; use a unique email local-part"
    end
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
    return password
end

-- Rotates the user's password (the cached one no longer logs in) and
-- re-asserts the provisioned state. A soft-deleted account is reactivated
-- first: Mattermost's DELETE deactivates instead of removing, and a
-- deactivated account can never log in, so rotation alone would not
-- converge. The new password is cached only after everything succeeded.
function MattermostSslAuth:self_heal_password(user)
    if not self.provision_token then
        return nil, "MATTERMOST_PROVISION_TOKEN is not configured"
    end
    local user_id = user.id

    if user.delete_at and user.delete_at ~= 0 then
        local res, err = self:api_request(
            "PUT",
            "/api/v4/users/" .. ngx.escape_uri(user_id) .. "/active",
            cjson.encode({ active = true }),
            json_headers(self.provision_token)
        )
        if not res then
            return nil, err
        end
        local body = res:read_body()
        if res.status ~= 200 then
            return nil, "failed to reactivate user (HTTP " .. res.status .. "): " .. body
        end
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
    -- MATTERMOST_SITE_URL lets the login be presented from the URL the
    -- browser sees; empty (default) synthesizes the Origin from Host.
    local origin
    if self.site_url ~= "" then
        origin = self.site_url
    else
        origin = "https://" .. host
    end
    local headers = {
        ["Host"]              = host,
        ["Content-Type"]      = "application/json",
        ["Accept"]            = "application/json",
        ["Origin"]            = origin,
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
    -- lua-resty-http returns a single Set-Cookie header as a string and
    -- multiple ones as a table; normalize a string to a one-element list.
    if type(set_cookies) == "string" then
        set_cookies = { set_cookies }
    end
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
            self:release_lock()
            return self:get_password()
        end
        -- Otherwise we re-acquired the lock and no session exists yet: fall
        -- through to the critical section below.
    end

    local password = self:resolve_password_locked()
    self:release_lock()
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
        local password, heal_err = self:self_heal_password(user)
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

-- The shared login critical section, used by both hooks and by session
-- renewal: drop the stale session, resolve a password that is known to
-- log in (the agent owns the per-email session lock for the duration),
-- log in with the given stale cookies/CSRF (nil for a clean login), and
-- store the fresh session including its age marker. Returns the stored
-- (cookies, token). Every failure exits the request with the hook
-- conventions (400 on login, 5xx on infrastructure).
function MattermostSslAuth:establish_session(login_cookies, login_csrf)
    self:del_session()
    local password = self:resolve_password()
    if not password then
        -- A peer published the session while we waited; use it.
        local stored = self:get_cookies()
        if not stored then
            self:fail(ngx.HTTP_INTERNAL_SERVER_ERROR, "no password resolved for session")
        end
        return stored, self:get_token()
    end
    local cookies, token = self:http_login(password, login_cookies, login_csrf)
    if not cookies then
        -- The second http_login return value doubles as the error message.
        self:fail(ngx.HTTP_BAD_REQUEST, token)
    end
    self:store_cookies(cookies)
    self:store_token(token)
    self:store_since()
    return cookies, token
end

-- Runs the renewal critical section so that a failure degrades instead
-- of terminating the request: for its duration fail() raises a catchable
-- Lua error (soft_fail) that this pcall swallows, so a broken renewal
-- still lets the request proceed (serve the stored session, or pass a
-- 401 through). Returns true + (cookies, token), or false + err.
function MattermostSslAuth:try_establish(login_cookies, login_csrf)
    self.soft_fail = true
    local ok, first, second = pcall(self.establish_session, self, login_cookies, login_csrf)
    self.soft_fail = false
    if not ok then
        return false, first
    end
    return true, first, second
end

-- A session is fresh while its age marker is within
-- SESSION_MAX_AGE_HOURS. A missing or unparseable marker counts as stale:
-- an age-unknown session is renewed rather than served.
function MattermostSslAuth:is_session_fresh()
    local since = self:get_since()
    return since ~= nil and ngx.now() - since <= self.session_max_age_s
end

-- Proactive session renewal: re-login before the stored session can die,
-- so the SPA never has to. Returns one of:
--   "miss"     no stored session; the caller does the normal cold path.
--   "fresh"    the stored session is within the renewal age; serve it.
--   "renewed"  a fresh session was just established; serve the stored
--              values.
--   "degraded" renewal failed: the pre-renewal session is restored and
--              served as-is (the 401 intercept gets another chance on
--              the next request).
function MattermostSslAuth:maybe_renew_session()
    local cookies = self:get_cookies()
    if not cookies then
        return "miss"
    end
    if self:is_session_fresh() then
        return "fresh"
    end

    -- Stale or age-unknown. Serialize the renewal per email: only the
    -- lock holder re-logs in, the others wait and reuse the result.
    if not self:acquire_lock(self.email) then
        if not self:wait_for_session(self.email) then
            self:fail(ngx.HTTP_GATEWAY_TIMEOUT, "timed out waiting for session renewal")
        end
    end
    -- Re-check under the lock: a peer may have renewed while we waited.
    if self:is_session_fresh() then
        self:release_lock()
        return "fresh"
    end

    -- Snapshot what is about to be replaced, for the degraded path.
    local token = self:get_token()
    local since = self:get_since()
    local ok, err = self:try_establish()
    self:release_lock()
    if not ok then
        ngx.log(ngx.WARN,
            "[lua] session renewal failed, serving existing session: " .. tostring(err))
        -- The critical section deleted the stale session before failing;
        -- put it back so the caller still has something to serve. A peer
        -- that renewed in the meantime republished first and wins.
        if not self:get_cookies() then
            self:store_cookies(cookies)
            self:store_token(token)
            if since then
                self:store_since(since)
            end
        end
        return "degraded"
    end
    return "renewed"
end

-- Reactive renewal for a request whose upstream response was just 401:
-- the stored session is dead, re-establish it. A peer that renewed
-- after our 401 (age marker >= the 401 moment) makes a replay with the
-- stored session valid, which is the fast skip. Returns true (renewed,
-- or already fresh by a peer), or nil + err — never terminates the
-- request: the 401 must pass through to the client unchanged.
function MattermostSslAuth:renew_for_401()
    local t401 = ngx.now()
    local since = self:get_since()
    if since and since >= t401 then
        return true
    end
    if not self:acquire_lock(self.email) then
        if not self:wait_for_session(self.email) then
            return nil, "timed out waiting for session renewal"
        end
    end
    since = self:get_since()
    if since and since >= t401 then
        self:release_lock()
        return true
    end
    local ok, err = self:try_establish()
    self:release_lock()
    if not ok then
        return nil, err
    end
    return true
end

-- Sends the client's request to the configured upstream for the 401
-- intercept: a plain replay with renewed headers. `uri` is the request
-- target as received (path plus query string), `method` uppercase,
-- `body` may be nil. Timeouts: 10 s connect, 60 s send/receive. Returns
-- status, headers, body, or nil, nil, nil, err on a transport failure.
function MattermostSslAuth:replay_request(new_headers, method, uri, body)
    local c = http:new()
    c:set_timeouts(REPLAY_CONNECT_TIMEOUT_MS, REPLAY_TRANSFER_TIMEOUT_MS, REPLAY_TRANSFER_TIMEOUT_MS)
    local ok, err = c:connect(self.upstream_host, self.upstream_port)
    if not ok then
        return nil, nil, nil, "replay connect failed: " .. tostring(err)
    end
    local opts = {
        method = method,
        path = uri,
        headers = new_headers,
    }
    if body and body ~= "" then
        opts.body = body
    end
    local res, req_err = c:request(opts)
    if not res then
        return nil, nil, nil, "replay request failed: " .. tostring(req_err)
    end
    local response_body = res:read_body()
    return res.status, res.headers, response_body
end

-- The full outbound header set for a replay: rewrite_request() re-applied
-- first with the freshly stored session (the access phase ran with the
-- old values), then the current request's headers, plus the fixed
-- overrides the config's proxy_set_header lines apply. Host is dropped
-- too: the replay client sets it from the connect target. Returns the
-- header table (lowercase keys), or nil + err when there is no stored
-- session to rewrite from.
--
-- The websocket location reuses this snapshot: upgrade and
-- sec-websocket-* are deliberately kept (the handshake replay needs
-- them); connection framing is re-negotiated by the fresh connection,
-- and the replay client recomputes Content-Length from the body it
-- sends.
function MattermostSslAuth:snapshot_outbound_headers()
    local cookies = self:get_cookies()
    if not cookies then
        return nil, "no stored session to rewrite"
    end
    local token = self:get_token()
    self:rewrite_request(cookies, token, cookies:match("MMCSRF=([^=; ]+)"))

    local headers = ngx.req.get_headers(true)
    local remote_addr = ngx.var.remote_addr
    headers["x-real-ip"] = remote_addr
    headers["x-forwarded-for"] = remote_addr
    headers["x-forwarded-proto"] = "https"
    headers["x-forwarded-ssl"] = "on"
    for _, name in ipairs({ "connection", "proxy-connection", "keep-alive",
                            "transfer-encoding", "content-length", "host" }) do
        headers[name] = nil
    end
    return headers
end

-- The current request's body, for a replay: browsers send small XHR
-- bodies that nginx keeps in memory; the file read covers the rare
-- buffered-to-disk one. Returns the body string, or nil when the
-- request has none.
function MattermostSslAuth:read_request_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        local file = ngx.req.get_body_file()
        if not file then
            return nil
        end
        local f = io.open(file, "rb")
        if not f then
            return nil
        end
        body = f:read("*a")
        f:close()
    end
    return body
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
    if type(request_cookies) == "table" then
        -- A client may send several Cookie headers; nginx returns them as a
        -- table, so rejoin into one header before merging.
        request_cookies = table.concat(request_cookies, "; ")
    end
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
    -- Release the session lock before terminating: ngx.exit kills the
    -- request, so without this a failure inside the critical section would
    -- leave the 60 s lock behind and every waiter for the same email would
    -- burn its 15 s wait window and time out with 504.
    self:release_lock()
    ngx.log(ngx.ERR, "[lua] ", msg)
    if self.soft_fail then
        -- A renewal path runs under pcall (try_establish): raise a
        -- catchable Lua error instead of terminating the request, so the
        -- failed renewal degrades (serve the stored session, let a 401
        -- pass through) instead of killing it.
        error("[lua] " .. tostring(msg or "unknown error"), 0)
    end
    -- ngx.status must be set before ngx.say: the first say starts the
    -- response with whatever status is currently in effect (200 by
    -- default), so a say-then-exit order would serve every failure as 200.
    ngx.status = status
    ngx.say("[lua] ", msg or "unknown error")
    ngx.exit(status)
end

return MattermostSslAuth
