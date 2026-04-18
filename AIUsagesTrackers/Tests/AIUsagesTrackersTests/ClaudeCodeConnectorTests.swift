import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - URL mocking

// swiftlint:disable:next w4_unchecked_sendable — URLProtocol subclass; all mutable static state accessed only from the serialized test suite (@Suite(.serialized))
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?
    // Captured by startLoading before handler runs; safe because the suite is .serialized
    nonisolated(unsafe) static var capturedRequest: URLRequest?
    // When set, startLoading fails with this error instead of invoking handler
    nonisolated(unsafe) static var errorToThrow: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        if let error = Self.errorToThrow {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
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
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00+00:00"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00+00:00"}}
        """)
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
        mockHTTP200(json: """
        {"five_hour":{"utilization":0.5,"resets_at":"2025-01-01T00:00:00Z"},
         "seven_day":{"utilization":0.3,"resets_at":"2025-01-07T00:00:00Z"}}
        """)
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

    @Test("resets_at with fractional seconds is normalized to whole-second ISO8601")
    func resetsAtFractionalSecondsNormalized() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {"five_hour":{"utilization":5,"resets_at":"2026-04-23T19:00:00.107277+00:00"},
         "seven_day":{"utilization":17,"resets_at":"2026-04-24T00:00:00.999999+00:00"}}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        if case .timeWindow(_, let sessionResetAt, _, _) = entries[0].metrics[0] {
            // Fractional seconds must be stripped; standard ISO8601DateFormatter must parse the result
            #expect(sessionResetAt.date != nil)
            #expect(!sessionResetAt.rawValue.contains("."))
        } else {
            Issue.record("Expected timeWindow metric for session")
        }
        if case .timeWindow(_, let weeklyResetAt, _, _) = entries[0].metrics[1] {
            #expect(weeklyResetAt.date != nil)
            #expect(!weeklyResetAt.rawValue.contains("."))
        } else {
            Issue.record("Expected timeWindow metric for weekly")
        }
    }

    @Test("URLError returns api_error entry")
    func urlErrorReturnsApiError() async throws {
        let dir = makeTempDir()
        MockURLProtocol.capturedRequest = nil
        MockURLProtocol.errorToThrow = URLError(.notConnectedToInternet)
        MockURLProtocol.handler = nil
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()
        MockURLProtocol.errorToThrow = nil

        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "api_error")
        #expect(entries[0].metrics.isEmpty)
    }

    @Test("success path sends correct Authorization and anthropic-beta headers")
    func successPathHeaders() async throws {
        let dir = makeTempDir()
        MockURLProtocol.capturedRequest = nil
        MockURLProtocol.errorToThrow = nil
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00+00:00"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00+00:00"}}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        _ = try await connector.fetchUsages()

        #expect(MockURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
        #expect(MockURLProtocol.capturedRequest?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
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

    // MARK: - Per-model weekly metrics

    private static let weeklyWindowMinutes = DurationMinutes(rawValue: 10080)

    /// Finds the first timeWindow metric matching the given name, or fails the test.
    private func requireTimeWindowMetric(
        named name: String,
        in metrics: [UsageMetric],
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> (name: String, resetAt: ISODate, duration: DurationMinutes, pct: UsagePercent)? {
        guard let metric = metrics.first(where: {
            if case .timeWindow(let n, _, _, _) = $0 { return n == name }
            return false
        }) else {
            Issue.record("Expected timeWindow metric named '\(name)'", sourceLocation: sourceLocation)
            return nil
        }
        if case .timeWindow(let n, let r, let d, let p) = metric {
            return (name: n, resetAt: r, duration: d, pct: p)
        }
        return nil
    }

    private func mockHTTP200(json: String) {
        MockURLProtocol.errorToThrow = nil
        MockURLProtocol.handler = { _ in
            let data = json.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
    }

    @Test("both seven_day_sonnet and seven_day_opus present emits 4 metrics")
    func bothModelKeysPresent() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_sonnet":{"utilization":15,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_opus":{"utilization":3,"resets_at":"2026-04-24T12:00:00Z"}}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError == nil)
        #expect(entries[0].metrics.count == 4)

        if let session = requireTimeWindowMetric(named: "session", in: entries[0].metrics) {
            #expect(session.pct == 42)
        }
        if let weekly = requireTimeWindowMetric(named: "weekly", in: entries[0].metrics) {
            #expect(weekly.pct == 8)
        }
        if let sonnet = requireTimeWindowMetric(named: "Weekly Sonnet", in: entries[0].metrics) {
            #expect(sonnet.pct == 15)
            #expect(sonnet.resetAt == "2026-04-23T21:00:00Z")
            #expect(sonnet.duration == Self.weeklyWindowMinutes)
        }
        if let opus = requireTimeWindowMetric(named: "Weekly Opus", in: entries[0].metrics) {
            #expect(opus.pct == 3)
            #expect(opus.resetAt == "2026-04-24T12:00:00Z")
            #expect(opus.duration == Self.weeklyWindowMinutes)
        }
    }

    @Test("only seven_day_sonnet present emits 3 metrics")
    func onlySonnetPresent() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_sonnet":{"utilization":15,"resets_at":"2026-04-23T21:00:00Z"}}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries[0].metrics.count == 3)
        if let session = requireTimeWindowMetric(named: "session", in: entries[0].metrics) {
            #expect(session.pct == 42)
        }
        if let weekly = requireTimeWindowMetric(named: "weekly", in: entries[0].metrics) {
            #expect(weekly.pct == 8)
        }
        if let sonnet = requireTimeWindowMetric(named: "Weekly Sonnet", in: entries[0].metrics) {
            #expect(sonnet.pct == 15)
        }
    }

    @Test("only seven_day_opus present emits 3 metrics")
    func onlyOpusPresent() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_opus":{"utilization":3,"resets_at":"2026-04-23T21:00:00Z"}}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries[0].metrics.count == 3)
        if let session = requireTimeWindowMetric(named: "session", in: entries[0].metrics) {
            #expect(session.pct == 42)
        }
        if let weekly = requireTimeWindowMetric(named: "weekly", in: entries[0].metrics) {
            #expect(weekly.pct == 8)
        }
        if let opus = requireTimeWindowMetric(named: "Weekly Opus", in: entries[0].metrics) {
            #expect(opus.pct == 3)
        }
    }

    @Test("no per-model keys emits only 2 metrics (session + weekly)")
    func bothModelKeysAbsent() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"}}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries[0].metrics.count == 2)
        if let session = requireTimeWindowMetric(named: "session", in: entries[0].metrics) {
            #expect(session.pct == 42)
        }
        if let weekly = requireTimeWindowMetric(named: "weekly", in: entries[0].metrics) {
            #expect(weekly.pct == 8)
        }
    }

    @Test("seven_day_sonnet with null resets_at is silently skipped")
    func sonnetNullResetsAt() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_sonnet":{"utilization":15,"resets_at":null},
         "seven_day_opus":{"utilization":3,"resets_at":"2026-04-23T21:00:00Z"}}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries[0].lastError == nil)
        #expect(entries[0].metrics.count == 3)
        _ = requireTimeWindowMetric(named: "Weekly Opus", in: entries[0].metrics)
    }

    @Test("HTTP 429 preserves all 4 per-model metrics from previous successful fetch")
    func perModelMetricsPreservedOn429() async throws {
        let dir = makeTempDir()
        let connector = makeConnector(dir: dir) { "fake-token" }

        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_sonnet":{"utilization":15,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_opus":{"utilization":3,"resets_at":"2026-04-23T21:00:00Z"}}
        """)
        let firstEntries = try await connector.fetchUsages()
        #expect(firstEntries[0].metrics.count == 4)

        MockURLProtocol.handler = { _ in
            let body = #"{"error":"rate limited"}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }
        let rateLimitedEntries = try await connector.fetchUsages()

        #expect(rateLimitedEntries[0].lastError?.type == "http_429")
        #expect(rateLimitedEntries[0].metrics.count == 4)
        #expect(rateLimitedEntries[0].metrics == firstEntries[0].metrics)
    }

    @Test("per-model block with missing utilization key is silently skipped")
    func modelBlockMissingUtilization() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_sonnet":{"resets_at":"2026-04-23T21:00:00Z"}}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries[0].lastError == nil)
        #expect(entries[0].metrics.count == 2)
    }

    @Test("per-model block with non-numeric utilization is silently skipped")
    func modelBlockNonNumericUtilization() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_opus":{"utilization":"not_a_number","resets_at":"2026-04-23T21:00:00Z"}}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries[0].lastError == nil)
        #expect(entries[0].metrics.count == 2)
    }

    @Test("per-model key that is not a dictionary is silently skipped")
    func modelBlockNotADict() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_sonnet":42,
         "seven_day_opus":null}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries[0].lastError == nil)
        #expect(entries[0].metrics.count == 2)
    }

    @Test("fractional utilization is rounded to nearest integer (15.6→16, 15.4→15)")
    func fractionalUtilizationRounding() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_sonnet":{"utilization":15.6,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_opus":{"utilization":15.4,"resets_at":"2026-04-23T21:00:00Z"}}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        if let sonnet = requireTimeWindowMetric(named: "Weekly Sonnet", in: entries[0].metrics) {
            #expect(sonnet.pct == 16)
        }
        if let opus = requireTimeWindowMetric(named: "Weekly Opus", in: entries[0].metrics) {
            #expect(opus.pct == 15)
        }
    }

    @Test("per-model resets_at with fractional seconds is normalized")
    func perModelFractionalSecondsNormalized() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"},
         "seven_day_sonnet":{"utilization":15,"resets_at":"2026-04-23T21:00:00.123456Z"}}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        if let sonnet = requireTimeWindowMetric(named: "Weekly Sonnet", in: entries[0].metrics) {
            #expect(sonnet.resetAt.date != nil)
            #expect(!sonnet.resetAt.rawValue.contains("."))
        }
    }

    @Test("debug log is emitted on HTTP 200 with masked payload")
    func debugLogOnSuccess() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"}}
        """)
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let configPath = "\(dir)/claude.json"
        try #"{"oauthAccount":{"emailAddress":"user@example.com"}}"#
            .write(toFile: configPath, atomically: true, encoding: .utf8)
        let connector = ClaudeCodeConnector(
            claudeConfigPath: configPath,
            logger: logger,
            session: mockSession(),
            tokenProvider: { "fake-token" }
        )
        _ = try await connector.fetchUsages()
        // Logger writes asynchronously on a serial queue — drain it before reading
        logger.waitForPendingWrites()

        let logContent = try String(contentsOfFile: "\(dir)/test.log", encoding: .utf8)
        #expect(logContent.contains("API payload:"))
    }
}
