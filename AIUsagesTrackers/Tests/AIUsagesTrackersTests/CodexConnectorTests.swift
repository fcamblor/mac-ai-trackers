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

private struct MockCodexAuth: CodexAuthProviding {
    let credentials: CodexCredentials?
    let error: Error?

    func load() async throws -> CodexCredentials {
        if let error { throw error }
        return credentials!
    }
}

private actor SequenceCodexAuth: CodexAuthProviding {
    private var results: [Result<CodexCredentials, Error>]

    init(_ results: [Result<CodexCredentials, Error>]) {
        self.results = results
    }

    func load() async throws -> CodexCredentials {
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
        #expect(names.contains("Credits used"))

        let creditsMetric = entries[0].metrics.first {
            if case .payAsYouGo(let n, _, _) = $0 { return n == "Credits used" }
            return false
        }
        if case .payAsYouGo(_, let amount, let currency) = creditsMetric {
            #expect(amount == 250.0)  // 1000 - 750
            #expect(currency == "credits")
        } else {
            Issue.record("Expected payAsYouGo Credits used metric")
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
            .failure(CodexAuthError.keychainEmpty),
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

    @Test("malformed JSON payload returns parse_error entry")
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
        _ = try await connector.fetchUsages()

        CodexMockURLProtocol.handler = { _ in
            let data = "not-json".data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://chatgpt.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].account == "user@openai.com")
        #expect(entries[0].lastError?.type == "parse_error")
    }

    @Test("URLError returns api_error entry")
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
        _ = try await connector.fetchUsages()

        CodexMockURLProtocol.errorToThrow = URLError(.notConnectedToInternet)
        CodexMockURLProtocol.handler = nil
        let entries = try await connector.fetchUsages()
        CodexMockURLProtocol.errorToThrow = nil

        #expect(entries.count == 1)
        #expect(entries[0].account == "user@openai.com")
        #expect(entries[0].lastError?.type == "api_error")
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
            if case .payAsYouGo(let n, _, _) = $0 { return n == "Credits used" }
            return false
        }
        if case .payAsYouGo(_, let amount, _) = creditsMetric {
            #expect(amount == 800.0)  // 1000 - 200
        } else {
            Issue.record("Expected payAsYouGo Credits used from header")
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
