# Plan — Menubar usage metrics display

## Layer 1 — Structural overview

### Architecture

Three new modules sit between the existing `App` layer and the external
JSON file, following a unidirectional data flow:

```
usages.json ──► FileWatcher ──► UsageStore (ObservableObject) ──► MenuBarExtra label
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
