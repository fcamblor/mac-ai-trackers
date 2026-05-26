import Foundation

/// One-shot migration converting the legacy flat `[MenuBarSegmentConfig]` JSON
/// payload (stored under `ai-tracker.menuBarSegments`) into the chip-based
/// model. Each legacy segment becomes a chip containing a single sub-segment.
/// The chip inherits the segment's vendor, vendor-icon toggle, and outage
/// warning. After conversion, the legacy keys (`menuBarSegments`,
/// `menuBarSegmentsInitialized`, `menuBarSeparator`) are cleared and a
/// completion flag is set so the migration never runs again.
///
/// Ordering: this migration MUST run after `OutageWarningMigration`, because
/// the latter rewrites the legacy per-segment outage fields and we need the
/// final values when promoting them to the chip level.
@MainActor
public enum MenuBarChipsMigration {
    private static let legacySegmentsKey = "ai-tracker.menuBarSegments"
    private static let legacySegmentsInitializedKey = "ai-tracker.menuBarSegmentsInitialized"
    private static let legacySeparatorKey = "ai-tracker.menuBarSeparator"

    public static func migrateIfNeeded(
        preferences: any AppPreferences,
        defaults: UserDefaults = .standard
    ) {
        let completedKey = AppPreferenceKeys.menuBarChipsMigrationCompleted.rawValue
        guard !defaults.bool(forKey: completedKey) else { return }

        if let data = defaults.data(forKey: legacySegmentsKey) {
            let chips: [MenuBarChipConfig]
            do {
                let legacy = try JSONDecoder().decode([LegacyMenuBarSegmentConfig].self, from: data)
                chips = legacy.map { $0.toChip() }
            } catch {
                Loggers.app.log(.error, "MenuBarChipsMigration: failed to decode legacy segments: \(error)")
                // Fall through: still mark the migration as done and clear keys
                // so we don't loop on a corrupt payload. The user will start
                // from an empty chips list (same end-state as a fresh install).
                chips = []
            }
            preferences.menuBarChips = chips
            // Carry the legacy "initialized" semantic across so the seeder
            // doesn't second-guess an upgrade that deliberately ended with
            // zero segments.
            let wasInitialized = defaults.bool(forKey: legacySegmentsInitializedKey)
            if wasInitialized || !chips.isEmpty {
                preferences.menuBarChipsInitialized = true
            }
        }

        defaults.removeObject(forKey: legacySegmentsKey)
        defaults.removeObject(forKey: legacySegmentsInitializedKey)
        defaults.removeObject(forKey: legacySeparatorKey)
        defaults.set(true, forKey: completedKey)
    }
}

// MARK: - Legacy decoding

/// Inlined image of the pre-chip `MenuBarSegmentConfig` payload. Kept private
/// to this file so the rest of the codebase isn't polluted by the legacy
/// shape, and so renaming/removing the production types can never break the
/// migration's ability to read old JSON.
private struct LegacyMenuBarSegmentConfig: Decodable {
    let id: UUID
    let vendor: Vendor
    let account: AccountSelection
    let metricName: String
    let display: LegacyDisplay
    let showOutageWarning: Bool
    let outageWarningText: String

    enum CodingKeys: String, CodingKey {
        case id, vendor, account, metricName, display, showOutageWarning, outageWarningText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vendor = try c.decode(Vendor.self, forKey: .vendor)
        account = try c.decode(AccountSelection.self, forKey: .account)
        metricName = try c.decode(String.self, forKey: .metricName)
        display = try c.decode(LegacyDisplay.self, forKey: .display)
        showOutageWarning = try c.decodeIfPresent(Bool.self, forKey: .showOutageWarning) ?? false
        outageWarningText = try c.decodeIfPresent(String.self, forKey: .outageWarningText)
            ?? MenuBarChipConfig.defaultOutageWarningText
    }

