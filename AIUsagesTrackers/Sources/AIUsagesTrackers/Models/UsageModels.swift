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
