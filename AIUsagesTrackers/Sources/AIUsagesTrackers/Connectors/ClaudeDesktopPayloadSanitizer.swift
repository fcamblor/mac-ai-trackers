import Foundation

/// Sanitizer for the Claude Desktop connector. Identical default-deny posture to
/// `ClaudePayloadSanitizer` (the usage endpoint is shared and returns no secrets)
/// plus a guard against the Electron `safeStorage` `v10` ciphertext blobs that
/// could appear if a decryption error path ever logged raw `config.json`
/// material. The authoritative field list lives in
/// `docs/vendors/claude-desktop.md`.
public struct ClaudeDesktopPayloadSanitizer: PayloadSanitizing {
    private let headerSanitizer = BaseHeaderSanitizer()
    private let jsonSanitizer = JSONFieldSanitizer()
    private let emailSanitizer = EmailPatternSanitizer()
    private let secretSanitizer = SecretPatternSanitizer(patterns: [
        #"sk-ant-[A-Za-z0-9_-]+"#,
        #"anth_[A-Za-z0-9_-]+"#,
        // Electron safeStorage ciphertext: base64 payload with the `v10` prefix.
        #"v10[A-Za-z0-9+/=]{16,}"#,
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
