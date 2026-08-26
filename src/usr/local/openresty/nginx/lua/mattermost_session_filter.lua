--[[
https://github.com/fl0l0u
]]
-- header_filter_by_lua_file + body_filter_by_lua_file, proxied locations
-- 401 session-renewal intercept (ADR 0002): when the upstream answers 401
-- for an /api/v4/* request, renew the stored session and replay the
-- original request, swapping the fresh response in. One file serves both
-- filters; the body filter is a cheap no-op unless a swap is pending.

if ngx.get_phase() == "body_filter" then
    if ngx.ctx.mm401_swap then
        if ngx.arg[2] then
            ngx.arg[1] = ngx.ctx.mm401_body
        else
            ngx.arg[1] = ""
        end
    end
    return
end

-- 1. Once per request
if ngx.ctx.mm401_done then
    return
end
ngx.ctx.mm401_done = true

-- 2. Act only on an upstream 401 (nginx-generated 401s carry no upstream
-- status) on a retriable API path, never a browser login attempt
local uri = ngx.var.uri
local act =
    ngx.var.upstream_status == "401"
    and uri:sub(1, 8) == "/api/v4/"
    and uri ~= "/api/v4/users/login"
    and not ngx.ctx.mm401_retried
if not act then
    ngx.ctx.mm401_retried = true
    return
end

-- 3. Claim the attempt before any blocking work (no loops)
ngx.ctx.mm401_retried = true

-- Same test-seam DN logic as the hooks; without a DN there is no session
-- to renew, so the 401 passes through
local test_dn = ngx.var.mmssl_test_dn
if test_dn == "" then
    test_dn = nil
end
local dn = test_dn or ngx.var.ssl_client_s_dn
if not dn or dn == "" then
    return
end

-- 4. Renew: lock-serialized, peer-aware — a burst of parallel 401s still
-- costs exactly one login.
-- pcall: the renewal must never abort the request. Any failure —
-- including an "API disabled" error on an OpenResty build without
-- cosocket support in the filter phases — degrades to passing the 401
-- through.
local MattermostSslAuth = require("mattermost_ssl_auth")
local agent_ok, ssl = pcall(MattermostSslAuth.new, MattermostSslAuth, dn)
if not agent_ok then
    ngx.log(ngx.WARN, "[lua] 401 renew failed, passing 401 through: " .. tostring(ssl))
    return
end
local renew_ok, renewed, err = pcall(ssl.renew_for_401, ssl)
if not (renew_ok and renewed) then
    ngx.log(ngx.WARN, "[lua] 401 renew failed, passing 401 through: " .. tostring(err or renewed))
    return
end

-- 5. Replay the original request with the renewed session
local headers, snap_err = ssl:snapshot_outbound_headers()
if not headers then
    ngx.log(ngx.WARN, "[lua] 401 replay aborted, passing 401 through: " .. tostring(snap_err))
    return
end
local body = ssl:read_request_body()
local status, rheaders, rbody, rerr = ssl:replay_request(
    headers, ngx.req.get_method(),
    uri .. (ngx.var.args and ("?" .. ngx.var.args) or ""), body)
if rerr then
    ngx.log(ngx.WARN, "[lua] 401 replay failed, passing 401 through: " .. tostring(rerr))
    return
end

-- 6. Swap the response in: the browser never sees the 401
ngx.status = status
local old = ngx.resp.get_headers()
for k in pairs(old or {}) do
    ngx.header[k] = nil
end
for k, v in pairs(rheaders or {}) do
    if v ~= nil and (type(v) ~= "table" or next(v)) then
        ngx.header[k] = v
    end
end
ngx.header["Content-Length"] = #rbody
ngx.header["Transfer-Encoding"] = nil
ngx.header["Content-Encoding"] = nil
ngx.header["X-Session-Renewed"] = "1"
ngx.ctx.mm401_body = rbody
ngx.ctx.mm401_swap = true
