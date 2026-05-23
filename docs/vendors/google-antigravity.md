# Google Antigravity

> **Last verified:** 2026-05-23 by @fcamblor on Antigravity Workspace plan

<!--
  Read `docs/VENDOR-PLUGIN-CONTRACT.md` first; it defines the shape of
  this document. If this file disagrees with the contract, the contract
  wins.
-->

## Endpoints

_verified: 2026-05-23_

| Method | URL | Headers | Body | Timeout | Response |
|--------|-----|---------|------|---------|----------|
| GET    | `https://www.googleapis.com/oauth2/v3/userinfo` | `Authorization: Bearer <token>` | — | 5s | identity claims |
| POST   | `https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` | `Authorization: Bearer <token>`, `Content-Type: application/json`, `User-Agent: antigravity` | `{"metadata":{"ideType":"ANTIGRAVITY","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}` | 5s | tier + project |
| POST   | `https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels` | same as above | `{"project":"<cloudaicompanionProject>"}` | 5s | model catalogue |
| POST   | `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` | same as above | `{"project":"<cloudaicompanionProject>"}` | 5s | per-model quota buckets |

The four endpoints form a chain:

- `userinfo` resolves the Google account identity (email, hosted domain).
- `loadCodeAssist` exposes the user's `currentTier.id` and the assigned
  `cloudaicompanionProject` — the latter is **mandatory** in the body of
  the next two endpoints. Without the `project` key, `retrieveUserQuota`
  silently returns `remainingFraction: 1` for every bucket regardless of
  real consumption (empirically verified — a tester with a model at
  100% consumed in the UI saw all-1.0 on the bare-body call).
- `fetchAvailableModels` returns the catalogue (`modelId → displayName`,
  `modelProvider`, `isInternal`). Its `quotaInfo.remainingFraction` is
  unreliable (sometimes absent when the value is 0); use it for the
  catalogue only.
- `retrieveUserQuota` is the **source of truth** for `remainingFraction`.

### Call cadence

- **Userinfo, loadCodeAssist, fetchAvailableModels**: called once at
  bootstrap and once per OAuth access-token refresh. The connector caches
  the resulting identity, project_id, and catalogue across polls — none
  of these change between two ticks on a healthy session.
- **retrieveUserQuota**: called on every poll tick. The lean payload
  (~15 buckets at ~150 bytes each) keeps logging cheap.

If a `retrieveUserQuota` bucket arrives with a `modelId` absent from the
cached catalogue, the connector triggers a one-off `fetchAvailableModels`
refresh to pick up the new model's `displayName`. Until the refresh
returns, the bucket is emitted with `modelId` as a fallback display
name.

## Credential sources

_verified: 2026-05-23_

Cascade (read-only — the app never writes any of these):

