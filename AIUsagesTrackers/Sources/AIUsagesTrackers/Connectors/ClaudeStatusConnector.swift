import Foundation

public actor ClaudeStatusConnector: StatusConnector {
    nonisolated public let vendor: Vendor = .claude

    private let logger: FileLogger
    private let session: URLSession
    private let endpointURLString: String

    private static let requestTimeoutSeconds: TimeInterval = 5
    public static let defaultEndpoint = "https://status.anthropic.com/api/v2/incidents/unresolved.json"

    public init(
        logger: FileLogger = Loggers.claude,
        session: URLSession = .shared,
        endpointURLString: String = ClaudeStatusConnector.defaultEndpoint
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
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        logger.log(.debug, "Fetching Claude status from \(endpointURLString)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.warning, "Status endpoint network error: \(error)")
            throw StatusConnectorError.networkError(underlying: error, url: endpointURLString)
        }

        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard httpCode == 200 else {
            logger.log(.warning, "Status endpoint returned HTTP \(httpCode)")
            throw StatusConnectorError.unexpectedResponse(statusCode: httpCode, url: endpointURLString)
        }

        let decoded: StatuspageIncidentsResponse
        do {
            decoded = try JSONDecoder().decode(StatuspageIncidentsResponse.self, from: data)
        } catch {
            logger.log(.error, "Status endpoint parse error: \(error)")
            throw StatusConnectorError.parseError(underlying: error, url: endpointURLString)
        }

        let outages: [Outage] = decoded.incidents.compactMap { incident in
            // "none" impact means the incident is informational with no user-facing effect —
            // don't surface it as an outage in the UI.
            guard incident.impact != "none" else { return nil }
            let severity = OutageSeverity(rawValue: incident.impact)
            // Invalid shortlink must not drop the incident itself — surface it without href.
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
                since: ISODate(rawValue: incident.created_at),
                href: href
            )
        }
        logger.log(.info, "Claude status: \(outages.count) active outage(s)")
        return outages
    }

    // MARK: - DTOs

    private struct StatuspageIncidentsResponse: Decodable {
        let incidents: [StatuspageIncident]
    }

    private struct StatuspageIncident: Decodable {
        let name: String
        let impact: String
        let created_at: String
        let shortlink: String?
    }
}
