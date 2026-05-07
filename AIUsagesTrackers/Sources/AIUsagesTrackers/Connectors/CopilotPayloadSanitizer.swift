import Foundation

/// Sanitizer for the GitHub Copilot `copilot_internal/user` endpoint. The
/// `login` field is the public GitHub username and stays unredacted —
/// it's the per-account identity the rest of the app keys on, and it's
/// already public via every git commit. The `analytics_tracking_id` and
/// any token-shaped value get redacted.
public struct CopilotPayloadSanitizer: PayloadSanitizing {
    private let headerSanitizer = BaseHeaderSanitizer()
    /// `login` is intentionally absent from the substring patterns — the
    /// shared default already excludes it. `analytics_tracking_id` is
    /// added as an exact-key match because no shared substring captures
    /// it.
    private let jsonSanitizer = JSONFieldSanitizer(
        substringPatterns: JSONFieldSanitizer.defaultSubstringPatterns,
        extraExactKeys: ["analytics_tracking_id"]
    )
    private let emailSanitizer = EmailPatternSanitizer()
    /// GitHub OAuth tokens follow stable prefixes: `gho_` (OAuth user),
    /// `ghp_` (personal access), `ghu_` (user-to-server), `ghs_`
    /// (GitHub App). `Bearer` / `token` prefixes catch raw header values
    /// spliced into prose.
    private let secretSanitizer = SecretPatternSanitizer(patterns: [
        #"gh[ousp]_[A-Za-z0-9_-]{20,}"#,
        #"(?i)Bearer\s+[A-Za-z0-9._-]+"#,
        #"go-keyring-base64:[A-Za-z0-9+/=]+"#,
    ])

    public init() {}

    public func sanitize(_ payload: Data) -> Data {
        let masked = jsonSanitizer.sanitize(payload)
        guard let text = String(data: masked, encoding: .utf8) else { return masked }
        let scrubbed = secretSanitizer.sanitize(emailSanitizer.sanitize(text))
        return scrubbed.data(using: .utf8) ?? masked
    }

    public func sanitize(_ headers: [String: String]) -> [String: String] {
        headerSanitizer.sanitize(headers)
    }

    public func sanitize(_ message: String) -> String {
        secretSanitizer.sanitize(emailSanitizer.sanitize(message))
    }
}
