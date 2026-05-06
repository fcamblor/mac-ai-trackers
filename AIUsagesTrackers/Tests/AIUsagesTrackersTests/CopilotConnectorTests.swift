import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - URL mocking

// swiftlint:disable:next w4_unchecked_sendable — URLProtocol subclass; all mutable static state accessed only from the serialized test suite
final class CopilotMockURLProtocol: URLProtocol, @unchecked Sendable {
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

private struct MockCopilotAuth: CopilotAuthProviding {
    let credentials: CopilotCredentials?
    let error: Error?

    func load() async throws -> CopilotCredentials {
        if let error { throw error }
        return credentials!
    }
}

// MARK: - Helpers

private func makeTempDir() throws -> String {
    let dir = NSTemporaryDirectory() + "ai-tracker-copilot-fetch-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CopilotMockURLProtocol.self]
    return URLSession(configuration: config)
}

private func validCredentials(login: String = "fcamblor") -> CopilotCredentials {
    CopilotCredentials(
        accessToken: "fake-token",
        activeLogin: AccountEmail(rawValue: login),
        tokenSource: .keychain
    )
}

private func makeConnector(
    dir: String,
    credentials: CopilotCredentials? = nil,
    authError: Error? = nil
) -> CopilotConnector {
    let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
    let auth = MockCopilotAuth(credentials: credentials ?? validCredentials(), error: authError)
    return CopilotConnector(auth: auth, logger: logger, session: mockSession())
}

private func mockHTTP(status: Int, json: String, headers: [String: String] = [:]) {
    CopilotMockURLProtocol.errorToThrow = nil
    CopilotMockURLProtocol.handler = { _ in
        let data = json.data(using: .utf8)!
        let resp = HTTPURLResponse(
            url: URL(string: "https://api.github.com/copilot_internal/user")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        return (data, resp)
    }
}

// MARK: - Suite

@Suite("CopilotConnector — fetchUsages", .serialized)
struct CopilotConnectorFetchTests {
    @Test("Pro plan: quota_snapshots produces Premium + Chat metrics")
    func proPlanHappyPath() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)

        mockHTTP(status: 200, json: """
        {
          "copilot_plan": "pro",
          "quota_reset_date": "2026-06-01",
          "quota_snapshots": {
            "premium_interactions": { "percent_remaining": 80, "unlimited": false },
            "chat":                 { "percent_remaining": 95, "unlimited": false }
          }
        }
        """)

        let entries = try await connector.fetchUsages()
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.vendor == .copilot)
        #expect(entry.account.rawValue == "fcamblor")
        #expect(entry.metrics.count == 2)
        #expect(entry.lastError == nil)

        guard case let .timeWindow(name1, _, _, percent1) = entry.metrics[0] else {
            Issue.record("Expected timeWindow metric, got \(entry.metrics[0])")
            return
        }
        #expect(name1 == "Premium")
        // 100 - 80 = 20% used
        #expect(percent1.rawValue == 20)

