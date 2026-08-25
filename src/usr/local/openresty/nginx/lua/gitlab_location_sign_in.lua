-- REQUEST -> access_by_lua_file
-- 1. INIT
-- 1.1. the gitlab backend to contact for authentication
local webserver = ngx.var.gitlab_workhorse
if not webserver then
    ngx.say("[lua] Nginx variable 'gitlab_workhorse' not set")
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end
-- 1.2. the gitlab agent to contact to provision users (daemon: gitlab-rails runner 'load("/opt/gitlab/runner.rb")')
local webrunner = ngx.var.gitlab_agent
if not webrunner then
    ngx.say("[lua] Nginx variable 'gitlab_agent' not set")
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end
-- 1.3. the redis server to synchronize passwords and cookies
local redis_uri = ngx.var.redis_uri
if not redis_uri then
    ngx.say("[lua] Nginx variable 'redis_uri' not set")
    ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end
-- 1.4. Parsing attributes of DN header, expecting at least a CN and an emailAddress
local client_dn = ngx.var.ssl_client_s_dn
if not client_dn then
    ngx.say("[lua] DN header not found")
    ngx.exit(ngx.HTTP_BAD_REQUEST)
end
-- 1.5. Agent
local gitlab_ssl_auth = require("gitlab_ssl_auth")
local agent = gitlab_ssl_auth:new(webserver, webrunner, redis_uri, client_dn)

-- 2. RENEW CACHED SESSION
agent.redisc:del("frp:cookies:"..agent.username)

-- 2.1. AUTH USER
local authenticity_token, cookie_header = agent:http_get_token()
local password = agent:get_password()
local cookies = agent:http_sign_in(authenticity_token, cookie_header, password)

-- 2.2. CACHE SESSION
agent:store_cookies(cookies)

-- 3. REDIRECT BACK
if ngx.header.Referer then
    if string.match(ngx.header.Referer, "^https://[^/]+/users/sign_in$") then
        return ngx.redirect('/')
    else
        return ngx.redirect(ngx.header.Referer)
    end
else
    return ngx.redirect('/')
end
