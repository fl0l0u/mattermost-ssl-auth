#!/bin/bash
# Demo installer for mattermost-ssl-auth on a FRESH Ubuntu 24.04 (noble) box.
#
#   1. apt packages: openresty (official repo), mattermost (newest 11.x,
#      official repo), postgresql, redis-server
#   2. Postgres: role mmuser (LOGIN, random password) + database mattermost
#   3. Mattermost config: loopback listen, SiteURL, local mode, SQL DSN
#   4. First user via API (local mode makes it the system admin),
#      provisioning PAT, default team
#   5. PKI from build_certs.sh -> /etc/ssl/private/{mattermost.crt,mattermost.key,client-ca.crt}
#   6. vendored lua-resty-http v0.17.1 (repo-pinned) -> /usr/local/openresty/nginx/lua/resty/
#   7. repo src/ -> /usr/local + /etc/systemd/system (existing files backed up)
#   8. /etc/mattermost-ssl-auth.env (root:600)
#   9. proxy state dirs (logs/pid/temp) + worker ownership
#  10. systemctl + openresty -t
#
# Run as root:  sudo bash example/demo_install.sh
# Safe to re-run: every step is idempotent (secrets are persisted in
# /etc/mattermost-ssl-auth-demo/ so re-runs stay consistent).

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

MM_FQDN=mattermost.example.test
MM_SITE_URL="https://${MM_FQDN}"
MM_UPSTREAM=http://127.0.0.1:8065
MM_DB_USER=mmuser
MM_DB_NAME=mattermost
MM_ADMIN_USER=admin
MM_ADMIN_EMAIL=admin@example.test
MM_PAT_NAME=ssl-auth-provision
MM_TEAM_NAME=town-square
MM_TEAM_DISPLAY="Town Square"
CRED_DIR=/etc/mattermost-ssl-auth-demo
API="$MM_UPSTREAM/api/v4"

echo "1. Check pre-requisites"
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }
grep -qE '^PRETTY_NAME="Ubuntu 24\.04' /etc/os-release \
  || { echo "designed for Ubuntu 24.04 LTS (noble)"; exit 1; }

echo "2. Install packages"
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg openssl python3

# OpenResty from the official repo (combine both published keys so apt
# picks the current signer).
if [ ! -f /etc/apt/sources.list.d/openresty.list ]; then
  install -d -m 0755 /etc/apt/keyrings
  cat <(curl -fsSL https://openresty.org/package/pubkey.gpg) \
      <(curl -fsSL https://openresty.org/package/pubkey2.gpg) \
    | gpg --dearmor -o /etc/apt/keyrings/openresty.gpg
  chmod a+r /etc/apt/keyrings/openresty.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/openresty.gpg] https://openresty.org/package/ubuntu noble main" \
    > /etc/apt/sources.list.d/openresty.list
fi

# Mattermost from the official repo. pkg.mattermost.com is retired; the
# signing key is now published next to the repository itself.
if [ ! -f /etc/apt/sources.list.d/mattermost.list ]; then
  curl -fsSL -o- https://deb.packages.mattermost.com/pubkey.gpg \
    | gpg --dearmor -o /usr/share/keyrings/mattermost-archive-keyring.gpg
  chmod a+r /usr/share/keyrings/mattermost-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/mattermost-archive-keyring.gpg] https://deb.packages.mattermost.com noble main" \
    > /etc/apt/sources.list.d/mattermost.list
fi

apt-get update -qq
# Pin to the newest 11.x release the repo currently publishes.
MM_VERSION="$(apt-cache madison mattermost | awk -F'|' '{gsub(/ /, "", $2); print $2}' \
  | grep -E '^11\.' | sort -V | tail -1)"
[ -n "$MM_VERSION" ] || { echo "no Mattermost 11.x found in the repo"; exit 1; }
echo "  mattermost version: ${MM_VERSION}"
apt-get install -y -qq openresty "mattermost=${MM_VERSION}" postgresql redis-server

echo "3. Postgres: role ${MM_DB_USER} + database ${MM_DB_NAME}"
install -d -m 700 -o root -g root "$CRED_DIR"
DB_PASS_FILE="${CRED_DIR}/db.pass"
if [ -f "$DB_PASS_FILE" ]; then
  MM_DB_PASS="$(cat "$DB_PASS_FILE")"
else
  MM_DB_PASS="$(openssl rand -hex 12)"
  printf '%s' "$MM_DB_PASS" > "$DB_PASS_FILE"
  chmod 600 "$DB_PASS_FILE"
fi
su -s /bin/bash postgres -c "psql -qc \"CREATE ROLE ${MM_DB_USER} LOGIN PASSWORD '${MM_DB_PASS}'\"" \
  || su -s /bin/bash postgres -c "psql -qc \"ALTER ROLE ${MM_DB_USER} WITH LOGIN PASSWORD '${MM_DB_PASS}'\""
