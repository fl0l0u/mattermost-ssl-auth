--[[
https://github.com/fl0l0u
]]
-- header_filter_by_lua_file, location /
-- Hydrates the browser's cookie jar with the stored session (pure Lua, no
-- cosockets — phase-legal; ADR 0002). The webapp decides "logged in" from
-- MMUSERID in the browser's jar, but the access hook only rewrites the
-- outbound wire request, so a fresh browser lands on the login form. This
-- filter replaces the upstream's Set-Cookie headers (same values) with
-- the stored session's, carrying the jar's attributes.
local s = ngx.ctx.mmssl
if not s or not s.cookie_string then
    return
end

-- Path=/ so the jar receives the cookies on every path; Max-Age 30 days
-- covers Mattermost's session lifetime; SameSite=Lax is the webapp's
-- default. Secure is appended only when the gateway is served over TLS —
-- the loopback http test ingress must hydrate the jar too.
local attrs = "; Path=/; HttpOnly; Max-Age=2592000; SameSite=Lax"
if ngx.var.https == "on" then
    attrs = attrs .. "; Secure"
end

local set_cookie = {}
for k, v in string.gmatch(s.cookie_string, "([^=; ]+)=([^=; ]+)") do
    set_cookie[#set_cookie + 1] = k .. "=" .. v .. attrs
end
if #set_cookie > 0 then
    -- Table form = multiple Set-Cookie headers; replaces the upstream's.
    ngx.header["Set-Cookie"] = set_cookie
end
