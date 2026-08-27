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

## The 16 probes

| # | Probe | How (exact command) | Expected |
|---|-------|---------------------|----------|
| 1 | WS @18444, flo cert | `curl -sk -i -N --http1.1 --max-time 3 --cert /root/pki-v3/example/certs/flo.crt --key /root/pki-v3/example/certs/flo.key -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' https://127.0.0.1:18444/api/v4/websocket` | `101` (demo server, DN pin) |
| 2 | WS @18445, aze cert | `curl -sk -i -N --http1.1 --max-time 3 --cert /root/pki-v3/example/certs/aze.crt --key /root/pki-v3/example/certs/aze.key -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' https://127.0.0.1:18445/api/v4/websocket` | `101` |
| 3 | WS @18443, aze cert + `X-Test-DN` | `curl -sk -i -N --http1.1 --max-time 3 --cert /root/pki-v3/example/certs/aze.crt --key /root/pki-v3/example/certs/aze.key -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==' -H 'X-Test-DN: flo@example.test' https://127.0.0.1:18443/api/v4/websocket` | `101` (127.0.0.1 test seam) |
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
| 15 | `nginx -T` header expansion | `sudo /usr/local/openresty/nginx/sbin/nginx -T` | In the expanded output, `proxy_set_header` count = **7** in each WS location and **6** in each root location, across **all 4 servers** (shared-include splice intact) |
| 16 | `journalctl` mmssl access log | `sudo journalctl -u mattermost-ssl-auth --no-pager --since '10 min ago' \| tail -n 30` | Recent lines well-formed — method, path, status, client IP, `cert_fp` present, DN present for pinned servers |

## Pass criteria

All 16 probes must match their expected result exactly. Any deviation is an
investigation, not a pass — a row that "almost matches" is a FAIL. If a probe's
expectation is wrong, fix this spec with a dated note rather than fudging the run.
