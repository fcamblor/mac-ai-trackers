import Foundation

// MARK: - StatusPlatform

/// The status-page platform a vendor uses. Open-ended so future vendors using
/// statuspage.io / etc can reuse the same registry + preferences shell.
public struct StatusPlatform: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let incidentIO = StatusPlatform(rawValue: "incidentIO")

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension StatusPlatform: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { rawValue = value }
}

extension StatusPlatform: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - StatusComponentID

/// Stable per-component ULID assigned by the status-page platform. Used as
/// the subscription key — names like "App" or "CLI" are not unique across
/// groups so they cannot serve as keys.
public struct StatusComponentID: RawRepresentable, Codable, Equatable, Hashable, Sendable {
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

extension StatusComponentID: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { rawValue = value }
}

extension StatusComponentID: CustomStringConvertible {
    public var description: String { rawValue }
}

// MARK: - StatusComponent

/// A single child component of a status-page group (e.g. "Codex Web" under
/// the "Codex" group). The id is the subscription key; `name` is shown to
/// users in the preferences UI so the listing is meaningful instead of a
/// raw ULID.
public struct StatusComponent: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: StatusComponentID
    public let name: String
    public let groupID: StatusComponentID

    public init(id: StatusComponentID, name: String, groupID: StatusComponentID) {
        self.id = id
        self.name = name
        self.groupID = groupID
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case groupID = "group_id"
    }
}

// MARK: - StatusComponentsCacheEntry

/// One refresh result for a (platform, host, group-root) triple. Indexing by
/// all three keeps the file open to future vendors on the same platform
/// without collisions.
public struct StatusComponentsCacheEntry: Codable, Equatable, Sendable {
    public let platform: StatusPlatform
    public let host: String
    public let groupRootID: StatusComponentID
    public var lastRefreshedAt: ISODate
    public var components: [StatusComponent]

    public init(
        platform: StatusPlatform,
        host: String,
        groupRootID: StatusComponentID,
        lastRefreshedAt: ISODate,
        components: [StatusComponent]
    ) {
        self.platform = platform
        self.host = host
        self.groupRootID = groupRootID
        self.lastRefreshedAt = lastRefreshedAt
        self.components = components
    }

    private enum CodingKeys: String, CodingKey {
        case platform
        case host
        case groupRootID = "group_root_id"
        case lastRefreshedAt = "last_refreshed_at"
        case components
    }
}

// MARK: - StatusComponentsCache

/// Root document for `status-components.json`.
public struct StatusComponentsCache: Codable, Equatable, Sendable {
    public var entries: [StatusComponentsCacheEntry]

    public init(entries: [StatusComponentsCacheEntry] = []) {
        self.entries = entries
    }

    public func entry(
        platform: StatusPlatform,
        host: String,
        groupRootID: StatusComponentID
    ) -> StatusComponentsCacheEntry? {
        entries.first {
            $0.platform == platform
                && $0.host == host
                && $0.groupRootID == groupRootID
        }
    }

    public mutating func upsert(_ entry: StatusComponentsCacheEntry) {
        if let idx = entries.firstIndex(where: {
            $0.platform == entry.platform
                && $0.host == entry.host
                && $0.groupRootID == entry.groupRootID
        }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
    }
}
