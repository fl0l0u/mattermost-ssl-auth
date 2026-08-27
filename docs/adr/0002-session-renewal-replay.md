# ADR 0002: Session liveness check and cookie-jar hydration (access phase)

- Status: accepted
- Date: 2026-08-26
- Supersedes: the refresh decision of [ADR 0001](0001-login-only-session-store-refresh.md)

## Context

Three facts shape this design:

1. **The webapp never requests `/login`.** Mattermost uses client-side
   routing: when the browser's session dies, the SPA pushes `/login`
   client-side (`pushState`) — **no HTTP request to `/login` ever
   reaches the proxy**. A browser navigation to `/login` is only ever a
   human choice.
2. **A dead stored session kills the user's view.** The webapp's XHRs
   start answering 401, the SPA treats that as "user logged out" and
   client-side-logs-out. The user is stuck on the login screen even
   though the gateway holds a cached password that could re-log in
   invisibly. (ADR 0001's assumed failure mode — "the SPA sends the
   browser to `/login`" — never occurs: there is no `/login` request to
   answer.)
3. **The target OpenResty cannot do reactive work in filter or log
   phases.** OpenResty 1.31.1.1 (the apt package we support) disables
   the cosocket API in the `header_filter_by_lua*`, `body_filter_by_lua*`
   and `log_by_lua*` phases — verified empirically on the reference VM
   (resty.redis answers "API disabled in the context of the …"). The
   only filter-phase work that is legal is pure Lua over `ngx`. Any
   renewal — which needs Redis and a Mattermost API round trip — must
   happen in a phase with cosockets: the access phase, while the
   request is still in flight.

## Decision

One renewal mechanism, plus one filter:

1. **Access-phase session liveness check.** On the fast path (a stored
   session exists), `health_check()` runs in the access phase before
   the request is proxied. It never fails the request: it runs under
   `pcall` with a soft-fail flag, and a failure restores the pre-renewal
   session snapshot so the request proceeds with whatever was stored.
   Inside the check:
   * **Throttle** — at most one check per user per
     `SESSION_CHECK_INTERVAL_SECONDS` (default 60 s), claimed
     atomically via `lua_shared_dict` (`mmssl_sessions`).
   * **Age first** — a session older than `SESSION_MAX_AGE_HOURS`
     (default 20 h), or with a missing/unparseable age marker, is
     renewed without probing.
   * **Liveness probe** — otherwise `GET /api/v4/users/me` with the
     stored Bearer token: 200 → healthy, 401 → dead, anything else or
     a failed probe → unknown (the session is left alone).
   * **In-access renewal** — a stale or dead session is re-established
     synchronously under the per-email Redis lock. Under the lock the
     stored `since` marker is re-read: a peer that renewed while we
     waited (`get_since() >= t_probe`) wins and we skip; the lock is
     re-verified before the final store.
2. **Cookie-jar hydration (pure-Lua header filter).**
   `mattermost_cookie_hydration.lua` runs as `header_filter_by_lua_file`
   on `location /` (both the `:443` and the loopback test servers). It
   replaces the upstream's `Set-Cookie` headers with the stored
   `MMAUTHTOKEN`, `MMUSERID` and `MMCSRF`, carrying attributes that
   mirror Mattermost's own login response: `Path=/; Max-Age=2592000;
   SameSite=Lax`, `HttpOnly` on `MMAUTHTOKEN` only, `Secure` only when
   the gateway is served over TLS (the loopback http ingress must
   hydrate too). Pure Lua — no cosockets — hence phase-legal.
   * Why: the access hook only rewrites the outbound wire request, but
     the SPA decides "logged in" from `MMUSERID` in the browser's cookie
     jar. Without hydration a fresh browser boots on the login form even
     though every proxied request carries a live session. With it, a
     fresh browser boots straight into the logged-in app.
3. **`/login` remains a manual debug trigger** — a navigation there
   drops and re-logs in the session, then 302s to the `Referer`
   (same-origin only, else `/`). The webapp never requests it.

## Consequences

* **Worst case after a sudden invalidation** (revoke, server-side
  kill): up to one throttle interval (~60 s) of 401s, then a
  transparent in-access renewal — the token rotates under the user,
  with no navigation and no reload; the browser recovers on its next
  request or a refresh.
* **Probe cost:** at most one extra `GET /api/v4/users/me` per user per
  `SESSION_CHECK_INTERVAL_SECONDS` — negligible against Mattermost's
  rate limits.
* **Fresh browsers boot authenticated** (jar hydration); only
  `MMAUTHTOKEN` is HttpOnly, matching a normal Mattermost login —
  `MMUSERID`/`MMCSRF` remain script-readable for the SPA.
* **One shared dict** (`lua_shared_dict mmssl_sessions 1m`) holds the
  throttle; a missing or full dict degrades to unthrottled checks, not
  failures.
* **WebSocket Origin policy (Mattermost 11.10.1, probed
  experimentally):** the WS upgrade's `Origin` must equal the SiteURL —
  scheme+host case-insensitive, **port compared literally** (an
  explicit `:443` is rejected); an empty Origin is allowed. The access
  hook therefore normalizes the forwarded Origin to the SiteURL
  (`MATTERMOST_SITE_URL`) **only when the Origin's host matches the
  SiteURL's host** (any or absent port): same-origin pages are
  untouched (identical value), same-host non-default ports get the port
  fixed (what makes browser WebSockets work on the loopback test and
  demo ingresses, where the browser's explicit port would otherwise be
  rejected), and other hosts are left untouched so Mattermost rejects
  them with 403 — the cross-origin drive-by defense (attacker page +
  victim's auto-presented client cert/cookie opening a readable WS
  stream) is preserved; verified end-to-end through the proxy (101 +
  hello on the rewritten port, 403 on an attacker-host Origin).
* **Browser-verified** (Playwright, reference VM): fresh-browser cold
  start boots logged in (0×401 out of 47 requests); a server-side
  session revoke
  401s only inside the 60 s throttle window, then renews in-access
  (token rotated, no `/login`, no reload); a forced-stale age renews;
  two users exchange messages both directions with 0×401/0×5xx.

## Superseded intermediate designs

Both were implemented, verified to be infeasible on the target
OpenResty, and deleted:

* **Log-phase 401 renewal** — renew after the 401 response is sent, in
  `log_by_lua_file`. Deleted: the target OpenResty disables cosockets
  in the log phase, so it cannot renew at all.
* **Transparent 401 swap/replay** — renew and replay in the header/body
  filter so the browser never sees the 401. Deleted: it needs cosockets
  in the filter phases (disabled, same reason) or a content-phase
  reimplementation of the proxy (disproportionate).
