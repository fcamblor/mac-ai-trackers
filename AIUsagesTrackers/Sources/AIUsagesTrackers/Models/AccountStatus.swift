import Foundation

// MARK: - AccountStatus

/// Account-level state reported alongside the usage metrics: plan, whether the
/// vendor is currently refusing requests, per-model availability, reset tokens
/// and credit details. Every field is optional so a vendor only fills what its
/// API exposes, and the UI renders nothing for a nominal account.
public struct AccountStatus: Codable, Equatable, Sendable {
    public var plan: PlanType?
    public var block: AccountBlock?
    /// Only models the vendor reports as unavailable — available models carry
    /// no actionable information and are not persisted.
    public var unavailableModels: [ModelAvailability]
    public var resetCredits: ResetCredits?
    public var credits: CreditsSummary?

    public init(
        plan: PlanType? = nil,
        block: AccountBlock? = nil,
        unavailableModels: [ModelAvailability] = [],
        resetCredits: ResetCredits? = nil,
        credits: CreditsSummary? = nil
    ) {
        self.plan = plan
        self.block = block
        self.unavailableModels = unavailableModels
        self.resetCredits = resetCredits
        self.credits = credits
    }

    private enum CodingKeys: String, CodingKey {
        case plan, block, unavailableModels, resetCredits, credits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plan = try container.decodeIfPresent(PlanType.self, forKey: .plan)
        block = try container.decodeIfPresent(AccountBlock.self, forKey: .block)
        unavailableModels = try container.decodeIfPresent([ModelAvailability].self, forKey: .unavailableModels) ?? []
        resetCredits = try container.decodeIfPresent(ResetCredits.self, forKey: .resetCredits)
        credits = try container.decodeIfPresent(CreditsSummary.self, forKey: .credits)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(plan, forKey: .plan)
        try container.encodeIfPresent(block, forKey: .block)
        if !unavailableModels.isEmpty {
            try container.encode(unavailableModels, forKey: .unavailableModels)
        }
        try container.encodeIfPresent(resetCredits, forKey: .resetCredits)
        try container.encodeIfPresent(credits, forKey: .credits)
    }
}

// MARK: - PlanType

/// Vendor plan slug (`plus`, `pro`, `prolite`…). Open-ended: new plans appear
/// without a code change and fall back to a capitalised slug for display.
public struct PlanType: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    private static let knownDisplayNames: [String: String] = [
        "free": "Free",
        "go": "Go",
        "plus": "Plus",
        "pro": "Pro",
        "prolite": "Pro Lite",
        "team": "Team",
        "business": "Business",
        "enterprise": "Enterprise",
        "edu": "Edu",
        "max": "Max",
        "max_5x": "Max 5x",
        "max_20x": "Max 20x",
        "team_standard": "Team Standard",
        "team_premium": "Team Premium",
        "individual": "Individual",
        "free_limited_copilot": "Free",
        "business_copilot": "Business",
        "enterprise_copilot": "Enterprise",
        "copilot_pro": "Pro",
        "copilot_pro_plus": "Pro+",
        "copilot_business": "Business",
        "copilot_enterprise": "Enterprise",
    ]

    public var displayName: String {
        Self.knownDisplayNames[rawValue.lowercased()]
            ?? rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension PlanType: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { rawValue = value }
}

extension PlanType: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - AccountBlock

/// The vendor currently refuses requests for this account.
public struct AccountBlock: Codable, Equatable, Sendable {
    public let reason: BlockReason
    /// When requests are accepted again; nil when the vendor gives no date
    /// (e.g. an admin spending cap has no automatic end).
    public let resumesAt: ISODate?

    public init(reason: BlockReason, resumesAt: ISODate?) {
        self.reason = reason
        self.resumesAt = resumesAt
    }
}

/// Why an account is blocked. Struct rather than enum so a reason written by a
/// newer build still decodes.
public struct BlockReason: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A usage window is exhausted; lifts automatically at its reset.
    public static let rateLimit = BlockReason(rawValue: "rate_limit")
    /// An organisation admin's spending cap is reached; only the admin can lift it.
    public static let spendControl = BlockReason(rawValue: "spend_control")

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension BlockReason: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { rawValue = value }
}

