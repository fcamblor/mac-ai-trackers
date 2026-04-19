---
title: Settings window
date: 2026-04-19
---

# Implementation plan — Settings window

## Overall approach

Introduce a first-class preferences layer (`AppPreferences`, an `@Observable @MainActor` store backed by `UserDefaults` and exposed to the lib via a protocol so tests can inject an in-memory backing) that every runtime-configurable behavior reads from. Wire the `UsagePoller` interval to that store, so changes take effect immediately (the poller actor observes a snapshot each tick — no restart required, fulfilling the "no restart" acceptance criterion). Replace the placeholder `Settings { EmptyView() }` scene in `AIUsagesTrackersApp.swift` with a real SwiftUI settings view, and open it from a new cog button in the popover footer using `NSApplication.showSettingsWindow(_:)` plus `NSApp.activate(ignoringOtherApps:)` (an `.accessory` app needs to be activated explicitly to bring the window to front). For the first pass we expose three settings: **refresh interval**, **launch at login** (via `SMAppService.mainApp`), and **log level** (moved from env var to user-facing). Account management and per-vendor config stay out of scope (epic).

Rejected alternative — a bespoke `NSWindow` built in `AppDelegate`: rejected because the SwiftUI `Settings` scene already provides HIG-correct chrome (tabbable, proper window title, correctly binds `Cmd+,`) and hooking into it is a one-liner via `showSettingsWindow(_:)`. We only give up programmatic control over window lifetime, which we do not need.

Rejected alternative — keeping the env-based log level only: rejected because the epic lists log verbosity under "app-wide configuration" naturally, and surfacing it in UI does not preclude keeping the env var as a developer override (env var wins when set, per existing `FileLogger` code path).

## Impacted areas

- `AIUsagesTrackers/Sources/AIUsagesTrackers/Preferences/` — new module: `AppPreferences` protocol + `UserDefaultsAppPreferences` implementation + value objects for durations and log level choice.
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Scheduler/UsagePoller.swift` — read the refresh interval from the preferences store on each tick instead of holding a fixed `Duration`.
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/Logger.swift` — consult preferences when the env var is not set, so the user-facing setting takes effect at runtime.
- `AIUsagesTrackers/Sources/App/AIUsagesTrackersApp.swift` — replace the empty `Settings` scene with the real settings view.
- `AIUsagesTrackers/Sources/App/Views/SettingsView.swift` — new: root settings content (single-pane, tabbed only if we later split).
- `AIUsagesTrackers/Sources/App/Views/Settings/` — new: one view per settings section (`GeneralSettingsView`, `LoggingSettingsView`).
- `AIUsagesTrackers/Sources/App/AppDelegate.swift` — instantiate the preferences store, inject it into poller + logger, and add a menubar/popover command to surface the window.
- `AIUsagesTrackers/Sources/App/Views/UsageDetailsView.swift` — add a cog button in the footer that closes the popover and opens the settings window.
- `AIUsagesTrackers/Sources/App/LaunchAtLoginService.swift` — new: thin wrapper around `SMAppService.mainApp` exposing an injectable protocol.
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/AppPreferencesTests.swift` — new.
- `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsagePollerTests.swift` — extend to cover dynamic interval updates.
- `docs/ARCHITECTURE.md` — document the preferences layer and the settings-window activation dance.

## Phases and commits

### Phase 1 — Preferences infrastructure

**Goal**: land a tested, injectable preferences store that the rest of the app will consume, with no UI yet so failures stay localized.

#### Commit 1 — `feat(preferences): add AppPreferences store backed by UserDefaults`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Preferences/AppPreferences.swift`, `AIUsagesTrackers/Sources/AIUsagesTrackers/Preferences/AppPreferenceKeys.swift`, `AIUsagesTrackers/Sources/AIUsagesTrackers/Models/ValueObjects.swift` (extend)
- Changes:
  - Define a `public protocol AppPreferences: AnyObject, Observable, Sendable` with typed properties: `refreshInterval: RefreshInterval`, `launchAtLogin: Bool`, `logLevel: LogLevel`.
  - Add a `RefreshInterval` value object (struct wrapping `Duration` with `min = 30s`, `max = 30min`, `default = 180s`) in `ValueObjects.swift`. Follow `docs/SWIFT-VALUE-OBJECTS.md`: Codable, clamping init returning `Result`, `ExpressibleByIntegerLiteral` for test convenience.
  - Implement `UserDefaultsAppPreferences: @Observable @MainActor final class` reading/writing through an injected `UserDefaults` (defaults to `.standard`). Keys centralized in `AppPreferenceKeys` (enum with a `rawValue` string prefix to avoid collisions).
  - Provide a test double `InMemoryAppPreferences` in the lib (not the test target) so both production code (defaults when user defaults are absent) and tests can share it.
