import Foundation

// MARK: - AccountSelection

/// Which account a chip segment targets. `.currentlyActive` re-resolves at render
/// time so the segment tracks whichever vendor account is currently active.
public enum AccountSelection: Codable, Equatable, Hashable, Sendable {
    case currentlyActive
    case specific(AccountEmail)

    private enum CodingKeys: String, CodingKey {
        case kind, email
    }

    private enum Kind: String, Codable {
        case currentlyActive = "currently-active"
        case specific
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .currentlyActive:
            self = .currentlyActive
        case .specific:
            let email = try container.decode(AccountEmail.self, forKey: .email)
            self = .specific(email)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .currentlyActive:
            try container.encode(Kind.currentlyActive, forKey: .kind)
        case .specific(let email):
            try container.encode(Kind.specific, forKey: .kind)
            try container.encode(email, forKey: .email)
        }
    }
}

// MARK: - SegmentDisplay

/// Variant-dependent display options. `timeWindow` carries four independent
/// toggles plus the letter shown when `showLetter` is on; `payAsYouGo` has no
/// options — the rendered text is always "amount currency".
public enum SegmentDisplay: Codable, Equatable, Hashable, Sendable {
    case timeWindow(TimeWindowDisplay)
    case payAsYouGo

    private enum CodingKeys: String, CodingKey {
        case kind, timeWindow
    }

    private enum Kind: String, Codable {
        case timeWindow = "time-window"
        case payAsYouGo = "pay-as-you-go"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .timeWindow:
            let tw = try container.decode(TimeWindowDisplay.self, forKey: .timeWindow)
            self = .timeWindow(tw)
        case .payAsYouGo:
            self = .payAsYouGo
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .timeWindow(let tw):
            try container.encode(Kind.timeWindow, forKey: .kind)
            try container.encode(tw, forKey: .timeWindow)
        case .payAsYouGo:
            try container.encode(Kind.payAsYouGo, forKey: .kind)
        }
    }

    /// True when the variant carries at least one element the user might want
    /// to render. `payAsYouGo` is unconditionally non-empty (the amount is
    /// always shown). `timeWindow` requires at least one of its visible
    /// toggles — see `TimeWindowDisplay.hasAnyVisibleElement`.
    public var hasAnyVisibleElement: Bool {
        switch self {
        case .timeWindow(let tw): return tw.hasAnyVisibleElement
        case .payAsYouGo:         return true
        }
    }
}

public enum UsagePercentDisplayMode: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case consumed
    case remaining
}

public struct TimeWindowDisplay: Codable, Equatable, Hashable, Sendable {
    public var showLetter: Bool
    public var letter: String
    public var showPercent: Bool
    public var percentDisplayMode: UsagePercentDisplayMode
    public var showReset: Bool
    public var hideResetMinutesWhenOverOneDay: Bool

    public init(
        showLetter: Bool = true,
        letter: String = "",
        showPercent: Bool = true,
        percentDisplayMode: UsagePercentDisplayMode = .consumed,
        showReset: Bool = true,
        hideResetMinutesWhenOverOneDay: Bool = true
    ) {
        self.showLetter = showLetter
        self.letter = letter
        self.showPercent = showPercent
        self.percentDisplayMode = percentDisplayMode
        self.showReset = showReset
        self.hideResetMinutesWhenOverOneDay = hideResetMinutesWhenOverOneDay
    }

    private enum CodingKeys: String, CodingKey {
        case showLetter, letter, showPercent, percentDisplayMode, showReset
        case hideResetMinutesWhenOverOneDay
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Tolerate JSON written by older builds where each toggle was present
        // unconditionally — and where `showDot` could legitimately be the only
        // visible piece. We default any missing toggle to false and then
        // promote `showLetter` if the resulting display would be invisible, so
        // existing chips don't silently drop on first read after the upgrade.
        showLetter = try c.decodeIfPresent(Bool.self, forKey: .showLetter) ?? false
        letter = try c.decodeIfPresent(String.self, forKey: .letter) ?? ""
        showPercent = try c.decodeIfPresent(Bool.self, forKey: .showPercent) ?? false
        percentDisplayMode = try c.decodeIfPresent(
            UsagePercentDisplayMode.self,
            forKey: .percentDisplayMode
        ) ?? .consumed
        showReset = try c.decodeIfPresent(Bool.self, forKey: .showReset) ?? false
        hideResetMinutesWhenOverOneDay = try c.decodeIfPresent(
            Bool.self,
            forKey: .hideResetMinutesWhenOverOneDay
        ) ?? true
        if !(showLetter || showPercent || showReset) {
            showLetter = true
        }
    }

