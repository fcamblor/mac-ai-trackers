import Foundation
import Observation

// MARK: - Protocol

/// Single source of truth for user-adjustable runtime behaviour.
/// Injectable so tests can swap in `InMemoryAppPreferences`.
@MainActor
public protocol AppPreferences: AnyObject, Observable, Sendable {
    var refreshInterval: RefreshInterval { get set }
    var launchAtLogin: Bool { get set }
    var logLevel: LogLevel { get set }
}

// MARK: - UserDefaults-backed implementation

@Observable
@MainActor
public final class UserDefaultsAppPreferences: AppPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var refreshInterval: RefreshInterval {
        get {
            let raw = defaults.integer(forKey: AppPreferenceKeys.refreshIntervalSeconds.rawValue)
            if raw == 0 { return .default }
            return RefreshInterval(clamping: raw)
        }
        set {
            defaults.set(newValue.seconds, forKey: AppPreferenceKeys.refreshIntervalSeconds.rawValue)
        }
    }

    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: AppPreferenceKeys.launchAtLogin.rawValue) }
        set { defaults.set(newValue, forKey: AppPreferenceKeys.launchAtLogin.rawValue) }
    }

    public var logLevel: LogLevel {
        get {
            let raw = defaults.string(forKey: AppPreferenceKeys.logLevel.rawValue) ?? ""
            if raw.isEmpty { return .info }
            return LogLevel.from(string: raw)
        }
        set {
            defaults.set(newValue.label.lowercased(), forKey: AppPreferenceKeys.logLevel.rawValue)
        }
    }
}

// MARK: - In-memory test double

/// Shared between production defaults-absent paths and test code.
@Observable
@MainActor
public final class InMemoryAppPreferences: AppPreferences {
    public var refreshInterval: RefreshInterval
    public var launchAtLogin: Bool
    public var logLevel: LogLevel

    public init(
        refreshInterval: RefreshInterval = .default,
        launchAtLogin: Bool = false,
        logLevel: LogLevel = .info
    ) {
        self.refreshInterval = refreshInterval
        self.launchAtLogin = launchAtLogin
        self.logLevel = logLevel
    }
}
