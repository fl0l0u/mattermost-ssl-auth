# ADR 0002: Transparent 401 session-renewal intercept

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

Two complementary renewal mechanisms, both server-side, both invisible to
the browser:

1. **Proactive age-based renewal.** Every request checks the stored
   session's age against `SESSION_MAX_AGE_HOURS` (default 20). A session
   older than that is re-logged in while the user is still active. The
   old session stays valid during the switch, so the switchover is
   seamless; a failed renewal degrades to serving the existing session.
2. **Reactive 401 intercept.** When the upstream answers 401 for a
   `/api/v4/*` request (except `/api/v4/users/login` — a browser login
   attempt must never be retried), the proxy renews the session —
   lock-serialized, `:since`-stamped, and peer-aware, so N parallel 401s
   still cause exactly one login — and then **replays the original
   request** to the upstream with the renewed session, swapping the fresh
   response in for the 401. The browser never sees the 401 and therefore
   never client-side-logs-out. Swapped responses carry
   `X-Session-Renewed: 1` so the transparent renewal stays observable.

`/login` remains as a manual debug trigger.

## Consequences

* One extra Lua file (the filter), which serves as both the header and
  the body filter for the proxied locations; the body filter is a cheap
  no-op unless a swap is pending.
* Worst case (the renewal itself fails, e.g. Mattermost unreachable): the
  401 passes through unchanged and the user sees the login screen until
  the next request — degraded, but honest.
* Each user costs one login per `SESSION_MAX_AGE_HOURS` of activity, far
  under Mattermost's 5 rps login rate limit.
