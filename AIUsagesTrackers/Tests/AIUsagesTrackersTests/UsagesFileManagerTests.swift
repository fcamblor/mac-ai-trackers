import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("UsagesFileManager")
struct UsagesFileManagerTests {
    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-tests-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManager(dir: String) -> UsagesFileManager {
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        return UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
    }

    @Test("read returns empty file when no file exists")
    func readMissing() {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let result = mgr.read()
        #expect(result.usages.isEmpty)
    }

    @Test("update creates file and writes entries")
    func updateCreatesFile() {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let entry = VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true, metrics: [
            .timeWindow(name: "session", resetAt: "2026-04-17T15:00:00+00:00",
                        windowDurationMinutes: 300, usagePercent: 50),
        ])
        mgr.update(with: [entry])

        let result = mgr.read()
        #expect(result.usages.count == 1)
        #expect(result.usages[0].vendor == "claude")
        #expect(result.usages[0].account == "a@b.com")
    }

    @Test("update merges by (vendor, account) — upserts existing")
    func updateUpserts() {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)

        let v1 = VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true, metrics: [
            .timeWindow(name: "session", resetAt: "2026-04-17T15:00:00+00:00",
                        windowDurationMinutes: 300, usagePercent: 30),
        ])
        mgr.update(with: [v1])

        let v2 = VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true, metrics: [
            .timeWindow(name: "session", resetAt: "2026-04-17T20:00:00+00:00",
                        windowDurationMinutes: 300, usagePercent: 70),
        ])
        mgr.update(with: [v2])

        let result = mgr.read()
        #expect(result.usages.count == 1)
        #expect(result.usages[0].metrics == v2.metrics)
    }

    @Test("update appends new vendor without removing existing")
    func updateAppendsNewVendor() {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)

        mgr.update(with: [VendorUsageEntry(vendor: "claude", account: "a@b.com")])
        mgr.update(with: [VendorUsageEntry(vendor: "codex", account: "c@d.com")])

        let result = mgr.read()
        #expect(result.usages.count == 2)
        #expect(result.usages.contains(where: { $0.vendor == "claude" }))
        #expect(result.usages.contains(where: { $0.vendor == "codex" }))
    }

    @Test("merge logic — same vendor different account appends")
    func mergeDifferentAccounts() {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let existing = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com"),
        ])
        let incoming = [VendorUsageEntry(vendor: "claude", account: "other@b.com")]
        let merged = mgr.merge(existing: existing, incoming: incoming)
        #expect(merged.usages.count == 2)
    }

    @Test("read handles corrupt JSON gracefully")
    func readCorruptJSON() {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        try! "not json".write(toFile: mgr.filePath, atomically: true, encoding: .utf8)
        let result = mgr.read()
        #expect(result.usages.isEmpty)
    }

    @Test("JSON output is pretty-printed and human-readable")
    func jsonIsPrettyPrinted() {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        mgr.update(with: [VendorUsageEntry(vendor: "claude", account: "a@b.com")])
        let raw = try! String(contentsOfFile: mgr.filePath, encoding: .utf8)
        #expect(raw.contains("\n"))
        #expect(raw.contains("\"vendor\""))
    }

    @Test("read returns empty when lock file cannot be opened")
    func readFailsGracefullyOnBadLockPath() {
        // Point to a non-existent directory so open(O_CREAT) fails
        let logger = FileLogger(filePath: "/tmp/ai-tracker-flock-test-\(UUID())/test.log", minLevel: .debug)
        let mgr = UsagesFileManager(filePath: "/nonexistent-dir-\(UUID())/usages.json", logger: logger)
        let result = mgr.read()
        #expect(result.usages.isEmpty)
    }
}
