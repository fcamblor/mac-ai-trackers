import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - URL mocking

// swiftlint:disable:next w4_unchecked_sendable — URLProtocol subclass; all mutable static state accessed only from the serialized test suite (@Suite(.serialized))
final class AntigravityMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handlers: [String: (URLRequest) -> (Data, HTTPURLResponse)?] = [:]
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)
        
        var found = false
        if let url = request.url?.absoluteString {
            for (pattern, handler) in Self.handlers {
                if url.contains(pattern) {
                    if let (data, response) = handler(request) {
                        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                        client?.urlProtocol(self, didLoad: data)
                        found = true
                    }
                    break
                }
            }
        }
        
        // If no handler matched or handler returned nil, signal an error
        if !found {
            let error = URLError(.cannotConnectToHost)
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private func mockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AntigravityMockURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Mock credential locator

private struct MockAntigravityCredentialLocator: CredentialLocator {
    enum Error: Swift.Error {
        case tokenExpired
        case other
    }
    
    let shouldFail: Bool
    let tokenExpired: Bool
    
    func locate() async throws -> AntigravityCredentials {
        if tokenExpired {
            throw Error.tokenExpired
        }
        if shouldFail {
            throw Error.other
        }
        return AntigravityCredentials(
            accessToken: "test-token-abc123",
            expiresAt: Date(timeIntervalSinceNow: 3600)
        )
    }
}

// MARK: - Test data builders

private func userinfoPaload(email: String = "test@example.com") -> Data {
    let json = ["email": email, "sub": "user123"]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func loadCodeAssistPayload(project: String = "projects/test-project") -> Data {
    let json = ["cloudaicompanionProject": project]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func fetchAvailableModelsPayload(models: [(id: String, name: String)] = [
    ("claude-opus-4-6-thinking", "Claude Opus 4.6 Thinking"),
    ("gemini-2.5-flash", "Gemini 2.5 Flash"),
]) -> Data {
    let modelArray = models.map { ["modelId": $0.id, "displayName": $0.name] }
    let json = ["models": modelArray]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func retrieveUserQuotaPayload(buckets: [(modelId: String, remaining: Double, resetTime: String?)] = [
    ("claude-opus-4-6-thinking", 0.0, "2026-05-29T23:44:13Z"),
    ("gemini-2.5-flash", 0.4, "2026-05-29T23:24:10Z"),
]) -> Data {
    let bucketArray = buckets.map { bucket -> [String: Any] in
        var dict: [String: Any] = [
            "modelId": bucket.modelId,
            "remainingFraction": bucket.remaining,
            "tokenType": "WTUS"
        ]
        if let reset = bucket.resetTime {
            dict["resetTime"] = reset
        }
        return dict
    }
    let json = ["buckets": bucketArray]
    return try! JSONSerialization.data(withJSONObject: json)
}

// MARK: - Account resolution tests

@Suite("AntigravityConnector — account resolution")
struct AntigravityConnectorAccountTests {
    init() {
        AntigravityMockURLProtocol.handlers = [:]
        AntigravityMockURLProtocol.capturedRequests = []
    }
    
    @Test("resolveActiveAccount returns nil initially")
    func resolveInitial() {
        let connector = AntigravityConnector(
            auth: MockAntigravityCredentialLocator(shouldFail: false, tokenExpired: false)
        )
        #expect(connector.resolveActiveAccount() == nil)
    }

    @Test("knownAccounts returns empty array initially")
    func knownAccountsInitial() {
        let connector = AntigravityConnector(
            auth: MockAntigravityCredentialLocator(shouldFail: false, tokenExpired: false)
        )
        #expect(connector.knownAccounts() == [])
    }


}

// MARK: - Credential error tests

@Suite("AntigravityConnector — credential errors", .serialized)
struct AntigravityConnectorCredentialTests {
    init() {
        AntigravityMockURLProtocol.handlers = [:]
        AntigravityMockURLProtocol.capturedRequests = []
    }
    
    @Test("missing credentials returns empty entries (no account identity)")
    func missingCredentials() async throws {
        AntigravityMockURLProtocol.handlers = [:]
        AntigravityMockURLProtocol.capturedRequests = []

        let connector = AntigravityConnector(
            auth: MockAntigravityCredentialLocator(shouldFail: true, tokenExpired: false),
            session: mockSession()
        )

        let entries = try await connector.fetchUsages()

        // No cached account → no entry written (follows usages-retention rules)
        #expect(entries.count == 0)
        #expect(connector.knownAccounts() == [])
    }

    @Test("token expired returns empty entries (no account identity)")
    func tokenExpired() async throws {
        AntigravityMockURLProtocol.handlers = [:]
        AntigravityMockURLProtocol.capturedRequests = []

        let connector = AntigravityConnector(
            auth: MockAntigravityCredentialLocator(shouldFail: false, tokenExpired: true),
            session: mockSession()
        )

        let entries = try await connector.fetchUsages()

        // No cached account → no entry written
        #expect(entries.count == 0)
    }
}

// MARK: - Bootstrap error tests

@Suite("AntigravityConnector — bootstrap errors", .serialized)
struct AntigravityConnectorBootstrapTests {
    init() {
        AntigravityMockURLProtocol.handlers = [:]
        AntigravityMockURLProtocol.capturedRequests = []
    }
    
    @Test("userinfo HTTP 401 returns empty entries (cannot resolve account)")
    func userinfoHttpError() async throws {
        AntigravityMockURLProtocol.handlers = [
            "userinfo": { _ in
                (Data(), HTTPURLResponse(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
            },
        ]
        AntigravityMockURLProtocol.capturedRequests = []

        let connector = AntigravityConnector(
            auth: MockAntigravityCredentialLocator(shouldFail: false, tokenExpired: false),
            session: mockSession()
        )

        let entries = try await connector.fetchUsages()

        // Bootstrap failure before account resolution → no entry written
        #expect(entries.count == 0)
    }

    @Test("userinfo parse error returns empty entries")
    func userinfoParseError() async throws {
        AntigravityMockURLProtocol.handlers = [
            "userinfo": { _ in
                (Data("{}".utf8), HTTPURLResponse(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
        ]
        AntigravityMockURLProtocol.capturedRequests = []

        let connector = AntigravityConnector(
            auth: MockAntigravityCredentialLocator(shouldFail: false, tokenExpired: false),
            session: mockSession()
        )

        let entries = try await connector.fetchUsages()

        // Cannot parse email → cannot resolve account
        #expect(entries.count == 0)
    }

    @Test("loadCodeAssist HTTP error returns empty entries")
    func loadCodeAssistHttpError() async throws {
        AntigravityMockURLProtocol.handlers = [
            "userinfo": { _ in
                (userinfoPaload(), HTTPURLResponse(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            },
            "loadCodeAssist": { _ in
                (Data(), HTTPURLResponse(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
            },
        ]
        AntigravityMockURLProtocol.capturedRequests = []

        let connector = AntigravityConnector(
            auth: MockAntigravityCredentialLocator(shouldFail: false, tokenExpired: false),
            session: mockSession()
        )

        let entries = try await connector.fetchUsages()

        // Bootstrap fails after userinfo succeeds but before we use the account
        #expect(entries.count == 0)
    }
}




