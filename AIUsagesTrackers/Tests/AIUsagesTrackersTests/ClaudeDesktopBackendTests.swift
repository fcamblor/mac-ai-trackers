import Foundation
import Testing
@testable import AIUsagesTrackersLib

/// A `v10` value produced offline with the Electron safeStorage scheme
/// (PBKDF2-HMAC-SHA1("peanuts", "saltysalt", 1003, 16) → AES-128-CBC, IV = 16
/// spaces, PKCS7). Decrypts to a single-entry token cache with the inference
/// scope.
private enum Vector {
    static let password = Data("peanuts".utf8)
    static let base64 = "djEwDBMe+x25reEOCG7BywQPjGIahaHwCps/4sXuHq1EC4E/EIXmYKbDKpp+U+CtpWvMGoZegkeDH3wcrkfcoJfTgync5VrydWlJVMyXrkyiWbCCy0EEqqYecbxJN8619IdZ"
    static let decryptedJSON = #"{"acct:u|s:org-uuid:https://api.anthropic.com:user:inference":{"token":"sk-ant-oat01-X"}}"#
}

private struct StubKeyReader: SafeStorageKeyReading {
    let key: Data
    var error: SafeStorageError?
    func readKey(service: String) async throws -> Data {
        if let error { throw error }
        return key
    }
}

@Suite("AppleSafeStorageDecryptor")
struct AppleSafeStorageDecryptorTests {
    @Test("decrypts a known v10 vector")
    func decryptsKnownVector() throws {
        let plaintext = try AppleSafeStorageDecryptor().decrypt(base64Value: Vector.base64, keyPassword: Vector.password)
        #expect(String(data: plaintext, encoding: .utf8) == Vector.decryptedJSON)
    }

    @Test("rejects a non-v10 prefix")
    func rejectsWrongPrefix() {
        // "v11…" base64-encoded
        let wrong = Data(base64Encoded: Data("v11abcdef".utf8).base64EncodedString())!
        let value = wrong.base64EncodedString()
        #expect(throws: SafeStorageError.self) {
            _ = try AppleSafeStorageDecryptor().decrypt(base64Value: value, keyPassword: Vector.password)
        }
    }

    @Test("rejects non-base64 input")
    func rejectsNonBase64() {
        #expect(throws: SafeStorageError.self) {
            _ = try AppleSafeStorageDecryptor().decrypt(base64Value: "!!!not base64!!!", keyPassword: Vector.password)
        }
    }
}

@Suite("ClaudeDesktopProfileStore")
struct ClaudeDesktopProfileStoreTests {
    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "cds-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("discovers a custom profile and reads its token cache")
    func discoversCustomProfile() throws {
        let home = try makeTempDir()
        let profileDir = try makeTempDir()
        let config = #"{"oauth:tokenCacheV2":"\#(Vector.base64)","other":1}"#
        try config.write(toFile: profileDir + "/config.json", atomically: true, encoding: .utf8)

        let store = ClaudeDesktopProfileStore(
            homeDirectoryPath: home,
            customProfilePaths: { [profileDir] }
        )
        let profiles = store.discoverProfiles()
        #expect(profiles.count == 1)
        #expect(profiles.first?.name == (profileDir as NSString).lastPathComponent)
        #expect(profiles.first?.encryptedTokenCache == Vector.base64)
    }

    @Test("skips non-existent directories and deduplicates repeated paths")
    func skipsMissingAndDeduplicates() throws {
        let home = try makeTempDir()
        let profileDir = try makeTempDir()
        try "{}".write(toFile: profileDir + "/config.json", atomically: true, encoding: .utf8)
        let missing = try makeTempDir() + "/does-not-exist"

        let store = ClaudeDesktopProfileStore(
            homeDirectoryPath: home,
            customProfilePaths: { [profileDir, profileDir, missing] }
        )
        let profiles = store.discoverProfiles()
        #expect(profiles.count == 1)
        // config.json present but no token cache key → nil, not a crash
        #expect(profiles.first?.encryptedTokenCache == nil)
    }
}

@Suite("ClaudeDesktopCredentialLocator")
struct ClaudeDesktopCredentialLocatorTests {
    private func makeProfileDir(config: String) throws -> String {
        let dir = NSTemporaryDirectory() + "cds-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try config.write(toFile: dir + "/config.json", atomically: true, encoding: .utf8)
        return dir
    }

    @Test("locate decrypts and returns the inference credential")
    func locateReturnsCredential() async throws {
        let home = NSTemporaryDirectory() + "cds-home-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let profileDir = try makeProfileDir(config: #"{"oauth:tokenCacheV2":"\#(Vector.base64)"}"#)
        let store = ClaudeDesktopProfileStore(homeDirectoryPath: home, customProfilePaths: { [profileDir] })
        let locator = ClaudeDesktopCredentialLocator(
            profileStore: store,
            keyReader: StubKeyReader(key: Vector.password)
        )
        let credentials = try await locator.locate()
        #expect(credentials.count == 1)
        #expect(credentials.first?.accessToken == "sk-ant-oat01-X")
        #expect(credentials.first?.accountLabel == (profileDir as NSString).lastPathComponent)
    }

