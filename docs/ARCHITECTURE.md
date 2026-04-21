# Architecture

An executable Swift Package produces a **menubar-only** macOS application: no Dock icon, no main window, and all interaction flows through a single menu bar item.

Invariants worth preserving when modifying the codebase:

- The app sets its activation policy to `.accessory` at startup. Removing this call makes macOS show a Dock icon and breaks the menubar-only contract.
- The UI is exposed through an AppKit `NSStatusItem` owned by `AppDelegate`, not SwiftUI's `MenuBarExtra`. `MenuBarExtra` was dropped after it proved unable to render per-segment colored indicators (template tinting strips colors, mixed HStacks silently truncate). See `docs/SWIFT-MENUBAR.md` before changing anything menu-bar related. User-visible features belong inside the popover's root SwiftUI view — there is intentionally no main `WindowGroup`.

## Package structure

The Swift package is split into a library target and an executable target, plus a test target that exercises the library. The library contains all domain logic; the executable is a thin SwiftUI entry point.

## Usage-fetching pipeline

A `UsageConnector` protocol abstracts vendor-specific API access. Each connector resolves an active account and fetches usage data asynchronously. A connector may also emit additional optional per-model `timeWindow` entries when the upstream API includes them — these travel through the same persistence and display pipeline as the mandatory session and weekly aggregates, and are silently omitted when the API does not provide them. The first concrete implementation targets the Claude API via OAuth tokens stored in the macOS Keychain.

A polling actor periodically invokes all registered connectors in parallel and merges results into a shared JSON file.

## Persistence

Usage data is persisted as a JSON file at `~/.cache/ai-usages-tracker/usages.json`. The schema is a top-level `usages` array where each entry is keyed by `(vendor, account)`. A dedicated actor (`UsagesFileManager`) serializes all reads and writes for internal callers. Writes use the system's atomic write facility to prevent partial-file corruption. All public methods also acquire an advisory POSIX `flock` on a dedicated lock file (`usages.json.lock`) before touching the data file, so external readers (widgets, scripts) that do the same can safely coordinate access.

## Display pipeline

A file watcher observes `usages.json` using a hybrid strategy: a kernel `DispatchSource` fires on `.write`/`.delete`/`.rename` events, backed by a polling timer that re-checks on a configurable polling interval to handle atomic replaces and network-mount edge cases. Events are debounced to coalesce rapid successive writes into a single read.

An `@Observable` store (running on `@MainActor`) receives each new file snapshot, decodes it, locates the active Claude account, and formats the session and weekly time-window metrics into the menubar label. A secondary countdown timer periodically refreshes the remaining-time values in the display so they stay current between file changes. When data is unavailable or malformed the label falls back to `"--"`.

When the user clicks the menu bar item, `AppDelegate` toggles an `NSPopover` hosting the root SwiftUI view via `NSHostingController`. The popover renders one card per vendor/account entry, sorted alphabetically by vendor then by account (active accounts first within a vendor). Each card shows time-window metrics (gauge bar, theoretical pace marker, remaining time, next reset date) and pay-as-you-go metrics (amount with currency). An empty state is shown when no entries are available. A footer provides the app name and a Quit shortcut.

The menu bar label itself is rasterised into a non-template `NSImage` by `MenuBarLabelRenderer`, so per-tier dot colors survive macOS's template tinting. Text color is picked from the status button's `effectiveAppearance` (which tracks the menu bar, not the app) and re-rendered whenever that appearance changes.

## Account monitoring

A separate monitoring actor polls the vendor's local config file at a short fixed interval to detect account switches in real time. When a switch is detected, it updates the `isActive` flag on the corresponding persistence entry without waiting for the next usage fetch. This separation keeps account-status latency low without coupling it to the (slower) API polling cadence.

## Preferences

An injectable preferences protocol backed by `UserDefaults` is the single source of truth for user-adjustable runtime behaviour. Two consumers read it: the polling actor (refresh cadence) and the logging subsystem (verbosity). Changes made in the settings window take effect immediately — the poller re-reads the interval on every tick, and the logger resolves its effective level on every log call.

The settings window is a standard SwiftUI `Settings` scene (tabbed, HIG chrome, `Cmd+,`). Because the app uses `.accessory` activation policy, opening the window requires explicitly activating the app before sending the `showSettingsWindow:` action.

Launch-at-login state is reconciled at startup: if the user toggled the entry in System Settings > Login Items, the preferences store is updated to match the system state rather than overriding it.

## Logging

Two log files live under `~/.cache/ai-usages-tracker/`: one for the app lifecycle and poller events, another for connector-specific activity. Log level is configurable via the `AI_TRACKER_LOG_LEVEL` environment variable; when that variable is absent, the level falls back to the user's setting in the preferences window (default: info). Size-based rotation keeps each file under 5 MB with one backup. A retention purge removes entries older than 7 days from all managed log files at startup and every 24 hours, using atomic rewrites so a crash mid-cleanup leaves the previous file intact.

For authoritative details (Swift tools version, platform minimums, target layout), read the package manifest rather than mirroring them here.
