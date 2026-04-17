import Foundation

// MARK: - AccountEmail

public struct AccountEmail: RawRepresentable, Codable, Equatable, Hashable, Sendable {
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

extension AccountEmail: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { rawValue = value }
}

extension AccountEmail: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - ISODate

/// An ISO 8601 datetime string without sub-second precision.
/// Stores the raw string and lazily parses it when `.date` is accessed.
public struct ISODate: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Creates an ISODate by formatting a Date with the standard ISO 8601 format (no fractional seconds).
    public init(date: Date) {
        // New formatter per call — ISO8601DateFormatter is not thread-safe; acceptable for this cold path
        rawValue = ISO8601DateFormatter().string(from: date)
    }

    /// Parses the stored string and returns the corresponding Date, or nil if parsing fails.
    public var date: Date? {
        // New formatter per call — ISO8601DateFormatter is not thread-safe; acceptable for this cold path
        ISO8601DateFormatter().date(from: rawValue)
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension ISODate: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { rawValue = value }
}

// MARK: - Vendor

/// Identifies the AI service provider. Represented as a plain string in JSON for forward compatibility.
public struct Vendor: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let claude = Vendor(rawValue: "claude")

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension Vendor: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { rawValue = value }
}

extension Vendor: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - MetricKind

/// The discriminator for a usage metric; determines which fields are present.
public enum MetricKind: String, Codable, Equatable, Hashable, Sendable {
    case timeWindow = "time-window"
    case payAsYouGo = "pay-as-you-go"
}

// MARK: - UsagePercent

public struct UsagePercent: RawRepresentable, Codable, Equatable, Comparable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static func < (lhs: UsagePercent, rhs: UsagePercent) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension UsagePercent: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { rawValue = value }
}

// MARK: - DurationMinutes

public struct DurationMinutes: RawRepresentable, Codable, Equatable, Comparable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static func < (lhs: DurationMinutes, rhs: DurationMinutes) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension DurationMinutes: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { rawValue = value }
}
