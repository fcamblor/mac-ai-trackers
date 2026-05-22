import Foundation
import Security

/// Result of the on-demand Claude Keychain diagnostic surfaced in the
/// "Coding Assistants" settings tab. Enumerates every generic-password item
/// stored under the `Claude Code-credentials` service, parses each one for
/// a usable `claudeAiOauth.accessToken`, and lets the UI pick which entry
/// the runtime should target. Runs only on explicit user action so it can
/// never trigger Keychain authorisation prompts at app startup.
public struct KeychainDiagnosticReport: Sendable, Equatable {
    public let credentialsServiceName: String
    public let apiKeyServiceName: String
    public let entries: [Entry]
    /// `true` when a generic-password under the `Claude Code` service holds a
    /// raw `sk-ant-api…` API key (which the connector cannot use for usage
    /// metrics — only OAuth credentials work).
    public let apiKeyDetected: Bool

    public struct Entry: Sendable, Equatable {
        public let account: String?
        public let status: Status
    }

    public enum Status: Sendable, Equatable {
        /// `claudeAiOauth.accessToken` present and (if `expiresAt` is set) not yet expired.
        case validOAuthToken(expiresAt: Date?)
        /// `claudeAiOauth.accessToken` present but the embedded `expiresAt` is in the past.
        case expiredOAuthToken(expiresAt: Date)
        /// JSON parsed but `claudeAiOauth.accessToken` is missing or empty.
        case missingOAuthBlock
        /// Entry exists but its value is not parseable JSON.
        case unparseable(rawPreview: String)
        /// Entry has empty data.
        case empty
        /// `SecItemCopyMatching` failed to read this entry's data.
        case readDenied(status: OSStatus)
    }

    public var totalEntries: Int { entries.count }

    public var distinctAccounts: [String] {
        Array(Set(entries.compactMap(\.account))).sorted()
    }

    public var entriesWithoutAccount: Int {
        entries.filter { $0.account == nil }.count
    }

    public var hasDuplicates: Bool {
        let distinctBuckets = distinctAccounts.count + (entriesWithoutAccount > 0 ? 1 : 0)
        return totalEntries > distinctBuckets
    }

    public var hasUsableOAuthToken: Bool {
        entries.contains { entry in
            if case .validOAuthToken = entry.status { true } else { false }
        }
    }

    /// `true` when at least one entry carries a `claudeAiOauth` block, even if
    /// its `accessToken` has expired — pinning the runtime to that entry still
    /// makes sense because a `claude` CLI refresh will revive it in place.
    public var hasPinnableOAuthEntry: Bool {
        entries.contains { entry in
            switch entry.status {
            case .validOAuthToken, .expiredOAuthToken: true
            default: false
            }
        }
    }
}

public enum KeychainDiagnosticError: Error, CustomStringConvertible, Equatable {
    case accessDenied(service: String, status: OSStatus)
    case timeout(service: String, timeoutSeconds: Int)

    public var description: String {
        switch self {
        case let .accessDenied(svc, status):
            "Keychain diagnostic denied for service '\(svc)' (OSStatus \(status))"
        case let .timeout(svc, secs):
            "Keychain diagnostic timed out after \(secs)s for service '\(svc)'"
        }
    }
}

/// On-demand scanner used by the Coding Assistants settings tab. Runs the
/// two-step `kSecReturnAttributes` then per-account `kSecReturnData` lookups
/// so the scan keeps working even when the combined `kSecMatchLimitAll +
/// kSecReturnData` query returns `errSecParam` — a failure mode the
/// Keychain raises when several generic-password items share the same
/// service name and macOS cannot disambiguate them.
public struct KeychainDuplicatesScanner: Sendable {
    static let timeoutSeconds = 10

    private let credentialsServiceName: String
    private let apiKeyServiceName: String

    public init(
        credentialsServiceName: String = ClaudeCredentialLocator.defaultKeychainService,
        apiKeyServiceName: String = ClaudeCredentialLocator.apiKeyKeychainService
    ) {
        self.credentialsServiceName = credentialsServiceName
        self.apiKeyServiceName = apiKeyServiceName
    }

    public func scan() async throws -> KeychainDiagnosticReport {
        try await withCheckedThrowingContinuation { continuation in
            let callback = OneShotScanCallback()
            let credentialsService = credentialsServiceName
            let apiKeyService = apiKeyServiceName

            DispatchQueue.global(qos: .userInitiated).async {
                callback.resume(
                    continuation,
                    with: Self.runScan(credentialsService: credentialsService, apiKeyService: apiKeyService)
                )
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(Self.timeoutSeconds)) {
                callback.resume(
                    continuation,
                    with: .failure(KeychainDiagnosticError.timeout(
                        service: credentialsService,
                        timeoutSeconds: Self.timeoutSeconds
                    ))
                )
            }
        }
    }

