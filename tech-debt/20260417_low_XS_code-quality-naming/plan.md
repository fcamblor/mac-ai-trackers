---
title: Minor code quality and naming issues in connector layer
date: 2026-04-18
---

## Drift from original debt description

- **Item 2** (`merge` visibility): Debt recorded it as `internal`; current code declares it `public`. The fix (→ `private`) is the same but the scope is slightly larger.
- **Item 4** (redundant `pollerRef` comment): No comment exists around `pollerRef` in `AIUsagesTrackersApp.swift`. This acceptance criterion is already met — skip.
- **Item 5** (MARK label): The original label "Unsafe (caller holds lock)" was partially revised to "Unsafe (actor-isolated, no external lock needed)" but was not renamed to the target "Lock-guarded internals".
- **Item 6** (WHAT comments): A block comment was added above the metrics array explaining the Claude rate-limit policy (WHY). The inline `// 5 hours` and `// 7 days` labels on the `windowDuration` lines remain as WHAT-comments.

## Overall approach

Apply five isolated, low-risk text changes across four files. Each commit is self-contained; none requires logic changes or new test coverage beyond verifying the existing suite still compiles and passes. Order: persistence → connector → poller.

## Phases and commits

### Phase 1: Persistence layer — visibility and MARK label

**Goal**: Reduce the public surface of `UsagesFileManager` and fix the misleading MARK section name.

#### Commit 1 — `fix(persistence): make merge() private and rename MARK section`

- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Persistence/UsagesFileManager.swift`
- Changes:
  1. Line 59: change `public func merge(` → `private func merge(`. The method is called only from within the actor (`update(with:)` at line 35); `@testable import` in tests still allows access.
  2. Line 89: change `// MARK: - Unsafe (actor-isolated, no external lock needed)` → `// MARK: - Lock-guarded internals`. The term "Unsafe" is misleading — it connotes `UnsafePointer`-style memory danger; the functions are simply actor-isolated helpers.
- Risk: Tests that call `merge(existing:incoming:)` directly must compile via `@testable import`; verify no `public` qualifier is required by the test target.

### Phase 2: Connector layer — magic constant and inline WHAT-comments

**Goal**: Replace the hard-coded keychain timeout with a named constant and remove the remaining WHAT-only inline comments.

#### Commit 2 — `fix(connector): extract keychainTimeoutSeconds and drop WHAT-only inline comments`

- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Connectors/ClaudeCodeConnector.swift`
- Changes:
  1. Add a private constant near the top of `fetchOAuthToken()` (or as a `private let` on the actor):
     ```swift
     // Long enough for a cached keychain lookup; short enough to avoid stalling the poller
     private static let keychainTimeoutSeconds: Int = 10
     ```
  2. Line 173: replace `.seconds(10)` → `.seconds(keychainTimeoutSeconds)`.
  3. Line 185: replace `timeoutSeconds: 10` → `timeoutSeconds: Self.keychainTimeoutSeconds`.
  4. Lines 125 and 130: remove the trailing `// 5 hours` and `// 7 days` inline comments. The block comment at line 120–121 already explains that these values are fixed by Claude's rate-limit policy; the inline comments only restate the unit conversion, adding noise without context.
- Risk: None — purely cosmetic.

### Phase 3: Poller — document interval-drift behaviour

**Goal**: Prevent future maintainers from being surprised by the sleep-based cadence.

#### Commit 3 — `docs(poller): document sleep-based interval drift`

- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Scheduler/UsagePoller.swift`
- Changes:
  1. Add a comment immediately above `try? await Task.sleep(for: self.interval)` (currently line 32) explaining the drift:
     ```swift
     // Sleep-based cadence: effective period = poll duration + interval.
     // This is intentional — avoids overlapping polls at the cost of slight drift.
     ```
- Risk: None — comment only.

## Validation

1. Build the library target: `swift build` from `AIUsagesTrackers/` — must succeed with no warnings added.
2. Run the test suite: `swift test` — all tests must pass, confirming `@testable import` still exposes `merge(existing:incoming:)` to tests after the visibility change.
3. Grep checks:
   - `grep -n "public func merge" AIUsagesTrackers/Sources/AIUsagesTrackers/Persistence/UsagesFileManager.swift` — must return no match.
   - `grep -n "MARK.*Unsafe" AIUsagesTrackers/Sources/AIUsagesTrackers/Persistence/UsagesFileManager.swift` — must return no match.
   - `grep -n "keychainTimeoutSeconds" AIUsagesTrackers/Sources/AIUsagesTrackers/Connectors/ClaudeCodeConnector.swift` — must return ≥ 3 matches (declaration + 2 uses).
   - `grep -n "\.seconds(10)" AIUsagesTrackers/Sources/AIUsagesTrackers/Connectors/ClaudeCodeConnector.swift` — must return no match.

Acceptance criteria from `debt.md`:
- [x] `merge` is `private`; `@testable` tests still compile and pass
- [x] `keychainTimeoutSeconds` constant exists and is used
- [x] `MARK` label updated to `// MARK: - Lock-guarded internals`
- [x] Two WHAT-comments (`// 5 hours`, `// 7 days`) removed (block comment already covers the WHY)
- [x] Redundant `pollerRef` comment already absent — no action needed
