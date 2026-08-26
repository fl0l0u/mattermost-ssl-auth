# ADR 0002: 401 session renewal — proactive age-based + reactive log-phase

- Status: accepted
- Date: 2026-08-26
- Supersedes: the refresh decision of [ADR 0001](0001-login-only-session-store-refresh.md)

## Context

The Mattermost webapp uses client-side routing. When the browser's session
dies, the SPA pushes `/login` on the client side (`pushState`) — **no HTTP
request to `/login` ever reaches the proxy**. A browser navigation to
`/login` is only ever a human choice, so the login-only refresh of ADR
0001 can never trigger reliably as a session-renewal mechanism.

What actually happens with a dead stored session is worse: the webapp's
XHRs start answering 401, the SPA treats that as "user logged out" and
client-side-logs-out — the user is stuck on the login screen even though
the gateway holds a cached password that could re-log in invisibly. ADR
0001's assumed failure mode ("the webapp answers 401; the SPA sends the
browser to `/login`") never occurs: there is no `/login` request to
answer.

## Decision

Two complementary renewal mechanisms, both server-side:

1. **Proactive age-based renewal.** Every request checks the stored
   session's age against `SESSION_MAX_AGE_HOURS` (default 20). A session
   older than that is re-logged in while the user is still active. The
   old session stays valid during the switch, so the switchover is
   seamless; a failed renewal degrades to serving the existing session.
2. **Reactive 401 renewal (log phase).** When the upstream answers 401
   for a `/api/v4/*` request (except `/api/v4/users/login` — a browser
   login attempt must never be retried), the log-phase handler
   re-establishes the session immediately **after** the response has been
   sent to the client — lock-serialized, `:since`-stamped, and
   peer-aware, so N parallel 401s still cause exactly one login. The
   browser may have seen that single 401 (the SPA may briefly show its
   login screen); because the session is re-established immediately, the
   NEXT request — the SPA fires more XHRs, the user refreshes, or a
   full-page `/login` hits the renewal hook — succeeds without any user
   action beyond a refresh in the worst case.

**Why no transparent swap.** A "the browser never sees the 401" design
needs the cosocket API in the header/body filter phases to renew and
replay in flight. The target OpenResty (1.31.1.1, the apt package we
support) disables cosockets in those phases — verified empirically
(`API disabled in the context of the header_filter_by_lua*` from
`resty.redis`). A transparent replay would instead have to run in the
content phase and reimplement the proxy there, which was deemed
disproportionate. Proactive renewal is what keeps the experience
invisible in normal operation; the reactive path is the backstop for a
sudden session death.

`/login` remains as a manual debug trigger.

## Consequences

* One extra Lua file, wired as `log_by_lua_file` in the proxied
  locations; it does nothing unless the upstream just answered 401.
* The browser can see a single 401 after a sudden session invalidation;
  the SPA may briefly show its login screen. Recovery is the next
  request, a refresh, or a full-page `/login`.
* Worst case (the renewal itself fails, e.g. Mattermost unreachable):
  nothing is re-established; the next request 401s again and the renewal
  is retried — degraded, but honest.
* Each user costs one login per `SESSION_MAX_AGE_HOURS` of activity, far
  under Mattermost's 5 rps login rate limit.