    @Test("locate throws noProfiles when nothing is discovered")
    func locateNoProfiles() async throws {
        let home = NSTemporaryDirectory() + "cds-empty-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let store = ClaudeDesktopProfileStore(homeDirectoryPath: home, customProfilePaths: { [] })
        let locator = ClaudeDesktopCredentialLocator(
            profileStore: store,
            keyReader: StubKeyReader(key: Vector.password)
        )
        await #expect(throws: ClaudeDesktopAuthError.noProfiles) {
            _ = try await locator.locate()
        }
    }

    @Test("parseCredentials keeps only inference entries and disambiguates multiple orgs")
    func parseCredentialsMultiOrg() throws {
        let json = """
        {
          "acct:u|s:11111111-1111-1111-1111-111111111111:https://api.anthropic.com:user:inference user:profile": {"token":"tok-a","expiresAt":1900000000000,"subscriptionType":"pro"},
          "acct:u|s:22222222-2222-2222-2222-222222222222:https://api.anthropic.com:user:inference": {"token":"tok-b"},
          "acct:u|s:33333333-3333-3333-3333-333333333333:https://api.anthropic.com:user:profile": {"token":"tok-profile-only"}
        }
        """
        let creds = try ClaudeDesktopCredentialLocator.parseCredentials(plaintext: Data(json.utf8), profileName: "Perso")
        #expect(creds.count == 2)
        #expect(creds.allSatisfy { $0.accountLabel.hasPrefix("Perso · ") })
        #expect(Set(creds.map(\.accessToken)) == ["tok-a", "tok-b"])
    }

    @Test("parseCredentials uses the bare profile name for a single org")
    func parseCredentialsSingleOrg() throws {
        let json = #"{"acct:u|s:11111111-1111-1111-1111-111111111111:https://api.anthropic.com:user:inference":{"token":"tok"}}"#
        let creds = try ClaudeDesktopCredentialLocator.parseCredentials(plaintext: Data(json.utf8), profileName: "Dentalsoft")
        #expect(creds.count == 1)
        #expect(creds.first?.accountLabel == "Dentalsoft")
    }

    @Test("orgUuid extracts the organisation id preceding :https")
    func orgUuidExtraction() {
        let key = "acct:u|s:abcdef01-2345-6789-abcd-ef0123456789:https://api.anthropic.com:user:inference"
        #expect(ClaudeDesktopCredentialLocator.orgUuid(fromCacheKey: key) == "abcdef01-2345-6789-abcd-ef0123456789")
    }

    @Test("accountUuid extracts the id between acct: and the first pipe")
    func accountUuidExtraction() {
        let key = "acct:839b59f1-5fcc-4731-8933-2086e5b040e5|session:org:https://api.anthropic.com:user:inference"
        #expect(ClaudeDesktopCredentialLocator.accountUuid(fromCacheKey: key) == "839b59f1-5fcc-4731-8933-2086e5b040e5")
        #expect(ClaudeDesktopCredentialLocator.accountUuid(fromCacheKey: "no-prefix") == nil)
    }

    @Test("parseExpiresAt accepts ms epoch in several shapes")
    func parseExpiresAtShapes() {
        #expect(ClaudeDesktopCredentialLocator.parseExpiresAt(1_700_000_000_000 as Double) != nil)
        #expect(ClaudeDesktopCredentialLocator.parseExpiresAt(1_700_000_000_000 as Int) != nil)
        #expect(ClaudeDesktopCredentialLocator.parseExpiresAt("1700000000000") != nil)
        #expect(ClaudeDesktopCredentialLocator.parseExpiresAt(nil) == nil)
        #expect(ClaudeDesktopCredentialLocator.parseExpiresAt("not-a-number") == nil)
    }
}

@Suite("HTTPClaudeProfileResolver — parsing")
struct HTTPClaudeProfileResolverTests {
    @Test("parses account.email_address from a profile payload")
    func parsesEmail() {
        let json = #"{"account":{"uuid":"u","email_address":"frederic.camblor@4sh.fr"},"organization":{"uuid":"o","name":"4SH"}}"#
        #expect(HTTPClaudeProfileResolver.parseEmail(Data(json.utf8)) == AccountEmail(rawValue: "frederic.camblor@4sh.fr"))
    }

    @Test("returns nil when the email is missing")
    func missingEmail() {
        let json = #"{"account":{"uuid":"u"}}"#
        #expect(HTTPClaudeProfileResolver.parseEmail(Data(json.utf8)) == nil)
    }
}

@Suite("ClaudeUsageResponseParser — breakdown")
struct ClaudeUsageResponseParserBreakdownTests {
    @Test("breakdown rows become per-product weekly-share metrics")
    func breakdownMetrics() throws {
        let json = """
        {
          "five_hour": {"utilization": 10.0, "resets_at": "2026-10-17T16:20:00+00:00"},
          "seven_day": {"utilization": 60.0, "resets_at": "2026-10-21T04:00:00+00:00"},
          "seven_day_breakdown": {"rows": [
            {"key":"cowork","display_name":"Cowork","percent":97},
            {"key":"chat","display_name":"Chats","percent":3}
          ]}
        }
        """
        let metrics = try ClaudeUsageResponseParser().parseMetrics(Data(json.utf8))
        let names = metrics.compactMap { metric -> String? in
            if case let .timeWindow(name, _, _, _) = metric { return name }
            return nil
        }
        #expect(names.contains("Weekly share · Cowork"))
        #expect(names.contains("Weekly share · Chats"))
    }

    @Test("breakdown is omitted when the weekly window is absent")
    func breakdownRequiresWeekly() throws {
        let json = """
        {
          "five_hour": {"utilization": 10.0, "resets_at": "2026-10-17T16:20:00+00:00"},
          "seven_day_breakdown": {"rows": [{"key":"cowork","display_name":"Cowork","percent":97}]}
        }
        """
        let metrics = try ClaudeUsageResponseParser().parseMetrics(Data(json.utf8))
        let hasBreakdown = metrics.contains { metric in
            if case let .timeWindow(name, _, _, _) = metric { return name.hasPrefix("Weekly share") }
            return false
        }
        #expect(!hasBreakdown)
    }
}
