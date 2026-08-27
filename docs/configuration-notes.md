# Configuration change notes (reference deployment)

Concise, exhaustive notes of every configuration change made to reach a working
state (reference VM <vm-ip>, 2026-08-25).

## systemd

- v1 `mattermost-ssl-auth.service`: stopped → disabled → replaced by the unit
  in this repo. Backups kept on the VM:
  `/etc/systemd/system/mattermost-ssl-auth.service.v1.bak` and
  `/etc/systemd/system/mattermost-ssl-auth.service.pre-testing.bak`.
- `mattermost.service` (apt package): enabled.
- `postgresql.service`: enabled.
- Docker Mattermost stack: stopped, not removed. Rollback:
  `sudo docker compose -f /opt/mattermost/docker-compose.yml start`.

## apt

- `/etc/apt/sources.list.d/mattermost.list`:
  `deb [signed-by=/usr/share/keyrings/mattermost-archive-keyring.gpg] https://deb.packages.mattermost.com noble main`
  (key fingerprint <fingerprint>). Note: `pkg.mattermost.com` is NXDOMAIN — the
  current package repo is `deb.packages.mattermost.com`.
- Installed: `mattermost` 11.10.1-0, `postgresql-16`.

## Postgres

- Role `mmuser`: LOGIN, password `<password>`.
- Database `mattermost`, owner `mmuser`.

## /opt/mattermost/config/config.json

Backup: `config.json.bak-20260825`.

| Key | Before | After |
|---|---|---|
| `ListenAddress` | `:8065` | `127.0.0.1:8065` |
| `SiteURL` | `` | `https://mattermost.example.test` |
| `EnableLocalMode` | `false` | `true` |
| `DataSource` | (v1 docker DB) | `postgres://<db_user>:<password>@127.0.0.1:5432/mattermost?sslmode=disable` |

Note: `example/demo_install.sh` also sets `EnableUserAccessTokens=true` —
11.x ships personal access tokens disabled.

## Mattermost data (local mode)

- First local-mode user `admin@example.test` / `<password>` = system admin
  (id `<user id>`).
- PAT `ssl-auth-provision`: `<system-admin personal access token>`.
- Team `town-square` `<team id>` created manually — local mode
  does NOT auto-create teams (the web onboarding wizard does).
- Evidence users: `flo` (system_admin, OU=Admins), `aze`/`dave`/`erin`
  (OU=Users), `bob`/`carol` soft-deleted.

## Proxy deployment (OpenResty)

- `nginx.conf` replaced; backups: `/root/nginx.conf.v1.bak`,
  `/root/nginx.conf.pre-testing.bak`,
  `/usr/local/openresty/nginx/conf/nginx.conf.pre-18443.bak`.
- 3 Lua files replaced; backups: `/root/lua.v1.bak`,
  `/root/lua.pre-testing.bak`.
- `lua-resty-http` v0.17.1 ADDED to
  `/usr/local/openresty/nginx/lua/resty/` (v1 used a custom client).
- Unit v2: `LimitNOFILE=65536` — the systemd default of 1024 caused
  `worker_connections` warnings.
- `/etc/mattermost-ssl-auth.env` (root:600) with the 9 values:
  `MATTERMOST_UPSTREAM=http://127.0.0.1:8065`;
  `REDIS_URI=unix:/run/redis/redis-server.sock` (the worker user `nobody` is
  in the `redis` group); `MATTERMOST_PROVISION_TOKEN=<redacted>` (the PAT above);
  `ALLOW_PROVISION=true`; `MM_DEFAULT_TEAM_ID=<team id>`;
  `CERT_EMAIL_FIELD=emailAddress`; `CERT_NAME_FIELD=CN`;
  `CERT_ADMIN_OU=Admins`; `USERNAME_FROM_EMAIL=true`.

## Redis

- Flushed 2 stale v1 `x509auth:user:alice…` keys.
- Key shape: `x509auth:<email>:{cookies,token,password[,lock]}`.

## PKI

- Server cert/key + client CA kept from v1 in `/etc/ssl/private` (validated by
  `openresty -t`).
- New test client certs issued from the existing CA (its key was at
  `/tmp/repo/example/ca/client-ca/private/client-ca.key`) →
  `/root/pki-v2/{flo,aze,dave,erin,bob,carol}.crt/.key`.

## Port notes

- 8443 = Mattermost Calls plugin RTC port (binds `0.0.0.0:8443` on MM
  restart) — the loopback test ingress therefore uses `18443` instead.

## Verification summary

- 15/15 cert-based E2E + 13/13 header-based E2E (test ingress) + LimitNOFILE
  clean.
- Code review findings (C2/M1/M2/M3/m1/m4/m9) fixed in
  `51154e7` + `8c6dc38`.

## 2026-08-26 — renewal redesign + browser verification

