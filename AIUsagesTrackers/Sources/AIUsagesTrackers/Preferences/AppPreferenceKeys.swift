import Foundation

/// Centralised UserDefaults key names, prefixed to avoid collisions with
/// other subsystems that might share the same defaults suite.
public enum AppPreferenceKeys: String {
    case refreshIntervalSeconds = "ai-tracker.refreshIntervalSeconds"
    case launchAtLogin = "ai-tracker.launchAtLogin"
    case logLevel = "ai-tracker.logLevel"
    case menuBarChips = "ai-tracker.menuBarChips"
    case menuBarChipsInitialized = "ai-tracker.menuBarChipsInitialized"
    /// One-shot flag set by `MenuBarChipsMigration` once it has converted the
    /// legacy `[MenuBarSegmentConfig]` payload (formerly under
    /// `ai-tracker.menuBarSegments`) into the chip-based model.
    case menuBarChipsMigrationCompleted = "ai-tracker.menuBarChipsMigrationCompleted"
    /// One-shot flag set by `OutageWarningMigration` once it has promoted the
    /// legacy global outage warning preference to per-segment fields on the
    /// (still-legacy) `[MenuBarSegmentConfig]` payload. Runs before
    /// `menuBarChipsMigrationCompleted`, but the flags are independent.
    case menuBarOutageWarningMigrationCompleted = "ai-tracker.menuBarOutageWarningMigrationCompleted"
    /// Persisted name of the chip pill colour scheme. Decoded into a
    /// `ChipBackground` value object — defaults to `.paper` (light pill).
    case menuBarChipBackground = "ai-tracker.menuBarChipBackground"
    /// Debug-build only: when true, the renderer cycles every visible chip
    /// segment's text & dot through `ConsumptionTier.allCases` once per
    /// second so contrast against `menuBarChipBackground` can be QA'd.
    case menuBarPacingColorCycleEnabled = "ai-tracker.menuBarPacingColorCycleEnabled"
    case chartConfigurations = "ai-tracker.chartConfigurations"
    case chartConfigurationsInitialized = "ai-tracker.chartConfigurationsInitialized"
    case ignoredAccounts = "ai-tracker.ignoredAccounts"
    /// JSON-encoded `[String]` of `"vendor:account"` identifiers in the order
    /// the user has chosen for the popover account list. Identifiers absent
    /// from this list fall back to the legacy alphabetical sort.
    case accountsOrder = "ai-tracker.accountsOrder"
    case updatesAutoCheckEnabled = "ai-tracker.updatesAutoCheckEnabled"
    case updatesAutoCheckEnabledInitialized = "ai-tracker.updatesAutoCheckEnabledInitialized"
    case updatesDismissedVersions = "ai-tracker.updatesDismissedVersions"
    /// JSON-encoded `[String: Bool]` mapping `StatusComponentID.rawValue` → subscribed.
    /// Default is ON for any component not explicitly stored, including those
    /// newly discovered on a future refresh.
    case statusComponentSubscriptions = "ai-tracker.statusComponentSubscriptions"
    /// `kSecAttrAccount` of the Keychain entry to use when reading Claude
    /// credentials. The `claude` CLI sometimes leaves several generic-password
    /// items under the `Claude Code-credentials` service — typically one
    /// holding MCP plugin OAuth state under `account=unknown` and the actual
    /// `claudeAiOauth` bearer under `account=$USER`. An unscoped lookup picks
    /// the first match returned by the keychain, which may be the wrong one.
    /// The Coding Assistants diagnostic writes this preference so the runtime
    /// targets a specific entry instead of guessing.
    case claudeKeychainAccount = "ai-tracker.claudeKeychainAccount"
    /// When true, the Claude Desktop usage source is active: the connector
    /// decrypts the Electron profiles' OAuth token cache (which requires reading
    /// the `Claude Safe Storage` Keychain entry) and reports per-profile usage.
    /// Defaults to false so no Keychain authorisation prompt is ever raised
    /// before the user has explicitly opted in — see
    /// `.claude/rules/swift-quality.md` §9.
    case claudeDesktopEnabled = "ai-tracker.claudeDesktopEnabled"
    /// JSON-encoded `[String]` of absolute directory paths the user opened Claude
    /// Desktop against via `--user-data-dir=<path>`, in addition to the two
    /// standard profile directories the installer always creates.
    case claudeDesktopProfilePaths = "ai-tracker.claudeDesktopProfilePaths"
}
