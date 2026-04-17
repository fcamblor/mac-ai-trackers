import Foundation

// MARK: - Root

struct UsagesFile: Codable, Equatable, Sendable {
    var usages: [VendorUsageEntry]

    init(usages: [VendorUsageEntry] = []) {
        self.usages = usages
    }
}

// MARK: - Entry

struct VendorUsageEntry: Codable, Equatable, Sendable {
    let vendor: String
    let account: String
    var isActive: Bool
    var lastAcquiredOn: String?
    var lastError: UsageError?
    var metrics: [UsageMetric]

    init(
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

struct UsageError: Codable, Equatable, Sendable {
    let timestamp: String
    let type: String
}

// MARK: - Metric (polymorphic on "type" discriminator)

enum UsageMetric: Codable, Equatable, Sendable {
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

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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
