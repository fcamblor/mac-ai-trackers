import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("CopilotPayloadSanitizer — leakage")
struct CopilotPayloadSanitizerLeakageTests {
    @Test("realistic full payload produces no surviving seeded secret")
    func noLeakage() {
        let sanitizer = CopilotPayloadSanitizer()
        let fixture = FixtureLoader.load("copilot-full-payload")
        let seededHeaders = [
            "Authorization": "Bearer seededFakeBearerSentinel",
            "Editor-Version": "vscode/1.96.2",
            "User-Agent": "GithubCopilotChat/0.26.7",
        ]
        let messages = [
            "Token retrieval used gho_seededFakeOauthToken123456789",
            "Decoded keychain go-keyring-base64:Z2hvX1NlZWRlZEZha2VPYXV0aFRva2VuMTIzNDU2Nzg5",
            "Failed for victim-seeded@example.com",
        ]
        assertNoLeakage(
            sanitizer: sanitizer,
            fixture: fixture,
            seededHeaders: seededHeaders,
            additionalMessages: messages
        )
    }

    @Test("login is preserved (it is the public account identity)")
    func loginPreserved() {
        let sanitizer = CopilotPayloadSanitizer()
        let raw = #"{"login":"fcamblor","analytics_tracking_id":"abc","copilot_plan":"individual"}"#
        let sanitized = sanitizer.sanitize(raw.data(using: .utf8)!)
        let json = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        #expect((json?["login"] as? String) == "fcamblor")
        #expect((json?["analytics_tracking_id"] as? String) == "<redacted>")
        #expect((json?["copilot_plan"] as? String) == "individual")
    }

    @Test("GitHub token shapes in messages are redacted")
    func tokenShapesRedacted() {
        let sanitizer = CopilotPayloadSanitizer()
        let masked = sanitizer.sanitize("Used gho_AAAAAAAAAAAAAAAAAAAAAA and ghu_BBBBBBBBBBBBBBBBBBBBBB")
        #expect(!masked.contains("gho_AAAAAAAAAAAAAAAAAAAAAA"))
        #expect(!masked.contains("ghu_BBBBBBBBBBBBBBBBBBBBBB"))
    }
}
