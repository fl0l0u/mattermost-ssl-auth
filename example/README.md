# Example

Demo PKI and one-shot installer for the Mattermost gateway.

## Pre-requisite
* `openssl` installed
* for `demo_install.sh`: a **fresh Ubuntu 24.04 LTS** server, run as root

## 1. Full demo install (Ubuntu 24.04)

```bash
sudo bash demo_install.sh
```

Installs and wires up everything on a clean box:
* apt: OpenResty (official repo), Mattermost (newest 11.x, official repo), PostgreSQL, Redis
* Postgres: role `mmuser` + database `mattermost`
* Mattermost: loopback listen (`127.0.0.1:8065`), `SiteURL=https://mattermost.example.test`, local mode, SQL DSN
* First user via the API (local mode makes it the system admin), provisioning PAT, default team
* PKI (via `build_certs.sh`) → `/etc/ssl/private/{mattermost.crt,mattermost.key,client-ca.crt}`
* vendored lua-resty-http v0.17.1 (repo-pinned) → `/usr/local/openresty/nginx/lua/resty/`
* gateway files from `src/` (existing files backed up) + `/etc/mattermost-ssl-auth.env` (root:600)
* `mattermost-ssl-auth` service started, `openresty -t` + certificate smoke test

The script is idempotent: secrets are persisted under `/etc/mattermost-ssl-auth-demo/` so re-runs stay consistent.

## 2. Certificates only

```bash
bash build_certs.sh
```

Builds a minimal two-level PKI (root CA + signing CA):
* server certificate `certs/mattermost.{crt,key}` for `mattermost.example.test` (SAN)
* admin user `certs/flo.{crt,key,pfx}` — `O=Example Org`, `OU=Admins`, `CN=flolou`, `emailAddress=flo@example.test` (provisioned user `flo`, system admin via `OU=Admins`)
* regular user `certs/aze.{crt,key,pfx}` — `O=Example Org`, `OU=Users`, `CN=Azerty`, `emailAddress=aze@example.test` (provisioned user `aze`)

To deploy the server material manually:
```bash
sudo cp certs/mattermost.crt /etc/ssl/private/
sudo install -m 600 certs/mattermost.key /etc/ssl/private/
sudo sh -c 'cat ca/signing-ca.crt ca/root-ca.crt > /etc/ssl/private/client-ca.crt'
```

## 3. Connection
* (optional) install `ca/root-ca.crt` as a trusted root CA
* import a user PFX (`certs/flo.pfx` or `certs/aze.pfx`, empty password) into the browser
* add `mattermost.example.test` to `/etc/hosts` (or point a real DNS entry at the box)
* open `https://mattermost.example.test` — the gateway provisions the user on first connection and signs them in; no password is ever shown
