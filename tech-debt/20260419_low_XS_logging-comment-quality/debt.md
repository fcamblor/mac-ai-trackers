---
title: Stale and redundant comments in the Logging module
date: 2026-04-19
criticality: low
size: XS
---

## Problem

The Logging module accumulated several comment-quality violations during the
log-cleanup feature implementation: comments that restate the variable name or
the doc-comment verbatim (WHAT comments), a `WHY:` prefix that was intended as a
convention but is not used consistently elsewhere, and a justification comment for
`@unchecked Sendable` that conflates two distinct concerns on a single line.

Specific sites:

- `LogCleaner.swift:34-35` — `WHY:` prefix on a comment; the reason is correct
  but the label is noise since no other file uses this convention.
- `Logger.swift:111` — inline comment duplicates the `purgeEntries` doc-comment
  and the variable name `keepingContinuation`; carries zero additional meaning.
- `LogCleanerTests.swift:5` — `@unchecked Sendable` justification mixes two
  concerns (thread-safety mechanism + test-only scope) on one line.
- `LogCleanerTests.swift:80` — `// second call — should be no-op` is pure WHAT;
  the test name `startIdempotent` already says this.
- `LogCleanerTests.swift:85` — `// If two tasks were spawned, count would roughly
  double.` is vague; "roughly" is not a useful assertion bound.
- `LogCleanerTests.swift:117` — `// Restart should work` is pure WHAT; the test
  name `stopThenRestart` already says this.
- `LoggerTests.swift:196` — seed-line comment describes the setup action, not
  the reason for it.

## Impact

- **Maintainability**: redundant comments drift from the code and mislead future
  readers; future agents may over-copy the `WHY:` pattern or preserve stale WHAT
  comments.
- **AI code generation quality**: low — agents may replicate the inconsistent
  `WHY:` convention or preserve WHAT comments when touching adjacent code.
- **Bug/regression risk**: none — purely cosmetic.

## Affected files / areas

- `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/LogCleaner.swift` — line 34-35
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/Logger.swift` — line 111
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/LogCleanerTests.swift` — lines 5, 80, 85, 117
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/LoggerTests.swift` — line 196

## Refactoring paths

1. `LogCleaner.swift:34-35` — Remove the `WHY:` prefix; keep the rest of the
   sentence unchanged.
2. `Logger.swift:111` — Delete the comment entirely.
3. `LogCleanerTests.swift:5` — Split into two lines:
   ```swift
   // @unchecked Sendable: all mutations go through NSLock;
   // test-only, never escapes the test suite
   ```
4. `LogCleanerTests.swift:80` — Delete the comment entirely.
5. `LogCleanerTests.swift:85` — Replace with a concrete bound:
   ```swift
   // Upper bound: one tick per 10 ms over 100 ms ≈ 10; double if two tasks ran
   ```
6. `LogCleanerTests.swift:117` — Delete the comment entirely.
7. `LoggerTests.swift:196` — Replace with motivation:
   ```swift
   // Seed a recent line so the purge scan doesn't short-circuit on an empty file
   ```

## Acceptance criteria

- [ ] No comment in the Logging module starts with `WHY:`.
- [ ] No comment in the Logging module restates the name of the immediately
  following variable or a statement already made in the doc-comment.
- [ ] Every `@unchecked Sendable` justification comment covers exactly one
  concern per line.
- [ ] `swift build` passes with zero SwiftLint warnings.

## Additional context

Findings surfaced during the multi-axis review of the log-cleanup feature
(aggregate-apply phase). They were deferred from the PR to avoid blocking the
critical/high fixes.
