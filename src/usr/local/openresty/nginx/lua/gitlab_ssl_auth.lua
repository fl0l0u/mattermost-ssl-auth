--[[
https://github.com/fl0l0u
]]
local GitlabSslAuth = {
    _VERSION = '0.1'
}

function GitlabSslAuth:new(webserver, webrunner, redis_uri, fqdn)
    local http = require "resty.http"
    local this = {
        webserver = webserver,
        webrunner = webrunner,
        httpc     = http:new(),
        redisc    = self:setup_redis(redis_uri),
        --
        username = nil,
        email    = nil,
        name     = nil,
        admin    = 'false'
    }
    self.__index = self
    setmetatable(this, self)
    this.username, this.email, this.name, this.admin = self:parse_fqdn(fqdn)
    return this
end

function GitlabSslAuth:parse_fqdn(fqdn)
    local username, email, name
    local admin = 'false'
    for k,v in string.gmatch(fqdn, "([^/, ]+)=([^/,]+)") do
        if k == "OU" and v == "Admins" then
            admin = 'true'
        end
        if ((k == "CN") and (not name)) then
            -- decode non-ascii character
            name = string.gsub(v, "\\(..)", function(s)
                return string.char(tonumber(s, 16))
            end)
        end
        if k == "emailAddress" then
            email = v
        end
    end
    if email then
        username = string.match(email, "([^@]+)@")
    else
        ngx.say("[lua] DN does not contain an emailAddress attribute")
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    if not name then
        ngx.say("[lua] DN does not contain a CN attribute")
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    if not username then
        ngx.say("[lua] failed to parse username")
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    return username, email, name, admin
end

function GitlabSslAuth:setup_redis(redis_uri)
    local redis = require "resty.redis"
    local red = redis:new()
    local ok, err = red:connect(redis_uri)
    if not ok then
        ngx.say("[lua][redis] failed to connect: ", err)
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    return red
end

function GitlabSslAuth:get_cookies()
    return self.redisc:get("x509auth:"..self.username..":cookies")
end

function GitlabSslAuth:get_password()
    return self.redisc:get("x509auth:"..self.username..":password")
end

function GitlabSslAuth:assert_user_doesn_exist()
    local ok, err, ssl_session = self.httpc:connect(self.webrunner)
    if not ok then
        ngx.say(ngx.ERR, "[lua][http] connection failed to agent: ", err)
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    local res, err = self.httpc:request({
        method = 'POST',
        path = '/check_user',
        body = ngx.encode_args({
            username     = self.username
        }),
        headers = {
            ["Host"]         = ngx.var.http_host,
            ["Content-Type"] = "application/x-www-form-urlencoded"
        }
    })
    if res then
        -- Check the agent was able to find the user, expect status 200 if found, 404 if not found
        if (res.status == 200) then
            ngx.say("[lua][http] agent reported the user already exist: ", res:read_body())
            return ngx.exit(ngx.HTTP_BAD_REQUEST)
        elseif (res.status == 404) then
            return
        else
            ngx.say("[lua][http] agent could not check if the user already exist: ", res:read_body())
            return ngx.exit(ngx.HTTP_BAD_REQUEST)
        end
    else
        ngx.say("[lua][http] failed to contact agent:", err)
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
end

function GitlabSslAuth:create_user()
    local ok, err, ssl_session = self.httpc:connect(self.webrunner)
    if not ok then
        ngx.say(ngx.ERR, "[lua][http] connection failed to agent: ", err)
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    local res, err = self.httpc:request({
        method = 'POST',
        path = '/create_user',
        body = ngx.encode_args({
            username     = self.username,
            display_name = self.name,
            email        = self.email,
            admin        = self.admin
        }),
        headers = {
            ["Host"]         = ngx.var.http_host,
            ["Content-Type"] = "application/x-www-form-urlencoded"
        }
    })
    local password, ok
    if res then
        -- Check the agent was able to create the user, expect status 200
        if not (res.status == 200) then
            ngx.say("[lua][http] agent reported failure to create user:", res:read_body())
            return ngx.exit(ngx.HTTP_BAD_REQUEST)
        end
        -- Cleaning up the password for future use (Gitlab is serializing data in Redis so we need to skip the extra header and footer)
        password, err = self.redisc:get("x509auth:"..self.username..":password")
        if password == ngx.null then
            ngx.say("[lua][redis] failed to retreive user password")
            return ngx.exit(ngx.HTTP_BAD_REQUEST)
        end
        password = string.sub(password, 6, -6)
        ok, err = self.redisc:set("x509auth:"..self.username..":password", password)
        if not ok then
            ngx.say("[lua][redis] failed to update user password: ", err)
            return ngx.exit(ngx.HTTP_BAD_REQUEST)
        end
    else
        ngx.say("[lua][http] failed to contact agent:", err)
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    return password
end

