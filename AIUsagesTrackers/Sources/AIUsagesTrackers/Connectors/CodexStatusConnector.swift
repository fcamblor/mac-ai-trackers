import Foundation

/// Async closure resolving the currently-subscribed component IDs the status
/// connector should retain. `nil` disables filtering entirely — the legacy
/// "no resolver wired" path used by the convenience init and pre-filter
/// tests. An empty set means the filter is wired but nothing is subscribed,
/// so every incident is dropped; only a non-empty set surfaces incidents
/// that overlap with at least one subscribed component.
public typealias SubscribedComponentIDsResolver = @Sendable () async -> Set<StatusComponentID>?

public actor CodexStatusConnector: StatusConnector {
    nonisolated public let vendor: Vendor = .codex

    private let logger: FileLogger
    private let session: URLSession
    private let endpointURLString: String
    private let incidentHrefBase: String
    private let resolveSubscribedComponentIDs: SubscribedComponentIDsResolver

    /// OpenAI moved off statuspage.io to incident.io; the public status page exposes
    /// a JSON document at this path that lists every incident (resolved + active).
    /// We filter by `status != "resolved"` to surface only currently affecting incidents.
    public static let defaultEndpoint = "https://status.openai.com/proxy/status.openai.com/incidents"
    public static let defaultIncidentHrefBase = "https://status.openai.com/incidents/"

    /// Codex group root id observed on `status.openai.com`. Its children are
    /// the user-subscribable components (Codex Web, App, CLI, Codex API, VS
    /// Code extension). Lives on the connector so tests and the registry can
    /// share one source of truth.
    public static let codexGroupRootID: StatusComponentID = "01KMKF9EBTCD8BN9PG8DJZXRSQ"

    /// Convenience init used by production paths that have no resolver wired
    /// yet — keeps the legacy "no filter" behaviour for tests until they opt
    /// into a subscription set.
    public init(
        logger: FileLogger = Loggers.codex,
        session: URLSession = .shared,
        endpointURLString: String = CodexStatusConnector.defaultEndpoint,
        incidentHrefBase: String = CodexStatusConnector.defaultIncidentHrefBase
    ) {
        self.init(
            logger: logger,
            session: session,
            endpointURLString: endpointURLString,
            incidentHrefBase: incidentHrefBase,
            // No resolver supplied → unfiltered. Production wires
            // `StatusComponentRegistry` + `AppPreferences` so this path is
            // only ever taken by tests that pre-date the filter.
            resolveSubscribedComponentIDs: { nil }
        )
    }

    public init(
        logger: FileLogger = Loggers.codex,
        session: URLSession = .shared,
        endpointURLString: String = CodexStatusConnector.defaultEndpoint,
        incidentHrefBase: String = CodexStatusConnector.defaultIncidentHrefBase,
        resolveSubscribedComponentIDs: @escaping SubscribedComponentIDsResolver
    ) {
        self.logger = logger
        self.session = session
        self.endpointURLString = endpointURLString
        self.incidentHrefBase = incidentHrefBase
        self.resolveSubscribedComponentIDs = resolveSubscribedComponentIDs
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

        let decoded: IncidentIOIncidentsResponse
        do {
            decoded = try JSONDecoder().decode(IncidentIOIncidentsResponse.self, from: data)
        } catch {
            logger.log(.error, "Codex status endpoint parse error: \(error)")
            throw StatusConnectorError.parseError(underlying: error, url: endpointURLString)
        }

        let subscribed = await resolveSubscribedComponentIDs()
        let useComponentFilter = subscribed != nil

        var droppedCount = 0
        let outages: [Outage] = decoded.incidents.compactMap { incident in
            // incident.io marks a closed incident with status "resolved" — anything
            // else (investigating / identified / monitoring / scheduled / in_progress)
            // is still affecting the page and should surface to the user.
            guard incident.status.lowercased() != "resolved" else { return nil }

            if useComponentFilter {
                let incidentComponentIDs = Set(
                    incident.affectedComponents.compactMap { $0.componentID }
                )
                let overlap = incidentComponentIDs.intersection(subscribed ?? [])
                if overlap.isEmpty {
                    droppedCount += 1
                    return nil
                }
            }

            let worst = worstComponentStatus(in: incident.affectedComponents)
            let severity = Self.severity(for: incident, worstComponent: worst)
            let href = URL(string: incidentHrefBase + incident.id)
            return Outage(
                vendor: vendor,
                errorMessage: incident.name,
                severity: severity,
                since: incident.publishedAt,
                href: href
            )
        }
        if useComponentFilter && droppedCount > 0 {
            logger.log(
                .debug,
                "Codex status: dropped \(droppedCount) incident(s) with no subscribed component overlap"
            )
        }
        logger.log(.info, "Codex status: \(outages.count) active outage(s)")
        return outages
    }

    private func worstComponentStatus(in components: [IncidentIOAffectedComponent]) -> String? {
        // Order from most to least severe — first match wins so callers can short-circuit.
        let severityRanking: [String] = [
            "full_outage",
            "major_outage",
            "partial_outage",
            "degraded_performance",
            "under_maintenance"
        ]
        for level in severityRanking where components.contains(where: { $0.status.lowercased() == level }) {
            return level
        }
        return components.first?.status
    }

    private static func severity(for incident: IncidentIOIncident, worstComponent: String?) -> OutageSeverity {
        // Maintenance windows declare themselves at the incident level via `type`;
        // operational impact lives on the component statuses for regular incidents.
        if incident.type.lowercased() == "maintenance" {
            return .maintenance
        }
        switch (worstComponent ?? "").lowercased() {
        case "full_outage", "major_outage":
            return .critical
        case "partial_outage":
            return .major
        case "degraded_performance":
            return .minor
        case "under_maintenance":
            return .maintenance
        default:
            return OutageSeverity(rawValue: worstComponent ?? "unknown")
        }
    }

    // MARK: - DTOs

    private struct IncidentIOIncidentsResponse: Decodable {
        let incidents: [IncidentIOIncident]
    }

    private struct IncidentIOIncident: Decodable {
        let id: String
        let name: String
        let status: String
        let type: String
        let publishedAt: ISODate
        let affectedComponents: [IncidentIOAffectedComponent]

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case status
            case type
            case publishedAt = "published_at"
            case affectedComponents = "affected_components"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            status = try container.decode(String.self, forKey: .status)
            type = try container.decodeIfPresent(String.self, forKey: .type) ?? "incident"
            publishedAt = try container.decode(ISODate.self, forKey: .publishedAt)
            affectedComponents = try container.decodeIfPresent(
                [IncidentIOAffectedComponent].self, forKey: .affectedComponents
            ) ?? []
        }
    }

    private struct IncidentIOAffectedComponent: Decodable {
        let status: String
        /// `component_id` is present on the incident.io payload but optional
        /// in this DTO so older fixtures without it still decode (the filter
        /// then drops the incident as if no overlap existed).
        let componentID: StatusComponentID?

        private enum CodingKeys: String, CodingKey {
            case status
            case componentID = "component_id"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(String.self, forKey: .status)
            if let raw = try container.decodeIfPresent(String.self, forKey: .componentID) {
                componentID = StatusComponentID(rawValue: raw)
            } else {
                componentID = nil
            }
        }
    }
}
