import Foundation

/// Centralised UserDefaults key names, prefixed to avoid collisions with
/// other subsystems that might share the same defaults suite.
public enum AppPreferenceKeys: String {
    case refreshIntervalSeconds = "ai-tracker.refreshIntervalSeconds"
    case launchAtLogin = "ai-tracker.launchAtLogin"
    case logLevel = "ai-tracker.logLevel"
    case menuBarSegments = "ai-tracker.menuBarSegments"
    case menuBarSegmentsInitialized = "ai-tracker.menuBarSegmentsInitialized"
    case menuBarSeparator = "ai-tracker.menuBarSeparator"
    case chartConfigurations = "ai-tracker.chartConfigurations"
    case chartConfigurationsInitialized = "ai-tracker.chartConfigurationsInitialized"
    case ignoredAccounts = "ai-tracker.ignoredAccounts"
    case updatesAutoCheckEnabled = "ai-tracker.updatesAutoCheckEnabled"
    case updatesAutoCheckEnabledInitialized = "ai-tracker.updatesAutoCheckEnabledInitialized"
    case updatesDismissedVersions = "ai-tracker.updatesDismissedVersions"
    /// JSON-encoded `[String: Bool]` mapping `StatusComponentID.rawValue` → subscribed.
    /// Default is ON for any component not explicitly stored, including those
    /// newly discovered on a future refresh.
    case statusComponentSubscriptions = "ai-tracker.statusComponentSubscriptions"
}