    func toChip() -> MenuBarChipConfig {
        let segment = MenuBarChipSegmentConfig(
            account: account,
            metricName: metricName,
            display: display.toSegmentDisplay()
        )
        return MenuBarChipConfig(
            id: id,
            vendor: vendor,
            showVendorIcon: display.showVendorIcon,
            showOutageWarning: showOutageWarning,
            outageWarningText: outageWarningText,
            segments: [segment]
        )
    }
}

/// Legacy `SegmentDisplay` payload — preserves the now-removed `showVendorIcon`
/// flag on the time-window variant so the migration can promote it to the chip.
private struct LegacyDisplay: Decodable {
    let kind: Kind
    let timeWindow: LegacyTimeWindowDisplay?

    enum Kind: String, Decodable {
        case timeWindow = "time-window"
        case payAsYouGo = "pay-as-you-go"
    }

    enum CodingKeys: String, CodingKey {
        case kind, timeWindow
    }

    /// `payAsYouGo` never carried a vendor icon — promote to false. For
    /// `timeWindow`, fall back to the same default as the legacy field
    /// when the payload predates its introduction.
    var showVendorIcon: Bool {
        switch kind {
        case .timeWindow: return timeWindow?.showVendorIcon ?? false
        case .payAsYouGo: return false
        }
    }

    /// Returns a display variant that satisfies the chip-segment "at least one
    /// visible element" invariant. The legacy resolver tolerated time-window
    /// displays with every toggle off (they rendered as `nil`). The chip model
    /// rejects them at decode, so we promote `showLetter` when no element is
    /// active — preserving the user's segment instead of silently dropping the
    /// chip on the next read.
    func toSegmentDisplay() -> SegmentDisplay {
        switch kind {
        case .timeWindow:
            var tw = timeWindow?.toTimeWindowDisplay() ?? TimeWindowDisplay()
            if !tw.hasAnyVisibleElement {
                Loggers.app.log(.warning, "MenuBarChipsMigration: legacy segment had no visible element, forcing showLetter=true")
                tw.showLetter = true
            }
            return .timeWindow(tw)
        case .payAsYouGo:
            return .payAsYouGo
        }
    }
}

private struct LegacyTimeWindowDisplay: Decodable {
    let showDot: Bool
    let showLetter: Bool
    let letter: String
    let showPercent: Bool
    let percentDisplayMode: UsagePercentDisplayMode?
    let showReset: Bool
    let hideResetMinutesWhenOverOneDay: Bool?
    let showVendorIcon: Bool
    let colorizeText: Bool?

    enum CodingKeys: String, CodingKey {
        case showDot, showLetter, letter, showPercent, percentDisplayMode, showReset
        case hideResetMinutesWhenOverOneDay, showVendorIcon, colorizeText
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showDot = try c.decode(Bool.self, forKey: .showDot)
        showLetter = try c.decode(Bool.self, forKey: .showLetter)
        letter = try c.decode(String.self, forKey: .letter)
        showPercent = try c.decode(Bool.self, forKey: .showPercent)
        percentDisplayMode = try c.decodeIfPresent(UsagePercentDisplayMode.self, forKey: .percentDisplayMode)
        showReset = try c.decode(Bool.self, forKey: .showReset)
        hideResetMinutesWhenOverOneDay = try c.decodeIfPresent(Bool.self, forKey: .hideResetMinutesWhenOverOneDay)
        showVendorIcon = try c.decodeIfPresent(Bool.self, forKey: .showVendorIcon) ?? false
        colorizeText = try c.decodeIfPresent(Bool.self, forKey: .colorizeText)
    }

    func toTimeWindowDisplay() -> TimeWindowDisplay {
        TimeWindowDisplay(
            showDot: showDot,
            showLetter: showLetter,
            letter: letter,
            showPercent: showPercent,
            percentDisplayMode: percentDisplayMode ?? .consumed,
            showReset: showReset,
            hideResetMinutesWhenOverOneDay: hideResetMinutesWhenOverOneDay ?? true,
            colorizeText: colorizeText ?? true
        )
    }
}
