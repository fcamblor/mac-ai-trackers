import Foundation
import Testing
@testable import AIUsagesTrackersLib

private struct StubDesktopLocator: CredentialLocator {
    typealias Credentials = [ClaudeDesktopCredential]
    let credentials: [ClaudeDesktopCredential]
    func locate() async throws -> [ClaudeDesktopCredential] { credentials }
}

private struct StubProfileResolver: ClaudeProfileResolving {
    let email: AccountEmail?
    func resolveEmail(accessToken: String) async -> AccountEmail? { email }
}

private struct StubProcessInspector: ClaudeDesktopProcessInspecting {
    let active: Set<String>
    func activeProfilePaths() async -> Set<String> { active }
}

// Dedicated URLProtocol so this suite's mock state never races the shared
// MockURLProtocol that other connector suites mutate in parallel.
// swiftlint:disable:next w4_unchecked_sendable — URLProtocol subclass; mutable static state accessed only from the serialized ClaudeDesktopConnector suite
final class DesktopMockURLProtocol: URLProtocol, @unchecked Sendable {
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

private func desktopMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DesktopMockURLProtocol.self]
    return URLSession(configuration: config)
}

@Suite("ClaudeDesktopConnector", .serialized)
struct ClaudeDesktopConnectorTests {
    private func credential(label: String = "Perso", uuid: String? = "uuid-1", dir: String = "/tmp/Perso", expiresAt: Date? = nil) -> ClaudeDesktopCredential {
        ClaudeDesktopCredential(accountLabel: label, accountUuid: uuid, profileDirectoryPath: dir, accessToken: "tok", expiresAt: expiresAt, subscriptionType: "pro")
    }

    @Test("disabled source returns no entries and never calls the locator")
    func disabledReturnsEmpty() async throws {
        DesktopMockURLProtocol.handler = nil
        let connector = ClaudeDesktopConnector(
            session: desktopMockSession(),
            credentialLocator: StubDesktopLocator(credentials: [credential()]),
            profileResolver: StubProfileResolver(email: nil),
            processInspector: StubProcessInspector(active: []),
            isEnabled: { false }
        )
        let entries = try await connector.fetchUsages()
        #expect(entries.isEmpty)
    }

    @Test("enabled success path emits a per-account entry with breakdown metrics")
    func successPathWithBreakdown() async throws {
        let fixture = FixtureLoader.load("claude-desktop-full-payload")
        DesktopMockURLProtocol.handler = { request in
            (fixture, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let connector = ClaudeDesktopConnector(
            session: desktopMockSession(),
            credentialLocator: StubDesktopLocator(credentials: [credential(label: "Perso")]),
            profileResolver: StubProfileResolver(email: nil),
            processInspector: StubProcessInspector(active: []),
            isEnabled: { true }
        )
        let entries = try await connector.fetchUsages()
        #expect(entries.count == 1)
        // Profile resolution returned nil → identity falls back to the label.
        #expect(entries[0].account == AccountEmail(rawValue: "Perso"))
        #expect(entries[0].lastError == nil)
        let names = entries[0].metrics.compactMap { metric -> String? in
            if case let .timeWindow(name, _, _, _) = metric { return name }
            return nil
        }
        #expect(names.contains("Weekly share · Cowork"))
    }

    @Test("resolved profile email becomes the account identity")
    func resolvedEmailIsIdentity() async throws {
        let fixture = FixtureLoader.load("claude-desktop-full-payload")
        DesktopMockURLProtocol.handler = { request in
            (fixture, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let connector = ClaudeDesktopConnector(
            session: desktopMockSession(),
            credentialLocator: StubDesktopLocator(credentials: [credential(label: "Default")]),
            profileResolver: StubProfileResolver(email: AccountEmail(rawValue: "frederic.camblor@4sh.fr")),
            processInspector: StubProcessInspector(active: []),
            isEnabled: { true }
        )
        let entries = try await connector.fetchUsages()
        #expect(entries.count == 1)
        #expect(entries[0].account == AccountEmail(rawValue: "frederic.camblor@4sh.fr"))
    }

    @Test("entry is active when its profile directory has a running app")
    func activeWhenProfileRunning() async throws {
        let fixture = FixtureLoader.load("claude-desktop-full-payload")
        DesktopMockURLProtocol.handler = { request in
            (fixture, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let connector = ClaudeDesktopConnector(
            session: desktopMockSession(),
            credentialLocator: StubDesktopLocator(credentials: [
                credential(label: "Perso", dir: "/tmp/Perso"),
                credential(label: "Idle", uuid: "uuid-2", dir: "/tmp/Idle"),
            ]),
            profileResolver: StubProfileResolver(email: nil),
            processInspector: StubProcessInspector(active: ["/tmp/Perso"]),
            isEnabled: { true }
        )
        let entries = try await connector.fetchUsages()
        let perso = entries.first { $0.account == AccountEmail(rawValue: "Perso") }
        let idle = entries.first { $0.account == AccountEmail(rawValue: "Idle") }
        #expect(perso?.isActive == true)
        #expect(idle?.isActive == false)
    }

    @Test("expired token short-circuits with token_expired and no HTTP call")
    func expiredTokenSkipsHTTP() async throws {
        DesktopMockURLProtocol.handler = { _ in
            Issue.record("HTTP must not be called for an expired token")
            return (Data(), HTTPURLResponse())
        }
        let past = Date(timeIntervalSinceNow: -3600)
        let connector = ClaudeDesktopConnector(
            session: desktopMockSession(),
            credentialLocator: StubDesktopLocator(credentials: [credential(label: "Perso", expiresAt: past)]),
            profileResolver: StubProfileResolver(email: nil),
            processInspector: StubProcessInspector(active: []),
            isEnabled: { true }
        )
        let entries = try await connector.fetchUsages()
        #expect(entries.count == 1)
        #expect(entries[0].lastError?.type == "token_expired")
    }
}