1. **macOS Keychain entry**, service `gemini`, account `antigravity`,
   written by the `antigravity` CLI. The keychain value is a UTF-8
   string of the form `go-keyring-base64:<base64>`; decoding the
   base64 yields a JSON document with this shape:

   ```jsonc
   {
     "token": {
       "access_token": "ya29.a0Ax...",
       "token_type": "Bearer",
       "refresh_token": "1//03r...",
       "expiry": "2026-05-22T20:50:02.146183+02:00"
     },
     "auth_method": "consumer"
   }
   ```

   The `gemini` service name is shared with other Google CLI tooling
   (Gemini CLI, Code Assist CLI). Filtering on `account=antigravity` is
   mandatory — without it the locator may pick up an unrelated token
   from a sibling Google CLI.

   `auth_method` value `consumer` has been observed on a Google
   Workspace account whose `userinfo.hd` reveals the workspace domain
   (`hd: "4sh.fr"` in the maintainer's capture). The `auth_method`
   field thus reflects the **OAuth client variant** the CLI used to
   sign in, not the Google account type. Tier detection happens via
   `loadCodeAssist` (see Plan variants).

2. **`ANTIGRAVITY_API_KEY` environment variable** — API-key alternative
   for CI / headless environments. The tracker reads it but does not
   currently call any Antigravity endpoint that accepts a raw API key
   (the `cloudcode-pa.googleapis.com` routes require an OAuth bearer).
   The locator surfaces `api_key_usage_unsupported` when only the env
   var is set, so the user gets an actionable diagnostic.

The `antigravity` CLI owns the full lifecycle of the keychain entry.
The locator never invokes `antigravity auth login`, never writes the
keychain entry, never refreshes the OAuth token.

### Bootstrap path

The boot path uses an attribute-only lookup
(`security find-generic-password -s gemini -a antigravity` with no
`-w` / `-g`) per `CLAUDE.md` "Bootstrap must not trigger Keychain
prompts". Secret data is read only inside the steady-state vendor poll
or in code paths the user explicitly initiates.

### Local expiry pre-check

Before each request, the locator parses `token.expiry` (RFC 3339 / ISO
8601 with sub-second precision and explicit offset). It short-circuits
with `AntigravityAuthError.tokenExpired` if `now()` is past the expiry
(60-second skew margin). A missing or unparseable `expiry` skips the
check and lets the HTTP layer surface a real 401 as `token_expired`.

### Active account identity

Resolved by calling `https://www.googleapis.com/oauth2/v3/userinfo`
with the OAuth bearer. The response shape (verified 2026-05-23):

```jsonc
{
  "sub": "103709611654083364164",
  "name": "Frédéric Camblor",
  "given_name": "...",
  "family_name": "...",
  "picture": "https://lh3.googleusercontent.com/...",
  "email": "user@example.com",
  "email_verified": true,
  "hd": "4sh.fr"
}
```

- `email` populates `AccountEmail`.
- `hd` (hosted domain, only present on Google Workspace accounts) feeds
  the plan-variant detection logic (see Plan variants).
- `name`, `picture`, `sub` are read but not surfaced beyond logs.

The userinfo result is cached for the lifetime of the OAuth access
token; the connector re-resolves it whenever the token changes.

### Account switches

A user signing out of the `antigravity` CLI and signing in with a
different Google account rewrites the keychain entry. The next OAuth
token refresh thus produces a fresh access token, and the next
`userinfo` call returns the new identity. The connector treats this
exactly like the framework treats any vendor's account change:

- The previously-active `VendorUsageEntry` is **kept** in `usages.json`
  with its last-known metrics (per the
  [usage retention rule](../../.claude/rules/usages-retention.md) —
  account entries are never deleted just because the connector stops
  observing them).
- A new `VendorUsageEntry` is appended for the new identity.
- The popover's active-account selector lets the user pick which entry
  is foregrounded; "ignoring" an inactive account remains an explicit
  user gesture, not an inferred state.

No dedicated `ActiveAccountMonitoring` slot is wired for this vendor:
the userinfo refresh is itself the identity-change signal, and account
switches surface at the next token-refresh boundary (typically within
~1 hour). The lag is acceptable because the keychain rewrite and the
CLI's own token refresh are coupled — re-invoking the CLI immediately
after a sign-in usually triggers both within seconds.

## Sanitized fields

_verified: 2026-05-23_

Drives the leakage test in `Tests/Fixtures/google-antigravity-full-payload.json`.

| Location | Field path | Redaction style |
|----------|-----------|-----------------|
| Header   | `Authorization` value | full removal (`<redacted>`) |
| Header   | `User-Agent` value | preserved (no secret) |
| Body (response, userinfo) | `email`, `name`, `given_name`, `family_name`, `picture`, `sub`, `hd` | full removal |
| Body (response, loadCodeAssist) | `cloudaicompanionProject` | full removal (Google Cloud project IDs are user-private) |
| Body (response, fetchAvailableModels) | any `*token*` / `*key*` / `*secret*` / `*password*` / `*credential*` key | full removal |
| Body (response, fetchAvailableModels) | any `*email*` key | full removal |
| Body (response, fetchAvailableModels) | `models.*.modelExperiments` | **full removal** — contains Antigravity's internal system prompts (planning templates, identity prompt referring to "Google DeepMind team", communication-style instructions). Not strictly secret but Google IP and ~5 KB per model entry, which would dwarf usage logs. |
| Body (response, fetchAvailableModels) | `models.*.supportedMimeTypes` | **full removal** — high-volume noise unrelated to usage; ~1 KB per model. |
| Body (response, retrieveUserQuota) | `buckets[].modelId` | preserved (public model identifier, needed for diagnosis) |
| Message  | `[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+` matches | replace with `<email>` |
| Message  | `ya29\.[A-Za-z0-9_-]+` matches | replace with `<token>` (defence against access tokens leaking through error strings) |
| Message  | `GOCSPX-[A-Za-z0-9_-]+` matches | replace with `<secret>` (defence against OAuth client secrets) |

The keychain JSON is never logged. The locator reads it and only
forwards the resulting access token to the HTTP request; payload-bearing
log entries contain Cloud Code responses with `modelExperiments` and
`supportedMimeTypes` stripped at the sanitizer boundary.

## Plan variants observed

_verified: 2026-05-23_

### Detection logic

The connector combines `loadCodeAssist.currentTier.id` with
`userinfo.hd` to label the plan:

| `currentTier.id` | `userinfo.hd` | Plan label |
|------------------|---------------|------------|
| `standard-tier` | (any)         | `Paid` |
| `free-tier`     | non-empty     | `Workspace` |
| `free-tier`     | empty         | `Free` |
| `legacy-tier`   | (any)         | `Legacy` |
| anything else   | (any)         | fallback to `currentTier.name` |

(Mapping cross-referenced with the upstream CodexBar Swift
implementation, which arrived at the same table independently.)

### Workspace plan (verified by tester)

Sanitized capture of `retrieveUserQuota` with `{"project":"<id>"}`
body. The maintainer's account is on `currentTier.id = "free-tier"`
with `userinfo.hd = "4sh.fr"`, classifying as `Workspace`.

```jsonc
<!-- captured: 2026-05-23, plan: Workspace, login: redacted -->
{
  "buckets": [
    { "tokenType": "WTUS", "modelId": "chat_20706",                  "remainingFraction": 1 },
    { "tokenType": "WTUS", "modelId": "chat_23310",                  "remainingFraction": 1 },
    { "tokenType": "WTUS", "modelId": "claude-opus-4-6-thinking",    "remainingFraction": 0,   "resetTime": "2026-05-29T23:44:13Z" },
    { "tokenType": "WTUS", "modelId": "claude-sonnet-4-6",           "remainingFraction": 0,   "resetTime": "2026-05-29T23:44:13Z" },
    { "tokenType": "WTUS", "modelId": "gemini-2.5-flash",            "remainingFraction": 0.4, "resetTime": "2026-05-29T23:24:10Z" },
    { "tokenType": "WTUS", "modelId": "gemini-2.5-flash-lite",       "remainingFraction": 0.4, "resetTime": "2026-05-29T23:24:10Z" },
    { "tokenType": "WTUS", "modelId": "gemini-2.5-flash-thinking",   "remainingFraction": 0.4, "resetTime": "2026-05-29T23:24:10Z" },
    { "tokenType": "WTUS", "modelId": "gemini-2.5-pro",              "remainingFraction": 0.4, "resetTime": "2026-05-29T23:24:10Z" },
    { "tokenType": "WTUS", "modelId": "gemini-3-flash",              "remainingFraction": 0.4, "resetTime": "2026-05-29T23:24:10Z" },
    { "tokenType": "WTUS", "modelId": "gemini-3-flash-agent",        "remainingFraction": 0.4, "resetTime": "2026-05-29T23:24:10Z" },
    { "tokenType": "WTUS", "modelId": "gemini-3.1-flash-image",      "remainingFraction": 0.4, "resetTime": "2026-05-29T23:24:10Z" },
    { "tokenType": "WTUS", "modelId": "gemini-3.1-flash-lite",       "remainingFraction": 0.4, "resetTime": "2026-05-29T23:24:10Z" },
    { "tokenType": "WTUS", "modelId": "gemini-3.1-pro-high",         "remainingFraction": 0.4, "resetTime": "2026-05-29T23:24:10Z" },
    { "tokenType": "WTUS", "modelId": "gemini-3.1-pro-low",          "remainingFraction": 0.4, "resetTime": "2026-05-29T23:24:10Z" },
    { "tokenType": "WTUS", "modelId": "gemini-3.5-flash-low",        "remainingFraction": 0.4, "resetTime": "2026-05-29T23:24:10Z" },
    { "tokenType": "WTUS", "modelId": "gemini-pro-agent",            "remainingFraction": 0.4, "resetTime": "2026-05-29T23:24:10Z" },
    { "tokenType": "WTUS", "modelId": "gpt-oss-120b-medium",         "remainingFraction": 0,   "resetTime": "2026-05-29T23:44:13Z" },
    { "tokenType": "WTUS", "modelId": "tab_flash_lite_preview",      "remainingFraction": 1 },
    { "tokenType": "WTUS", "modelId": "tab_jump_flash_lite_preview", "remainingFraction": 1 }
  ]
}
```

Key observations from this capture:

- Two distinct `resetTime` values are present, ~20 minutes apart, both
  ~7 days out: one shared by all Anthropic-proxied and OpenAI-proxied
  models, one shared by all Google-Gemini models. Different bucket
  alignment per upstream provider.
- All buckets sharing a given `resetTime` also share the same
  `remainingFraction` (`0` for the Anthropic/OpenAI bucket, `0.4` for
  the Gemini bucket). This is the expected pattern — see Metric
  semantics for the defensive split rule when it ever isn't the case.
- Buckets missing a `resetTime` (`chat_*`, `tab_*`) correspond to
  internal models (`isInternal: true` in `fetchAvailableModels`); they
  are filtered out before metric emission.
- The `tokenType` value `WTUS` (presumed acronym; meaning not
  documented by Google) appears uniformly on this capture. The
  connector does not currently filter on this field, but a future
  drift introducing a second `tokenType` per model would need explicit
  handling.

### Free plan (assumed, not yet verified by tester)

Expected to return the same `retrieveUserQuota` shape with a strictly
smaller `remainingFraction` ceiling per bucket and possibly a reduced
model set (Free tier likely excludes the Anthropic/OpenAI-proxied
entries). Google's published policy mentions ~20 agent requests per
day refreshing every 5h; this is the cohort our 5h cadence detection
covers, though the maintainer's Workspace capture did not exhibit it.

### Paid plan (assumed, not yet verified by tester)

`loadCodeAssist.currentTier.id == "standard-tier"` is the expected
signature; uses the same Cloud Code endpoints with higher quota
ceilings. Pending a paid-tier tester capture.

### Enterprise / Workspace variants

`currentTier.id` and `userinfo.hd` already cover the observed Workspace
variant. Google's "Enterprise Agent Platform" announced at I/O 2026 may
introduce a new tier id; until a tester capture surfaces it, the
fallback (`currentTier.name`) carries us through with a non-canonical
but readable label.

## Metric semantics

_verified: 2026-05-23_

### Bucket filtering

For each entry in `retrieveUserQuota.buckets`:

1. Skip if `resetTime` is absent (matches internal `chat_*` / `tab_*`
   buckets in the observed payload).
2. Look up `modelId` in the cached `fetchAvailableModels` catalogue:
   - If absent → trigger an async catalogue refresh and emit the
     bucket with `modelId` as the display name for this tick.
   - If found with `isInternal: true` → skip.
   - If found with an empty `displayName` → skip (non-user-facing
     model, e.g. `tab_flash_lite_preview`).

### Cohorting

After filtering, group the surviving buckets:

- **Primary cohort key**: `resetTime` (the stable identity of a bucket
  across polls).
- **Defensive sub-split**: within a same-`resetTime` group, if buckets
  carry **different** `remainingFraction` values, split into
  sub-cohorts by `remainingFraction`. This handles the (so far
  unobserved) case where Google would shard a same-reset bucket into
  uneven sub-buckets. In the common case (all members share one
  fraction), the split is a no-op.

### Per-cohort metric

Each cohort emits one `.timeWindow`:

| Field | Source |
|-------|--------|
| `usagePercent` | `(1 - remainingFraction) * 100` — exact (all members of a cohort share this value by definition; defensive split guarantees it) |
| `resetAt` | the cohort's `resetTime` |
| `windowDurationMinutes` | see "Window duration" below |
| `name` | `"<cadence label>"` or `"<cadence label> #<n>"` — see "Naming" below |
| `subtitle` | deduplicated display names of the cohort's members, in **reverse order of appearance** in the original `retrieveUserQuota.buckets` array (Google tends to list newer models last; reversing surfaces the most recent first), joined with `", "` |

### Window duration

The cohort's `windowDurationMinutes` is determined **at metric
creation time**, never recomputed thereafter. The data lives in
`usages.json` and survives restarts.

Algorithm on each tick:

1. Look up `usages.json` for an existing `.timeWindow` with the same
   `resetAt`.
2. **If found**: reuse its `windowDurationMinutes`. The cadence
   classification of a bucket is fixed for the bucket's lifetime — a
   weekly bucket observed when it has 3 hours left to live is still a
   weekly bucket.
3. **If not found**: classify by `delta = resetTime - now()`:
   - `delta < 6h` → `300` (5h cadence)
   - else → `10080` (weekly cadence)

The `< 6h` threshold gives a 1-hour grace beyond a genuine 5h bucket's
maximum lifetime. The pathological case ("cold start observes a
weekly bucket with `delta < 6h` left and misclassifies it as 5h")
persists only until that bucket resets — at the next reset, the new
`resetAt` is a fresh entry, classified correctly. Probability: ~3.5%
of the cold-start moments (6h out of 7d).

### Naming

The cadence label is derived from `windowDurationMinutes`:

- `300` → `"5h session"`
- `10080` → `"Weekly"`
- (future cadences would extend this table)

Cohorts are sorted by `(resetTime ascending, remainingFraction
ascending)` for deterministic numbering.

When a cadence label corresponds to **a single cohort** in the current
emit, the label is used as-is (no `#N` suffix). When **multiple
cohorts** share a cadence label (e.g. the two weekly buckets observed
on Workspace), they are disambiguated with `"#1"`, `"#2"`, … in
sort order.

### Subtitle generation

Within a cohort:

1. For each member bucket, look up the `displayName` in the
   `fetchAvailableModels` cache. If absent, use the raw `modelId`.
2. **Reverse** the cohort's member list (the original order in
   `retrieveUserQuota.buckets` is Google's order, generally
   alphabetical / by creation date — reversing surfaces newer
   model variants first, which are the ones the user is most likely
   actively using).
3. **Deduplicate** consecutive equal display names (this collapses the
   observed case where `gemini-pro-agent` and `gemini-3.1-pro-high`
   both display as `"Gemini 3.1 Pro (High)"`).
4. Join with `", "`.

### Example (from the Workspace capture above)

Two cohorts, both weekly cadence, two distinct `resetTime` values.
Sorted by `(resetTime asc)`:

- **#1**: `resetTime = 2026-05-29T23:24:10Z`, all `remainingFraction = 0.4`
  → `usagePercent = 60`, members reversed = `[gemini-pro-agent, gemini-3.5-flash-low, gemini-3.1-pro-low, gemini-3.1-pro-high, gemini-3.1-flash-lite, gemini-3.1-flash-image, gemini-3-flash-agent, gemini-3-flash, gemini-2.5-pro, gemini-2.5-flash-thinking, gemini-2.5-flash-lite, gemini-2.5-flash]`, deduped via displayName → 8 distinct names.
- **#2**: `resetTime = 2026-05-29T23:44:13Z`, all `remainingFraction = 0`
  → `usagePercent = 100`, members reversed = `[gpt-oss-120b-medium, claude-sonnet-4-6, claude-opus-4-6-thinking]` → 3 distinct names.

Emitted JSON (with `subtitle` and naming derived as specified):

```jsonc
[
  {
    "type": "timeWindow",
    "name": "Weekly #1",
    "usagePercent": 60.0,
    "resetAt": "2026-05-29T23:24:10Z",
    "windowDurationMinutes": 10080,
    "subtitle": "Gemini 3.1 Pro (High), Gemini 3.5 Flash (Medium), Gemini 3.1 Pro (Low), Gemini 3.1 Flash Lite, Gemini 3.1 Flash Image, Gemini 3.5 Flash (High), Gemini 3 Flash, Gemini 2.5 Pro"
  },
  {
    "type": "timeWindow",
    "name": "Weekly #2",
    "usagePercent": 100.0,
    "resetAt": "2026-05-29T23:44:13Z",
    "windowDurationMinutes": 10080,
    "subtitle": "GPT-OSS 120B (Medium), Claude Sonnet 4.6 (Thinking), Claude Opus 4.6 (Thinking)"
  }
]
```

### Retention (cleanup of expired metrics)

A `.timeWindow` metric whose `resetAt` is in the past is **not deleted
immediately**. Users benefit from seeing that they had a bucket which
expired some hours ago and has not been re-issued — that signals a
period of inactivity rather than a connector failure.

The cleanup rule (applied at merge time, on each tick):

- A persisted metric `M` whose `resetAt > now()` is **kept** and
  updated by the matching fresh metric (same `resetAt`).
- A persisted metric `M` whose `resetAt <= now()` is **kept until** a
  fresh metric `M'` in the current tick covers at least one of `M`'s
  members. "Covers" is computed as the set intersection of display
  names parsed from `M.subtitle` and `M'.subtitle` (split by `", "`).
- When the intersection is non-empty for any fresh `M'`, the expired
  `M` is dropped — the new bucket has taken its place.
- Expired metrics with no covering fresh metric remain visible. The
  UI's `isUnknown` logic naturally degrades their value to `???`
  once `resetAt` lapses.

This rule is **vendor-specific** to Antigravity; the framework's
default merge logic still applies to all other vendors.

## Time semantics

_verified: 2026-05-23_

- `buckets[].resetTime` values arrive as ISO 8601 datetimes in UTC
  with a `Z` suffix and no sub-second precision
  (`2026-05-29T23:44:13Z`). Strict ISO 8601 — parses directly via
  `ISODate.parsing(_:)`.
- `token.expiry` in the keychain JSON carries sub-second precision and
  a numeric offset (`2026-05-22T20:50:02.146183+02:00`); the locator
  parses it via `ISODate.parsingFlexibleDate(_:)`.

## Error catalog

_verified: 2026-05-23_

| Source | Outcome | Connector response |
|--------|---------|--------------------|
| Locator | `AntigravityAuthError.notLoggedIn` (no keychain entry, no env var) | surface `not_logged_in`; no metric refresh |
| Locator | `AntigravityAuthError.tokenExpired` (pre-check) | surface `token_expired`; preserve `lastKnownMetrics`; mark `isActive: true`; arm sticky auth-failure flag; skip HTTP entirely |
| Locator | `AntigravityAuthError.apiKeyOnlyUnsupported` | surface `api_key_usage_unsupported`; no metric refresh |
| Locator | `AntigravityAuthError.malformedKeychain` (envelope unparseable) | surface `token_error` with diagnostic |
| HTTP   | 200 | parse, emit metrics, refresh `lastKnownMetrics`, clear sticky auth-failure flag |
| HTTP   | 401 (`UNAUTHENTICATED`) | surface `token_expired`; preserve `lastKnownMetrics`; arm sticky auth-failure flag |
| HTTP   | 403 (`PERMISSION_DENIED`) | surface `permission_denied`; preserve `lastKnownMetrics`. Google returns 403 when the account lacks Cloud Code access (e.g. the user has not accepted the IDE EULA, or the `cloudaicompanionProject` is invalid). |
| HTTP   | 429 (auth-failure flag armed) | re-attribute to `token_expired`; preserve `lastKnownMetrics` |
| HTTP   | 429 (no recent auth failure) | surface `http_429`; preserve `lastKnownMetrics` |
| HTTP   | other | surface `http_<code>`; do not refresh metrics |
| Bootstrap | `loadCodeAssist` returns no `cloudaicompanionProject` | surface `bootstrap_failed`; the subsequent quota calls would return all-1.0 — better to refuse than mislead |

The 401 mapping is empirically verified: a stale token returns
`{"error":{"code":401,"message":"Request had invalid authentication
credentials. Expected OAuth 2 access token...","status":"UNAUTHENTICATED"}}`.

`lastKnownMetrics` is preserved across auth failures for the same
reason as the Claude Code connector: token expiry invalidates our
ability to refresh the numbers, not the numbers themselves.

## Status page

_verified: 2026-05-23_

No public status page — `status` slot left `nil` in the plugin bundle.

Google's `status.cloud.google.com` covers Google Cloud Platform
products but does not name Antigravity as a tracked service. Until
Google publishes a dedicated Antigravity status surface, incidents
remain unsignaled from the tracker; users rely on the connector's own
error catalog.

## Known unknowns

- The `auth_method` field of the keychain envelope was observed only as
  `"consumer"` — even on a Workspace-bound account. Other values
  (`"enterprise"`, `"workspace"`) hypothesized by reverse-engineered
  references have not been seen; tier detection happens via
  `loadCodeAssist` rather than this field.
- The `tokenType: "WTUS"` value's meaning is undocumented by Google.
  Whether a second `tokenType` per model could ever appear is unknown;
  the connector tolerates duplicates but does not filter on this
  field.
- The 5h cadence detection was not exercised on the Workspace capture
  (all observed `resetTime` values were weekly). The threshold and
  cohorting logic are inferred from the upstream openusage and CodexBar
  reference implementations + Google's policy blog post. A Free-tier
  tester capture would confirm.
- Cold-start misclassification of a weekly bucket as `"5h session"`
  when first observed with `delta < 6h` left. Self-heals at the next
  reset (~3.5% of cold-start moments).
- The retention rule's "covers at least one member" check relies on
  parsing the `subtitle` field by `", "`. If Google ever introduces a
  display name containing a literal `", "`, the parser would split it
  incorrectly. Observed display names so far use parenthesized
  qualifiers (e.g. `"Gemini 3.1 Pro (High)"`); none contain commas.
- No dedicated active-account monitor is wired. Identity is resolved
  from `userinfo` on each OAuth token refresh — that is the signal an
  account change is picked up by. Switches surface at the next
  token-refresh boundary rather than instantly; the prior identity's
  `VendorUsageEntry` is preserved in `usages.json` and a new entry is
  appended for the new identity. A future evolution could shorten the
  detection delay if a faster local signal (file-watch on an inspected
  path, etc.) is empirically validated, but the current behavior is
  intentional, not a gap.

## Alternative integration paths considered

A second integration path — talking to the local `language_server`
process Antigravity 2 spawns, instead of the OAuth + Google Code Assist
endpoints documented above — was investigated and **deferred**. The
local IPC surface returns useful identity / plan / global-credit data
but does not expose the per-model `remainingFraction` values that
drive the metrics in this connector, and its proto namespace is
inherited verbatim from Windsurf with no Antigravity-specific
stability guarantee. The investigation findings, RPC shapes,
discovery procedure, and the conditions under which the path would be
worth re-evaluating are kept in
[`google-antigravity-language-server.md`](./google-antigravity-language-server.md).

## Source references

- Antigravity CLI overview
  (https://antigravity.google/docs/cli-overview) (retrieved 2026-05-22)
- Antigravity pricing (https://antigravity.google/pricing) (retrieved
  2026-05-22)
- Antigravity plans (https://antigravity.google/docs/plans) (retrieved
  2026-05-22)
- Google I/O 2026 developer highlights blog post
  (https://blog.google/innovation-and-ai/technology/developers-tools/google-io-2026-developer-highlights/)
  (retrieved 2026-05-22)
- Google AI subscriptions blog post
  (https://blog.google/products-and-platforms/products/google-one/google-ai-subscriptions/)
  (retrieved 2026-05-22)
- Antigravity rate-limit policy blog post
  (https://blog.google/feed/new-antigravity-rate-limits-pro-ultra-subsribers/)
  (retrieved 2026-05-22)
- TechCrunch Antigravity 2.0 launch coverage
  (https://techcrunch.com/2026/05/19/google-launches-antigravity-2-0-with-an-updated-desktop-app-and-cli-tool-at-io-2026/)
  (retrieved 2026-05-22)
- Antigravity authentication-loop discussion (root-cause keychain entry)
  (https://discuss.ai.google.dev/t/resolved-authentication-required-loop-on-macos-root-cause-is-corrupted-keychain-entry-not-app-files/135744)
  (retrieved 2026-05-22)
- Antigravity CLI source
  (https://github.com/google-antigravity/antigravity-cli) (retrieved
  2026-05-22)
- Cross-references that informed the Cloud Code API surface and the
  OAuth credential envelope shape: openusage `antigravity` plugin
  (third-party reverse-engineering effort) and CodexBar
  `AntigravityRemoteUsageFetcher` (Swift reference implementation).
- Maintainer's own captures of `userinfo`, `loadCodeAssist`,
  `fetchAvailableModels`, and `retrieveUserQuota` on a Workspace
  account, 2026-05-23.

## Change log

- 2026-05-23 — initial capture. Endpoint chain `userinfo` (identity) +
  `loadCodeAssist` (tier + `cloudaicompanionProject`) +
  `fetchAvailableModels` (catalogue, cached) + `retrieveUserQuota`
  (poll-time source of truth, requires `{"project":"..."}` body). Two
  reset cadences expected (5h legacy + weekly recommended), only the
  weekly cohort observed in this capture. Cohorting by `resetTime`
  with defensive sub-split on heterogeneous `remainingFraction`.
  Cohort `windowDurationMinutes` is determined at metric creation
  (threshold `delta < 6h` → 5h, else weekly) and re-used across polls
  via the persisted `usages.json` entry — no in-memory cache, no
  reclassification mid-bucket. Multiple cohorts sharing a cadence
  label disambiguated by `#1`, `#2`. Subtitle = reverse-order
  deduplicated display names joined with `", "`. Retention rule keeps
  expired metrics until a fresh metric covers at least one of their
  members. Empirical 401 mapping to `token_expired` verified against a
  stale token. Sanitization strips `modelExperiments` (~5 KB system
  prompts per model) and `supportedMimeTypes` (~1 KB MIME map per
  model). Workspace plan verified (`free-tier` id + `hd: 4sh.fr`); Free
  / Paid / Enterprise variants remain assumed. No public status page —
  `StatusConnector` slot left `nil`. `ANTIGRAVITY_API_KEY` env var
  surfaced as `api_key_usage_unsupported`.
