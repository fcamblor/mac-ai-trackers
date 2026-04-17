---
title: Missing test coverage in ClaudeCodeConnector and UsagePoller
date: 2026-04-18
---

## Drift from original debt description

Debt item 1 ("success test only asserts the first metric") is already resolved: `successPath()` in
`ClaudeCodeConnectorTests.swift` (lines 134–139) already asserts the weekly metric
(`pct == 8`, `duration == 10080`). Only items 2, 3, and 4 remain open.

## Overall approach

Extend `MockURLProtocol` with two static hooks — a captured-request slot for header inspection and
an error-injection slot for transport failures — then add three focused tests: transport-level
`URLError`, outgoing header values, and `pollOnce()` with zero connectors. All changes are confined
to the two test files; no production code is touched.

## Phases and commits

### Phase 1: Extend MockURLProtocol

**Goal**: Make `MockURLProtocol` capable of (a) recording the last outgoing request and (b)
simulating a transport-level error so that the three new tests can assert on those behaviours.

#### Commit 1 — `test(connector): extend MockURLProtocol with request capture and error injection`

- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/ClaudeCodeConnectorTests.swift`
- Changes:
  1. Add `nonisolated(unsafe) static var capturedRequest: URLRequest?` below the existing
     `handler` property.
  2. Add `nonisolated(unsafe) static var errorToThrow: Error?` below `capturedRequest`.
  3. In `startLoading()`, before the `guard let handler` line, assign
     `Self.capturedRequest = request`.
  4. After the `capturedRequest` assignment, add an early-exit branch:
     ```swift
     if let error = Self.errorToThrow {
         client?.urlProtocol(self, didFailWithError: error)
         return
     }
     ```
  5. In the `makeConnector(dir:tokenProvider:)` helper, reset both new statics at the top of each
     test (or document that callers are responsible). It is safer to reset in a helper; add a
     private `resetMockURLProtocol()` function that sets both to `nil` and call it at the start
     of every new `@Test` body that configures `MockURLProtocol`.
     Actually, the cleaner approach is to nil them out inside each test that uses them, since the
     suite is already `.serialized`.
- Risk: `MockURLProtocol` is `nonisolated(unsafe)` for its existing `handler`. The same approach
  is safe here because the suite is marked `.serialized` — only one test runs at a time.

### Phase 2: Add the three missing tests

**Goal**: Cover the three remaining acceptance criteria from `debt.md`.

#### Commit 2 — `test(connector): verify outgoing Authorization and anthropic-beta headers`

- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/ClaudeCodeConnectorTests.swift`
- Changes: Add a new `@Test` inside `ClaudeCodeConnectorFetchTests` named
  `"success path sends correct Authorization and anthropic-beta headers"`:
  1. Reset `MockURLProtocol.capturedRequest = nil` and `MockURLProtocol.errorToThrow = nil`.
  2. Set `MockURLProtocol.handler` to return a valid 200 response with a well-formed payload
     (re-use the same JSON as `successPath()`).
  3. Call `connector.fetchUsages()`.
  4. Assert `MockURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization") ==
     "Bearer fake-token"`.
  5. Assert `MockURLProtocol.capturedRequest?.value(forHTTPHeaderField: "anthropic-beta") ==
     "oauth-2025-04-20"`.
- Risk: `capturedRequest` is set in `startLoading()` which runs on a URLSession delegate thread.
  Because the suite is `.serialized` and the `await` on `fetchUsages()` ensures the protocol has
  finished before assertions run, there is no data race.

#### Commit 3 — `test(connector): transport URLError returns api_error entry`

- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/ClaudeCodeConnectorTests.swift`
- Changes: Add a new `@Test` inside `ClaudeCodeConnectorFetchTests` named
  `"URLError returns api_error entry"`:
  1. Reset `MockURLProtocol.capturedRequest = nil`.
  2. Set `MockURLProtocol.errorToThrow = URLError(.notConnectedToInternet)`.
  3. Set `MockURLProtocol.handler = nil` (ensure the error path is taken, not the handler).
  4. Call `connector.fetchUsages()`.
  5. Assert `entries.count == 1`.
  6. Assert `entries[0].lastError?.type == "api_error"`.
  7. Assert `entries[0].metrics.isEmpty`.
  8. Clear `MockURLProtocol.errorToThrow = nil` after the test (or rely on the next test's reset).
- Risk: None beyond what is covered by `MockURLProtocol`'s error-injection mechanism above.

#### Commit 4 — `test(poller): pollOnce with zero connectors skips file write`

- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsagePollerTests.swift`
- Changes: Add a new `@Test` inside `UsagePollerTests` named
  `"pollOnce with no connectors skips file write"`:
  1. Create a temp dir, logger, and `UsagesFileManager`.
  2. Create a `UsagePoller` with `connectors: []`.
  3. Call `await poller.pollOnce()`.
  4. Read the file with `await fm.read()`.
  5. Assert `result.usages.isEmpty` — the `guard !entries.isEmpty` early return in `pollOnce`
     must prevent `fileManager.update(with:)` from being called.
- Risk: None; this is a pure logic path with no external dependencies.

## Validation

Run from `AIUsagesTrackers/`:

```
swift test
```

All four acceptance criteria in `debt.md` must be green:

- [x] Success test asserts both session and weekly metrics — already passing before this work.
- [ ] Transport-level URLSession error covered with `URLError` → covered by commit 3.
- [ ] `pollOnce()` with `connectors: []` does not write → covered by commit 4.
- [ ] Outgoing `Authorization` and `anthropic-beta` headers verified → covered by commit 2.

The test suite must pass with zero failures and zero warnings about untested paths.
