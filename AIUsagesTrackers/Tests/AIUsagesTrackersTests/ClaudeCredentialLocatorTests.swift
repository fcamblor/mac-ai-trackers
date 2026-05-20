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

    private struct AccountAwareMockProcessRunner: ProcessRunning {
        let results: [String?: ProcessExecutionResult]

        func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult {
            let account: String?
            if let accountFlagIndex = arguments.firstIndex(of: "-a"),
               accountFlagIndex + 1 < arguments.count {
                account = arguments[accountFlagIndex + 1]
            } else {
                account = nil
            }
            return results[account] ?? ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false)
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
            keychainAccountCandidates: ["testuser", nil],
            processRunner: MockProcessRunner(result: ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }

    @Test("reads claudeAiOauth from username account before unscoped entry")
    func prefersUsernameAccount() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let usernameJSON = #"{"claudeAiOauth":{"accessToken":"tok-user","expiresAt":\#(futureMillis)}}"#
        let mcpOnlyJSON = #"{"mcpOAuth":{"plugin:vercel:vercel|abc":{"accessToken":"","expiresAt":0}}}"#
        let locator = ClaudeCredentialLocator(
            keychainAccountCandidates: ["livio", nil],
            processRunner: AccountAwareMockProcessRunner(results: [
                "livio": keychainResult(json: usernameJSON),
                nil: keychainResult(json: mcpOnlyJSON),
            ]),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-user")
    }

    @Test("falls back to unscoped lookup when username account is missing")
    func fallsBackToUnscopedAccount() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let oauthJSON = #"{"claudeAiOauth":{"accessToken":"tok-fallback","expiresAt":\#(futureMillis)}}"#
        let locator = ClaudeCredentialLocator(
            keychainAccountCandidates: ["livio", nil],
            processRunner: AccountAwareMockProcessRunner(results: [
                "livio": ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false),
                nil: keychainResult(json: oauthJSON),
            ]),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-fallback")
    }

    @Test("skips mcpOAuth-only unscoped entry when username account is missing")
    func skipsMcpOAuthOnlyEntry() async throws {
        let mcpOnlyJSON = #"{"mcpOAuth":{"plugin:vercel:vercel|abc":{"accessToken":"","expiresAt":0}}}"#
        let locator = ClaudeCredentialLocator(
            keychainAccountCandidates: ["livio", nil],
            processRunner: AccountAwareMockProcessRunner(results: [
                "livio": ProcessExecutionResult(stdout: Data(), terminationStatus: 44, timedOut: false),
                nil: keychainResult(json: mcpOnlyJSON),
            ]),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }

    @Test("empty stdout surfaces keychainAccessDenied after exhausting accounts")
    func keychainEmpty() async throws {
        let locator = ClaudeCredentialLocator(
            keychainAccountCandidates: ["testuser", nil],
            processRunner: MockProcessRunner(result: ProcessExecutionResult(stdout: Data(), terminationStatus: 0, timedOut: false)),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }
}
