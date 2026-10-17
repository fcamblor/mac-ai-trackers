# Claude Desktop

> **Last verified:** 2026-10-17 by @fcamblor on Pro and Team plans

<!--
  Read `docs/VENDOR-PLUGIN-CONTRACT.md` first; it defines the shape of
  this document. If this file disagrees with the contract, the contract
  wins.

  This vendor shares the OAuth usage endpoint and response parsing with
  the `claude` vendor (see `docs/vendors/claude.md`). Only the credential
  source and the multi-account/multi-profile behaviour are specific to
  Claude Desktop; endpoint/metric/time semantics are documented in full in
  `claude.md` and only summarised here.
-->

## Endpoints

_verified: 2026-10-17_

| Method | URL | Headers | Timeout | Response Content-Type |
|--------|-----|---------|---------|-----------------------|
| GET    | `https://api.anthropic.com/api/oauth/usage` | `Authorization: Bearer <oauth>`, `anthropic-beta: oauth-2025-04-20` | 5s | `application/json` |
| GET    | `https://api.anthropic.com/api/oauth/profile` | `Authorization: Bearer <oauth>`, `anthropic-beta: oauth-2025-04-20` | 5s | `application/json` |

The usage endpoint is identical to the `claude` vendor; its response
additionally carries a `seven_day_breakdown` block (per-product shares)
that both connectors now consume — see Metric semantics.

The profile endpoint resolves the account behind a bearer. Its response is
`{ account: { uuid, email, full_name, … }, organization: { uuid, name }, … }`
(the email field is `email`). The connector calls it to turn each Desktop
profile bearer into the account's real email (see Account identity).

## Credential sources

_verified: 2026-10-17_

Read-only — the app never writes any of these, never mutates the Keychain,
and never runs the OAuth refresh flow.

Claude Desktop is an Electron app. Each profile directory holds a
`config.json` whose `oauth:tokenCacheV2` key is an Electron `safeStorage`
`v10` ciphertext (base64). The symmetric key lives in the macOS Keychain
under the generic-password service **`Claude Safe Storage`**.

Profile directory cascade (all existing directories are read):

1. `~/Library/Application Support/Claude` — default profile.
2. `~/Library/Application Support/Claude-3p` — secondary ("3p") profile the
   installer provisions.
3. Any custom directory the user opened via
   `open -n -a Claude.app --args --user-data-dir="<path>"`, configured in the
   Coding Assistants tab and stored under
   `ai-tracker.claudeDesktopProfilePaths`.

### Decryption

`v10` values decrypt with the Electron/Chromium scheme, fixed and not
version-negotiated here:

- key = `PBKDF2-HMAC-SHA1(password = <Keychain "Claude Safe Storage" value>, salt = "saltysalt", iterations = 1003, keyLength = 16)`
- cipher = `AES-128-CBC`, IV = 16 bytes of `0x20` (ASCII space), PKCS7 padding
- the 3-byte `v10` prefix is stripped before decryption

The decrypted `oauth:tokenCacheV2` is a JSON object keyed by strings of the
shape
`acct:<accountUuid>|<sessionUuid>:<orgUuid>:https://api.anthropic.com:<space-separated scopes>`.
Each value carries `token`, `refreshToken`, `expiresAt` (Unix millisecond
epoch), and `subscriptionType`. The connector keeps only entries whose key
contains the `user:inference` scope — a profile also stores a narrower
`user:profile`-only entry that cannot read the usage endpoint.

### Bootstrap / no-prompt rule (§9)

The `Claude Safe Storage` Keychain entry is **distinct** from the
`Claude Code-credentials` entry the `claude` vendor reads, and the user has
not pre-approved its ACL for the steady-state poll. Reading it with
`security … -w` therefore raises a macOS authorisation prompt the first
time.

To comply with `.claude/rules/swift-quality.md` §9, the whole source is
**opt-in**: while `ai-tracker.claudeDesktopEnabled` is false the connector
returns no entries and never calls the locator, so no Safe Storage read —
and no prompt — occurs. The first decryption happens only after the user
enables the source in the Coding Assistants tab (an explicit user action).
After the user approves the macOS ACL once ("Always Allow"), subsequent
background polls are silent.

