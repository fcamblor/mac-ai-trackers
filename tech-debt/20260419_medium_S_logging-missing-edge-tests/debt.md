---
title: Missing edge-case tests for FileLogger purge and LogCleaner
date: 2026-04-19
criticality: medium
size: S
---

## Problem

The log-cleanup feature ships with good happy-path and error-path coverage, but
three edge cases were not tested: `LogCleaner.stop()` idempotence (double-stop
without intervening start), a log file whose first line is a continuation line
with no leading timestamp, and non-ASCII content (e.g. emoji) surviving a purge
round-trip intact.

These gaps matter because:

- **`stop()` idempotence**: `stop()` cancels the internal `Task` and nils it;
  calling it twice should be a no-op, but if the nil-check or cancellation logic
  is ever changed, there is no test to catch a regression.
- **Continuation-only file**: `purgeEntries` initialises `keepingContinuation =
  true`, meaning orphan continuation lines at the top of a file (no preceding
  timestamp) are kept unconditionally. This behaviour has no dedicated test, so a
  future refactor of the leading-line handling could silently break it.
- **Non-ASCII round-trip**: `purgeFile` reads the file as a `String`, filters
  lines, and re-encodes as UTF-8. Characters outside ASCII (emoji, accented
  letters) must survive the round-trip. The current force-unwrap comment says
  "provably safe", but there is no test that proves it on real non-ASCII input.

## Impact

- **Maintainability**: untested behaviour is a silent regression magnet; any
  refactor of the purge or scheduling logic can break these paths undetected.
- **AI code generation quality**: agents working on adjacent code will not learn
  the expected behaviour of these edge cases from tests.
- **Bug/regression risk**: medium — the continuation-only and non-ASCII paths are
  exercised in production on every purge cycle.

## Affected files / areas

- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/LogCleanerTests.swift` — missing
  `stop()` idempotence test (double-stop without start).
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/LoggerTests.swift` — missing
  continuation-only file test and non-ASCII round-trip test.

## Refactoring paths

1. **`stop()` idempotence** (`LogCleanerTests.swift`):
   - Create a `LogCleaner`, call `start()`, call `stop()`, call `stop()` again.
   - Assert no crash, no assertion failure, and `cleanOnce()` can still be called
     safely after the double-stop (or a subsequent `start()` succeeds).

2. **Continuation-only file** (`LoggerTests.swift`):
   - Write a file whose every line starts with a space or tab (no ISO 8601 prefix).
   - Call `purgeEntries(olderThan: now)`.
   - Assert all lines are preserved (they all travel with the implicit `keepingContinuation = true` initial state).

3. **Non-ASCII round-trip** (`LoggerTests.swift`):
   - Write a log file containing at least one entry with emoji and accented
     characters in the message, timestamped within the retention window.
   - Call `purgeEntries(olderThan: cutoff)` where the entry is within the window.
   - Read the file back and assert the message text is byte-for-byte identical.
   - Additionally, add a comment on the force-unwrap at `Logger.swift:purgeFile`
     documenting why it is safe: the string was read from disk as UTF-8 and only
     split/joined on `\n` — no scalar boundary can be introduced.

## Acceptance criteria

- [ ] A test named `stopIdempotent` (or similar) covers double-stop without crash
  and verifies a subsequent `start()` succeeds.
- [ ] A test covers a file with no timestamped leading lines and asserts all
  content is kept after purge.
- [ ] A test covers non-ASCII (emoji + accented letters) surviving a purge
  round-trip intact.
- [ ] All new tests pass under `swift test` with no `Task.sleep` literals (use
  injectable clock/sleep or poll helper to satisfy SwiftLint W3).
- [ ] The force-unwrap in `purgeFile` has a `// known-safe` comment explaining
  the UTF-8 round-trip guarantee.

## Additional context

Findings 16, 17, and 18 from the multi-axis review of the log-cleanup feature
(aggregate-apply phase, MED and LOW severity). Deferred to keep the PR focused on
critical and high fixes.
