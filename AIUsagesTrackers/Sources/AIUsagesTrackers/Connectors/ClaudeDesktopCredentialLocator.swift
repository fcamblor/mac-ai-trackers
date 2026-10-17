import Foundation

/// One OAuth bearer resolved from a Claude Desktop profile's token cache, tagged
/// with a stable account identity derived from the profile (and org when a
/// profile holds more than one). `expiresAt` lets the connector short-circuit a
/// request against a token it already knows is dead, mirroring the CLI
/// connector's local expiry pre-check.
public struct ClaudeDesktopCredential: Sendable, Equatable {
    public let accountLabel: String
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?

    public init(accountLabel: String, accessToken: String, expiresAt: Date?, subscriptionType: String?) {
        self.accountLabel = accountLabel
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }
}

public enum ClaudeDesktopAuthError: Error, CustomStringConvertible, Equatable {
    case noProfiles
    case noUsableCredential
    case safeStorage(SafeStorageError)

    public var description: String {
        switch self {
        case .noProfiles:
            "No Claude Desktop profile directory found"
        case .noUsableCredential:
            "No Claude Desktop profile carries a usable OAuth token"
        case let .safeStorage(error):
            "Safe Storage failure: \(error)"
        }
    }
}

/// Reads OAuth bearers from every discovered Claude Desktop profile.
///
/// Read-only by contract: never writes a profile file, never mutates the
/// Keychain, never runs the OAuth refresh flow. The one secret-bearing call
/// (`SafeStorageKeyReading.readKey`) is gated upstream behind the user's
/// explicit Claude Desktop opt-in, satisfying the bootstrap/no-prompt rule
/// (`.claude/rules/swift-quality.md` §9).
public actor ClaudeDesktopCredentialLocator: CredentialLocator {
    public typealias Credentials = [ClaudeDesktopCredential]

    public static let safeStorageService = "Claude Safe Storage"
    /// Only entries whose cache key carries this scope can read the usage
    /// endpoint; the profile also stores a narrower `user:profile`-only entry we
    /// must skip.
    private static let requiredScope = "user:inference"

    private let profileStore: ClaudeDesktopProfileStore
    private let keyReader: SafeStorageKeyReading
    private let decryptor: AppleSafeStorageDecryptor
    private let logger: FileLogger

    public init(
        profileStore: ClaudeDesktopProfileStore = ClaudeDesktopProfileStore(),
        keyReader: SafeStorageKeyReading = SecuritySafeStorageKeyReader(),
        decryptor: AppleSafeStorageDecryptor = AppleSafeStorageDecryptor(),
        logger: FileLogger = Loggers.claudeDesktop
    ) {
        self.profileStore = profileStore
        self.keyReader = keyReader
        self.decryptor = decryptor
        self.logger = logger
    }

    public func locate() async throws -> [ClaudeDesktopCredential] {
        let profiles = profileStore.discoverProfiles()
        guard !profiles.isEmpty else {
            throw ClaudeDesktopAuthError.noProfiles
        }

        // Read the Safe Storage key once and reuse it for every profile — the
        // decryption key is shared across all profiles of the same app install.
        let keyPassword: Data
        do {
            keyPassword = try await keyReader.readKey(service: Self.safeStorageService)
        } catch let error as SafeStorageError {
            throw ClaudeDesktopAuthError.safeStorage(error)
        }

        var credentials: [ClaudeDesktopCredential] = []
        for profile in profiles {
            guard let encrypted = profile.encryptedTokenCache else {
                logger.log(.info, "Profile '\(profile.name)' has no token cache — skipping")
                continue
            }
            do {
                let plaintext = try decryptor.decrypt(base64Value: encrypted, keyPassword: keyPassword)
                credentials.append(contentsOf: try Self.parseCredentials(plaintext: plaintext, profileName: profile.name))
            } catch {
                // One broken profile must not sink the others.
                logger.log(.error, "Failed to decrypt/parse token cache for profile '\(profile.name)': \(error)")
            }
        }

        guard !credentials.isEmpty else {
            throw ClaudeDesktopAuthError.noUsableCredential
        }
        return credentials
    }

    /// Parses the decrypted `oauth:tokenCacheV2` JSON. Keys look like
    /// `acct:<accountUuid>|<sessionUuid>:<orgUuid>:https://api.anthropic.com:<space-separated scopes>`.
    /// We keep only entries carrying the inference scope. When a single profile
    /// holds several orgs we disambiguate the account label with a short org id
    /// so the merge keeps them as distinct accounts.
    static func parseCredentials(plaintext: Data, profileName: String) throws -> [ClaudeDesktopCredential] {
        guard let json = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            return []
        }

        let inferenceKeys = json.keys.filter { $0.contains(requiredScope) }
        let distinctOrgs = Set(inferenceKeys.compactMap(orgUuid(fromCacheKey:)))
        let needsOrgSuffix = distinctOrgs.count > 1

        var result: [ClaudeDesktopCredential] = []
        var usedLabels = Set<String>()
        for key in inferenceKeys.sorted() {
            guard let entry = json[key] as? [String: Any],
                  let token = entry["token"] as? String, !token.isEmpty else {
                continue
            }
            let org = orgUuid(fromCacheKey: key)
            var label = profileName
            if needsOrgSuffix, let org {
                label = "\(profileName) · \(org.prefix(8))"
            }
            // Guard against two inference entries for the same org (e.g. differing
            // optional scopes) collapsing onto one label and losing the first.
            guard usedLabels.insert(label).inserted else { continue }
            result.append(ClaudeDesktopCredential(
                accountLabel: label,
                accessToken: token,
                expiresAt: parseExpiresAt(entry["expiresAt"]),
                subscriptionType: entry["subscriptionType"] as? String
            ))
        }
        return result
    }

    /// Extracts the 36-char organisation UUID that precedes `:https` in a cache
    /// key. Returns nil when the key does not match the expected shape.
    static func orgUuid(fromCacheKey key: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "([0-9a-fA-F-]{36}):https"
        ) else {
            return nil
        }
        let range = NSRange(key.startIndex..<key.endIndex, in: key)
        guard let match = regex.firstMatch(in: key, range: range),
              let orgRange = Range(match.range(at: 1), in: key) else {
            return nil
        }
        return String(key[orgRange])
    }

    /// Accepts `Double`, `Int`, or numeric `String` millisecond epoch — the same
    /// Node.js `Date.now()` convention the CLI uses.
    static func parseExpiresAt(_ raw: Any?) -> Date? {
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
