import Foundation

/// Sanitizer for the Codex (ChatGPT) `wham/usage` endpoint. The body
/// includes `email`, `user_id` and `account_id` — three fields the vendor
/// treats as private identifiers — so the JSON sanitizer extends the
/// shared default-deny with an exact-key list. Tokens in messages match
/// JWT and `sk-…` shapes via the secret pattern sanitizer.
public struct CodexPayloadSanitizer: PayloadSanitizing {
    private let headerSanitizer = BaseHeaderSanitizer()
    private let jsonSanitizer = JSONFieldSanitizer(
        substringPatterns: JSONFieldSanitizer.defaultSubstringPatterns,
        extraExactKeys: ["user_id", "account_id"]
    )
    private let emailSanitizer = EmailPatternSanitizer()
    /// JWT shape (`eyJ…`) catches `id_token` and `access_token` if they
    /// ever surface inside a free-form log line. `sk-…` catches OpenAI
    /// API keys mistakenly logged.
    private let secretSanitizer = SecretPatternSanitizer(patterns: [
        #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#,
        #"sk-[A-Za-z0-9_-]{20,}"#,
    ])

    public init() {}

    public func sanitize(_ payload: Data) -> Data {
        let masked = jsonSanitizer.sanitize(payload)
        guard let text = String(data: masked, encoding: .utf8) else { return masked }
        let scrubbed = secretSanitizer.sanitize(emailSanitizer.sanitize(text))
        return scrubbed.data(using: .utf8) ?? masked
    }

    public func sanitize(_ headers: [String: String]) -> [String: String] {
        // ChatGPT-Account-Id is the account identifier the vendor treats
        // as private — redact it on the way out the same way the body
        // sanitizer redacts `account_id`.
        var result = headerSanitizer.sanitize(headers)
        for (key, _) in result where key.lowercased() == "chatgpt-account-id" {
            result[key] = BaseHeaderSanitizer.redactedPlaceholder
        }
        return result
    }

    public func sanitize(_ message: String) -> String {
        secretSanitizer.sanitize(emailSanitizer.sanitize(message))
    }
}
