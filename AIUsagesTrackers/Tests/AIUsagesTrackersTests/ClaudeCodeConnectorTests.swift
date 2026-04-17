import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - URL mocking

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Account resolution tests

@Suite("ClaudeCodeConnector — account resolution")
struct ClaudeCodeConnectorAccountTests {
    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-claude-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("resolves email from valid claude.json")
    func resolveValid() {
        let dir = makeTempDir()
        let configPath = "\(dir)/claude.json"
        let json = #"{"oauthAccount":{"emailAddress":"user@example.com","accountUuid":"abc"}}"#
        try! json.write(toFile: configPath, atomically: true, encoding: .utf8)

        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let connector = ClaudeCodeConnector(claudeConfigPath: configPath, logger: logger)
        #expect(connector.resolveActiveAccount() == "user@example.com")
    }

    @Test("returns nil when file is missing")
    func resolveMissing() {
        let logger = FileLogger(filePath: "/tmp/ai-tracker-test-\(UUID()).log", minLevel: .debug)
        let connector = ClaudeCodeConnector(claudeConfigPath: "/nonexistent/path", logger: logger)
        #expect(connector.resolveActiveAccount() == nil)
    }

    @Test("returns nil when JSON lacks oauthAccount")
    func resolveNoOauth() {
        let dir = makeTempDir()
        let configPath = "\(dir)/claude.json"
        try! "{}".write(toFile: configPath, atomically: true, encoding: .utf8)

        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let connector = ClaudeCodeConnector(claudeConfigPath: configPath, logger: logger)
        #expect(connector.resolveActiveAccount() == nil)
    }

    @Test("returns nil when JSON is malformed")
    func resolveMalformed() {
        let dir = makeTempDir()
        let configPath = "\(dir)/claude.json"
        try! "not json".write(toFile: configPath, atomically: true, encoding: .utf8)

        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let connector = ClaudeCodeConnector(claudeConfigPath: configPath, logger: logger)
        #expect(connector.resolveActiveAccount() == nil)
    }
}

// MARK: - fetchUsages tests

@Suite("ClaudeCodeConnector — fetchUsages", .serialized)
struct ClaudeCodeConnectorFetchTests {
    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-claude-fetch-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConnector(dir: String, tokenProvider: @escaping @Sendable () async throws -> String) -> ClaudeCodeConnector {
        let configPath = "\(dir)/claude.json"
        let json = #"{"oauthAccount":{"emailAddress":"user@example.com"}}"#
        try! json.write(toFile: configPath, atomically: true, encoding: .utf8)
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        return ClaudeCodeConnector(
            claudeConfigPath: configPath,
            logger: logger,
            session: mockSession(),
            tokenProvider: tokenProvider
        )
    }

    @Test("success path returns entry with two metrics")
    func successPath() async throws {
        let dir = makeTempDir()
        let apiJSON = """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00+00:00"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00+00:00"}}
        """
        MockURLProtocol.handler = { _ in
            let data = apiJSON.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].account == "user@example.com")
        #expect(entries[0].lastError == nil)
        #expect(entries[0].metrics.count == 2)
        // utilization is a Double from the API; connector rounds to nearest Int percent (42.0 → 42)
        if case .timeWindow(let name, _, _, let pct) = entries[0].metrics[0] {
            #expect(name == "session")
            #expect(pct == 42)
        } else {
            Issue.record("Expected timeWindow metric for session")
        }
        if case .timeWindow(let name, _, let duration, let pct) = entries[0].metrics[1] {
            #expect(name == "weekly")
            #expect(pct == 8)
            #expect(duration == 10080)
        } else {
            Issue.record("Expected timeWindow metric for weekly")
        }
    }

    @Test("token error returns error entry")
    func tokenError() async throws {
        let dir = makeTempDir()
        let connector = makeConnector(dir: dir) { throw ConnectorError.keychainAccessDenied(serviceName: "test", exitCode: 1) }
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "token_error")
        #expect(entries[0].metrics.isEmpty)
    }

    @Test("HTTP 401 returns error entry")
    func httpError() async throws {
        let dir = makeTempDir()
        MockURLProtocol.handler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "http_401")
    }

    @Test("HTTP 429 preserves previous metrics and sets rate-limit error")
    func rateLimited() async throws {
        let dir = makeTempDir()
        let connector = makeConnector(dir: dir) { "fake-token" }

        // First call succeeds — seeds lastKnownMetrics
        MockURLProtocol.handler = { _ in
            let data = """
            {"five_hour":{"utilization":0.5,"resets_at":"2025-01-01T00:00:00Z"},
             "seven_day":{"utilization":0.3,"resets_at":"2025-01-07T00:00:00Z"}}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
        let firstEntries = try await connector.fetchUsages()
        #expect(firstEntries[0].metrics.count == 2)

        // Second call returns 429 — metrics must be preserved
        MockURLProtocol.handler = { _ in
            let body = #"{"error":"rate limited"}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }
        let rateLimitedEntries = try await connector.fetchUsages()

        #expect(rateLimitedEntries.count == 1)
        #expect(rateLimitedEntries[0].lastError?.type == "http_429")
        #expect(rateLimitedEntries[0].metrics.count == 2)
        #expect(rateLimitedEntries[0].metrics == firstEntries[0].metrics)
    }

    @Test("malformed API response returns parse error entry")
    func parseError() async throws {
        let dir = makeTempDir()
        MockURLProtocol.handler = { _ in
            let data = "{}".data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "parse_error")
    }

    @Test("nil account returns account_unknown error entry")
    func unknownAccount() async throws {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        // No claude.json → resolveActiveAccount returns nil
        let connector = ClaudeCodeConnector(
            claudeConfigPath: "\(dir)/missing.json",
            logger: logger,
            session: mockSession(),
            tokenProvider: { "fake-token" }
        )
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "account_unknown")
    }
}
