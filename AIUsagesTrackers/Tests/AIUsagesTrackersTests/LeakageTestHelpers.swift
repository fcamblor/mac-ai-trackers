import Foundation
import Testing
@testable import AIUsagesTrackersLib

/// Loads a JSON fixture from `Tests/AIUsagesTrackersTests/Fixtures/`. The
/// file must be a valid JSON document; the loader returns its raw bytes
/// for sanitizer round-trips and its parsed object for direct
/// inspection.
enum FixtureLoader {
    static func load(_ name: String, ext: String = "json") -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            // The fixture is mandatory for the leakage test to do anything
            // meaningful — failing here surfaces the missing resource at
            // suite-load time rather than at deeper inspection.
            fatalError("Missing fixture \(name).\(ext) in test bundle")
        }
        // swiftlint:disable:next force_try
        return try! Data(contentsOf: url)
    }
}

/// Seeded secret tokens placed inside the per-vendor full-payload
/// fixture. Every leakage test asserts none of these survive in the
/// sanitized output. Adding a new entry here means: add a JSON field
/// using that exact value to every fixture so the sanitizer's reach is
/// exercised against the new pattern too.
enum SeededSecrets {
    static let all: [String] = [
        // OAuth-shaped tokens
        "sk-ant-oat01-DEADBEEFseededFakeToken",
        "sk-ant-ort01-AnotherFakeToken",
        "ghu_seededFakeUserToken",
        "gho_seededFakeOauthToken",
        "Bearer seededFakeBearerSentinel",
        // API keys
        "anth_apikey_seededfake",
        "openai_seededapikey_fake",
        "ghp_seededFakePATToken",
        // Refresh tokens
        "refresh_seededfake_token",
        // Generic credentials
        "seeded-credential-blob",
        // Account ids
        "acct_seededfakeid",
        "user-seededfakeuserid",
        // Email
        "victim-seeded@example.com",
        // Tracking ids
        "seededtrackingid000000000000000",
    ]
}

/// Asserts the sanitizer produces no surviving seeded secret across the
/// payload, header, and message paths. Re-used by every per-vendor
/// leakage test.
func assertNoLeakage(
    sanitizer: any PayloadSanitizing,
    fixture: Data,
    seededHeaders: [String: String] = [:],
    additionalMessages: [String] = [],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let sanitizedBody = sanitizer.sanitize(fixture)
    let sanitizedBodyString = String(data: sanitizedBody, encoding: .utf8) ?? ""
    let sanitizedHeaders = sanitizer.sanitize(seededHeaders)
    let allHeaderValues = sanitizedHeaders.values.joined(separator: " ")

    var allSanitizedText = sanitizedBodyString + " " + allHeaderValues
    for message in additionalMessages {
        let sanitizedMessage = sanitizer.sanitize(message)
        allSanitizedText += " " + sanitizedMessage
    }

    for secret in SeededSecrets.all {
        // Skip secrets the fixture clearly doesn't contain — the seeded
        // list is shared across vendors but each fixture only carries a
        // subset, plus any header/message specifically passed in.
        guard fixtureContains(fixture: fixture, headers: seededHeaders, messages: additionalMessages, value: secret) else {
            continue
        }
        #expect(
            !allSanitizedText.contains(secret),
            "Sanitizer leaked secret '\(secret)'",
            sourceLocation: sourceLocation
        )
    }
}

private func fixtureContains(
    fixture: Data,
    headers: [String: String],
    messages: [String],
    value: String
) -> Bool {
    if let str = String(data: fixture, encoding: .utf8), str.contains(value) { return true }
    if headers.values.contains(where: { $0.contains(value) }) { return true }
    if messages.contains(where: { $0.contains(value) }) { return true }
    return false
}
