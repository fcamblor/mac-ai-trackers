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
    case menuBarOutageWarningEnabled = "ai-tracker.menuBarOutageWarningEnabled"
    case menuBarOutageWarningEnabledInitialized = "ai-tracker.menuBarOutageWarningEnabledInitialized"
    case menuBarOutageWarningText = "ai-tracker.menuBarOutageWarningText"
    case chartConfigurations = "ai-tracker.chartConfigurations"
    case chartConfigurationsInitialized = "ai-tracker.chartConfigurationsInitialized"
    case ignoredAccounts = "ai-tracker.ignoredAccounts"
    case updatesAutoCheckEnabled = "ai-tracker.updatesAutoCheckEnabled"
    case updatesAutoCheckEnabledInitialized = "ai-tracker.updatesAutoCheckEnabledInitialized"
    case updatesDismissedVersions = "ai-tracker.updatesDismissedVersions"
}
