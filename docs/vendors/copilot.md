# GitHub Copilot CLI

> **Last verified:** 2026-05-07 by @fcamblor on Copilot Individual (free-limited) plan

<!--
  Read `docs/VENDOR-PLUGIN-CONTRACT.md` first; it defines the shape of
  this document. If this file disagrees with the contract, the contract
  wins.
-->

## Endpoints

_verified: 2026-05-07_

| Method | URL | Headers | Timeout | Response Content-Type |
|--------|-----|---------|---------|-----------------------|
| GET    | `https://api.github.com/copilot_internal/user` | `Authorization: token <oauth>`, `Accept: application/json`, `Editor-Version: <vendor const>`, `Editor-Plugin-Version: <vendor const>`, `User-Agent: <vendor const>`, `X-Github-Api-Version: <vendor const>` | 5s | `application/json` |

The four "vendor const" headers are constants in
`Connectors/CopilotConstants.swift`; they impersonate the official VS
Code Copilot Chat extension closely enough to satisfy the
`copilot_internal/user` endpoint.

## Credential sources

_verified: 2026-05-07_

Cascade (read-only — the app never writes any of these):

1. `$GITHUB_TOKEN` environment variable.
2. macOS Keychain entry `gh:github.com` written by the `gh` CLI. Token
   may be raw, hex-encoded with `0x` prefix, or `go-keyring-base64:` +
   base64-encoded body — the locator handles all three shapes.
3. `gh` `hosts.yml`, searched in this order:
   - `$GH_CONFIG_DIR/hosts.yml` if set,
   - `$XDG_CONFIG_HOME/gh/hosts.yml` if set,
   - `~/.config/gh/hosts.yml`.

The active GitHub login is read from `hosts.yml` (`github.com.user`).
The token is per-user under `github.com.users.<login>.oauth_token` with
fallback to a host-level `github.com.oauth_token` for legacy configs.

The `gh` CLI owns lifecycle. The locator never calls `SecItemAdd`, never
invokes `gh auth login`, never writes any of these files.

## Sanitized fields

_verified: 2026-05-07_

Drives the leakage test in `Tests/Fixtures/copilot-full-payload.json`.

| Location | Field path | Redaction style |
|----------|-----------|-----------------|
| Header   | `Authorization` value | full removal (`<redacted>`) |
| Body     | any `*token*` / `*key*` / `*secret*` / `*password*` / `*credential*` key | full removal |
| Body     | `analytics_tracking_id` | full removal (vendor-issued opaque ID — telemetry session) |
| Body     | `login` | preserved (it IS the public account identity the user shares; not redacted) |
| Body     | any field whose value matches `[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+` | replace with `<email>` |

`login` is the GitHub username — it's the natural per-account identity
the rest of the app keys on, and it's already public via every git
commit. Redacting it would break the doc's usefulness without any
security benefit.

## Plan variants observed

_verified: 2026-05-07_

### Free / limited (verified by tester)

```jsonc
<!-- captured: 2026-05-07, plan: free_limited_copilot, login: redacted -->
{
  "login": "<redacted>",
  "access_type_sku": "free_limited_copilot",
  "analytics_tracking_id": "<redacted>",
  "assigned_date": "2026-05-06T14:16:33+02:00",
  "can_signup_for_limited": false,
  "chat_enabled": true,
  "copilotignore_enabled": false,
  "copilot_plan": "individual",
  "is_mcp_enabled": true,
  "organization_login_list": [],
  "organization_list": [],
  "restricted_telemetry": false,
  "endpoints": {
    "api": "https://api.individual.githubcopilot.com",
    "origin-tracker": "https://origin-tracker.individual.githubcopilot.com",
    "proxy": "https://proxy.individual.githubcopilot.com",
    "telemetry": "https://telemetry.individual.githubcopilot.com"
  },
  "limited_user_quotas": {
    "chat": 480,
    "completions": 4000
  },
  "limited_user_subscribed_day": 6,
  "limited_user_reset_date": "2026-06-06",
  "monthly_quotas": {
    "chat": 500,
    "completions": 4000
  }
}
```

`limited_user_quotas` carries the **remaining** count for each pool;
`monthly_quotas` carries the **total**. Connector computes
`used = total - remaining` and emits a percent.

### Pro / paid (assumed, not yet verified by tester)

The Pro plan exposes a `quota_snapshots` block with `percent_remaining`
fields, plus a single `quota_reset_date`. Expected shape:

```jsonc
<!-- captured: assumed, plan: copilot_individual_pro, login: redacted -->
{
  "login": "<redacted>",
  "copilot_plan": "individual_pro",
  "quota_reset_date": "2026-06-06",
  "quota_snapshots": {
    "premium_interactions": { "percent_remaining": 73, "unlimited": false },
    "chat":                 { "percent_remaining": 100, "unlimited": true }
  }
}
```

