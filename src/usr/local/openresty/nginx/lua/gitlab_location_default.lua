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

-- 2. FETCH SESSION
-- 2.1. FETCH SAVED SESSION
local cookies = agent:get_cookies()

-- 2.2. CREATE NEW SESSION
if cookies == ngx.null then
-- 2.2.1. FETCH PASSWORD
    local password = agent:get_password()

-- 2.2.1.1. CREATE USER AND CACHE PASSWORD
    if password == ngx.null then
        agent:assert_user_doesn_exists()
        password = agent:create_user()
    end

-- 2.2.1.2. AUTH USER
    local authenticity_token, cookie_header = agent:http_get_token()
    cookies = agent:http_sign_in(authenticity_token, cookie_header, password)

-- 2.3. CACHE SESSION
    agent:store_cookies(cookies)
    cookies = agent:get_cookies()
else
-- 3. SET SESSION
    local cookies_map = {}
    for k,v in string.gmatch(cookies, "([^=; ]+)=([^=; ]+)") do
        cookies_map[k] = v
    end
    -- 3.1. Overwrite cookies
    local cookie_header = ""
    local request_cookies = ngx.req.get_headers()["Cookie"]
    if request_cookies then
        for k,v in string.gmatch(request_cookies, "([^=; ]+)=([^=; ]+)") do
            cookie_header = cookie_header .. k .. "="
            -- overwrite cookie value
            if cookies_map[k] ~= nil then
                cookie_header = cookie_header .. cookies_map[k]
                cookies_map[k] = nil
            -- forward cookie value
            else
                cookie_header = cookie_header .. v
            end
            cookie_header = cookie_header .. ";"
        end
    end
    -- 3.2. Dump cookies if not already overwritten
    for k,v in pairs(cookies_map) do
        cookie_header = cookie_header..k.."="..v..";"
    end

    -- 3.3. Set cookies for forwarded request
    ngx.req.set_header("Cookie", cookie_header)    
end
