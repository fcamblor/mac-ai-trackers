import Foundation
import os
import Testing
@testable import AIUsagesTrackersLib

// URLProtocol is Foundation-owned; mutable mock state is protected by the lock.
// swiftlint:disable:next w4_unchecked_sendable
private final class BillingURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case http(Int, String)
        case stalled
    }

    struct State: Sendable {
        var replies: [String: Reply] = [:]
        var paths: [String] = []
        var cancellations = 0
    }

    static let state = OSAllocatedUnfairLock(initialState: State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.state.withLock { state in
            let path = request.url?.path ?? ""
            state.paths.append(path)
            return state.replies[path] ?? .http(404, "{}")
        }
        guard case let .http(status, body) = reply, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.state.withLock { $0.cancellations += 1 }
    }
}

@Suite("Copilot organization billing", .serialized)
struct CopilotOrgBillingClientTests {
    private static let listPath = "/user/orgs"
    private static let firstOrgPath = "/orgs/first/settings/billing/usage/summary"
    private static let secondOrgPath = "/orgs/second/settings/billing/usage/summary"
    private static let organizations = #"[{"login":"first"},{"login":"second"}]"#
    private static let usage = #"{"usageItems":[{"product":"Copilot","unitType":"ai-credits","grossQuantity":25,"netAmount":0.25}]}"#
    private static let shortBudget: Duration = .milliseconds(50)
    private static let afterCooldown: TimeInterval = 16 * 60

    private func makeClient(
        replies: [String: BillingURLProtocol.Reply],
        clock: @escaping @Sendable () -> Date = { Date() },
        timeout: Duration = .seconds(5)
    ) -> CopilotOrgBillingClient {
        BillingURLProtocol.state.withLock { $0 = .init(replies: replies) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillingURLProtocol.self]
        let logger = FileLogger(filePath: NSTemporaryDirectory() + UUID().uuidString + ".log", minLevel: .debug)
        return CopilotOrgBillingClient(
            session: URLSession(configuration: configuration), logger: logger, clock: clock, lookupTimeout: timeout
        )
    }

    @Test("readable billing is cached, then refreshed through the known organization")
    func successfulCache() async throws {
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let client = makeClient(replies: [
            Self.listPath: .http(200, Self.organizations),
            Self.firstOrgPath: .http(403, "{}"),
            Self.secondOrgPath: .http(200, Self.usage)
        ], clock: { clock.withLock { $0 } })
        let metrics = await client.metrics(for: "user", token: "fake")
        #expect(metrics == [
            .payAsYouGo(name: "Org Credits", currentAmount: 25, currency: "credits"),
            .payAsYouGo(name: "Org Spend", currentAmount: 0.25, currency: "USD")
        ])
        #expect(await client.metrics(for: "user", token: "fake") == metrics)
        #expect(BillingURLProtocol.state.withLock { $0.paths.count } == 3)
        clock.withLock { $0 = $0.addingTimeInterval(Self.afterCooldown) }
        #expect(await client.metrics(for: "user", token: "fake") == metrics)
        #expect(BillingURLProtocol.state.withLock { $0.paths } == [
            Self.listPath, Self.firstOrgPath, Self.secondOrgPath, Self.secondOrgPath
        ])
        _ = try JSONEncoder().encode(metrics)
    }

    @Test("unreadable billing is not rediscovered on every poll")
    func failedLookupCooldown() async {
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let client = makeClient(replies: [Self.listPath: .http(403, "{}")], clock: { clock.withLock { $0 } })
        #expect(await client.metrics(for: "user", token: "fake").isEmpty)
        #expect(await client.metrics(for: "user", token: "fake").isEmpty)
        #expect(BillingURLProtocol.state.withLock { $0.paths.count } == 1)
        clock.withLock { $0 = $0.addingTimeInterval(Self.afterCooldown) }
        #expect(await client.metrics(for: "user", token: "fake").isEmpty)
        #expect(BillingURLProtocol.state.withLock { $0.paths.count } == 2)
    }

    @Test("a stalled request is cancelled by the total lookup budget")
    func totalBudgetCancelsRequest() async throws {
        let client = makeClient(replies: [Self.listPath: .stalled], timeout: Self.shortBudget)
        #expect(await client.metrics(for: "user", token: "fake").isEmpty)
        try await eventually { BillingURLProtocol.state.withLock { $0.cancellations > 0 } }
        #expect(await client.metrics(for: "user", token: "fake").isEmpty)
        #expect(BillingURLProtocol.state.withLock { $0.paths.count } == 1)
    }

    @Test("rate limiting stops organization discovery")
    func rateLimitStopsSweep() async {
        let client = makeClient(replies: [
            Self.listPath: .http(200, Self.organizations),
            Self.firstOrgPath: .http(429, "{}"),
            Self.secondOrgPath: .http(200, Self.usage)
        ])
        #expect(await client.metrics(for: "user", token: "fake").isEmpty)
        #expect(BillingURLProtocol.state.withLock { $0.paths } == [Self.listPath, Self.firstOrgPath])
    }

    @Test("overflowing optional totals cannot poison persistence")
    func overflowingTotals() async throws {
        let client = makeClient(replies: [
            Self.listPath: .http(200, #"[{"login":"first"}]"#),
            Self.firstOrgPath: .http(200, #"{"usageItems":[{"product":"Copilot","unitType":"ai-credits","grossQuantity":1e308},{"product":"Copilot","unitType":"ai-credits","grossQuantity":1e308}]}"#)
        ])
        let metrics = await client.metrics(for: "user", token: "fake")
        #expect(metrics.isEmpty)
        _ = try JSONEncoder().encode(metrics)
    }
}
