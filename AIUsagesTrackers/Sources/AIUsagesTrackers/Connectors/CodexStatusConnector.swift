import Foundation

public actor CodexStatusConnector: StatusConnector {
    nonisolated public let vendor: Vendor = .codex

    private let logger: FileLogger
    private let session: URLSession
    private let endpointURLString: String

    public static let defaultEndpoint = "https://status.openai.com/api/v2/incidents/unresolved.json"

    public init(
        logger: FileLogger = Loggers.codex,
        session: URLSession = .shared,
        endpointURLString: String = CodexStatusConnector.defaultEndpoint
    ) {
        self.logger = logger
        self.session = session
        self.endpointURLString = endpointURLString
    }

    public func fetchOutages() async throws -> [Outage] {
        guard let url = URL(string: endpointURLString) else {
            throw StatusConnectorError.invalidURL(rawValue: endpointURLString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = CodexConstants.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        logger.log(.debug, "Fetching Codex status from \(endpointURLString)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.warning, "Codex status endpoint network error: \(error)")
            throw StatusConnectorError.networkError(underlying: error, url: endpointURLString)
        }

        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard httpCode == 200 else {
            logger.log(.warning, "Codex status endpoint returned HTTP \(httpCode)")
            throw StatusConnectorError.unexpectedResponse(statusCode: httpCode, url: endpointURLString)
        }

        let decoded: StatuspageIncidentsResponse
        do {
            decoded = try JSONDecoder().decode(StatuspageIncidentsResponse.self, from: data)
        } catch {
            logger.log(.error, "Codex status endpoint parse error: \(error)")
            throw StatusConnectorError.parseError(underlying: error, url: endpointURLString)
        }

        let outages: [Outage] = decoded.incidents.compactMap { incident in
            // "none" impact means the incident is informational with no user-facing effect
            guard incident.impact != "none" else { return nil }
            let severity = OutageSeverity(rawValue: incident.impact)
            let href: URL?
            if let raw = incident.shortlink {
                href = URL(string: raw)
            } else {
                href = nil
            }
            return Outage(
                vendor: vendor,
                errorMessage: incident.name,
                severity: severity,
                since: incident.createdAt,
                href: href
            )
        }
        logger.log(.info, "Codex status: \(outages.count) active outage(s)")
        return outages
    }

    // MARK: - DTOs

    private struct StatuspageIncidentsResponse: Decodable {
        let incidents: [StatuspageIncident]
    }

    private struct StatuspageIncident: Decodable {
        let name: String
        let impact: String
        let createdAt: ISODate
        let shortlink: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case impact
            case createdAt = "created_at"
            case shortlink
        }
    }
}