### Active accounts

Unlike the `claude` CLI (a single active account), several Claude Desktop apps
can run at once — one per `--user-data-dir` — and a profile may be inactive
(no running instance). The connector marks an entry active when a Claude
Desktop main process (`…/Claude.app/Contents/MacOS/Claude`) is running against
that profile's directory: with `--user-data-dir=<dir>` for a custom profile, or
with no such flag for the default profile. Helper processes and the bundled
`…/MacOS/claude` CLI are excluded. Detection uses `/bin/ps` (no Keychain, no
network). Because this is per-profile and additive, the single-active-per-vendor
`updateIsActive` path is not used for this vendor; the connector stamps
`isActive` per entry directly.

### Account identity

Claude Desktop profiles do not store an account email in cleartext —
`config.json` only carries `lastKnownAccountUuid`, and the decrypted
token-cache keys embed the same `acct:<accountUuid>|…`. To make a Desktop
profile and a Claude Code login recognisable as the same account, the
connector resolves the **real account email** from `GET /api/oauth/profile`
and uses it as the account identity. This aligns with the `claude` vendor,
which already identifies accounts by `oauthAccount.emailAddress`: the same
person's Claude Code and Claude Desktop entries then share an `AccountEmail`
(distinct rows, since they are distinct vendors) and the UI can group them.

