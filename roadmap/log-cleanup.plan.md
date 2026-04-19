---
title: Log cleanup
date: 2026-04-19
---

# Implementation plan — Log cleanup

## Overall approach

Add a **retention purge** operation on `FileLogger` that atomically rewrites the log file by keeping only lines whose leading ISO 8601 timestamp is within the retention window (7 days). Coordinate startup and daily execution through a new `LogCleaner` actor that owns the schedule, receives the list of managed log files and an injectable clock, and is wired from `AppDelegate` alongside the poller. Purge work runs on the logger's existing serial queue so it cannot interleave with concurrent `log()` writes.

Rationale:

- Putting the purge on `FileLogger` reuses the logger's serial queue, which is the natural serialization point with in-flight writes. A separate mutex would have to guard the same file from two sides.
- A dedicated `LogCleaner` actor keeps scheduling (start/stop/idempotence) and dependency injection (clock, logger list) out of `FileLogger`, whose single responsibility remains per-file write/rotate/purge primitives.
- Retention is hard-coded to 7 days to match the metrics time window (stated constraint in the epic). No user-facing knob.

Rejected alternative: external tool / shell cron / `launchd` agent — rejected because the app must not require out-of-process scaffolding, and a hung/killed app should not leave stale logs.

## Impacted areas

- `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/Logger.swift` — extend `FileLogger` with an atomic retention purge primitive; extend `Loggers` to expose the managed log-file paths.
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/LogCleaner.swift` — **new** actor: coordinates startup pass + daily schedule, iterates over managed loggers, injectable clock and interval for tests.
- `AIUsagesTrackers/Sources/App/AppDelegate.swift` — instantiate the `LogCleaner` at launch, run it once, then start the daily loop; stop it on quit.
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/LoggerTests.swift` — add the five purge scenarios from acceptance criteria + atomicity / malformed-line cases.
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/LogCleanerTests.swift` — **new**: schedule behaviour, start/stop idempotence, startup pass, clock-driven tick.
- `docs/ARCHITECTURE.md` — update the Logging section to mention the 7-day retention and its scheduling.

## Phases and commits

### Phase 1 — Purge primitive on `FileLogger`

**Goal**: rewrite a log file in place, keeping only entries whose leading ISO 8601 timestamp is newer than a given cutoff, atomically, under the logger's serial queue.

#### Commit 1 — `feat(logging): add retention purge primitive to FileLogger`

- Files:
  - `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/Logger.swift`
- Changes:
  - Add a `LogPurgeError` enum (cases: `readFailed(path:underlying:)`, `writeFailed(path:underlying:)`, `renameFailed(from:to:underlying:)`) with associated diagnostic context.
  - Add a private helper `FileLogger.parseLeadingTimestamp(from line: Substring, formatter: ISO8601DateFormatter) -> Date?` that extracts the text between the first `[` and the first `]` on the line and attempts to parse it. Return `nil` if brackets are missing or parsing fails (log entries write `[timestamp] [LEVEL] message`; continuation / malformed lines without a leading timestamp stay attached to the previous kept line — see below).
  - Add `public func purgeEntries(olderThan cutoff: Date) throws` on `FileLogger`:
    1. Dispatch to `self.queue` via `queue.sync { ... }` to serialize with ongoing writes. Any thrown error is captured and re-thrown outside the closure.
    2. If the file does not exist → return (no-op, not an error).
    3. Read `filePath` as UTF-8 via `String(contentsOfFile:encoding:.utf8)`. Throw `.readFailed` on underlying error.
    4. Split on `\n`. Walk the lines in order; keep a line when either:
       - it has a parseable leading timestamp **and** that date is `>= cutoff`, OR
       - it has **no** parseable leading timestamp (treated as a continuation of the previous line) **and** the previous line was kept.
       Drop any line with a parseable timestamp older than `cutoff`, and drop continuation lines attached to a dropped timestamped line.
    5. Reassemble kept lines with `\n` separators (preserve the trailing newline if the original had one, so append does not collapse two entries onto one line).
    6. If kept content equals the original → skip the rewrite entirely (avoid unnecessary I/O; important for the daily tick when nothing has aged out).
    7. Write kept content atomically using `Data.write(to:options:.atomic)` into the same URL — Foundation implements this as temp-file + rename, satisfying the "crash mid-cleanup leaves previous file intact" criterion. Throw `.writeFailed` on error.
  - Apply the same purge to the rotated backup path `filePath + ".1"` when it exists (within the same `queue.sync` block) — the rotation backup is still a `FileLogger`-managed file and must not keep lines older than 7 days.
  - Reuse a single `ISO8601DateFormatter` instance within one purge call (cold path, acceptable per SWIFT-CONCURRENCY §NSFormatter guidance).
  - Add an `internal func purgeEntriesForTesting(olderThan:)` thin wrapper only if the tests cannot invoke the public API directly — prefer exposing the public API and avoid the extra surface.
- Risk:
  - Reading a nearly-5-MB file into memory: acceptable given the explicit 5 MB rotation cap. Document the assumption in a `// WHY` comment next to the read.
  - `queue.sync` from a caller already running on `queue` would deadlock. The actor `LogCleaner` (Phase 2) calls from an async context via `Task.detached`, never from the logger's own queue, so this cannot happen in practice — but add a doc comment on `purgeEntries` forbidding calls from within a log handler.
  - Concurrent external writers (e.g. the `.1` file right after a rotation): rotation runs on the same `queue`, so the purge and rotation are mutually exclusive on the same logger.

