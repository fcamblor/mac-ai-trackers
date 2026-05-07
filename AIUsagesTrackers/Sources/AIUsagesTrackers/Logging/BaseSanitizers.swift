import Foundation

/// Header redaction shared across vendors. Composed by every per-vendor
/// sanitizer — see `JSONFieldSanitizer` for the body-key counterpart.
public struct BaseHeaderSanitizer: Sendable {
    /// Header names matched case-insensitively that always get redacted.
    /// Adding a new header here applies to every vendor at once — only do
    /// this for headers that are universally credential-bearing.
    public static let alwaysRedacted: Set<String> = [
        "authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token",
        "proxy-authorization",
    ]

    public static let redactedPlaceholder = "<redacted>"

    public init() {}

    public func sanitize(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers {
            if Self.alwaysRedacted.contains(key.lowercased()) {
                result[key] = Self.redactedPlaceholder
            } else {
                result[key] = value
            }
        }
        return result
    }
}

/// Strips JSON object fields whose key matches any of the
/// `sensitiveKeyPatterns` (substring match, case-insensitive). Values are
/// replaced by the literal string `"<redacted>"` so the payload structure
/// stays intact and parseable for triage.
///
/// Each per-vendor sanitizer composes a `JSONFieldSanitizer` with its own
/// `sensitiveKeyPatterns` and `extraExactKeys` (keys whose substring rule
/// would otherwise miss them — e.g. `account_id` if `id` is too broad).
public struct JSONFieldSanitizer: Sendable {
    public let substringPatterns: [String]
    public let extraExactKeys: Set<String>

    /// `<redacted>` matches the in-payload placeholder for redacted strings;
    /// the body sanitizer always emits this same value so leakage tests can
    /// scan output for it as a positive sentinel of "something was redacted".
    public static let redactedPlaceholder = "<redacted>"

    /// Substrings checked case-insensitively against every JSON object key.
    /// Vendors compose this default with their own additions.
    public static let defaultSubstringPatterns: [String] = [
        "token", "key", "secret", "password", "credential", "email",
    ]

    public init(
        substringPatterns: [String] = JSONFieldSanitizer.defaultSubstringPatterns,
        extraExactKeys: Set<String> = []
    ) {
        self.substringPatterns = substringPatterns
        self.extraExactKeys = extraExactKeys
    }

    public func sanitize(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return data
        }
        let masked = sanitizeAny(object)
        guard let out = try? JSONSerialization.data(
            withJSONObject: masked,
            options: [.sortedKeys, .fragmentsAllowed]
        ) else {
            return data
        }
        return out
    }

    private func sanitizeAny(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (key, child) in dict {
                if matchesSensitiveKey(key) {
                    result[key] = Self.redactedPlaceholder
                } else {
                    result[key] = sanitizeAny(child)
                }
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map(sanitizeAny)
        }
        return value
    }

    private func matchesSensitiveKey(_ key: String) -> Bool {
        if extraExactKeys.contains(key) { return true }
        let lower = key.lowercased()
        return substringPatterns.contains { lower.contains($0) }
    }
}

/// Strips substrings matching any provided regex pattern. Vendors
/// compose this with their token shapes (e.g. `sk-ant-…`, `ghu_…`,
/// `Bearer\s+\S+`) so error-message log lines that splice raw
/// credentials into prose still get scrubbed at the logger boundary.
public struct SecretPatternSanitizer: Sendable {
    public static let placeholder = "<redacted>"

    private let patterns: [NSRegularExpression]

    public init(patterns: [String]) {
        self.patterns = patterns.compactMap { source in
            // Patterns are static configuration baked into per-vendor
            // sanitizers — failing to compile one is a build-time bug
            // that should surface, not be hidden as a silent skip.
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: source)
        }
    }

    public func sanitize(_ message: String) -> String {
        var current = message
        for pattern in patterns {
            let range = NSRange(current.startIndex..<current.endIndex, in: current)
            current = pattern.stringByReplacingMatches(
                in: current,
                range: range,
                withTemplate: Self.placeholder
            )
        }
        return current
    }
}

/// Replaces email-looking substrings with the literal `<email>`. Composed
/// by per-vendor sanitizers in their `sanitize(_ message:)` and (after
/// JSON masking) `sanitize(_ payload:)` paths so log lines that splice
/// payload fragments into prose still get scrubbed.
public struct EmailPatternSanitizer: Sendable {
    public static let placeholder = "<email>"

    /// `NSRegularExpression` is documented thread-safe (Apple Foundation
    /// reference) — Swift's native `Regex<...>` isn't `Sendable`, which
    /// would force per-call recompilation or actor isolation. The literal
    /// pattern is a conservative shape: RFC 5322 is intractable with a
    /// regex, the goal is to catch every realistic vendor-emitted email
    /// with no false negatives, accepting some false positives (e.g.
    /// version strings containing `@`) that only affect log readability.
    private static let pattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    }()

    public init() {}

    public func sanitize(_ message: String) -> String {
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        return Self.pattern.stringByReplacingMatches(
            in: message,
            range: range,
            withTemplate: Self.placeholder
        )
    }
}
