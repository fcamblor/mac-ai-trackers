import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - UsageMetric Codable round-trip

@Suite("UsageMetric encoding/decoding")
struct UsageMetricCodableTests {
    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    let decoder = JSONDecoder()

    @Test("time-window round-trips through JSON")
    func timeWindowRoundTrip() throws {
        let metric = UsageMetric.timeWindow(
            name: "session",
            resetAt: "2026-04-17T15:00:00+00:00",
            windowDuration: 300,
            usagePercent: 42
        )
        let data = try encoder.encode(metric)
        let decoded = try decoder.decode(UsageMetric.self, from: data)
        #expect(decoded == metric)
    }

    @Test("pay-as-you-go round-trips through JSON")
    func payAsYouGoRoundTrip() throws {
        let metric = UsageMetric.payAsYouGo(name: "monthly", currentAmount: 12.50, currency: "USD")
        let data = try encoder.encode(metric)
        let decoded = try decoder.decode(UsageMetric.self, from: data)
        #expect(decoded == metric)
    }

    @Test("time-window JSON contains type discriminator")
    func timeWindowDiscriminator() throws {
        let metric = UsageMetric.timeWindow(
            name: "weekly",
            resetAt: "2026-04-23T21:00:00+00:00",
            windowDuration: 10080,
            usagePercent: 8
        )
        let data = try encoder.encode(metric)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "time-window")
        #expect(json["name"] as? String == "weekly")
    }

    @Test("pay-as-you-go JSON contains type discriminator")
    func payAsYouGoDiscriminator() throws {
        let metric = UsageMetric.payAsYouGo(name: "usage", currentAmount: 0, currency: "EUR")
        let data = try encoder.encode(metric)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "pay-as-you-go")
    }

    @Test("unknown type discriminator decodes as .unknown instead of throwing")
    func unknownTypeDecodesAsUnknown() throws {
        let json = #"{"type":"unknown","name":"x"}"#.data(using: .utf8)!
        let decoded = try decoder.decode(UsageMetric.self, from: json)
        #expect(decoded == .unknown("unknown"))
    }

    @Test("unknown metric type round-trips through JSON")
    func unknownTypeRoundTrips() throws {
        let metric = UsageMetric.unknown("future-type")
        let data = try encoder.encode(metric)
        let decoded = try decoder.decode(UsageMetric.self, from: data)
        #expect(decoded == metric)
    }

    @Test("missing required field throws")
    func missingFieldThrows() throws {
        let bad = #"{"type":"time-window","name":"x"}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try decoder.decode(UsageMetric.self, from: bad)
        }
    }
}

// MARK: - Outage Codable

@Suite("Outage encoding/decoding")
struct OutageCodableTests {
    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    let decoder = JSONDecoder()

    @Test("full outage round-trips through JSON")
    func fullRoundTrip() throws {
        let outage = Outage(
            id: "abcd-1234",
            title: "Elevated error rate on Messages API",
            severity: .major,
            affectedComponents: ["Claude API", "Console"],
            status: "investigating",
            startedAt: "2026-04-19T11:32:00Z",
            url: URL(string: "https://status.claude.com/incidents/abcd-1234")!
        )
        let data = try encoder.encode(outage)
        let decoded = try decoder.decode(Outage.self, from: data)
        #expect(decoded == outage)
    }

    @Test("minimal outage (only required fields) decodes successfully")
    func minimalDecode() throws {
        let json = """
        {"id":"x","title":"Test","severity":"minor"}
        """.data(using: .utf8)!
        let decoded = try decoder.decode(Outage.self, from: json)
        #expect(decoded.id == OutageId(rawValue: "x"))
        #expect(decoded.title == "Test")
        #expect(decoded.severity == .minor)
        #expect(decoded.affectedComponents.isEmpty)
        #expect(decoded.status == nil)
        #expect(decoded.startedAt == nil)
        #expect(decoded.url == nil)
    }

    @Test("unknown severity decodes without throwing")
    func unknownSeverity() throws {
        let json = """
        {"id":"x","title":"T","severity":"partial_outage"}
        """.data(using: .utf8)!
        let decoded = try decoder.decode(Outage.self, from: json)
        #expect(decoded.severity == OutageSeverity(rawValue: "partial_outage"))
    }

    @Test("missing required field throws")
    func missingRequiredField() {
        let json = """
        {"id":"x","severity":"major"}
        """.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try decoder.decode(Outage.self, from: json)
        }
    }
}

// MARK: - VendorUsageEntry

