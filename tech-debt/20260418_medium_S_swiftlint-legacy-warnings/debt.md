---
title: Resolve SwiftLint legacy warnings captured in .swiftlint.baseline
date: 2026-04-18
criticality: medium
size: S
---

## Problem

`AIUsagesTrackers/.swiftlint.baseline` lists 16 violations that existed when
the six custom rules (E1, E2, W1, W3, W4, W5) were introduced. Each
violation is a real finding already surfaced in prior review passes; the
baseline only silences them so the build stays green. As long as an entry
sits in the baseline, the rule is passively disabled for that site — a new
agent modifying the same region will not learn from the finding.

Breakdown:

- **W1 — `nonisolated(unsafe)` in production** (×1)
  - `Sources/AIUsagesTrackers/Logging/Logger.swift:31` — static ISO formatter.
- **W3 — `Task.sleep` literal in tests** (×8)
  - `Tests/AIUsagesTrackersTests/UsageStoreTests.swift:80, 369, 747`
  - `Tests/AIUsagesTrackersTests/UsagePollerTests.swift:143, 236`
  - `Tests/AIUsagesTrackersTests/UsagesFileWatcherTests.swift:33, 88, 114`
- **W4 — `@unchecked Sendable` without a justification comment** (×2)
  - `Tests/AIUsagesTrackersTests/ClaudeCodeConnectorTests.swift:7`
  - `Tests/AIUsagesTrackersTests/UsageStoreTests.swift:11`
- **W5 — duration literal embedded in a comment** (×5)
  - `Tests/AIUsagesTrackersTests/UsageStoreTests.swift:438 (×3), 510, 543`

## Impact

- **Maintainability**: baseline entries are a hidden rule carve-out; the
  longer they persist, the less the harness teaches new work.
- **AI code generation quality**: agents copying from these sites replicate
  the exact patterns the rules were introduced to prevent.
- **Bug/regression risk**: W1 (single thread formatter) and W3 (fragile
  async sync) are the real correctness/flake risks; W4 and W5 are code
  quality.

## Affected files / areas

- `AIUsagesTrackers/.swiftlint.baseline` — remove entries as each site is
  fixed.
- The 8 files listed above.

## Refactoring paths

1. **W1 in `Logger.swift`**: move `isoFormatter` off a `nonisolated(unsafe)
   static let` to a dedicated serial `DispatchQueue` or instantiate per
   call — `Logger` is not in a hot path, per-call allocation is acceptable.
2. **W3 in tests**: introduce an `eventually(timeout:interval:_:)` helper
   (already exists in `UsageStoreTests` — promote to a shared test utility)
   and replace every fixed `Task.sleep` that waits for an observable
   state change. Pure time-based waits (no observable state to poll, e.g.
   "no emit happens within N ms") can stay with a `Task.sleep` behind a
   named constant + rationale comment.
3. **W4**: add a one-line justification comment directly above each
   `@unchecked Sendable` conformance explaining why single-threaded access
   is safe.
4. **W5**: lift every `// N <unit>` comment to a named constant whose
   declaration site carries the rationale. Update the test body to reference
   the constant.
5. After each batch, regenerate `.swiftlint.baseline`:
   `swift package plugin --allow-writing-to-package-directory swiftlint lint --write-baseline .swiftlint.baseline`
   and commit the shrunken baseline alongside the fix.

## Acceptance criteria

- [ ] `.swiftlint.baseline` is empty or the file is removed along with the
  `baseline:` key in `.swiftlint.yml`.
- [ ] `swift build` passes with zero SwiftLint warnings.
- [ ] No new `Task.sleep(fixed literal)` remains on a site where an
  observable state could be polled instead.
- [ ] Every surviving `@unchecked Sendable` has a justification comment on
  the preceding line.

## Additional context

Introduced alongside the SwiftLint migration (see commit that adds
`AIUsagesTrackers/.swiftlint.yml`). The rules themselves correspond to
recurring findings from reviews on PRs #3–#5; see `.claude/rules/swift-quality.md`
for the rule catalog and `docs/SWIFT-*.md` for the underlying specs.
