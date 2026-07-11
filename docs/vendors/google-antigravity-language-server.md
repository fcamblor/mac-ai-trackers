# Google Antigravity — language_server investigation (deferred)

> **Status:** investigated, **not implemented**. The active connector for
> Antigravity is documented in `google-antigravity.md` and goes through
> the OAuth + Google Code Assist endpoints. This file records what was
> learned about an alternative local-IPC path so the investigation does
> not have to be redone if the trade-offs change.

<!--
  Read `docs/VENDOR-PLUGIN-CONTRACT.md` first; it defines the shape of
  vendor documentation. If this file disagrees with the contract, the
  contract wins. This file documents an alternative integration path
  that is not currently wired into a connector, so several contract
  sections (Error catalog, Sanitized fields, Plan variants observed)
  intentionally do not apply.
-->

## Why this path was investigated

The keychain-based OAuth path documented in `google-antigravity.md`
exhibits a hard practical limitation:

- The Antigravity 2 desktop app reads the keychain entry once at boot
  to obtain the OAuth refresh token, then performs the refresh flow and
  keeps the resulting access token **in process memory only** — it does
  not write the refreshed `access_token` / `expiry` back into the
  keychain entry. The keychain `mdat` therefore remains pinned to the
  last full re-login.
- A typical Google OAuth access token has a one-hour TTL. Within an
  hour of any keychain-side login event, the tracker's keychain read
  returns a bearer that Google rejects with HTTP 401, regardless of
  whether the Antigravity app itself is currently using the API
  successfully via its in-memory refreshed token.
- The tracker is strictly read-only on the keychain (see `CLAUDE.md`
  "Bootstrap must not trigger Keychain prompts" and §9 of
  `.claude/rules/swift-quality.md`), so it cannot run the refresh flow
  itself even if it wanted to: that would require the OAuth `client_id`
  / `client_secret` baked into the Antigravity binary, and using those
  would impersonate the official client.

This makes the keychain path useful only in the narrow window right
after a fresh `antigravity` CLI auth. To cover the much more common
case — Antigravity desktop running, keychain stale — an in-process IPC
path was investigated.

## Architecture discovered

Antigravity 2 spawns a Go binary `language_server` shipped inside
`Antigravity.app/Contents/Resources/bin/`. The binary exposes a
Connect-protocol HTTPS server on `127.0.0.1` with an auto-assigned port
and a self-signed certificate. The process is launched with arguments
of the form:

```
language_server --standalone \
                --override_ide_name antigravity \
                --subclient_type hub \
                --override_ide_version <version> \
                --override_user_agent_name antigravity \
                --https_server_port 0 \
                --csrf_token <uuid> \
                --app_data_dir antigravity \
                --api_server_url https://generativelanguage.googleapis.com \
                --cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com \
                --enable_sidecars
```

Key facts:

- `--https_server_port 0` means "auto-pick a free port"; the bound port
  is discovered by inspecting `lsof -p <pid> -iTCP -P` for the
  `LISTEN`-state socket on `127.0.0.1`.
- `--csrf_token <uuid>` is the value the server expects in the
  `x-codeium-csrf-token` request header. Without it, all RPC calls
  fail with an HTTP-level error.
- The certificate is self-signed; clients must either trust the local
  CA the language_server installs or skip TLS verification entirely
  (the openusage reference plugin does the latter via
  `dangerouslyIgnoreTls`).
- The RPC namespace is `exa.language_server_pb.LanguageServerService`,
  the `exa.` prefix being a Codeium / Windsurf heritage marker.
- The `cloud_code_endpoint` is the `daily-cloudcode-pa` host, not the
  public `cloudcode-pa` host the keychain-path connector talks to.
- Antigravity 2 currently shares ABI traits with Windsurf (the
  Codeium-acquired IDE that Google rebranded after acquisition). The
  proto namespace, header names, and CSRF discipline are direct
  carryovers. The shape is therefore unstable across Antigravity
  versions until the namespace is stabilised under a Google-owned name.

## Discovery procedure for connectors

