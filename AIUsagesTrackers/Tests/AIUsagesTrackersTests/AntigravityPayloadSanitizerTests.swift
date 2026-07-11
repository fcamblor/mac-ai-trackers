import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("AntigravityPayloadSanitizer — leakage")
struct AntigravityPayloadSanitizerLeakageTests {
    @Test("realistic full payload produces no surviving seeded secret")
    func noLeakage() {
        let sanitizer = AntigravityPayloadSanitizer()
        let fixture = FixtureLoader.load("google-antigravity-full-payload")
        let seededHeaders = [
            "Authorization": "Bearer seededFakeBearerSentinel",
            "User-Agent": "antigravity-cli/2.0",
            "Cookie": "session=seeded-credential-blob",
        ]
        let messages = [
            "Failed to refresh: ya29.a0AfH6SMBseededFakeAccessTokenABCDEF1234567890 expired",
            "Client secret GOCSPX-seededFakeClientSecret1234567890 rejected by token endpoint",
            "Contact victim-seeded@example.com to rotate the leaked credential",
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
        let sanitized = AntigravityPayloadSanitizer().sanitize([
            "Authorization": "Bearer ya29.a0AfH6SMBsecret",
            "User-Agent": "antigravity-cli/2.0",
        ])
        #expect(sanitized["Authorization"] == "<redacted>")
        #expect(sanitized["User-Agent"] == "antigravity-cli/2.0")
    }

    @Test("modelExperiments and supportedMimeTypes are stripped")
    func modelMetadataStripped() {
        let sanitizer = AntigravityPayloadSanitizer()
        let raw = #"{"models":[{"modelId":"gemini-3-pro","modelExperiments":"internal Google DeepMind prompt","supportedMimeTypes":["text/plain","image/png"]}]}"#
        let sanitized = sanitizer.sanitize(raw.data(using: .utf8)!)
        let json = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        let models = json?["models"] as? [[String: Any]]
        let first = models?.first
        #expect((first?["modelId"] as? String) == "gemini-3-pro")
        #expect((first?["modelExperiments"] as? String) == "<redacted>")
        #expect((first?["supportedMimeTypes"] as? String) == "<redacted>")
    }

    @Test("cloudaicompanionProject is stripped from loadCodeAssist payload")
    func cloudProjectStripped() {
        let sanitizer = AntigravityPayloadSanitizer()
        let raw = #"{"cloudaicompanionProject":"seeded-private-cloud-project-id","currentTier":{"id":"free-tier"}}"#
        let sanitized = sanitizer.sanitize(raw.data(using: .utf8)!)
        let json = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        #expect((json?["cloudaicompanionProject"] as? String) == "<redacted>")
        #expect(((json?["currentTier"] as? [String: Any])?["id"] as? String) == "free-tier")
    }

    @Test("retrieveUserQuota structural fields survive sanitization")
    func quotaStructurePreserved() {
        let sanitizer = AntigravityPayloadSanitizer()
        let raw = #"{"buckets":[{"tokenType":"WTUS","modelId":"gemini-3-pro","remainingFraction":0.42,"resetTime":"2026-05-29T23:24:10Z"}]}"#
        let sanitized = sanitizer.sanitize(raw.data(using: .utf8)!)
        let json = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        let bucket = (json?["buckets"] as? [[String: Any]])?.first
        // `tokenType` matches the substring redaction (`token` ⇒ <redacted>);
        // the cohorting logic relies on modelId / remainingFraction / resetTime, which must survive.
        #expect((bucket?["modelId"] as? String) == "gemini-3-pro")
        #expect((bucket?["remainingFraction"] as? Double) == 0.42)
        #expect((bucket?["resetTime"] as? String) == "2026-05-29T23:24:10Z")
    }

    @Test("ya29 access token pattern in free-form message is masked")
    func accessTokenMasked() {
        let sanitizer = AntigravityPayloadSanitizer()
        let masked = sanitizer.sanitize("Refresh failed for ya29.a0AfH6SMBseededFakeAccessTokenABCDEF1234567890")
        #expect(!masked.contains("ya29.a0AfH6SMBseededFakeAccessTokenABCDEF1234567890"))
    }

    @Test("GOCSPX client secret pattern in free-form message is masked")
    func clientSecretMasked() {
        let sanitizer = AntigravityPayloadSanitizer()
        let masked = sanitizer.sanitize("Rejected GOCSPX-seededFakeClientSecret1234567890 at token endpoint")
        #expect(!masked.contains("GOCSPX-seededFakeClientSecret1234567890"))
    }
}
