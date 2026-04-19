---
title: LogCleaner stop() does not await task, Logger purge has TOCTOU guard
date: 2026-04-19
criticality: medium
size: S
---

## Problem

Two robustness gaps were identified in the log-cleanup implementation:

**1. `LogCleaner.stop()` does not await the running task.**

`stop()` cancels the internal `Task` and nils it synchronously, but does not
`await task?.value`. If the app calls `quit()` immediately after `stop()`, a
`cleanOnce()` that is mid-purge will continue running in the background. The
atomic write (`Data.write(to:options:.atomic)`) mitigates data corruption, but
the window still exists: on a very slow disk, the in-flight write may be
interrupted by process termination before the atomic rename completes.

**2. `Logger.purgeFile` checks `fileExists` before reading (TOCTOU).**

`purgeFile` guards on `FileManager.default.fileExists(atPath:)` before calling
`String(contentsOfFile:)`. If another process removes the file between the guard
and the read, `String(contentsOfFile:)` throws — which is caught by the `do/catch`
below. The guard is therefore misleading: it suggests that a missing file is a
silent no-op, while a concurrent deletion after the guard would surface as a
`.readFailed` error. The intent is correct but the code structure makes it
invisible.

## Impact

- **Maintainability**: the TOCTOU guard pattern will be copied by agents working
  on adjacent I/O code, spreading a misleading idiom.
- **AI code generation quality**: agents reading `LogCleaner.stop()` may assume
  callers need not await cleanup completion and replicate that pattern.
- **Bug/regression risk**: low in normal operation (atomic writes protect data),
  but on a slow or very busy disk the mid-purge quit window could produce a
  truncated log file.

## Affected files / areas

- `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/LogCleaner.swift` — `stop()`
  method (lines 69-71).
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/Logger.swift` — `purgeFile`
  function, `fileExists` guard.

## Refactoring paths

### 1. Make `stop()` async and await the task

```swift
public func stop() async {
    task?.cancel()
    await task?.value
    task = nil
}
```

Update the caller in `AppDelegate.quit()` to `await cleaner.stop()`. Because
`AppDelegate` is `@MainActor`, the await is already safe. Ensure all test call
sites update accordingly.

### 2. Remove the TOCTOU `fileExists` guard in `purgeFile`

Remove the `guard FileManager.default.fileExists(atPath: path) else { return }`
line. Handle the missing-file case explicitly in the `do/catch`:

```swift
} catch let err as NSError where err.domain == NSCocoaErrorDomain
    && err.code == NSFileReadNoSuchFileError {
    return // file vanished between schedule and read — normal, skip
} catch {
    throw LogPurgeError.readFailed(path: path, underlying: error)
}
```

This makes the silent-skip path explicit and maps every other read failure to a
typed error.

## Acceptance criteria

- [ ] `LogCleaner.stop()` is `async` and `await`s the task before nilling it.
- [ ] `AppDelegate.quit()` calls `await cleaner.stop()`.
- [ ] A test verifies that after `stop()` returns, no further purge work runs
  (i.e. the task is truly complete, not just cancelled).
- [ ] `purgeFile` contains no `fileExists` guard; missing-file is handled
  explicitly in the `catch` block.
- [ ] `swift build` passes and all existing log-cleanup tests remain green.

## Additional context

Findings 19 and 20 from the multi-axis review of the log-cleanup feature
(aggregate-apply phase, LOW severity). Deferred to keep the PR focused on
critical and high fixes. The atomic-write mitigation means there is no data
corruption risk in current production; the fix improves code clarity and removes
a latent quit-race.
