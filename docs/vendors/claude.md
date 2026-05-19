# Claude Code

> **Last verified:** 2026-05-19 by @fcamblor on Claude Code Pro plan

<!--
  Read `docs/VENDOR-PLUGIN-CONTRACT.md` first; it defines the shape of
  this document. If this file disagrees with the contract, the contract
  wins.
-->

## Endpoints

_verified: 2026-05-07_

| Method | URL | Headers | Timeout | Response Content-Type |
|--------|-----|---------|---------|-----------------------|
| GET    | `https://api.anthropic.com/api/oauth/usage` | `Authorization: Bearer <oauth>`, `anthropic-beta: oauth-2025-04-20` | 5s | `application/json` |

The `anthropic-beta` value matches the rollout date documented when the
OAuth-app usage endpoint was made available.

## Credential sources

_verified: 2026-05-19_

Cascade (read-only — the app never writes any of these):

1. **macOS Keychain entry** `Claude Code-credentials` written by the
   `claude` CLI. Value is JSON of the form
   `{"claudeAiOauth":{"accessToken":"sk-ant-oat01-...","refreshToken":"...","expiresAt":1715000000000}}`.
   `expiresAt` is a Unix millisecond timestamp (Node.js `Date.now()`
   convention — Claude Code CLI is a Node/Bun program).

The `claude` CLI owns the lifecycle. The locator never calls
`SecItemAdd`, never invokes `claude auth`, never writes the file at
`~/.claude.json`. The locator also never performs the OAuth refresh
flow — if the access token has expired, the only way to get a new one
is for the user to invoke the `claude` CLI, which uses the stored
refresh token. **An access token whose owner stops using the CLI dies
within hours and stays dead until the CLI is invoked again** — see the
"Stale-token failure mode" section below.

### Local expiry pre-check

Before sending each request, the locator parses `expiresAt` from the
keychain JSON and short-circuits with `ClaudeAuthError.tokenExpired` if
the token is past its expiry (with a 60-second skew margin to avoid
racing the boundary). A missing or unparseable `expiresAt` skips the
local check and falls through to the HTTP layer — a real 401 then
surfaces as `token_expired` (see Error catalog).

This pre-check exists specifically to break the chronic 401→429 loop
described in the Stale-token failure mode below.

The active account email is read from `~/.claude.json` (`oauthAccount.emailAddress`).

## Stale-token failure mode

_verified: 2026-05-19_

A user who logs into the `claude` CLI once (typically to enable this
app) and then stops using the CLI exhibits a distinctive failure mode:

1. The keychain `accessToken` expires within hours (no refresh because
   the CLI is never invoked).
2. Subsequent calls to `/api/oauth/usage` return HTTP 401.
3. If the app keeps polling on the expired token (every 15s), Anthropic
   eventually switches from 401 to **HTTP 429** (rate_limit_error). The
   429 persists indefinitely as long as the polling continues — it is
   not a transient throttle, it is a downstream effect of the 401.
4. Without a sticky auth-failure flag, each 429 overwrites the
   connector's `lastError` to `http_429` and the actionable diagnostic
   ("token expired, re-run the CLI") is lost behind a misleading
   "rate limited" surface.

The fix has three pieces:

- **Locator-side pre-check.** Parsing `expiresAt` and short-circuiting
  with `tokenExpired` skips the HTTP call entirely when we already know
  the bearer is dead, which prevents the request that would have
  produced the 429 cascade in the first place.
- **Preserve `lastKnownMetrics` on `token_expired`.** Token expiry
  invalidates our ability to *refresh* the numbers, not the numbers
  themselves. A 5h session at 42% is still 42% — the user actually
  consumed that. Values whose window has not yet rolled stay accurate
  until their `resetAt`; once `resetAt` is in the past, the UI's
  `isUnknown` logic naturally degrades the row to `???` without any
  data wipe on our side.
