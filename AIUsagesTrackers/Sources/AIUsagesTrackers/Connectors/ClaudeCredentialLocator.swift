import Foundation

/// What `ClaudeCredentialLocator.locate()` produces — a Claude OAuth bearer
/// token resolved from the macOS Keychain entry written by the `claude` CLI.
public struct ClaudeCredentials: Sendable, Equatable {
    public let accessToken: String

    public init(accessToken: String) {
        self.accessToken = accessToken
    }
}

public enum ClaudeAuthError: Error, CustomStringConvertible {
    case keychainAccessDenied(serviceName: String, exitCode: Int32)
    case keychainEmpty(serviceName: String)
    case keychainTimeout(serviceName: String, timeoutSeconds: Int)
    case keychainParseFailed(serviceName: String, rawPreview: String)
    case apiKeyOnlyUnsupported(serviceName: String)
    /// Access token from the keychain has passed its `expiresAt` timestamp.
    /// The user must re-run the `claude` CLI to refresh — the locator is
    /// read-only by contract and never invokes the OAuth refresh flow.
    case tokenExpired(serviceName: String, expiredAt: Date)

    public var description: String {
        switch self {
        case let .keychainAccessDenied(svc, code):
            "Keychain access denied for service '\(svc)' (exit \(code))"
        case let .keychainEmpty(svc):
            "Keychain item is empty for service '\(svc)'"
        case let .keychainTimeout(svc, secs):
            "Keychain access timed out after \(secs)s for service '\(svc)'"
        case let .keychainParseFailed(svc, preview):
            "Failed to parse keychain value for service '\(svc)' — preview: '\(preview.prefix(80))'"
        case let .apiKeyOnlyUnsupported(svc):
            "Claude Code is authenticated with a standard API key in service '\(svc)'; usage reporting requires Claude Code OAuth credentials"
        case let .tokenExpired(svc, expiredAt):
            "OAuth access token for service '\(svc)' expired at \(expiredAt)"
        }
    }
}

