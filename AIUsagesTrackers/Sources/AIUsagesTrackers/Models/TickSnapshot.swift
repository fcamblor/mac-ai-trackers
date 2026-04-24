import Foundation

/// One JSONL line of usage-history: a full snapshot of every account's metrics
/// captured at a given instant. `timestamp` is listed first in the coding keys
/// so the serialized form opens with the timestamp, which makes hand-inspection
/// of the history file much easier.
public struct TickSnapshot: Codable, Equatable, Sendable {
    public let timestamp: ISODate
    public let accounts: [AccountSnapshot]

    public init(timestamp: ISODate, accounts: [AccountSnapshot]) {
        self.timestamp = timestamp
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, accounts
    }
}

public struct AccountSnapshot: Codable, Equatable, Sendable {
    public let vendor: Vendor
    public let account: AccountEmail
    public let metrics: [MetricSnapshot]

    public init(vendor: Vendor, account: AccountEmail, metrics: [MetricSnapshot]) {
        self.vendor = vendor
        self.account = account
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey {
        case vendor, account, metrics
    }
}

public struct MetricSnapshot: Codable, Equatable, Sendable {
    public let name: String
    public let kind: MetricKind
    public let usagePercent: UsagePercent?
    public let currentAmount: Double?
    public let currency: String?

    public init(
        name: String,
        kind: MetricKind,
        usagePercent: UsagePercent? = nil,
        currentAmount: Double? = nil,
        currency: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.usagePercent = usagePercent
        self.currentAmount = currentAmount
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey {
        case name, kind, usagePercent, currentAmount, currency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(MetricKind.self, forKey: .kind)
        usagePercent = try container.decodeIfPresent(UsagePercent.self, forKey: .usagePercent)
        currentAmount = try container.decodeIfPresent(Double.self, forKey: .currentAmount)
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(usagePercent, forKey: .usagePercent)
        try container.encodeIfPresent(currentAmount, forKey: .currentAmount)
        try container.encodeIfPresent(currency, forKey: .currency)
    }
}
