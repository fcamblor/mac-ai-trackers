import Foundation

// MARK: - Root

public struct UsagesFile: Codable, Equatable, Sendable {
    public var usages: [VendorUsageEntry]

    public init(usages: [VendorUsageEntry] = []) {
        self.usages = usages
    }
}

// MARK: - Entry

public struct VendorUsageEntry: Codable, Equatable, Sendable {
    public let vendor: String
    public let account: String
    public var isActive: Bool
    public var lastAcquiredOn: String?
    public var lastError: UsageError?
    public var metrics: [UsageMetric]

    public init(
        vendor: String,
        account: String,
        isActive: Bool = false,
        lastAcquiredOn: String? = nil,
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
    public let timestamp: String
    public let type: String

    public init(timestamp: String, type: String) {
        self.timestamp = timestamp
        self.type = type
    }
}

// MARK: - Metric (polymorphic on "type" discriminator)

public enum UsageMetric: Codable, Equatable, Sendable {
    case timeWindow(name: String, resetAt: String, windowDurationMinutes: Int, usagePercent: Int)
    case payAsYouGo(name: String, currentAmount: Double, currency: String)

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case type, name, resetAt, windowDurationMinutes, usagePercent, currentAmount, currency
    }

    private enum MetricType: String, Codable {
        case timeWindow = "time-window"
        case payAsYouGo = "pay-as-you-go"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metricType = try container.decode(MetricType.self, forKey: .type)
        switch metricType {
        case .timeWindow:
            self = .timeWindow(
                name: try container.decode(String.self, forKey: .name),
                resetAt: try container.decode(String.self, forKey: .resetAt),
                windowDurationMinutes: try container.decode(Int.self, forKey: .windowDurationMinutes),
                usagePercent: try container.decode(Int.self, forKey: .usagePercent)
            )
        case .payAsYouGo:
            self = .payAsYouGo(
                name: try container.decode(String.self, forKey: .name),
                currentAmount: try container.decode(Double.self, forKey: .currentAmount),
                currency: try container.decode(String.self, forKey: .currency)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .timeWindow(name, resetAt, windowDurationMinutes, usagePercent):
            try container.encode(MetricType.timeWindow, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(resetAt, forKey: .resetAt)
            try container.encode(windowDurationMinutes, forKey: .windowDurationMinutes)
            try container.encode(usagePercent, forKey: .usagePercent)
        case let .payAsYouGo(name, currentAmount, currency):
            try container.encode(MetricType.payAsYouGo, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(currentAmount, forKey: .currentAmount)
            try container.encode(currency, forKey: .currency)
        }
    }
}