- Lua files: 4 now — `mattermost_ssl_auth.lua` (core),
  `mattermost_location_default.lua`, `mattermost_location_login.lua`,
  `mattermost_cookie_hydration.lua` (pure-Lua
  `header_filter_by_lua_file` on `location /`, both servers). The old
  log-phase `mattermost_session_filter.lua` is deleted.
- `/etc/mattermost-ssl-auth.env` now has 12 values — 3 added on top of
  the 9 above: `MATTERMOST_SITE_URL=https://mattermost.example.test`;
  `SESSION_MAX_AGE_HOURS=20`; `SESSION_CHECK_INTERVAL_SECONDS=60`.
- `nginx.conf`: `lua_shared_dict mmssl_sessions 1m;` — per-user throttle
  for the access-phase liveness check.
- OS-level note: OpenResty 1.31.1.1 (apt) disables cosockets in the
  `header_filter`, `body_filter` and `log` phases (verified
  empirically). That killed the log-phase renewal design; session
  liveness is now checked in the access phase (probe, in-access renewal
  under the per-email Redis lock, never-fails degraded path), and the
  only filter-phase work is the pure-Lua cookie-jar hydration.
- Browser verification (Playwright, this VM): P0–P6 all pass — P0 no-DN
  → 400; P1 fresh-browser cold start boots logged in (0×401/47, jar
  hydrated); P3 server-side revoke → 401s only inside the 60 s throttle
  window → transparent in-access renewal (token rotated, no `/login`,
  no reload); P4 forced-stale age → renewal; P5 OU=Admins →
  system_admin; P6 fresh browser, warm session → straight to the app,
  zero logins. Two-user (flo↔aze): messages delivered both directions,
  0×401/0×5xx.
- WebSocket: production path verified end-to-end through the proxy
  (101 + hello with a matching Origin); the loopback test ingress
  could not carry browser WS (Mattermost compares the Origin port
  literally — see ADR 0002) — superseded 2026-08-27 by same-host-only
  normalization (entry below).

## 2026-08-27 — same-host-only WS Origin normalization

- `mattermost_location_default.lua` now normalizes the WebSocket
  `Origin` to `MATTERMOST_SITE_URL` in the access hook (hook shared by
  every `location = /api/v4/websocket`), **only when the Origin's host
  matches the SiteURL's host** (any or absent port) — replacing the
  per-location `proxy_set_header Origin` lines, removed from
  `nginx.conf` (443 + 18443 in the repo conf; 443, 18443 plus the
  VM-only demo blocks 18444/18445 on this VM).
- Effect: the loopback/test/demo ingresses now carry browser
  WebSockets (port-only rewrite), while cross-origin WS upgrades
  (attacker-host Origin) pass through untouched and are rejected by
  Mattermost with 403. Backups:
  `/root/nginx.conf.pre-samehost.bak`,
  `/root/mattermost_location_default.lua.pre-samehost.bak`.

## 2026-08-27 — nginx.conf split into includes (DRY, zero behavior change)

- `nginx.conf` is now main context + http infra only; the server blocks
  and their location bodies moved verbatim to
  `/usr/local/openresty/nginx/conf/includes/` — 5 files:
  `location-ws.conf`, `location-login.conf`, `location-root.conf`
  (shared by every server) and `server-443.conf`,
  `server-test-18443.conf` (the former inline blocks; where the location
  bodies were, they now carry three `include` lines). Absolute include
  paths. Zero behavior change: each new server file re-expands
  byte-for-byte to its original inline block.
- On this VM the demo servers became `includes/server-demo-18444.conf`
  / `includes/server-demo-18445.conf` (VM-only, not in the repo) — each
  keeps listen/`server_name`/ssl_*/pinned `set $mmssl_test_dn`/
  `client_max_body_size` and includes the shared location bodies (the
  inlined copies were verified byte-identical before replacing). The
  VM's `nginx.conf` differs from the repo's only by the two demo
  include lines. Backups: `/root/nginx.conf.pre-dry.bak`,
  `/root/nginx-conf.pre-dry.bak.tgz` (whole conf dir).
- `example/demo_install.sh` deploy-list fixes (pre-existing bugs):
  removed `mattermost_session_filter.lua` (file no longer in the repo —
  a fresh install aborted on it under `set -euo pipefail`) and added
  `mattermost_cookie_hydration.lua` (referenced by the conf's
  `header_filter_by_lua_file` but never installed).
- The installer backs up and overwrites the files it deploys but does
  NOT remove stale files on re-deploy: e.g. the now-unreferenced
  `/usr/local/openresty/nginx/lua/mattermost_session_filter.lua` left on
  this VM stays on disk (harmless — nothing includes it).

## 2026-08-27 — shared include for the common proxy headers (DRY)

- The 4 proxy headers duplicated in `location-ws.conf` and
  `location-root.conf` (`X-Real-IP $remote_addr`,
  `X-Forwarded-For $proxy_add_x_forwarded_for`,
  `X-Forwarded-Proto https`, `X-Forwarded-Ssl on`) moved to
  `includes/proxy-common-headers.conf`, spliced in via `include` —
  they cannot live in the http block because nginx
  `proxy_set_header` inheritance is all-or-nothing: a location that
  defines any `proxy_set_header` inherits none of the outer ones, so
  hoisting them would have silently dropped all four from every
  location. (`location-login.conf` has no proxying — Lua-terminated —
  and is untouched; `example/demo_install.sh` deploy list gained the
  new include.)
