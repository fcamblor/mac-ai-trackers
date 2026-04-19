import Foundation

// MARK: - Root

public struct UsagesFile: Codable, Equatable, Sendable {
    public var usages: [VendorUsageEntry]

    public init(usages: [VendorUsageEntry] = []) {
        self.usages = usages
    }
}

// MARK: - Entry

public struct VendorUsageEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { "\(vendor.rawValue):\(account.rawValue)" }

    public let vendor: Vendor
    public let account: AccountEmail
    public var isActive: Bool
    public var lastAcquiredOn: ISODate?
    public var lastError: UsageError?
    public var metrics: [UsageMetric]

    public init(
        vendor: Vendor,
        account: AccountEmail,
        isActive: Bool = false,
        lastAcquiredOn: ISODate? = nil,
        lastError: UsageError? = nil,
        metrics: [UsageMetric] = []
    ) {
        self.vendor = vendor
        self.account = account
        self.isActive = isActive
        self.lastAcquiredOn = lastAcquiredOn
        self.lastError = lastError
        self.metrics = metrics
    }
}

// MARK: - Error

public struct UsageError: Codable, Equatable, Sendable {
    public let timestamp: ISODate
    public let type: String

    public init(timestamp: ISODate, type: String) {
        self.timestamp = timestamp
        self.type = type
    }
}

// MARK: - Outage

/// An active incident on a vendor's platform, written by an upstream status-fetching process.
public struct Outage: Codable, Equatable, Sendable, Identifiable {
    public let id: OutageId
    public let title: String
    public let severity: OutageSeverity
    public let affectedComponents: [String]
    public let status: String?
    public let startedAt: ISODate?
    public let url: String?

    public init(
        id: OutageId,
        title: String,
        severity: OutageSeverity,
        affectedComponents: [String] = [],
        status: String? = nil,
        startedAt: ISODate? = nil,
        url: String? = nil
    ) {
        self.id = id
        self.title = title
        self.severity = severity
        self.affectedComponents = affectedComponents
        self.status = status
        self.startedAt = startedAt
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, severity, affectedComponents, status, startedAt, url
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(OutageId.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        severity = try container.decode(OutageSeverity.self, forKey: .severity)
        affectedComponents = try container.decodeIfPresent([String].self, forKey: .affectedComponents) ?? []
        status = try container.decodeIfPresent(String.self, forKey: .status)
        startedAt = try container.decodeIfPresent(ISODate.self, forKey: .startedAt)
        url = try container.decodeIfPresent(String.self, forKey: .url)
    }
}

// MARK: - Metric (polymorphic on "type" discriminator)

public enum UsageMetric: Codable, Equatable, Sendable {
    case timeWindow(name: String, resetAt: ISODate?, windowDuration: DurationMinutes, usagePercent: UsagePercent)
    case payAsYouGo(name: String, currentAmount: Double, currency: String)
    /// A metric type not yet known to this client; retained for round-trip fidelity.
    case unknown(String)

    // MARK: Kind

    public var kind: MetricKind {
        switch self {
        case .timeWindow:       .timeWindow
        case .payAsYouGo:       .payAsYouGo
        case .unknown(let t):   .unknown(t)
        }
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case type, name, resetAt
        case windowDuration = "windowDurationMinutes"
        case usagePercent, currentAmount, currency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metricKind = try container.decode(MetricKind.self, forKey: .type)
        switch metricKind {
        case .timeWindow:
            self = .timeWindow(
                name: try container.decode(String.self, forKey: .name),
                resetAt: try container.decodeIfPresent(ISODate.self, forKey: .resetAt),
                windowDuration: try container.decode(DurationMinutes.self, forKey: .windowDuration),
                usagePercent: try container.decode(UsagePercent.self, forKey: .usagePercent)
            )
        case .payAsYouGo:
            self = .payAsYouGo(
                name: try container.decode(String.self, forKey: .name),
                currentAmount: try container.decode(Double.self, forKey: .currentAmount),
                currency: try container.decode(String.self, forKey: .currency)
            )
        case .unknown(let t):
            self = .unknown(t)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .timeWindow(name, resetAt, windowDuration, usagePercent):
            try container.encode(MetricKind.timeWindow, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(resetAt, forKey: .resetAt)
            try container.encode(windowDuration, forKey: .windowDuration)
            try container.encode(usagePercent, forKey: .usagePercent)
        case let .payAsYouGo(name, currentAmount, currency):
            try container.encode(MetricKind.payAsYouGo, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(currentAmount, forKey: .currentAmount)
            try container.encode(currency, forKey: .currency)
        case let .unknown(t):
            // Only the type discriminator round-trips; unknown fields are not preserved
            try container.encode(MetricKind.unknown(t), forKey: .type)
        }
    }
}