- **Sticky auth-failure flag.** Once a 401 (or local `tokenExpired`)
  has fired, subsequent 429s are re-attributed to `token_expired` so
  the auth signal is not overwritten by the cascade. The flag clears
  on any HTTP 200.

The fix only addresses the diagnostic, not the root cause: the user
must still re-invoke the `claude` CLI for the OAuth refresh to happen.

## Sanitized fields

_verified: 2026-05-07_

Drives the leakage test in `Tests/Fixtures/claude-full-payload.json`.

| Location | Field path | Redaction style |
|----------|-----------|-----------------|
| Header   | `Authorization` value | full removal (`<redacted>`) |
| Header   | `anthropic-beta` value | preserved (no secret) |
| Body     | any `*token*` / `*key*` / `*secret*` / `*password*` / `*credential*` key | full removal |
| Body     | any `*email*` key | full removal |
| Message  | `[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+` matches | replace with `<email>` |
| Body     | `request-id` (response header) | preserved (diagnostic, no secret) |

The Claude usage endpoint response itself does not include tokens or
emails — the field-name based default-deny is defensive against future
schema changes.

## Plan variants observed

_verified: 2026-05-07_

### Pro plan (verified by tester)

```jsonc
<!-- captured: 2026-05-07, plan: Pro, login: redacted -->
{
  "five_hour": {
    "utilization": 50.0,
    "resets_at": "2026-05-07T00:29:59.571486+00:00"
  },
  "seven_day": {
    "utilization": 13.0,
    "resets_at": "2026-05-12T22:00:00.571503+00:00"
  },
  "seven_day_oauth_apps": null,
  "seven_day_opus": null,
  "seven_day_sonnet": {
    "utilization": 2.0,
    "resets_at": "2026-05-12T22:00:00.571510+00:00"
  },
  "seven_day_cowork": null,
  "seven_day_omelette": {
    "utilization": 0.0,
    "resets_at": null
  },
  "tangelo": null,
  "iguana_necktie": null,
  "omelette_promotional": null,
  "extra_usage": {
    "is_enabled": false,
    "monthly_limit": null,
    "used_credits": null,
    "utilization": null,
    "currency": null
  }
}
```

Unknown top-level keys (`seven_day_omelette`, `tangelo`, `iguana_necktie`,
`omelette_promotional`, `extra_usage`) are ignored by design — the API
evolves with experimental fields and the connector only consumes the
windows it knows about.

### Max plan (assumed, not yet verified by tester)

Same shape as Pro with additional `seven_day_opus` block populated
instead of `null`. To be confirmed by a tester running on Max.

### Free plan (assumed, not yet verified by tester)

Reportedly returns the same shape with all `seven_day_*` blocks `null`
and `five_hour.utilization` capped on a tighter quota.

## Metric semantics

_verified: 2026-05-07_

| Swift metric | Source field | Reset cadence | Unit | Edge cases |
|--------------|--------------|---------------|------|------------|
| `.timeWindow("5h sessions (all models)")` | `five_hour.utilization` / `five_hour.resets_at` | rolling 5-hour window (300 minutes) | percent | `resets_at: null` → emit with `resetAt: nil`; missing block → metric omitted |
| `.timeWindow("Weekly (all models)")` | `seven_day.utilization` / `seven_day.resets_at` | weekly (10080 minutes) | percent | same |
| `.timeWindow("Weekly Sonnet")` | `seven_day_sonnet.*` | weekly | percent | additive — absent → metric omitted |
| `.timeWindow("Weekly Opus")` | `seven_day_opus.*` | weekly | percent | additive — absent → metric omitted |

Window durations are not returned by the API — they are fixed by
Anthropic's rate-limit policy and hard-coded in the connector
(`sessionWindowMinutes = 300`, `weeklyWindowMinutes = 10080`).

## Time semantics

_verified: 2026-05-07_

- Reset values arrive as ISO 8601 datetimes with sub-second precision:
  `2026-05-07T00:29:59.571486+00:00`.
