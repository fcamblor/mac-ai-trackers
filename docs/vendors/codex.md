# Codex (ChatGPT)

> **Last verified:** 2026-05-07 by @fcamblor on ChatGPT Plus plan

<!--
  Read `docs/VENDOR-PLUGIN-CONTRACT.md` first; it defines the shape of
  this document. If this file disagrees with the contract, the contract
  wins.
-->

## Endpoints

_verified: 2026-05-07_

| Method | URL | Headers | Timeout | Response Content-Type |
|--------|-----|---------|---------|-----------------------|
| GET    | `https://chatgpt.com/backend-api/wham/usage` | `Authorization: Bearer <oauth>`, `ChatGPT-Account-Id: <account_id>`, `User-Agent: OpenUsage` | 5s | `application/json` |

The `User-Agent: OpenUsage` value reproduces the header used by the
upstream `openusage` reverse-engineering effort and avoids bot filtering.

## Credential sources

_verified: 2026-05-07_

Cascade (read-only — the app never writes any of these):

1. `$CODEX_HOME/auth.json` if `CODEX_HOME` is set.
2. `~/.config/codex/auth.json`
3. `~/.codex/auth.json`
4. **macOS Keychain entry** `Codex Auth` (fallback when no auth file
   exists).

The `codex` CLI owns lifecycle for all sources. The locator never calls
`SecItemAdd`, never invokes `codex auth`, never writes any of these
files.

`auth.json` shape (only the fields the connector reads):

```jsonc
{
  "tokens": {
    "access_token": "<jwt>",
    "account_id": "user-...",
    "id_token": "<jwt>"
  },
  "last_refresh": "2026-05-07T00:00:00.000000Z"
}
```

The active account email is derived from JWT claims (`email` or
`https://api.openai.com/profile.email`) on `tokens.id_token` first, then
`tokens.access_token`. The `email` field also surfaces in the API
response itself and overrides the JWT-derived value at fetch time.

## Sanitized fields

_verified: 2026-05-07_

Drives the leakage test in `Tests/Fixtures/codex-full-payload.json`.

| Location | Field path | Redaction style |
|----------|-----------|-----------------|
| Header   | `Authorization` value | full removal (`<redacted>`) |
| Header   | `ChatGPT-Account-Id` value | full removal (account identifier the vendor treats as private) |
| Body     | any `*token*` / `*key*` / `*secret*` / `*password*` / `*credential*` key | full removal |
| Body     | any `*email*` key | full removal |
| Body     | `user_id`, `account_id` | full removal (account identifiers) |
| Message  | `[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+` matches | replace with `<email>` |

`user_id` and `account_id` look indistinguishable from each other in the
captured payload (same value); both are treated as private.

## Plan variants observed

_verified: 2026-05-07_

### Plus plan (verified by tester)

```jsonc
<!-- captured: 2026-05-07, plan: Plus, login: redacted -->
{
  "user_id": "<redacted>",
  "account_id": "<redacted>",
  "email": "<email>",
  "plan_type": "plus",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 30,
      "limit_window_seconds": 18000,
      "reset_after_seconds": 2473,
      "reset_at": 1778114717
    },
    "secondary_window": {
      "used_percent": 39,
      "limit_window_seconds": 604800,
      "reset_after_seconds": 1690,
      "reset_at": 1778113934
    }
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": null,
  "credits": {
    "has_credits": false,
    "unlimited": false,
    "overage_limit_reached": false,
    "balance": "0",
    "approx_local_messages": [0, 0],
    "approx_cloud_messages": [0, 0]
  },
  "spend_control": { "reached": false, "individual_limit": null },
  "rate_limit_reached_type": null,
  "promo": null,
  "referral_beacon": null
}
```

### Pro plan (assumed, not yet verified by tester)

Same shape as Plus. Tighter `limit_window_seconds` on `primary_window`
likely; `code_review_rate_limit` may be populated.

### Spark / Team / Enterprise plans (assumed, not yet verified by tester)

`additional_rate_limits` block expected to be populated with per-model
quotas: `[{"limit_name": "<model>", "rate_limit": {"primary_window": ...,
"secondary_window": ...}}]`. The connector emits a metric per
`limit_name × window`.

### Pay-as-you-go credits (assumed, not yet verified by tester)

`credits.has_credits: true` with `balance` as a numeric remaining
allowance. Connector subtracts from a hard-coded pool size
(`creditPoolTotal = 1000`) to emit a `.payAsYouGo("Credits used", ...)`
metric. Header fallback `x-codex-credits-balance` is consumed when the
body block is absent.

## Metric semantics

_verified: 2026-05-07_

| Swift metric | Source field | Reset cadence | Unit | Edge cases |
|--------------|--------------|---------------|------|------------|
| `.timeWindow("Session (5h)")` | `rate_limit.primary_window.used_percent` / `reset_at` | rolling, duration from `limit_window_seconds` (fallback 300 minutes) | percent | missing `used_percent` → metric omitted |
| `.timeWindow("Weekly (7d)")` | `rate_limit.secondary_window.*` | rolling, duration from `limit_window_seconds` (fallback 10080 minutes) | percent | same |
| `.timeWindow("Code Review (7d)")` | `code_review_rate_limit.primary_window.*` | weekly | percent | absent block → metric omitted |
| `.timeWindow("<limit_name> (5h)")` | `additional_rate_limits[i].rate_limit.primary_window.*` | rolling | percent | one per `limit_name` |
| `.timeWindow("<limit_name> Weekly (7d)")` | `additional_rate_limits[i].rate_limit.secondary_window.*` | weekly | percent | one per `limit_name` |
| `.payAsYouGo("Credits used", ..., currency: "credits")` | `credits.balance` (body) → `x-codex-credits-balance` (header) | n/a | credits | `has_credits: false` → metric omitted; balance clamped to ≥ 0 |

Window durations are returned in seconds via `limit_window_seconds`; the
connector divides by 60 and falls back to fixed values when the field is
absent or zero.

## Time semantics

_verified: 2026-05-07_

- Reset values arrive as **Unix epoch seconds**: `"reset_at": 1778114717`.
- Connector wraps with `Date(timeIntervalSince1970:)` and emits as ISO
  8601 via `ISODate(date:)`.

## Error catalog

_verified: 2026-05-07_

| Status | Connector response |
|--------|--------------------|
| 200    | parse, emit metrics, refresh `lastKnownMetrics`; if no known window block, surface `parse_error` |
| 401    | surface `token_expired`; no metric refresh |
| 429    | preserve last-known metrics, mark active, surface `http_429` |
| other  | surface `http_<code>`; do not refresh metrics |

`identity_unresolved` is logged (no entry written) when both the
response email and the cached email are missing — exceptional state where
the active account cannot be attributed.

## Known unknowns

- Pro plan response shape on a Pro-only account.
- Enterprise / Team plan shapes — `additional_rate_limits` content
  unverified.
- Live `credits.has_credits: true` payload with non-zero balance.
- `code_review_rate_limit` populated payload (any plan).
- Headers Codex returns on 429 (Retry-After cadence).

## Source references

- `openusage` upstream project — initial reverse engineering of the
  `wham/usage` endpoint (https://github.com/openusage/openusage) (retrieved
  2026-05-07).
- Maintainer's own captures during development of `CodexConnector`.

## Change log

- 2026-05-07 — initial capture: Plus plan response shape, Unix epoch
  reset semantics, `User-Agent: OpenUsage` header. Cascade order
  `$CODEX_HOME` → `~/.config/codex` → `~/.codex` → keychain.
