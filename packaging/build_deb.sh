#!/usr/bin/env bash
# Build dist/mattermost-ssl-auth_<VERSION>_all.deb from the repo tree.
# Requires dpkg-deb (package dpkg-dev on Debian/Ubuntu).
set -euo pipefail

cd "$(dirname "$0")/.."

package=mattermost-ssl-auth
version=$(cat VERSION)
pkg_dir="dist/pkg/$package"
out="dist/${package}_${version}_all.deb"

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "error: dpkg-deb not found — install dpkg-dev, or run on a Debian/Ubuntu host." >&2
  exit 1
fi

maintainer_name=$(git config user.name || true)
maintainer_email=$(git config user.email || true)
if [ -n "$maintainer_name" ] && [ -n "$maintainer_email" ]; then
  maintainer="$maintainer_name <$maintainer_email>"
else
  maintainer="Flo <flo@localhost>"
fi

rm -rf "$pkg_dir"
mkdir -p \
  "$pkg_dir/DEBIAN" \
  "$pkg_dir/usr/local/openresty/nginx/conf/includes" \
  "$pkg_dir/usr/local/openresty/nginx/lua" \
  "$pkg_dir/usr/local/openresty/nginx/test" \
  "$pkg_dir/etc/systemd/system" \
  "$pkg_dir/usr/share/doc/$package"

# --- payload -------------------------------------------------------------
install -m 644 \
  src/usr/local/openresty/nginx/conf/nginx.conf \
  "$pkg_dir/usr/local/openresty/nginx/conf/nginx.conf"

install -m 644 \
  src/usr/local/openresty/nginx/conf/includes/proxy-common-headers.conf \
  src/usr/local/openresty/nginx/conf/includes/server-443.conf \
  src/usr/local/openresty/nginx/conf/includes/server-test-18443.conf \
  "$pkg_dir/usr/local/openresty/nginx/conf/includes/"

install -m 644 \
  src/usr/local/openresty/nginx/lua/mattermost_ssl_auth.lua \
  src/usr/local/openresty/nginx/lua/mattermost_location_default.lua \
  src/usr/local/openresty/nginx/lua/mattermost_location_login.lua \
  src/usr/local/openresty/nginx/lua/mattermost_cookie_hydration.lua \
  src/usr/local/openresty/nginx/lua/mattermost_origin.lua \
  "$pkg_dir/usr/local/openresty/nginx/lua/"

install -m 644 test/origin_test.lua "$pkg_dir/usr/local/openresty/nginx/test/"

install -m 644 src/etc/systemd/system/mattermost-ssl-auth.service \
  "$pkg_dir/etc/systemd/system/"

# Ships the example values as a dpkg conffile (600, like
# example/demo_install.sh installs it); postinst refuses to start the
# service while the placeholders are in place.
install -m 600 src/etc/mattermost-ssl-auth.env.example \
  "$pkg_dir/etc/mattermost-ssl-auth.env"

# --- documentation ---------------------------------------------------------
install -m 644 LICENSE "$pkg_dir/usr/share/doc/$package/copyright"
printf '%s - %s\n' "$version" "$(date +%F)" \
  > "$pkg_dir/usr/share/doc/$package/changelog"
chmod 644 "$pkg_dir/usr/share/doc/$package/changelog"

# --- DEBIAN/ ----------------------------------------------------------------
sed -e "s/__VERSION__/$version/" \
    -e "s/__MAINTAINER__/$maintainer/" \
    packaging/debian/control > "$pkg_dir/DEBIAN/control"

install -m 755 \
  packaging/debian/postinst \
  packaging/debian/prerm \
  packaging/debian/postrm \
  "$pkg_dir/DEBIAN/"

( cd "$pkg_dir" && find . -type f -not -path './DEBIAN/*' -printf '%P\n' \
    | LC_ALL=C sort | xargs -r md5sum ) > "$pkg_dir/DEBIAN/md5sums"

# --- build -------------------------------------------------------------------
dpkg-deb --build --root-owner-group "$pkg_dir" "$out"
dpkg-deb --info "$out"
dpkg-deb --contents "$out"

rm -rf dist/pkg
echo "built: $out"
