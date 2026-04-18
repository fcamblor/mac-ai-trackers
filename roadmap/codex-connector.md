# Codex connector

## Goal

Allow users who use the OpenAI Codex CLI to track their Codex usage alongside Claude in the same menu bar app, without switching tools.

## Dependencies

- [Vendor status monitor](vendor-status-monitor.md) — the JSON schema restructuring it introduces (vendor-keyed top level) must be in place before a second vendor's data can be persisted cleanly.
- [Settings window](settings-window.md) — the settings window must exist so that per-vendor menu bar display preferences (which vendors appear in the compact label) can be configured before Codex is wired in.

## Scope

- Add `Vendor.codex` static constant to `ValueObjects.swift`.
- Add `Loggers.codex` dedicated logger (`codex-usages-connector.log`) in `Logger.swift`.
- Implement a `CodexConnector` actor conforming to `UsageConnector`:
  - `resolveActiveAccount()` — reads the active account email from the Codex CLI config file (expected at `~/.codex/config.json`; exact schema TBD via inspection of a live installation).
  - `fetchUsages()` — retrieves the auth credential (API key or OAuth token; see Notes), calls the OpenAI usage endpoint, parses the response into `[VendorUsageEntry]` with `vendor = .codex`.
  - All dependencies (`URLSession`, credential provider, config path, logger) injected via constructor for testability — same pattern as `ClaudeCodeConnector`.
- Implement a `CodexActiveAccountMonitor` actor (if Codex CLI supports multiple accounts) — polls `~/.codex/config.json` at the same 15-second interval as its Claude counterpart; triggers a forced poll on account switch.
- Register `CodexConnector()` (and the monitor if applicable) in `AppDelegate.applicationDidFinishLaunching`.
- Generalize `UsageStore` multi-vendor display:
  - Remove the hardcoded `private static let targetVendor: Vendor = .claude`.
  - Show a card per vendor that has at least one active account in the persisted file.
  - Menu bar compact label strategy for multiple active vendors is a design decision to make during implementation (e.g. concatenate all active vendors' key metrics, or show only the most-recently-updated one).
- Test coverage:
  - `CodexConnectorTests.swift` — mirrors the structure of `ClaudeCodeConnectorTests.swift`: mock credential provider, mock `URLSession`, happy path, HTTP errors, parse errors, account-unknown path, rate-limit (HTTP 429) path.
  - `CodexActiveAccountMonitorTests.swift` (if monitor is implemented) — mirrors `ClaudeActiveAccountMonitorTests.swift`.
  - Extend `UsageStoreTests.swift` to cover multi-vendor rendering.

**Out of scope**

- A settings UI for entering the OpenAI API key (deferred to the Settings window epic).
- Codex-specific plan or quota information beyond what the OpenAI usage API exposes.
- Usage metrics normalization or cross-vendor comparison views.
- Vendor status / outage display for Codex (covered by the Vendor status monitor epic).

## Acceptance criteria

- The popover shows a Codex card with its usage metrics when a valid Codex credential is present and the API call succeeds.
- The popover shows no Codex card (or a graceful error state) when no credential is found or the API call fails.
- Switching the active Codex account (if applicable) triggers a refresh within 15 seconds, consistent with the Claude monitor behaviour.
- Adding Codex does not regress Claude's existing display or polling behaviour.
- All new public methods have at least one test; all error paths are exercised.
- SwiftLint reports zero errors and zero new warnings on the added files.

## Notes

- **Credential mechanism (TBD)**: Codex CLI most likely stores its OpenAI API key in one of: the config file (`~/.codex/config.json`), the macOS Keychain (service name TBD), or the `OPENAI_API_KEY` environment variable. Inspect a live `~/.codex/` directory before implementing `fetchCredential()` to confirm the actual storage location and format.
- **Usage API (TBD)**: OpenAI exposes usage data at `https://api.openai.com/v1/usage` (legacy) and under the newer `/v1/organization/usage/*` family of endpoints. The exact endpoint and response schema that maps to Codex CLI plan limits must be confirmed against the live API before implementing `parseAPIResponse()`.
- **Metric kinds**: Claude exposes time-windowed utilization percentages (`five_hour`, `seven_day`). OpenAI may return token counts or cost figures instead. Map whatever the API provides to the existing `UsageMetric` types (`timeWindow` or `payAsYouGo`); add a new `MetricKind` case only if neither fits.
- **Multi-vendor `UsageStore`**: The current `private static let targetVendor: Vendor = .claude` single-vendor filter in `UsageStore` must be removed. The `AccountCardView` is already vendor-agnostic (renders `vendor.rawValue.capitalized`), so the popover requires no view changes beyond receiving entries for both vendors.
- **`AppDelegate` wiring**: `ClaudeActiveAccountMonitor` is a concrete type held by name in `AppDelegate`. If a second monitor is added for Codex, consider extracting a shared `ActiveAccountMonitoring` protocol to avoid the delegate growing unbounded with one typed property per vendor.
