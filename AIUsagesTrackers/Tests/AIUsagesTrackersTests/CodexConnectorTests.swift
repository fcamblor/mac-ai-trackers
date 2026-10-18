import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - URL mocking

// swiftlint:disable:next w4_unchecked_sendable — URLProtocol subclass; all mutable static state accessed only from the serialized test suite
final class CodexMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?
    nonisolated(unsafe) static var capturedRequest: URLRequest?
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

// MARK: - Auth mock

private struct MockCodexAuth: CodexCredentialLocating {
    let credentials: CodexCredentials?
    let error: Error?

    func locate() async throws -> CodexCredentials {
        if let error { throw error }
        return credentials!
    }
}

private actor SequenceCodexAuth: CodexCredentialLocating {
    private var results: [Result<CodexCredentials, Error>]

    init(_ results: [Result<CodexCredentials, Error>]) {
        self.results = results
    }

    func locate() async throws -> CodexCredentials {
        guard !results.isEmpty else {
            fatalError("SequenceCodexAuth exhausted")
        }
        return try results.removeFirst().get()
    }
}

// MARK: - Helpers

private func makeTempDir() throws -> String {
    let dir = NSTemporaryDirectory() + "ai-tracker-codex-fetch-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CodexMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func validCredentials(
    accountEmail: AccountEmail? = nil,
    lastRefreshedAt: Date? = Date()
) -> CodexCredentials {
    CodexCredentials(
        accessToken: "fake-token",
        accountId: "acct-123",
        accountEmail: accountEmail,
        lastRefreshedAt: lastRefreshedAt
    )
}

private func makeConnector(dir: String, credentials: CodexCredentials? = nil, authError: Error? = nil) -> CodexConnector {
    let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
    let auth = MockCodexAuth(credentials: credentials ?? validCredentials(), error: authError)
    return CodexConnector(auth: auth, logger: logger, session: mockSession())
}

