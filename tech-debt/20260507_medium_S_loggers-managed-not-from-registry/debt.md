---
title: Loggers.managed is hardcoded instead of derived from VendorRegistry
date: 2026-05-07
criticality: medium
size: S
---

## Problem

`Loggers.managed` in `Logging/Logger.swift` is a hardcoded array:

```swift
public static let managed: [FileLogger] = [app, claude, codex, copilot]
```

`LogCleaner` reads this array to enumerate every log file that should be
subject to retention-based purging. The vendor plugin contract promises that
adding a new vendor requires only: connector files, plugin registration line,
branding asset, and vendor doc — no edits to shared subsystems. But adding
a fourth vendor without also editing `Loggers.managed` means its log file
silently escapes rotation and grows unbounded.

## Impact

- **Maintainability**: `Loggers.managed` is a second place that must be
  kept in sync with `VendorRegistry.bundles`. The contract says one registry
  line — this is a hidden second registration.
- **AI code generation quality**: an agent adding a new vendor following the
  contract spec will not know to update `Loggers.managed` because the spec
  does not mention it.
- **Bug/regression risk**: medium — a missed entry means a vendor's log file
  is never purged; over weeks it can grow to the point where it touches the
  5 MB rotation threshold and gets silently dropped, losing history.

## Affected files / areas

- `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/Logger.swift` — `Loggers.managed` static let
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/LogCleaner.swift` — reads `Loggers.managed` as its default parameter

## Refactoring paths

1. In `VendorBundle`, the `logger` field is already a `FileLogger`. Derive
   the managed list from the registry at the point `LogCleaner` is
   constructed:

   ```swift
   let managedLoggers = [Loggers.app] + VendorRegistry.bundles.map(\.logger)
   let cleaner = LogCleaner(loggers: managedLoggers)
   ```

2. Remove the per-vendor named properties (`Loggers.claude`, `Loggers.codex`,
   `Loggers.copilot`) from `Loggers` — the loggers now live inside each
   `VendorBundle` and are accessed via `VendorRegistry.bundle(for:)?.logger`.
   Keep only `Loggers.app` as the cross-cutting application log.
   > **Note**: this removal requires updating every call site that reads
   > `Loggers.<vendor>` directly. Search for `Loggers.claude`, `Loggers.codex`,
   > `Loggers.copilot` and replace with `VendorRegistry.bundle(for: .<vendor>)?.logger ?? Loggers.app`.

3. Update `Loggers.setPreferences(_:)` if it iterates over named properties;
   generalise it to walk the registry instead.

4. Remove the `public static let managed` declaration from `Loggers` once
   the registry-derived list is in place everywhere.

## Acceptance criteria

- [ ] Adding a fifth vendor (no edits to `Logger.swift`) causes its log file
  to appear in `LogCleaner`'s retention pass automatically.
- [ ] `Loggers.managed` is removed or is derived from `VendorRegistry.bundles`.
- [ ] `swift test` passes.

## Additional context

Introduced in the vendor-plugin-framework epic (step 2). The named
per-vendor loggers were left in place to avoid a breaking change in step 5
(AppDelegate migration). The contract spec (`docs/VENDOR-PLUGIN-CONTRACT.md`
§9) documents the intent: "Adding a vendor does not require editing `Loggers`
or any cross-cutting subsystem."