/// Reads the Claude OAuth access token from the macOS Keychain entry
/// written by the `claude` CLI. Read-only by contract — never calls
/// `SecItemAdd`, `SecItemUpdate`, `SecItemDelete`; never invokes
/// `claude auth login`; never writes any vendor file.
public actor ClaudeCredentialLocator: CredentialLocator {
    public typealias Credentials = ClaudeCredentials

    public static let defaultKeychainService = "Claude Code-credentials"
    public static let apiKeyKeychainService = "Claude Code"
    /// Long enough for a cached keychain lookup; short enough to avoid
    /// stalling the poller.
    public static let keychainTimeoutSeconds = SystemKeychainQuery.timeoutSeconds
    /// Treat the token as expired this many seconds before the actual
    /// `expiresAt` to avoid the race where we send a request just as the
    /// token flips invalid and burn a 401 we could have skipped.
    public static let expirySkewSeconds: TimeInterval = 60

    private let keychainServiceName: String
    private let keychainQuerying: any KeychainQuerying
    private let logger: FileLogger
    private let clock: @Sendable () -> Date

    public init(
        keychainServiceName: String = ClaudeCredentialLocator.defaultKeychainService,
        keychainQuerying: any KeychainQuerying = SystemKeychainQuery(),
        logger: FileLogger = Loggers.claude,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keychainServiceName = keychainServiceName
        self.keychainQuerying = keychainQuerying
        self.logger = logger
        self.clock = clock
    }

    public func locate() async throws -> ClaudeCredentials {
        let serviceName = keychainServiceName
        let now = clock()

        let allEntries: [Data]
        do {
            allEntries = try await keychainQuerying.allPasswords(service: serviceName)
        } catch {
            throw try await mapKeychainError(error, serviceName: serviceName)
        }

        guard !allEntries.isEmpty else {
            if serviceName == Self.defaultKeychainService, try await hasStandardAPIKey() {
                throw ClaudeAuthError.apiKeyOnlyUnsupported(serviceName: Self.apiKeyKeychainService)
            }
            throw ClaudeAuthError.keychainEmpty(serviceName: serviceName)
        }

        // Parse every entry; keep those with a non-empty claudeAiOauth.accessToken.
        // Multiple entries for the same service arise when one holds MCP plugin OAuth
        // state (acct=unknown) and another holds the actual usage bearer (acct=$USER).
        var candidates: [(token: String, expiryDate: Date?)] = []
        var lastRawPreview = ""

        for data in allEntries {
            guard let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }

            let parsed: [String: Any]
            do {
                parsed = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            } catch {
                lastRawPreview = raw
                continue
            }

            guard let oauth = parsed["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String,
                  !token.isEmpty else {
                lastRawPreview = raw
                continue
            }

            guard !candidates.contains(where: { $0.token == token }) else { continue }

            // expiresAt is a Unix millisecond timestamp written by the `claude` CLI
            // (Node.js convention — `Date.now()`). A missing or unparseable value
            // skips the local check: the API call still happens and a 401 will
            // surface as token_expired downstream.
            let expiryDate = oauth["expiresAt"].flatMap { Self.parseExpiresAt($0) }
            candidates.append((token: token, expiryDate: expiryDate))
        }

        let skewedNow = now.addingTimeInterval(Self.expirySkewSeconds)
        if let bestKnownExpiry = candidates.first(where: { candidate in
            guard let expiryDate = candidate.expiryDate else { return false }
            return skewedNow < expiryDate
        }) {
            return ClaudeCredentials(accessToken: bestKnownExpiry.token)
        }

        if let fallbackUnknownExpiry = candidates.first(where: { $0.expiryDate == nil }) {
            return ClaudeCredentials(accessToken: fallbackUnknownExpiry.token)
        }

        if let expired = candidates.first, let expiredAt = expired.expiryDate {
            throw ClaudeAuthError.tokenExpired(serviceName: serviceName, expiredAt: expiredAt)
        }

        if !lastRawPreview.isEmpty {
            throw ClaudeAuthError.keychainParseFailed(serviceName: serviceName, rawPreview: lastRawPreview)
        }

        throw ClaudeAuthError.keychainEmpty(serviceName: serviceName)
    }

    private func hasStandardAPIKey() async throws -> Bool {
        let entries: [Data]
        do {
            entries = try await keychainQuerying.allPasswords(service: Self.apiKeyKeychainService)
        } catch {
            return false
        }
        return entries.contains {
            String(data: $0, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("sk-ant-api") == true
        }
    }

    private func mapKeychainError(_ error: Error, serviceName: String) async throws -> ClaudeAuthError {
        if let qErr = error as? KeychainQueryError {
            switch qErr {
            case let .timeout(_, secs):
                return ClaudeAuthError.keychainTimeout(serviceName: serviceName, timeoutSeconds: secs)
            case let .accessDenied(_, status):
                if serviceName == Self.defaultKeychainService, try await hasStandardAPIKey() {
                    return ClaudeAuthError.apiKeyOnlyUnsupported(serviceName: Self.apiKeyKeychainService)
                }
                return ClaudeAuthError.keychainAccessDenied(serviceName: serviceName, exitCode: status)
            }
        }
        return ClaudeAuthError.keychainAccessDenied(serviceName: serviceName, exitCode: -1)
    }

    /// Accepts `Double`, `Int`, or numeric `String` (millisecond epoch).
    /// Returns nil if the value is missing or in an unrecognized shape — the
    /// caller then skips the local expiry check rather than risking a false
    /// positive that would silence the connector.
    static func parseExpiresAt(_ raw: Any) -> Date? {
        let millis: Double
        switch raw {
        case let value as Double: millis = value
        case let value as Int: millis = Double(value)
        case let value as String:
            guard let parsed = Double(value) else { return nil }
            millis = parsed
        default: return nil
        }
        guard millis.isFinite, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}
