import Foundation

/// Resolves the Anthropic account email behind an OAuth bearer. Used by the
/// Claude Desktop connector to turn a profile bearer into the same
/// `AccountEmail` the `claude` CLI connector reports, so the UI can detect that
/// a Claude Desktop profile and a Claude Code login are the same account.
public protocol ClaudeProfileResolving: Sendable {
    /// Returns the account email for `accessToken`, or nil on any failure — the
    /// caller falls back to a profile-derived label, so this never throws.
    func resolveEmail(accessToken: String) async -> AccountEmail?
}

/// Default resolver backed by `GET /api/oauth/profile`. The endpoint returns
/// `{ account: { uuid, email, full_name, … }, organization: { uuid, name }, … }`.
public struct HTTPClaudeProfileResolver: ClaudeProfileResolving {
    public static let endpoint = "https://api.anthropic.com/api/oauth/profile"

    private let session: URLSession
    private let logger: FileLogger

    public init(session: URLSession = .shared, logger: FileLogger = Loggers.claudeDesktop) {
        self.session = session
        self.logger = logger
    }

    public func resolveEmail(accessToken: String) async -> AccountEmail? {
        guard let url = URL(string: Self.endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.warning, "Profile resolution request failed: \(error)")
            return nil
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            logger.log(.warning, "Profile resolution returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            return nil
        }
        return Self.parseEmail(data)
    }

    static func parseEmail(_ data: Data) -> AccountEmail? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["account"] as? [String: Any] else {
            return nil
        }
        // The profile endpoint names the field `email`; `email_address` is kept
        // as a defensive fallback for the token-introspection response shape.
        let email = (account["email"] as? String) ?? (account["email_address"] as? String)
        guard let email, !email.isEmpty else { return nil }
        return AccountEmail(rawValue: email)
    }
}
