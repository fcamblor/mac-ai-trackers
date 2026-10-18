import Foundation

/// Reads organization-wide Copilot credit totals for token-based-billing seats.
/// The token belongs to GitHub CLI or an editor; this client only sends GETs.
actor CopilotOrgBillingClient {
    private static let userOrgsURL: URL = {
        URL(string: "https://api.github.com/user/orgs?per_page=100")! // known-valid literal
    }()
    private static let timeoutSeconds: TimeInterval = 15
    private static let userAgent = "mac-ai-trackers"

    private let session: URLSession
    private let logger: FileLogger
    private var cachedOrgByAccount: [AccountEmail: String] = [:]

    init(session: URLSession, logger: FileLogger) {
        self.session = session
        self.logger = logger
    }

    func metrics(for account: AccountEmail, token: String) async -> [UsageMetric] {
        if let cachedOrg = cachedOrgByAccount[account] {
            do {
                if let metrics = try await usageMetrics(org: cachedOrg, token: token) {
                    return metrics
                }
                cachedOrgByAccount[account] = nil
            } catch {
                logger.log(
                    .warning,
                    "Copilot cached organization billing request failed for login=\(account): \(error)"
                )
                return []
            }
        }

        let organizations: [String]
        do {
            let (data, response) = try await session.data(for: makeRequest(url: Self.userOrgsURL, token: token))
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                logger.log(.info, "Copilot organization list returned HTTP \(status) for login=\(account)")
                return []
            }
            organizations = Self.organizationLogins(from: data)
        } catch {
            logger.log(.warning, "Copilot organization list request failed for login=\(account): \(error)")
            return []
        }

        for organization in organizations {
            do {
                if let metrics = try await usageMetrics(org: organization, token: token) {
                    cachedOrgByAccount[account] = organization
                    return metrics
                }
            } catch {
                // A transient error for one org should not hide billing from another org.
                logger.log(.warning, "Copilot organization billing request failed for login=\(account): \(error)")
            }
        }
        return []
    }

    private func usageMetrics(org: String, token: String) async throws -> [UsageMetric]? {
        guard let url = Self.usageSummaryURL(org: org) else { return nil }
        let (data, response) = try await session.data(for: makeRequest(url: url, token: token))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            logger.log(.debug, "Copilot organization billing returned HTTP \(status)")
            if status == 429 || status >= 500 {
                throw CopilotOrgBillingError.transientHTTP(status)
            }
            return nil
        }
        return Self.metrics(from: data)
    }

    private func makeRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = Self.timeoutSeconds
        return request
    }

    private static func usageSummaryURL(org: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard let encoded = org.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://api.github.com/orgs/\(encoded)/settings/billing/usage/summary")
    }

    private static func organizationLogins(from data: Data) -> [String] {
        guard let organizations = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return organizations.compactMap { organization in
            guard let login = organization["login"] as? String else { return nil }
            let trimmed = login.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func metrics(from data: Data) -> [UsageMetric]? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = body["usageItems"] as? [[String: Any]] else {
            return nil
        }
        let creditItems = items.filter { item in
            let product = (item["product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let unit = (item["unitType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return product == "copilot" && (unit == "ai-units" || unit == "ai-credits")
        }
        guard !creditItems.isEmpty else { return nil }

        let credits = creditItems.reduce(0.0) { total, item in
            total + max(0, number(item["grossQuantity"]) ?? 0)
        }
        let spend = creditItems.reduce(0.0) { total, item in
            total + max(0, number(item["netAmount"]) ?? 0)
        }
        return [
            .payAsYouGo(name: "Org Credits", currentAmount: credits, currency: "credits"),
            .payAsYouGo(name: "Org Spend", currentAmount: spend, currency: "USD")
        ]
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

private enum CopilotOrgBillingError: Error {
    case transientHTTP(Int)
}
