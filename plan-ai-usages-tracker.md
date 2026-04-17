# Plan — AI Usages Tracker (`usages.json` + connectors)

## Layer 1 — High-level architecture

### 1. New JSON format: `~/.cache/ai-usages-tracker/usages.json`

Multi-vendor, multi-account. Each entry carries a `vendor`
("claude", "codex", "gh-copilot"…) and an `account` (e.g. email).
Metrics is a typed array:

- **time-window**: `name`, `type:"time-window"`, `resetAt` (ISO),
  `windowDurationMinutes`, `usagePercent`
- **pay-as-you-go**: `name`, `type:"pay-as-you-go"`, `currentAmount`,
  `currency`

Per-entry metadata: `lastAcquiredOn`, `lastError`, `isActive`.

### 2. Connector protocol

A Swift `UsageConnector` protocol defines:
- `vendor: String`
- `func fetchUsages() async throws -> [VendorUsageEntry]`
- `func resolveActiveAccount() -> String?`

One concrete type per vendor. Only `ClaudeCodeConnector` is
implemented initially.

### 3. ClaudeCodeConnector — data sources

- **OAuth token**: macOS Keychain
  (`Claude Code-credentials` → `claudeAiOauth.accessToken`)
- **API**: `GET https://api.anthropic.com/api/oauth/usage`
  header `anthropic-beta: oauth-2025-04-20`
- **Active account**: `~/.claude.json`
  → `.oauthAccount.emailAddress`
- Produces 2 time-window metrics (`session`, `weekly`).

### 4. Dual locking strategy

Two independent locks protect different resources:

- **File lock** (POSIX `flock` on
  `~/.cache/ai-usages-tracker/usages.json.lock`): serializes
  read-merge-write cycles on the JSON file. Released in a
  `defer` block.
- **In-memory lock** (Swift `actor` or `NSLock`, one per
  connector instance): ensures at most one `fetchUsages` call
  in-flight per connector, guarding against slow APIs and
  HTTP 429.

### 5. Logging

Two log files under `~/.cache/ai-usages-tracker/`:

- `app.log` — poller lifecycle, scheduler ticks, file writes,
  lock acquisition/release.
- `claude-usages-connector.log` — API calls, account resolution,
  errors.

Configurable log level. Simple size-based rotation if feasible.

### 6. Scheduler (background task)

`UsagePoller` orchestrates registered connectors:
- Configurable interval (default 3 min).
- Aggregates results, acquires file lock, merges into
  `usages.json`.
- Runs in a detached Swift `Task`, compatible with the SwiftUI
  run-loop.

### 7. Integration with the menubar app

The existing app starts the poller on launch. This plan covers
the **data layer** (connector + JSON file) only, not UI.

### Architectural risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| Expired / missing OAuth token | No data | Cache fallback + `lastError` |
| Keychain permission denied | Silent failure | Explicit Keychain error handling, logged |
| Concurrent JSON writes | Corruption | POSIX flock on dedicated lock file |
| Anthropic API format change | Broken metrics | Resilient parser, typed error in `lastError` |
| Slow API / 429 rate-limit | Poller pile-up | In-memory lock per connector, one in-flight at a time |

---

## Layer 2 — Detailed impacts

### 2.1 JSON schema (`usages.json`)

```jsonc
{
  "usages": [
    {
      "vendor": "claude",
      "account": "user@example.com",
      "isActive": true,
      "lastAcquiredOn": "2026-04-17T10:00:00+00:00",
      "lastError": null,           // or { "timestamp": "…", "type": "…" }
      "metrics": [
        {
          "name": "session",
          "type": "time-window",
          "resetAt": "2026-04-17T15:00:00+00:00",
          "windowDurationMinutes": 300,
          "usagePercent": 42
        },
        {
          "name": "weekly",
          "type": "time-window",
          "resetAt": "2026-04-23T21:00:00+00:00",
          "windowDurationMinutes": 10080,
          "usagePercent": 8
        }
        // Future: { "name": "pay-as-you-go", "type": "pay-as-you-go",
        //           "currentAmount": 12.50, "currency": "USD" }
      ]
    }
  ]
}
```

Key decisions:
- `isActive` is set by the connector that owns the vendor (Claude
  connector reads `~/.claude.json`). Only one account per vendor
  is active at a time.
- `lastError` is `null` on success, an object on failure — same
  shape as ccstatusline but at the entry level, not per-metric.
- `windowDurationMinutes`: session = 300 (5 h), weekly = 10 080
  (7 d), derived from the API's window semantics, not from the
  response payload.

### 2.2 Swift model types

New file: `Sources/AIUsagesTrackers/Models/UsageModels.swift`

| Type | Role |
|------|------|
| `VendorUsageEntry` (Codable struct) | Top-level entry: vendor, account, isActive, lastAcquiredOn, lastError, metrics |
| `UsageMetric` (Codable enum with associated values) | `.timeWindow(name, resetAt, windowDurationMinutes, usagePercent)` / `.payAsYouGo(name, currentAmount, currency)` |
| `UsageError` (Codable struct) | `timestamp` + `type` (string) |
| `UsagesFile` (Codable struct) | Root wrapper: `usages: [VendorUsageEntry]` |

