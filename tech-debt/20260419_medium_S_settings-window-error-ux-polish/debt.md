---
title: Settings window — error handling and toggle UX polish
date: 2026-04-19
criticality: medium
size: S
---

## Problem

Four issues touch the error-surfacing and the perceived quality of the settings
UI. Individually each is small, together they shape the user's trust in the
preferences window.

1. **`AppDelegate.swift:49-50`** — when `SMAppService.status` returns
   `.requiresApproval`, the reconciliation silently flips
   `launchAtLogin` to `false`. The user sees a toggle that un-checks itself
   with no indication of why. At minimum the state should be logged; ideally a
   UI surface should explain that user approval is required in System Settings.

2. **`LaunchAtLoginService.swift:23-28`** — the raw `SMAppService` error is
   propagated without context. Callers cannot distinguish between "not
   approved", "already enabled", and "unknown failure". Wrap in a domain error
   `LaunchAtLoginError` carrying the attempted `enabled` flag and the
   underlying error.

3. **`GeneralSettingsView.swift:42-49`** — the launch-at-login toggle flashes
   briefly to the new state on error before snapping back. The UI source of
   truth should be a `@State` seeded from preferences, mutated only after the
   service call succeeds, so the user never sees a phantom state.

4. **`AppPreferences.swift:28-29`** — the sentinel value `0` for
   `refreshInterval` conflates "never set" with an impossible clamped value.
   Add a comment making the convention explicit, or use `nil` / a distinct
   sentinel.

## Impact

- **Maintainability**: error masking in reconciliation makes debugging
  launch-at-login issues harder.
- **AI code generation quality**: agents reading the reconciliation code will
  not understand that the silent flip is a known limitation, not a bug.
- **Bug/regression risk**: low for data; medium for perceived quality — users
  may lose trust in the toggle.

## Affected files / areas

- `AIUsagesTrackers/Sources/App/AppDelegate.swift:47-51`
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Services/LaunchAtLoginService.swift:23-28`
- `AIUsagesTrackers/Sources/App/Views/GeneralSettingsView.swift:40-57`
- `AIUsagesTrackers/Sources/AIUsagesTrackers/Preferences/AppPreferences.swift:28-30`

## Refactoring paths

1. **AppDelegate reconciliation**: in the `.requiresApproval` branch, call
   `Loggers.app.log(.warning, "Launch at login requires user approval; prefs
   flipped to false")`. Optionally add a boolean `requiresApprovalWarning` to
   `AppPreferences` that the settings UI can surface.

2. **LaunchAtLoginError**: introduce
   ```swift
   public enum LaunchAtLoginError: Error {
       case requiresApproval(attemptedEnabled: Bool)
       case unexpected(attemptedEnabled: Bool, underlying: Error)
   }
   ```
   and map `SMAppService` outcomes into it.

3. **Toggle UX**: replace the direct `preferences.launchAtLogin` binding with
   a `@State private var isEnabled: Bool` initialised from preferences.
   `onChange(of: isEnabled)` calls the service, only persists to preferences
   on success, rolls back `isEnabled` on failure, and presents an alert or
   inline error text.

4. **Sentinel clarification**: either replace `0` with `nil` (using an
   optional in `UserDefaults`), or add a `// SENTINEL:` comment on the
   `refreshInterval` storage site explaining that `0` means "never stored,
   use default".

## Acceptance criteria

- [ ] The `.requiresApproval` reconciliation path logs a warning AND provides a
  UI surface (even a read-only hint) explaining why launch-at-login is off.
- [ ] `LaunchAtLoginService` throws `LaunchAtLoginError` with associated values,
  no raw `SMAppService` error leaks to callers.
- [ ] The launch-at-login toggle never shows a phantom "checked" state on
  error; the UI source of truth is a `@State` that only flips on success.
- [ ] The `0` sentinel in `AppPreferences.refreshInterval` is either replaced
  with `nil` or documented with a `// SENTINEL:` comment.
- [ ] Corresponding tests exist (see the tests debt entry).

## Additional context

Findings 11, 12, 22, 23 from the multi-axis review of settings-window
(aggregate-apply phase, MED/LOW severity).
