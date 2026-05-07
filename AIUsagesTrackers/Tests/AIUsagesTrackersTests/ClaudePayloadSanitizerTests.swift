import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("ClaudePayloadSanitizer — leakage")
struct ClaudePayloadSanitizerLeakageTests {
    @Test("realistic full payload produces no surviving seeded secret")
    func noLeakage() {
        let sanitizer = ClaudePayloadSanitizer()
        let fixture = FixtureLoader.load("claude-full-payload")
        let seededHeaders = [
            "Authorization": "Bearer seededFakeBearerSentinel",
            "anthropic-beta": "oauth-2025-04-20",
            "X-Api-Key": "anth_apikey_seededfake",
            "Cookie": "session=seeded-credential-blob",
        ]
        let messages = [
            "Failed for victim-seeded@example.com",
            "Token retrieval used sk-ant-oat01-DEADBEEFseededFakeToken",
        ]
        assertNoLeakage(
            sanitizer: sanitizer,
            fixture: fixture,
            seededHeaders: seededHeaders,
            additionalMessages: messages
        )
    }

    @Test("Authorization header is replaced with placeholder")
    func authorizationRedacted() {
        let sanitized = ClaudePayloadSanitizer().sanitize([
            "Authorization": "Bearer secret-token-value",
            "anthropic-beta": "oauth-2025-04-20",
        ])
        #expect(sanitized["Authorization"] == "<redacted>")
        #expect(sanitized["anthropic-beta"] == "oauth-2025-04-20")
    }

    @Test("known structural fields survive sanitization")
    func structurePreserved() {
        let sanitizer = ClaudePayloadSanitizer()
        let raw = #"{"five_hour":{"utilization":50.0,"resets_at":"2026-05-07T00:29:59+00:00"},"oauth_token":"sk-ant-oat01-secret"}"#
        let sanitized = sanitizer.sanitize(raw.data(using: .utf8)!)
        let json = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        let fiveHour = json?["five_hour"] as? [String: Any]
        #expect((fiveHour?["utilization"] as? Double) == 50.0)
        #expect((fiveHour?["resets_at"] as? String) == "2026-05-07T00:29:59+00:00")
        #expect((json?["oauth_token"] as? String) == "<redacted>")
    }

    @Test("email pattern in free-form message is masked")
    func emailMasked() {
        let sanitizer = ClaudePayloadSanitizer()
        let masked = sanitizer.sanitize("Contact victim-seeded@example.com for help")
        #expect(masked == "Contact <email> for help")
    }
}
