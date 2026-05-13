import Foundation
import Testing
@testable import AIUsagesTrackersLib

// swiftlint:disable:next w4_unchecked_sendable — URLProtocol subclass; static state accessed only from this @Suite(.serialized) suite
final class CodexStatusFilterMockURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("CodexStatusConnector — component subscription filter", .serialized)
struct CodexStatusConnectorFilterTests {
    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-codex-filter-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CodexStatusFilterMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func mockHTTP(body: String) {
        CodexStatusFilterMockURLProtocol.handler = { _ in
            let data = body.data(using: .utf8)!
            let resp = HTTPURLResponse(
                url: URL(string: "https://status.openai.com")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (data, resp)
        }
    }

    private static let audioIncident = """
    {
      "id": "01KRG0AZKH41DV4D9SNJSXM33Q",
      "name": "Realtime / Audio degraded",
      "status": "investigating",
      "type": "incident",
      "published_at": "2026-05-12T16:00:00Z",
      "affected_components": [
        {"component_id": "01AUDIO00000000000000000A", "status": "degraded_performance"}
      ]
    }
    """

    private static let codexWebIncident = """
    {
      "id": "01CODEXWEBINCIDENT00000001",
      "name": "Codex Web slow",
      "status": "investigating",
      "type": "incident",
      "published_at": "2026-05-12T17:00:00Z",
      "affected_components": [
        {"component_id": "01JVCV8YSWZFRSM1G5CVP253SK", "status": "partial_outage"}
      ]
    }
    """

    private static let codexWebID: StatusComponentID = "01JVCV8YSWZFRSM1G5CVP253SK"

    @Test("nil resolver means 'no filter wired' and lets every incident through")
    func nilResolverPassesThrough() async throws {
        let dir = try makeTempDir()
        mockHTTP(body: "{\"incidents\":[\(Self.audioIncident),\(Self.codexWebIncident)]}")
        let connector = CodexStatusConnector(
            logger: FileLogger(filePath: "\(dir)/test.log", minLevel: .debug),
            session: mockSession(),
            resolveSubscribedComponentIDs: { nil }
        )
        let outages = try await connector.fetchOutages()
        #expect(outages.count == 2)
    }

    @Test("empty subscription set drops every incident")
    func emptySubscriptionDropsAll() async throws {
        let dir = try makeTempDir()
        mockHTTP(body: "{\"incidents\":[\(Self.audioIncident),\(Self.codexWebIncident)]}")
        let connector = CodexStatusConnector(
            logger: FileLogger(filePath: "\(dir)/test.log", minLevel: .debug),
            session: mockSession(),
            resolveSubscribedComponentIDs: { Set<StatusComponentID>() }
        )
        let outages = try await connector.fetchOutages()
        #expect(outages.isEmpty)
    }

    @Test("incident affecting only an unsubscribed component is dropped")
    func unrelatedIncidentDropped() async throws {
        let dir = try makeTempDir()
        mockHTTP(body: "{\"incidents\":[\(Self.audioIncident)]}")
        let connector = CodexStatusConnector(
            logger: FileLogger(filePath: "\(dir)/test.log", minLevel: .debug),
            session: mockSession(),
            resolveSubscribedComponentIDs: { [Self.codexWebID] }
        )
        let outages = try await connector.fetchOutages()
        #expect(outages.isEmpty)
    }

    @Test("incident affecting a subscribed component is retained")
    func subscribedIncidentRetained() async throws {
        let dir = try makeTempDir()
        mockHTTP(body: "{\"incidents\":[\(Self.audioIncident),\(Self.codexWebIncident)]}")
        let connector = CodexStatusConnector(
            logger: FileLogger(filePath: "\(dir)/test.log", minLevel: .debug),
            session: mockSession(),
            resolveSubscribedComponentIDs: { [Self.codexWebID] }
        )
        let outages = try await connector.fetchOutages()
        #expect(outages.count == 1)
        #expect(outages[0].errorMessage == "Codex Web slow")
    }

    @Test("incident with no component_id is dropped when filter is active")
    func incidentWithoutComponentIDDropped() async throws {
        let dir = try makeTempDir()
        let unscopedIncident = """
        {
          "id": "01UNSCOPED0000000000000001",
          "name": "Unscoped notice",
          "status": "investigating",
          "type": "incident",
          "published_at": "2026-05-12T16:00:00Z",
          "affected_components": []
        }
        """
        mockHTTP(body: "{\"incidents\":[\(unscopedIncident)]}")
        let connector = CodexStatusConnector(
            logger: FileLogger(filePath: "\(dir)/test.log", minLevel: .debug),
            session: mockSession(),
            resolveSubscribedComponentIDs: { [Self.codexWebID] }
        )
        let outages = try await connector.fetchOutages()
        #expect(outages.isEmpty)
    }
}
