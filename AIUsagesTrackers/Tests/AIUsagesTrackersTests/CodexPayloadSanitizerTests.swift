import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("CodexPayloadSanitizer — leakage")
struct CodexPayloadSanitizerLeakageTests {
    @Test("realistic full payload produces no surviving seeded secret")
    func noLeakage() {
        let sanitizer = CodexPayloadSanitizer()
        let fixture = FixtureLoader.load("codex-full-payload")
        let seededHeaders = [
            "Authorization": "Bearer eyJseededFakeJwtPayload.eyJseededClaims.seededSig",
            "ChatGPT-Account-Id": "user-seededfakeuserid",
            "User-Agent": "OpenUsage",
        ]
        let messages = [
            "Token retrieval used eyJseededFakeJwtPayload.eyJseededClaims.seededSig",
            "Failed for victim-seeded@example.com",
        ]
        assertNoLeakage(
            sanitizer: sanitizer,
            fixture: fixture,
            seededHeaders: seededHeaders,
            additionalMessages: messages
        )
    }

    @Test("user_id and account_id are redacted")
    func accountIdsRedacted() {
        let sanitizer = CodexPayloadSanitizer()
        let raw = #"{"user_id":"user-secret","account_id":"user-secret","plan_type":"plus"}"#
        let sanitized = sanitizer.sanitize(raw.data(using: .utf8)!)
        let json = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        #expect((json?["user_id"] as? String) == "<redacted>")
        #expect((json?["account_id"] as? String) == "<redacted>")
        #expect((json?["plan_type"] as? String) == "plus")
    }

    @Test("ChatGPT-Account-Id header is redacted")
    func accountHeaderRedacted() {
        let sanitized = CodexPayloadSanitizer().sanitize([
            "Authorization": "Bearer secret",
            "ChatGPT-Account-Id": "user-secret",
            "User-Agent": "OpenUsage",
        ])
        #expect(sanitized["Authorization"] == "<redacted>")
        #expect(sanitized["ChatGPT-Account-Id"] == "<redacted>")
        #expect(sanitized["User-Agent"] == "OpenUsage")
    }
}