1. Enumerate processes with `ps -axo pid,command` (no shell-out to
   `grep` — parse in-process). A line that ends with a path under
   `Antigravity.app/Contents/Resources/bin/language_server` and carries
   `--app_data_dir antigravity` identifies the target.
2. Parse the line for `--csrf_token <uuid>` and `--https_server_port`.
   The port flag is informational only — when set to `0`, the actual
   bound port must be obtained from `lsof -p <pid> -iTCP -P` filtered
   for `LISTEN`.
3. Issue the RPC call to `https://127.0.0.1:<port>/<rpc>` with
   `Content-Type: application/json`, the CSRF header, and a body of the
   form documented per-RPC below.

Because the port and CSRF token rotate on every Antigravity restart,
discovery must be repeated on each poll tick (or invalidated on RPC
failure).

## RPC surface

The binary exposes 88+ RPC methods under
`exa.language_server_pb.LanguageServerService`. The ones relevant for
usage tracking:

| Method | Body | Returns |
|--------|------|---------|
| `GetUserStatus` | `{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}` | identity, plan, global credits, recommended model list with `resetTime` |
| `GetAvailableModels` | same metadata envelope | full model catalogue with per-model `quotaInfo` |
| `GetCascadeModelConfigData` | same metadata envelope | recommended-model subset of the catalogue |
| `FetchUserInfo`, `GetAuthStatusRoundTripper` | unexplored | likely auth-state introspection |

### `GetUserStatus` response shape

```jsonc
{
  "userStatus": {
    "email": "<user>@<domain>",
    "name": "<display name>",
    "disableTelemetry": true,
    "acceptedLatestTermsOfService": true,
    "planStatus": {
      "planInfo": {
        "planName": "Pro",            // display label, free-form string
        "teamsTier": "TEAMS_TIER_PRO", // enum, see values below
        "monthlyPromptCredits": 50000,
        "monthlyFlowCredits": 150000,
        "monthlyFlexCreditPurchaseAmount": 25000,
        "canBuyMoreCredits": true,
        // ~15 capability flags (browserEnabled, cascadeWebSearchEnabled,
        // knowledgeBaseEnabled, hasTabToJump, etc.)
      },
      "availablePromptCredits": 500,    // remaining prompt credits this month
      "availableFlowCredits": 100       // remaining flow credits this month
    },
    "cascadeModelConfigData": {
      "clientModelConfigs": [
        {
          "label": "Claude Sonnet 4.6 (Thinking)",
          "modelOrAlias": { "model": "MODEL_PLACEHOLDER_M35" },
          "isRecommended": true,
          "supportsImages": true,
          "allowedTiers": ["TEAMS_TIER_PRO", "..."],
          "quotaInfo": { "resetTime": "2026-05-29T23:44:13Z" }
        }
        // ~7 entries (Recommended group)
      ],
      "clientModelSorts": [
        { "name": "Recommended", "groups": [{ "modelLabels": ["..."] }] }
      ]
    }
  }
}
```

### `GetAvailableModels` response shape

```jsonc
{
  "response": {
    "models": {
      "<modelId>": {
        "displayName": "Gemini 3.1 Pro (Low)",
        "model": "MODEL_PLACEHOLDER_M36",
        "maxTokens": 16384,
        "tokenizerType": "...",
        "apiProvider": "...",
        "isInternal": false,
        "quotaInfo": {
          "resetTime": "2026-05-29T23:24:10Z"
          // remainingFraction is OMITTED from the JSON when its value
          // equals the protobuf default (0). Empirically, fully-consumed
          // models and untouched models both serialise as
          // `{resetTime: ...}` with no remainingFraction field, making
          // the local API unable to distinguish "exhausted" from "full"
          // for user-facing models on at least the Pro tier.
        }
      },
      // ~15 user-facing models + ~4 internal (chat_*, tab_*) entries
    },
    "defaultAgentModelId": "...",
    "agentModelSorts": [{ "displayName": "Recommended", "groups": [{ "modelIds": ["..."] }] }],
    "commandModelIds": ["..."],
    "tabModelIds": ["..."],
    "imageGenerationModelIds": ["..."],
    "mqueryModelIds": ["..."],
    "webSearchModelIds": ["..."],
    "commitMessageModelIds": ["..."],
    "deprecatedModelIds": ["..."],
    "audioTranscriptionModelIds": ["..."],
    "tieredModelIds": [...],
    "experimentIds": [...]
  }
}
```