#### Commit 2 — `test(logging): cover FileLogger retention purge cases`

- Files:
  - `AIUsagesTrackers/Tests/AIUsagesTrackersTests/LoggerTests.swift`
- Changes: add a `@Suite("FileLogger.purgeEntries")` covering the acceptance-criteria matrix:
  - All lines older than cutoff → file becomes empty.
  - All lines newer than cutoff → file byte-for-byte unchanged.
  - Mixed → only old lines removed, order of kept lines preserved.
  - Empty file → no crash, file still empty.
  - Missing file → no crash, no file created.
  - Malformed / continuation line following an old entry → dropped with its parent.
  - Malformed / continuation line following a kept entry → kept.
  - Purge running concurrently with 20 `log()` calls (TaskGroup) does not lose lines or corrupt the file (every line in the final file parses as `[ISO8601] [LEVEL] ...`).
  - Rotated backup (`filePath + ".1"`) is purged alongside the main file when present.
- All tests build cutoff timestamps in the test body using a fixed `Date` — never `Date()` inside assertions. Inject timestamps by writing pre-formed log lines directly to the file, not through `log()`.
- Risk: concurrency test must drain the serial queue with `waitForPendingWrites()` before assertions (pattern already used by `concurrentLogging`).

### Phase 2 — Daily scheduler: `LogCleaner`

**Goal**: run one purge at startup and one every 24 h, over an injectable list of loggers and an injectable clock, with idempotent start/stop.

#### Commit 3 — `feat(logging): add LogCleaner actor scheduling the 7-day purge`

- Files:
  - `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/LogCleaner.swift` (new)
  - `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/Logger.swift` (expose shared logger list)
- Changes:
  - In `Loggers`, add `public static let managed: [FileLogger] = [app, claude]` so `LogCleaner` does not hard-code the list and future loggers are picked up automatically.
  - New file `LogCleaner.swift`:
    ```swift
    public actor LogCleaner {
        public static let retention: Duration = .seconds(7 * 24 * 60 * 60)
        public static let tickInterval: Duration = .seconds(24 * 60 * 60)

        private let loggers: [FileLogger]
        private let retention: Duration
        private let tickInterval: Duration
        private let now: @Sendable () -> Date
        private let sleep: @Sendable (Duration) async throws -> Void
        private let logger: FileLogger
        private var task: Task<Void, Never>?

        public init(
            loggers: [FileLogger] = Loggers.managed,
            retention: Duration = LogCleaner.retention,
            tickInterval: Duration = LogCleaner.tickInterval,
            now: @Sendable @escaping () -> Date = { Date() },
            sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            logger: FileLogger = Loggers.app
        )

        public func cleanOnce() async   // runs purge on every managed logger off the cooperative pool
        public func start() async       // immediate cleanOnce, then every tickInterval; idempotent
        public func stop()              // cancels the task; idempotent
    }
    ```
  - `cleanOnce()` iterates the loggers and for each one hops to a background queue via `withCheckedContinuation` + `DispatchQueue.global(qos: .utility).async` before calling `purgeEntries(olderThan: now().addingTimeInterval(-retentionSeconds))`. This keeps `queue.sync` inside `FileLogger.purgeEntries` off the cooperative pool (SWIFT-CONCURRENCY §Never block).
  - Per-logger errors are logged (`logger.log(.error, ...)`) with the failing path; one logger's failure does not stop the sweep.
  - `start()` guards with `task == nil`, logs `"Log cleaner already running"` and returns when re-invoked (pattern mirrors `UsagePoller.start`).
  - The daily loop uses the injected `sleep(tickInterval)` and `Task.isCancelled` checks (same pattern as `UsagePoller`).
  - All numeric literals use named constants (`retention`, `tickInterval`, …) per SWIFT-TESTABILITY §Name magic numbers.