su -s /bin/bash postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='${MM_DB_NAME}'\"" | grep -q 1 \
  || su -s /bin/bash postgres -c "createdb -O ${MM_DB_USER} ${MM_DB_NAME}"

echo "4. Mattermost configuration"
MM_CFG=/opt/mattermost/config/config.json
[ -f "${MM_CFG}.bak" ] || cp -p "$MM_CFG" "${MM_CFG}.bak"
MM_DSN="postgres://${MM_DB_USER}:${MM_DB_PASS}@127.0.0.1:5432/${MM_DB_NAME}?sslmode=disable"
python3 - "$MM_CFG" "$MM_SITE_URL" "$MM_DSN" <<'EOF'
import json, os, sys

path, site_url, dsn = sys.argv[1], sys.argv[2], sys.argv[3]
st = os.stat(path)
with open(path) as f:
    cfg = json.load(f)
cfg["ServiceSettings"]["ListenAddress"] = "127.0.0.1:8065"
cfg["ServiceSettings"]["SiteURL"] = site_url
cfg["ServiceSettings"]["EnableLocalMode"] = True
# v11 ships personal access tokens disabled by default; provisioning needs one.
cfg["ServiceSettings"]["EnableUserAccessTokens"] = True
cfg["SqlSettings"]["DriverName"] = "postgres"
cfg["SqlSettings"]["DataSource"] = dsn
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=4)
    f.write("\n")
os.chown(tmp, st.st_uid, st.st_gid)
os.chmod(tmp, 0o600)
os.replace(tmp, path)
EOF
systemctl enable --now mattermost
echo "  waiting for Mattermost on 127.0.0.1:8065"
for i in $(seq 1 30); do
  if curl -fsS "$API/system/ping" >/dev/null; then break; fi
  [ "$i" -eq 30 ] && { echo "mattermost did not come up; see /opt/mattermost/logs/mattermost.log"; exit 1; }
  sleep 2
done

echo "5. First admin user, provisioning PAT, default team"
ADMIN_PASS_FILE="${CRED_DIR}/admin.pass"
if [ -f "$ADMIN_PASS_FILE" ]; then
  MM_ADMIN_PASS="$(cat "$ADMIN_PASS_FILE")"
else
  MM_ADMIN_PASS="$(openssl rand -base64 15)"
  printf '%s' "$MM_ADMIN_PASS" > "$ADMIN_PASS_FILE"
  chmod 600 "$ADMIN_PASS_FILE"
fi

# The session token arrives as a `Token:` response header. The -D dump is
# CRLF; strip the \r — a CR inside Authorization makes Mattermost reject
# the request with a bare "400 Bad Request".
mm_login() {
  curl -fsS -D - -o /dev/null -X POST -H "Content-Type: application/json" \
    -d "{\"login_id\":\"${MM_ADMIN_EMAIL}\",\"password\":\"${MM_ADMIN_PASS}\"}" \
    "$API/users/login" | tr -d '\r' | awk 'tolower($1) == "token:" {print $2}'
}

# Existence is detected by logging in: GET /api/v4/users/id/{username}
# was removed from the Mattermost API (routing 404 on 11.x), and login
# also hands us the session token the PAT management below needs.
MM_ADMIN_TOKEN="$(mm_login || true)"
if [ -z "$MM_ADMIN_TOKEN" ]; then
  # Local mode makes the FIRST user created the system admin; no promotion needed.
  curl -fsS -X POST -H "Content-Type: application/json" \
    -d "{\"username\":\"${MM_ADMIN_USER}\",\"email\":\"${MM_ADMIN_EMAIL}\",\"password\":\"${MM_ADMIN_PASS}\",\"email_verified\":true}" \
    "$API/users" >/dev/null
  echo "  created first (system-admin) user ${MM_ADMIN_USER}"
  MM_ADMIN_TOKEN="$(mm_login)" \
    || { echo "admin login failed — delete ${ADMIN_PASS_FILE} (and the admin user) to reset"; exit 1; }
else
  echo "  admin user ${MM_ADMIN_USER} already exists"
fi
# /users/me (authenticated) replaces the removed /users/id/{username}.
MM_ADMIN_ID="$(curl -fsS -H "Authorization: Bearer ${MM_ADMIN_TOKEN}" "$API/users/me" \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"