`UsageMetric` is encoded/decoded via a `type` discriminator field
so the JSON stays human-readable. A custom `CodingKeys` +
`init(from:)` / `encode(to:)` handles the polymorphism.

### 2.3 Connector protocol & Claude implementation

New file: `Sources/AIUsagesTrackers/Connectors/UsageConnector.swift`

```swift
protocol UsageConnector: Sendable {
    var vendor: String { get }
    func fetchUsages() async throws -> [VendorUsageEntry]
    func resolveActiveAccount() -> String?
}
```

New file: `Sources/AIUsagesTrackers/Connectors/ClaudeCodeConnector.swift`

This is a Swift `actor` (provides the in-memory lock for free):

| Responsibility | Detail |
|----------------|--------|
| `resolveActiveAccount()` | Read `~/.claude.json`, parse `.oauthAccount.emailAddress` |
| `fetchToken()` | Shell out to `security find-generic-password -s "Claude Code-credentials" -w`, parse JSON → `.claudeAiOauth.accessToken` |
| `fetchUsages()` | 1. Resolve active account. 2. Fetch token. 3. `URLSession` GET to Anthropic API. 4. Parse `five_hour` / `seven_day` → 2 `UsageMetric.timeWindow`. 5. Return `[VendorUsageEntry]`. |
| Error handling | On any failure: return entry with `lastError` set, metrics empty. Log to connector log. |

Because `ClaudeCodeConnector` is an `actor`, only one
`fetchUsages()` runs at a time — the in-memory lock requirement
is satisfied without explicit `NSLock`.

### 2.4 File persistence layer

New file: `Sources/AIUsagesTrackers/Persistence/UsagesFileManager.swift`

| Method | Behavior |
|--------|----------|
| `read() -> UsagesFile` | Acquire POSIX flock (shared), read + decode, release in `defer`. Return empty `UsagesFile` if file absent. |
| `merge(_: [VendorUsageEntry]) -> UsagesFile` | Takes existing file content + new entries. For each new entry, match on `(vendor, account)`: replace if found, append if new. Set `isActive` flag based on connector's `resolveActiveAccount()`. |
| `write(_: UsagesFile)` | Acquire POSIX flock (exclusive), encode + atomic-write (write to `.tmp` then rename), release in `defer`. |
| `update(with: [VendorUsageEntry])` | Convenience: `read → merge → write` in a single exclusive-lock scope. |

The flock operates on `~/.cache/ai-usages-tracker/usages.json.lock`
(separate from the data file) so readers don't block on partial
writes.

### 2.5 Logging

New file: `Sources/AIUsagesTrackers/Logging/Logger.swift`

A custom file-based logger writes to two on-disk log files:

| Logger instance | Subsystem | File |
|-----------------|-----------|------|
| `appLogger` | `ai-usages-tracker.app` | `~/.cache/ai-usages-tracker/app.log` |
| `claudeLogger` | `ai-usages-tracker.claude` | `~/.cache/ai-usages-tracker/claude-usages-connector.log` |

- Log level configurable via environment variable
  (`AI_TRACKER_LOG_LEVEL=debug|info|warning|error`, default `info`).
- Rotation: if file > 5 MB, rename to `.log.1` (keep only one
  backup). Checked at logger init and on each write.

### 2.6 Scheduler / poller

New file: `Sources/AIUsagesTrackers/Scheduler/UsagePoller.swift`

```
actor UsagePoller {
    let connectors: [any UsageConnector]
    let interval: Duration              // default .seconds(180)
    let fileManager: UsagesFileManager

    func start()   // launches a detached Task with a loop
    func stop()    // cancels the task
    func pollOnce() async  // single tick: fetch all → merge → write
}
```

`pollOnce` iterates connectors concurrently
(`withTaskGroup`), collects results, calls
`fileManager.update(with:)`. Logs each tick to `appLogger`.

### 2.7 App integration

Modified file: `Sources/AIUsagesTrackers/AIUsagesTrackersApp.swift`

- Add a `@State private var poller: UsagePoller` initialized with
  `[ClaudeCodeConnector()]` and default interval.
- Call `poller.start()` in an `.onAppear` or `.task` modifier.
- Wire `poller.stop()` to the Quit action.
- No UI changes beyond wiring the poller lifecycle.

### 2.8 File tree (new files only)

```
Sources/
├── AIUsagesTrackers/                  (library target)
│   ├── Models/
│   │   └── UsageModels.swift
│   ├── Connectors/
│   │   ├── UsageConnector.swift
│   │   └── ClaudeCodeConnector.swift
│   ├── Persistence/
│   │   └── UsagesFileManager.swift
│   ├── Logging/
│   │   └── Logger.swift
│   └── Scheduler/
│       └── UsagePoller.swift
└── App/                               (executable target)
    └── AIUsagesTrackersApp.swift
```