- Risk:
  - `cleanOnce` must not block on the cooperative pool. The continuation + background `DispatchQueue` pattern is explicit about this — add a `// WHY` comment.
  - Restart after `stop()` must work: `task = nil` on cancel.

#### Commit 4 — `test(logging): cover LogCleaner scheduling and idempotence`

- Files:
  - `AIUsagesTrackers/Tests/AIUsagesTrackersTests/LogCleanerTests.swift` (new)
- Changes: cover:
  - `cleanOnce()` purges every injected logger file (feed 2 temp loggers pre-populated with old + recent lines; assert old lines are gone from both).
  - `start()` is idempotent: calling it twice does not spawn two tasks (count how many times the fake `sleep` closure is entered in a short window).
  - `stop()` cancels the task and a subsequent `start()` resumes ticking.
  - Missing / empty files are handled (no crash, no file created).
  - Clock injection drives the cutoff: wire `now = { fixedDate }`; write a line timestamped `fixedDate - 6d23h` (kept) and `fixedDate - 7d1h` (dropped); assert accordingly.
- All tests use `eventually()`-style polling (existing helper in the test target, per SWIFT-TESTABILITY §W3) instead of `Task.sleep(literal)`.
- Risk: race between the scheduled tick and the test assertions — use an injectable `sleep` that `await`s on a controllable continuation rather than wall-clock sleep.

### Phase 3 — Wiring and documentation

**Goal**: run the cleaner at app launch and every 24 h; document the retention behaviour.

#### Commit 5 — `feat(app): run log cleanup at startup and daily`

- Files:
  - `AIUsagesTrackers/Sources/App/AppDelegate.swift`
- Changes:
  - Store a `private var logCleaner: LogCleaner?` field.
  - In `applicationDidFinishLaunching`, after `pidGuard` is acquired and before launching the poller, instantiate `let logCleaner = LogCleaner()` and retain it on `self`.
  - In the existing launch `Task { ... }` block, add `await logCleaner.start()` — placed *before* `poller.start()` so the startup pass completes before the first poll writes new entries (this is not strictly required for correctness, but keeps log volume predictable on cold starts).
  - In `quit()`, add `await logCleanerRef?.stop()` alongside the existing `pollerRef?.stop()` / `monitorRef?.stop()` calls.
- Risk: `quit()` already awaits stops inside a `Task` — make sure `logCleaner.stop()` is added **inside** that same task and captured via a local `let` (same pattern as `pollerRef`) to avoid capturing `self` from the detached task.

#### Commit 6 — `docs(architecture): document log retention cleanup`

- Files:
  - `docs/ARCHITECTURE.md`
- Changes: in the Logging section, add one sentence: the app purges entries older than 7 days from managed log files at startup and every 24 h, using atomic rewrites. Do not name specific types — describe the role only (per `.claude/rules/markdown-authoring.md` §Write for longevity).

## Validation

1. **Swift build + tests** — from the repo root:
   ```bash
   cd AIUsagesTrackers && swift build && swift test
   ```
   Must be green. SwiftLint custom rules (E1/E2/W1/W3/W4/W5) must produce zero violations.

2. **Acceptance-criteria cross-check** against `roadmap/log-cleanup.md`:
   - "At app launch, any log line with a timestamp older than 7 days is absent from all log files after startup completes" → covered by the Phase 2 startup pass + Phase 1 test matrix.
   - "A daily timer fires every 24 hours and repeats the same purge without restarting the app" → covered by `LogCleaner.start()` loop + Commit 4 schedule test.
   - "Log files are rewritten atomically; a crash mid-cleanup leaves the previous file intact" → covered by `Data.write(to:options:.atomic)` in Commit 1.
   - "Lines from the current 7-day window are never removed" → covered by Commit 2 `all-recent` and `mixed` cases.
   - "Unit tests cover: all lines old (file cleared), all lines recent (file unchanged), mixed lines (only old lines removed), empty file (no crash), missing file (no crash)" → covered by the Commit 2 suite.

3. **Manual smoke test**:
   - Populate `~/.cache/ai-usages-tracker/app.log` with a synthetic line timestamped 10 days in the past plus a recent line, launch the app, quit it, re-open the file — only the recent line must remain.

4. **Regression**:
   - Existing rotation test (`rotatesFile`) still passes.
   - Concurrent logging test (`concurrentLogging`) still passes, and the new concurrent purge + log test is green.
