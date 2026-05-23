import Foundation

/// Sanitizer for Google Antigravity OAuth. Composes base sanitizers for
/// headers (BaseHeaderSanitizer), JSON fields (JSONFieldSanitizer), and
/// adds Antigravity-specific redaction for modelExperiments,
/// supportedMimeTypes, cloudaicompanionProject, and Google token patterns.
public struct AntigravityPayloadSanitizer: PayloadSanitizing {
    private let headerSanitizer = BaseHeaderSanitizer()
    private let jsonSanitizer = JSONFieldSanitizer(
        substringPatterns: JSONFieldSanitizer.defaultSubstringPatterns,
        extraExactKeys: ["modelExperiments", "supportedMimeTypes", "cloudaicompanionProject"]
    )
    private let emailSanitizer = EmailPatternSanitizer()
    /// Google OAuth tokens carry a stable `ya29.` prefix; client secrets start with `GOCSPX-`.
    private let googleTokenSanitizer = SecretPatternSanitizer(patterns: [
        #"ya29\.[A-Za-z0-9_-]+"#,
        #"GOCSPX-[A-Za-z0-9_-]+"#,
    ])

    public init() {}

    public func sanitize(_ payload: Data) -> Data {
        let masked = jsonSanitizer.sanitize(payload)
        guard let text = String(data: masked, encoding: .utf8) else { return masked }
        let scrubbed = googleTokenSanitizer.sanitize(emailSanitizer.sanitize(text))
        return scrubbed.data(using: .utf8) ?? masked
    }

    public func sanitize(_ headers: [String: String]) -> [String: String] {
        headerSanitizer.sanitize(headers)
    }

    public func sanitize(_ message: String) -> String {
        googleTokenSanitizer.sanitize(emailSanitizer.sanitize(message))
    }
}
