import Foundation
import Testing
@testable import AIUsagesTrackersLib

// Dedicated mock for this suite — avoids static-state collisions with other serialized suites.
// swiftlint:disable:next w4_unchecked_sendable — URLProtocol subclass; static state accessed only from this @Suite(.serialized) suite
final class CopilotStatusMockURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("CopilotStatusConnector", .serialized)
struct CopilotStatusConnectorTests {
    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-copilot-status-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CopilotStatusMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeConnector(dir: String) -> CopilotStatusConnector {
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        return CopilotStatusConnector(
            logger: logger,
            session: mockSession()
        )
    }

    private func mockHTTP(status: Int, body: String) {
        CopilotStatusMockURLProtocol.errorToThrow = nil
        CopilotStatusMockURLProtocol.handler = { _ in
            let data = body.data(using: .utf8)!
            let resp = HTTPURLResponse(
                url: URL(string: "https://www.githubstatus.com")!,
                statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (data, resp)
        }
    }

    @Test("Copilot-component incident maps to a single Outage with all fields")
    func singleCopilotIncident() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {
              "name": "Copilot Chat degraded",
              "impact": "major",
              "created_at": "2026-04-22T10:15:00.000Z",
              "shortlink": "https://stspg.io/abc123",
              "components": [
                {"name": "Copilot"}
              ]
            }
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()

        #expect(outages.count == 1)
        #expect(outages[0].vendor == .copilot)
        #expect(outages[0].errorMessage == "Copilot Chat degraded")
        #expect(outages[0].severity == .major)
        #expect(outages[0].since.rawValue == "2026-04-22T10:15:00.000Z")
        #expect(outages[0].href?.absoluteString == "https://stspg.io/abc123")
    }

    @Test("incident affecting only non-Copilot components is filtered out")
    func unrelatedComponentFiltered() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {
              "name": "Actions queue backlog",
              "impact": "major",
              "created_at": "2026-04-22T10:00:00Z",
              "shortlink": "https://x.com",
              "components": [
                {"name": "Actions"},
                {"name": "API Requests"}
              ]
            }
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.isEmpty)
    }

    @Test("component name matching is case-insensitive and surfaces AI Model Providers")
    func copilotMatchIsCaseInsensitive() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {
              "name": "Upstream model slowness",
              "impact": "minor",
              "created_at": "2026-04-22T11:00:00Z",
              "shortlink": "https://y.com",
              "components": [
                {"name": "Copilot AI Model Providers"}
              ]
            },
            {
              "name": "lowercase match",
              "impact": "minor",
              "created_at": "2026-04-22T12:00:00Z",
              "shortlink": "https://z.com",
              "components": [
                {"name": "copilot extensions"}
              ]
            }
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.count == 2)
    }

    @Test("incident with impact=none is filtered out even on a Copilot component")
    func noneImpactFiltered() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {
              "name": "informational",
              "impact": "none",
              "created_at": "2026-04-22T10:00:00Z",
              "shortlink": "https://x.com",
              "components": [{"name": "Copilot"}]
            },
            {
              "name": "real issue",
              "impact": "critical",
              "created_at": "2026-04-22T11:00:00Z",
              "shortlink": "https://y.com",
              "components": [{"name": "Copilot"}]
            }
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.count == 1)
        #expect(outages[0].errorMessage == "real issue")
        #expect(outages[0].severity == .critical)
    }

    @Test("missing shortlink results in href=nil without throwing")
    func missingShortlink() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {
              "name": "x",
              "impact": "major",
              "created_at": "2026-04-22T10:00:00Z",
              "components": [{"name": "Copilot"}]
            }
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.count == 1)
        #expect(outages[0].href == nil)
    }

    @Test("empty incidents array returns empty list")
    func emptyIncidents() async throws {
        let dir = try makeTempDir()
        mockHTTP(status: 200, body: #"{"incidents":[]}"#)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.isEmpty)
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
        CopilotStatusMockURLProtocol.handler = nil
        CopilotStatusMockURLProtocol.errorToThrow = URLError(.notConnectedToInternet)
        defer { CopilotStatusMockURLProtocol.errorToThrow = nil }

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