    private static func runScan(
        credentialsService: String,
        apiKeyService: String
    ) -> Result<KeychainDiagnosticReport, Error> {
        let entriesResult = enumerateEntries(service: credentialsService)
        let entries: [KeychainDiagnosticReport.Entry]
        switch entriesResult {
        case let .success(items): entries = items
        case let .failure(error): return .failure(error)
        }

        let apiKeyDetected = detectAPIKey(service: apiKeyService)

        return .success(KeychainDiagnosticReport(
            credentialsServiceName: credentialsService,
            apiKeyServiceName: apiKeyService,
            entries: entries,
            apiKeyDetected: apiKeyDetected
        ))
    }

    private static func enumerateEntries(service: String) -> Result<[KeychainDiagnosticReport.Entry], Error> {
        let attributesQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnAttributes: true,
        ]
        var rawResult: CFTypeRef?
        let status = SecItemCopyMatching(attributesQuery as CFDictionary, &rawResult)
        switch status {
        case errSecItemNotFound:
            return .success([])
        case errSecSuccess:
            break
        default:
            return .failure(KeychainDiagnosticError.accessDenied(service: service, status: status))
        }

        let attributeItems = attributeDictionaries(from: rawResult)
        var entries: [KeychainDiagnosticReport.Entry] = []
        var processedAccounts = Set<String>()
        var didProcessAccountlessBucket = false

        for item in attributeItems {
            let account = stringAttribute(kSecAttrAccount, in: item)

            var dataQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecMatchLimit: kSecMatchLimitOne,
                kSecReturnData: true,
            ]
            if let account {
                guard processedAccounts.insert(account).inserted else {
                    // Already covered by a previous attribute entry sharing this account.
                    entries.append(KeychainDiagnosticReport.Entry(account: account, status: .empty))
                    continue
                }
                dataQuery[kSecAttrAccount] = account
            } else {
                if attributeItems.count > 1 {
                    guard !didProcessAccountlessBucket else {
                        entries.append(KeychainDiagnosticReport.Entry(account: nil, status: .empty))
                        continue
                    }
                    didProcessAccountlessBucket = true
                }
            }

            var dataResult: CFTypeRef?
            let dataStatus = SecItemCopyMatching(dataQuery as CFDictionary, &dataResult)
            switch dataStatus {
            case errSecSuccess:
                let data = (dataResult as? Data) ?? Data()
                entries.append(KeychainDiagnosticReport.Entry(
                    account: account,
                    status: parsePayload(data)
                ))
            case errSecItemNotFound:
                entries.append(KeychainDiagnosticReport.Entry(account: account, status: .empty))
            default:
                entries.append(KeychainDiagnosticReport.Entry(
                    account: account,
                    status: .readDenied(status: dataStatus)
                ))
            }
        }

        return .success(entries)
    }

    private static func parsePayload(_ data: Data) -> KeychainDiagnosticReport.Status {
        guard !data.isEmpty,
              let raw = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return .empty
        }

        let parsed: [String: Any]
        do {
            parsed = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            return .unparseable(rawPreview: String(raw.prefix(80)))
        }

        guard let oauth = parsed["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return .missingOAuthBlock
        }

        let expiryDate = oauth["expiresAt"].flatMap { parseExpiresAt($0) }
        if let expiryDate, expiryDate <= Date() {
            return .expiredOAuthToken(expiresAt: expiryDate)
        }
        return .validOAuthToken(expiresAt: expiryDate)
    }

    private static func detectAPIKey(service: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let blobs = result as? [Data] else {
            return false
        }
        return blobs.contains { data in
            guard let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return raw.hasPrefix("sk-ant-api")
        }
    }

    private static func attributeDictionaries(from result: CFTypeRef?) -> [[String: Any]] {
        if let array = result as? [[String: Any]] { return array }
        if let dictionary = result as? [String: Any] { return [dictionary] }
        return []
    }

    private static func stringAttribute(_ key: CFString, in item: [String: Any]) -> String? {
        if let string = item[key as String] as? String { return string }
        if let data = item[key as String] as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    /// Accepts `Double`, `Int`, or numeric `String` (millisecond epoch — Node.js
    /// `Date.now()` convention used by the `claude` CLI).
    private static func parseExpiresAt(_ raw: Any) -> Date? {
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

private final class OneShotScanCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ continuation: CheckedContinuation<KeychainDiagnosticReport, Error>,
        with result: Result<KeychainDiagnosticReport, Error>
    ) {
        lock.lock()
        let shouldResume = !didResume
        didResume = true
        lock.unlock()

        guard shouldResume else { return }
        continuation.resume(with: result)
    }
}
