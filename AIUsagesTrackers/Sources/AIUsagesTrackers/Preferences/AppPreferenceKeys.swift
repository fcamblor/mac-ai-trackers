import Foundation

/// Centralised UserDefaults key names, prefixed to avoid collisions with
/// other subsystems that might share the same defaults suite.
public enum AppPreferenceKeys: String {
    case refreshIntervalSeconds = "ai-tracker.refreshIntervalSeconds"
    case launchAtLogin = "ai-tracker.launchAtLogin"
    case logLevel = "ai-tracker.logLevel"
}
