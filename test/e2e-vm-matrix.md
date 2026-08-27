# E2E VM probe matrix

Post-deploy verification of the gateway on the reference VM. This file is the
**single source of truth** for the 16-probe matrix: every verification round runs
exactly these probes, in this order, against the VM. No paraphrasing — probe 4 in
particular has drifted between rounds when carried only in task-prompt prose. If a
probe's expectation is wrong, fix this file with a dated note; do not fudge the run.

## Run policy

- Run **after EVERY deploy**.
- Run **twice** (two full rounds) if the gateway Lua logic changed.
- A **single round** is sufficient for config/packaging-only changes (conf tree,
  unit, .deb, env).

## VM preconditions

- Host: `<vm-ip>`, user `<VM_USER>`, password `<VM_PASS>`; use `sudo` where noted.
- OpenResty **1.31.1.1**; Mattermost **11.10.1** at `127.0.0.1:8065`.
- FQDN: `mattermost.example.test`.
- Client certs: `/root/pki-v3/example/certs/{flo,aze}.{crt,key}`.
- Run probes **as root** (the certs live under `/root` and are not readable by the
  <VM_USER> user).
- **Optional test seam** (probes touching `127.0.0.1:18443` — probe 3, and the
  18443 parts of probes 12, 13 and 15): since 0.1.3 the .deb no longer installs
  the seam (conffiles 5 → 4). Probes touching 18443 require the optional
  loopback test seam installed on the test machine — the reference VM keeps it
  as an unowned operator file (it survives upgrades; it is not in the package's
  file list). A machine without the seam runs the remaining probes (all rows
  minus their 18443 parts); the 18443 parts are skipped, not failed.

## WebSocket curl template

All WS probes (1–6) use this exact template; substitute `<port>`, the cert/key
pair, and the optional `-H` lines as noted per row. Do not change the flag set.

```bash
curl -sk -i -N --http1.1 --max-time 3 --cert <CERT> --key <KEY> \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' \
  [-H 'Origin: ...'] [-H 'X-Test-DN: ...'] \
  https://127.0.0.1:<port>/api/v4/websocket
```

Cert paths: `<CERT>/<KEY>` for flo = `/root/pki-v3/example/certs/flo.crt` /
`flo.key`; for aze = `/root/pki-v3/example/certs/aze.crt` / `aze.key`.

**18443 exception:** the test seam listens on plain HTTP
(`listen 127.0.0.1:18443;` — no `ssl`), so for probe 3 drop `--cert`/`--key`
and use the `http://` scheme (the DN arrives via `X-Test-DN`, not TLS).

## The 16 probes

