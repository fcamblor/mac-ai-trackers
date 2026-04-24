import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("CodexAuth")
struct CodexAuthTests {
    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-codex-auth-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeAuthJSON(_ json: String, in dir: String, filename: String = "auth.json") -> String {
        let path = "\(dir)/\(filename)"
        try! json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func makeAuth(codexHomePath: String) -> CodexAuth {
        let dir = NSTemporaryDirectory() + "ai-tracker-codex-auth-log-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        return CodexAuth(codexHomePath: codexHomePath, logger: logger)
    }

    // MARK: - File parsing

    @Test("loads credentials from CODEX_HOME/auth.json")
    func loadsFromCodexHome() async throws {
        let dir = makeTempDir()
        _ = writeAuthJSON(
            #"{"tokens":{"access_token":"tok-abc","account_id":"acct-001"},"last_refresh":"2026-04-20T10:00:00.000Z"}"#,
            in: dir
        )
        let auth = makeAuth(codexHomePath: dir)
        let credentials = try await auth.load()

        #expect(credentials.accessToken == "tok-abc")
        #expect(credentials.accountId == "acct-001")
        #expect(credentials.lastRefreshedAt != nil)
    }

    @Test("parses last_refresh ISO8601 date with fractional seconds")
    func parsesLastRefresh() async throws {
        let dir = makeTempDir()
        _ = writeAuthJSON(
            #"{"tokens":{"access_token":"tok","account_id":"acct-001"},"last_refresh":"2026-04-15T08:30:00.123Z"}"#,
            in: dir
        )
        let auth = makeAuth(codexHomePath: dir)
        let credentials = try await auth.load()

        #expect(credentials.lastRefreshedAt != nil)
        // Verify the date is roughly April 15, 2026
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day], from: credentials.lastRefreshedAt!)
        #expect(components.year == 2026)
        #expect(components.month == 4)
        #expect(components.day == 15)
    }

    @Test("lastRefreshedAt is nil when last_refresh field is absent")
    func lastRefreshAbsent() async throws {
        let dir = makeTempDir()
        _ = writeAuthJSON(
            #"{"tokens":{"access_token":"tok","account_id":"acct-001"}}"#,
            in: dir
        )
        let auth = makeAuth(codexHomePath: dir)
        let credentials = try await auth.load()

        #expect(credentials.lastRefreshedAt == nil)
    }

    @Test("throws parseFailed when JSON is malformed")
    func throwsParseFailedOnMalformedJSON() async throws {
        let dir = makeTempDir()
        _ = writeAuthJSON("not valid json {{{", in: dir)
        let auth = makeAuth(codexHomePath: dir)

        await #expect(throws: CodexAuthError.self) {
            try await auth.load()
        }
    }

    @Test("throws missingAccountId when tokens.account_id is absent")
    func throwsMissingAccountId() async throws {
        let dir = makeTempDir()
        _ = writeAuthJSON(
            #"{"tokens":{"access_token":"tok"}}"#,
            in: dir
        )
        let auth = makeAuth(codexHomePath: dir)

        do {
            _ = try await auth.load()
            Issue.record("Expected missingAccountId error, but load succeeded")
        } catch let error as CodexAuthError {
            if case .missingAccountId = error {
                // expected
            } else {
                Issue.record("Expected missingAccountId, got \(error)")
            }
        } catch {
            Issue.record("Expected CodexAuthError, got \(error)")
        }
    }

    @Test("throws parseFailed when access_token is empty")
    func throwsParseFailedOnEmptyAccessToken() async throws {
        let dir = makeTempDir()
        _ = writeAuthJSON(
            #"{"tokens":{"access_token":"","account_id":"acct-001"}}"#,
            in: dir
        )
        let auth = makeAuth(codexHomePath: dir)

        await #expect(throws: CodexAuthError.self) {
            try await auth.load()
        }
    }

    @Test("reads valid credentials when auth.json has extra unknown keys")
    func toleratesUnknownTopLevelKeys() async throws {
        let dir = makeTempDir()
        _ = writeAuthJSON(
            #"{"tokens":{"access_token":"tok","account_id":"acct-001"},"unknown_field":"ignored","version":2}"#,
            in: dir
        )
        let auth = makeAuth(codexHomePath: dir)
        let credentials = try await auth.load()

        #expect(credentials.accessToken == "tok")
        #expect(credentials.accountId == "acct-001")
    }
}
