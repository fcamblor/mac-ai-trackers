import Foundation

// MARK: - AccountSelection

/// Which account a segment targets. `.currentlyActive` re-resolves at render time
/// so the segment tracks whichever Claude account is currently active.
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
}

public enum UsagePercentDisplayMode: String, Codable, Equatable, Hashable, CaseIterable, Sendable {
    case consumed
    case remaining
}

public struct TimeWindowDisplay: Codable, Equatable, Hashable, Sendable {
    public var showDot: Bool
    public var showLetter: Bool
    public var letter: String
    public var showPercent: Bool
    public var percentDisplayMode: UsagePercentDisplayMode
    public var showReset: Bool
    public var hideResetMinutesWhenOverOneDay: Bool
    public var showVendorIcon: Bool

    public init(
        showDot: Bool = true,
        showLetter: Bool = true,
        letter: String = "",
        showPercent: Bool = true,
        percentDisplayMode: UsagePercentDisplayMode = .consumed,
        showReset: Bool = true,
        hideResetMinutesWhenOverOneDay: Bool = true,
        showVendorIcon: Bool = false
    ) {
        self.showDot = showDot
        self.showLetter = showLetter
        self.letter = letter
        self.showPercent = showPercent
        self.percentDisplayMode = percentDisplayMode
        self.showReset = showReset
        self.hideResetMinutesWhenOverOneDay = hideResetMinutesWhenOverOneDay
        self.showVendorIcon = showVendorIcon
    }

    private enum CodingKeys: String, CodingKey {
        case showDot, showLetter, letter, showPercent, percentDisplayMode, showReset
        case hideResetMinutesWhenOverOneDay, showVendorIcon
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showDot = try c.decode(Bool.self, forKey: .showDot)
        showLetter = try c.decode(Bool.self, forKey: .showLetter)
        letter = try c.decode(String.self, forKey: .letter)
        showPercent = try c.decode(Bool.self, forKey: .showPercent)
        percentDisplayMode = try c.decodeIfPresent(
            UsagePercentDisplayMode.self,
            forKey: .percentDisplayMode
        ) ?? .consumed
        showReset = try c.decode(Bool.self, forKey: .showReset)
        hideResetMinutesWhenOverOneDay = try c.decodeIfPresent(
            Bool.self,
            forKey: .hideResetMinutesWhenOverOneDay
        ) ?? true
        showVendorIcon = try c.decodeIfPresent(Bool.self, forKey: .showVendorIcon) ?? false
    }
}

// MARK: - MenuBarSegmentConfig

/// A user-configured menu bar segment: which metric to read (vendor/account/metric)
/// and how to display it. Persisted as JSON in UserDefaults.
public struct MenuBarSegmentConfig: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var vendor: Vendor
    public var account: AccountSelection
    public var metricName: String
    public var display: SegmentDisplay

    public init(
        id: UUID = UUID(),
        vendor: Vendor,
        account: AccountSelection,
        metricName: String,
        display: SegmentDisplay
    ) {
        self.id = id
        self.vendor = vendor
        self.account = account
        self.metricName = metricName
        self.display = display
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
