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

    @Test("unknown type discriminator throws")
    func unknownTypeThrows() throws {
        let bad = #"{"type":"unknown","name":"x"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try decoder.decode(UsageMetric.self, from: bad)
        }
    }

    @Test("missing required field throws")
    func missingFieldThrows() throws {
        let bad = #"{"type":"time-window","name":"x"}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) {
            try decoder.decode(UsageMetric.self, from: bad)
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
    @Test("empty file round-trips")
    func emptyRoundTrip() throws {
        let file = UsagesFile()
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(UsagesFile.self, from: data)
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
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(UsagesFile.self, from: data)
        #expect(decoded == file)
        #expect(decoded.usages.count == 2)
    }
}
