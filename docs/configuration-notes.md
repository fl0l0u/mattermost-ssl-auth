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
