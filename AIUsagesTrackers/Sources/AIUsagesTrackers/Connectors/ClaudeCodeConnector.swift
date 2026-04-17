import Foundation

public actor ClaudeCodeConnector: UsageConnector {
    nonisolated public let vendor: Vendor = .claude

    private let claudeConfigPath: String
    private let logger: FileLogger
    private let session: URLSession
    private let keychainServiceName: String
    private let tokenProvider: (@Sendable () async throws -> String)?
    private let accountProvider: (@Sendable () -> AccountEmail?)?

    private var lastKnownMetrics: [UsageMetric] = []

    public init(
        claudeConfigPath: String? = nil,
        logger: FileLogger = Loggers.claude,
        session: URLSession = .shared,
        keychainServiceName: String = "Claude Code-credentials",
        tokenProvider: (@Sendable () async throws -> String)? = nil,
        accountProvider: (@Sendable () -> AccountEmail?)? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeConfigPath = claudeConfigPath ?? "\(home)/.claude.json"
        self.logger = logger
        self.session = session
        self.keychainServiceName = keychainServiceName
        self.tokenProvider = tokenProvider
        self.accountProvider = accountProvider
    }

    // MARK: - UsageConnector

    nonisolated public func resolveActiveAccount() -> AccountEmail? {
        if let provider = accountProvider {
            return provider()
        }
        guard let data = FileManager.default.contents(atPath: claudeConfigPath) else {
            logger.log(.warning, "Cannot read \(claudeConfigPath)")
            return nil
        }
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let oauth = json?["oauthAccount"] as? [String: Any]
            return (oauth?["emailAddress"] as? String).map(AccountEmail.init(rawValue:))
        } catch {
            logger.log(.error, "Failed to parse \(claudeConfigPath): \(error)")
            return nil
        }
    }

    public func fetchUsages() async throws -> [VendorUsageEntry] {
        guard let earlyAccount = resolveActiveAccount() else {
            logger.log(.warning, "Cannot resolve active account — skipping fetch")
            return [errorEntry(account: "unknown", type: "account_unknown")]
        }
        logger.log(.info, "Fetching usages for account=\(earlyAccount)")

        let token: String
        do {
            if let provider = tokenProvider {
                token = try await provider()
            } else {
                token = try await fetchOAuthToken()
            }
        } catch {
            logger.log(.error, "Token retrieval failed: \(error)")
            return [errorEntry(account: earlyAccount, type: "token_error")]
        }

        // Re-read at HTTP dispatch time: if the user switched accounts while the token was being
        // fetched, the response must be attributed to whoever was active when the request went out.
        let account = resolveActiveAccount() ?? earlyAccount

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return [errorEntry(account: account, type: "api_error")]
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Required by the OAuth usage endpoint — beta flag must match the rollout date
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 5

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.error, "API request failed: \(error)")
            return [errorEntry(account: account, type: "api_error")]
        }

        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        logger.log(.info, "API response: HTTP \(httpCode)")

        if httpCode == 429 {
            let body = String(data: data, encoding: .utf8) ?? "<non-UTF8 body, \(data.count) bytes>"
            logger.log(.warning, "API rate-limited (HTTP 429): \(body)")
            return [errorEntry(account: account, type: "http_429", isActive: true, preservedMetrics: lastKnownMetrics)]
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            logger.log(.error, "API returned HTTP \(httpCode)")
            return [errorEntry(account: account, type: "http_\(httpCode)")]
        }

        logger.log(.debug, "API payload: \(Self.maskedPayload(data))")

        do {
            let usage = try parseAPIResponse(data)
            logger.log(.info, "Fetched successfully: session=\(usage.sessionPercent)% weekly=\(usage.weeklyPercent)%")
            // Window durations are not in the API response — they're fixed by Claude's rate-limit policy
            let metrics: [UsageMetric] = [
                .timeWindow(
                    name: "session",
                    resetAt: usage.sessionResetAt,
                    windowDuration: DurationMinutes(rawValue: 300),  // 5 hours
                    usagePercent: UsagePercent(rawValue: usage.sessionPercent)
                ),
                .timeWindow(
                    name: "weekly",
                    resetAt: usage.weeklyResetAt,
                    windowDuration: DurationMinutes(rawValue: 10080),  // 7 days
                    usagePercent: UsagePercent(rawValue: usage.weeklyPercent)
                ),
            ]
            lastKnownMetrics = metrics
            return [VendorUsageEntry(
                vendor: vendor,
                account: account,
                isActive: true,
                lastAcquiredOn: ISODate(date: Date()),
                lastError: nil,
                metrics: metrics
            )]
        } catch {
            logger.log(.error, "Response parse failed: \(error)")
            return [errorEntry(account: account, type: "parse_error")]
        }
    }

    // MARK: - Token

    private func fetchOAuthToken() async throws -> String {
        let serviceName = keychainServiceName
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", serviceName, "-w"]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Keychain may prompt the user or hang if the login keychain is locked;
                // 10 s is long enough for a cached lookup, short enough to not stall the poller
                let timedOut = DispatchSemaphore(value: 0)
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(10)) {
                    guard process.isRunning else { return }
                    process.terminate()
                    timedOut.signal()
                }

                let raw = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                // Check the flag rather than terminationReason, which may not
                // reflect SIGTERM reliably if the process handles the signal
                if timedOut.wait(timeout: .now()) == .success {
                    continuation.resume(throwing: ConnectorError.keychainTimeout(serviceName: serviceName, timeoutSeconds: 10))
                    return
                }
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: ConnectorError.keychainAccessDenied(serviceName: serviceName, exitCode: process.terminationStatus))
                    return
                }
                guard let jsonString = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !jsonString.isEmpty else {
                    continuation.resume(throwing: ConnectorError.keychainEmpty(serviceName: serviceName))
                    return
                }

                guard let jsonData = jsonString.data(using: .utf8) else {
                    continuation.resume(throwing: ConnectorError.tokenParseError(rawValue: jsonString))
                    return
                }
                let parsedJSON: [String: Any]
                do {
                    parsedJSON = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] ?? [:]
                } catch {
                    continuation.resume(throwing: ConnectorError.tokenParseError(rawValue: jsonString))
                    return
                }
                guard let oauthDict = parsedJSON["claudeAiOauth"] as? [String: Any],
                      let token = oauthDict["accessToken"] as? String,
                      !token.isEmpty else {
                    continuation.resume(throwing: ConnectorError.tokenParseError(rawValue: jsonString))
                    return
                }

                continuation.resume(returning: token)
            }
        }
    }

    // MARK: - Response parsing

    private static let sensitiveKeyPatterns = ["token", "key", "secret", "password", "email", "credential"]

    private static func maskedPayload(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "<non-JSON, \(data.count) bytes>"
        }
        let masked = maskSensitiveFields(json)
        guard let out = try? JSONSerialization.data(withJSONObject: masked, options: [.sortedKeys]),
              let str = String(data: out, encoding: .utf8) else {
            return "<serialization failed>"
        }
        return str
    }

    private static func maskSensitiveFields(_ dict: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            let lower = key.lowercased()
            if sensitiveKeyPatterns.contains(where: { lower.contains($0) }) {
                result[key] = "***"
            } else if let nested = value as? [String: Any] {
                result[key] = maskSensitiveFields(nested)
            } else if let array = value as? [[String: Any]] {
                result[key] = array.map { maskSensitiveFields($0) }
            } else {
                result[key] = value
            }
        }
        return result
    }

    private struct ParsedUsage {
        let sessionPercent: Int
        let sessionResetAt: ISODate
        let weeklyPercent: Int
        let weeklyResetAt: ISODate
    }

    private func parseAPIResponse(_ data: Data) throws -> ParsedUsage {
        let jsonObject = try JSONSerialization.jsonObject(with: data)
        guard let json = jsonObject as? [String: Any] else {
            throw ConnectorError.unexpectedAPIFormat(receivedKeys: [])
        }
        guard let fiveHour = json["five_hour"] as? [String: Any],
              let sevenDay = json["seven_day"] as? [String: Any],
              let sessionUtil = fiveHour["utilization"] as? Double,
              let sessionReset = fiveHour["resets_at"] as? String,
              let weeklyUtil = sevenDay["utilization"] as? Double,
              let weeklyReset = sevenDay["resets_at"] as? String else {
            throw ConnectorError.unexpectedAPIFormat(receivedKeys: Array(json.keys))
        }
        return ParsedUsage(
            sessionPercent: Int(sessionUtil.rounded()),
            sessionResetAt: Self.normalizeISO8601(sessionReset),
            weeklyPercent: Int(weeklyUtil.rounded()),
            weeklyResetAt: Self.normalizeISO8601(weeklyReset)
        )
    }

    /// Strips sub-second precision from API-provided ISO8601 strings so downstream
    /// consumers can rely on the standard formatter (no fractional-seconds option needed).
    /// Returns the original string unchanged if it cannot be parsed.
    private static func normalizeISO8601(_ raw: String) -> ISODate {
        let fractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        let standard = ISO8601DateFormatter()
        if let date = fractional.date(from: raw) ?? standard.date(from: raw) {
            return ISODate(rawValue: standard.string(from: date))
        }
        return ISODate(rawValue: raw)
    }

    // MARK: - Helpers

    private func errorEntry(account: AccountEmail, type: String, isActive: Bool = false, preservedMetrics: [UsageMetric] = []) -> VendorUsageEntry {
        return VendorUsageEntry(
            vendor: vendor,
            account: account,
            isActive: isActive,
            lastAcquiredOn: nil,
            lastError: UsageError(timestamp: ISODate(date: Date()), type: type),
            metrics: preservedMetrics
        )
    }
}

public enum ConnectorError: Error, CustomStringConvertible {
    case keychainAccessDenied(serviceName: String, exitCode: Int32)
    case keychainEmpty(serviceName: String)
    case keychainTimeout(serviceName: String, timeoutSeconds: Int)
    case tokenParseError(rawValue: String)
    case unexpectedAPIFormat(receivedKeys: [String])

    public var description: String {
        switch self {
        case let .keychainAccessDenied(svc, code):
            "Keychain access denied for service '\(svc)' (exit \(code))"
        case let .keychainEmpty(svc):
            "Keychain item is empty for service '\(svc)'"
        case let .keychainTimeout(svc, secs):
            "Keychain access timed out after \(secs)s for service '\(svc)'"
        case let .tokenParseError(raw):
            "Failed to parse OAuth token — raw value preview: '\(raw.prefix(80))'"
        case let .unexpectedAPIFormat(keys):
            "API response does not match expected format — top-level keys: \(keys)"
        }
    }
}
