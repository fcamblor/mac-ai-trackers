---
title: Usage display pipeline test coverage and robustness gaps
date: 2026-04-18
---

## Drift from original debt description

- `UsageModelsTests.swift` contains a test `unknownTypeThrows` that currently **asserts** unknown metric types throw. Fixing the unknown-type decode behavior (debt item 8) requires updating that test to expect `.unknown(...)` instead — plan accounts for this.
- All other described gaps are confirmed present exactly as described.

## Overall approach

Replace all fixed `Task.sleep` calls with a poll-with-timeout helper (`eventually`) backed by a new observable `dataProcessedCount` counter on `UsageStore`. Then add the eight missing `UsageStore` tests, fix unknown-metric-type decode resilience in the model layer, and create `UsagesFileWatcherTests.swift` with four integration tests against the real file system.

The `dataProcessedCount` counter is the minimal production change needed to make negative-case tests (where `menuBarText` stays `"--"`) reliable: without it, there is no observable signal that the store actually processed the bad data, so a poll helper cannot distinguish "data not yet processed" from "data processed and result is correct".

## Phases and commits

### Phase 1: Async synchronization infrastructure

**Goal**: Provide a robust, non-sleep-based way for tests to wait for async state changes and confirm data was processed.

#### Commit 1 — `feat(store): add dataProcessedCount observable for test observability`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Store/UsageStore.swift`
- Changes: Add `public private(set) var dataProcessedCount: Int = 0` (annotated `@MainActor` via class isolation). Increment it at the start of `handleNewData(_:)`, before any guard or decode. This fires whether the data is valid or malformed, giving tests a reliable signal that the store consumed the last yielded item.
- Risk: None — additive change, existing behaviour unchanged.

