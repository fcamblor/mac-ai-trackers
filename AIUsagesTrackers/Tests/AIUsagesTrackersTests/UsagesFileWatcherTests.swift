import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("UsagesFileWatcher integration tests")
struct UsagesFileWatcherTests {

    // MARK: - Helpers

    /// Thread-safe collector used by `collect(from:maxCount:timeout:)`.
    private actor DataCollector {
        private(set) var items: [Data] = []
        func append(_ data: Data) { items.append(data) }
    }

    /// Collects up to `maxCount` values from the watcher's changes() stream then cancels.
    /// Returns as soon as `maxCount` items arrive; cancels after `timeout` if fewer arrive.
    private func collect(
        from watcher: UsagesFileWatcher,
        maxCount: Int,
        timeout: TimeInterval = 2.0
    ) async -> [Data] {
        let collector = DataCollector()

        let collectTask = Task {
            for await data in watcher.changes() {
                await collector.append(data)
                if await collector.items.count >= maxCount { break }
            }
        }

        // CancellationError swallowed intentionally; timeout guard only
        try? await Task.sleep(for: .seconds(timeout))
        collectTask.cancel()

        return await collector.items
    }

    /// Writes `content` atomically to `url`, creating the file if absent.
    private func write(_ content: String, to url: URL) throws {
        let data = content.data(using: .utf8)!
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Tests

    @Test("emits initial content when file exists before watcher is created")
    func initialEmitIfFileExists() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsagesFileWatcherTests-initial-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = #"{"usages":[]}"#
        try write(expected, to: url)

        let watcher = UsagesFileWatcher(path: url.path, pollInterval: 0.1)
        let results = await collect(from: watcher, maxCount: 1)

        #expect(results.count == 1)
        #expect(String(data: results[0], encoding: .utf8) == expected)
    }

    @Test("no emit when file does not exist")
    func noEmitIfFileAbsent() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsagesFileWatcherTests-absent-\(UUID().uuidString).json")
        // Intentionally not creating the file

        let watcher = UsagesFileWatcher(path: url.path, pollInterval: 0.1)
        // Fixed sleep: absence of an event has no reactive condition to poll for.
        // 0.3 s covers ≥ 3 poll cycles at pollInterval: 0.1.
        let results = await collect(from: watcher, maxCount: 1, timeout: 0.3)

        #expect(results.isEmpty)
    }

    @Test("emits content after file is written")
    func emitAfterWrite() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsagesFileWatcherTests-write-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let watcher = UsagesFileWatcher(path: url.path, pollInterval: 0.1)

        // Start collecting in the background, then write the file
        async let results = collect(from: watcher, maxCount: 1)
        // swiftlint:disable:next w3_task_sleep_literal_in_tests — sequencing: let watcher start its first poll before we write
        try await Task.sleep(for: .milliseconds(50))

        let expected = #"{"usages":[]}"#
        try write(expected, to: url)

        let received = await results
        #expect(received.count == 1)
        #expect(String(data: received[0], encoding: .utf8) == expected)
    }

    @Test("unchanged file is not emitted again on subsequent polls")
    func dedupOnUnchangedFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsagesFileWatcherTests-dedup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let content = #"{"usages":[]}"#
        try write(content, to: url)

        let watcher = UsagesFileWatcher(path: url.path, pollInterval: 0.1)

        // Collect up to 2 items; if dedup works we should only receive 1
        let results = await collect(from: watcher, maxCount: 2, timeout: 0.5)

        // swiftlint:disable:next w3_task_sleep_literal_in_tests — absence confirmation: no reactive signal for a non-emitted event
        try await Task.sleep(for: .milliseconds(300))

        #expect(results.count == 1, "Unchanged modDate must suppress duplicate emits")
    }
}