function GitlabSslAuth:http_get_token()
    -- Retrieving authenticity_token from webserver
    local ok, err, ssl_session = self.httpc:connect(self.webserver)
    if not ok then
        ngx.say(ngx.ERR, "[lua][http] connection failed to webserver: ", err)
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    local res, err = self.httpc:request({
        method = 'POST',
        path = '/users/sign_in',
        headers = {
            ["Host"]         = ngx.var.http_host
        }
    })
    if not res then
        ngx.say("[lua][http] failed to query login page: ", err)
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    if not (res.status == 200) then
        ngx.say("[lua][http] webserver response status:"..res.status..", aborting")
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    local authenticity_token = string.match(res:read_body(), "authenticity_token\"%svalue=\"([^\"]+)")
    if not authenticity_token then
        ngx.say("[lua][http] authenticity_token not found in webserver response, aborting")
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    local cookies = res.headers["Set-Cookie"]
    local cookie_header = ""
    for k,v in pairs(cookies) do
        cookie_header = cookie_header .. string.match(v, "^([^=; ]+=[^; ]+)") .. ";"
    end
    return authenticity_token, cookie_header
end

function GitlabSslAuth:http_sign_in(authenticity_token, cookie_header, password)
    local ok, err, ssl_session = self.httpc:connect(self.webserver)
    if not ok then
        ngx.say(ngx.ERR, "[lua][http] connection failed to webserver: ", err)
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    local res, err = self.httpc:request({
        method = "POST",
        path = '/users/sign_in',
        body = ngx.encode_args({
            authenticity_token = authenticity_token,
            ['user[login]']    = self.username,
            ['user[password]'] = password,
            remember_me        = 0
        }),
        headers = {
            ["Host"]         = ngx.var.http_host,
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Cookie"] = cookie_header
        }
    })
    if not res then
        ngx.say("[lua][http] failed to post login form: ", err)
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    -- Gitlab redirects on succesful authentication
    if not (res.status == 302) then
        -- Gitlab does not enforce password expiration, so no need to force password change... user may be blocked or disabled?
        ngx.say("[lua][http] webserver denied login for user")
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    return res.headers["Set-Cookie"]
end

function GitlabSslAuth:store_cookies(cookies)
    local session_cookie = false
    local cookie = ""
    if type(cookies) == "table" then
        for k,v in pairs(cookies) do
            local key, value = string.match(v, "^([^=; ]+)=([^; ]+)")
            if key == "_gitlab_session" then
                session_cookie = true
            end
            cookie = cookie .. key .. "=" .. value .. ";"
        end
    else
        local key, value = string.match(cookies, "^([^=; ]+)=([^; ]+)")
        if key == "_gitlab_session" then
            session_cookie = true
        end
        cookie = cookie .. key .. "=" .. value .. ";"
    end
    if not session_cookie then
        ngx.say("[lua][http] webserver did not return a session cookie")
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
    local ok, err = self.redisc:set("x509auth:"..self.username..":cookies", cookie)
    if not ok then
        ngx.say("[lua][redis] failed to store session cookies for user, ", err)
        return ngx.exit(ngx.HTTP_BAD_REQUEST)
    end
end

function GitlabSslAuth:create_session(username, password)
    -- Retrieving temporary session cookie and form token
    local authenticity_token, cookie_header = self:http_get_token()

    -- Performing authentication
    local cookies = self:http_sign_in(authenticity_token, cookie_header)

    -- 2.3.4. Store cookies for future use
    self:store_cookies(cookies)
end

return GitlabSslAuth