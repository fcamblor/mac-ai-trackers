import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("ClaudeCredentialLocator")
struct ClaudeCredentialLocatorTests {

    private func makeTempLogger() -> FileLogger {
        let dir = NSTemporaryDirectory() + "ai-tracker-claude-locator-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
    }

    private func singleEntry(json: String) -> MockKeychainQuery {
        MockKeychainQuery(passwordsByService: [
            ClaudeCredentialLocator.defaultKeychainService: [Data(json.utf8)],
        ])
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_715_000_000)
    private let fixedClock: @Sendable () -> Date = { Self.fixedNow }

    @Test("returns token when expiresAt is in the future")
    func validToken() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let locator = ClaudeCredentialLocator(
            keychainQuerying: singleEntry(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":\#(futureMillis)}}"#),
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
            keychainQuerying: singleEntry(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":\#(pastMillis)}}"#),
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
            keychainQuerying: singleEntry(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":\#(nearFutureMillis)}}"#),
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
            keychainQuerying: singleEntry(json: #"{"claudeAiOauth":{"accessToken":"tok-abc"}}"#),
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
            keychainQuerying: singleEntry(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":"\#(futureMillis)"}}"#),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-abc")
    }

    @Test("expiresAt as malformed value skips local check and returns token")
    func malformedExpiresAt() async throws {
        let locator = ClaudeCredentialLocator(
            keychainQuerying: singleEntry(json: #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":"not-a-number"}}"#),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-abc")
    }

    @Test("keychain access denied surfaces keychainAccessDenied")
    func keychainDenied() async throws {
        let locator = ClaudeCredentialLocator(
            keychainQuerying: MockKeychainQuery(
                passwordsByService: [:],
                errorsByService: [
                    ClaudeCredentialLocator.defaultKeychainService:
                        KeychainQueryError.accessDenied(service: ClaudeCredentialLocator.defaultKeychainService, status: 44),
                ]
            ),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }

    @Test("no keychain entries surfaces keychainEmpty")
    func keychainEmpty() async throws {
        let locator = ClaudeCredentialLocator(
            keychainQuerying: MockKeychainQuery(passwordsByService: [:]),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        await #expect(throws: ClaudeAuthError.self) {
            try await locator.locate()
        }
    }

    // MARK: - Multiple keychain entries

    @Test("skips mcpOAuth-only entry and picks the valid claudeAiOauth entry")
    func skipsMcpOnlyEntry() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let mcpOnlyJSON = #"{"mcpOAuth":{"plugin:vercel:vercel|abc":{"accessToken":"mcp-tok","expiresAt":0}}}"#
        let validJSON = #"{"claudeAiOauth":{"accessToken":"tok-user","expiresAt":\#(futureMillis)}}"#
        let locator = ClaudeCredentialLocator(
            keychainQuerying: MockKeychainQuery(passwordsByService: [
                ClaudeCredentialLocator.defaultKeychainService: [
                    Data(mcpOnlyJSON.utf8),
                    Data(validJSON.utf8),
                ],
            ]),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-user")
    }

    @Test("picks non-expired entry when first candidate is expired")
    func picksNonExpiredFromMultipleCandidates() async throws {
        let pastMillis = Int((Self.fixedNow.timeIntervalSince1970 - 3600) * 1000)
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let expiredJSON = #"{"claudeAiOauth":{"accessToken":"tok-expired","expiresAt":\#(pastMillis)}}"#
        let validJSON = #"{"claudeAiOauth":{"accessToken":"tok-valid","expiresAt":\#(futureMillis)}}"#
        let locator = ClaudeCredentialLocator(
            keychainQuerying: MockKeychainQuery(passwordsByService: [
                ClaudeCredentialLocator.defaultKeychainService: [
                    Data(expiredJSON.utf8),
                    Data(validJSON.utf8),
                ],
            ]),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-valid")
    }

    @Test("prefers non-expired entry with known expiry over unknown expiry")
    func prefersKnownNonExpiredCandidate() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let unknownExpiryJSON = #"{"claudeAiOauth":{"accessToken":"tok-unknown"}}"#
        let validJSON = #"{"claudeAiOauth":{"accessToken":"tok-valid","expiresAt":\#(futureMillis)}}"#
        let locator = ClaudeCredentialLocator(
            keychainQuerying: MockKeychainQuery(passwordsByService: [
                ClaudeCredentialLocator.defaultKeychainService: [
                    Data(unknownExpiryJSON.utf8),
                    Data(validJSON.utf8),
                ],
            ]),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-valid")
    }

    @Test("deduplicates entries with identical tokens")
    func deduplicatesIdenticalTokens() async throws {
        let futureMillis = Int((Self.fixedNow.timeIntervalSince1970 + 3600) * 1000)
        let json = #"{"claudeAiOauth":{"accessToken":"tok-single","expiresAt":\#(futureMillis)}}"#
        let locator = ClaudeCredentialLocator(
            keychainQuerying: MockKeychainQuery(passwordsByService: [
                ClaudeCredentialLocator.defaultKeychainService: [
                    Data(json.utf8),
                    Data(json.utf8),
                ],
            ]),
            logger: makeTempLogger(),
            clock: fixedClock
        )

        let creds = try await locator.locate()
        #expect(creds.accessToken == "tok-single")
    }
}