`unlimited: true` for a pool does NOT cause the metric to be skipped —
paid plans expose `premium_interactions` with `unlimited: true` (soft
monthly allowance, overage billed separately) where `percent_remaining`
remains the meaningful signal.

### Business / Enterprise plans (assumed, not yet verified by tester)

Likely populate `organization_list` and `organization_login_list` with
per-org entitlement records. `endpoints.api` may point at an enterprise
proxy. Quota fields shape unknown.

## Metric semantics

_verified: 2026-05-07_

| Swift metric | Source field | Reset cadence | Unit | Edge cases |
|--------------|--------------|---------------|------|------------|
| `.timeWindow("Premium")` | `quota_snapshots.premium_interactions.percent_remaining` / `quota_reset_date` | calendar monthly | percent | `unlimited: true` is NOT skipped; missing block → metric omitted |
| `.timeWindow("Chat")`    | `quota_snapshots.chat.percent_remaining` / `quota_reset_date` | calendar monthly | percent | same |
| `.timeWindow("Chat")`    | `(monthly_quotas.chat - limited_user_quotas.chat) / monthly_quotas.chat × 100` / `limited_user_reset_date` | calendar monthly | percent | free tier — emitted only when both blocks present |
| `.timeWindow("Completions")` | `(monthly_quotas.completions - limited_user_quotas.completions) / ...` / `limited_user_reset_date` | calendar monthly | percent | free tier |

Free-tier "Chat" and paid-tier "Chat" share the metric name on purpose —
the UI keys on vendor + name, and a single user is on exactly one tier
at a time, so there's no collision.

The synthetic 30-day window duration (`monthlyWindowMinutes = 30 * 24 *
60`) matches openusage's default — the API exposes only an absolute
reset date, not a window length.

## Time semantics

_verified: 2026-05-07_

- Reset values arrive as `yyyy-MM-dd` calendar dates:
  `"limited_user_reset_date": "2026-06-06"`.
- Connector promotes calendar dates to UTC midnight via
  `ISODate.parsingFlexibleDate(_:)`. This matters because the rest of the
  app expects a parseable ISO 8601 datetime — without normalization,
  calendar-only values would be silently dropped as "missing".

## Error catalog

_verified: 2026-05-07_

| Status   | Connector response |
|----------|--------------------|
| 200      | parse, emit metrics, refresh `lastKnownMetrics` |
| 401, 403 | surface `token_expired` (token expired/revoked or no Copilot entitlement) |
| 429      | preserve last-known metrics, mark active, surface `http_429` |
| other    | surface `http_<code>`; do not refresh metrics |

`identity_unresolved` is logged (no entry written) when the active login
cannot be determined from any source.

## Status page

_verified: 2026-05-07_

| URL | Format | Component filter |
|-----|--------|-----------------|
| `https://www.githubstatus.com/api/v2/incidents/unresolved.json` | statuspage.io v2 | component name contains `"copilot"` (case-insensitive) |

`CopilotStatusConnector` fetches unresolved incidents from the GitHub
status page and retains only those affecting a component whose name
contains `"copilot"` — this covers both the `"Copilot"` component and
`"Copilot AI Model Providers"`. Incidents that do not touch any
Copilot component are silently skipped so that unrelated GitHub
outages do not surface in the Copilot vendor pane.

Impact maps directly to `OutageSeverity` (`critical`, `major`, `minor`,
`maintenance`); the incident `shortlink` becomes the clickable href in
the UI.

## Known unknowns

- Copilot Pro response shape with active `quota_snapshots`.
- Behavior of `unlimited: true` pools beyond `premium_interactions` —
  whether `percent_remaining` is always meaningful or sometimes a fixed
  100.
- Business / Enterprise plan shapes (org-scoped seats).
- `analytics_tracking_id` rotation cadence — may need re-sanitization
  across snapshots if it stays stable enough to identify the session
  uniquely.

## Source references

- `openusage` Copilot connector — origin of the User-Agent / Editor-Version
  header impersonation pattern (https://github.com/openusage/openusage)
  (retrieved 2026-05-07).
- `gh` CLI source — `hosts.yml` schema and keychain layout
  (https://github.com/cli/cli) (retrieved 2026-05-07).
- Maintainer's own captures during development of `CopilotConnector`.

## Change log

- 2026-05-07 — initial capture: free-limited plan response shape,
  calendar-date reset semantics, three-source token cascade
  (env / keychain / hosts.yml), `go-keyring-base64:` decoding tolerance.
