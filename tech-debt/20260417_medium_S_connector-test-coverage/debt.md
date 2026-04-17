---
title: Missing test coverage in ClaudeCodeConnector and UsagePoller
date: 2026-04-17
criticality: medium
size: S
---

## Problem

Four test gaps remain in the connector and poller test suites after the initial implementation:

1. **ClaudeCodeConnectorTests.swift:127** — The success path test only asserts the first metric (session). The second metric (weekly, `0.08 → 8%`) is not verified.

2. **ClaudeCodeConnectorTests.swift** — No test covers a transport-level URLSession error (network unreachable, timeout). Only HTTP status errors are currently tested.

3. **UsagePollerTests.swift** — `pollOnce()` with zero connectors (`connectors: []`) hits an early return (`guard !entries.isEmpty`) that is never exercised.

4. **ClaudeCodeConnectorTests.swift** — No test verifies that the `Authorization` and `anthropic-beta` HTTP headers are actually sent in outgoing requests.

## Impact

- **Maintainability**: Missing edge-case tests mean regressions in error handling or header construction go undetected.
- **AI code generation quality**: Future agents extending the connector have no test templates for transport errors or header verification.
- **Bug/regression risk**: A header typo or missing auth header would not be caught by the test suite.

## Affected files / areas

- `Tests/AIUsagesTrackersLibTests/ClaudeCodeConnectorTests.swift` — success test incomplete, missing transport error + header tests
- `Tests/AIUsagesTrackersLibTests/UsagePollerTests.swift` — missing zero-connectors path

## Refactoring paths

1. In the existing success test, add assertions for the second `VendorUsageEntry` metric (weekly: `usagePercent == 8`).

2. Add a test using `MockURLProtocol` that has the session throw a `URLError(.notConnectedToInternet)`. Assert the result contains a `lastError` with type `api_error`.

3. Add a test calling `pollOnce()` on a `UsagePoller` with an empty `connectors` array. Assert `usagesFileManager.updateCallCount == 0` (no write attempted).

4. In `MockURLProtocol`, capture the last `URLRequest` and add assertions on `request.value(forHTTPHeaderField: "Authorization")` and `request.value(forHTTPHeaderField: "anthropic-beta")`.

## Acceptance criteria

- [ ] Success test asserts both session and weekly metrics
- [ ] Transport-level URLSession error is covered with `URLError`
- [ ] `pollOnce()` with `connectors: []` is tested and does not write
- [ ] Outgoing `Authorization` and `anthropic-beta` headers are verified in at least one test

## Additional context

Identified during the 3rd review pass of fcr-dev run `77047594ea8f699acd4d6dcb2d3bc445` (branch `feat/claude-usages-connector`). Items #6, #7, #8, #15 of that review. Deferred to keep the PR focused on functional correctness.
