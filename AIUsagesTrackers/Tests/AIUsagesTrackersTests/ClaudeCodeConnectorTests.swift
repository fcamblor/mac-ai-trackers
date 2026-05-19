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
            #expect(name == "5h sessions (all models)")
            #expect(pct == 42)
        } else {
            Issue.record("Expected timeWindow metric for session")
        }
        if case .timeWindow(let name, _, let duration, let pct) = entries[0].metrics[1] {
            #expect(name == "Weekly (all models)")
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

    @Test("HTTP 401 surfaces token_expired and preserves last-known metrics")
    func httpError() async throws {
        let dir = makeTempDir()
        let connector = makeConnector(dir: dir) { "fake-token" }

        // Seed lastKnownMetrics with a successful fetch — token expiry doesn't
        // invalidate what was already measured; metrics whose window has not
        // yet rolled stay accurate until their resetAt naturally lapses.
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"}}
        """)
        let firstEntries = try await connector.fetchUsages()
        #expect(firstEntries[0].metrics.count == 2)

        MockURLProtocol.handler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "token_expired")
        #expect(entries[0].isActive == true)
        #expect(entries[0].metrics == firstEntries[0].metrics)
    }

    @Test("HTTP 429 following a 401 keeps surfacing token_expired (cascade)")
    func authFailureSurvivesCascade() async throws {
        let dir = makeTempDir()
        let connector = makeConnector(dir: dir) { "fake-token" }

        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"}}
        """)
        let seedEntries = try await connector.fetchUsages()
        #expect(seedEntries[0].metrics.count == 2)

        // First trip — Anthropic returns 401.
        MockURLProtocol.handler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        let after401 = try await connector.fetchUsages()
        #expect(after401[0].lastError?.type == "token_expired")

        // Subsequent 429 — must NOT be reported as plain rate-limit. The auth
        // failure stays the actionable diagnostic.
        MockURLProtocol.handler = { _ in
            let body = #"{"error":"rate limited"}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }
        let after429 = try await connector.fetchUsages()
        #expect(after429[0].lastError?.type == "token_expired")
        #expect(after429[0].metrics == seedEntries[0].metrics)
    }

    @Test("HTTP 200 clears the auth-failure flag so later 429s are genuine rate-limits again")
    func authFailureFlagClearedOn200() async throws {
        let dir = makeTempDir()
        let connector = makeConnector(dir: dir) { "fake-token" }

        // Trigger a 401 to arm the sticky flag.
        MockURLProtocol.handler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        _ = try await connector.fetchUsages()

        // Healthy round-trip — must disarm the flag.
        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"}}
        """)
        _ = try await connector.fetchUsages()

        // A 429 now must be reported as a genuine rate-limit, not token_expired.
        MockURLProtocol.handler = { _ in
            let body = #"{"error":"rate limited"}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }
        let after429 = try await connector.fetchUsages()
        #expect(after429[0].lastError?.type == "http_429")
    }

    @Test("locator tokenExpired error surfaces token_expired and preserves metrics")
    func locatorTokenExpired() async throws {
        let dir = makeTempDir()
        let connector = makeConnector(dir: dir) { "fake-token" }

        mockHTTP200(json: """
        {"five_hour":{"utilization":42,"resets_at":"2026-04-17T15:00:00Z"},
         "seven_day":{"utilization":8,"resets_at":"2026-04-23T21:00:00Z"}}
        """)
        let seedEntries = try await connector.fetchUsages()

        // Replace tokenProvider on the SAME connector by reaching into the same
        // path with a new connector that shares the actor-private cache via the
        // same instance is not possible — instead we keep using the seeded
        // connector but mock the HTTP layer to behave as if the token had just
        // expired in transit (locator path is exercised separately in
        // ClaudeCredentialLocatorTests).
        //
        // Here we cover the connector-side mapping by routing through a fresh
        // connector that throws tokenExpired immediately. Metrics start empty
        // (no seed) so we verify the no-data shape; the seeded case is covered
        // by the 401 test above.
        let configPath = "\(dir)/claude.json"
        let logger = FileLogger(filePath: "\(dir)/test-expired.log", minLevel: .debug)
        let expiredAt = Date(timeIntervalSinceNow: -3600)
        let expiredConnector = ClaudeCodeConnector(
            claudeConfigPath: configPath,
            logger: logger,
            session: mockSession(),
            tokenProvider: { throw ClaudeAuthError.tokenExpired(serviceName: "Claude Code-credentials", expiredAt: expiredAt) }
        )
        let entries = try await expiredConnector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "token_expired")
        #expect(entries[0].isActive == true)
        // Fresh connector has no seeded metrics — preserve [] is still preserve.
        #expect(entries[0].metrics.isEmpty)
        _ = seedEntries
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

    @Test("five_hour with null resets_at emits metric with nil resetAt — not silently dropped")
    func fiveHourNullResetsAtEmitsMetricWithoutDate() async throws {
        let dir = makeTempDir()
        // Payload observed after a fresh account switch: no active 5h session yet,
        // `five_hour.resets_at` is null. Must not escalate to parse_error and must
        // still emit the metric so the UI can show "???".
        mockHTTP200(json: """
        {"five_hour":{"utilization":0,"resets_at":null},
         "seven_day":{"utilization":38,"resets_at":"2026-04-23T19:00:00+00:00"},
         "omelette_promotional":null,"iguana_necktie":null}
        """)
        let connector = makeConnector(dir: dir) { "fake-token" }
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError == nil)
        #expect(entries[0].isActive == true)
        #expect(entries[0].metrics.count == 2)
        if case .timeWindow(let name, let resetAt, _, let pct) = entries[0].metrics[0] {
            #expect(name == "5h sessions (all models)")
            #expect(resetAt == nil)
            #expect(pct.rawValue == 0)
        } else {
            Issue.record("Expected first metric to be a timeWindow for 5h sessions")
        }
        if case .timeWindow(_, _, _, let pct) = entries[0].metrics[1] {
            #expect(pct.rawValue == 38)
        } else {
            Issue.record("Expected second metric to be the weekly timeWindow")
        }
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
            #expect(sessionResetAt?.date != nil)
            #expect(sessionResetAt.map { !$0.rawValue.contains(".") } ?? false)
        } else {
            Issue.record("Expected timeWindow metric for session")
        }
        if case .timeWindow(_, let weeklyResetAt, _, _) = entries[0].metrics[1] {
            #expect(weeklyResetAt?.date != nil)
            #expect(weeklyResetAt.map { !$0.rawValue.contains(".") } ?? false)
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
    ) -> (name: String, resetAt: ISODate?, duration: DurationMinutes, pct: UsagePercent)? {
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

        if let session = requireTimeWindowMetric(named: "5h sessions (all models)", in: entries[0].metrics) {
            #expect(session.pct == 42)
        }
        if let weekly = requireTimeWindowMetric(named: "Weekly (all models)", in: entries[0].metrics) {
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
        if let session = requireTimeWindowMetric(named: "5h sessions (all models)", in: entries[0].metrics) {
            #expect(session.pct == 42)
        }
        if let weekly = requireTimeWindowMetric(named: "Weekly (all models)", in: entries[0].metrics) {
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
        if let session = requireTimeWindowMetric(named: "5h sessions (all models)", in: entries[0].metrics) {
            #expect(session.pct == 42)
        }
        if let weekly = requireTimeWindowMetric(named: "Weekly (all models)", in: entries[0].metrics) {
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
        if let session = requireTimeWindowMetric(named: "5h sessions (all models)", in: entries[0].metrics) {
            #expect(session.pct == 42)
        }
        if let weekly = requireTimeWindowMetric(named: "Weekly (all models)", in: entries[0].metrics) {
            #expect(weekly.pct == 8)
        }
    }

    @Test("seven_day_sonnet with null resets_at emits metric with nil resetAt — not silently dropped")
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
        #expect(entries[0].metrics.count == 4)
        if let sonnet = requireTimeWindowMetric(named: "Weekly Sonnet", in: entries[0].metrics) {
            #expect(sonnet.resetAt == nil)
            #expect(sonnet.pct.rawValue == 15)
        }
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
            #expect(sonnet.resetAt?.date != nil)
            #expect(sonnet.resetAt.map { !$0.rawValue.contains(".") } ?? false)
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

    // MARK: - Window preservation guard tests
    //
    // These tests live in this same .serialized suite (not a sibling suite)
    // because they share `MockURLProtocol.handler` static state with the rest
    // of the file. Swift Testing's .serialized trait orders tests within ONE
    // suite — siblings would still run in parallel and stomp the handler.
    //
    // Their semantic invariant: token validity and data validity are
    // independent. A 5h session at 42% with reset in 2h is still 42%
    // whether our bearer is alive or dead. The assertions are per-field
    // (name, percent, resetAt, duration) so a regression that drops or
    // mutates a single window surfaces exactly which field went wrong.

    private struct ExpectedMetric {
        let name: String
        let percent: Int
        let resetAt: String?
        let duration: Int
    }

    /// Future-dated payload: every window resets well past test execution time
    /// so any "we wiped it because resetAt looks expired" code path would be
    /// wrong by construction.
    private static let futureSeedJSON = """
    {"five_hour":{"utilization":42,"resets_at":"2099-12-31T15:00:00Z"},
     "seven_day":{"utilization":8,"resets_at":"2099-12-31T21:00:00Z"},
     "seven_day_sonnet":{"utilization":15,"resets_at":"2099-12-31T21:00:00Z"},
     "seven_day_opus":{"utilization":3,"resets_at":"2099-12-31T21:00:00Z"}}
    """

    private static let expectedFutureSeed: [ExpectedMetric] = [
        ExpectedMetric(name: "5h sessions (all models)", percent: 42, resetAt: "2099-12-31T15:00:00Z", duration: 300),
        ExpectedMetric(name: "Weekly (all models)", percent: 8, resetAt: "2099-12-31T21:00:00Z", duration: 10080),
        ExpectedMetric(name: "Weekly Sonnet", percent: 15, resetAt: "2099-12-31T21:00:00Z", duration: 10080),
        ExpectedMetric(name: "Weekly Opus", percent: 3, resetAt: "2099-12-31T21:00:00Z", duration: 10080),
    ]

    private func mockHTTP(status: Int, body: String) {
        MockURLProtocol.errorToThrow = nil
        MockURLProtocol.handler = { _ in
            let data = body.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
    }

    private func assertPreserved(
        _ metrics: [UsageMetric],
        against expected: [ExpectedMetric],
        context: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(metrics.count == expected.count, "\(context): expected \(expected.count) metrics, got \(metrics.count)", sourceLocation: sourceLocation)
        for expectedMetric in expected {
            let found = metrics.first(where: {
                if case .timeWindow(let name, _, _, _) = $0 { return name == expectedMetric.name }
                return false
            })
            guard let metric = found else {
                Issue.record("\(context): metric '\(expectedMetric.name)' missing — token expiry must not delete non-expired windows", sourceLocation: sourceLocation)
                continue
            }
            guard case .timeWindow(let name, let resetAt, let duration, let pct) = metric else {
                Issue.record("\(context): metric '\(expectedMetric.name)' has wrong kind", sourceLocation: sourceLocation)
                continue
            }
            #expect(name == expectedMetric.name, "\(context): name drifted on '\(expectedMetric.name)'", sourceLocation: sourceLocation)
            #expect(pct.rawValue == expectedMetric.percent, "\(context): percent for '\(expectedMetric.name)' changed (expected \(expectedMetric.percent), got \(pct.rawValue))", sourceLocation: sourceLocation)
            #expect(resetAt?.rawValue == expectedMetric.resetAt, "\(context): resetAt for '\(expectedMetric.name)' changed", sourceLocation: sourceLocation)
            #expect(duration.rawValue == expectedMetric.duration, "\(context): duration for '\(expectedMetric.name)' changed", sourceLocation: sourceLocation)
        }
    }

    @Test("guard: HTTP 401 must preserve every non-expired window — per-field assertion")
    func guardHttp401PreservesEveryWindow() async throws {
        let dir = makeTempDir()
        let connector = makeConnector(dir: dir) { "fake-token" }

        mockHTTP(status: 200, body: Self.futureSeedJSON)
        let seed = try await connector.fetchUsages()
        assertPreserved(seed[0].metrics, against: Self.expectedFutureSeed, context: "seed/200")

        mockHTTP(status: 401, body: "")
        let after401 = try await connector.fetchUsages()
        #expect(after401[0].lastError?.type == "token_expired")
        assertPreserved(after401[0].metrics, against: Self.expectedFutureSeed, context: "after 401")
    }

    @Test("guard: local tokenExpired (locator) must preserve every non-expired window")
    func guardLocatorTokenExpiredPreservesEveryWindow() async throws {
        let dir = makeTempDir()

        // Use one connector instance throughout so lastKnownMetrics is shared:
        // tokenProvider is swapped between seeding and the expiry phase by
        // toggling a mutable holder. The Box keeps it Sendable-safe.
        final class TokenBox: @unchecked Sendable {
            var current: () throws -> String = { "fake-token" }
        }
        let box = TokenBox()
        let configPath = "\(dir)/claude.json"
        let json = #"{"oauthAccount":{"emailAddress":"user@example.com"}}"#
        try json.write(toFile: configPath, atomically: true, encoding: .utf8)
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let connector = ClaudeCodeConnector(
            claudeConfigPath: configPath,
            logger: logger,
            session: mockSession(),
            tokenProvider: { try box.current() }
        )

        mockHTTP(status: 200, body: Self.futureSeedJSON)
        let seed = try await connector.fetchUsages()
        assertPreserved(seed[0].metrics, against: Self.expectedFutureSeed, context: "seed/200")

        // Flip the token provider to simulate the locator's pre-check firing.
        box.current = { throw ClaudeAuthError.tokenExpired(serviceName: "Claude Code-credentials", expiredAt: Date(timeIntervalSinceNow: -10)) }
        let afterLocalExpiry = try await connector.fetchUsages()
        #expect(afterLocalExpiry[0].lastError?.type == "token_expired")
        assertPreserved(afterLocalExpiry[0].metrics, against: Self.expectedFutureSeed, context: "after locator tokenExpired")
    }

    @Test("guard: 401 → 429 → 429 cascade must not erode metrics across iterations")
    func guardCascadeDoesNotErodeMetrics() async throws {
        let dir = makeTempDir()
        let connector = makeConnector(dir: dir) { "fake-token" }

        mockHTTP(status: 200, body: Self.futureSeedJSON)
        _ = try await connector.fetchUsages()

        mockHTTP(status: 401, body: "")
        let step1 = try await connector.fetchUsages()
        assertPreserved(step1[0].metrics, against: Self.expectedFutureSeed, context: "step1: 401")

        mockHTTP(status: 429, body: #"{"error":"rate limited"}"#)
        let step2 = try await connector.fetchUsages()
        #expect(step2[0].lastError?.type == "token_expired", "429 after 401 must keep the auth diagnostic")
        assertPreserved(step2[0].metrics, against: Self.expectedFutureSeed, context: "step2: 429 (cascade)")

        let step3 = try await connector.fetchUsages()
        assertPreserved(step3[0].metrics, against: Self.expectedFutureSeed, context: "step3: 429 again")

        let step4 = try await connector.fetchUsages()
        assertPreserved(step4[0].metrics, against: Self.expectedFutureSeed, context: "step4: 429 again")
    }

    @Test("guard: token_expired entry must mark isActive: true, with lastAcquiredOn unset")
    func guardTokenExpiredEntryShape() async throws {
        let dir = makeTempDir()
        let connector = makeConnector(dir: dir) { "fake-token" }

        mockHTTP(status: 200, body: Self.futureSeedJSON)
        _ = try await connector.fetchUsages()

        mockHTTP(status: 401, body: "")
        let entries = try await connector.fetchUsages()

        // isActive: true keeps the row visible in the popover so the user sees
        // the token_expired diagnostic — without it the entry would disappear
        // and the bug would look like "the app forgot my account".
        #expect(entries[0].isActive == true, "token_expired entry must keep the account visible in the UI")
        // lastAcquiredOn is intentionally nil on error entries — the previous
        // value lives in lastKnownMetrics' resetAt, not in this field.
        #expect(entries[0].lastAcquiredOn == nil)
    }

    @Test("guard: a successful 200 after token_expired must refresh metrics with the new payload")
    func guardRecoveryReplacesMetrics() async throws {
        let dir = makeTempDir()
        let connector = makeConnector(dir: dir) { "fake-token" }

        mockHTTP(status: 200, body: Self.futureSeedJSON)
        _ = try await connector.fetchUsages()

        mockHTTP(status: 401, body: "")
        _ = try await connector.fetchUsages()

        // User re-runs `claude` CLI → fresh token → 200 with NEW numbers.
        mockHTTP(status: 200, body: """
        {"five_hour":{"utilization":50,"resets_at":"2099-12-31T16:00:00Z"},
         "seven_day":{"utilization":12,"resets_at":"2099-12-31T22:00:00Z"}}
        """)
        let recovered = try await connector.fetchUsages()
        #expect(recovered[0].lastError == nil)
        #expect(recovered[0].metrics.count == 2)
        if case .timeWindow(_, _, _, let pct) = recovered[0].metrics[0] {
            #expect(pct.rawValue == 50, "recovery must replace the seeded 42% with the fresh 50%")
        }

        // A subsequent 429 must now be reported as a real rate-limit — the
        // sticky auth-failure flag was cleared by the 200.
        mockHTTP(status: 429, body: #"{"error":"rate limited"}"#)
        let afterRecovery429 = try await connector.fetchUsages()
        #expect(afterRecovery429[0].lastError?.type == "http_429", "200 must disarm the auth-failure flag")
    }
}