- Deployed on this VM (all four servers pick it up via the shared
  location includes): `openresty -t` OK, service restarted, full
  16-point E2E battery green — WS 101 on all four ingresses,
  cross-origin WS still 403, identities flo/aze on 18444/18445/18443,
  no-cert 400, HSTS 443-only, server cert + CertificateRequest intact
  on 443, and `openresty -T` shows the spliced 7 (WS) / 6 (root)
  proxy headers. Backups: `/root/nginx-conf.pre-headersenv.bak.tgz`
  (whole conf dir), `/root/mattermost-ssl-auth.env.pre-headersenv.bak`.

## 2026-08-27 — cert-path env externalization: gated, NOT shipped

- Attempt: take the hardcoded cert paths out of `server-443.conf`
  (and the VM-only demo servers') `ssl_certificate` /
  `ssl_certificate_key` / `ssl_client_certificate` into `$MATTEMOST_SSL_CERT`
  / `$MATTEMOST_SSL_KEY` / `$MATTEMOST_SSL_CLIENT_CA` via main-context
  `env` + `/etc/mattermost-ssl-auth.env`, following the existing 12
  env-var pattern.
- Gate (throwaway conf, live conf untouched) FAILED on
  OpenResty 1.31.1.1 (nginx 1.31.1):
  `nginx: [emerg] unknown "testcert" variable` — in any stock nginx
  a main-context `env` directive only preserves the variable in the
  process environment (for Lua `os.getenv`); it never creates an nginx
  config variable (the separate `ngx_http_env_module` http-context
  `env` is what maps env vars to named nginx variables, and it is
  irrelevant here — `ssl_certificate` is evaluated at config time,
  not request time). Evidence: the same error for
  `return 200 "$TESTCERT";`, with the variable confirmed present in
  the master's environment; a hardcoded-path control conf passed.
  NOT shipped: cert paths stay hardcoded in the repo conf and on this
  VM.
- Alternatives if this is wanted later: keep hardcoded + document;
  substitute the paths into the conf at install time; or dynamic ssl
  (`ssl_certificate_by_lua_block`) — heavier, and re-reads the cert
  material per handshake.

## 2026-08-27 — locations re-merged inline into the server files (self-contained servers)

- At operator request, the location bodies were re-merged inline into
  `includes/server-443.conf` and `includes/server-test-18443.conf` —
  each server file is now self-contained — and
  `location-ws.conf` / `location-login.conf` / `location-root.conf`
  were deleted (`example/demo_install.sh` deploy list updated to match).
- Accepted tradeoff: the location bodies are now duplicated per
  server (the VM-only demo servers 18444/18445 carry their own inline
  copies too), in exchange for each server file being readable as a
  whole.
- `proxy-common-headers.conf` is unchanged and remains the only shared
  snippet (spliced into the WS and root locations of every server).
  Note the common headers cannot live at the server level either:
  nginx `proxy_set_header` inheritance is all-or-nothing, the same
  rule that rules out the http level — a location defining any
  `proxy_set_header` inherits none of the outer ones.
- Behavior-preserving move: verified on this VM (all four servers) —
  `openresty -T` re-expands byte-identically (7 WS / 6 root
  proxy_set_header everywhere) and the full E2E battery is green.
  Backups: `/root/nginx-conf.pre-remerge.bak.tgz` (whole conf dir).

## 2026-08-27 — server includes globbed (makes .deb upgrades safe for site-specific servers)

- The two explicit include lines in `nginx.conf` (`server-443.conf`,
  `server-test-18443.conf`) became one glob:
  `include /usr/local/openresty/nginx/conf/includes/server-*.conf;`
  (expands in alphabetical order). Rationale for the .deb packaging:
  the package will own only `server-443.conf` and
  `server-test-18443.conf`; a site-specific server is a
  `server-*.conf` file dropped into `includes/` outside dpkg's file
  list, so it — and any local edits to it — survive .deb upgrades
  without the main conf ever needing a per-site edit that an upgrade
  would prompt on or replace.
- On this VM the two VM-only demo include lines disappeared from
  `nginx.conf` (the glob picks up `server-demo-18444.conf` /
  `server-demo-18445.conf` already on disk) — the VM's conf is now
  byte-identical to the repo's. Verified on this VM: `openresty -t`
  OK, graceful reload (systemd `ExecReload` = HUP), all four
  listeners still answer — /users/me: flo on 443 (client cert) and
  18444 (pinned), aze on 18443 (X-Test-DN) and 18445 (pinned); WS
  101 on the 443 production path. Backup:
  `/root/nginx.conf.pre-glob.bak`.
