import Foundation

// MARK: - Root

/// The top-level file model.
///
/// **Schema v2** (new shape): `{ schemaVersion: 2, vendors: { "claude": { accounts: [...], outages: [...] } } }`
/// **Schema v1** (legacy flat shape): `{ usages: [...] }` — decoded transparently and upgraded on next write.
///
/// Internal storage is always the v2 vendor-keyed map. The `usages` computed property
/// flattens it back to `[VendorUsageEntry]` so existing UI and merge code keeps compiling.
public struct UsagesFile: Equatable, Sendable {
    private static let currentSchemaVersion = 2

    public var vendors: [Vendor: VendorSection]

    public init(vendors: [Vendor: VendorSection] = [:]) {
        self.vendors = vendors
    }

    /// Backward-compatible initialiser: builds vendor sections from a flat entry list (no outages).
    public init(usages: [VendorUsageEntry]) {
        var sections: [Vendor: VendorSection] = [:]
        for entry in usages {
            var section = sections[entry.vendor] ?? VendorSection()
            section.accounts.append(VendorAccountEntry(from: entry))
            sections[entry.vendor] = section
        }
        self.vendors = sections
    }

    /// Flattened view for backward-compatible access. Each account entry is annotated
    /// with its parent vendor so callers that filter by vendor keep working.
    public var usages: [VendorUsageEntry] {
        get {
            vendors.flatMap { vendor, section in
                section.accounts.map { $0.toUsageEntry(vendor: vendor) }
            }
        }
        set {
            var sections: [Vendor: VendorSection] = [:]
            // Preserve existing outages when rebuilding from a flat list
            for (vendor, existingSection) in vendors {
                sections[vendor] = VendorSection(accounts: [], outages: existingSection.outages)
            }
            for entry in newValue {
                var section = sections[entry.vendor] ?? VendorSection()
                section.accounts.append(VendorAccountEntry(from: entry))
                sections[entry.vendor] = section
            }
            vendors = sections
        }
    }

    /// Per-vendor outages for display; vendors without outages are omitted.
    public var outagesByVendor: [Vendor: [Outage]] {
        vendors.compactMapValues { section in
            section.outages.isEmpty ? nil : section.outages
        }
    }
}

// MARK: UsagesFile Codable

extension UsagesFile: Codable {
    private enum RootKeys: String, CodingKey {
        case schemaVersion, vendors, usages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: RootKeys.self)
        if container.contains(.schemaVersion) {
            // v2: vendor-keyed shape
            let vendorDict = try container.decode([String: VendorSection].self, forKey: .vendors)
            var typed: [Vendor: VendorSection] = [:]
            for (key, section) in vendorDict {
                typed[Vendor(rawValue: key)] = section
            }
            self.init(vendors: typed)
        } else if container.contains(.usages) {
            // v1: legacy flat array — lift into sections with no outages
            let entries = try container.decode([VendorUsageEntry].self, forKey: .usages)
            self.init(usages: entries)
        } else {
            // Neither v2 sentinel nor v1 usages key — payload is corrupt or unrecognised
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Expected 'schemaVersion' (v2) or 'usages' (v1) key"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RootKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        // Encode vendor map with string keys
        var stringKeyed: [String: VendorSection] = [:]
        for (vendor, section) in vendors {
            stringKeyed[vendor.rawValue] = section
        }
        try container.encode(stringKeyed, forKey: .vendors)
    }
}

// MARK: - VendorSection

/// Per-vendor container: the accounts configured for this vendor and any active outages
/// written by an upstream status-fetching process.
public struct VendorSection: Codable, Equatable, Sendable {
    public var accounts: [VendorAccountEntry]
    public var outages: [Outage]

    public init(accounts: [VendorAccountEntry] = [], outages: [Outage] = []) {
        self.accounts = accounts
        self.outages = outages
    }

    private enum CodingKeys: String, CodingKey {
        case accounts, outages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accounts = try container.decode([VendorAccountEntry].self, forKey: .accounts)
        outages = try container.decodeIfPresent([Outage].self, forKey: .outages) ?? []
    }
}

// MARK: - VendorAccountEntry (persisted shape — no vendor field)

/// The persisted shape of an account inside a vendor section. The vendor is implicit
/// from the parent key, so it is not stored here.
public struct VendorAccountEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { account.rawValue }

    public let account: AccountEmail
    public var isActive: Bool
    public var lastAcquiredOn: ISODate?
    public var lastError: UsageError?
    public var metrics: [UsageMetric]

    public init(
        account: AccountEmail,
        isActive: Bool = false,
        lastAcquiredOn: ISODate? = nil,
        lastError: UsageError? = nil,
        metrics: [UsageMetric] = []
    ) {
        self.account = account
        self.isActive = isActive
        self.lastAcquiredOn = lastAcquiredOn
        self.lastError = lastError
        self.metrics = metrics
    }

    /// Converts from the display-facing VendorUsageEntry (drops the vendor field).
    public init(from entry: VendorUsageEntry) {
        self.account = entry.account
        self.isActive = entry.isActive
        self.lastAcquiredOn = entry.lastAcquiredOn
        self.lastError = entry.lastError
        self.metrics = entry.metrics
    }

    /// Inflates back to VendorUsageEntry by attaching the vendor.
    public func toUsageEntry(vendor: Vendor) -> VendorUsageEntry {
        VendorUsageEntry(
            vendor: vendor,
            account: account,
            isActive: isActive,
            lastAcquiredOn: lastAcquiredOn,
            lastError: lastError,
            metrics: metrics
        )
    }
}

// MARK: - VendorUsageEntry (display-facing view model)

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
    public let url: URL?

    public init(
        id: OutageId,
        title: String,
        severity: OutageSeverity,
        affectedComponents: [String] = [],
        status: String? = nil,
        startedAt: ISODate? = nil,
        url: URL? = nil
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
        if let urlString = try container.decodeIfPresent(String.self, forKey: .url) {
            guard let parsed = URL(string: urlString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .url, in: container,
                    debugDescription: "Invalid URL string: \(urlString)")
            }
            url = parsed
        } else {
            url = nil
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