private func mockHTTP200(json: String, headers: [String: String] = [:]) {
    CodexMockURLProtocol.errorToThrow = nil
    CodexMockURLProtocol.handler = { _ in
        let data = json.data(using: .utf8)!
        let resp = HTTPURLResponse(
            url: URL(string: "https://chatgpt.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: headers
        )!
        return (data, resp)
    }
}

private func readLog(at path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

// MARK: - Suite

@Suite("CodexConnector — fetchUsages", .serialized)
struct CodexConnectorFetchTests {
    // MARK: - Happy path

    @Test("Plus plan: primary + secondary window returns 2 metrics with email from payload")
    func plusPlanHappyPath() async throws {
        let dir = try makeTempDir()
        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {
              "used_percent": 42.0,
              "reset_at": 1745000000,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 8.0,
              "reset_at": 1745500000,
              "limit_window_seconds": 604800
            }
          }
        }
        """)
        let connector = makeConnector(dir: dir)
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].vendor == .codex)
        #expect(entries[0].account == "user@openai.com")
        #expect(entries[0].isActive == true)
        #expect(entries[0].lastError == nil)
        #expect(entries[0].metrics.count == 2)

        if case .timeWindow(let name, let resetAt, let duration, let pct) = entries[0].metrics[0] {
            #expect(name == "Session (5h)")
            #expect(pct == 42)
            #expect(duration.rawValue == 300)   // 18000 / 60
            #expect(resetAt != nil)
        } else {
            Issue.record("Expected timeWindow for Session (5h)")
        }
        if case .timeWindow(let name, _, let duration, let pct) = entries[0].metrics[1] {
            #expect(name == "Weekly (7d)")
            #expect(pct == 8)
            #expect(duration.rawValue == 10080) // 604800 / 60
        } else {
            Issue.record("Expected timeWindow for Weekly (7d)")
        }
    }

    @Test("Pro plan with code review and credits emits additional metrics")
    func proPlanWithCodeReviewAndCredits() async throws {
        let dir = try makeTempDir()
        mockHTTP200(json: """
        {
          "email": "pro@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 15.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 5.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          },
          "code_review_rate_limit": {
            "primary_window": {"used_percent": 30.0, "reset_at": 1745200000, "limit_window_seconds": 604800}
          },
          "credits": {"balance": 750.0, "has_credits": true}
        }
        """)
        let connector = makeConnector(dir: dir)
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].metrics.count == 4)

        let names = entries[0].metrics.compactMap { metric -> String? in
            if case .timeWindow(let n, _, _, _) = metric { return n }
            if case .payAsYouGo(let n, _, _) = metric { return n }
            return nil
        }
        #expect(names.contains("Session (5h)"))
        #expect(names.contains("Weekly (7d)"))
        #expect(names.contains("Code Review (7d)"))
        #expect(names.contains("Credits balance"))

        let creditsMetric = entries[0].metrics.first {
            if case .payAsYouGo(let n, _, _) = $0 { return n == "Credits balance" }
            return false
        }
        if case .payAsYouGo(_, let amount, let currency) = creditsMetric {
            #expect(amount == 750.0)
            #expect(currency == "credits")
        } else {
            Issue.record("Expected payAsYouGo Credits balance metric")
        }
    }

    @Test("Spark plan with additional_rate_limits emits per-model metrics")
    func sparkPlanAdditionalRateLimits() async throws {
        let dir = try makeTempDir()
        mockHTTP200(json: """
        {
          "email": "spark@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 10.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 3.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          },
          "additional_rate_limits": [
            {
              "limit_name": "gpt-4.5",
              "rate_limit": {
                "primary_window": {"used_percent": 60.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
                "secondary_window": {"used_percent": 25.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
              }
            }
          ]
        }
        """)
        let connector = makeConnector(dir: dir)
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].metrics.count == 4)

        let names = entries[0].metrics.compactMap { metric -> String? in
            if case .timeWindow(let n, _, _, _) = metric { return n }
            return nil
        }
        #expect(names.contains("gpt-4.5 (5h)"))
        #expect(names.contains("gpt-4.5 Weekly (7d)"))
    }

    // MARK: - Error paths

    @Test("HTTP 401 returns token_expired entry without any preserved metrics")
    func http401ReturnsTokenExpired() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)

        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 50.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 20.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let firstEntries = try await connector.fetchUsages()
        #expect(firstEntries[0].account == "user@openai.com")

        CodexMockURLProtocol.handler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://chatgpt.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].account == "user@openai.com")
        #expect(entries[0].lastError?.type == "token_expired")
        #expect(entries[0].metrics.isEmpty)
    }

    @Test("HTTP 429 preserves previous metrics and sets http_429 error")
    func http429PreservesMetrics() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)

        // First successful fetch seeds lastKnownMetrics
        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 50.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 20.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let firstEntries = try await connector.fetchUsages()
        #expect(firstEntries[0].metrics.count == 2)

        // Second call returns 429 — metrics must be preserved
        CodexMockURLProtocol.handler = { _ in
            let body = #"{"error":"rate limited"}"#.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://chatgpt.com")!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }
        let rateLimitedEntries = try await connector.fetchUsages()

        #expect(rateLimitedEntries.count == 1)
        #expect(rateLimitedEntries[0].account == "user@openai.com")
        #expect(rateLimitedEntries[0].lastError?.type == "http_429")
        #expect(rateLimitedEntries[0].isActive == true)
        #expect(rateLimitedEntries[0].metrics.count == 2)
        #expect(rateLimitedEntries[0].metrics == firstEntries[0].metrics)
    }

    @Test("credentials load failure reuses cached email from a previous fetch")
    func credentialsLoadFailureReusesCachedEmail() async throws {
        let dir = try makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let auth = SequenceCodexAuth([
            .success(validCredentials()),
            .failure(CodexCredentialLocatorError.keychainEmpty),
        ])
        let connector = CodexConnector(auth: auth, logger: logger, session: mockSession())

        mockHTTP200(json: """
        {
          "email": "cached@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 2.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        _ = try await connector.fetchUsages()

        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].account == "cached@openai.com")
        #expect(entries[0].lastError?.type == "token_error")
    }

    @Test("old last_refresh still calls API and accepts successful response")
    func oldLastRefreshStillCallsAPIAndAcceptsSuccess() async throws {
        let dir = try makeTempDir()
        CodexMockURLProtocol.capturedRequest = nil
        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 1.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)

        let oldDate = Date(timeIntervalSinceNow: -(9 * 24 * 3600))  // 9 days ago
        let connector = makeConnector(dir: dir, credentials: CodexCredentials(
            accessToken: "old-token",
            accountId: "acct-123",
            accountEmail: "expired@openai.com",
            lastRefreshedAt: oldDate
        ))
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].account == "user@openai.com")
        #expect(entries[0].lastError == nil)
        #expect(entries[0].isActive == true)
        #expect(entries[0].metrics.count == 2)
        #expect(CodexMockURLProtocol.capturedRequest != nil)
    }

    @Test("fresh token (<8 days) is not treated as expired")
    func freshTokenIsNotExpired() async throws {
        let dir = try makeTempDir()
        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 1.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let freshDate = Date(timeIntervalSinceNow: -(3 * 24 * 3600))  // 3 days ago
        let connector = makeConnector(dir: dir, credentials: CodexCredentials(
            accessToken: "valid-token",
            accountId: "acct-123",
            lastRefreshedAt: freshDate
        ))
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError == nil)
    }

    @Test("malformed JSON payload returns parse_error entry, preserves isActive and metrics")
    func parseErrorOnMalformedJSON() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)

        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 2.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let firstEntries = try await connector.fetchUsages()

        CodexMockURLProtocol.handler = { _ in
            let data = "not-json".data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://chatgpt.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].account == "user@openai.com")
        #expect(entries[0].lastError?.type == "parse_error")
        #expect(entries[0].isActive == true)
        #expect(entries[0].metrics == firstEntries[0].metrics)
    }

    @Test("URLError returns api_error entry, preserves isActive and metrics")
    func urlErrorReturnsApiError() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)

        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 2.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let firstEntries = try await connector.fetchUsages()

        CodexMockURLProtocol.errorToThrow = URLError(.notConnectedToInternet)
        CodexMockURLProtocol.handler = nil
        let entries = try await connector.fetchUsages()
        CodexMockURLProtocol.errorToThrow = nil

        #expect(entries.count == 1)
        #expect(entries[0].account == "user@openai.com")
        #expect(entries[0].lastError?.type == "api_error")
        #expect(entries[0].isActive == true)
        #expect(entries[0].metrics == firstEntries[0].metrics)
    }

    @Test("HTTP 5xx preserves isActive and metrics across server hiccups")
    func http500PreservesActiveAndMetrics() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)

        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 2.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let firstEntries = try await connector.fetchUsages()

        CodexMockURLProtocol.handler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://chatgpt.com")!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].account == "user@openai.com")
        #expect(entries[0].lastError?.type == "http_503")
        #expect(entries[0].isActive == true)
        #expect(entries[0].metrics == firstEntries[0].metrics)
    }

    // MARK: - limit_window_seconds vs fallback

    @Test("limit_window_seconds absent → fallback to 300 min for primary and 10080 for secondary")
    func fallbackDurationsWhenLimitWindowSecondsMissing() async throws {
        let dir = try makeTempDir()
        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 10.0, "reset_at": 1745000000},
            "secondary_window": {"used_percent": 5.0, "reset_at": 1745500000}
          }
        }
        """)
        let connector = makeConnector(dir: dir)
        let entries = try await connector.fetchUsages()

        if case .timeWindow(_, _, let duration, _) = entries[0].metrics[0] {
            #expect(duration.rawValue == 300)
        } else {
            Issue.record("Expected timeWindow for primary window")
        }
        if case .timeWindow(_, _, let duration, _) = entries[0].metrics[1] {
            #expect(duration.rawValue == 10080)
        } else {
            Issue.record("Expected timeWindow for secondary window")
        }
    }

    // MARK: - Credits header fallback

    @Test("x-codex-credits-balance header used when body credits absent")
    func creditsHeaderFallback() async throws {
        let dir = try makeTempDir()
        mockHTTP200(
            json: """
            {
              "email": "user@openai.com",
              "rate_limit": {
                "primary_window": {"used_percent": 10.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
                "secondary_window": {"used_percent": 5.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
              }
            }
            """,
            headers: ["x-codex-credits-balance": "200"]
        )
        let connector = makeConnector(dir: dir)
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].metrics.count == 3)

        let creditsMetric = entries[0].metrics.first {
            if case .payAsYouGo(let n, _, _) = $0 { return n == "Credits balance" }
            return false
        }
        if case .payAsYouGo(_, let amount, _) = creditsMetric {
            #expect(amount == 200.0)
        } else {
            Issue.record("Expected payAsYouGo Credits balance from header")
        }
    }

    // MARK: - Account email and cache

    @Test("credentials email is used when payload email is absent")
    func accountUsesCredentialsEmailWhenPayloadEmailMissing() async throws {
        let dir = try makeTempDir()
        mockHTTP200(json: """
        {
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 2.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let connector = makeConnector(dir: dir, credentials: validCredentials(accountEmail: "from-creds@openai.com"))
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].account == "from-creds@openai.com")
        #expect(connector.resolveActiveAccount() == "from-creds@openai.com")
    }

    @Test("missing email everywhere writes no fallback entry and logs identity_unresolved")
    func missingEmailEverywhereSkipsEntry() async throws {
        let dir = try makeTempDir()
        let logPath = "\(dir)/test.log"
        mockHTTP200(json: """
        {
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 2.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let logger = FileLogger(filePath: logPath, minLevel: .debug)
        let connector = CodexConnector(
            auth: MockCodexAuth(credentials: validCredentials(), error: nil),
            logger: logger,
            session: mockSession()
        )
        let entries = try await connector.fetchUsages()

        #expect(entries.isEmpty)
        #expect(connector.resolveActiveAccount() == nil)

        logger.waitForPendingWrites()
        let logContent = try readLog(at: logPath)
        #expect(logContent.contains("identity_unresolved"))
        #expect(!logContent.contains("acct-123@codex"))
    }

    @Test("resolveActiveAccount returns cached email after successful fetch")
    func resolveActiveAccountReturnsCachedEmail() async throws {
        let dir = try makeTempDir()
        mockHTTP200(json: """
        {
          "email": "cached@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 2.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let connector = makeConnector(dir: dir)
        #expect(connector.resolveActiveAccount() == nil)

        _ = try await connector.fetchUsages()

        #expect(connector.resolveActiveAccount() == "cached@openai.com")
    }

    @Test("invalidateEmailCache clears resolved account")
    func invalidateEmailCacheClearsAccount() async throws {
        let dir = try makeTempDir()
        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 2.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let connector = makeConnector(dir: dir)
        _ = try await connector.fetchUsages()
        #expect(connector.resolveActiveAccount() != nil)

        await connector.invalidateEmailCache()

        #expect(connector.resolveActiveAccount() == nil)
    }

    // MARK: - Request headers

    @Test("request sends correct Authorization, ChatGPT-Account-Id, and User-Agent headers")
    func requestHeaders() async throws {
        let dir = try makeTempDir()
        CodexMockURLProtocol.capturedRequest = nil
        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 2.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let connector = makeConnector(dir: dir)
        _ = try await connector.fetchUsages()

        #expect(CodexMockURLProtocol.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer fake-token")
        #expect(CodexMockURLProtocol.capturedRequest?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-123")
        #expect(CodexMockURLProtocol.capturedRequest?.value(forHTTPHeaderField: "User-Agent") == "OpenUsage")
    }

    // MARK: - reset_at

    @Test("null reset_at emits metric with nil resetAt — not silently dropped")
    func nullResetAtEmitsMetricWithoutDate() async throws {
        let dir = try makeTempDir()
        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 0.0, "reset_at": null, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 0.0, "reset_at": null, "limit_window_seconds": 604800}
          }
        }
        """)
        let connector = makeConnector(dir: dir)
        let entries = try await connector.fetchUsages()

        #expect(entries[0].lastError == nil)
        #expect(entries[0].metrics.count == 2)
        if case .timeWindow(_, let resetAt, _, _) = entries[0].metrics[0] {
            #expect(resetAt == nil)
        } else {
            Issue.record("Expected timeWindow for primary window")
        }
    }

    @Test("idle account: reset_after_seconds == limit_window_seconds is treated as window-not-opened (resetAt: nil)")
    func idleAccountFreshWindowSignatureEmitsNilResetAt() async throws {
        // Captured from a live `GET /backend-api/wham/usage` call on 2026-05-11
        // for an account that had not sent any message in several days.
        // OpenAI returned `used_percent: 1` (likely an internal baseline) and
        // `reset_at = now + 5h`. The smoking gun is `reset_after_seconds`
        // matching `limit_window_seconds` exactly (18000 == 18000): a genuine
        // rolling window in progress would have `reset_after_seconds < limit_window_seconds`
        // because time has elapsed since the first request opened it.
        //
        // We treat that signature as "window not actually opened" and emit the
        // metric with `resetAt: nil` so the popover renders "???" instead of a
        // misleading "ends in 5h". This compensates for an OpenAI API quirk —
        // not a bug in our side. If OpenAI changes the API to either return
        // `reset_at: null` or stop emitting this idle-default response, this
        // workaround becomes dead weight; remove it then. Update or delete
        // this test the day the live capture below stops reproducing.
        let dir = try makeTempDir()
        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {
              "used_percent": 1,
              "limit_window_seconds": 18000,
              "reset_after_seconds": 18000,
              "reset_at": 1778515227
            },
            "secondary_window": {
              "used_percent": 0,
              "limit_window_seconds": 604800,
              "reset_after_seconds": 223950,
              "reset_at": 1778721177
            }
          }
        }
        """)
        let connector = makeConnector(dir: dir)
        let entries = try await connector.fetchUsages()

        #expect(entries[0].metrics.count == 2)

        // Primary window: idle-account signature → resetAt must be nil
        if case .timeWindow(let name, let resetAt, _, _) = entries[0].metrics[0] {
            #expect(name == "Session (5h)")
            #expect(resetAt == nil, "Fresh-untouched-window signature must surface as resetAt: nil so the UI renders ???")
        } else {
            Issue.record("Expected timeWindow for Session (5h)")
        }

        // Secondary window: reset_after_seconds (223950) < limit_window_seconds (604800)
        // → genuine in-progress window, resetAt must be preserved
        if case .timeWindow(let name, let resetAt, _, _) = entries[0].metrics[1] {
            #expect(name == "Weekly (7d)")
            #expect(resetAt != nil, "In-progress window (reset_after_seconds < limit_window_seconds) must keep its resetAt")
        } else {
            Issue.record("Expected timeWindow for Weekly (7d)")
        }
    }

    // MARK: - Debug logging

    @Test("debug log is emitted on HTTP 200 with masked payload")
    func debugLogOnSuccess() async throws {
        let dir = try makeTempDir()
        mockHTTP200(json: """
        {
          "email": "user@openai.com",
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 2.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let auth = MockCodexAuth(credentials: validCredentials(), error: nil)
        let connector = CodexConnector(auth: auth, logger: logger, session: mockSession())
        _ = try await connector.fetchUsages()

        logger.waitForPendingWrites()
        let logContent = try String(contentsOfFile: "\(dir)/test.log", encoding: .utf8)
        let payloadLogLine = try #require(logContent
            .split(separator: "\n")
            .first { $0.contains("Codex API payload:") })
        #expect(payloadLogLine.contains(#""email":"***""#))
        #expect(!payloadLogLine.contains("user@openai.com"))
    }

    @Test("maskedPayload redacts nested sensitive fields")
    func maskedPayloadRedactsNestedSensitiveFields() throws {
        let payload = """
        {
          "email": "user@openai.com",
          "nested": {
            "access_token": "secret-token",
            "safe": "visible"
          },
          "items": [
            {"api_key": "secret-key", "name": "kept"}
          ]
        }
        """
        let data = try #require(payload.data(using: .utf8))

        let masked = CodexConnector.maskedPayload(data)

        #expect(masked.contains(#""email":"***""#))
        #expect(masked.contains(#""access_token":"***""#))
        #expect(masked.contains(#""api_key":"***""#))
        #expect(masked.contains(#""safe":"visible""#))
        #expect(!masked.contains("user@openai.com"))
        #expect(!masked.contains("secret-token"))
        #expect(!masked.contains("secret-key"))
    }
}

// MARK: - Account status

// Extension of the serialized suite: the URL mock is shared static state, so
// these must not run concurrently with the other fetch tests.
extension CodexConnectorFetchTests {
    private func fetchSingleEntry(_ json: String) async throws -> VendorUsageEntry {
        let dir = try makeTempDir()
        mockHTTP200(json: json)
        let entries = try await makeConnector(dir: dir).fetchUsages()
        return try #require(entries.first)
    }

    /// Fixtures carry no email (identity fields were stripped), so the
    /// account comes from the credentials, as for a real auth.json login.
    private func fetchFixtureEntry(_ name: String) async throws -> VendorUsageEntry {
        let entries = try await fetchFixtureEntries(name)
        return try #require(entries.first)
    }

    private func fetchFixtureEntries(_ name: String) async throws -> [VendorUsageEntry] {
        let dir = try makeTempDir()
        let json = try #require(String(data: FixtureLoader.load(name), encoding: .utf8))
        mockHTTP200(json: json)
        let connector = makeConnector(dir: dir, credentials: validCredentials(accountEmail: "fixture@example.invalid"))
        return try await connector.fetchUsages()
    }

    private func metricNames(_ entry: VendorUsageEntry) -> [String] {
        entry.metrics.compactMap { metric in
            switch metric {
            case .timeWindow(let name, _, _, _): name
            case .payAsYouGo(let name, _, _): name
            case .unknown: nil
            }
        }
    }

    @Test("fixture prolite + Spark: weekly primary, per-model 5h and weekly limits, reset count")
    func fixtureProliteSpark() async throws {
        let entry = try await fetchFixtureEntry("codex-prolite-spark")
        #expect(metricNames(entry) == ["Weekly (7d)", "GPT-5.3-Codex-Spark (5h)", "GPT-5.3-Codex-Spark Weekly (7d)"])
        #expect(entry.accountStatus?.plan?.displayName == "Pro Lite")
        #expect(entry.accountStatus?.block == nil)
        #expect(entry.accountStatus?.resetCredits == ResetCredits(available: 1, applicable: 0))
    }

    @Test("fixture prolite with credits: string balance and message ranges")
    func fixtureProliteCredits() async throws {
        let entry = try await fetchFixtureEntry("codex-prolite-credits")
        #expect(metricNames(entry) == ["Weekly (7d)", "Credits balance"])
        #expect(entry.accountStatus?.credits?.approxLocalMessages == MessageRange(lower: 65, upper: 339))
        #expect(entry.accountStatus?.credits?.approxCloudMessages == MessageRange(lower: 10, upper: 65))
        #expect(entry.accountStatus?.unavailableModels.isEmpty == true)
    }

    @Test("fixture plus with \"12.50\" balance: balance metric emitted")
    func fixturePlusStringBalance() async throws {
        let entry = try await fetchFixtureEntry("codex-plus-string-balance")
        let balance = entry.metrics.compactMap { metric -> Double? in
            if case let .payAsYouGo(_, amount, _) = metric { return amount }
            return nil
        }
        #expect(balance == [12.5])
        #expect(metricNames(entry).prefix(2) == ["Session (5h)", "Weekly (7d)"])
    }

    @Test("fixture blocked Pro with a malformed extra limit: block kept, bad limit skipped")
    func fixtureLimitReachedMalformedExtra() async throws {
        let entry = try await fetchFixtureEntry("codex-pro-limit-reached-malformed-extra")
        #expect(metricNames(entry) == ["Session (5h)"])
        #expect(entry.accountStatus?.block == AccountBlock(
            reason: .rateLimit,
            resumesAt: ISODate(date: Date(timeIntervalSince1970: 1789000900))
        ))
    }

    @Test("fixture API-key account without rate_limit → parse_error, no crash")
    func fixtureApiKeyNoRateLimit() async throws {
        let entries = try await fetchFixtureEntries("codex-api-key-no-rate-limit")
        #expect(entries.first?.lastError?.type == "parse_error")
    }

    @Test("Pro blocked payload: weekly label on primary window, block, unavailable model")
    func proBlocked() async throws {
        let entry = try await fetchFixtureEntry("codex-pro-blocked")

        guard case let .timeWindow(name, _, duration, percent) = entry.metrics.first else {
            Issue.record("Expected a time window metric"); return
        }
        #expect(name == "Weekly (7d)")
        #expect(duration == 10080)
        #expect(percent == 100)

        let status = try #require(entry.accountStatus)
        #expect(status.plan == "pro")
        #expect(status.block == AccountBlock(
            reason: .rateLimit,
            resumesAt: ISODate(date: Date(timeIntervalSince1970: 1791050824))
        ))
        #expect(status.unavailableModels.count == 1)
        let model = try #require(status.unavailableModels.first)
        #expect(model.model == "gpt-6-astra")
        #expect(model.creditsWouldEnable)
        #expect(model.availableAt?.date != nil)
        #expect(status.credits == nil)
    }

    @Test("nominal Plus payload: plan + resets only, no block / models / credits")
    func plusNominal() async throws {
        let entry = try await fetchSingleEntry("""
        {
          "email": "user@openai.com",
          "plan_type": "plus",
          "rate_limit": {
            "allowed": true, "limit_reached": false,
            "primary_window": {"used_percent": 0, "limit_window_seconds": 18000, "reset_after_seconds": 14931, "reset_at": 1792297715},
            "secondary_window": {"used_percent": 0, "limit_window_seconds": 604800, "reset_after_seconds": 601731, "reset_at": 1792884515}
          },
          "model_usage": {"gpt-6-astra": {"available": true, "available_at": null, "credits_would_enable": false}},
          "credits": {"has_credits": false, "unlimited": false, "overage_limit_reached": false, "balance": "0",
                      "approx_local_messages": [0, 0], "approx_cloud_messages": [0, 0]},
          "spend_control": {"reached": false, "individual_limit": null},
          "rate_limit_reached_type": null,
          "rate_limit_reset_credits": {"available_count": 3, "applicable_available_count": 0}
        }
        """)
        let names = entry.metrics.compactMap { metric -> String? in
            if case .timeWindow(let n, _, _, _) = metric { return n }
            return nil
        }
        #expect(names == ["Session (5h)", "Weekly (7d)"])
        #expect(entry.accountStatus == AccountStatus(
            plan: "plus",
            resetCredits: ResetCredits(available: 3, applicable: 0)
        ))
    }

    @Test("string balance is parsed and approx message ranges are kept")
    func creditsWithStringBalance() async throws {
        let entry = try await fetchSingleEntry("""
        {
          "email": "user@openai.com",
          "plan_type": "prolite",
          "rate_limit": {"primary_window": {"used_percent": 56, "limit_window_seconds": 604800, "reset_after_seconds": 261856, "reset_at": 1790015277}, "secondary_window": null},
          "credits": {"has_credits": true, "unlimited": false, "balance": "260.9493799584",
                      "approx_local_messages": [65, 339], "approx_cloud_messages": [10, 65]}
        }
        """)
        let balance = entry.metrics.compactMap { metric -> Double? in
            if case let .payAsYouGo(name, amount, _) = metric, name == "Credits balance" { return amount }
            return nil
        }.first
        #expect(balance == 260.9493799584)
        #expect(entry.accountStatus?.credits == CreditsSummary(
            unlimited: false,
            overageLimitReached: false,
            approxLocalMessages: MessageRange(lower: 65, upper: 339),
            approxCloudMessages: MessageRange(lower: 10, upper: 65)
        ))
        #expect(entry.accountStatus?.plan?.displayName == "Pro Lite")
    }

    @Test("spend control reached → spendControl block without resume date")
    func spendControlBlock() async throws {
        let entry = try await fetchSingleEntry("""
        {
          "email": "user@openai.com",
          "rate_limit": {"allowed": false, "limit_reached": false,
                         "primary_window": {"used_percent": 12, "limit_window_seconds": 18000, "reset_at": 1745000000}},
          "spend_control": {"reached": true, "individual_limit": 50}
        }
        """)
        #expect(entry.accountStatus?.block == AccountBlock(reason: .spendControl, resumesAt: nil))
    }

    @Test("both windows exhausted → resume at the later reset")
    func blockResumesAtLatestExhaustedWindow() async throws {
        let entry = try await fetchSingleEntry("""
        {
          "email": "user@openai.com",
          "rate_limit": {"allowed": false, "limit_reached": true,
            "primary_window": {"used_percent": 100, "limit_window_seconds": 18000, "reset_after_seconds": 100, "reset_at": 1745000000},
            "secondary_window": {"used_percent": 100, "limit_window_seconds": 604800, "reset_after_seconds": 100, "reset_at": 1745500000}}
        }
        """)
        #expect(entry.accountStatus?.block?.resumesAt == ISODate(date: Date(timeIntervalSince1970: 1745500000)))
    }

    @Test("unlimited and overage-reached credits are surfaced even without ranges")
    func creditsStates() async throws {
        let entry = try await fetchSingleEntry("""
        {
          "email": "user@openai.com",
          "rate_limit": {"primary_window": {"used_percent": 1, "limit_window_seconds": 18000, "reset_at": 1745000000}},
          "credits": {"has_credits": false, "unlimited": true, "overage_limit_reached": true}
        }
        """)
        #expect(entry.accountStatus?.credits?.unlimited == true)
        #expect(entry.accountStatus?.credits?.overageLimitReached == true)
    }

    @Test("windowLabel maps durations onto stable metric names")
    func windowLabels() {
        #expect(CodexConnector.windowLabel(for: 300) == "Session (5h)")
        #expect(CodexConnector.windowLabel(for: 10080) == "Weekly (7d)")
        #expect(CodexConnector.windowLabel(for: 1440) == "(1d)")
        #expect(CodexConnector.windowLabel(for: 180) == "(3h)")
        #expect(CodexConnector.windowLabel(for: 45) == "(45m)")
        #expect(CodexConnector.windowLabel(for: 300, prefix: "Spark") == "Spark (5h)")
        #expect(CodexConnector.windowLabel(for: 10080, prefix: "Spark") == "Spark Weekly (7d)")
    }

    @Test("invalid optional counts do not discard valid usage", arguments: ["1e100", "-1", "1.5"])
    func invalidStatusCounts(raw: String) async throws {
        let entry = try await fetchSingleEntry("""
        {"email":"user@openai.com",
         "rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000}},
         "rate_limit_reset_credits":{"available_count":\(raw),"applicable_available_count":0},
         "credits":{"approx_local_messages":[0,\(raw)]}}
        """)
        #expect(entry.lastError == nil)
        #expect(metricNames(entry) == ["Session (5h)"])
        #expect(entry.accountStatus?.resetCredits == nil)
        #expect(entry.accountStatus?.credits == nil)
        _ = try JSONEncoder().encode(entry)
    }

    @Test("nonfinite credit balances leave usage persistable", arguments: [false, true])
    func nonfiniteBalance(fromHeader: Bool) async throws {
        let json = """
        {"email":"user@openai.com",
         "rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000}},
         "credits":{"has_credits":true,"balance":"Infinity"}}
        """
        mockHTTP200(json: json, headers: fromHeader ? ["x-codex-credits-balance": "Infinity"] : [:])
        let entries = try await makeConnector(dir: try makeTempDir()).fetchUsages()
        let entry = try #require(entries.first)
        #expect(entry.lastError == nil)
        #expect(metricNames(entry) == ["Session (5h)"])
        _ = try JSONEncoder().encode(entry)
    }

    private func mockRouted(usage: String, resetStatus: Int, resets: String) {
        CodexMockURLProtocol.errorToThrow = nil
        CodexMockURLProtocol.handler = { request in
            let isResets = request.url?.path.hasSuffix("rate-limit-reset-credits") == true
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: isResets ? resetStatus : 200, httpVersion: nil, headerFields: [:]
            )!
            return (Data((isResets ? resets : usage).utf8), resp)
        }
    }

    private static let usageWithResets = """
    {"email": "user@openai.com",
     "rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 18000, "reset_at": 1745000000}},
     "rate_limit_reset_credits": {"available_count": 2, "applicable_available_count": 0}}
    """

    @Test("reset credits: available grants carry their expiry from the details endpoint")
    func resetCreditDetails() async throws {
        mockRouted(usage: Self.usageWithResets, resetStatus: 200, resets: """
        {"credits": [
          {"id": "c1", "status": "available", "expires_at": "2026-07-17T00:00:00Z", "title": "Full reset (Weekly + 5 hr)"},
          {"id": "c2", "status": "available", "expires_at": 1790000000, "title": "5 hr reset"},
          {"id": "c3", "status": "redeemed", "expires_at": "2026-06-01T00:00:00Z"}
        ]}
        """)
        let entries = try await makeConnector(dir: try makeTempDir()).fetchUsages()
        let resets = try #require(entries.first?.accountStatus?.resetCredits)
        #expect(resets.available == 2)
        #expect(resets.grants.map(\.kind) == [.full, .session])
        #expect(resets.grants.first?.expiresAt?.date != nil)
        #expect(resets.nextExpiry?.date == ISO8601DateFormatter().date(from: "2026-07-17T00:00:00Z"))
    }

    @Test("reset credits: details endpoint failure keeps the counts")
    func resetCreditDetailsFailure() async throws {
        mockRouted(usage: Self.usageWithResets, resetStatus: 500, resets: "oops")
        let entries = try await makeConnector(dir: try makeTempDir()).fetchUsages()
        #expect(entries.first?.lastError == nil)
        #expect(entries.first?.accountStatus?.resetCredits == ResetCredits(available: 2, applicable: 0))
    }
}
