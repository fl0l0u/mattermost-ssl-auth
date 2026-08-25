# Gitlab SSL Auth
## About The Project
Client certificate authentication to Gitlab-CE using OpenResty and Lua

![Product screenshot][preview]

This project replaces the Gitlab bundled Nginx with OpenResty

## Features

* Gitlab will now ask for a x509 certificate to generate and authenticate its users
* Users are provisioned at first connection (default configuration)
* Session cookies are never passed to the client, they are overwritten internally to prevent session theft

## Getting started
### Installation

Project directory tree under `src` reproduces the target deployment on a Ubuntu Server 22.04 system.

***TLDR**: Install OpenResty, Disable Gitlab Nginx, Copy stuff inside `src` directory according to its directory tree (i.e. `src/etc/bla` -> `/etc/bla`), Add **lua-resty-http** libs and Run the new systemd gitlab-ssl-auth.service.*

**Detailed installation:**
* Install [OpenResty][openresty]
* Replace default OpenResty Nginx config by `usr/local/openresty/nginx/conf/nginx.conf` 
* Configure SSL certificates for Nginx (default `/etc/ssl/private/`), modify it on nginx.conf if needed
* [Disable Gitlab bundled Nginx][disable-gitlab-nginx]. In /etc/gitlab/gitlab.rb set:
```ruby
nginx['enable'] = false
```
Then reconfigure Gitlab to stop its bundled Nginx
```bash
gitlab-ctl reconfigure
```
* Copy `opt/gitlab/runner.rb` in the Gitlab directory, or somewhere with read access for system user `git` (privilege needed to connect to `gitlab-workhorse` and `redis` unix sockets)
* Copy `etc/systemd/system/gitlab-ssl-auth.service` to systemd configuration directory
* Copy `usr/local/openresty/nginx/lua/` in OpenResty nginx lua directory (this directory is appended in [`nginx.conf`][nginx-conf-lua-dir])
* Adjust ACLs `chmod 644 /opt/gitlab/runner.rb`, `chmod -R 644 /usr/local/openresty/nginx/lua; chmod 755 /usr/local/openresty/nginx/lua /usr/local/openresty/nginx/lua/resty; chown -R git /usr/local/openresty/nginx/lua`;
* Install dependencies in OpenResty nginx lua library directory:
  * [lua-resty-http][lua-resty-http] (project developped with v0.17.1)
```bash
cd /usr/local/openresty/nginx/lua/ # cd into the lua modules directory
sudo mkdir resty
cd resty

sudo curl https://raw.githubusercontent.com/ledgetech/lua-resty-http/v0.17.1/lib/resty/http.lua -o http.lua
sudo curl https://raw.githubusercontent.com/ledgetech/lua-resty-http/v0.17.1/lib/resty/http_connect.lua -o http_connect.lua
sudo curl https://raw.githubusercontent.com/ledgetech/lua-resty-http/v0.17.1/lib/resty/http_headers.lua -o http_headers.lua
```
* Start Gitlab-runner service:
```bash
systemctl daemon-reload && systemctl enable gitlab-ssl-auth.service && systemctl start gitlab-ssl-auth.service
```
* Reload OpenResty config:
```
openresty -t && openresty -s reload
```

### Example

The [`example`](example) directory provides succints scripts (one based on [OpenSSL PKI Tutorial][openssl-pki-tuto]) to setup minimal SSL PKI and certificates to test the project.
* [build_certs.sh][script-cert]: Create a minimal PKI with one server and two users to test SSL certificate authentication.
* [demo_install.sh][script-install]: Deploys scripts and optionally install required `deb` packages to run a Gitlab-CE with SSL authentication (also calls above PKI generation script).

### Caveats

* The Client certificate `Subject` is parsed to populate `username` from `emailAddress` field and `display_name` from `CN` field. Only first `CN` field will be taken as `display_name` (i.e. objects like Active Directory builtin DA DN - *[`CN=Administrator, CN=Users, DC=...`][ms-adds-acnts]* - may not be parsed as expected).
* The [certificate `emailAddress` field is parsed to generate the `username`][username-parsing], `username@test.com` and `username@ext.test.com` will collide and the first user created will prevent the creation of the second.
* By default a certificate with a `Subject` including an `OU` named `Admins` will create an [admin user][admin-parsing]. Existing users will not see their privileges change.
* Deleting a user in Gitlab will not flush it's password in `redis` which is used to perform authentication. Connecting again with this user certificate will not recreate a new user (who was certainly deleted for a reason) unless an admin manually removes his cached password in `redis`
```bash
gitlab-redis DEL "x509auth:<username>:password"
```
* The `gitlab-ssl-auth` service is configured [with a dependency][svc-dependency] to `gitlab-runsvdir.service` aka the Omnibus bundled Gitlab service. If you are using another deployment method you should adapt this dependency

## License

Ditributed under Apache-2.0 License. See `LICENSE` for more information.

## Contact

Project Link: https://github.com/fl0l0u/gitlab-ssl-auth

[preview]: images/ssl-auth.png
[openresty]:            https://openresty.org/en/installation.html
[disable-gitlab-nginx]: https://docs.gitlab.com/omnibus/settings/nginx.html#using-a-non-bundled-web-server
[lua-resty-http]:       https://github.com/ledgetech/lua-resty-http
[openssl-pki-tuto]:     https://pki-tutorial.readthedocs.io/en/latest/#simple-pki
[ms-adds-acnts]:        https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/understand-default-user-accounts#administrator-account-attributes
[nginx-conf-lua-dir]: blob/master/src/usr/local/openresty/nginx/conf/nginx.conf#L92
[username-parsing]:   blob/master/src/usr/local/openresty/nginx/lua/gitlab_lib.lua#L45
[admin-parsing]:      blob/master/src/usr/local/openresty/nginx/lua/gitlab_lib.lua#L31
[svc-dependency]:     blob/master/src/etc/systemd/system/gitlab-ssl-auth.service#L4
[script-cert]:        blob/master/example/build_certs.sh
[script-install]:     blob/master/example/demo_install.sh