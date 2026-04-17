---
title: Concurrency and blocking issues in Logger, FileManager and Connector
date: 2026-04-17
criticality: high
size: M
---

## Problem

Three concurrency/blocking hazards remain after the initial implementation of the claude-usages-connector feature:

1. **Logger.swift:56** — `queue.sync` in `append()` blocks the caller. When `log()` is called from an async context (actor, Task), this blocks a thread from Swift's cooperative thread pool, degrading throughput under load.

2. **UsagesFileManager.swift:110** — `flock(fd, LOCK_EX)` acquires an exclusive lock with no timeout. If another process holds the lock (crash, hung process), the cooperative thread is blocked indefinitely with no way to abort.

3. **ClaudeCodeConnector.swift:12** — `nonisolated(unsafe) static let isoFormatter` is declared as shared across all callers. `ISO8601DateFormatter` is not thread-safe (`NSFormatter` subclass). Currently safe because only one actor uses it, but fragile if the actor is ever called from multiple isolation contexts.

## Impact

- **Maintainability**: Blocking patterns in async Swift code are hard to reason about and violate structured-concurrency contracts.
- **AI code generation quality**: Future agents may copy these patterns to other connectors, propagating blocking anti-patterns.
- **Bug/regression risk**: Item 2 (flock no-timeout) can cause the app to hang silently; item 3 can cause data races if concurrency model evolves.

## Affected files / areas

- `Sources/AIUsagesTrackersLib/Logger.swift:56` — `queue.sync` in `append`
- `Sources/AIUsagesTrackersLib/UsagesFileManager.swift:110` — `flock(LOCK_EX)` without timeout
- `Sources/AIUsagesTrackersLib/ClaudeCodeConnector.swift:12` — `nonisolated(unsafe) static` formatter

## Refactoring paths

1. **Logger** — Replace `queue.sync` with `queue.async` in `append()`. Callers don't need a return value from logging, so fire-and-forget is correct. Ensure ordering is preserved (serial queue already guarantees this).

2. **UsagesFileManager** — Replace `flock(fd, LOCK_EX)` with a retry loop using `LOCK_NB` (non-blocking) + `usleep`, aborting after a configurable deadline (e.g. 5 seconds). Log a warning on timeout and return `nil` from `withFlock`.

3. **ClaudeCodeConnector** — Either (a) instantiate `ISO8601DateFormatter` inside the `queue.sync` block in Logger (already protected there), or (b) move the formatter inside `ClaudeCodeConnector` as an actor-isolated property (not `nonisolated`), or (c) protect it with its own `NSLock`.

## Acceptance criteria

- [ ] `Logger.append()` uses `queue.async` instead of `queue.sync`
- [ ] `withFlock` has a configurable timeout and returns `nil` with a log warning on expiry
- [ ] `isoFormatter` is either actor-isolated or protected against concurrent access
- [ ] All existing tests still pass; add a test that calls `log()` from a `TaskGroup` (20 concurrent calls) without data races

## Additional context

Identified during the 3rd review pass of fcr-dev run `77047594ea8f699acd4d6dcb2d3bc445` (branch `feat/claude-usages-connector`). Items #3, #4, #5 of that review. Accepted at the time to keep the PR scope focused.
