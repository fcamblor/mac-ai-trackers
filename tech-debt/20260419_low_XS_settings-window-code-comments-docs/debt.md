---
title: Settings window — dead code, WHAT comments, and DEVELOPMENT doc drift
date: 2026-04-19
criticality: low
size: XS
---

## Problem

Seven small cosmetic / documentary issues across the settings-window feature.
None affects correctness; they only degrade code readability and doc accuracy.

Code hygiene:

- `LoggingSettingsView.swift:7-9` — `envOverrideActive` reads `ProcessInfo.env`
  on every `body` evaluation. Compute once as `static let` or at struct
  init.
- `UsagePoller.swift:56` — `?? .seconds(180)` fallback is unreachable dead
  code (the preceding chain never yields `nil`). Remove the fallback or, if
  kept as a safety net, extract `.seconds(180)` as a named constant alongside
  the default definition.

Comment quality:

- `Logger.swift:48-49` — WHAT comment on the singleton-level tracking. Rewrite
  to the WHY: "Used for singleton loggers whose level must track live
  preference changes without reconstruction."
- `UsagePoller.swift:50-51` — WHAT comment on the per-tick interval read.
  Rewrite: "Re-read on every tick so preference changes take effect
  immediately without restarting the poller."
- `AppPreferences.swift:56` — misleading comment ("production defaults-absent
  paths"); the helper is actually test-only in practice. Rewrite to reflect
  that it lives in the lib target for test importability.
- `AppPreferencesTests.swift:117-118` — WHAT comment `// Verify the raw value
  stored in defaults` restates the assertion below. Delete.

Doc drift:

- `docs/DEVELOPMENT.md:10` — current note says the log-level env var is the
  sole control. Update: the env var overrides the settings-window preference
  when set, otherwise the preference wins.

## Impact

- **Maintainability**: dead code accumulates and misleads readers into
  believing the fallback path is meaningful.
- **AI code generation quality**: agents copying the WHAT comments will
  replicate the anti-pattern on nearby code.
- **Bug/regression risk**: none — all issues are cosmetic or documentary.

## Affected files / areas

- `AIUsagesTrackers/Sources/App/Views/LoggingSettingsView.swift:7-9`
- `AIUsagesTrackers/Sources/AIUsagesTrackers/UsagePoller.swift:50-51,56`
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/Logger.swift:48-49`
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Preferences/AppPreferences.swift:56`
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/AppPreferencesTests.swift:117-118`
- `docs/DEVELOPMENT.md:10`

## Refactoring paths

1. **envOverrideActive**: hoist to a `static let` on the view struct (one-time
   read at first access).
2. **UsagePoller fallback**: either delete the `?? .seconds(180)` or extract
   `defaultInterval` as a named constant referenced by both the preferences
   default and this fallback.
3. **Rewrite comments** at the four flagged sites; delete the test-file WHAT
   comment outright.
4. **docs/DEVELOPMENT.md**: change the log-level sentence to reflect the
   env-var-over-preference precedence introduced by the settings-window
   feature. Keep it brief; point readers at the Preferences architecture
   section rather than duplicating.

## Acceptance criteria

- [ ] `envOverrideActive` is read at most once per view lifetime.
- [ ] `UsagePoller` has no unreachable fallback; any retained default is a
  named constant.
- [ ] No WHAT comment remains at the flagged sites.
- [ ] `docs/DEVELOPMENT.md` log-level note accurately describes the env-var
  vs preference precedence.
- [ ] `swift build` passes with zero SwiftLint warnings.

## Additional context

Findings 9, 10, 18, 19, 20, 21, 28 from the multi-axis review of
settings-window (aggregate-apply phase, MED/LOW severity).
