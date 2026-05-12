import Foundation

public actor CopilotStatusConnector: StatusConnector {
    nonisolated public let vendor: Vendor = .copilot

    private let logger: FileLogger
    private let session: URLSession
    private let endpointURLString: String

    public static let defaultEndpoint = "https://www.githubstatus.com/api/v2/incidents/unresolved.json"

    public init(
        logger: FileLogger = Loggers.copilot,
        session: URLSession = .shared,
        endpointURLString: String = CopilotStatusConnector.defaultEndpoint
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
        request.timeoutInterval = CopilotConstants.requestTimeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        logger.log(.debug, "Fetching Copilot status from \(endpointURLString)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.warning, "Copilot status endpoint network error: \(error)")
            throw StatusConnectorError.networkError(underlying: error, url: endpointURLString)
        }

        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard httpCode == 200 else {
            logger.log(.warning, "Copilot status endpoint returned HTTP \(httpCode)")
            throw StatusConnectorError.unexpectedResponse(statusCode: httpCode, url: endpointURLString)
        }

        let decoded: StatuspageIncidentsResponse
        do {
            decoded = try JSONDecoder().decode(StatuspageIncidentsResponse.self, from: data)
        } catch {
            logger.log(.error, "Copilot status endpoint parse error: \(error)")
            throw StatusConnectorError.parseError(underlying: error, url: endpointURLString)
        }

        let outages: [Outage] = decoded.incidents.compactMap { incident in
            // githubstatus.com covers all GitHub services — only surface incidents
            // that explicitly affect a Copilot component.
            let affectsCopilot = incident.components.contains {
                $0.name.localizedCaseInsensitiveContains("copilot")
            }
            guard affectsCopilot else { return nil }
            // "none" impact means informational only — no user-facing effect.
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
        logger.log(.info, "Copilot status: \(outages.count) active outage(s)")
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
        let components: [StatuspageComponent]

        private enum CodingKeys: String, CodingKey {
            case name
            case impact
            case createdAt = "created_at"
            case shortlink
            case components
        }
    }

    private struct StatuspageComponent: Decodable {
        let name: String
    }
}