| # | Probe | How (exact command) | Expected |
|---|-------|---------------------|----------|
| 1 | WS @18444, flo cert | `curl -sk -i -N --http1.1 --max-time 3 --cert /root/pki-v3/example/certs/flo.crt --key /root/pki-v3/example/certs/flo.key -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' https://127.0.0.1:18444/api/v4/websocket` | `101` (demo server, DN pin) |
| 2 | WS @18445, aze cert | `curl -sk -i -N --http1.1 --max-time 3 --cert /root/pki-v3/example/certs/aze.crt --key /root/pki-v3/example/certs/aze.key -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' https://127.0.0.1:18445/api/v4/websocket` | `101` |
| 3 | WS @18443, `X-Test-DN` (flo DN) | `curl -sk -i -N --http1.1 --max-time 3 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' -H 'X-Test-DN: emailAddress=flo@example.test,CN=flolou,OU=Admins,O=Example Org' http://127.0.0.1:18443/api/v4/websocket` (plain HTTP — see the 18443 exception above) | `101` (127.0.0.1 test seam) |
| 4 | @443, flo cert, WS upgrade headers + cross-origin `Origin` | `curl -sk -i -N --http1.1 --max-time 3 --cert /root/pki-v3/example/certs/flo.crt --key /root/pki-v3/example/certs/flo.key -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' -H 'Origin: https://attacker.example' https://127.0.0.1:443/api/v4/websocket` | **`403`** — THE security-critical same-host defense: cross-origin Origins pass through untouched and are rejected; the `403` is minted by the gateway. **Not** the w/o-Upgrade probe — a WS-path request with no `Upgrade` headers returns MM's `400 upgrade.app_error`, which is not a matrix row. |
| 5 | @443, flo cert, WS + same-host `Origin` | `curl -sk -i -N --http1.1 --max-time 3 --cert /root/pki-v3/example/certs/flo.crt --key /root/pki-v3/example/certs/flo.key -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' -H 'Origin: https://mattermost.example.test' https://127.0.0.1:443/api/v4/websocket` | `101` |
| 6 | @443, flo cert, WS, no `Origin` | `curl -sk -i -N --http1.1 --max-time 3 --cert /root/pki-v3/example/certs/flo.crt --key /root/pki-v3/example/certs/flo.key -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' https://127.0.0.1:443/api/v4/websocket` | `101` (no-Origin passthrough) |
| 7 | @443, flo cert, `GET /api/v4/users/me` | `curl -sk -i --cert /root/pki-v3/example/certs/flo.crt --key /root/pki-v3/example/certs/flo.key https://127.0.0.1:443/api/v4/users/me` | JSON with username `flo` |
| 8 | @443, aze cert, `GET /api/v4/users/me` | `curl -sk -i --cert /root/pki-v3/example/certs/aze.crt --key /root/pki-v3/example/certs/aze.key https://127.0.0.1:443/api/v4/users/me` | JSON with username `aze` |
| 9 | @443, aze cert, `GET /api/v4/users/me` (repeat) | `curl -sk -i --cert /root/pki-v3/example/certs/aze.crt --key /root/pki-v3/example/certs/aze.key https://127.0.0.1:443/api/v4/users/me` | JSON with username `aze` (lookup stability / idempotence) |
| 10 | @443, NO client cert, `GET /` | `curl -sk -i https://127.0.0.1:443/` (no `--cert`/`--key`) | `400` |
| 11 | @443, flo cert, `GET /` | `curl -sk -i --cert /root/pki-v3/example/certs/flo.crt --key /root/pki-v3/example/certs/flo.key https://127.0.0.1:443/` | `200` |
| 12 | HSTS header | `curl -sk -I https://127.0.0.1:443/` (also `http://127.0.0.1:18443/` and `https://127.0.0.1:18444/`) | `Strict-Transport-Security: max-age=63072000` **present** on 443; **absent** on 18443; **absent** on 18444 |
| 13 | `s_client` CertificateRequest | `echo \| openssl s_client -connect 127.0.0.1:443 -servername mattermost.example.test -msg 2>/dev/null \| grep -c CertificateRequest` (repeat against `18444`) | `CertificateRequest` **present** on 443 (count ≥ 1); **absent** on 18444 (count 0) |
| 14 | TLS 1.2 + TLS 1.3 handshakes | For each port in {443, 18444, 18445}: `echo \| openssl s_client -connect 127.0.0.1:<port> -tls1_2` **and** `... -tls1_3` | All 6 handshakes complete OK |
| 15 | `nginx -T` header expansion | `sudo /usr/local/openresty/nginx/sbin/nginx -T -c /etc/mattermost-ssl-auth/nginx.conf` | In the expanded output, each of the **4** servers carries **3** `proxy_set_header` in its WS location and **2** in its root location, and **8** `include .../proxy-common-headers.conf` lines (one per WS + root location) splice the shared 4 headers — effective **7** per WS location, **6** per root location (splice intact). `nginx -T` prints each included file only once under a `# configuration file` banner, so the shared 4 must not be expected inline at each splice site. |
| 16 | mmssl access log | `sudo tail -n 30 /var/log/openresty/access.log` | Recent lines well-formed — method, path, status, client IP, `cert_fp` present, DN present for pinned servers |

## Dated spec fixes

### 2026-08-27 — probes 3, 15, 16 corrected to match the deployed reality

Discovered running the matrix against the 0.1.3 .deb install (the first run
since the conf tree moved to `/etc/mattermost-ssl-auth/`):

- **Probe 3**: the test seam listens on plain HTTP (no `ssl` in the
  `listen` directive — probe 12 already used `http://` for it), so the
  shared https/cert template never applied: no `--cert/--key`, `http://`
  scheme. The `X-Test-DN` value must be in attribute form
  (`emailAddress=...,CN=...,OU=...`, as the README shows) — the old
  bare-email value (`flo@example.test`) is rejected by the gateway with
  400 ("DN does not contain an emailAddress attribute"). The corrected
  invocation returns `101`.
- **Probe 15**: bare `nginx -T` reads the openresty package default
  (`/usr/local/openresty/nginx/conf/nginx.conf`), which does not exist on
  a .deb-based deploy (conf tree lives at `/etc/mattermost-ssl-auth/`
  since the 0.1.1 rework). Use `-c /etc/mattermost-ssl-auth/nginx.conf`.
  Also: `nginx -T` prints each included file once under a
  `# configuration file` banner (not inline at each splice site), so the
  expectation now counts 3 (WS) / 2 (root) inline headers per server plus
  the 8 shared-include lines (effective 7/6).
- **Probe 16**: the mmssl access log is a file
  (`/var/log/openresty/access.log`), not on the journal —
  `journalctl -u mattermost-ssl-auth` carries only systemd + nginx
  stderr lines. Tail the file instead.

### 2026-08-27 — probe 14: use the `New, ...` line as the handshake-complete indicator

The SSL-Session block's `Protocol:` line is racy under the `echo |`
EOF style for TLS 1.3: the server's session ticket arrives
asynchronously after the handshake, and `s_client` can print the
SSL-Session block before it lands, so `Protocol:` does not reliably
reflect the negotiated version. Judge each handshake by the
`New, <ver>, Cipher is <cipher>` line (printed at handshake
completion) instead.

## Pass criteria

All 16 probes must match their expected result exactly. Any deviation is an
investigation, not a pass — a row that "almost matches" is a FAIL. If a probe's
expectation is wrong, fix this spec with a dated note rather than fudging the run.