- Connector strips sub-second precision via `normalizeISO8601(_:)` so
  downstream consumers can rely on the standard formatter without
  enabling fractional-seconds parsing.

## Error catalog

_verified: 2026-05-19_

| Source | Outcome | Connector response |
|--------|---------|--------------------|
| Locator | `ClaudeAuthError.tokenExpired` (pre-check) | surface `token_expired`; preserve `lastKnownMetrics`; mark `isActive: true`; arm sticky auth-failure flag; skip HTTP entirely |
| Locator | other `ClaudeAuthError` (keychain missing / denied / parse) | surface `token_error` |
| HTTP   | 200 | parse, emit metrics, refresh `lastKnownMetrics`, clear sticky auth-failure flag |
| HTTP   | 401 | surface `token_expired`; preserve `lastKnownMetrics`; mark `isActive: true`; arm sticky auth-failure flag |
| HTTP   | 429 (auth-failure flag armed) | re-attribute to `token_expired`; preserve `lastKnownMetrics`; mark `isActive: true` |
| HTTP   | 429 (no recent auth failure) | surface `http_429`; preserve `lastKnownMetrics`; mark `isActive: true` |
| HTTP   | other | surface `http_<code>`; do not refresh metrics |

A `parse_error` is surfaced if a 200 response cannot be decoded as JSON
or contains no known window block.

`lastKnownMetrics` is intentionally **preserved** across auth failures:
an expired bearer means we can no longer refresh the data, but the
values we previously read are still semantically valid until their
window's `resetAt` naturally lapses. Wiping them would destroy
information that is still correct; instead the UI's `isUnknown` logic
collapses each metric to `???` on its own schedule (per-row), while
the `token_expired` error type drives any global "re-auth required"
banner.

## Status page

_verified: 2026-05-12_

| URL | Format | Component filter |
|-----|--------|-----------------|
| `https://status.claude.com/api/v2/incidents/unresolved.json` | statuspage.io v2 | none — all incidents on this page are Anthropic-specific |

`status.anthropic.com` 302-redirects to `status.claude.com`; the
connector points at the canonical destination so it does not depend on
`URLSession` following redirects.

`ClaudeStatusConnector` fetches unresolved incidents and surfaces any
incident whose `impact` is not `"none"`. Impact maps directly to
`OutageSeverity` (`critical`, `major`, `minor`, `maintenance`); the
incident `shortlink` becomes the clickable href in the UI.

## Known unknowns

- Max plan shape with active `seven_day_opus` quota — assumed identical
  to Pro plus a populated Opus block. Pending tester verification.
- Free plan shape — assumed Pro-shaped with reduced quotas. Pending
  tester verification.
- Enterprise / Team plans — completely unverified. Behavior unknown.
- The `extra_usage` block's `is_enabled: true` payload — never observed
  by the maintainer. Pending tester verification.

## Source references

- Anthropic API documentation, OAuth usage endpoint
  (https://docs.anthropic.com/) (retrieved 2026-05-07).
- Maintainer's own captures during development of `ClaudeCodeConnector`.

## Change log

- 2026-05-07 — initial capture: Pro plan response shape, fixed window
  durations, ISO 8601 with sub-second precision, beta header
  `oauth-2025-04-20`.
- 2026-05-19 — documented `expiresAt` keychain field (Unix ms epoch),
  added local expiry pre-check in the locator and explicit
  `token_expired` mapping for both the pre-check and HTTP 401.
  `lastKnownMetrics` is preserved across auth failures (data validity
  is independent of token validity — the UI's `isUnknown` logic
  handles per-row staleness on `resetAt` lapse). A sticky
  auth-failure flag re-attributes subsequent 429s to `token_expired`
  until a successful 200 disarms it, preventing the chronic 401→429
  cascade from masking the auth diagnostic. Documented the
  Stale-token failure mode that motivated the change.
