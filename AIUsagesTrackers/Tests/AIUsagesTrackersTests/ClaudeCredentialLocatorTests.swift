import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("ClaudeCredentialLocator")
struct ClaudeCredentialLocatorTests {
    private struct MockProcessRunner: ProcessRunning {
        let result: ProcessExecutionResult

        func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult {
            result
        }
    }

    /// Dispatches keychain results by the account value passed via `-a <account>`,
    /// or to the `nil` key for unscoped lookups (no `-a` flag).
    private struct AccountDispatchMockRunner: ProcessRunning {
        let resultsByAccount: [String?: ProcessExecutionResult]

        func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult {
            let account: String?
            if let idx = arguments.firstIndex(of: "-a"), idx + 1 < arguments.count {
                account = arguments[idx + 1]
            } else {
                account = nil
            }
            return resultsByAccount[account]
                ?? ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false)
        }
    }

    private func makeTempLogger() -> FileLogger {
        let dir = NSTemporaryDirectory() + "ai-tracker-claude-locator-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
    }

    private func keychainResult(json: String) -> ProcessExecutionResult {
        ProcessExecutionResult(stdout: Data(json.utf8), terminationStatus: 0, timedOut: false)
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_715_000_000)
    private let fixedClock: @Sendable () -> Date = { Self.fixedNow }

    @Test("returns token when expiresAt is in the future")
    func validToken() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":\#(futureMillis)}}"#)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-abc")
    }

    @Test("throws tokenExpired when expiresAt is in the past")
    func expiredToken() async throws {
        let pastMillis = Int((Self.fixedNow.timeIntervalSince1970 - 10) * 1000)
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":\#(pastMillis)}}"#)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }

    @Test("throws tokenExpired within the skew window even if absolute expiry is in the near future")
    func expiringSoonTriggersSkew() async throws {
        // 30s in the future — under the 60s skew margin, so should be considered expired.
        let nearFutureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 30) * 1000)
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":\#(nearFutureMillis)}}"#)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }

    @Test("missing expiresAt skips local check and returns token")
    func missingExpiresAt() async throws {
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc"}}"#)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-abc")
    }

    @Test("expiresAt as numeric string is accepted")
    func expiresAtAsString() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":"\#(futureMillis)"}}"#)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-abc")
    }

    @Test("expiresAt as malformed value skips local check and returns token")
    func malformedExpiresAt() async throws {
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: keychainResult(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":"not-a-number"}}"#)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-abc")
    }

    @Test("non-zero security exit code surfaces keychainAccessDenied")
    func keychainDenied() async throws {
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }

    @Test("empty stdout surfaces keychainEmpty")
    func keychainEmpty() async throws {
        let locator = ClaudeCredentialLocator(
            processRunner: MockProcessRunner(result: ProcessExecutionResult(stdout: Data(), terminationStatus: 0, timedOut: false)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }

    // MARK: - Multiple keychain entries

    @Test("prefers username-scoped claudeAiOauth entry over mcpOAuth-only unscoped entry")
    func prefersUsernameAccountOverMcpOnlyEntry() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let usernameJSON = #"{"claudeAiOauth":{"accessToken":"tok-user","expiresAt":\#(futureMillis)}}"#
        let mcpOnlyJSON = #"{"mcpOAuth":{"plugin:vercel:vercel|abc":{"accessToken":"mcp-tok","expiresAt":0}}}"#
        let locator = ClaudeCredentialLocator(
            processRunner: AccountDispatchMockRunner(resultsByAccount: [
                NSUserName(): keychainResult(json: usernameJSON),
                nil: keychainResult(json: mcpOnlyJSON),
            ]),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-user")
    }

    @Test("falls back to unscoped entry when username-scoped lookup is absent")
    func fallsBackToUnscopedWhenUsernameEntryAbsent() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let oauthJSON = #"{"claudeAiOauth":{"accessToken":"tok-fallback","expiresAt":\#(futureMillis)}}"#
        let locator = ClaudeCredentialLocator(
            processRunner: AccountDispatchMockRunner(resultsByAccount: [
                // username-scoped entry absent (exit 44)
                nil: keychainResult(json: oauthJSON),
            ]),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-fallback")
    }

    @Test("picks non-expired entry when username entry is expired and unscoped entry is valid")
    func picksNonExpiredFromMultipleCandidates() async throws {
        let pastMillis = Int((Self.fixedNow.timeIntervalSince1970 - 3600) * 1000)
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let expiredJSON = #"{"claudeAiOauth":{"accessToken":"tok-expired","expiresAt":\#(pastMillis)}}"#
        let validJSON = #"{"claudeAiOauth":{"accessToken":"tok-valid","expiresAt":\#(futureMillis)}}"#
        let locator = ClaudeCredentialLocator(
            processRunner: AccountDispatchMockRunner(resultsByAccount: [
                NSUserName(): keychainResult(json: expiredJSON),
                nil: keychainResult(json: validJSON),
            ]),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-valid")
    }

    @Test("deduplicates identical tokens returned by both lookups")
    func deduplicatesIdenticalTokens() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let json = #"{"claudeAiOauth":{"accessToken":"tok-single","expiresAt":\#(futureMillis)}}"#
        let locator = ClaudeCredentialLocator(
            processRunner: AccountDispatchMockRunner(resultsByAccount: [
                NSUserName(): keychainResult(json: json),
                nil: keychainResult(json: json),
            ]),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-single")
    }
}