@Suite("VendorUsageEntry Codable")
struct VendorUsageEntryTests {
    @Test("full entry round-trips")
    func fullRoundTrip() throws {
        let entry = VendorUsageEntry(
            vendor: "claude",
            account: "user@example.com",
            isActive: true,
            lastAcquiredOn: "2026-04-17T10:00:00+00:00",
            lastError: nil,
            metrics: [
                .timeWindow(name: "session", resetAt: "2026-04-17T15:00:00+00:00",
                            windowDuration: 300, usagePercent: 42),
                .timeWindow(name: "weekly", resetAt: "2026-04-23T21:00:00+00:00",
                            windowDuration: 10080, usagePercent: 8),
            ]
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(VendorUsageEntry.self, from: data)
        #expect(decoded == entry)
    }

    @Test("entry with error round-trips")
    func errorEntryRoundTrip() throws {
        let entry = VendorUsageEntry(
            vendor: "claude",
            account: "user@example.com",
            isActive: true,
            lastError: UsageError(timestamp: "2026-04-17T10:00:00+00:00", type: "api_error"),
            metrics: []
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(VendorUsageEntry.self, from: data)
        #expect(decoded == entry)
        #expect(decoded.lastError?.type == "api_error")
    }
}

// MARK: - UsagesFile

@Suite("UsagesFile Codable")
struct UsagesFileTests {
    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    let decoder = JSONDecoder()

    @Test("empty file round-trips")
    func emptyRoundTrip() throws {
        let file = UsagesFile()
        let data = try encoder.encode(file)
        let decoded = try decoder.decode(UsagesFile.self, from: data)
        #expect(decoded.usages.isEmpty)
    }

    @Test("file with multiple vendors round-trips")
    func multiVendorRoundTrip() throws {
        let file = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", metrics: [
                .timeWindow(name: "session", resetAt: "2026-04-17T15:00:00+00:00",
                            windowDuration: 300, usagePercent: 42),
            ]),
            VendorUsageEntry(vendor: "codex", account: "c@d.com", metrics: [
                .payAsYouGo(name: "monthly", currentAmount: 5.0, currency: "USD"),
            ]),
        ])
        let data = try encoder.encode(file)
        let decoded = try decoder.decode(UsagesFile.self, from: data)
        #expect(decoded.usages.count == 2)
        // Entries are the same but order may differ (dictionary iteration)
        #expect(Set(decoded.usages.map(\.id)) == Set(file.usages.map(\.id)))
    }

    @Test("legacy v1 shape decodes transparently")
    func legacyV1Decode() throws {
        let json = """
        {"usages":[{"vendor":"claude","account":"a@b.com","isActive":true,"metrics":[]}]}
        """.data(using: .utf8)!
        let file = try decoder.decode(UsagesFile.self, from: json)
        #expect(file.usages.count == 1)
        #expect(file.usages[0].vendor == .claude)
        #expect(file.usages[0].account == AccountEmail(rawValue: "a@b.com"))
        // No outages from legacy shape
        #expect(file.outagesByVendor.isEmpty)
    }

    @Test("v2 shape with outages decodes correctly")
    func v2WithOutages() throws {
        let json = """
        {
          "schemaVersion": 2,
          "vendors": {
            "claude": {
              "accounts": [
                {"account":"a@b.com","isActive":true,"metrics":[]}
              ],
              "outages": [
                {"id":"inc-1","title":"API issues","severity":"major"}
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let file = try decoder.decode(UsagesFile.self, from: json)
        #expect(file.usages.count == 1)
        #expect(file.usages[0].vendor == .claude)
        #expect(file.outagesByVendor[.claude]?.count == 1)
        #expect(file.outagesByVendor[.claude]?[0].title == "API issues")
    }

    @Test("encode always emits v2 with schemaVersion")
    func encodeAlwaysV2() throws {
        let file = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com"),
        ])
        let data = try encoder.encode(file)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["schemaVersion"] as? Int == 2)
        #expect(json["vendors"] != nil)
        #expect(json["usages"] == nil)
    }

    @Test("legacy decode then encode produces v2 shape")
    func legacyMigrationOnEncode() throws {
        let v1 = """
        {"usages":[{"vendor":"claude","account":"a@b.com","isActive":true,"metrics":[]}]}
        """.data(using: .utf8)!
        let file = try decoder.decode(UsagesFile.self, from: v1)
        let encoded = try encoder.encode(file)
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect(json["schemaVersion"] as? Int == 2)
        #expect(json["usages"] == nil)
    }

    @Test("outagesByVendor omits vendors with no outages")
    func outagesByVendorFiltering() {
        let file = UsagesFile(vendors: [
            .claude: VendorSection(
                accounts: [VendorAccountEntry(account: "a@b.com")],
                outages: [Outage(id: "x", title: "T", severity: .minor)]
            ),
            Vendor(rawValue: "codex"): VendorSection(
                accounts: [VendorAccountEntry(account: "c@d.com")],
                outages: []
            ),
        ])
        #expect(file.outagesByVendor.count == 1)
        #expect(file.outagesByVendor[.claude] != nil)
    }

    @Test("usages setter preserves existing outages")
    func usagesSetterPreservesOutages() {
        var file = UsagesFile(vendors: [
            .claude: VendorSection(
                accounts: [VendorAccountEntry(account: "a@b.com")],
                outages: [Outage(id: "x", title: "T", severity: .major)]
            ),
        ])
        // Overwriting usages should keep outages
        file.usages = [VendorUsageEntry(vendor: "claude", account: "new@b.com")]
        #expect(file.outagesByVendor[.claude]?.count == 1)
        #expect(file.usages.count == 1)
        #expect(file.usages[0].account == AccountEmail(rawValue: "new@b.com"))
    }
}
