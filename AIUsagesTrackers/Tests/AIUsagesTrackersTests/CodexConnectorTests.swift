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

// MARK: - Helpers

private func makeTempDir() -> String {
    let dir = NSTemporaryDirectory() + "ai-tracker-codex-fetch-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CodexMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func validCredentials(lastRefreshedAt: Date? = Date()) -> CodexCredentials {
    CodexCredentials(accessToken: "fake-token", accountId: "acct-123", lastRefreshedAt: lastRefreshedAt)
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

// MARK: - Suite

@Suite("CodexConnector — fetchUsages", .serialized)
struct CodexConnectorFetchTests {
    // MARK: - Happy path

    @Test("Plus plan: primary + secondary window returns 2 metrics with email from payload")
    func plusPlanHappyPath() async throws {
        let dir = makeTempDir()
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
        let dir = makeTempDir()
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
        let dir = makeTempDir()
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
        let dir = makeTempDir()
        CodexMockURLProtocol.handler = { _ in
            let resp = HTTPURLResponse(url: URL(string: "https://chatgpt.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }
        let connector = makeConnector(dir: dir)
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "token_expired")
        #expect(entries[0].metrics.isEmpty)
    }

    @Test("HTTP 429 preserves previous metrics and sets http_429 error")
    func http429PreservesMetrics() async throws {
        let dir = makeTempDir()
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
        #expect(rateLimitedEntries[0].lastError?.type == "http_429")
        #expect(rateLimitedEntries[0].isActive == true)
        #expect(rateLimitedEntries[0].metrics.count == 2)
        #expect(rateLimitedEntries[0].metrics == firstEntries[0].metrics)
    }

    @Test("credentials load failure returns token_error entry")
    func credentialsLoadFailureReturnsTokenError() async throws {
        let dir = makeTempDir()
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let auth = MockCodexAuth(credentials: nil, error: CodexAuthError.keychainEmpty)
        let connector = CodexConnector(auth: auth, logger: logger, session: mockSession())
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "token_error")
    }

    @Test("expired token (>8 days since last_refresh) returns token_expired without network call")
    func expiredTokenReturnsTokenExpiredNoNetworkCall() async throws {
        let dir = makeTempDir()
        CodexMockURLProtocol.capturedRequest = nil
        CodexMockURLProtocol.handler = nil

        let oldDate = Date(timeIntervalSinceNow: -(9 * 24 * 3600))  // 9 days ago
        let connector = makeConnector(dir: dir, credentials: CodexCredentials(
            accessToken: "old-token",
            accountId: "acct-123",
            lastRefreshedAt: oldDate
        ))
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "token_expired")
        // Network must not have been called
        #expect(CodexMockURLProtocol.capturedRequest == nil)
    }

    @Test("fresh token (<8 days) is not treated as expired")
    func freshTokenIsNotExpired() async throws {
        let dir = makeTempDir()
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
        let dir = makeTempDir()
        CodexMockURLProtocol.handler = { _ in
            let data = "not-json".data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://chatgpt.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
        let connector = makeConnector(dir: dir)
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "parse_error")
    }

    @Test("URLError returns api_error entry")
    func urlErrorReturnsApiError() async throws {
        let dir = makeTempDir()
        CodexMockURLProtocol.errorToThrow = URLError(.notConnectedToInternet)
        CodexMockURLProtocol.handler = nil
        let connector = makeConnector(dir: dir)
        let entries = try await connector.fetchUsages()
        CodexMockURLProtocol.errorToThrow = nil

        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "api_error")
    }

    // MARK: - limit_window_seconds vs fallback

    @Test("limit_window_seconds absent → fallback to 300 min for primary and 10080 for secondary")
    func fallbackDurationsWhenLimitWindowSecondsMissing() async throws {
        let dir = makeTempDir()
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
        let dir = makeTempDir()
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

    @Test("account falls back to accountId@codex when email absent from payload")
    func accountFallbackToAccountId() async throws {
        let dir = makeTempDir()
        mockHTTP200(json: """
        {
          "rate_limit": {
            "primary_window": {"used_percent": 5.0, "reset_at": 1745000000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 2.0, "reset_at": 1745500000, "limit_window_seconds": 604800}
          }
        }
        """)
        let connector = makeConnector(dir: dir)
        let entries = try await connector.fetchUsages()

        #expect(entries.count == 1)
        #expect(entries[0].account.rawValue == "acct-123@codex")
    }

    @Test("resolveActiveAccount returns cached email after successful fetch")
    func resolveActiveAccountReturnsCachedEmail() async throws {
        let dir = makeTempDir()
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
        let dir = makeTempDir()
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
        let dir = makeTempDir()
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
        let dir = makeTempDir()
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
        let dir = makeTempDir()
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
        #expect(logContent.contains("Codex API payload:"))
    }
}
