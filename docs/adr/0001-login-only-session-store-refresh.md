# ADR 0001: Refresh the session store only at first login and /login renewal

> **Superseded by [ADR 0002](0002-session-renewal-replay.md)** — the webapp never requests /login (client-side routing); session liveness is now checked in the access phase.

- Status: superseded by ADR 0002
- Date: 2026-08-25

## Context

Mattermost sets its session cookies — `MMAUTHTOKEN`, `MMUSERID`, `MMCSRF` —
only in **login responses**, and only for **XHR requests** (requests
carrying `X-Requested-With: XMLHttpRequest`). A plain browser navigation
never receives fresh session cookies: the SPA reuses whatever it already
holds. The successful login response also carries a `Token` response
header whose value equals the `MMAUTHTOKEN` cookie value.

Because the browser is never allowed to hold Mattermost session material,
the gateway cannot rely on client-carried cookies. It must replay the
session server-side on **every** forwarded request: the stored cookies in
`Cookie`, plus `Authorization: Bearer <token>` and `X-CSRF-Token` derived
from the stored `MMCSRF`.

This ADR settles the remaining question: when does the gateway
re-authenticate against Mattermost to pick up rotated cookies?

## Decision

The stored session is refreshed at exactly two points:

1. **First login** — no stored session exists for the user's email. The
   gateway resolves a working password (provisioning or repairing the
   account via the admin API as needed), calls `/api/v4/users/login`, and
   stores the returned cookies plus the `Token` header value in Redis.
2. **`/login` renewal** — the browser navigates to `/login`. The gateway
   drops the stored session and re-logs in with the cached (or repaired)
   password.

Every other request overwrites `Cookie`, `X-CSRF-Token` and
`Authorization` from the store without any re-login. The gateway
performs **no response-header filtering**: it does not inspect or rewrite
Mattermost responses to harvest fresh cookies. This keeps the
implementation a 3-file architecture (core library + two location hooks),
matching the original gitlab-ssl-auth layout.

## Consequences

* **Safe failure mode.** If the server-side token ever rotates
  mid-session (e.g. Mattermost invalidates it), the webapp answers 401;
  the SPA sends the browser to `/login`, which hits the renewal path and
  re-logs in with the cached password. A stale session degrades into a
  transparent re-login instead of a broken state.
* **Simpler code.** No per-response cookie harvesting and no header
  rewriting on the proxy path; the hot path is a Redis read plus a header
  overwrite.
* **Sessions survive gateway restarts** because the session store lives
  in Redis, not in the gateway's memory.
* **Accepted trade-off.** Between two refresh points the gateway replays
  a session that Mattermost may already consider stale; correctness is
  restored by the 401 → `/login` loop above rather than by keeping the
  session continuously fresh.
