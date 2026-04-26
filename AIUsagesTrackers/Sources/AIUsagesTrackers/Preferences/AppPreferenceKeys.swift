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
}