- Risk: UserDefaults reads on main thread only — the `@MainActor` constraint documents this. Cross-process writes (widgets) are out of scope.

#### Commit 2 — `test(preferences): cover AppPreferences read/write and clamping`
- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/AppPreferencesTests.swift`
- Changes:
  - Test that writes round-trip via a scratch `UserDefaults(suiteName:)`.
  - Test that `RefreshInterval` clamps out-of-range values (returns `.failure` below min / above max) per value-object rules.
  - Test that `@Observable` property reads fire observation on writes (use `withObservationTracking` directly).
  - Test defaults are returned when the suite is empty.
- Risk: `UserDefaults(suiteName:)` leaks across test runs — each test must call `removePersistentDomain(forName:)` in teardown.

### Phase 2 — Wire existing behaviors to preferences

**Goal**: make the poller and logger consume preferences without changing user-visible behavior (defaults match current hardcoded values).

#### Commit 3 — `refactor(poller): read refresh interval from AppPreferences`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Scheduler/UsagePoller.swift`, `AIUsagesTrackers/Sources/App/AppDelegate.swift`, `AIUsagesTrackers/Tests/AIUsagesTrackersTests/UsagePollerTests.swift`
- Changes:
  - `UsagePoller.init` takes an `AppPreferences` (default `UserDefaultsAppPreferences.shared`). The `interval` stored property is removed; each loop iteration reads `await MainActor.run { preferences.refreshInterval }` to pick up live changes.
  - `AppDelegate` constructs `UserDefaultsAppPreferences` once and passes it to both `UsagePoller` and the logger.
  - Test: inject an `InMemoryAppPreferences`, start the poller with interval `.seconds(30)`, mutate it to `.seconds(60)` mid-run, assert the next sleep uses the new value. Use `eventually()` poll helper per W3.
- Risk: The `await MainActor.run` call from inside the poller actor adds one hop per tick. Acceptable (polling cadence is minutes). Alternative (snapshot at `start()`) would break the "takes effect without restart" acceptance criterion.

#### Commit 4 — `refactor(logger): honor AppPreferences.logLevel when env var unset`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/Logger.swift`, `AIUsagesTrackers/Tests/AIUsagesTrackersTests/LoggerTests.swift`
- Changes:
  - `FileLogger` gains an optional `AppPreferences` dependency. Resolution order: env var (`AI_TRACKER_LOG_LEVEL`) wins, then `preferences?.logLevel`, then the existing default.
  - Loggers singletons (`Loggers.app`, `Loggers.claude`) lazily read the shared preferences.
  - Test: set preferences to `.debug`, no env var, assert logger accepts debug lines; then set env var to `.error`, assert debug lines are dropped (env wins).
- Risk: Singleton coupling. Acceptable for now — the preferences store is effectively process-wide anyway.

### Phase 3 — Settings window UI

**Goal**: HIG-correct settings window driven by `AppPreferences`.

#### Commit 5 — `feat(settings): replace empty Settings scene with tabbed SettingsView`
- Files: `AIUsagesTrackers/Sources/App/AIUsagesTrackersApp.swift`, `AIUsagesTrackers/Sources/App/Views/SettingsView.swift`, `AIUsagesTrackers/Sources/App/Views/Settings/GeneralSettingsView.swift`, `AIUsagesTrackers/Sources/App/Views/Settings/LoggingSettingsView.swift`
- Changes:
  - `AIUsagesTrackersApp.body` replaces `Settings { EmptyView() }` with `Settings { SettingsView(preferences: AppDelegate.sharedPreferences) }`. The shared reference is exposed by the delegate as a `@MainActor static` so the Settings scene (constructed before `applicationDidFinishLaunching` runs) picks it up after init.
  - `SettingsView` is a `TabView` with a "General" tab (refresh interval `Slider` + numeric `TextField`, launch-at-login `Toggle`) and a "Logging" tab (log-level `Picker`). Uses SwiftUI `Form` with `.formStyle(.grouped)` to match macOS 14 conventions.
  - Bindings write straight through to the `AppPreferences` store — no apply/cancel button, matching macOS HIG for preferences.
