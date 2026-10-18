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
    var menuBarChips: [MenuBarChipConfig] { get set }
    /// Tracks whether seeding has already run — distinguishes "fresh install"
    /// from "user deleted all chips." False on a brand-new UserDefaults suite.
    var menuBarChipsInitialized: Bool { get set }
    /// Pill colour for every chip in the menu bar. Global by design — per-chip
    /// colours would defeat the "stay consistent with tier colours" guarantee.
    var menuBarChipBackground: ChipBackground { get set }
    /// Debug-build affordance: when true, the menu bar renderer cycles every
    /// chip segment's text & dot through `ConsumptionTier.allCases` at 1 Hz so
    /// the user can visually QA each pacing colour against the chosen
    /// `menuBarChipBackground`. AppDelegate only arms the timer under
    /// `#if DEBUG`, but the preference is exposed unconditionally to keep the
    /// protocol stable across build configurations.
    var menuBarPacingColorCycleEnabled: Bool { get set }
    var chartConfigurations: [ChartConfiguration] { get set }
    /// Tracks whether chart seeding has already run so an intentionally empty
    /// configuration list is preserved after first initialization.
    var chartConfigurationsInitialized: Bool { get set }
    var ignoredAccounts: [IgnoredAccount] { get set }
    /// User-chosen display order for the popover account list. Stored as a
    /// list of `VendorUsageEntry.id` (`"vendor:account"`). Entries not present
    /// fall back to the legacy alphabetical sort behind the ordered ones.
    var accountsOrder: [String] { get set }
    /// Popover rows hidden per assistant family. Popover-only: menu bar chips
    /// and charts are unaffected.
    var popoverMetricVisibility: PopoverMetricVisibility { get set }
    var popoverWidth: PopoverWidth { get set }
    /// When true, the scheduler periodically polls GitHub for new releases.
    /// Defaults to true (opt-out).
    var updatesAutoCheckEnabled: Bool { get set }
    /// Versions the user explicitly dismissed via the "Skip this version"
    /// banner action. Stored as raw `tag_name` strings (without leading `v`).
    var updatesDismissedVersions: [String] { get set }
    /// Per-component subscription state keyed by `StatusComponentID.rawValue`.
    /// A missing key means "subscribed" (default ON); the dictionary only
    /// stores explicit user overrides — typically `false` for opted-out
    /// components. Storing the key set explicitly would force a migration
    /// every time the registry discovers a new component.
    var statusComponentSubscriptions: [String: Bool] { get set }
    /// `kSecAttrAccount` to scope the Claude Keychain lookup to. `nil` means
    /// "use the first match" (the default `security find-generic-password -s`
    /// behaviour). Set from the Coding Assistants tab when the diagnostic
    /// finds multiple entries — we never delete the duplicates ourselves.
    var claudeKeychainAccount: String? { get set }

    /// Whether the Claude Desktop usage source is enabled. Off by default; the
    /// connector performs no Keychain Safe Storage read while this is false.
    var claudeDesktopEnabled: Bool { get set }

    /// Extra Claude Desktop profile directories (absolute paths) opened via
    /// `--user-data-dir`, on top of the two standard installer directories.
    var claudeDesktopProfilePaths: [String] { get set }
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
            access(keyPath: \.refreshInterval)
            let raw = defaults.integer(forKey: AppPreferenceKeys.refreshIntervalSeconds.rawValue)
            if raw == 0 { return .default }
            return RefreshInterval(clamping: raw)
        }
        set {
            withMutation(keyPath: \.refreshInterval) {
                defaults.set(newValue.seconds, forKey: AppPreferenceKeys.refreshIntervalSeconds.rawValue)
            }
        }
    }

    public var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return defaults.bool(forKey: AppPreferenceKeys.launchAtLogin.rawValue)
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                defaults.set(newValue, forKey: AppPreferenceKeys.launchAtLogin.rawValue)
            }
        }
    }

    public var logLevel: LogLevel {
        get {
            access(keyPath: \.logLevel)
            let raw = defaults.string(forKey: AppPreferenceKeys.logLevel.rawValue) ?? ""
            if raw.isEmpty { return .info }
            return LogLevel.from(string: raw)
        }
        set {
            withMutation(keyPath: \.logLevel) {
                defaults.set(newValue.label.lowercased(), forKey: AppPreferenceKeys.logLevel.rawValue)
            }
        }
    }

    public var menuBarChips: [MenuBarChipConfig] {
        get {
            // @Observable wraps stored properties; computed ones need manual tracking so
            // SwiftUI / withObservationTracking observers are notified on mutation.
            access(keyPath: \.menuBarChips)
            guard let data = defaults.data(forKey: AppPreferenceKeys.menuBarChips.rawValue) else {
                return []
            }
            do {
                return try JSONDecoder().decode([MenuBarChipConfig].self, from: data)
            } catch {
                Loggers.app.log(.error, "Failed to decode menuBarChips from UserDefaults: \(error)")
                return []
            }
        }
        set {
            withMutation(keyPath: \.menuBarChips) {
                do {
                    let data = try JSONEncoder().encode(newValue)
                    defaults.set(data, forKey: AppPreferenceKeys.menuBarChips.rawValue)
                } catch {
                    Loggers.app.log(.error, "Failed to encode menuBarChips to UserDefaults: \(error)")
                }
            }
        }
    }

    public var menuBarChipsInitialized: Bool {
        get { defaults.bool(forKey: AppPreferenceKeys.menuBarChipsInitialized.rawValue) }
        set { defaults.set(newValue, forKey: AppPreferenceKeys.menuBarChipsInitialized.rawValue) }
    }

    public var menuBarChipBackground: ChipBackground {
        get {
            access(keyPath: \.menuBarChipBackground)
            let raw = defaults.string(forKey: AppPreferenceKeys.menuBarChipBackground.rawValue) ?? ""
            return ChipBackground(rawValue: raw) ?? .default
        }
        set {
            withMutation(keyPath: \.menuBarChipBackground) {
                defaults.set(newValue.rawValue, forKey: AppPreferenceKeys.menuBarChipBackground.rawValue)
            }
        }
    }

    public var menuBarPacingColorCycleEnabled: Bool {
        get {
            access(keyPath: \.menuBarPacingColorCycleEnabled)
            return defaults.bool(forKey: AppPreferenceKeys.menuBarPacingColorCycleEnabled.rawValue)
        }
        set {
            withMutation(keyPath: \.menuBarPacingColorCycleEnabled) {
                defaults.set(newValue, forKey: AppPreferenceKeys.menuBarPacingColorCycleEnabled.rawValue)
            }
        }
    }

    public var chartConfigurations: [ChartConfiguration] {
        get {
            access(keyPath: \.chartConfigurations)
            guard let data = defaults.data(forKey: AppPreferenceKeys.chartConfigurations.rawValue) else {
                return []
            }
            do {
                return try JSONDecoder().decode([ChartConfiguration].self, from: data)
            } catch {
                Loggers.app.log(.error, "Failed to decode chartConfigurations from UserDefaults: \(error)")
                return []
            }
        }
        set {
            withMutation(keyPath: \.chartConfigurations) {
                do {
                    let data = try JSONEncoder().encode(newValue)
                    defaults.set(data, forKey: AppPreferenceKeys.chartConfigurations.rawValue)
                } catch {
                    Loggers.app.log(.error, "Failed to encode chartConfigurations to UserDefaults: \(error)")
                }
            }
        }
    }

    public var chartConfigurationsInitialized: Bool {
        get { defaults.bool(forKey: AppPreferenceKeys.chartConfigurationsInitialized.rawValue) }
        set { defaults.set(newValue, forKey: AppPreferenceKeys.chartConfigurationsInitialized.rawValue) }
    }

    public var ignoredAccounts: [IgnoredAccount] {
        get {
            access(keyPath: \.ignoredAccounts)
            guard let data = defaults.data(forKey: AppPreferenceKeys.ignoredAccounts.rawValue) else {
                return []
            }
            do {
                return try JSONDecoder().decode([IgnoredAccount].self, from: data)
            } catch {
                Loggers.app.log(.error, "Failed to decode ignoredAccounts from UserDefaults: \(error)")
                return []
            }
        }
        set {
            withMutation(keyPath: \.ignoredAccounts) {
                do {
                    let data = try JSONEncoder().encode(newValue)
                    defaults.set(data, forKey: AppPreferenceKeys.ignoredAccounts.rawValue)
                } catch {
                    Loggers.app.log(.error, "Failed to encode ignoredAccounts to UserDefaults: \(error)")
                }
            }
        }
    }

    public var accountsOrder: [String] {
        get {
            access(keyPath: \.accountsOrder)
            return defaults.stringArray(forKey: AppPreferenceKeys.accountsOrder.rawValue) ?? []
        }
        set {
            withMutation(keyPath: \.accountsOrder) {
                defaults.set(newValue, forKey: AppPreferenceKeys.accountsOrder.rawValue)
            }
        }
    }

    public var popoverWidth: PopoverWidth {
        get {
            access(keyPath: \.popoverWidth)
            let raw = defaults.string(forKey: AppPreferenceKeys.popoverWidth.rawValue) ?? ""
            return PopoverWidth(rawValue: raw) ?? .default
        }
        set {
            withMutation(keyPath: \.popoverWidth) {
                defaults.set(newValue.rawValue, forKey: AppPreferenceKeys.popoverWidth.rawValue)
            }
        }
    }

    public var popoverMetricVisibility: PopoverMetricVisibility {
        get {
            access(keyPath: \.popoverMetricVisibility)
            guard let data = defaults.data(forKey: AppPreferenceKeys.popoverMetricVisibility.rawValue) else {
                return PopoverMetricVisibility()
            }
            do {
                return try JSONDecoder().decode(PopoverMetricVisibility.self, from: data)
            } catch {
                Loggers.app.log(.error, "Failed to decode popoverMetricVisibility from UserDefaults: \(error)")
                return PopoverMetricVisibility()
            }
        }
        set {
            withMutation(keyPath: \.popoverMetricVisibility) {
                do {
                    let data = try JSONEncoder().encode(newValue)
                    defaults.set(data, forKey: AppPreferenceKeys.popoverMetricVisibility.rawValue)
                } catch {
                    Loggers.app.log(.error, "Failed to encode popoverMetricVisibility to UserDefaults: \(error)")
                }
            }
        }
    }

    public var updatesAutoCheckEnabled: Bool {
        get {
            access(keyPath: \.updatesAutoCheckEnabled)
            // Default-on requires distinguishing "never set" from "explicitly false".
            if !defaults.bool(forKey: AppPreferenceKeys.updatesAutoCheckEnabledInitialized.rawValue) {
                return true
            }
            return defaults.bool(forKey: AppPreferenceKeys.updatesAutoCheckEnabled.rawValue)
        }
        set {
            withMutation(keyPath: \.updatesAutoCheckEnabled) {
                defaults.set(newValue, forKey: AppPreferenceKeys.updatesAutoCheckEnabled.rawValue)
                defaults.set(true, forKey: AppPreferenceKeys.updatesAutoCheckEnabledInitialized.rawValue)
            }
        }
    }

    public var updatesDismissedVersions: [String] {
        get {
            access(keyPath: \.updatesDismissedVersions)
            return defaults.stringArray(forKey: AppPreferenceKeys.updatesDismissedVersions.rawValue) ?? []
        }
        set {
            withMutation(keyPath: \.updatesDismissedVersions) {
                defaults.set(newValue, forKey: AppPreferenceKeys.updatesDismissedVersions.rawValue)
            }
        }
    }

    public var statusComponentSubscriptions: [String: Bool] {
        get {
            access(keyPath: \.statusComponentSubscriptions)
            guard let data = defaults.data(
                forKey: AppPreferenceKeys.statusComponentSubscriptions.rawValue
            ) else {
                return [:]
            }
            do {
                return try JSONDecoder().decode([String: Bool].self, from: data)
            } catch {
                Loggers.app.log(.error, "Failed to decode statusComponentSubscriptions: \(error)")
                return [:]
            }
        }
        set {
            withMutation(keyPath: \.statusComponentSubscriptions) {
                do {
                    let data = try JSONEncoder().encode(newValue)
                    defaults.set(
                        data, forKey: AppPreferenceKeys.statusComponentSubscriptions.rawValue
                    )
                } catch {
                    Loggers.app.log(.error, "Failed to encode statusComponentSubscriptions: \(error)")
                }
            }
        }
    }

    public var claudeKeychainAccount: String? {
        get {
            access(keyPath: \.claudeKeychainAccount)
            let raw = defaults.string(forKey: AppPreferenceKeys.claudeKeychainAccount.rawValue)
            // Treat the empty string the same as "no override" so the user can
            // clear the override by writing "" without leaving the key dangling.
            guard let raw, !raw.isEmpty else { return nil }
            return raw
        }
        set {
            withMutation(keyPath: \.claudeKeychainAccount) {
                if let newValue, !newValue.isEmpty {
                    defaults.set(newValue, forKey: AppPreferenceKeys.claudeKeychainAccount.rawValue)
                } else {
                    defaults.removeObject(forKey: AppPreferenceKeys.claudeKeychainAccount.rawValue)
                }
            }
        }
    }

    public var claudeDesktopEnabled: Bool {
        get {
            access(keyPath: \.claudeDesktopEnabled)
            return defaults.bool(forKey: AppPreferenceKeys.claudeDesktopEnabled.rawValue)
        }
        set {
            withMutation(keyPath: \.claudeDesktopEnabled) {
                defaults.set(newValue, forKey: AppPreferenceKeys.claudeDesktopEnabled.rawValue)
            }
        }
    }

    public var claudeDesktopProfilePaths: [String] {
        get {
            access(keyPath: \.claudeDesktopProfilePaths)
            return defaults.stringArray(forKey: AppPreferenceKeys.claudeDesktopProfilePaths.rawValue) ?? []
        }
        set {
            withMutation(keyPath: \.claudeDesktopProfilePaths) {
                defaults.set(newValue, forKey: AppPreferenceKeys.claudeDesktopProfilePaths.rawValue)
            }
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
    public var menuBarChips: [MenuBarChipConfig]
    public var menuBarChipsInitialized: Bool
    public var menuBarChipBackground: ChipBackground
    public var menuBarPacingColorCycleEnabled: Bool
    public var chartConfigurations: [ChartConfiguration]
    public var chartConfigurationsInitialized: Bool
    public var ignoredAccounts: [IgnoredAccount]
    public var accountsOrder: [String]
    public var popoverMetricVisibility: PopoverMetricVisibility
    public var popoverWidth: PopoverWidth
    public var updatesAutoCheckEnabled: Bool
    public var updatesDismissedVersions: [String]
    public var statusComponentSubscriptions: [String: Bool]
    public var claudeKeychainAccount: String?
    public var claudeDesktopEnabled: Bool
    public var claudeDesktopProfilePaths: [String]

    public init(
        refreshInterval: RefreshInterval = .default,
        launchAtLogin: Bool = false,
        logLevel: LogLevel = .info,
        menuBarChips: [MenuBarChipConfig] = [],
        menuBarChipsInitialized: Bool = false,
        menuBarChipBackground: ChipBackground = .default,
        menuBarPacingColorCycleEnabled: Bool = false,
        chartConfigurations: [ChartConfiguration] = [],
        chartConfigurationsInitialized: Bool = false,
        ignoredAccounts: [IgnoredAccount] = [],
        accountsOrder: [String] = [],
        popoverMetricVisibility: PopoverMetricVisibility = PopoverMetricVisibility(),
        popoverWidth: PopoverWidth = .default,
        updatesAutoCheckEnabled: Bool = true,
        updatesDismissedVersions: [String] = [],
        statusComponentSubscriptions: [String: Bool] = [:],
        claudeKeychainAccount: String? = nil,
        claudeDesktopEnabled: Bool = false,
        claudeDesktopProfilePaths: [String] = []
    ) {
        self.refreshInterval = refreshInterval
        self.launchAtLogin = launchAtLogin
        self.logLevel = logLevel
        self.menuBarChips = menuBarChips
        self.menuBarChipsInitialized = menuBarChipsInitialized
        self.menuBarChipBackground = menuBarChipBackground
        self.menuBarPacingColorCycleEnabled = menuBarPacingColorCycleEnabled
        self.chartConfigurations = chartConfigurations
        self.chartConfigurationsInitialized = chartConfigurationsInitialized
        self.ignoredAccounts = ignoredAccounts
        self.accountsOrder = accountsOrder
        self.popoverMetricVisibility = popoverMetricVisibility
        self.popoverWidth = popoverWidth
        self.updatesAutoCheckEnabled = updatesAutoCheckEnabled
        self.updatesDismissedVersions = updatesDismissedVersions
        self.statusComponentSubscriptions = statusComponentSubscriptions
        self.claudeKeychainAccount = claudeKeychainAccount
        self.claudeDesktopEnabled = claudeDesktopEnabled
        self.claudeDesktopProfilePaths = claudeDesktopProfilePaths
    }
}
