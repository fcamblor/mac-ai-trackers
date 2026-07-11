import Foundation
import os

public actor AntigravityConnector: UsageConnector {
    nonisolated public let vendor: Vendor = .antigravity

    private let auth: any CredentialLocator<AntigravityCredentials>
    private let logger: FileLogger
    private let session: URLSession
    private let sanitizer: AntigravityPayloadSanitizer

    // Thread-safe account identity cache readable from nonisolated resolveActiveAccount()
    private let _cachedAccount = OSAllocatedUnfairLock<AccountEmail?>(initialState: nil)
    private let _knownAccounts = OSAllocatedUnfairLock<[AccountEmail]>(initialState: [])
    private var lastKnownMetricsByAccount: [AccountEmail: [UsageMetric]] = [:]

    // OAuth state cache: refreshed once per token lifetime
    private var cachedUserInfo: UserinfoResponse?
    private var cachedProjectId: String?
    private var cachedModelCatalogue: [String: ModelInfo] = [:]
    private var cachedCatalogueRefresh: Date?

    // Memoises the window duration last resolved for each `modelId`. Internal
    // models (chat_*, tab_*) and freshly-rolled buckets ship without a
    // `resetTime`, so without this fallback they collapse to "Unknown" even
    // after we've previously seen them in a typed cohort. The map is keyed on
    // `modelId` rather than display name because Antigravity ships several
    // model aliases that map to the same display label.
    private var lastKnownWindowByModel: [String: DurationMinutes] = [:]

    // Memoises the cohort metric name last assigned to each `modelId`. Names
    // must remain stable across polls because they are referenced by id from
    // menu hints and chart configurations. When a cohort rolls over (its
    // resetAt elapses and a fresh window opens) the new cohort inherits the
    // previous name as long as it shares at least one modelId with the old
    // one. Disjoint cohorts that collide on baseName ("Weekly", "5h sessions")
    // are disambiguated with a "#N" increment.
    private var lastKnownCohortNameByModel: [String: String] = [:]

    private static let requestTimeoutSeconds = 5.0
    private static let fiveHourWindowMinutes = 5 * 60
    private static let weeklyWindowMinutes = 7 * 24 * 60
    private static let fiveHourThresholdSeconds: TimeInterval = 6 * 3600

    public init(
        auth: any CredentialLocator<AntigravityCredentials> = AntigravityCredentialLocator(),
        logger: FileLogger = Loggers.antigravity,
        session: URLSession = .shared,
        sanitizer: AntigravityPayloadSanitizer = AntigravityPayloadSanitizer()
    ) {
        self.auth = auth
        self.logger = logger
        self.session = session
        self.sanitizer = sanitizer
    }

    // MARK: - UsageConnector

    nonisolated public func resolveActiveAccount() -> AccountEmail? {
        _cachedAccount.withLock { $0 }
    }

    nonisolated public func knownAccounts() -> [AccountEmail] {
        _knownAccounts.withLock { $0 }
    }

    public func invalidateLoginCache() {
        _cachedAccount.withLock { $0 = nil }
        _knownAccounts.withLock { $0 = [] }
        cachedUserInfo = nil
        cachedProjectId = nil
        cachedModelCatalogue = [:]
        cachedCatalogueRefresh = nil
        lastKnownMetricsByAccount = [:]
        lastKnownWindowByModel = [:]
        lastKnownCohortNameByModel = [:]
        logger.log(.info, "Antigravity credential cache invalidated")
    }

    public func fetchUsages() async throws -> [VendorUsageEntry] {
        let credentials: AntigravityCredentials
        do {
            credentials = try await auth.locate()
        } catch {
            logger.log(.error, "Antigravity credentials load failed: \(error)")
            _knownAccounts.withLock { $0 = [] }
            return errorEntries(type: Self.credentialErrorType(for: error))
        }

        // Bootstrap path: userinfo + loadCodeAssist + fetchAvailableModels
        let userInfo: UserinfoResponse
        let projectId: String
        do {
            userInfo = try await fetchUserinfo(token: credentials.accessToken)
            let loadResponse = try await fetchLoadCodeAssist(token: credentials.accessToken)
            projectId = loadResponse.cloudaicompanionProject
            cachedUserInfo = userInfo
            cachedProjectId = projectId
        } catch {
            logger.log(.error, "Antigravity bootstrap failed: \(error)")
            _knownAccounts.withLock { $0 = [] }
            return errorEntries(type: "credential_error")
        }

        let account = AccountEmail(rawValue: userInfo.email)
        _cachedAccount.withLock { $0 = account }

        // Refresh model catalogue if any bucket has an unknown modelId
        try await refreshModelCatalogueIfNeeded(
            token: credentials.accessToken,
            projectId: projectId
        )

        // Fetch quotas (main payload per tick)
        let quotas: RetrieveUserQuotaResponse
        do {
            quotas = try await fetchRetrieveUserQuota(
                token: credentials.accessToken,
                projectId: projectId
            )
        } catch {
            logger.log(.error, "Antigravity quota fetch failed: \(error)")
            return [errorEntry(
                type: "api_error",
                account: account,
                isActive: true,
                preservedMetrics: lastKnownMetricsByAccount[account] ?? []
            )]
        }

        // Build metrics from quotas
        let metrics = buildMetrics(
            quotas: quotas,
            catalogue: cachedModelCatalogue
        )

        storeMetrics(metrics, for: account)
        logger.log(.info, "Antigravity fetched \(metrics.count) metric(s) for account=\(account)")

        let entry = VendorUsageEntry(
            vendor: vendor,
            account: account,
            isActive: true,
            lastAcquiredOn: ISODate(date: Date()),
            lastError: nil,
            metrics: metrics
        )

        _knownAccounts.withLock { $0 = [account] }
        return [entry]
    }

    // MARK: - Endpoint calls

    private func fetchUserinfo(token: String) async throws -> UserinfoResponse {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.requestTimeoutSeconds

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AntigravityConnectorError.httpError(
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                endpoint: "userinfo"
            )
        }

        logger.log(.debug, "Antigravity userinfo payload: \(loggablePayload(data))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = json["email"] as? String else {
            throw AntigravityConnectorError.parseError(endpoint: "userinfo")
        }

        return UserinfoResponse(email: email)
    }

    private func fetchLoadCodeAssist(token: String) async throws -> LoadCodeAssistResponse {
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.requestTimeoutSeconds

        let body = ["metadata": [
            "ideType": "ANTIGRAVITY",
            "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI"
        ]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AntigravityConnectorError.httpError(
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                endpoint: "loadCodeAssist"
            )
        }

        logger.log(.debug, "Antigravity loadCodeAssist payload: \(loggablePayload(data))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let project = json["cloudaicompanionProject"] as? String else {
            throw AntigravityConnectorError.parseError(endpoint: "loadCodeAssist")
        }

        return LoadCodeAssistResponse(cloudaicompanionProject: project)
    }

    private func fetchFetchAvailableModels(token: String, projectId: String) async throws -> [ModelInfo] {
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.requestTimeoutSeconds

        let body = ["project": projectId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AntigravityConnectorError.httpError(
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                endpoint: "fetchAvailableModels"
            )
        }

        logger.log(.debug, "Antigravity fetchAvailableModels payload: \(loggablePayload(data))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            throw AntigravityConnectorError.parseError(endpoint: "fetchAvailableModels")
        }

        var catalogue: [String: ModelInfo] = [:]
        for model in models {
            guard let modelId = model["modelId"] as? String,
                  let displayName = model["displayName"] as? String else {
                continue
            }
            catalogue[modelId] = ModelInfo(id: modelId, displayName: displayName)
        }

        return Array(catalogue.values)
    }

    private func fetchRetrieveUserQuota(token: String, projectId: String) async throws -> RetrieveUserQuotaResponse {
        var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("antigravity", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.requestTimeoutSeconds

        let body = ["project": projectId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AntigravityConnectorError.httpError(
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                endpoint: "retrieveUserQuota"
            )
        }

        logger.log(.debug, "Antigravity retrieveUserQuota payload: \(loggablePayload(data))")

        // Schema reference: see Tests/Fixtures/google-antigravity-anonymized-golden.json.
        // Top-level key is `buckets`; per-bucket reset key is `resetTime`.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quotaBuckets = json["buckets"] as? [[String: Any]] else {
            throw AntigravityConnectorError.parseError(endpoint: "retrieveUserQuota")
        }

        var buckets: [QuotaBucket] = []
        for bucket in quotaBuckets {
            guard let modelId = bucket["modelId"] as? String else { continue }
            // remainingFraction is omitted from the payload when its protobuf
            // default applies — empirically observed on full (=1) internal
            // buckets. Treat absence as 1.0 so the row reads as "untouched"
            // rather than "exhausted".
            let remaining = (bucket["remainingFraction"] as? NSNumber)?.doubleValue ?? 1.0
            let total = (bucket["totalFraction"] as? NSNumber)?.doubleValue ?? 1.0
            let resetAt = isoDate(from: bucket["resetTime"] as? String)
            buckets.append(QuotaBucket(
                modelId: modelId,
                remainingFraction: remaining,
                totalFraction: total,
                resetAt: resetAt
            ))
        }

        return RetrieveUserQuotaResponse(quotaBuckets: buckets)
    }

    private func refreshModelCatalogueIfNeeded(token: String, projectId: String) async throws {
        // If catalogue is fresh, skip refresh
        if let lastRefresh = cachedCatalogueRefresh, Date().timeIntervalSince(lastRefresh) < 3600 {
            return
        }

        do {
            let models = try await fetchFetchAvailableModels(token: token, projectId: projectId)
            var catalogue: [String: ModelInfo] = [:]
            for model in models {
                catalogue[model.id] = model
            }
            cachedModelCatalogue = catalogue
            cachedCatalogueRefresh = Date()
        } catch {
            logger.log(.warning, "Antigravity catalogue refresh failed: \(error) — using cached catalogue")
        }
    }

    // MARK: - Metrics building

    private func buildMetrics(quotas: RetrieveUserQuotaResponse, catalogue: [String: ModelInfo]) -> [UsageMetric] {
        var cohorted: [String: [QuotaBucket]] = [:]

        // Cohort by resetAt
        for bucket in quotas.quotaBuckets {
            let resetKey = bucket.resetAt?.rawValue ?? "unknown"
            if cohorted[resetKey] == nil {
                cohorted[resetKey] = []
            }
            cohorted[resetKey]?.append(bucket)
        }

        // Phase 1: assemble candidates with their baseName and any inherited
        // name from the previous tick. A name is inheritable only if at least
        // one modelId of the cohort was previously seen under that name AND
        // the previous name shares the cohort's current baseName (so we never
        // inherit "Weekly #1" onto a "5h sessions" cohort after a cadence
        // change).
        struct CohortCandidate {
            let buckets: [QuotaBucket]
            let resetAt: ISODate?
            let resolvedWindow: DurationMinutes?
            let baseName: String
            let inheritedName: String?
            let avgRemaining: Double
            let subtitle: String?
        }

        var candidates: [CohortCandidate] = []
        var inheritedNamesClaimed: Set<String> = []

        for (_, buckets) in cohorted.sorted(by: { ($0.key) < ($1.key) }) {
            guard !buckets.isEmpty else { continue }

            let resetAt = buckets[0].resetAt
            let avgRemaining = buckets.map(\.remainingFraction).reduce(0, +) / Double(buckets.count)

            let displayNames = buckets
                .reversed()
                .compactMap { catalogue[$0.modelId]?.displayName ?? $0.modelId }
                .reduce(into: [String]()) { result, name in
                    if !result.contains(name) {
                        result.append(name)
                    }
                }
            let subtitle = displayNames.joined(separator: ", ")

            let resolvedWindow = resolveWindowDuration(resetAt: resetAt, buckets: buckets)

            if let resolved = resolvedWindow {
                for bucket in buckets {
                    lastKnownWindowByModel[bucket.modelId] = resolved
                }
            }

            let baseName = metricName(for: resolvedWindow)

            var inheritedName: String?
            for bucket in buckets {
                guard let previous = lastKnownCohortNameByModel[bucket.modelId] else { continue }
                guard previous == baseName || previous.hasPrefix(baseName + " #") else { continue }
                guard !inheritedNamesClaimed.contains(previous) else { continue }
                inheritedName = previous
                inheritedNamesClaimed.insert(previous)
                break
            }

            candidates.append(CohortCandidate(
                buckets: buckets,
                resetAt: resetAt,
                resolvedWindow: resolvedWindow,
                baseName: baseName,
                inheritedName: inheritedName,
                avgRemaining: avgRemaining,
                subtitle: subtitle.isEmpty ? nil : subtitle
            ))
        }

        // Phase 2: resolve final names. A cohort that inherited a name keeps
        // it verbatim. Otherwise we apply a "#N" increment whenever the
        // baseName is shared by another cohort in this tick, or when an
        // inherited "#N" name already burns a slot — picking the smallest
        // available N so growth is monotonic.
        let baseNameCounts: [String: Int] = candidates.reduce(into: [:]) { $0[$1.baseName, default: 0] += 1 }
        var usedIncrements: [String: Set<Int>] = [:]
        for candidate in candidates {
            guard let inherited = candidate.inheritedName,
                  let n = Self.parseIncrement(from: inherited, baseName: candidate.baseName) else { continue }
            usedIncrements[candidate.baseName, default: []].insert(n)
        }

        var newCohortMapping: [String: String] = [:]
        var metrics: [UsageMetric] = []

        for candidate in candidates {
            let finalName: String
            if let inherited = candidate.inheritedName {
                finalName = inherited
            } else {
                let shares = (baseNameCounts[candidate.baseName] ?? 0) > 1
                let hasIncrementHistory = !(usedIncrements[candidate.baseName] ?? []).isEmpty
                if shares || hasIncrementHistory {
                    var n = 1
                    while (usedIncrements[candidate.baseName] ?? []).contains(n) { n += 1 }
                    usedIncrements[candidate.baseName, default: []].insert(n)
                    finalName = "\(candidate.baseName) #\(n)"
                } else {
                    finalName = candidate.baseName
                }
            }

            for bucket in candidate.buckets {
                newCohortMapping[bucket.modelId] = finalName
            }

            let percentRemaining = max(0.0, min(100.0, candidate.avgRemaining * 100.0))
            let percentUsed = 100.0 - percentRemaining

            let metric = UsageMetric.timeWindow(
                name: finalName,
                resetAt: candidate.resetAt,
                windowDuration: candidate.resolvedWindow ?? DurationMinutes(rawValue: Self.weeklyWindowMinutes),
                usagePercent: UsagePercent(rawValue: Int(percentUsed.rounded())),
                subtitle: candidate.subtitle
            )

            metrics.append(metric)
        }

        lastKnownCohortNameByModel = newCohortMapping

        return metrics
    }

    private static func parseIncrement(from name: String, baseName: String) -> Int? {
        let prefix = baseName + " #"
        guard name.hasPrefix(prefix) else { return nil }
        return Int(name.dropFirst(prefix.count))
    }

    private func resolveWindowDuration(resetAt: ISODate?, buckets: [QuotaBucket]) -> DurationMinutes? {
        if let resetAt, let resetDate = resetAt.date {
            let diff = resetDate.timeIntervalSince(clock())
            if diff > 0 && diff < Self.fiveHourThresholdSeconds {
                return DurationMinutes(rawValue: Self.fiveHourWindowMinutes)
            }
            return DurationMinutes(rawValue: Self.weeklyWindowMinutes)
        }
        // No resetAt — try to recover from the per-model memo. First hit wins;
        // mixed cadences in the same cohort are unobserved in practice.
        for bucket in buckets {
            if let memoised = lastKnownWindowByModel[bucket.modelId] {
                return memoised
            }
        }
        return nil
    }

    private func metricName(for windowDuration: DurationMinutes?) -> String {
        guard let windowDuration else { return "Unknown" }
        switch windowDuration.rawValue {
        case Self.fiveHourWindowMinutes: return "5h sessions"
        case Self.weeklyWindowMinutes:   return "Weekly"
        default:                          return "Models"
        }
    }

    private nonisolated func clock() -> Date { Date() }

    private func isoDate(from raw: String?) -> ISODate? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        return ISODate(rawValue: raw)
    }

    /// Runs the payload sanitizer and produces a human-readable string for
    /// the connector log. The sanitizer returns `Data`; without this helper,
    /// string-interpolating it would print the byte count instead of the
    /// JSON body and silently defeat the diagnostic.
    private func loggablePayload(_ data: Data) -> String {
        let sanitized = sanitizer.sanitize(data)
        return String(data: sanitized, encoding: .utf8) ?? "<non-UTF8, \(sanitized.count) bytes>"
    }

    private func preservedMetrics(for account: AccountEmail) -> [UsageMetric] {
        lastKnownMetricsByAccount[account] ?? []
    }

    private func storeMetrics(_ metrics: [UsageMetric], for account: AccountEmail) {
        lastKnownMetricsByAccount[account] = metrics
    }

    // MARK: - Error helpers

    private func errorEntries(type: String) -> [VendorUsageEntry] {
        let resolved: AccountEmail? = _cachedAccount.withLock { $0 }
        guard let account = resolved else {
            logger.log(.warning, "Antigravity identity_unresolved during \(type) — no usage entry written")
            return []
        }
        return [errorEntry(
            type: type,
            account: account,
            isActive: true,
            preservedMetrics: preservedMetrics(for: account)
        )]
    }

    private static func credentialErrorType(for error: Error) -> String {
        guard let error = error as? AntigravityAuthError else {
            return UsageErrorType.credentialError
        }
        switch error {
        case .bootstrapFailed:
            return UsageErrorType.tokenError
        case .tokenExpired:
            return UsageErrorType.tokenExpired
        case .keychainAccessDenied, .keychainEmpty, .keychainTimeout, .keychainParseFailed, .missingExpiresAt, .invalidExpiresAtFormat:
            return UsageErrorType.credentialError
        }
    }

    private func errorEntry(
        type: String,
        account: AccountEmail,
        isActive: Bool,
        preservedMetrics: [UsageMetric] = []
    ) -> VendorUsageEntry {
        VendorUsageEntry(
            vendor: vendor,
            account: account,
            isActive: isActive,
            lastAcquiredOn: nil,
            lastError: UsageError(timestamp: ISODate(date: Date()), type: type),
            metrics: preservedMetrics
        )
    }

    // MARK: - Internal types

    private struct UserinfoResponse {
        let email: String
    }

    private struct LoadCodeAssistResponse {
        let cloudaicompanionProject: String
    }

    private struct ModelInfo {
        let id: String
        let displayName: String
    }

    private struct QuotaBucket {
        let modelId: String
        let remainingFraction: Double
        let totalFraction: Double
        let resetAt: ISODate?
    }

    private struct RetrieveUserQuotaResponse {
        let quotaBuckets: [QuotaBucket]
    }
}

public enum AntigravityConnectorError: Error, CustomStringConvertible {
    case httpError(code: Int, endpoint: String)
    case parseError(endpoint: String)

    public var description: String {
        switch self {
        case let .httpError(code, endpoint):
            "Antigravity \(endpoint) returned HTTP \(code)"
        case let .parseError(endpoint):
            "Failed to parse Antigravity \(endpoint) response"
        }
    }
}
