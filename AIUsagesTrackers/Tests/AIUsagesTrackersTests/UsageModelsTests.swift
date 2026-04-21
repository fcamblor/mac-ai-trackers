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
            vendor: "claude",
            errorMessage: "Elevated errors on Claude.ai, API, Claude Code",
            severity: .major,
            since: "2026-04-15T14:53:00Z",
            href: URL(string: "https://status.claude.com/incidents/f00h6l76tsjs")!
        )
        let data = try encoder.encode(outage)
        let decoded = try decoder.decode(Outage.self, from: data)
        #expect(decoded == outage)
    }

    @Test("outage without href decodes successfully and renders as non-clickable")
    func minimalDecode() throws {
        let json = """
        {"vendor":"claude","errorMessage":"T","severity":"minor","since":"2026-04-15T14:53:00Z"}
        """.data(using: .utf8)!
        let decoded = try decoder.decode(Outage.self, from: json)
        #expect(decoded.vendor == .claude)
        #expect(decoded.errorMessage == "T")
        #expect(decoded.severity == .minor)
        #expect(decoded.since == ISODate(rawValue: "2026-04-15T14:53:00Z"))
        #expect(decoded.href == nil)
    }

    @Test("unknown severity decodes without throwing")
    func unknownSeverity() throws {
        let json = """
        {"vendor":"claude","errorMessage":"T","severity":"partial_outage","since":"2026-04-15T14:53:00Z"}
        """.data(using: .utf8)!
        let decoded = try decoder.decode(Outage.self, from: json)
        #expect(decoded.severity == OutageSeverity(rawValue: "partial_outage"))
    }

    @Test("missing required field throws")
    func missingRequiredField() {
        let json = """
        {"vendor":"claude","severity":"major"}
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
        #expect(decoded.outages.isEmpty)
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
        #expect(Set(decoded.usages.map(\.id)) == Set(file.usages.map(\.id)))
    }

    @Test("file with outages round-trips")
    func fileWithOutagesRoundTrip() throws {
        let file = UsagesFile(
            usages: [VendorUsageEntry(vendor: "claude", account: "a@b.com")],
            outages: [
                Outage(vendor: "claude",
                       errorMessage: "API issues",
                       severity: .major,
                       since: "2026-04-15T14:53:00Z",
                       href: URL(string: "https://status.claude.com/incidents/x")!),
            ]
        )
        let data = try encoder.encode(file)
        let decoded = try decoder.decode(UsagesFile.self, from: data)
        #expect(decoded.outages.count == 1)
        #expect(decoded.outages[0].errorMessage == "API issues")
        #expect(decoded.outagesByVendor[.claude]?.count == 1)
    }

    @Test("encoder omits outages key when array is empty")
    func encoderOmitsOutagesWhenEmpty() throws {
        let file = UsagesFile(usages: [VendorUsageEntry(vendor: "claude", account: "a@b.com")])
        let data = try encoder.encode(file)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["usages"] != nil)
        #expect(json["outages"] == nil)
    }

    @Test("decoder tolerates missing outages key (legacy file)")
    func decoderToleratesMissingOutages() throws {
        let json = """
        {"usages":[{"vendor":"claude","account":"a@b.com","isActive":true,"metrics":[]}]}
        """.data(using: .utf8)!
        let file = try decoder.decode(UsagesFile.self, from: json)
        #expect(file.usages.count == 1)
        #expect(file.outages.isEmpty)
        #expect(file.outagesByVendor.isEmpty)
    }

    @Test("outagesByVendor groups by vendor and omits absent vendors")
    func outagesByVendorGrouping() {
        let file = UsagesFile(outages: [
            Outage(vendor: "claude", errorMessage: "A", severity: .major, since: "2026-04-15T14:53:00Z"),
            Outage(vendor: "claude", errorMessage: "B", severity: .minor, since: "2026-04-15T15:00:00Z"),
            Outage(vendor: "codex",  errorMessage: "C", severity: .minor, since: "2026-04-15T16:00:00Z"),
        ])
        #expect(file.outagesByVendor[.claude]?.count == 2)
        #expect(file.outagesByVendor[Vendor(rawValue: "codex")]?.count == 1)
        #expect(file.outagesByVendor.count == 2)
    }
}