### `teamsTier` enum values

Extracted from the binary's string table:

- `TEAMS_TIER_UNSPECIFIED`
- `TEAMS_TIER_TRIAL`
- `TEAMS_TIER_WAITLIST_PRO`
- `TEAMS_TIER_PRO`
- `TEAMS_TIER_PRO_ULTIMATE`
- `TEAMS_TIER_TEAMS`
- `TEAMS_TIER_TEAMS_ULTIMATE`
- `TEAMS_TIER_ENTERPRISE_SAAS`
- `TEAMS_TIER_HYBRID`

`planName` is a free-form display string in the proto schema and may
differ from the tier label (`"Pro Ultimate"` vs
`TEAMS_TIER_PRO_ULTIMATE`). Plan-routing logic should key on
`teamsTier`, with `planName` reserved for display.

## Why deferred

1. **Per-model `remainingFraction` is unreachable from the local API.**
   The Antigravity Settings → Models pane shows fine-grained per-model
   quota bars (including "Model quota exhausted" badges), but the local
   RPC surface above does not expose that data. The desktop app
   obtains it from the same `retrieveUserQuota` endpoint the
   keychain-path connector talks to — using the OAuth token the
   `language_server` refreshes and holds in memory. There is no
   documented local RPC that returns the per-model fractions, and the
   protobuf default-omission behaviour makes the values that *are*
   exposed (`quotaInfo`) ambiguous between "untouched" and "fully
   consumed" for user-facing models. The local path therefore cannot
   reproduce what the keychain path delivers; at best it offers a
   complementary view (global Flow / Prompt credit pools).
2. **Antigravity 2 ABI is in flux.** The proto namespace, header
   conventions, and CSRF discipline are inherited verbatim from
   Windsurf. Until Google stabilises this surface under an Antigravity
   namespace, every Antigravity release is liable to shift the
   contract.
3. **Requires Antigravity to be running.** The whole IPC surface
   disappears the moment the desktop app quits. The keychain path, by
   contrast, can return last-known metrics with a `token_expired`
   diagnostic regardless of whether the app is open.
4. **Two-vendor exposure complicates the UI.** Exposing
   `antigravity-cli` and `antigravity-ui` as separate vendors would let
   the user see both readings simultaneously, but they would never
   agree (different metric domains: per-model quota fractions vs.
   global credit pools). Merging both signal sources into a single
   vendor entry would require a metric model the framework does not
   currently support.

## What would unblock implementation

- Either a stable local RPC that returns per-model `remainingFraction`,
  or a documented way for the tracker to obtain the Antigravity OAuth
  access token at its current refreshed value (without re-running the
  refresh flow with stolen client credentials).
- A version skew policy from Google for the `language_server` RPC
  surface, so the connector can pin to a known-good shape.

## Cached payload artifacts

Two raw payload captures from the maintainer's session are kept under
the workspace `.context/` directory (gitignored, not part of the
distribution):

- `antigravity-getuserstatus-local-ls.json` — `GetUserStatus` response
  on the Pro tier.
- `antigravity-getavailablemodels-local-ls.json` — `GetAvailableModels`
  response on the Pro tier.

Both still contain real account identifiers and must be re-sanitised
before being checked in as test fixtures.

## Source references

- openusage Antigravity plugin (`plugin.js` shipped under
  `~/Library/Application Support/com.sunstory.openusage/plugins/antigravity/`)
  — uses the same discovery procedure described above and falls back
  to the OAuth refresh path when the local API does not return enough
  signal.
- `Antigravity.app/Contents/Resources/bin/language_server` binary
  string table — source of the RPC name list and the `TEAMS_TIER_*`
  enum values.
