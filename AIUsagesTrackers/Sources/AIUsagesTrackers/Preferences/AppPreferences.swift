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
    var menuBarSegments: [MenuBarSegmentConfig] { get set }
    /// Tracks whether seeding has already run — distinguishes "fresh install"
    /// from "user deleted all segments." False on a brand-new UserDefaults suite.
    var menuBarSegmentsInitialized: Bool { get set }
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

    public var menuBarSegments: [MenuBarSegmentConfig] {
        get {
            // @Observable wraps stored properties; computed ones need manual tracking so
            // SwiftUI / withObservationTracking observers are notified on mutation.
            access(keyPath: \.menuBarSegments)
            guard let data = defaults.data(forKey: AppPreferenceKeys.menuBarSegments.rawValue) else {
                return []
            }
            do {
                return try JSONDecoder().decode([MenuBarSegmentConfig].self, from: data)
            } catch {
                Loggers.app.log(.error, "Failed to decode menuBarSegments from UserDefaults: \(error)")
                return []
            }
        }
        set {
            withMutation(keyPath: \.menuBarSegments) {
                do {
                    let data = try JSONEncoder().encode(newValue)
                    defaults.set(data, forKey: AppPreferenceKeys.menuBarSegments.rawValue)
                } catch {
                    Loggers.app.log(.error, "Failed to encode menuBarSegments to UserDefaults: \(error)")
                }
            }
        }
    }

    public var menuBarSegmentsInitialized: Bool {
        get { defaults.bool(forKey: AppPreferenceKeys.menuBarSegmentsInitialized.rawValue) }
        set { defaults.set(newValue, forKey: AppPreferenceKeys.menuBarSegmentsInitialized.rawValue) }
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
    public var menuBarSegments: [MenuBarSegmentConfig]
    public var menuBarSegmentsInitialized: Bool

    public init(
        refreshInterval: RefreshInterval = .default,
        launchAtLogin: Bool = false,
        logLevel: LogLevel = .info,
        menuBarSegments: [MenuBarSegmentConfig] = [],
        menuBarSegmentsInitialized: Bool = false
    ) {
        self.refreshInterval = refreshInterval
        self.launchAtLogin = launchAtLogin
        self.logLevel = logLevel
        self.menuBarSegments = menuBarSegments
        self.menuBarSegmentsInitialized = menuBarSegmentsInitialized
    }
}
