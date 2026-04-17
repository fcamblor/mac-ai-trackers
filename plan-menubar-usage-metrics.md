# Plan — Menubar usage metrics display

## Layer 1 — Structural overview

### Architecture

Three new modules sit between the existing `App` layer and the external
JSON file, following a unidirectional data flow:

```
usages.json ──► FileWatcher ──► UsageStore (@Observable) ──► MenuBarExtra label
```

The app remains **menubar-only** (`.accessory` activation policy, single
`MenuBarExtra` scene — no `WindowGroup`). The new code reads data; it
never writes to `usages.json`.

### Core modules

| Module | Role |
|--------|------|
| **Models** | Codable structs mirroring the `usages.json` schema: root file, vendor entry, polymorphic metric (time-window / pay-as-you-go). |
| **FileWatcher** | Monitors `~/.cache/ai-usages-tracker/usages.json` for changes (FS events or polling ≤ 30 s) and pushes raw `Data` to the store. |
| **UsageStore** | `@Observable` view-model: decodes JSON, finds the active Claude account, extracts time-window metrics, computes the formatted menubar string. Published state consumed by SwiftUI. |

### Menubar string format

```
S 48% 2h13m | W 7% 6d 6h 13m
```

Each time-window segment: **label abbreviation + usage % + remaining
time until `resetAt`**. Segments joined by ` | `. Only `time-window`
metrics are rendered in the menubar label (pay-as-you-go is out of scope
for this epic).

### Graceful degradation

| Condition | Menubar display |
|-----------|-----------------|
| File missing or unreadable | Static fallback text (e.g. `--`) |
| JSON malformed / decode error | Same fallback |
| No active Claude account | Same fallback |
| Active account but empty metrics | Same fallback |
| `resetAt` in the past | Show `0m` remaining |

### Risks

1. **FS event reliability** — `DispatchSource.makeFileSystemObjectSource`
   does not fire on every write to every filesystem (e.g. network mounts).
   Mitigation: hybrid approach (FS events + periodic fallback poll).
2. **Swift 6 strict concurrency** — the project uses Swift 6; all new
   types must be `Sendable`, and the file-watching callback must
   dispatch to `@MainActor` safely. Using `@Observable` (macOS 14+)
   aligns with the existing platform floor.
3. **Large or rapid file changes** — the upstream connector writes
   frequently. Debouncing / coalescing reads avoids unnecessary
   re-renders.

---

## Layer 2 — Impacts

### 2.1 Models

**New file:** `Sources/AIUsagesTrackers/Models/UsageModels.swift`

Four types, all `Codable`, `Equatable`, `Sendable`:

| Type | Fields | Notes |
|------|--------|-------|
| `UsagesFile` | `usages: [VendorUsageEntry]` | Root container. |
| `VendorUsageEntry` | `vendor: String`, `account: String`, `isActive: Bool`, `lastAcquiredOn: String?`, `lastError: UsageError?`, `metrics: [UsageMetric]` | One entry per account. |
| `UsageError` | `timestamp: String`, `type: String` | Optional error state. |
| `UsageMetric` | (enum) cases `timeWindow` and `payAsYouGo` | Discriminated on `"type"` JSON key. |

`UsageMetric` is a `Codable` enum with a `"type"` discriminator:
- `timeWindow(name: String, resetAt: String, windowDurationMinutes: Int, usagePercent: Int)` — decoded from `"time-window"`
- `payAsYouGo(name: String, currentAmount: Double, currency: String)` — decoded from `"pay-as-you-go"`

Custom `init(from:)` / `encode(to:)` handle the polymorphic JSON. The
`resetAt` field is an ISO 8601 string parsed at the store layer (not in
the model) to keep models as pure data transfer objects.

### 2.2 FileWatcher

**New file:** `Sources/AIUsagesTrackers/FileWatcher/UsagesFileWatcher.swift`

