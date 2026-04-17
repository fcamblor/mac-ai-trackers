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
        // Uses the internal init accessible via @testable import — production code uses .shared.
        return UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
    }

    @Test("read returns empty file when no file exists")
    func readMissing() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let result = await mgr.read()
        #expect(result.usages.isEmpty)
    }

    @Test("update creates file and writes entries")
    func updateCreatesFile() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let entry = VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true, metrics: [
            .timeWindow(name: "session", resetAt: "2026-04-17T15:00:00+00:00",
                        windowDuration: 300, usagePercent: 50),
        ])
        await mgr.update(with: [entry])

        let result = await mgr.read()
        #expect(result.usages.count == 1)
        #expect(result.usages[0].vendor == "claude")
        #expect(result.usages[0].account == "a@b.com")
    }

    @Test("update merges by (vendor, account) — upserts existing")
    func updateUpserts() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)

        let v1 = VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true, metrics: [
            .timeWindow(name: "session", resetAt: "2026-04-17T15:00:00+00:00",
                        windowDuration: 300, usagePercent: 30),
        ])
        await mgr.update(with: [v1])

        let v2 = VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true, metrics: [
            .timeWindow(name: "session", resetAt: "2026-04-17T20:00:00+00:00",
                        windowDuration: 300, usagePercent: 70),
        ])
        await mgr.update(with: [v2])

        let result = await mgr.read()
        #expect(result.usages.count == 1)
        #expect(result.usages[0].metrics == v2.metrics)
    }

    @Test("update appends new vendor without removing existing")
    func updateAppendsNewVendor() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)

        await mgr.update(with: [VendorUsageEntry(vendor: "claude", account: "a@b.com")])
        await mgr.update(with: [VendorUsageEntry(vendor: "codex", account: "c@d.com")])

        let result = await mgr.read()
        #expect(result.usages.count == 2)
        #expect(result.usages.contains(where: { $0.vendor == "claude" }))
        #expect(result.usages.contains(where: { $0.vendor == "codex" }))
    }

    @Test("merge logic — same vendor different account appends")
    func mergeDifferentAccounts() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let existing = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com"),
        ])
        let incoming = [VendorUsageEntry(vendor: "claude", account: "other@b.com")]
        let merged = await mgr.merge(existing: existing, incoming: incoming)
        #expect(merged.usages.count == 2)
    }

    // MARK: - lastError cleanup on success

    @Test("merge clears lastError when same account fetch succeeds")
    func mergeSuccessClearsLastError() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let errorEntry = VendorUsageEntry(
            vendor: "claude", account: "a@b.com",
            lastError: UsageError(timestamp: "2026-04-17T10:00:00+00:00", type: "api_error")
        )
        await mgr.update(with: [errorEntry])

        let successEntry = VendorUsageEntry(
            vendor: "claude", account: "a@b.com", isActive: true,
            lastAcquiredOn: "2026-04-17T11:00:00+00:00",
            metrics: [.timeWindow(name: "session", resetAt: "2026-04-17T16:00:00+00:00",
                                  windowDuration: 300, usagePercent: 10)]
        )
        await mgr.update(with: [successEntry])

        let result = await mgr.read()
        #expect(result.usages.count == 1)
        #expect(result.usages[0].lastError == nil)
    }

    @Test("merge removes stale account_unknown entry when real account fetch succeeds")
    func mergeRemovesUnknownAccountPlaceholderOnSuccess() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let placeholderError = VendorUsageEntry(
            vendor: "claude", account: "unknown",
            lastError: UsageError(timestamp: "2026-04-17T10:00:00+00:00", type: "account_unknown")
        )
        await mgr.update(with: [placeholderError])

        let successEntry = VendorUsageEntry(
            vendor: "claude", account: "real@b.com", isActive: true,
            lastAcquiredOn: "2026-04-17T11:00:00+00:00",
            metrics: [.timeWindow(name: "session", resetAt: "2026-04-17T16:00:00+00:00",
                                  windowDuration: 300, usagePercent: 20)]
        )
        await mgr.update(with: [successEntry])

        let result = await mgr.read()
        #expect(result.usages.count == 1)
        #expect(result.usages[0].account == "real@b.com")
        #expect(result.usages[0].lastError == nil)
    }

    @Test("merge keeps error entries for other vendors when one vendor succeeds")
    func mergeKeepsOtherVendorErrorsOnSuccess() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let claudeError = VendorUsageEntry(
            vendor: "claude", account: "a@b.com",
            lastError: UsageError(timestamp: "2026-04-17T10:00:00+00:00", type: "api_error")
        )
        let codexError = VendorUsageEntry(
            vendor: "codex", account: "a@b.com",
            lastError: UsageError(timestamp: "2026-04-17T10:00:00+00:00", type: "api_error")
        )
        await mgr.update(with: [claudeError, codexError])

        let claudeSuccess = VendorUsageEntry(
            vendor: "claude", account: "a@b.com", isActive: true,
            lastAcquiredOn: "2026-04-17T11:00:00+00:00",
            metrics: []
        )
        await mgr.update(with: [claudeSuccess])

        let result = await mgr.read()
        let codexEntry = result.usages.first { $0.vendor == "codex" }
        #expect(codexEntry != nil)
        #expect(codexEntry?.lastError?.type == "api_error")
    }

    @Test("merge preserves prior successful entry for other account when new account errors")
    func mergePreservesSuccessfulEntryForOtherAccount() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)

        // Account A had a prior successful fetch (lastError nil, lastAcquiredOn set)
        let accountASuccess = VendorUsageEntry(
            vendor: "claude", account: "a@b.com", isActive: false,
            lastAcquiredOn: "2026-04-17T09:00:00+00:00",
            metrics: []
        )
        await mgr.update(with: [accountASuccess])

        // Account B has an error; account A's entry (which has no error) must be preserved
        let accountBError = VendorUsageEntry(
            vendor: "claude", account: "b@b.com",
            lastError: UsageError(timestamp: "2026-04-17T11:00:00+00:00", type: "api_error")
        )
        await mgr.update(with: [accountBError])

        let result = await mgr.read()
        let entryA = result.usages.first { $0.account == "a@b.com" }
        #expect(entryA != nil)
        #expect(entryA?.lastError == nil)
    }

    @Test("read handles corrupt JSON gracefully")
    func readCorruptJSON() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        try! "not json".write(toFile: mgr.filePath, atomically: true, encoding: .utf8)
        let result = await mgr.read()
        #expect(result.usages.isEmpty)
    }

    @Test("JSON output is pretty-printed and human-readable")
    func jsonIsPrettyPrinted() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        await mgr.update(with: [VendorUsageEntry(vendor: "claude", account: "a@b.com")])
        let raw = try! String(contentsOfFile: mgr.filePath, encoding: .utf8)
        #expect(raw.contains("\n"))
        #expect(raw.contains("\"vendor\""))
    }

    // MARK: - updateIsActive

    @Test("updateIsActive marks the matching account active and others inactive")
    func updateIsActiveMarksCorrectAccount() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        await mgr.update(with: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: false),
            VendorUsageEntry(vendor: "claude", account: "c@d.com", isActive: false),
        ])

        await mgr.updateIsActive(vendor: "claude", activeAccount: "a@b.com")

        let result = await mgr.read()
        let byAccount = Dictionary(uniqueKeysWithValues: result.usages.map { ($0.account, $0.isActive) })
        #expect(byAccount["a@b.com"] == true)
        #expect(byAccount["c@d.com"] == false)
    }

    @Test("updateIsActive sets all accounts inactive when activeAccount is nil")
    func updateIsActiveNilDeactivatesAll() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        await mgr.update(with: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: true),
        ])

        await mgr.updateIsActive(vendor: "claude", activeAccount: nil)

        let result = await mgr.read()
        #expect(result.usages[0].isActive == false)
    }

    @Test("updateIsActive does not touch entries of other vendors")
    func updateIsActiveIgnoresOtherVendors() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        await mgr.update(with: [
            VendorUsageEntry(vendor: "claude", account: "a@b.com", isActive: false),
            VendorUsageEntry(vendor: "codex", account: "a@b.com", isActive: true),
        ])

        await mgr.updateIsActive(vendor: "claude", activeAccount: "a@b.com")

        let result = await mgr.read()
        let claudeEntry = result.usages.first { $0.vendor == "claude" }!
        let codexEntry  = result.usages.first { $0.vendor == "codex" }!
        #expect(claudeEntry.isActive == true)
        #expect(codexEntry.isActive == true)
    }

    @Test("updateIsActive is a no-op when file is empty")
    func updateIsActiveNoOpOnEmptyFile() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        await mgr.updateIsActive(vendor: "claude", activeAccount: "a@b.com")
        let result = await mgr.read()
        #expect(result.usages.isEmpty)
    }
}