        guard case let .timeWindow(name2, _, _, percent2) = entry.metrics[1] else {
            Issue.record("Expected timeWindow metric, got \(entry.metrics[1])")
            return
        }
        #expect(name2 == "Chat")
        #expect(percent2.rawValue == 5)
    }

    @Test("Pro plan: unlimited:true with percent_remaining still produces a metric (regression — openusage parity)")
    func proPlanUnlimitedTrueStillProducesMetric() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)

        // Real-world Pro response: `unlimited:true` on premium_interactions means
        // "soft monthly allowance, overage billed" — `percent_remaining` is still
        // meaningful (here: 99.67% remaining ≈ 1 premium request used out of 300).
        mockHTTP(status: 200, json: """
        {
          "copilot_plan": "pro",
          "quota_reset_date": "2026-06-06T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": { "percent_remaining": 99.67, "unlimited": true },
            "chat":                 { "percent_remaining": 100,   "unlimited": true }
          }
        }
        """)

        let entries = try await connector.fetchUsages()
        let entry = try #require(entries.first)
        #expect(entry.metrics.count == 2)

        guard case let .timeWindow(name1, _, _, percent1) = entry.metrics[0] else {
            Issue.record("Expected timeWindow metric, got \(entry.metrics[0])")
            return
        }
        #expect(name1 == "Premium")
        // 100 - 99.67 = 0.33 → rounds to 0
        #expect(percent1.rawValue == 0)

        guard case let .timeWindow(name2, _, _, percent2) = entry.metrics[1] else {
            Issue.record("Expected timeWindow metric, got \(entry.metrics[1])")
            return
        }
        #expect(name2 == "Chat")
        #expect(percent2.rawValue == 0)
    }

    @Test("Pro plan: integer percent_remaining (no decimal) still produces a metric")
    func proPlanIntegerPercentRemaining() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)

        // JSONSerialization decodes `99` as NSNumber-bridged Int — `as? Double`
        // can fail in some builds; `numericValue(_:)` handles both shapes.
        mockHTTP(status: 200, json: """
        {
          "quota_snapshots": {
            "premium_interactions": { "percent_remaining": 99, "unlimited": true }
          }
        }
        """)

        let entries = try await connector.fetchUsages()
        let entry = try #require(entries.first)
        #expect(entry.metrics.count == 1)
        guard case let .timeWindow(_, _, _, percent) = entry.metrics[0] else {
            Issue.record("Expected timeWindow")
            return
        }
        #expect(percent.rawValue == 1)
    }

    @Test("quota_reset_date in `yyyy-MM-dd` is normalized to ISO 8601 datetime")
    func dateOnlyResetDateNormalizedToDatetime() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)

        // GitHub historically returns `quota_reset_date` as a calendar date
        // (no time component) — must be promoted to UTC midnight datetime so
        // downstream code that calls `.date` on the ISODate gets a real Date.
        mockHTTP(status: 200, json: """
        {
          "quota_reset_date": "2026-06-06",
          "quota_snapshots": {
            "premium_interactions": { "percent_remaining": 80, "unlimited": false }
          }
        }
        """)

        let entries = try await connector.fetchUsages()
        let entry = try #require(entries.first)
        guard case let .timeWindow(_, resetAt, _, _) = entry.metrics[0] else {
            Issue.record("Expected timeWindow")
            return
        }
        let resolved = try #require(resetAt)
        #expect(resolved.isStrictlyValid, "resetAt must round-trip through Date — got '\(resolved.rawValue)'")
        #expect(resolved.rawValue.contains("T"), "expected ISO 8601 datetime, got date-only '\(resolved.rawValue)'")
    }

    @Test("Free plan: limited_user_quotas + monthly_quotas produce Chat + Completions metrics")
    func freePlanHappyPath() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)

        mockHTTP(status: 200, json: """
        {
          "copilot_plan": "individual",
          "limited_user_reset_date": "2026-06-01",
          "limited_user_quotas":  { "chat": 410, "completions": 4000 },
          "monthly_quotas":       { "chat": 500, "completions": 2000 }
        }
        """)

        let entries = try await connector.fetchUsages()
        let entry = try #require(entries.first)
        #expect(entry.metrics.count == 2)

        guard case let .timeWindow(name1, _, _, percent1) = entry.metrics[0] else {
            Issue.record("Expected timeWindow")
            return
        }
        #expect(name1 == "Chat")
        // (500 - 410) / 500 = 18%
        #expect(percent1.rawValue == 18)

        guard case let .timeWindow(name2, _, _, percent2) = entry.metrics[1] else {
            Issue.record("Expected timeWindow")
            return
        }
        #expect(name2 == "Completions")
        // remaining 4000 > total 2000 → used clamped to 0% (negative pre-clamp)
        #expect(percent2.rawValue == 0)
    }

    @Test("HTTP 401 returns token_expired error entry with cached login")
    func http401ReturnsTokenExpiredEntry() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)
        mockHTTP(status: 401, json: "{\"message\":\"Bad credentials\"}")

        let entries = try await connector.fetchUsages()
        let entry = try #require(entries.first)
        #expect(entry.lastError?.type == "token_expired")
        #expect(entry.account.rawValue == "fcamblor")
        #expect(entry.isActive == false)
        #expect(entry.metrics.isEmpty)
    }

    @Test("HTTP 429 preserves last known metrics and marks isActive=true")
    func http429PreservesMetrics() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)

        // First call: 200 to populate lastKnownMetrics
        mockHTTP(status: 200, json: """
        {
          "quota_snapshots": {
            "premium_interactions": { "percent_remaining": 70, "unlimited": false }
          }
        }
        """)
        _ = try await connector.fetchUsages()

        // Second call: 429 — should preserve the previous metric
        mockHTTP(status: 429, json: "{\"message\":\"rate limit\"}")
        let entries = try await connector.fetchUsages()
        let entry = try #require(entries.first)
        #expect(entry.lastError?.type == "http_429")
        #expect(entry.isActive == true)
        #expect(entry.metrics.count == 1)
    }

    @Test("Parse failure returns parse_error entry")
    func parseFailureReturnsErrorEntry() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)
        mockHTTP(status: 200, json: "{\"unrelated\":\"payload\"}")

        let entries = try await connector.fetchUsages()
        let entry = try #require(entries.first)
        #expect(entry.lastError?.type == "parse_error")
    }

    @Test("Required GitHub headers are sent on every request")
    func sendsRequiredHeaders() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)
        mockHTTP(status: 200, json: """
        {"quota_snapshots": {"premium_interactions": {"percent_remaining": 50, "unlimited": false}}}
        """)

        _ = try await connector.fetchUsages()
        let captured = try #require(CopilotMockURLProtocol.capturedRequest)
        #expect(captured.value(forHTTPHeaderField: "Authorization") == "token fake-token")
        #expect(captured.value(forHTTPHeaderField: "Editor-Version") != nil)
        #expect(captured.value(forHTTPHeaderField: "Editor-Plugin-Version") != nil)
        #expect(captured.value(forHTTPHeaderField: "X-Github-Api-Version") != nil)
    }

    @Test("Auth error returns token_error entry with no cached login")
    func authErrorReturnsTokenErrorEntry() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(
            dir: dir,
            authError: CopilotAuthError.notLoggedIn(searchedPaths: [])
        )

        let entries = try await connector.fetchUsages()
        // No cached login on first call → no entry written (matches Codex pattern)
        #expect(entries.isEmpty)
    }

    @Test("invalidateLoginCache clears resolveActiveAccount")
    func invalidateClearsCache() async throws {
        let dir = try makeTempDir()
        let connector = makeConnector(dir: dir)
        mockHTTP(status: 200, json: """
        {"quota_snapshots": {"premium_interactions": {"percent_remaining": 50, "unlimited": false}}}
        """)
        _ = try await connector.fetchUsages()
        #expect(connector.resolveActiveAccount()?.rawValue == "fcamblor")

        await connector.invalidateLoginCache()
        #expect(connector.resolveActiveAccount() == nil)
    }
}
