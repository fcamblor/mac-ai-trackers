import Foundation
import Testing
@testable import AIUsagesTrackersLib

// Dedicated mock protocol for this suite — avoids the shared static state of
// `MockURLProtocol` colliding with the Claude *usage* connector tests, which
// run in a different serialized suite but may overlap across suites.
// swiftlint:disable:next w4_unchecked_sendable — URLProtocol subclass; static state accessed only from this @Suite(.serialized) suite
final class StatusMockURLProtocol: URLProtocol, @unchecked Sendable {
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

@Suite("ClaudeStatusConnector", .serialized)
struct ClaudeStatusConnectorTests {
    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-claude-status-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StatusMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeConnector(dir: String) -> ClaudeStatusConnector {
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        return ClaudeStatusConnector(
            logger: logger,
            session: mockSession(),
            endpointURLString: "https://status.anthropic.com/api/v2/incidents/unresolved.json"
        )
    }

    private func mockHTTP(status: Int, body: String) {
        StatusMockURLProtocol.errorToThrow = nil
        StatusMockURLProtocol.handler = { _ in
            let data = body.data(using: .utf8)!
            let resp = HTTPURLResponse(
                url: URL(string: "https://status.anthropic.com")!,
                statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (data, resp)
        }
    }

    @Test("one major incident maps to a single Outage with all fields")
    func singleMajorIncident() async throws {
        let dir = makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {
              "name": "Elevated errors on /v1/messages",
              "impact": "major",
              "created_at": "2026-04-22T10:15:00.000Z",
              "shortlink": "https://stspg.io/abc123"
            }
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()

        #expect(outages.count == 1)
        #expect(outages[0].vendor == .claude)
        #expect(outages[0].errorMessage == "Elevated errors on /v1/messages")
        #expect(outages[0].severity == .major)
        #expect(outages[0].since.rawValue == "2026-04-22T10:15:00.000Z")
        #expect(outages[0].href?.absoluteString == "https://stspg.io/abc123")
    }

    @Test("empty incidents array returns empty list")
    func emptyIncidents() async throws {
        let dir = makeTempDir()
        mockHTTP(status: 200, body: #"{"incidents":[]}"#)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.isEmpty)
    }

    @Test("incident with impact=none is filtered out")
    func noneImpactFiltered() async throws {
        let dir = makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {"name":"minor notice","impact":"none","created_at":"2026-04-22T10:00:00Z","shortlink":"https://x.com"},
            {"name":"real issue","impact":"minor","created_at":"2026-04-22T11:00:00Z","shortlink":"https://y.com"}
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.count == 1)
        #expect(outages[0].errorMessage == "real issue")
    }

    @Test("missing shortlink results in href=nil without throwing")
    func missingShortlink() async throws {
        let dir = makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {"name":"x","impact":"major","created_at":"2026-04-22T10:00:00Z"}
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.count == 1)
        #expect(outages[0].href == nil)
    }

    @Test("unknown impact value passes through via OutageSeverity(rawValue:)")
    func unknownImpactPassthrough() async throws {
        let dir = makeTempDir()
        mockHTTP(status: 200, body: """
        {
          "incidents": [
            {"name":"x","impact":"catastrophic","created_at":"2026-04-22T10:00:00Z","shortlink":"https://x.com"}
          ]
        }
        """)
        let outages = try await makeConnector(dir: dir).fetchOutages()
        #expect(outages.count == 1)
        #expect(outages[0].severity.rawValue == "catastrophic")
    }

    @Test("HTTP 500 throws unexpectedResponse")
    func httpErrorThrows() async {
        let dir = makeTempDir()
        mockHTTP(status: 500, body: "")
        await #expect(throws: StatusConnectorError.self) {
            try await self.makeConnector(dir: dir).fetchOutages()
        }
    }

    @Test("network error throws networkError")
    func networkErrorThrows() async {
        let dir = makeTempDir()
        StatusMockURLProtocol.handler = nil
        StatusMockURLProtocol.errorToThrow = URLError(.notConnectedToInternet)
        defer { StatusMockURLProtocol.errorToThrow = nil }

        await #expect(throws: StatusConnectorError.self) {
            try await self.makeConnector(dir: dir).fetchOutages()
        }
    }

    @Test("malformed JSON throws parseError")
    func malformedJSONThrows() async {
        let dir = makeTempDir()
        mockHTTP(status: 200, body: "{not json")
        await #expect(throws: StatusConnectorError.self) {
            try await self.makeConnector(dir: dir).fetchOutages()
        }
    }
}