// MARK: - ModelAvailability

public struct ModelSlug: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ModelSlug: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { rawValue = value }
}

extension ModelSlug: CustomStringConvertible {
    public var description: String { rawValue }
}

public struct ModelAvailability: Codable, Equatable, Sendable {
    public let model: ModelSlug
    public let availableAt: ISODate?
    /// Buying credits would make the model usable right away.
    public let creditsWouldEnable: Bool

    public init(model: ModelSlug, availableAt: ISODate?, creditsWouldEnable: Bool) {
        self.model = model
        self.availableAt = availableAt
        self.creditsWouldEnable = creditsWouldEnable
    }
}

// MARK: - ResetCredits

/// "Usage limit reset" tokens the user can redeem to clear an exhausted window.
public struct ResetCredits: Codable, Equatable, Sendable {
    public let available: Int
    /// Subset of `available` that would have an effect right now.
    public let applicable: Int
    /// Per-grant detail (expiry, kind). Empty when the vendor only reports counts.
    public let grants: [ResetGrant]

    public init(available: Int, applicable: Int, grants: [ResetGrant] = []) {
        self.available = available
        self.applicable = applicable
        self.grants = grants
    }

    /// Earliest expiry among grants that still have resets left — the date
    /// after which at least one free reset is lost.
    public var nextExpiry: ISODate? {
        grants
            .filter { $0.remaining > 0 }
            .compactMap { grant in grant.expiresAt.flatMap { date in date.date.map { (date, $0) } } }
            .min { $0.1 < $1.1 }?
            .0
    }

    private enum CodingKeys: String, CodingKey {
        case available, applicable, grants
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decode(Int.self, forKey: .available)
        applicable = try container.decode(Int.self, forKey: .applicable)
        grants = try container.decodeIfPresent([ResetGrant].self, forKey: .grants) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try container.encode(applicable, forKey: .applicable)
        if !grants.isEmpty {
            try container.encode(grants, forKey: .grants)
        }
    }
}

/// What a reset clears. Open-ended: vendors add reset flavours over time.
public struct ResetGrantKind: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Clears both the session and the weekly windows.
    public static let full = ResetGrantKind(rawValue: "full")
    /// Clears the session (5h) window only.
    public static let session = ResetGrantKind(rawValue: "session")

    public var displayName: String {
        switch self {
        case .full: "Full reset"
        case .session: "5-hour reset"
        default: rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ResetGrantKind: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { rawValue = value }
}

public struct ResetGrant: Codable, Equatable, Sendable {
    public let kind: ResetGrantKind
    public let label: String?
    public let remaining: Int
    /// After this date the unused resets of the grant are lost; nil when they never expire.
    public let expiresAt: ISODate?
    public let usableNow: Bool

    public init(kind: ResetGrantKind, label: String?, remaining: Int, expiresAt: ISODate?, usableNow: Bool) {
        self.kind = kind
        self.label = label
        self.remaining = remaining
        self.expiresAt = expiresAt
        self.usableNow = usableNow
    }
}

// MARK: - CreditsSummary

/// Inclusive `[lower, upper]` estimate returned by the vendor.
public struct MessageRange: Codable, Equatable, Sendable {
    public let lower: Int
    public let upper: Int

    public init(lower: Int, upper: Int) {
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
    }

    public var isZero: Bool { upper == 0 }
}

public struct CreditsSummary: Codable, Equatable, Sendable {
    public let unlimited: Bool
    public let overageLimitReached: Bool
    public let approxLocalMessages: MessageRange?
    public let approxCloudMessages: MessageRange?

    public init(
        unlimited: Bool,
        overageLimitReached: Bool,
        approxLocalMessages: MessageRange?,
        approxCloudMessages: MessageRange?
    ) {
        self.unlimited = unlimited
        self.overageLimitReached = overageLimitReached
        self.approxLocalMessages = approxLocalMessages
        self.approxCloudMessages = approxCloudMessages
    }
}
