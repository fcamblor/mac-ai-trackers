# <Vendor display name>

> **Last verified:** YYYY-MM-DD by @<handle> on <plan name>

<!--
  This file is a dated snapshot of how the vendor's API behaves today.
  Read `docs/VENDOR-PLUGIN-CONTRACT.md` first — it defines the shape of
  this document. If the doc and the contract disagree, the contract wins.

  Every section that captures a payload, plan variant, or behavior carries
  its own `_verified: YYYY-MM-DD_` line. Sample payloads are prefixed with
  a comment carrying capture date and plan. Older payloads stay in place
  with a `(superseded by YYYY-MM-DD)` annotation — the drift trail matters.
-->

## Endpoints

_verified: YYYY-MM-DD_

| Method | URL | Headers | Timeout | Response Content-Type |
|--------|-----|---------|---------|-----------------------|
| GET    | `https://...` | `Authorization`, ... | 5s | `application/json` |

## Credential sources

_verified: YYYY-MM-DD_

Cascade order:

1. ...
2. ...
3. ...

Each source is owned by `<vendor-cli>`; the application only reads.

## Sanitized fields

_verified: YYYY-MM-DD_

Drives the leakage test in `Tests/Fixtures/<vendor>-full-payload.json`.

| Location | Field path | Redaction style |
|----------|-----------|-----------------|
| Header   | `Authorization` value | full removal (`<redacted>`) |
| Body     | `tokens.access_token` | full removal |
| Body     | `<email-pattern>` anywhere | replace with `<email>` |

## Plan variants observed

_verified: YYYY-MM-DD_

### Plan A (verified by tester)

Representative payload:

```jsonc
<!-- captured: YYYY-MM-DD, plan: <plan name>, login: redacted -->
{
  "...": "..."
}
```

### Plan B (assumed, not yet verified by tester)

...

## Metric semantics

_verified: YYYY-MM-DD_

| Swift metric | Source field | Reset cadence | Unit | Edge cases |
|--------------|--------------|---------------|------|------------|
| `.timeWindow(name: ..., ...)` | `<json path>` | rolling 5h / weekly / monthly calendar | percent | "unlimited" → no metric, null reset → emit with `resetAt: nil` |

## Time semantics

_verified: YYYY-MM-DD_

- Reset values arrive as: ISO 8601 datetime / Unix epoch seconds /
  `yyyy-MM-dd` calendar date.
- Connector promotes calendar dates to UTC midnight via
  `ISODate.parsingFlexibleDate(_:)`.

## Error catalog

_verified: YYYY-MM-DD_

| Status | Connector response |
|--------|--------------------|
| 401    | surface as `token_expired`; no metric refresh |
| 429    | preserve last-known metrics, mark active |
| 5xx    | surface as `http_<code>`; preserve last-known |

## Known unknowns

- ...

## Source references

- <link> (retrieved YYYY-MM-DD)
- <link> (retrieved YYYY-MM-DD)

## Change log

- YYYY-MM-DD — initial capture.
