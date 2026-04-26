import Foundation

// MARK: - ChartConfiguration

/// A user-configured chart shown in the history tab.
public struct ChartConfiguration: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public var selection: ChartSeriesSelection

    public init(
        id: UUID = UUID(),
        title: String,
        selection: ChartSeriesSelection
    ) {
        self.id = id
        self.title = title
        self.selection = selection
    }
}

// MARK: - Series selection

/// The chart's source series. Modes are exclusive: either all available series
/// from history, or an ordered list of custom series.
public enum ChartSeriesSelection: Codable, Equatable, Hashable, Sendable {
    case allAvailable
    case custom([ChartSeriesConfig])

    private enum CodingKeys: String, CodingKey {
        case kind, series
    }

    private enum Kind: String, Codable {
        case allAvailable = "all-available"
        case custom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .allAvailable:
            self = .allAvailable
        case .custom:
            self = .custom(try container.decode([ChartSeriesConfig].self, forKey: .series))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allAvailable:
            try container.encode(Kind.allAvailable, forKey: .kind)
        case .custom(let series):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(series, forKey: .series)
        }
    }
}

// MARK: - Custom series

public struct ChartSeriesConfig: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var vendor: Vendor
    public var account: AccountSelection
    public var metricName: String
    public var label: String
    public var style: ChartSeriesStyle

    public init(
        id: UUID = UUID(),
        vendor: Vendor,
        account: AccountSelection,
        metricName: String,
        label: String = "",
        style: ChartSeriesStyle = ChartSeriesStyle()
    ) {
        self.id = id
        self.vendor = vendor
        self.account = account
        self.metricName = metricName
        self.label = label
        self.style = style
    }

    private enum CodingKeys: String, CodingKey {
        case id, vendor, account, metricName, label, style
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vendor = try container.decode(Vendor.self, forKey: .vendor)
        account = try container.decode(AccountSelection.self, forKey: .account)
        metricName = try container.decode(String.self, forKey: .metricName)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        style = try container.decode(ChartSeriesStyle.self, forKey: .style)
    }
}

public struct ChartSeriesStyle: Codable, Equatable, Hashable, Sendable {
    public var color: ChartSeriesColor
    public var lineStyle: ChartLineStyle

    public init(
        color: ChartSeriesColor = .blue,
        lineStyle: ChartLineStyle = .solid
    ) {
        self.color = color
        self.lineStyle = lineStyle
    }
}

public enum ChartSeriesColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue
    case green
    case orange
    case purple
    case red
    case teal
    case olive
    case pink

    public var id: String { rawValue }
}

public enum ChartLineStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case solid
    case dashed
    case dotted

    public var id: String { rawValue }
}
