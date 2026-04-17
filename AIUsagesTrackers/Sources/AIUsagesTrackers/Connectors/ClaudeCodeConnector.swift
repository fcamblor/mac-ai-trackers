import Foundation

public actor ClaudeCodeConnector: UsageConnector {
    nonisolated public let vendor = "claude"

    private let claudeConfigPath: String
    private let logger: FileLogger
    private let session: URLSession
    private let keychainServiceName: String
    private let tokenProvider: (@Sendable () async throws -> String)?

    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    public init(
        claudeConfigPath: String? = nil,
        logger: FileLogger = Loggers.claude,
        session: URLSession = .shared,
        keychainServiceName: String = "Claude Code-credentials",
        tokenProvider: (@Sendable () async throws -> String)? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.claudeConfigPath = claudeConfigPath ?? "\(home)/.claude.json"
        self.logger = logger
        self.session = session
        self.keychainServiceName = keychainServiceName
        self.tokenProvider = tokenProvider
    }

    // MARK: - UsageConnector

    nonisolated public func resolveActiveAccount() -> String? {
        guard let data = FileManager.default.contents(atPath: claudeConfigPath) else {
            logger.log(.warning, "Cannot read \(claudeConfigPath)")
            return nil
        }
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let oauth = json?["oauthAccount"] as? [String: Any]
            return oauth?["emailAddress"] as? String
        } catch {
            logger.log(.error, "Failed to parse \(claudeConfigPath): \(error)")
            return nil
        }
    }

    public func fetchUsages() async throws -> [VendorUsageEntry] {
        guard let account = resolveActiveAccount() else {
            logger.log(.warning, "Cannot resolve active account — skipping fetch")
            return [errorEntry(account: "unknown", type: "account_unknown")]
        }
        logger.log(.info, "Fetching usages for account=\(account)")

        let token: String
        do {
            if let provider = tokenProvider {
                token = try await provider()
            } else {
                token = try await fetchOAuthToken()
            }
        } catch {
            logger.log(.error, "Token retrieval failed: \(error)")
            return [errorEntry(account: account, type: "token_error")]
        }

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

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            logger.log(.error, "API returned HTTP \(code)")
            return [errorEntry(account: account, type: "http_\(code)")]
        }

        do {
            let usage = try parseAPIResponse(data)
            let now = Self.isoFormatter.string(from: Date())
            logger.log(.info, "Fetched successfully: session=\(usage.sessionPercent)% weekly=\(usage.weeklyPercent)%")
            return [VendorUsageEntry(
                vendor: vendor,
                account: account,
                isActive: true,
                lastAcquiredOn: now,
                lastError: nil,
                metrics: [
                    // Window durations are not in the API response — they're fixed by Claude's rate-limit policy
                    .timeWindow(
                        name: "session",
                        resetAt: usage.sessionResetAt,
                        windowDurationMinutes: 300,  // 5 hours
                        usagePercent: usage.sessionPercent
                    ),
                    .timeWindow(
                        name: "weekly",
                        resetAt: usage.weeklyResetAt,
                        windowDurationMinutes: 10080,  // 7 days
                        usagePercent: usage.weeklyPercent
                    ),
                ]
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
                    continuation.resume(throwing: ConnectorError.keychainTimeout)
                    return
                }
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: ConnectorError.keychainAccessDenied)
                    return
                }
                guard let jsonString = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !jsonString.isEmpty else {
                    continuation.resume(throwing: ConnectorError.keychainEmpty)
                    return
                }

                guard let jsonData = jsonString.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let oauthDict = json["claudeAiOauth"] as? [String: Any],
                      let token = oauthDict["accessToken"] as? String,
                      !token.isEmpty else {
                    continuation.resume(throwing: ConnectorError.tokenParseError)
                    return
                }

                continuation.resume(returning: token)
            }
        }
    }

    // MARK: - Response parsing

    private struct ParsedUsage {
        let sessionPercent: Int
        let sessionResetAt: String
        let weeklyPercent: Int
        let weeklyResetAt: String
    }

    private func parseAPIResponse(_ data: Data) throws -> ParsedUsage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fiveHour = json["five_hour"] as? [String: Any],
              let sevenDay = json["seven_day"] as? [String: Any],
              let sessionUtil = fiveHour["utilization"] as? Double,
              let sessionReset = fiveHour["resets_at"] as? String,
              let weeklyUtil = sevenDay["utilization"] as? Double,
              let weeklyReset = sevenDay["resets_at"] as? String else {
            throw ConnectorError.unexpectedAPIFormat
        }
        return ParsedUsage(
            sessionPercent: Int((sessionUtil * 100).rounded()),
            sessionResetAt: sessionReset,
            weeklyPercent: Int((weeklyUtil * 100).rounded()),
            weeklyResetAt: weeklyReset
        )
    }

    // MARK: - Helpers

    private func errorEntry(account: String, type: String) -> VendorUsageEntry {
        let now = Self.isoFormatter.string(from: Date())
        return VendorUsageEntry(
            vendor: vendor,
            account: account,
            isActive: true,
            lastAcquiredOn: nil,
            lastError: UsageError(timestamp: now, type: type),
            metrics: []
        )
    }
}

public enum ConnectorError: Error, CustomStringConvertible {
    case keychainAccessDenied
    case keychainEmpty
    case keychainTimeout
    case tokenParseError
    case unexpectedAPIFormat

    public var description: String {
        switch self {
        case .keychainAccessDenied: "Keychain access denied or item not found"
        case .keychainEmpty: "Keychain item is empty"
        case .keychainTimeout: "Keychain access timed out"
        case .tokenParseError: "Failed to parse OAuth token from keychain data"
        case .unexpectedAPIFormat: "API response does not match expected format"
        }
    }
}
