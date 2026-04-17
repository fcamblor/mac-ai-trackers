---
title: Usage display pipeline code quality, comments, and documentation polish
date: 2026-04-18
---

## Drift from original debt description

Item 9 (plan-menubar-usage-metrics.md at repo root) is already resolved — no such file exists in the worktree. All other items are present exactly as described.

`FileLogger` is declared `public final class FileLogger: Sendable` with only `let` stored properties, all of which are `Sendable`. This means `@unchecked Sendable` on `UsagesFileWatcher` is removable without a comment justification.

## Overall approach

Group changes into four commits: Swift code quality improvements first (compactMap, Sendable, deinit, referenceDate), then comment cleanup (MARK sections and WHAT comments), then minor robustness fixes (UInt64 clamp, precise DecodingError assertion), and finally documentation updates (ARCHITECTURE.md wording, roadmap completion note). This ordering keeps Swift source changes together so they are verified as a unit before touching docs.

## Phases and commits

### Phase 1: Swift code quality

**Goal**: Eliminate the verbose compactMap closure, remove the unnecessary `@unchecked` annotation, add a defensive `deinit` to `UsageStore`, and turn the recreated-on-every-access formatter in tests into a `static let`.

#### Commit 1 — `refactor(store): simplify compactMap to method reference and add deinit`

- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Store/UsageStore.swift`
- Changes:
  - Line 124–126: replace the closure `entry.metrics.compactMap { metric -> String? in formatTimeWindowSegment(metric) }` with `entry.metrics.compactMap(formatTimeWindowSegment)`.
  - After `stop()` (line 94), add `deinit { stop() }` to cancel `watchTask` and `countdownTask` if `stop()` was never called explicitly. Add a one-line comment: `// Defensive: cancels tasks when the store is released without an explicit stop() call.`
- Risk: None — purely stylistic and additive.

#### Commit 2 — `refactor(file-watcher): remove @unchecked Sendable`

- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/FileWatcher/UsagesFileWatcher.swift`
- Changes:
  - Line 17: change `public final class UsagesFileWatcher: FileWatching, @unchecked Sendable` to `public final class UsagesFileWatcher: FileWatching, Sendable`. All three stored properties (`path`, `pollInterval`, `logger`) are `let` and their types (`String`, `TimeInterval`, `FileLogger`) all conform to `Sendable`; the compiler can verify conformance.
- Risk: If the build fails (e.g. compiler version doesn't synthesize conformance for classes), revert and instead keep `@unchecked` with a comment: `// @unchecked: all stored properties are let and Sendable; compiler cannot synthesize for class types.`

#### Commit 3 — `refactor(tests): make referenceDate a static let`

- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageStoreTests.swift`
- Changes:
  - Lines 82–85: replace the computed property `private var referenceDate: Date { let f = ISO8601DateFormatter(); return f.date(from: "2026-04-17T12:47:00Z")! }` with `private static let referenceDate: Date = ISO8601DateFormatter().date(from: "2026-04-17T12:47:00Z")!`. Update each usage in the test suite from `referenceDate` to `Self.referenceDate` (or just `referenceDate` — both work for `static let` accessed from instance methods).
- Risk: None.

### Phase 2: Comment cleanup

**Goal**: Remove MARK sub-sections inside `UsageStore` that label single declarations or trivially small groups, and remove WHAT comments from the test file.

#### Commit 4 — `refactor(store): remove excessive MARK sub-sections`

- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Store/UsageStore.swift`
- Changes: Remove the four plain-MARK lines inside the class body that add noise without aiding navigation:
  - Remove `// MARK: Published state` (covers a single property: `menuBarText`)
  - Remove `// MARK: Dependencies` (the grouping is obvious from the property declarations themselves)
  - Remove `// MARK: Tasks` (two lines; grouping is self-evident)
  - Remove `// MARK: Init` (a single `init`; no navigation value)
  - Keep all `// MARK: -` sections (`Clock abstraction`, `Store`, `Lifecycle`, `Processing`, `Formatting`) — they have separators and meaningful scope.
- Risk: None — cosmetic only.

#### Commit 5 — `refactor(tests): remove WHAT comments`

- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageStoreTests.swift`
- Changes:
  - Line 109: remove `// Let the async stream deliver` (restates the `Task.sleep` call).
  - Line 149: remove `// No time-window metrics → fallback` (restates the `#expect` assertion immediately below).
  - Line 308 (inside `startIdempotent`): remove `// second call should be no-op` (restates the test name).
- Risk: None — cosmetic only.

### Phase 3: Minor robustness

**Goal**: Guard against a UInt64 overflow trap for large `pollInterval` values, and tighten the `unknownTypeThrows` assertion to name the specific error type.

#### Commit 6 — `fix(file-watcher): clamp pollInterval before UInt64 cast`

- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/FileWatcher/UsagesFileWatcher.swift`
- Changes:
  - Line 114: replace `UInt64(pollInterval * 1_000_000_000)` with a clamped expression. Add a constant above the loop (or inline) to compute the nanoseconds safely:
    ```swift
    // Cap at ~292 years to prevent UInt64 overflow for large pollInterval values
    let maxNanos: Double = Double(UInt64.max)
    let refreshNanos = UInt64(min(pollInterval * 1_000_000_000, maxNanos))
    try? await Task.sleep(nanoseconds: refreshNanos)
    ```
- Risk: None in practice — the cap is astronomically large. The change only prevents a trap for pathological inputs.

#### Commit 7 — `fix(tests): assert specific DecodingError in unknownTypeThrows`

- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageModelsTests.swift`
- Changes:
  - Lines 61–64: replace `#expect(throws: (any Error).self)` with `#expect(throws: DecodingError.self)` so the test fails if a different error type is thrown (e.g. a future refactor accidentally throws a different error kind):
    ```swift
    #expect(throws: DecodingError.self) {
        try decoder.decode(UsageMetric.self, from: bad)
    }
    ```
- Risk: None — `JSONDecoder` throws `DecodingError` for unknown type discriminators.

### Phase 4: Documentation

**Goal**: Remove concrete timing values from ARCHITECTURE.md's Display pipeline section and add a delivery note to the menubar-usage-metrics epic.

#### Commit 8 — `docs(architecture): use structural descriptions in Display pipeline section`

- Files: `docs/ARCHITECTURE.md`
- Changes in the "Display pipeline" section (lines 28–30):
  - Replace "re-checks every 30 seconds" with "re-checks on a configurable polling interval".
  - Replace "A secondary timer refreshes the countdown display every 60 seconds" with "A secondary countdown timer periodically refreshes the remaining-time values in the display".
  - Remove the inline format example `(S 48% 2h 13m | W 7% 6d 6h 13m)` from the prose — it appears in the class-level doc comment in `UsageStore.swift` and does not need to be duplicated here.
- Risk: None.

#### Commit 9 — `docs(roadmap): add delivery note to menubar-usage-metrics epic`

- Files: `roadmap/menubar-usage-metrics.md`
- Changes: Append a `## Delivered` section at the end of the file with a brief note confirming the feature shipped and any notable deviations from original scope. Example:

  ```markdown
  ## Delivered

  Feature shipped as scoped. The display refresh uses a hybrid file-watcher/polling
  strategy rather than poll-only, and the countdown timer interval is configurable
  (not hard-coded). All acceptance criteria from the original scope were met.
  ```

- Risk: None.

## Validation

After all commits, run from `AIUsagesTrackers/`:

```bash
swift build && swift test
```

Check acceptance criteria from `debt.md`:

- `compactMap` uses method reference syntax → grep `compactMap(formatTimeWindowSegment)` in `UsageStore.swift`
- `@unchecked Sendable` is removed or has a justification comment → check `UsagesFileWatcher.swift` line 17
- `UsageStore.deinit` cancels tasks → grep `deinit` in `UsageStore.swift`
- No WHAT comments remain in test file → check removed lines in `UsageStoreTests.swift`
- `ARCHITECTURE.md` Display pipeline uses structural descriptions only → no "30 seconds" or "60 seconds" in that section
- Epic file has a delivery note → `roadmap/menubar-usage-metrics.md` contains `## Delivered`
- All tests pass → `swift test` exits 0
