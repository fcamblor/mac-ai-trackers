import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("StartupMigrationRunner")
struct StartupMigrationRunnerTests {
    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "ai-tracker-migrations-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeManager(dir: String) -> UsagesFileManager {
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        return UsagesFileManager(filePath: "\(dir)/usages.json", logger: logger)
    }

    private func makeRunner(
        dir: String,
        manager: UsagesFileManager,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
    ) -> StartupMigrationRunner {
        let logger = FileLogger(filePath: "\(dir)/migrations.log", minLevel: .debug)
        return StartupMigrationRunner(
            fileManager: manager,
            migrationsFilePath: "\(dir)/migrations.json",
            logger: logger,
            now: now
        )
    }

    @Test("first run removes account_unknown placeholders and records migration")
    func firstRunRemovesUnknownAndRecordsMigration() async throws {
        let dir = makeTempDir()
        let manager = makeManager(dir: dir)
        let legacyFile = UsagesFile(usages: [
            VendorUsageEntry(
                vendor: "claude",
                account: "unknown",
                lastError: UsageError(timestamp: "2026-04-17T10:00:00Z", type: "account_unknown")
            ),
            VendorUsageEntry(vendor: "claude", account: "real@example.com", isActive: true),
            VendorUsageEntry(vendor: "codex", account: "unknown"),
        ])
        let legacyData = try JSONEncoder().encode(legacyFile)
        try legacyData.write(to: URL(fileURLWithPath: manager.filePath), options: .atomic)

        let runner = makeRunner(dir: dir, manager: manager) {
            ISO8601DateFormatter().date(from: "2026-04-27T08:20:12Z")!
        }
        await runner.run()

        let usages = await manager.read()
        #expect(usages.usages.count == 2)
        #expect(!usages.usages.contains { $0.vendor == .claude && $0.account == "unknown" })
        #expect(usages.usages.contains { $0.account == "real@example.com" })
        #expect(usages.usages.contains { $0.vendor == .codex && $0.account == "unknown" })

        let data = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/migrations.json"))
        let migrations = try JSONDecoder().decode(StartupMigrationsFile.self, from: data)
        #expect(migrations.applied.count == 1)
        #expect(migrations.applied[0].id == "remove-account-unknown-placeholders")
        #expect(migrations.applied[0].appliedAt == "2026-04-27T08:20:12Z")
    }

    @Test("second run skips an already recorded migration")
    func secondRunSkipsAlreadyRecordedMigration() async throws {
        let dir = makeTempDir()
        let manager = makeManager(dir: dir)
        let runner = makeRunner(dir: dir, manager: manager)

        await runner.run()
        let legacyFile = UsagesFile(usages: [
            VendorUsageEntry(
                vendor: "claude",
                account: "unknown",
                lastError: UsageError(timestamp: "2026-04-17T10:00:00Z", type: "account_unknown")
            ),
        ])
        let legacyData = try JSONEncoder().encode(legacyFile)
        try legacyData.write(to: URL(fileURLWithPath: manager.filePath), options: .atomic)
        await runner.run()

        let usages = await manager.read()
        #expect(usages.usages.count == 1)
        #expect(usages.usages[0].account == "unknown")

        let data = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/migrations.json"))
        let migrations = try JSONDecoder().decode(StartupMigrationsFile.self, from: data)
        #expect(migrations.applied.count == 1)
    }

    @Test("pre-recorded migration skips cleanup")
    func preRecordedMigrationSkipsCleanup() async throws {
        let dir = makeTempDir()
        let manager = makeManager(dir: dir)
        let migrations = StartupMigrationsFile(applied: [
            AppliedStartupMigration(
                id: "remove-account-unknown-placeholders",
                appliedAt: "2026-04-27T08:20:12Z"
            ),
        ])
        let encoded = try JSONEncoder().encode(migrations)
        try encoded.write(to: URL(fileURLWithPath: "\(dir)/migrations.json"), options: .atomic)

        let existing = UsagesFile(usages: [
            VendorUsageEntry(
                vendor: "claude",
                account: "unknown",
                lastError: UsageError(timestamp: "2026-04-17T10:00:00Z", type: "account_unknown")
            ),
        ])
        let usageData = try JSONEncoder().encode(existing)
        try usageData.write(to: URL(fileURLWithPath: manager.filePath), options: .atomic)

        let runner = makeRunner(dir: dir, manager: manager)
        await runner.run()

        let usages = await manager.read()
        #expect(usages.usages.count == 1)
        #expect(usages.usages[0].account == "unknown")
    }
}
