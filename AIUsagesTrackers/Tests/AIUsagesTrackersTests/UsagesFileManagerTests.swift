import Darwin
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

    @Test("late poll and monitor writes leave restored legacy bytes intact until resumed")
    func suspendedWritesProtectDowngradeRestore() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = makeManager(dir: dir)
        let entry = VendorUsageEntry(vendor: .claudeTUI, account: "a@b.com", isActive: false)
        let encoded = try JSONEncoder().encode(UsagesFile(usages: [entry]))
        let legacy = Data(String(decoding: encoded, as: UTF8.self)
            .replacingOccurrences(of: "claude-tui", with: "claude").utf8)
        let file = URL(fileURLWithPath: mgr.filePath)
        try legacy.write(to: file, options: .atomic)
        let suite = "downgrade-write-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backup = PreMigrationBackup(directory: URL(fileURLWithPath: dir).appendingPathComponent("backup"), files: [file])
        try backup.create(defaults: defaults)
        await mgr.update(with: [entry])
        #expect(try Data(contentsOf: file) != legacy)

        await mgr.setWritesSuspended(true)
        try backup.restore(defaults: defaults)
        // These model a fetch completing after cancellation and a monitor that
        // was already running when the user requested the restore.
        await mgr.update(with: [VendorUsageEntry(vendor: .claudeDesktop, account: "new@b.com")])
        await mgr.updateIsActive(vendor: .claudeTUI, activeAccount: "a@b.com")
        #expect(try Data(contentsOf: file) == legacy)

        await mgr.setWritesSuspended(false)
        await mgr.update(with: [entry])
        #expect(try Data(contentsOf: file) != legacy)
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
        let entry = VendorUsageEntry(vendor: "claude-tui", account: "a@b.com", isActive: true, metrics: [
            .timeWindow(name: "session", resetAt: "2026-04-17T15:00:00+00:00",
                        windowDuration: 300, usagePercent: 50),
        ])
        await mgr.update(with: [entry])

        let result = await mgr.read()
        #expect(result.usages.count == 1)
        #expect(result.usages[0].vendor == "claude-tui")
        #expect(result.usages[0].account == "a@b.com")
    }

    @Test("update merges by (vendor, account) — upserts existing")
    func updateUpserts() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)

        let v1 = VendorUsageEntry(vendor: "claude-tui", account: "a@b.com", isActive: true, metrics: [
            .timeWindow(name: "session", resetAt: "2026-04-17T15:00:00+00:00",
                        windowDuration: 300, usagePercent: 30),
        ])
        await mgr.update(with: [v1])

        let v2 = VendorUsageEntry(vendor: "claude-tui", account: "a@b.com", isActive: true, metrics: [
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

        await mgr.update(with: [VendorUsageEntry(vendor: "claude-tui", account: "a@b.com")])
        await mgr.update(with: [VendorUsageEntry(vendor: "codex", account: "c@d.com")])

        let result = await mgr.read()
        #expect(result.usages.count == 2)
        #expect(result.usages.contains(where: { $0.vendor == "claude-tui" }))
        #expect(result.usages.contains(where: { $0.vendor == "codex" }))
    }

    @Test("merge logic — same vendor different account appends")
    func mergeDifferentAccounts() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let existing = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude-tui", account: "a@b.com"),
        ])
        let incoming = [VendorUsageEntry(vendor: "claude-tui", account: "other@b.com")]
        let merged = await mgr.merge(existing: existing, incoming: incoming)
        #expect(merged.usages.count == 2)
    }

    @Test("merge collapses pre-existing duplicate keys, keeping the freshest entry")
    func mergeCollapsesExistingDuplicates() async {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = makeManager(dir: dir)
        let stale = VendorUsageEntry(vendor: "claude-tui", account: "a@b.com",
                                     lastAcquiredOn: "2026-10-18T12:59:11Z")
        let fresh = VendorUsageEntry(vendor: "claude-tui", account: "a@b.com",
                                     lastAcquiredOn: "2026-10-18T18:38:18Z")
        let other = VendorUsageEntry(vendor: "codex", account: "a@b.com")

        for order in [[fresh, other, stale], [stale, other, fresh]] {
            let merged = await mgr.merge(existing: UsagesFile(usages: order), incoming: [])
            #expect(merged.usages.count == 2)
            #expect(merged.usages.first(where: { $0.vendor == "claude-tui" })?.lastAcquiredOn == fresh.lastAcquiredOn)
        }
    }

    @Test("update heals a file holding duplicate entries for the same key")
    func updateHealsDuplicateEntriesInFile() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = makeManager(dir: dir)
        let duplicated = UsagesFile(usages: [
            VendorUsageEntry(vendor: "claude-tui", account: "a@b.com", lastAcquiredOn: "2026-10-18T12:59:11Z"),
            VendorUsageEntry(vendor: "claude-tui", account: "a@b.com", lastAcquiredOn: "2026-10-18T18:38:18Z"),
        ])
        try JSONEncoder().encode(duplicated).write(to: URL(fileURLWithPath: mgr.filePath), options: .atomic)

        let incoming = VendorUsageEntry(vendor: "claude-tui", account: "a@b.com", isActive: true,
                                        lastAcquiredOn: "2026-10-18T18:42:48Z")
        await mgr.update(with: [incoming])

        let result = await mgr.read()
        #expect(result.usages.count == 1)
        #expect(result.usages.first?.lastAcquiredOn == incoming.lastAcquiredOn)
    }

    @Test("isFresher ranks missing dates oldest and lets ties go to the candidate")
    func isFresherOrdering() {
        let dated = VendorUsageEntry(vendor: "codex", account: "a@b.com", lastAcquiredOn: "2026-10-18T12:00:00Z")
        let undated = VendorUsageEntry(vendor: "codex", account: "a@b.com")
        #expect(UsagesFileManager.isFresher(dated, than: undated))
        #expect(!UsagesFileManager.isFresher(undated, than: dated))
        #expect(UsagesFileManager.isFresher(dated, than: dated))
    }

    // MARK: - lastError cleanup on success

    @Test("merge clears lastError when same account fetch succeeds")
    func mergeSuccessClearsLastError() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let errorEntry = VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com",
            lastError: UsageError(timestamp: "2026-04-17T10:00:00+00:00", type: "api_error")
        )
        await mgr.update(with: [errorEntry])

        let successEntry = VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com", isActive: true,
            lastAcquiredOn: "2026-04-17T11:00:00+00:00",
            metrics: [.timeWindow(name: "session", resetAt: "2026-04-17T16:00:00+00:00",
                                  windowDuration: 300, usagePercent: 10)]
        )
        await mgr.update(with: [successEntry])

        let result = await mgr.read()
        #expect(result.usages.count == 1)
        #expect(result.usages[0].lastError == nil)
    }

    @Test("merge does not persist account_unknown placeholder")
    func mergeDoesNotPersistAccountUnknownPlaceholder() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let placeholderError = VendorUsageEntry(
            vendor: "claude-tui", account: "unknown",
            lastError: UsageError(timestamp: "2026-04-17T10:00:00+00:00", type: "account_unknown")
        )
        await mgr.update(with: [placeholderError])

        let result = await mgr.read()
        #expect(result.usages.isEmpty)
    }

    @Test("merge removes account_unknown placeholder when real account fetch succeeds")
    func mergeRemovesUnknownAccountPlaceholderOnSuccess() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let placeholderError = VendorUsageEntry(
            vendor: "claude-tui", account: "unknown",
            lastError: UsageError(timestamp: "2026-04-17T10:00:00+00:00", type: "account_unknown")
        )
        let existing = UsagesFile(usages: [placeholderError])

        let successEntry = VendorUsageEntry(
            vendor: "claude-tui", account: "real@b.com", isActive: true,
            lastAcquiredOn: "2026-04-17T11:00:00+00:00",
            metrics: [.timeWindow(name: "session", resetAt: "2026-04-17T16:00:00+00:00",
                                  windowDuration: 300, usagePercent: 20)]
        )
        let result = await mgr.merge(existing: existing, incoming: [successEntry])

        #expect(result.usages.count == 1)
        #expect(result.usages.contains(where: { $0.account == "real@b.com" && $0.lastError == nil }))
        #expect(!result.usages.contains(where: { $0.account == "unknown" && $0.lastError?.type == "account_unknown" }))
    }

    @Test("merge keeps error entries for other vendors when one vendor succeeds")
    func mergeKeepsOtherVendorErrorsOnSuccess() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let claudeError = VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com",
            lastError: UsageError(timestamp: "2026-04-17T10:00:00+00:00", type: "api_error")
        )
        let codexError = VendorUsageEntry(
            vendor: "codex", account: "a@b.com",
            lastError: UsageError(timestamp: "2026-04-17T10:00:00+00:00", type: "api_error")
        )
        await mgr.update(with: [claudeError, codexError])

        let claudeSuccess = VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com", isActive: true,
            lastAcquiredOn: "2026-04-17T11:00:00+00:00",
            metrics: []
        )
        await mgr.update(with: [claudeSuccess])

        let result = await mgr.read()
        let codexEntry = result.usages.first { $0.vendor == "codex" }
        #expect(codexEntry != nil)
        #expect(codexEntry?.lastError?.type == "api_error")
    }

    @Test("merge keeps old account entry with metrics even if it has an error when new account succeeds")
    func mergeKeepsOldAccountWithMetricsOnErrorWhenOtherAccountSucceeds() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)

        // Account A: had good data previously (metrics preserved in file), but last fetch failed
        let oldMetrics: [UsageMetric] = [
            .timeWindow(name: "session", resetAt: "2026-04-17T15:00:00+00:00",
                        windowDuration: 300, usagePercent: 42),
        ]
        await mgr.update(with: [VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com", isActive: false,
            lastAcquiredOn: "2026-04-17T09:00:00+00:00",
            metrics: oldMetrics
        )])
        // Simulate a failed fetch for A (metrics are preserved by the merge, but lastError is set)
        await mgr.update(with: [VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com", isActive: false,
            lastError: UsageError(timestamp: "2026-04-17T10:00:00+00:00", type: "api_error"),
            metrics: []
        )])

        // Account B now succeeds — A's entry (which has metrics despite the error) must survive
        let bMetrics: [UsageMetric] = [
            .timeWindow(name: "session", resetAt: "2026-04-17T20:00:00+00:00",
                        windowDuration: 300, usagePercent: 10),
        ]
        await mgr.update(with: [VendorUsageEntry(
            vendor: "claude-tui", account: "b@b.com", isActive: true,
            lastAcquiredOn: "2026-04-17T11:00:00+00:00",
            metrics: bMetrics
        )])

        let result = await mgr.read()
        let entryA = result.usages.first { $0.account == "a@b.com" }
        #expect(entryA != nil, "Account A entry must be preserved after account B succeeds")
        #expect(entryA?.metrics == oldMetrics, "Account A metrics must survive the account switch")
        #expect(entryA?.lastError?.type == "api_error")
    }

    @Test("merge preserves prior successful entry for other account when new account errors")
    func mergePreservesSuccessfulEntryForOtherAccount() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)

        // Account A had a prior successful fetch (lastError nil, lastAcquiredOn set)
        let accountASuccess = VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com", isActive: false,
            lastAcquiredOn: "2026-04-17T09:00:00+00:00",
            metrics: []
        )
        await mgr.update(with: [accountASuccess])

        // Account B has an error; account A's entry (which has no error) must be preserved
        let accountBError = VendorUsageEntry(
            vendor: "claude-tui", account: "b@b.com",
            lastError: UsageError(timestamp: "2026-04-17T11:00:00+00:00", type: "api_error")
        )
        await mgr.update(with: [accountBError])

        let result = await mgr.read()
        let entryA = result.usages.first { $0.account == "a@b.com" }
        #expect(entryA != nil)
        #expect(entryA?.lastError == nil)
    }

    // MARK: - metrics preservation on error

    @Test("merge preserves existing metrics when error entry has empty metrics")
    func mergePreservesMetricsOnError() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let existingMetrics: [UsageMetric] = [
            .timeWindow(name: "session", resetAt: "2026-04-17T15:00:00+00:00",
                        windowDuration: 300, usagePercent: 42),
            .timeWindow(name: "weekly", resetAt: "2026-04-23T19:00:00+00:00",
                        windowDuration: 10080, usagePercent: 20),
        ]
        await mgr.update(with: [VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com", isActive: true,
            lastAcquiredOn: "2026-04-17T14:00:00+00:00",
            metrics: existingMetrics
        )])

        // Simulate a 429 after restart: connector's lastKnownMetrics is empty
        let errorEntry = VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com", isActive: true,
            lastError: UsageError(timestamp: "2026-04-17T15:00:00+00:00", type: "http_429"),
            metrics: []
        )
        await mgr.update(with: [errorEntry])

        let result = await mgr.read()
        #expect(result.usages.count == 1)
        #expect(result.usages[0].lastError?.type == "http_429")
        #expect(result.usages[0].metrics == existingMetrics)
    }

    @Test("merge clears existing metrics when token_error entry has empty metrics")
    func mergeClearsMetricsOnTokenError() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        await mgr.update(with: [VendorUsageEntry(
            vendor: "copilot", account: "LivioGama", isActive: true,
            lastAcquiredOn: "2026-04-17T14:00:00+00:00",
            metrics: [.timeWindow(name: "Premium", resetAt: "2026-06-01T00:00:00Z",
                                  windowDuration: 43200, usagePercent: 100)]
        )])

        let errorEntry = VendorUsageEntry(
            vendor: "copilot", account: "LivioGama", isActive: true,
            lastError: UsageError(timestamp: "2026-04-17T15:00:00+00:00", type: UsageErrorType.tokenError),
            metrics: []
        )
        await mgr.update(with: [errorEntry])

        let result = await mgr.read()
        #expect(result.usages[0].lastError?.type == UsageErrorType.tokenError)
        #expect(result.usages[0].metrics.isEmpty)
    }

    @Test("merge preserves lastAcquiredOn when error entry has nil lastAcquiredOn")
    func mergePreservesLastAcquiredOnOnError() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let acquiredOn: ISODate = "2026-04-17T14:00:00+00:00"
        await mgr.update(with: [VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com", isActive: true,
            lastAcquiredOn: acquiredOn,
            metrics: []
        )])

        let errorEntry = VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com", isActive: true,
            lastAcquiredOn: nil,
            lastError: UsageError(timestamp: "2026-04-17T15:00:00+00:00", type: "http_429"),
            metrics: []
        )
        await mgr.update(with: [errorEntry])

        let result = await mgr.read()
        #expect(result.usages[0].lastAcquiredOn == acquiredOn)
        #expect(result.usages[0].lastError?.type == "http_429")
    }

    @Test("merge preserves accountStatus when error entry carries none")
    func mergePreservesAccountStatusOnError() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let status = AccountStatus(plan: "pro", resetCredits: ResetCredits(available: 2, applicable: 1))
        await mgr.update(with: [VendorUsageEntry(
            vendor: "codex", account: "a@b.com", isActive: true,
            lastAcquiredOn: "2026-04-17T14:00:00+00:00",
            accountStatus: status
        )])

        await mgr.update(with: [VendorUsageEntry(
            vendor: "codex", account: "a@b.com", isActive: true,
            lastError: UsageError(timestamp: "2026-04-17T15:00:00+00:00", type: "api_error")
        )])

        let result = await mgr.read()
        #expect(result.usages[0].accountStatus == status)
    }

    @Test("merge uses incoming metrics from error entry when connector provides them (lastKnownMetrics populated)")
    func mergeUsesIncomingMetricsFromErrorWhenPresent() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let oldMetrics: [UsageMetric] = [
            .timeWindow(name: "session", resetAt: "2026-04-17T12:00:00+00:00",
                        windowDuration: 300, usagePercent: 10),
        ]
        await mgr.update(with: [VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com", isActive: true,
            lastAcquiredOn: "2026-04-17T11:00:00+00:00",
            metrics: oldMetrics
        )])

        // Connector had a successful fetch earlier in the same session: lastKnownMetrics is set
        let freshMetrics: [UsageMetric] = [
            .timeWindow(name: "session", resetAt: "2026-04-17T15:00:00+00:00",
                        windowDuration: 300, usagePercent: 55),
        ]
        let errorEntryWithMetrics = VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com", isActive: true,
            lastError: UsageError(timestamp: "2026-04-17T16:00:00+00:00", type: "http_429"),
            metrics: freshMetrics
        )
        await mgr.update(with: [errorEntryWithMetrics])

        let result = await mgr.read()
        #expect(result.usages[0].metrics == freshMetrics)
        #expect(result.usages[0].lastError?.type == "http_429")
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
        await mgr.update(with: [VendorUsageEntry(vendor: "claude-tui", account: "a@b.com")])
        let raw = try! String(contentsOfFile: mgr.filePath, encoding: .utf8)
        #expect(raw.contains("\n"))
        #expect(raw.contains("\"usages\""))
    }

    // MARK: - updateIsActive

    @Test("updateIsActive marks the matching account active and others inactive")
    func updateIsActiveMarksCorrectAccount() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        await mgr.update(with: [
            VendorUsageEntry(vendor: "claude-tui", account: "a@b.com", isActive: false),
            VendorUsageEntry(vendor: "claude-tui", account: "c@d.com", isActive: false),
        ])

        await mgr.updateIsActive(vendor: "claude-tui", activeAccount: "a@b.com")

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
            VendorUsageEntry(vendor: "claude-tui", account: "a@b.com", isActive: true),
        ])

        await mgr.updateIsActive(vendor: "claude-tui", activeAccount: nil)

        let result = await mgr.read()
        #expect(result.usages[0].isActive == false)
    }

    @Test("updateIsActive does not touch entries of other vendors")
    func updateIsActiveIgnoresOtherVendors() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        await mgr.update(with: [
            VendorUsageEntry(vendor: "claude-tui", account: "a@b.com", isActive: false),
            VendorUsageEntry(vendor: "codex", account: "a@b.com", isActive: true),
        ])

        await mgr.updateIsActive(vendor: "claude-tui", activeAccount: "a@b.com")

        let result = await mgr.read()
        let claudeEntry = result.usages.first { $0.vendor == "claude-tui" }!
        let codexEntry  = result.usages.first { $0.vendor == "codex" }!
        #expect(claudeEntry.isActive == true)
        #expect(codexEntry.isActive == true)
    }

    @Test("updateIsActive is a no-op when file is empty")
    func updateIsActiveNoOpOnEmptyFile() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        await mgr.updateIsActive(vendor: "claude-tui", activeAccount: "a@b.com")
        let result = await mgr.read()
        #expect(result.usages.isEmpty)
    }

    // MARK: - Outage preservation

    @Test("merge preserves outages from existing file when connectors provide none")
    func mergePreservesOutages() async throws {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)

        // Write an initial file containing an outage entry
        let initialJSON = """
        {
          "usages": [
            {"vendor": "claude-tui", "account": "a@b.com", "isActive": true, "metrics": []}
          ],
          "outages": [
            {"vendor": "claude-tui", "errorMessage": "API issues", "severity": "major", "since": "2026-04-15T14:53:00Z"}
          ]
        }
        """.data(using: .utf8)!
        try initialJSON.write(to: URL(fileURLWithPath: mgr.filePath), options: .atomic)

        // Connector provides fresh account data without outages
        let entry = VendorUsageEntry(
            vendor: "claude-tui", account: "a@b.com", isActive: true,
            lastAcquiredOn: "2026-04-19T12:00:00Z",
            metrics: [.timeWindow(name: "session", resetAt: "2026-04-19T15:00:00Z",
                                  windowDuration: 300, usagePercent: 50)]
        )
        await mgr.update(with: [entry])

        let result = await mgr.read()
        #expect(result.usages.count == 1)
        #expect(result.usages[0].metrics.count == 1)
        // Outages survive the merge
        let outages = result.outagesByVendor[.claudeTUI]
        #expect(outages?.count == 1)
        #expect(outages?[0].errorMessage == "API issues")
    }

    @Test("merge does not create outages from connector entries")
    func mergeDoesNotCreateOutages() async {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)

        await mgr.update(with: [
            VendorUsageEntry(vendor: "claude-tui", account: "a@b.com", isActive: true),
        ])
        let result = await mgr.read()
        #expect(result.outagesByVendor.isEmpty)
    }

    @Test("writeUnsafe omits outages key when there are none")
    func writeOmitsEmptyOutages() async throws {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)

        await mgr.update(with: [
            VendorUsageEntry(vendor: "claude-tui", account: "a@b.com"),
        ])

        let raw = try Data(contentsOf: URL(fileURLWithPath: mgr.filePath))
        let json = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        #expect(json["usages"] != nil)
        #expect(json["outages"] == nil)
    }

    @Test("merge does not reintroduce outages once the upstream drops them")
    func mergeHonoursOutageRemoval() async throws {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)

        // Outage is active
        let withOutage = """
        {
          "usages": [{"vendor":"claude-tui","account":"a@b.com","isActive":true,"metrics":[]}],
          "outages": [{"vendor":"claude-tui","errorMessage":"X","severity":"major","since":"2026-04-15T14:53:00Z"}]
        }
        """.data(using: .utf8)!
        try withOutage.write(to: URL(fileURLWithPath: mgr.filePath), options: .atomic)

        // Upstream resolves: rewrites file without outages key
        let resolved = """
        {"usages":[{"vendor":"claude-tui","account":"a@b.com","isActive":true,"metrics":[]}]}
        """.data(using: .utf8)!
        try resolved.write(to: URL(fileURLWithPath: mgr.filePath), options: .atomic)

        // A connector now refreshes usage — merge should read the resolved file
        // and not resurrect the prior outage.
        await mgr.update(with: [
            VendorUsageEntry(vendor: "claude-tui", account: "a@b.com", isActive: true),
        ])

        let result = await mgr.read()
        #expect(result.outagesByVendor.isEmpty)
    }

    // MARK: - Per-vendor outage replacement

    private func writeFileWithOutages(mgr: UsagesFileManager, outages: [Outage]) throws {
        let file = UsagesFile(usages: [], outages: outages)
        let data = try JSONEncoder().encode(file)
        try data.write(to: URL(fileURLWithPath: mgr.filePath), options: .atomic)
    }

    @Test("update with [.claudeTUI: [outage]] replaces claude outages and preserves others")
    func outageReplacementReplacesClaudePreservesOthers() async throws {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let old = [
            Outage(vendor: "claude-tui", errorMessage: "old", severity: .major, since: "2026-04-01T00:00:00Z"),
            Outage(vendor: "gemini", errorMessage: "g-outage", severity: .minor, since: "2026-04-02T00:00:00Z"),
        ]
        try writeFileWithOutages(mgr: mgr, outages: old)

        let fresh = Outage(vendor: "claude-tui", errorMessage: "new", severity: .critical, since: "2026-04-22T00:00:00Z")
        await mgr.update(with: [], outagesByVendor: [.claudeTUI: [fresh]])

        let result = await mgr.read()
        let claudeOutages = result.outages.filter { $0.vendor == .claudeTUI }
        let geminiOutages = result.outages.filter { $0.vendor == "gemini" }
        #expect(claudeOutages.count == 1)
        #expect(claudeOutages[0].errorMessage == "new")
        #expect(geminiOutages.count == 1)
        #expect(geminiOutages[0].errorMessage == "g-outage")
    }

    @Test("update with [.claudeTUI: []] removes claude outages and preserves others")
    func outageReplacementEmptyListRemovesVendor() async throws {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let old = [
            Outage(vendor: "claude-tui", errorMessage: "old", severity: .major, since: "2026-04-01T00:00:00Z"),
            Outage(vendor: "gemini", errorMessage: "g-outage", severity: .minor, since: "2026-04-02T00:00:00Z"),
        ]
        try writeFileWithOutages(mgr: mgr, outages: old)

        await mgr.update(with: [], outagesByVendor: [.claudeTUI: []])

        let result = await mgr.read()
        #expect(result.outages.filter { $0.vendor == .claudeTUI }.isEmpty)
        #expect(result.outages.filter { $0.vendor == "gemini" }.count == 1)
    }

    @Test("update with empty outagesByVendor preserves all outages")
    func outageReplacementEmptyMapPreservesAll() async throws {
        let dir = makeTempDir()
        let mgr = makeManager(dir: dir)
        let old = [
            Outage(vendor: "claude-tui", errorMessage: "old", severity: .major, since: "2026-04-01T00:00:00Z"),
            Outage(vendor: "gemini", errorMessage: "g-outage", severity: .minor, since: "2026-04-02T00:00:00Z"),
        ]
        try writeFileWithOutages(mgr: mgr, outages: old)

        await mgr.update(with: [], outagesByVendor: [:])

        let result = await mgr.read()
        #expect(result.outages.count == 2)
    }

    // MARK: - Lock error paths

    @Test("read returns empty file when lock times out")
    func lockTimeoutFallsBackToEmpty() async throws {
        let dir = makeTempDir()
        let filePath = "\(dir)/usages.json"
        let lockPath = filePath + ".lock"

        // Pre-create and hold an exclusive lock so the manager cannot acquire it
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o644)
        #expect(fd >= 0)
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }

        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let mgr = UsagesFileManager(filePath: filePath, logger: logger, lockTimeoutSeconds: 0.1)
        let result = await mgr.read()
        // Lock timed out — manager falls back to empty file
        #expect(result.usages.isEmpty)
    }

    @Test("read returns empty file when lock file cannot be opened")
    func cannotOpenLockFileFallsBackToEmpty() async throws {
        let dir = makeTempDir()
        // Make the lock path a directory so Darwin.open returns -1
        let filePath = "\(dir)/usages.json"
        let lockPath = filePath + ".lock"
        try FileManager.default.createDirectory(atPath: lockPath, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: lockPath) }

        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        let mgr = UsagesFileManager(filePath: filePath, logger: logger)
        let result = await mgr.read()
        // Darwin.open failed — manager falls back to empty file
        #expect(result.usages.isEmpty)
    }
}