    /// At least one of the three visible toggles must be on. Enforced as the
    /// "non-empty segment" invariant: a segment whose every toggle is off
    /// would render an empty chip slot that the user cannot see and cannot
    /// interact with.
    public var hasAnyVisibleElement: Bool {
        showLetter || showPercent || showReset
    }
}

// MARK: - MenuBarChipSegmentConfig

/// One sub-segment inside a chip. Targets a single account + metric and
/// carries the display variant. The parent chip's `segments` is constrained
/// to be non-empty and each segment is constrained to be non-empty via
/// `SegmentDisplay.hasAnyVisibleElement`.
public struct MenuBarChipSegmentConfig: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var account: AccountSelection
    public var metricName: String
    public var display: SegmentDisplay

    public init(
        id: UUID = UUID(),
        account: AccountSelection,
        metricName: String,
        display: SegmentDisplay
    ) {
        self.id = id
        self.account = account
        self.metricName = metricName
        self.display = display
    }

    private enum CodingKeys: String, CodingKey {
        case id, account, metricName, display
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        account = try c.decode(AccountSelection.self, forKey: .account)
        metricName = try c.decode(String.self, forKey: .metricName)
        display = try c.decode(SegmentDisplay.self, forKey: .display)
        if !display.hasAnyVisibleElement {
            throw DecodingError.dataCorruptedError(
                forKey: .display,
                in: c,
                debugDescription: "Chip segment must have at least one visible element"
            )
        }
    }
}

// MARK: - MenuBarChipConfig

/// A user-configured menu bar chip rendered as a coloured pill. Carries
/// vendor-level chrome (icon, outage warning) shared across its segments, and
/// holds at least one `MenuBarChipSegmentConfig` — the empty case is rejected
/// at decode time and the UI must prevent deletion of the last segment.
public struct MenuBarChipConfig: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var vendor: Vendor
    /// Vendor icon prepended to the chip when true. Carries the role the
    /// legacy per-segment `TimeWindowDisplay.showVendorIcon` used to play.
    public var showVendorIcon: Bool
    /// When true and the chip's vendor currently has an active outage,
    /// `outageWarningText` is rendered right after the vendor icon. The flag
    /// is vendor-wide (one outage = one warning per chip, not per segment).
    public var showOutageWarning: Bool
    /// Short label rendered while the chip's vendor has an active outage.
    /// Defaults to "⚠️". Ignored when `showOutageWarning` is false.
    public var outageWarningText: String
    /// Non-empty by construction. The UI must prevent deletion of the last
    /// segment; the decoder rejects an empty array.
    public var segments: [MenuBarChipSegmentConfig]

    public static let defaultOutageWarningText: String = "⚠️"

    public init(
        id: UUID = UUID(),
        vendor: Vendor,
        showVendorIcon: Bool = false,
        showOutageWarning: Bool = false,
        outageWarningText: String = MenuBarChipConfig.defaultOutageWarningText,
        segments: [MenuBarChipSegmentConfig]
    ) {
        self.id = id
        self.vendor = vendor
        self.showVendorIcon = showVendorIcon
        self.showOutageWarning = showOutageWarning
        self.outageWarningText = outageWarningText
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey {
        case id, vendor, showVendorIcon, showOutageWarning, outageWarningText, segments
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        vendor = try c.decode(Vendor.self, forKey: .vendor)
        showVendorIcon = try c.decodeIfPresent(Bool.self, forKey: .showVendorIcon) ?? false
        showOutageWarning = try c.decodeIfPresent(Bool.self, forKey: .showOutageWarning) ?? false
        outageWarningText = try c.decodeIfPresent(String.self, forKey: .outageWarningText)
            ?? MenuBarChipConfig.defaultOutageWarningText
        segments = try c.decode([MenuBarChipSegmentConfig].self, forKey: .segments)
        if segments.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .segments,
                in: c,
                debugDescription: "Chip must contain at least one segment"
            )
        }
    }
}

// MARK: - Default letters

/// Maps known metric names to their canonical menu bar letter. When unknown,
/// the first character of the metric name (uppercased) is used as default.
public enum MenuBarMetricLetter {
    private static let knownAbbreviations: [String: String] = [
        "5h sessions (all models)": "S",
        "Weekly (all models)": "W",
    ]

    public static func defaultLetter(for metricName: String) -> String {
        if let known = knownAbbreviations[metricName] {
            return known
        }
        return String(metricName.prefix(1)).uppercased()
    }
}
