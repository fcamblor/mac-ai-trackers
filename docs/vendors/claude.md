# Claude Code

> **Last verified:** 2026-05-07 by @fcamblor on Claude Code Pro plan

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

_verified: 2026-05-07_

Cascade (read-only — the app never writes any of these):

1. **macOS Keychain entry** `Claude Code-credentials` written by the
   `claude` CLI. Value is JSON of the form
   `{"claudeAiOauth":{"accessToken":"sk-ant-oat01-...","refreshToken":"...","expiresAt":...}}`.

The `claude` CLI owns the lifecycle. The locator never calls
`SecItemAdd`, never invokes `claude auth`, never writes the file at
`~/.claude.json`.

The active account email is read from `~/.claude.json` (`oauthAccount.emailAddress`).

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

_verified: 2026-05-07_

| Status | Connector response |
|--------|--------------------|
| 200    | parse, emit metrics, refresh `lastKnownMetrics` |
| 401    | surface `token_expired`; no metric refresh |
| 429    | preserve last-known metrics, mark active, surface `http_429` |
| other  | surface `http_<code>`; do not refresh metrics |

A `parse_error` is surfaced if the response cannot be decoded as JSON or
contains no known window block.

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
