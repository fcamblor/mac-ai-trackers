import Foundation

// MARK: - Root

/// The top-level file model: `{ usages: [...], outages?: [...] }`.
///
/// `outages` is an optional sibling written by an upstream status-fetching process.
/// When no incident is ongoing the upstream writer is expected to drop the key
/// entirely; the encoder here honours that convention by emitting nothing when
/// the in-memory array is empty.
public struct UsagesFile: Codable, Equatable, Sendable {
    public var usages: [VendorUsageEntry]
    public var outages: [Outage]

    public init(usages: [VendorUsageEntry] = [], outages: [Outage] = []) {
        self.usages = usages
        self.outages = outages
    }

    /// Grouped view for the UI — vendors without outages are omitted.
    public var outagesByVendor: [Vendor: [Outage]] {
        Dictionary(grouping: outages, by: \.vendor)
    }

    private enum CodingKeys: String, CodingKey {
        case usages, outages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usages = try container.decodeIfPresent([VendorUsageEntry].self, forKey: .usages) ?? []
        outages = try container.decodeIfPresent([Outage].self, forKey: .outages) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(usages, forKey: .usages)
        // Upstream convention: absent key when no ongoing outage — mirror that on write
        // so the file never carries a stale empty array between incidents.
        if !outages.isEmpty {
            try container.encode(outages, forKey: .outages)
        }
    }
}

// MARK: - VendorUsageEntry

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
/// The upstream writer removes entries as incidents resolve, so a missing or empty
/// `outages` array means "all clear".
public struct Outage: Codable, Equatable, Sendable, Identifiable {
    public let vendor: Vendor
    public let errorMessage: String
    public let severity: OutageSeverity
    public let since: ISODate
    public let href: URL?

    /// Composite id — outages have no stable upstream id in this shape, so we
    /// derive one from the fields that together identify a single incident row.
    public var id: String {
        "\(vendor.rawValue)|\(since.rawValue)|\(href?.absoluteString ?? "")"
    }

    public init(
        vendor: Vendor,
        errorMessage: String,
        severity: OutageSeverity,
        since: ISODate,
        href: URL? = nil
    ) {
        self.vendor = vendor
        self.errorMessage = errorMessage
        self.severity = severity
        self.since = since
        self.href = href
    }

    private enum CodingKeys: String, CodingKey {
        case vendor, errorMessage, severity, since, href
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vendor = try container.decode(Vendor.self, forKey: .vendor)
        errorMessage = try container.decode(String.self, forKey: .errorMessage)
        severity = try container.decode(OutageSeverity.self, forKey: .severity)
        since = try container.decode(ISODate.self, forKey: .since)
        if let hrefString = try container.decodeIfPresent(String.self, forKey: .href) {
            guard let parsed = URL(string: hrefString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .href, in: container,
                    debugDescription: "Invalid URL string: \(hrefString)")
            }
            href = parsed
        } else {
            href = nil
        }
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