# 11.x PAT notes: there is no `name` field (match on `description`), the
# create response is a single object (not a list), `description` is
# mandatory, the list response never exposes the secret, and no
# delete/revoke route exists — so the secret is only available at
# creation time and must be persisted to survive re-runs.
PAT_FILE="${CRED_DIR}/pat"
MM_PAT=""
[ -f "$PAT_FILE" ] && MM_PAT="$(cat "$PAT_FILE")"
MM_PAT_EXISTS="$(curl -fsS "$API/users/${MM_ADMIN_ID}/tokens" -H "Authorization: Bearer ${MM_ADMIN_TOKEN}" \
  | python3 -c "import json, sys; print(any(t['description'] == 'mattermost-ssl-auth user provisioning' for t in json.load(sys.stdin)))")"
if [ "$MM_PAT_EXISTS" = "True" ] && [ -n "$MM_PAT" ]; then
  echo "  reusing existing PAT ${MM_PAT_NAME}"
elif [ "$MM_PAT_EXISTS" = "True" ]; then
  echo "  PAT ${MM_PAT_NAME} exists but its secret is not in ${PAT_FILE}"; exit 1
else
  MM_PAT="$(curl -fsS -X POST -H "Authorization: Bearer ${MM_ADMIN_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"name\":\"${MM_PAT_NAME}\",\"description\":\"mattermost-ssl-auth user provisioning\"}" \
    "$API/users/${MM_ADMIN_ID}/tokens" \
    | python3 -c 'import json, sys
tok = json.load(sys.stdin)
if isinstance(tok, list):
    tok = tok[0]
print(tok["token"])')"
  printf '%s' "$MM_PAT" > "$PAT_FILE"
  chmod 600 "$PAT_FILE"
  echo "  created PAT ${MM_PAT_NAME}"
fi

# NOTE: local mode does NOT auto-create a team — the web onboarding wizard
# does, and it never runs under API provisioning, so create it explicitly.
if [ "$(curl -s -o /dev/null -w '%{http_code}' "$API/teams/name/${MM_TEAM_NAME}" -H "Authorization: Bearer ${MM_PAT}")" = "200" ]; then
  MM_TEAM_ID="$(curl -fsS "$API/teams/name/${MM_TEAM_NAME}" -H "Authorization: Bearer ${MM_PAT}" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
  echo "  default team ${MM_TEAM_NAME} already exists"
else
  MM_TEAM_ID="$(curl -fsS -X POST -H "Authorization: Bearer ${MM_PAT}" -H "Content-Type: application/json" \
    -d "{\"name\":\"${MM_TEAM_NAME}\",\"display_name\":\"${MM_TEAM_DISPLAY}\",\"type\":\"O\"}" "$API/teams" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')"
  echo "  created default team ${MM_TEAM_NAME}"
fi

echo "6. PKI"
if [ -f /etc/ssl/private/mattermost.crt ] && [ -f /etc/ssl/private/mattermost.key ] \
  && [ -f /etc/ssl/private/client-ca.crt ]; then
  echo "  certificates already present in /etc/ssl/private, skipping"
else
  ( cd "$SCRIPT_DIR" && bash build_certs.sh )
  # /etc/ssl/private is a root-only directory; only the nginx master (root)
  # reads the key.
  install -d -m 710 /etc/ssl/private
  install -m 644 -o root -g root "$SCRIPT_DIR/certs/mattermost.crt" /etc/ssl/private/mattermost.crt
  install -m 600 -o root -g root "$SCRIPT_DIR/certs/mattermost.key" /etc/ssl/private/mattermost.key
  # Trust store for ssl_client_certificate: client (signing) CA + root CA.
  cat "$SCRIPT_DIR/ca/signing-ca.crt" "$SCRIPT_DIR/ca/root-ca.crt" > /etc/ssl/private/client-ca.crt
  chmod 644 /etc/ssl/private/client-ca.crt
fi

echo "7. Install vendored lua-resty-http v0.17.1 (repo-pinned)"
# v0.17.1 repo layout: lib/resty/{http,http_connect,http_headers}.lua —
# vendored in the repo (src/usr/local/openresty/nginx/lua/resty/), so no
# network fetch is needed.
install -d -m 755 /usr/local/openresty/nginx/lua/resty
install -m 644 -o root -g root \
  "$REPO_ROOT/src/usr/local/openresty/nginx/lua/resty/http.lua" \
  "$REPO_ROOT/src/usr/local/openresty/nginx/lua/resty/http_connect.lua" \
  "$REPO_ROOT/src/usr/local/openresty/nginx/lua/resty/http_headers.lua" \
  "$REPO_ROOT/src/usr/local/openresty/nginx/lua/resty/LICENSE" \
  /usr/local/openresty/nginx/lua/resty/

echo "8. Deploy gateway files (existing files backed up)"
# The stock openresty service is superseded by mattermost-ssl-auth.service.
systemctl disable --now openresty 2>/dev/null || true
for src in \
  usr/local/openresty/nginx/conf/nginx.conf \
  usr/local/openresty/nginx/conf/includes/proxy-common-headers.conf \
  usr/local/openresty/nginx/conf/includes/server-443.conf \
  usr/local/openresty/nginx/conf/includes/server-test-18443.conf \
  usr/local/openresty/nginx/lua/mattermost_ssl_auth.lua \
  usr/local/openresty/nginx/lua/mattermost_origin.lua \
  usr/local/openresty/nginx/lua/mattermost_location_default.lua \
  usr/local/openresty/nginx/lua/mattermost_location_login.lua \
  usr/local/openresty/nginx/lua/mattermost_cookie_hydration.lua \
  etc/systemd/system/mattermost-ssl-auth.service
do
  dest="/${src}"
  [ -f "$dest" ] && mv -f "$dest" "${dest}.bak-$(date +%Y%m%d%H%M%S)"
  install -d -m 755 "$(dirname "$dest")"
  install -m 644 -o root -g root "$REPO_ROOT/src/${src}" "$dest"
  echo "  deployed ${dest}"
done

echo "9. /etc/mattermost-ssl-auth.env"
install -m 600 -o root -g root "$REPO_ROOT/src/etc/mattermost-ssl-auth.env.example" /etc/mattermost-ssl-auth.env
# Redis over loopback TCP: the distro unix socket is 700 redis:redis, which
# the nginx workers (nobody) cannot reach.
sed -i 's|^REDIS_URI=.*|REDIS_URI=redis://127.0.0.1:6379|' /etc/mattermost-ssl-auth.env
sed -i "s|^MATTERMOST_SITE_URL=.*|MATTERMOST_SITE_URL=${MM_SITE_URL}|" /etc/mattermost-ssl-auth.env
sed -i "s|^MATTERMOST_PROVISION_TOKEN=.*|MATTERMOST_PROVISION_TOKEN=${MM_PAT}|" /etc/mattermost-ssl-auth.env
sed -i "s|^MM_DEFAULT_TEAM_ID=.*|MM_DEFAULT_TEAM_ID=${MM_TEAM_ID}|" /etc/mattermost-ssl-auth.env

echo "9.5. Proxy state directories (must exist before first start)"
# ProtectSystem=strict mounts the nginx prefix read-only, so on a fresh
# install nginx cannot create its state paths itself. The unit's
# RuntimeDirectory=/LogsDirectory=/StateDirectory= entries create these on
# start (a missing ReadWritePaths= target aborts with 226/NAMESPACE),
# but the temp tree additionally needs the worker user as owner: the
# workers — not the root master — write the temp files.
install -d /var/log/openresty /var/run/openresty
install -d /var/lib/openresty/client_body_temp /var/lib/openresty/fastcgi_temp \
  /var/lib/openresty/proxy_temp /var/lib/openresty/scgi_temp /var/lib/openresty/uwsgi_temp
WORKER_USER="$({ /usr/local/openresty/nginx/sbin/nginx -V 2>&1 || true; } \
  | grep -oE -- '--user=[A-Za-z0-9_]{2,}' || true)"
WORKER_USER="${WORKER_USER#--user=}"
WORKER_USER="${WORKER_USER:-nobody}"
echo "  worker user: ${WORKER_USER}"
chown -R "$WORKER_USER" /var/lib/openresty

echo "10. Start gateway"
systemctl daemon-reload
systemctl enable --now mattermost-ssl-auth
openresty -t

echo "  smoke test: present the admin demo certificate"
# The demo client certs only exist under $SCRIPT_DIR when this run built
# the PKI; a re-run on an existing deployment (certs already in
# /etc/ssl/private) skips the build and has no local client certs.
if [ -f "$SCRIPT_DIR/certs/flo.crt" ]; then
  # The server cert is signed by the signing CA, so verify against the
  # full chain (signing + root) — root alone cannot validate it.
  SMOKE_CA="$(mktemp)"
  cat "$SCRIPT_DIR/ca/signing-ca.crt" "$SCRIPT_DIR/ca/root-ca.crt" > "$SMOKE_CA"
  curl -fsS --cacert "$SMOKE_CA" \
    --cert "$SCRIPT_DIR/certs/flo.crt" --key "$SCRIPT_DIR/certs/flo.key" \
    --resolve "${MM_FQDN}:443:127.0.0.1" "https://${MM_FQDN}/api/v4/users/me" \
    | python3 -m json.tool
  rm -f "$SMOKE_CA"
else
  echo "  (skipped: no demo client certs in $SCRIPT_DIR — verify $MM_FQDN with a trusted client certificate)"
fi

echo
echo "Demo installation done."
echo "  Add '${MM_FQDN}' to /etc/hosts pointing at this box."
echo "  Import a user PFX (certs/flo.pfx or certs/aze.pfx, empty password)"
echo "  into the browser, trust ca/root-ca.crt, and open ${MM_SITE_URL}"
