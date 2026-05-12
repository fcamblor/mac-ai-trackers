import Foundation
import Testing
@testable import AIUsagesTrackersLib

// Dedicated mock for this suite — avoids static-state collisions with other serialized suites.
// swiftlint:disable:next w4_unchecked_sendable — URLProtocol subclass; static state accessed only from this @Suite(.serialized) suite
final class CodexStatusMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?
    nonisolated(unsafe) static var errorToThrow: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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

@Suite("CodexStatusConnector", .serialized)
struct CodexStatusConnectorTests {
    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-codex-status-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CodexStatusMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeConnector(dir: String) -> CodexStatusConnector {
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        return CodexStatusConnector(
            logger: logger,
            session: mockSession()
        )
    }

    private func mockHTTP(status: Int, body: String) {
        CodexStatusMockURLProtocol.errorToThrow = nil
        CodexStatusMockURLProtocol.handler = { _ in
            let data = body.data(using: .utf8)!
            let resp = HTTPURLResponse(
                url: URL(string: "https://status.openai.com")!,
                statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (data, resp)
        }
    }

    @Test("active investigating incident maps to a single Outage with severity from worst component")
    func activeInvestigatingIncident() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {
              "id": "01ABC",
              "name": "Elevated error rates with GPT 5.5",
              "status": "investigating",
              "type": "incident",
              "published_at": "2026-05-11T16:11:00Z",
              "affected_components": [
                {"status": "degraded_performance", "current_status": "degraded_performance"},
                {"status": "partial_outage", "current_status": "partial_outage"}
              ]
            }
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()

        #expect(outages.count == 1)
        #expect(outages[0].vendor == .codex)
        #expect(outages[0].errorMessage == "Elevated error rates with GPT 5.5")
        #expect(outages[0].severity == .major) // partial_outage is worse than degraded_performance
        #expect(outages[0].since.rawValue == "2026-05-11T16:11:00Z")
        #expect(outages[0].href?.absoluteString == "https://status.openai.com/incidents/01ABC")
    }

    @Test("resolved incidents are filtered out")
    func resolvedFiltered() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {
              "id": "01OLD",
              "name": "Yesterday's incident",
              "status": "resolved",
              "type": "incident",
              "published_at": "2026-05-10T10:00:00Z",
              "affected_components": [{"status": "full_outage", "current_status": "operational"}]
            },
            {
              "id": "01NEW",
              "name": "Current monitoring",
              "status": "monitoring",
              "type": "incident",
              "published_at": "2026-05-11T11:00:00Z",
              "affected_components": [{"status": "degraded_performance", "current_status": "degraded_performance"}]
            }
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.count == 1)
        #expect(outages[0].errorMessage == "Current monitoring")
        #expect(outages[0].severity == .minor)
    }

    @Test("full_outage on any component yields critical severity")
    func fullOutageCritical() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {
              "id": "01CRIT",
              "name": "Major outage",
              "status": "identified",
              "type": "incident",
              "published_at": "2026-05-11T16:11:00Z",
              "affected_components": [
                {"status": "degraded_performance", "current_status": "degraded_performance"},
                {"status": "full_outage", "current_status": "full_outage"}
              ]
            }
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.count == 1)
        #expect(outages[0].severity == .critical)
    }

    @Test("maintenance type maps to maintenance severity regardless of component status")
    func maintenanceType() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {
              "id": "01MAINT",
              "name": "Scheduled DB upgrade",
              "status": "in_progress",
              "type": "maintenance",
              "published_at": "2026-05-11T16:11:00Z",
              "affected_components": [
                {"status": "full_outage", "current_status": "full_outage"}
              ]
            }
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.count == 1)
        #expect(outages[0].severity == .maintenance)
    }

    @Test("incident with empty affected_components still surfaces with passthrough severity")
    func emptyAffectedComponents() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {
              "id": "01EMPTY",
              "name": "Unscoped notice",
              "status": "investigating",
              "type": "incident",
              "published_at": "2026-05-11T16:11:00Z",
              "affected_components": []
            }
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.count == 1)
        #expect(outages[0].errorMessage == "Unscoped notice")
        // No component status to map → passthrough preserves "unknown" string
        #expect(outages[0].severity.rawValue == "unknown")
    }

    @Test("empty incidents array returns empty list")
    func emptyIncidents() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: #"{"incidents":[]}"#)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.isEmpty)
    }

    @Test("missing type field defaults to incident")
    func missingTypeDefaults() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {
              "id": "01NOTYPE",
              "name": "No type field",
              "status": "investigating",
              "published_at": "2026-05-11T16:11:00Z",
              "affected_components": [{"status": "partial_outage", "current_status": "partial_outage"}]
            }
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.count == 1)
        #expect(outages[0].severity == .major)
    }

    @Test("HTTP 500 throws unexpectedResponse")
    func httpErrorThrows() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 500, body: "")
        await #expect(throws: StatusConnectorError.self) {
            try await self.makeConnector(dir: dir).fetchOutages()
        }
    }

    @Test("network error throws networkError")
    func networkErrorThrows() async throws {
        let dir = try makeTempDir()
        CodexStatusMockURLProtocol.handler = nil
        CodexStatusMockURLProtocol.errorToThrow = URLError(.notConnectedToInternet)
        defer { CodexStatusMockURLProtocol.errorToThrow = nil }

        await #expect(throws: StatusConnectorError.self) {
            try await self.makeConnector(dir: dir).fetchOutages()
        }
    }

    @Test("malformed JSON throws parseError")
    func malformedJSONThrows() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: "{not json")
        await #expect(throws: StatusConnectorError.self) {
            try await self.makeConnector(dir: dir).fetchOutages()
        }
    }
}
