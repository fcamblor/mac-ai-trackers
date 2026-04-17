# Architecture

An executable Swift Package produces a **menubar-only** macOS application: no Dock icon, no main window, and all interaction flows through a single menu bar item.

Invariants worth preserving when modifying the codebase:

- The app sets its activation policy to `.accessory` at startup. Removing this call makes macOS show a Dock icon and breaks the menubar-only contract.
- The UI is exposed through a SwiftUI `MenuBarExtra` scene. User-visible features belong inside that scene or in views it references — there is intentionally no main `WindowGroup`.

## Package structure

The Swift package is split into a library target and an executable target, plus a test target that exercises the library. The library contains all domain logic; the executable is a thin SwiftUI entry point.

## Usage-fetching pipeline

A `UsageConnector` protocol abstracts vendor-specific API access. Each connector resolves an active account and fetches usage data asynchronously. The first concrete implementation targets the Claude API via OAuth tokens stored in the macOS Keychain.

A polling actor periodically invokes all registered connectors in parallel and merges results into a shared JSON file.

## Persistence

Usage data is persisted as a JSON file at `~/.cache/ai-usages-tracker/usages.json`. The schema is a top-level `usages` array where each entry is keyed by `(vendor, account)`. A dedicated actor (`UsagesFileManager`) serializes all reads and writes for internal callers, so no POSIX file lock is needed internally. Writes use the system's atomic write facility to prevent partial-file corruption.

Note: external processes reading the file (widgets, scripts) must tolerate a brief window where the file contains partial JSON between the OS atomic rename and their `read` call. A future addition of `flock` (see `docs/SWIFT-IO-ROBUSTNESS.md`) would remove this window.

## Account monitoring

A separate monitoring actor polls the vendor's local config file at a short fixed interval to detect account switches in real time. When a switch is detected, it updates the `isActive` flag on the corresponding persistence entry without waiting for the next usage fetch. This separation keeps account-status latency low without coupling it to the (slower) API polling cadence.

## Logging

Two log files live under `~/.cache/ai-usages-tracker/`: one for the app lifecycle and poller events, another for connector-specific activity. Log level is configurable via the `AI_TRACKER_LOG_LEVEL` environment variable. Size-based rotation keeps each file under 5 MB with one backup.

For authoritative details (Swift tools version, platform minimums, target layout), read the package manifest rather than mirroring them here.
