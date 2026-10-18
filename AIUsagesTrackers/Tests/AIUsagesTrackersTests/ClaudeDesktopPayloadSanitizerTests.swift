import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("ClaudeDesktopPayloadSanitizer — leakage")
struct ClaudeDesktopPayloadSanitizerLeakageTests {
    @Test("realistic full payload produces no surviving seeded secret")
    func noLeakage() {
        let sanitizer = ClaudeDesktopPayloadSanitizer()
        let fixture = FixtureLoader.load("claude-desktop-full-payload")
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

    @Test("Electron safeStorage v10 ciphertext is redacted from a message")
    func safeStorageCipherRedacted() {
        let sanitizer = ClaudeDesktopPayloadSanitizer()
        let masked = sanitizer.sanitize("config value v10c2VlZGVkRmFrZUNpcGhlclRleHRCbG9iVmFsdWU= leaked")
        #expect(!masked.contains("v10c2VlZGVkRmFrZUNpcGhlclRleHRCbG9iVmFsdWU="))
    }

    @Test("breakdown structural fields survive sanitization")
    func breakdownPreserved() {
        let sanitizer = ClaudeDesktopPayloadSanitizer()
        let raw = #"{"seven_day_breakdown":{"rows":[{"key":"cowork","display_name":"Cowork","percent":97}]}}"#
        let sanitized = sanitizer.sanitize(Data(raw.utf8))
        let json = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        let breakdown = json?["seven_day_breakdown"] as? [String: Any]
        let rows = breakdown?["rows"] as? [[String: Any]]
        #expect((rows?.first?["percent"] as? Int) == 97)
        #expect((rows?.first?["display_name"] as? String) == "Cowork")
    }
}
