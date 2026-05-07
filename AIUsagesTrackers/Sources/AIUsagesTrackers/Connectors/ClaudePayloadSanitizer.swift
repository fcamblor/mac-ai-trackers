import Foundation

/// Sanitizer for the Anthropic OAuth usage endpoint. The endpoint itself
/// returns no tokens, emails, or account ids, so the field-name based
/// default-deny is defensive against future schema changes — the
/// `Sanitized fields` section in `docs/vendors/claude.md` is the
/// authoritative list.
public struct ClaudePayloadSanitizer: PayloadSanitizing {
    private let headerSanitizer = BaseHeaderSanitizer()
    private let jsonSanitizer = JSONFieldSanitizer()
    private let emailSanitizer = EmailPatternSanitizer()
    /// Anthropic OAuth access tokens carry a stable `sk-ant-…` shape
    /// regardless of the prefix variant (`oat01`, `ort01`, etc.). The
    /// pattern stays loose enough to survive future prefix rotation.
    private let secretSanitizer = SecretPatternSanitizer(patterns: [
        #"sk-ant-[A-Za-z0-9_-]+"#,
        #"anth_[A-Za-z0-9_-]+"#,
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