| Aspect | Detail |
|--------|--------|
| **Interface** | An actor or `@MainActor`-isolated class exposing a single `onChange` async callback or `AsyncStream<Data>`. |
| **Primary mechanism** | `DispatchSource.makeFileSystemObjectSource` on the file descriptor, watching `.write` events. |
| **Fallback poll** | A `Task`-based timer (≤ 30 s) that reads the file and compares modification date. Fires if FS events are missed or if the file does not exist at startup (no fd to watch). |
| **Lifecycle** | Started in the store's `init` / `task` modifier. Cancelled when the store is deallocated or the SwiftUI task is cancelled. |
| **Debounce** | Coalesce events within a short window (~0.5 s) so rapid successive writes produce a single read. |
| **Concurrency** | The watcher itself is `Sendable`. Callback delivers `Data` on the caller's isolation (the store, `@MainActor`). |

When the watched file is deleted and recreated (common pattern for
atomic writes), the watcher detects the fd invalidation and re-opens.

### 2.3 UsageStore

**New file:** `Sources/AIUsagesTrackers/Store/UsageStore.swift`

An `@Observable @MainActor` class — the single source of truth for the
SwiftUI layer.

**Published properties:**

| Property | Type | Purpose |
|----------|------|---------|
| `menuBarText` | `String` | The formatted string shown in the `MenuBarExtra` label. Defaults to `"--"`. |

**Internal logic (private):**

1. **Decode** — `JSONDecoder` parses `Data` into `UsagesFile`.
2. **Filter** — find the first entry where `vendor == "claude"` and
   `isActive == true`.
3. **Extract** — collect `time-window` metrics from that entry's
   `metrics` array. Ignore `pay-as-you-go`.
4. **Format** — for each time-window metric:
   - Uppercase first letter of `name` as abbreviation (e.g. `"session"` → `S`, `"weekly"` → `W`).
   - `usagePercent` rendered as-is with `%`.
   - Remaining time = `resetAt` parsed as ISO 8601 date minus `Date.now`,
     formatted as compact duration (`Xd Xh Xm`). Clamped to `0m` if
     negative.
   - Segments joined by ` | `.
5. **Error path** — any failure at steps 1–3 sets `menuBarText = "--"`.

**Date handling:** `ISO8601DateFormatter` for parsing `resetAt`. A
`Timer` (or `Task.sleep`) ticking every ~60 s refreshes the "remaining
time" display even when the JSON file hasn't changed, so the countdown
stays current.

### 2.4 App integration

**Modified file:** `Sources/AIUsagesTrackers/AIUsagesTrackersApp.swift`

| Change | Detail |
|--------|--------|
| **State ownership** | Add `@State private var store = UsageStore()` to the app struct. |
| **MenuBarExtra label** | Replace the placeholder text with `Text(store.menuBarText)`. |
| **MenuBarExtra content** | Keep the `Quit` button. No new popover content in this epic. |
| **Lifecycle** | Attach a `.task` modifier (or use the store's init) to start the file watcher and the countdown refresh timer. |

No new `WindowGroup`, no Dock icon, no changes to the `.accessory`
activation policy.

### 2.5 Graceful degradation (cross-cutting)

Degradation is handled entirely in `UsageStore`:

| Scenario | Where caught | Behavior |
|----------|-------------|----------|
| File missing at startup | FileWatcher poll finds no file | Store receives no data → stays on default `"--"` |
| File deleted while running | FileWatcher detects fd invalidation | Store resets to `"--"`, watcher falls back to poll |
| JSON decode failure | Store decode step | Catch error, set `"--"`, log to `os_log` |
| No active Claude entry | Store filter step | `"--"` |
| Empty metrics array | Store extract step | `"--"` |
| `resetAt` in the past | Store format step | Clamp remaining to `0m` |

No alerts, no user-facing error messages — just the silent fallback
string. Errors are logged via `os_log` for diagnostics.

### 2.6 Package structure

No changes to the package manifest — no new dependencies. All new files
go under the existing executable target in new subdirectories
(`Models/`, `FileWatcher/`, `Store/`).
