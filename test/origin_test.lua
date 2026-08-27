-- Dependency-free unit tests for mattermost_origin.lua (the pure-Lua
-- same-host Origin helpers behind the WebSocket Origin normalization).
-- No OpenResty, no external dependencies — runs on stock LuaJIT.
--
-- Invoke from the repo root:
--   luajit test/origin_test.lua
-- or from the installed layout (this script copied next to the module in
-- /usr/local/openresty/nginx/lua):
--   cd /usr/local/openresty/nginx/lua && /usr/local/openresty/luajit/bin/luajit origin_test.lua

-- Locate the module: repo layout first, then a flat layout (module in the
-- current directory, e.g. the installed nginx lua dir).
package.path = "./src/usr/local/openresty/nginx/lua/?.lua;./?.lua;"
    .. package.path

local origin = require("mattermost_origin")

local cases = {
    -- origin_host: positive
    { 'origin_host("https://mattermost.example.test")',
      origin.origin_host("https://mattermost.example.test"),
      "mattermost.example.test" },
    { 'origin_host("https://mattermost.example.test:18445")',
      origin.origin_host("https://mattermost.example.test:18445"),
      "mattermost.example.test" },
    -- origin_host: safe rejections
    { 'reject uppercase scheme ("HTTPS://…")',
      origin.origin_host("HTTPS://mattermost.example.test"), nil },
    { 'reject trailing slash ("https://h/")',
      origin.origin_host("https://h/"), nil },
    { 'reject double port ("https://h:1:2")',
      origin.origin_host("https://h:1:2"), nil },
    { 'reject IPv6 brackets ("https://[::1]:18444")',
      origin.origin_host("https://[::1]:18444"), nil },
    { 'reject userinfo+port ("https://user@host:1@evil.com/")',
      origin.origin_host("https://user@host:1@evil.com/"), nil },
    { 'reject empty string ("")',
      origin.origin_host(""), nil },
    { 'reject opaque origin ("null")',
      origin.origin_host("null"), nil },
    { 'reject port then path ("https://mattermost.example.test:443/")',
      origin.origin_host("https://mattermost.example.test:443/"), nil },
    { 'reject absent host ("https://")',
      origin.origin_host("https://"), nil },
    -- same_host
    { 'same_host true: same host, different ports',
      origin.same_host("https://mattermost.example.test:18445",
                       "https://mattermost.example.test:8065"), true },
    { 'same_host true: case-differing hosts',
      origin.same_host("https://Mattermost.Example.Test",
                       "https://mattermost.example.test"), true },
    { 'same_host true: http vs https scheme',
      origin.same_host("http://mattermost.example.test",
                       "https://mattermost.example.test"), true },
    { 'same_host false: suffix-lookalike host',
      origin.same_host("https://mattermost.example.test.evil.com",
                       "https://mattermost.example.test"), false },
    { 'same_host false: different host',
      origin.same_host("https://evil.com",
                       "https://mattermost.example.test"), false },
    { 'same_host false: non-origin arg ("null")',
      origin.same_host("null", "https://mattermost.example.test"), false },
    { 'same_host false: userinfo prefix (host comparison, not shape)',
      origin.same_host("https://mattermost.example.test",
                       "https://user@mattermost.example.test"), false },
}

local failures = 0
for i, c in ipairs(cases) do
    if c[2] ~= c[3] then
        failures = failures + 1
        print(string.format("FAIL %-56s expected=%s  got=%s",
            c[1], tostring(c[3]), tostring(c[2])))
    end
end

if failures > 0 then
    print(string.format("FAIL %d/%d (origin_test)", failures, #cases))
    os.exit(1)
end
print(string.format("PASS %d/%d (origin_test)", #cases, #cases))
os.exit(0)