The accountUuid parsed from the token-cache key is the robust join key
(stable, shared with the CLI's `oauthAccount.accountUuid`) and is used to
**cache** the resolved email per account so the profile endpoint is hit at
most once per account per process.

Resolution falls back to the **profile directory name** (`Claude`,
`Claude-3p`, `Dentalsoft`, …) when the email cannot be fetched (no UUID,
expired token, or profile-endpoint failure). When a single profile holds
inference entries for more than one organisation, the fallback label is
disambiguated as `<profile> · <first 8 chars of orgUuid>`.

## Sanitized fields

_verified: 2026-10-17_

Drives the leakage test in `Tests/Fixtures/claude-desktop-full-payload.json`.

| Location | Field path | Redaction style |
|----------|-----------|-----------------|
| Header   | `Authorization` value | full removal (`<redacted>`) |
| Header   | `anthropic-beta` value | preserved (no secret) |
| Body     | any `*token*` / `*key*` / `*secret*` / `*password*` / `*credential*` key | full removal |
| Body     | any `*email*` key | full removal |
| Message  | `[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+` matches | replace with `<email>` |
| Message/Body | `sk-ant-…`, `anth_…` secret patterns | full removal |
| Message/Body | `v10<base64>` Electron safeStorage ciphertext | full removal |

The usage endpoint response carries no tokens or emails; the field-name
default-deny plus the `v10` pattern are defensive against a future code path
accidentally logging raw `config.json` material.

## Plan variants observed

_verified: 2026-10-17_

### Pro plan (verified)

Same response shape as the `claude` vendor's Pro capture, plus the
`seven_day_breakdown` block:

```jsonc
<!-- captured: 2026-10-17, plan: Pro, login: redacted -->
{
  "five_hour": { "utilization": 100.0, "resets_at": "2026-10-17T16:20:00+00:00" },
  "seven_day": { "utilization": 60.0, "resets_at": "2026-10-21T04:00:00+00:00" },
  "seven_day_breakdown": {
    "as_of": "2026-10-17T15:58:19+00:00",
    "window_started_at": "2026-10-14T04:00:00+00:00",
    "rows": [
      { "key": "claude_code", "display_name": "Claude Code", "percent": 0 },
      { "key": "chat", "display_name": "Chats", "percent": 3 },
      { "key": "cowork", "display_name": "Cowork", "percent": 97 },
      { "key": "other", "display_name": "Other", "percent": 0 }
    ]
  },
  "extra_usage": { "is_enabled": false }
}
```

### Team plan (verified)

Same shape; `five_hour`/`seven_day` present, `seven_day_breakdown` present.
Observed on a Team-plan profile run via a custom `--user-data-dir`.

## Metric semantics

_verified: 2026-10-17_

Windows (`five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus`) and
`extra_usage` map exactly as documented in `docs/vendors/claude.md`.

Additionally, each `seven_day_breakdown.rows[]` entry is emitted as:

| Swift metric | Source field | Reset cadence | Unit | Notes |
|--------------|--------------|---------------|------|-------|
| `.timeWindow("Weekly share · <display_name>")` | `seven_day_breakdown.rows[].percent` / `seven_day.resets_at` | weekly (10080 minutes) | percent | **Share** of the weekly consumption attributed to a product, not utilization of an independent limit. Emitted only when the `seven_day` window itself is present, sharing its reset date. Matches the "This week's usage by product" bars in the Claude Desktop UI. |

This breakdown parsing is shared: the `claude` (CLI) connector emits the
same rows when the endpoint returns them.

## Time semantics

Identical to `docs/vendors/claude.md`: ISO 8601 datetimes with sub-second
precision, normalised to whole-second ISO 8601 at the connector boundary.

## Error catalog

_verified: 2026-10-17_

| Source | Outcome | Connector response |
|--------|---------|--------------------|
| Preference | source disabled | return no entries; never read the Keychain |
| Locator | no profile directory found | return no entries |
| Locator | `Claude Safe Storage` read denied / times out | no entries this tick; prior accounts preserved in `usages.json` |
| Locator (per profile) | decrypt/parse failure | skip that profile, continue others |
| Connector (per account) | local expiry pre-check | surface `token_expired`; preserve that account's metrics; skip HTTP |
| HTTP | 200 | parse, emit metrics, refresh that account's metrics |
| HTTP | 401 | surface `token_expired`; preserve metrics |
| HTTP | 429 | surface `http_429`; preserve metrics |
| HTTP | other | surface `http_<code>` |

A disabled or temporarily unreadable source never removes previously-seen
accounts from `usages.json` (see `.claude/rules/usages-retention.md`).

## Status page

_verified: 2026-10-17_

**No dedicated status page.** Claude Desktop is served by the same Anthropic
platform as the `claude` vendor, whose `ClaudeStatusConnector` already
surfaces `https://status.claude.com` incidents. This vendor intentionally
omits the status slot (`status: nil`) to avoid duplicating every outage row
under a second vendor.

## Known unknowns

- Enterprise plan response shape — unverified.
- Whether `seven_day_breakdown` rows ever carry a per-product `resets_at`
  distinct from the weekly window — not observed; the connector reuses the
  weekly reset date.
- Refresh-token rotation behaviour if a token expires while Claude Desktop
  is closed — the connector never refreshes, so this is out of scope.

## Source references

- Electron `safeStorage` documentation
  (https://www.electronjs.org/docs/latest/api/safe-storage) (retrieved
  2026-10-17).
- Chromium OSCrypt key-derivation constants (`saltysalt`, 1003 iterations,
  AES-128-CBC) — public Chromium source (retrieved 2026-10-17).
- Maintainer's own captures during development of `ClaudeDesktopConnector`.

## Change log

- 2026-10-17 — initial capture: Electron `safeStorage` `v10` decryption of
  `oauth:tokenCacheV2`, multi-profile / multi-account support, opt-in gating
  for the `Claude Safe Storage` Keychain read, and shared `seven_day_breakdown`
  per-product parsing (also consumed by the `claude` connector).
- 2026-10-18 — resolve the real account email from `/api/oauth/profile` and
  use it as the account identity (cached per accountUuid) so Claude Desktop
  and Claude Code entries for the same account share an identity. Fall back to
  the profile label when resolution is not possible.
- 2026-10-18 — per-profile active detection via `/bin/ps` (several profiles may
  be active at once; some inactive). The popover merges the `claude` (CLI/TUI)
  and `claude-desktop` entries for one account — same Anthropic account, same
  usage — into a single card with a `tui` / `desktop` chip per auth source,
  each chip coloured by that source's own active state. Grouping is keyed on
  account *family* + email, so a Codex/Copilot login sharing an email is never
  merged with Claude. Same orange mark/tint as the `claude` vendor.
