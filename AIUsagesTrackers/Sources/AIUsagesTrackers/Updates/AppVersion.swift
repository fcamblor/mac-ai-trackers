import Foundation

/// Semantic version of the app, parsed from `CFBundleShortVersionString` or a
/// release tag like `v1.2.3`. Comparison ignores pre-release and metadata
/// suffixes — releases tagged with build suffixes still compare numerically.
public struct AppVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let rawValue: String

    public init?(string: String) {
        let trimmed = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? trimmed
        let parts = core.split(separator: ".")
        guard parts.count >= 1, let major = Int(parts[0]) else { return nil }
        let minor = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        let patch = parts.count >= 3 ? Int(parts[2]) ?? 0 : 0
        self.major = major
        self.minor = minor
        self.patch = patch
        self.rawValue = trimmed
    }

    public var description: String { rawValue }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}