- Risk: `Settings` scene is constructed eagerly but its content view is only instantiated when shown, so the shared-preferences lookup is safe. Double-check by running the app with the window closed — there must be no AppKit allocation until the user opens it.

#### Commit 6 — `feat(settings): open settings window from popover cog button`
- Files: `AIUsagesTrackers/Sources/App/Views/UsageDetailsView.swift`, `AIUsagesTrackers/Sources/App/AppDelegate.swift`
- Changes:
  - Add a cog button (`Image(systemName: "gearshape")`) in the footer, between the "AI Usages Tracker" label and the refresh button. On tap: call `onOpenSettings` closure supplied by the delegate.
  - `AppDelegate.openSettings()` performs, in order: `popover.performClose(nil)`, `NSApp.activate(ignoringOtherApps: true)`, and `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)` (macOS 14 replacement for the deprecated `showPreferencesWindow:` selector).
  - Add `keyboardShortcut(",", modifiers: .command)` on the cog button to match `Cmd+,`.
  - Wire the closure into `UsageDetailsView` via its initializer (same pattern as `onRefresh`, `onQuit`).
- Risk: `.accessory` activation policy keeps the app out of the Dock, but `NSApp.activate` still focuses the settings window. If the user switches apps while the window is open, the window is dismissed by the system (expected HIG behavior for accessory apps).

### Phase 4 — Launch at login

**Goal**: the launch-at-login toggle actually works.

#### Commit 7 — `feat(settings): implement launch-at-login via SMAppService`
- Files: `AIUsagesTrackers/Sources/App/LaunchAtLoginService.swift`, `AIUsagesTrackers/Sources/App/Views/Settings/GeneralSettingsView.swift`, `AIUsagesTrackers/Sources/App/AppDelegate.swift`
- Changes:
  - `LaunchAtLoginService` wraps `SMAppService.mainApp`, exposing `isEnabled: Bool { get }` and `setEnabled(_:) throws`. An injectable protocol `LaunchAtLoginManaging` lets us stub in tests.
  - `GeneralSettingsView`'s toggle now binds through the service: on toggle, call `register()` / `unregister()`, then update the preferences store only on success. On failure, surface the error via `Alert`.
  - `AppDelegate` reconciles preferences and service state at launch: if `preferences.launchAtLogin != service.isEnabled`, the service state wins (user may have disabled the app in System Settings > Login Items) and preferences are updated.
- Risk: `SMAppService` requires the app to be signed with a valid Team ID for production use. For unsigned dev builds, register/unregister silently no-ops; we log at `.warning` when unregistered status is unexpected. Does not block the feature.

### Phase 5 — Documentation and closure

**Goal**: reflect the new layer in the architecture doc; keep docs focused, no drift-prone lists.

#### Commit 8 — `docs(architecture): describe preferences layer and settings window`
- Files: `docs/ARCHITECTURE.md`
- Changes:
  - Add a "Preferences" section explaining the `AppPreferences` role (single source of truth for user-adjustable runtime behavior, injectable) and naming the two consumers (poller cadence, logger verbosity) in terms of responsibilities rather than symbols.
  - Mention the settings window activation pattern (`.accessory` app must call `NSApp.activate` before `showSettingsWindow:`).
- Risk: none.

## Validation

Run from the repo root:

```bash
cd AIUsagesTrackers
swift build                      # SwiftLint plugin runs: E1/E2/W1/W3/W4/W5 must stay green
swift test                       # all tests pass, including the two new suites
```

Manual acceptance (mirrors the criteria in `roadmap/settings-window.md`):

1. Launch the app. Click the menu bar icon → popover shows. Click the cog button → popover closes, settings window appears, menu bar icon remains clickable.
2. Change **refresh interval** from 180s to 60s. Observe in `~/.cache/ai-usages-tracker/app.log` that the next poll tick fires on the new cadence without a restart.
3. Change **log level** to `debug` (env var unset). New debug lines appear in the logs immediately.
4. Toggle **launch at login** on; verify the entry appears in System Settings > General > Login Items. Toggle off; entry disappears.
5. Dismiss the settings window with `Cmd+W` or the close button — the menu bar icon still responds to clicks.
6. Open the settings window a second time via the cog button — no crash, fields reflect the previously-saved values.