#### Commit 2 — `refactor(tests): replace Task.sleep with eventually helper in UsageStoreTests`
- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageStoreTests.swift`
- Changes:
  - Add at top of file (before any suite):
    ```swift
    private struct EventuallyTimeoutError: Error {}

    /// Polls `condition` on the main actor at `interval` until it returns true or `timeout` expires.
    @MainActor
    private func eventually(
        timeout: TimeInterval = 2.0,
        interval: TimeInterval = 0.01,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            if condition() { return }
            guard Date() < deadline else { throw EventuallyTimeoutError() }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
    ```
  - Replace every `try await Task.sleep(nanoseconds: 50_000_000)` call with an `eventually` call appropriate to the test:
    - Positive cases (text changes): `try await eventually { store.menuBarText == expected }`
    - Negative cases (text stays `"--"`): `try await eventually { store.dataProcessedCount == N }` followed by the `#expect(store.menuBarText == "--")` assertion
    - The `recoveryAfterError` test has two send/check cycles — use `eventually { store.dataProcessedCount == 1 }` after the first send, then `eventually { store.dataProcessedCount == 2 }` after the second.
- Risk: Tests relying on timing become slower under normal conditions only when conditions are slow — acceptable.

### Phase 2: UsageStore missing and strengthened tests

**Goal**: Achieve full coverage of the gaps listed in the debt.

#### Commit 3 — `test(store): add behavioral assertions to lifecycle tests and start/stop/start`
- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageStoreTests.swift`
- Changes within `UsageStoreLifecycleTests`:
  - `startIdempotent`: After `start(); start()`, send valid data and use `eventually { store.menuBarText != "--" }` to verify data still flows; `stop()` at end.
  - `stopIdempotent`: After `start(); stop(); stop()`, send valid data, wait `eventually { store.dataProcessedCount == 0 }` (it stays 0 because watch task is gone), then `#expect(store.menuBarText == "--")`. Note: since stop cancels the task, `dataProcessedCount` never increments — use a short fixed sleep (0.1s) then assert count == 0; document WHY (no reactive signal when task is cancelled).
  - Add new `startStopStart` test: `start()` → send valid data → `eventually { text != "--" }` → `stop()` → `start()` → send new valid data → `eventually { text == newExpected }` → `stop()`.
- Risk: `stopIdempotent` still uses a small sleep, but purpose is different (confirming nothing happened, not waiting for something to happen); this is the only acceptable residual sleep.

#### Commit 4 — `test(store): add missing edge-case and formatting tests`
- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageStoreTests.swift`
- Changes — add new tests to existing or new suites:
  - **Countdown refresh** (`UsageStoreLifecycleTests` or new suite): Set `countdownRefreshSeconds: 1`. Send valid data, `eventually { text != "--" }`. Let countdown fire (wait ~1.2s) — text should re-render with new clock value. Use a `FixedClock` that always returns `referenceDate`; since clock is fixed the text won't change value but `refreshMenuBarText()` is called — verify it stays correct.
    - Better: use a `MutableClock` (a new `ClockProvider` test double) whose `now()` is settable. After countdown fires, advance the clock; text should reflect the new remaining time.
    - Add `MutableClock` test double alongside `FixedClock`:
      ```swift
      @MainActor
      final class MutableClock: ClockProvider {
          var date: Date
          init(_ date: Date) { self.date = date }
          nonisolated func now() -> Date { ... } // needs @unchecked Sendable or nonisolated access
      ```
      Since `ClockProvider` is `Sendable` and tests are `@MainActor`, use `nonisolated(unsafe) var date` with documentation that tests access it single-threaded.
    - Test: start store with `countdownRefreshSeconds: 1`. After initial data loads, advance `MutableClock` by 1 hour. Wait for countdown tick (`try await Task.sleep(nanoseconds: 1_200_000_000)`). Verify `menuBarText` reflects the new remaining time.
  - **Error then countdown**: Start with bad data (menuBarText == "--", dataProcessedCount == 1). Wait for a countdown tick. Verify menuBarText remains "--" (confirming `refreshMenuBarText` is a no-op when `lastFile` is nil after an error).
  - **Multiple vendor entries**: Create JSON with two active Claude entries, each having different metrics. Verify the first entry's metrics are used (matching `first(where:)` semantics).
  - **Empty metric name**: Send a time-window metric with `name: ""`. Verify that the formatted output does not contain a leading space — either the metric is skipped (producing `"--"`) or a fallback label is used. Note: this test may initially FAIL if the production code is not fixed; fixing the production code is part of this commit (see "Risk" below).
    - Fix in `UsageStore.formatTimeWindowSegment`: add `guard !abbreviation.isEmpty else { return nil }` before building the segment string.
  - **Exactly N hours**: 2h 0m remaining → expect `"S X% 2h"` (no trailing `"0m"` because `minutes == 0` and `parts` is non-empty).
  - **Sub-minute remaining**: 30s remaining → `totalSeconds=30`, `minutes=0`, `parts` is empty → expect `"S X% 0m"`.
  - **Unknown metric type** (placeholder, full fix in Phase 3): add a test that sends JSON with one known `time-window` metric and one `unknown-future-type` metric; verify only the known metric renders.
- Risk: The empty-metric-name fix changes production behaviour for malformed data — this is intentional. All other changes are test-only.

### Phase 3: Unknown metric type decode resilience

**Goal**: Make `UsageMetric` decode unknown metric types gracefully instead of propagating a decode error that silently drops all metrics for the entry.

#### Commit 5 — `fix(models): decode unknown metric types as .unknown instead of throwing`
- Files:
  - `AIUsagesTrackers/Sources/AIUsagesTrackers/Models/ValueObjects.swift`
  - `AIUsagesTrackers/Sources/AIUsagesTrackers/Models/UsageModels.swift`
  - `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageModelsTests.swift`
  - `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsageStoreTests.swift`
- Changes:

  **ValueObjects.swift** — replace `MetricKind`:
  ```swift
  // Remove: String, RawRepresentable (raw values move to custom Codable)
  public enum MetricKind: Equatable, Hashable, Sendable {
      case timeWindow
      case payAsYouGo
      case unknown(String)   // forward-compatible: future API types are retained, not thrown
  }

  extension MetricKind: Codable {
      public init(from decoder: Decoder) throws {
          let raw = try decoder.singleValueContainer().decode(String.self)
          switch raw {
          case "time-window":   self = .timeWindow
          case "pay-as-you-go": self = .payAsYouGo
          default:              self = .unknown(raw)
          }
      }
      public func encode(to encoder: Encoder) throws {
          let raw: String
          switch self {
          case .timeWindow:        raw = "time-window"
          case .payAsYouGo:       raw = "pay-as-you-go"
          case .unknown(let s):   raw = s
          }
          var container = encoder.singleValueContainer()
          try container.encode(raw)
      }
  }
  ```

  **UsageModels.swift** — update `UsageMetric`:
  - Add `case unknown(String)` to the enum.
  - Update `kind` computed property to return `.unknown(t)` for the new case.
  - In `init(from:)`, add `case .unknown(let t): self = .unknown(t)` after the existing switch cases.
  - In `encode(to:)`, add `case .unknown(let t): try container.encode(MetricKind.unknown(t), forKey: .type)` (other fields are omitted — unknown metrics round-trip only their type discriminator).

  **UsageModelsTests.swift** — update `unknownTypeThrows`:
  - Rename to `unknownTypeDecodesAsUnknown`.
  - Change body: decode the same bad JSON and `#expect(decoded == .unknown("unknown"))`.
  - Add a new test `unknownTypeRoundTrips`: encode `.unknown("future-type")`, decode, verify equality.

  **UsageStoreTests.swift** — complete the placeholder unknown-type test added in Phase 2 (if not already done there): verify the known metric still renders when paired with an unknown-type metric.

- Risk: `MetricKind` loses `RawRepresentable`/`String` raw type — any callers using `.rawValue` must be updated. Grep for `MetricKind` usages before committing to ensure no missed call sites.

### Phase 4: UsagesFileWatcher integration tests

**Goal**: Provide at least four integration tests for `UsagesFileWatcher` covering the behaviours identified in the debt.

#### Commit 6 — `test(file-watcher): add integration tests for UsagesFileWatcher`
- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsagesFileWatcherTests.swift` (new file)
- Changes: Create the file with the suite below. All tests use `FileManager.default.temporaryDirectory` for isolation and `defer { try? FileManager.default.removeItem(at: url) }` for cleanup.

  Helper inside the suite:
  ```swift
  /// Collects up to `maxCount` values from `watcher.changes()` then cancels.
  private func collect(
      from watcher: UsagesFileWatcher,
      maxCount: Int,
      timeout: TimeInterval = 2.0
  ) async throws -> [Data] { ... }
  ```
  Implementation: launch a `Task` that appends to `[Data]`, break on `maxCount`, and cancel after `timeout` via `Task.sleep`.

  **Test 1 — `initialEmitIfFileExists`**: Write temp file before creating watcher. Call `changes()`. Verify first emit equals written content.

  **Test 2 — `noEmitIfFileAbsent`**: Point watcher at a path that does not exist. Let watcher run for 0.3s (3 poll cycles at `pollInterval: 0.1`). Verify zero emits received. Uses a short fixed sleep — acceptable because there is no reactive condition to poll for (absence of an event).

  **Test 3 — `emitAfterWrite`**: Create watcher on a non-existent path. Then write the file. Use `eventually` to wait for the first emit. Verify content matches.

  **Test 4 — `dedupOnUnchangedFile`**: Write temp file, start watcher, wait for initial emit (`eventually { received.count == 1 }`). Wait an additional 0.3s (allowing at least one more poll tick). Verify `received.count == 1` — unchanged modDate suppresses duplicate emit.

  All tests inject `pollInterval: 0.1` (100ms) so they complete well within CI time budgets.

- Risk: File system tests are inherently slower than in-memory tests; 0.1s poll keeps each test under ~500ms. APFS modification-date granularity is fine-grained enough (sub-millisecond) that the dedup test should be reliable.

## Validation

Run from `AIUsagesTrackers/`:

```bash
swift test
```

All tests must pass. Confirm acceptance criteria:

- [ ] `grep -r "Task\.sleep(nanoseconds: 50_000_000)" Tests/` → zero matches
- [ ] Tests exist (grep for `func countdown`, `func errorThenCountdown`, `func startStopStart`, `func multipleVendorEntries`, `func emptyMetricName`, `func exactlyNHours`, `func subMinuteRemaining`, `func unknownMetricType`)
- [ ] `startIdempotent` and `stopIdempotent` contain `#expect`
- [ ] `UsagesFileWatcherTests.swift` exists with ≥ 4 `@Test` functions
- [ ] `swift test` exits 0
