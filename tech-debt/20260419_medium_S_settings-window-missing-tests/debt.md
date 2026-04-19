---
title: Missing tests for settings-window preference wiring and UI error paths
date: 2026-04-19
criticality: medium
size: S
---

## Problem

The settings-window feature ships with good coverage of the preferences store
itself, but several wiring points and UI error branches have no tests. The gaps
are concentrated around the integration between the preferences store, the
`Logger`, the `AppDelegate` reconciliation logic, and the slider/toggle bindings
in `GeneralSettingsView`.

Missing tests:

- `Loggers.resolveLevel()` three branches (env var wins / prefs used when env
  absent / `.info` default).
- `Loggers.setPreferences` → `resolveLevel` path: verify an injected prefs
  level is resolved after `setPreferences` is called.
- `AppDelegate` launch-at-login reconciliation: mock `LaunchAtLoginManaging`
  returning `false` while prefs return `true`; assert prefs are flipped and
  warned.
- `AppPreferences` unrecognised `logLevel` string fallback: `"garbage"` →
  `.info`.
- `GeneralSettingsView` slider → `preferences.refreshInterval` binding: verify
  slider move updates the store.
- `GeneralSettingsView` launch-at-login toggle error path: throwing mock
  service; assert the toggle snaps back and an error surface is presented (or
  logged).
- `UsagePoller` double-nil fallback branch (the unreachable `?? .seconds(180)`
  already flagged as dead code).
- `ISODate.init(date:)` new init added in this PR: no round-trip test.
- `AppPreferences` `raw == 0` branch with an explicitly-stored `0` (not just
  "key absent").

## Impact

- **Maintainability**: untested wiring is a regression magnet — any refactor of
  `Logger.resolveLevel` or `AppDelegate.applicationDidFinishLaunching` can
  silently break the runtime preference propagation.
- **AI code generation quality**: agents touching these files will not learn
  the expected behaviour from tests.
- **Bug/regression risk**: medium — `Loggers.resolveLevel()` is on the hot
  log-writing path, and the launch-at-login reconciliation is a user-visible
  correctness concern.

## Affected files / areas

- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/LoggerTests.swift` — add
  `resolveLevel()` and `setPreferences` tests.
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/AppDelegateTests.swift` (may
  need to be created) — launch-at-login reconciliation.
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/AppPreferencesTests.swift` —
  unrecognised logLevel fallback, explicit `raw == 0`.
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/GeneralSettingsViewTests.swift`
  (may need to be created) — slider binding, toggle error path.
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsagePollerTests.swift` —
  double-nil fallback.
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/ValueObjectsTests.swift` —
  `ISODate.init(date:)` round-trip.

## Refactoring paths

1. **resolveLevel branches**: inject env via a `ProcessInfo`-like protocol (if
   not already) or shell out to a sub-process runner; assert each branch.
2. **setPreferences path**: call `setPreferences(mockPrefs)` with a known
   level, then trigger a log, assert the resolved level matches.
3. **AppDelegate reconciliation**: inject a mock `LaunchAtLoginManaging` and a
   mock `AppPreferences`; set prefs to `true` and service to `false`; invoke
   `applicationDidFinishLaunching`; assert prefs flipped to `false`.
4. **logLevel garbage**: store `"garbage"` in `UserDefaults` suite, create
   `AppPreferences`, assert `logLevel == .info`.
5. **Slider binding**: build `GeneralSettingsView` against a spy store, mutate
   the slider value via ViewInspector (or direct binding write), assert the
   store.
6. **Toggle error path**: throwing mock, tap the toggle, assert the UI does
   not stay in the `true` state.
7. **Double-nil fallback**: delete the dead path and add a test that would
   have covered it (or document why it's unreachable and remove).
8. **ISODate(date:)**: `Date() → ISODate → .date` within 1 second of the
   original.
9. **raw == 0 explicit**: `UserDefaults.set(0, forKey: ...)`, assert sentinel
   handling matches the "absent" case.

## Acceptance criteria

- [ ] `Loggers.resolveLevel()` has one test per branch (env / prefs / default).
- [ ] `setPreferences` path has a test proving prefs propagate to resolution.
- [ ] `AppDelegate` reconciliation has a test covering the `service false,
  prefs true` flip.
- [ ] `AppPreferences` has a test for the `"garbage"` logLevel fallback and
  the explicit `raw == 0` branch.
- [ ] `GeneralSettingsView` slider and launch-at-login toggle (including the
  error path) have tests.
- [ ] `UsagePoller` has a test for the double-nil fallback OR the dead path
  is removed.
- [ ] `ISODate.init(date:)` has a round-trip test.
- [ ] `swift build && swift test` green.

## Additional context

Findings 13-17, 24-27 from the multi-axis review of settings-window
(aggregate-apply phase, MED/LOW severity).
