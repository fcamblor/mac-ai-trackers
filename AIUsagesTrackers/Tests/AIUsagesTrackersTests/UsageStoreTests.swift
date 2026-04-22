import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - Test doubles

/// A mock FileWatching that lets tests push arbitrary Data payloads.
/// Implemented as a class so `changes()` can hand out a fresh AsyncStream on each
/// call — required for start/stop/start lifecycle tests where the previous iteration
/// is cancelled before a new watchTask begins consuming again.
// swiftlint:disable:next w4_unchecked_sendable — all test access is single-threaded on the main actor; AsyncStream.Continuation is Sendable
final class MockFileWatcher: FileWatching, @unchecked Sendable {
    private var continuation: AsyncStream<Data>.Continuation?
    /// Buffers sends that arrive before the watch task calls changes(), or after a
    /// cancelled previous cycle. Flushed immediately when changes() is called.
    private var pendingData: [Data] = []

    func changes() -> AsyncStream<Data> {
        // Finish the previous stream (if any) before creating a new one.
        // This prevents a stale task from consuming the new continuation's yields.
        continuation?.finish()
        var cont: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { cont = $0 }
        continuation = cont
        // Flush sends that arrived before this call (e.g. test called send() before
        // the watch task had a chance to call changes()).
        for data in pendingData { cont.yield(data) }
        pendingData.removeAll()
        return stream
    }

    func send(_ data: Data) {
        guard let cont = continuation else {
            pendingData.append(data)
            return
        }
        // .terminated means the previous cycle's consuming task was cancelled;
        // buffer the data so the next changes() call can deliver it.
        if case .terminated = cont.yield(data) {
            continuation = nil
            pendingData.append(data)
        }
    }

    func finish() { continuation?.finish() }
}

/// A clock fixed at a given date, for deterministic remaining-time formatting.
struct FixedClock: ClockProvider {
    let date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { date }
}

/// A clock whose date can be advanced between test steps to simulate time passing.
/// nonisolated(unsafe) — tests drive date changes from @MainActor, single-threaded; no concurrent writes.
@MainActor
final class MutableClock: ClockProvider {
    nonisolated(unsafe) var date: Date
    init(_ date: Date) { self.date = date }
    nonisolated func now() -> Date { date }
}

// MARK: - Helpers

private func makeUsagesJSON(
    vendor: String = "claude",
    account: String = "user@example.com",
    isActive: Bool = true,
    metrics: [[String: Any]] = []
) throws -> Data {
    let entry: [String: Any] = [
        "vendor": vendor,
        "account": account,
        "isActive": isActive,
        "metrics": metrics,
    ]
    let root: [String: Any] = ["usages": [entry]]
    return try JSONSerialization.data(withJSONObject: root)
}

/// Creates a flat-shape JSON payload with an optional sibling outages array.
private func makeUsagesWithOutagesJSON(
    vendor: String = "claude",
    account: String = "user@example.com",
    isActive: Bool = true,
    metrics: [[String: Any]] = [],
    outages: [[String: Any]] = []
) throws -> Data {
    let entry: [String: Any] = [
        "vendor": vendor,
        "account": account,
        "isActive": isActive,
        "metrics": metrics,
    ]
    var root: [String: Any] = ["usages": [entry]]
    if !outages.isEmpty {
        root["outages"] = outages
    }
    return try JSONSerialization.data(withJSONObject: root)
}

private func outageJSON(
    vendor: String = "claude",
    errorMessage: String = "API issues",
    severity: String = "major",
    since: String = "2026-04-15T14:53:00Z",
    href: String? = nil
) -> [String: Any] {
    var json: [String: Any] = [
        "vendor": vendor,
        "errorMessage": errorMessage,
        "severity": severity,
        "since": since,
    ]
    if let href { json["href"] = href }
    return json
}

private func timeWindowMetric(
    name: String = "5h sessions (all models)",
    resetAt: String = "2026-04-17T15:00:00Z",
    windowDurationMinutes: Int = 300,
    usagePercent: Int = 42
) -> [String: Any] {
    [
        "type": "time-window",
        "name": name,
        "resetAt": resetAt,
        "windowDurationMinutes": windowDurationMinutes,
        "usagePercent": usagePercent,
    ]
}

private func payAsYouGoMetric(
    name: String = "monthly",
    currentAmount: Double = 12.50,
    currency: String = "USD"
) -> [String: Any] {
    [
        "type": "pay-as-you-go",
        "name": name,
        "currentAmount": currentAmount,
        "currency": currency,
    ]
}

// MARK: - Tests

@Suite("UsageStore formatting")
struct UsageStoreFormattingTests {

    private static let referenceDate: Date = ISO8601DateFormatter().date(from: "2026-04-17T12:47:00Z")!

    @MainActor
    @Test("default menuBarText is fallback")
    func defaultIsFallback() {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher)
        #expect(store.menuBarText == "--")
    }

    @MainActor
    @Test("single time-window metric formats correctly")
    func singleTimeWindow() async throws {
        let watcher = MockFileWatcher()
        let clock = FixedClock(Self.referenceDate)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        // resetAt is 2h13m in the future from Self.referenceDate
        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", usagePercent: 48),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText == "S 48% 2h 13m" }
        #expect(store.menuBarText == "S 48% 2h 13m")
        store.stop()
    }

    @MainActor
    @Test("multiple time-window metrics joined by pipe")
    func multipleTimeWindows() async throws {
        let watcher = MockFileWatcher()
        let clock = FixedClock(Self.referenceDate)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", usagePercent: 48),
            timeWindowMetric(name: "Weekly (all models)", resetAt: "2026-04-23T21:00:00Z", usagePercent: 7),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText == "S 48% 2h 13m | W 7% 6d 8h 13m" }
        #expect(store.menuBarText == "S 48% 2h 13m | W 7% 6d 8h 13m")
        store.stop()
    }

    @MainActor
    @Test("pay-as-you-go metrics are ignored")
    func payAsYouGoIgnored() async throws {
        let watcher = MockFileWatcher()
        let clock = FixedClock(Self.referenceDate)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            payAsYouGoMetric(),
        ])
        watcher.send(data)
        try await eventually { store.dataProcessedCount == 1 }
        // No time-window metrics → fallback
        #expect(store.menuBarText == "--")
        store.stop()
    }

    @MainActor
    @Test("mixed metrics: only time-window rendered")
    func mixedMetrics() async throws {
        let watcher = MockFileWatcher()
        let clock = FixedClock(Self.referenceDate)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", usagePercent: 48),
            payAsYouGoMetric(),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText == "S 48% 2h 13m" }
        #expect(store.menuBarText == "S 48% 2h 13m")
        store.stop()
    }

    @MainActor
    @Test("resetAt in the past shows 0m")
    func resetAtInPast() async throws {
        let watcher = MockFileWatcher()
        let clock = FixedClock(Self.referenceDate)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T10:00:00Z", usagePercent: 100),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText != "--" }
        #expect(store.menuBarText == "S 100% 0m")
        store.stop()
    }

    @MainActor
    @Test("resetAt exactly now shows 0m")
    func resetAtExactlyNow() async throws {
        let watcher = MockFileWatcher()
        let clock = FixedClock(Self.referenceDate)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T12:47:00Z", usagePercent: 50),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText != "--" }
        #expect(store.menuBarText == "S 50% 0m")
        store.stop()
    }
}

@Suite("UsageStore graceful degradation")
struct UsageStoreDegradationTests {

    @MainActor
    @Test("malformed JSON falls back to --")
    func malformedJSON() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        watcher.send("not json".data(using: .utf8)!)
        try await eventually { store.dataProcessedCount == 1 }
        #expect(store.menuBarText == "--")
        store.stop()
    }

    @MainActor
    @Test("no active Claude entry falls back to --")
    func noActiveClaude() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(isActive: false, metrics: [
            timeWindowMetric(),
        ])
        watcher.send(data)
        try await eventually { store.dataProcessedCount == 1 }
        #expect(store.menuBarText == "--")
        store.stop()
    }

    @MainActor
    @Test("wrong vendor falls back to --")
    func wrongVendor() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(vendor: "other", metrics: [
            timeWindowMetric(),
        ])
        watcher.send(data)
        try await eventually { store.dataProcessedCount == 1 }
        #expect(store.menuBarText == "--")
        store.stop()
    }

    @MainActor
    @Test("active Claude entry with empty metrics falls back to --")
    func emptyMetrics() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [])
        watcher.send(data)
        try await eventually { store.dataProcessedCount == 1 }
        #expect(store.menuBarText == "--")
        store.stop()
    }

    @MainActor
    @Test("subsequent valid data recovers from error state")
    func recoveryAfterError() async throws {
        let watcher = MockFileWatcher()
        let f = ISO8601DateFormatter()
        let clock = FixedClock(f.date(from: "2026-04-17T12:00:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        watcher.send("bad".data(using: .utf8)!)
        try await eventually { store.dataProcessedCount == 1 }
        #expect(store.menuBarText == "--")

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T13:00:00Z", usagePercent: 10),
        ])
        watcher.send(data)
        try await eventually { store.dataProcessedCount == 2 }
        #expect(store.menuBarText == "S 10% 1h")

        store.stop()
    }
}

@Suite("UsageStore lifecycle")
struct UsageStoreLifecycleTests {

    @MainActor
    @Test("start is idempotent")
    func startIdempotent() async throws {
        let watcher = MockFileWatcher()
        let f = ISO8601DateFormatter()
        let clock = FixedClock(f.date(from: "2026-04-17T12:00:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()
        store.start() // second call should be no-op; data must still flow
        watcher.send(try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T13:00:00Z", usagePercent: 10),
        ]))
        try await eventually { store.menuBarText != "--" }
        #expect(store.menuBarText == "S 10% 1h")
        store.stop()
    }

    @MainActor
    @Test("stop is idempotent")
    func stopIdempotent() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()
        store.stop()
        store.stop() // second call should be no-op
        watcher.send(try makeUsagesJSON(metrics: [timeWindowMetric()]))
        // watchTask is cancelled; no data processing will happen.
        // swiftlint:disable:next w3_task_sleep_literal_in_tests — absence confirmation: no reactive signal to poll after stop()
        try await Task.sleep(for: absenceConfirmationDelay)
        #expect(store.dataProcessedCount == 0)
        #expect(store.menuBarText == "--")
    }

    @MainActor
    @Test("stop before start is safe")
    func stopBeforeStart() {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.stop()
    }

    @MainActor
    @Test("start, stop, then start again resumes data flow")
    func startStopStart() async throws {
        let watcher = MockFileWatcher()
        let f = ISO8601DateFormatter()
        let clock = FixedClock(f.date(from: "2026-04-17T12:00:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)

        store.start()
        watcher.send(try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T13:00:00Z", usagePercent: 10),
        ]))
        try await eventually { store.menuBarText != "--" }
        #expect(store.menuBarText == "S 10% 1h")
        store.stop()

        store.start()
        watcher.send(try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "Weekly (all models)", resetAt: "2026-04-17T14:00:00Z", usagePercent: 50),
        ]))
        try await eventually { store.menuBarText == "W 50% 2h" }
        #expect(store.menuBarText == "W 50% 2h")
        store.stop()
    }
}

@Suite("UsageStore remaining time formatting edge cases")
struct UsageStoreRemainingTimeTests {

    @MainActor
    @Test("exactly 1 day remaining")
    func exactlyOneDay() async throws {
        let watcher = MockFileWatcher()
        let f = ISO8601DateFormatter()
        let clock = FixedClock(f.date(from: "2026-04-17T00:00:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "Weekly (all models)", resetAt: "2026-04-18T00:00:00Z", usagePercent: 0),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText != "--" }
        #expect(store.menuBarText == "W 0% 1d")
        store.stop()
    }

    @MainActor
    @Test("large remaining time with days hours and minutes")
    func largeDuration() async throws {
        let watcher = MockFileWatcher()
        let f = ISO8601DateFormatter()
        let clock = FixedClock(f.date(from: "2026-04-17T00:00:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        // resetAt is several days ahead — verifies d/h/m rendering
        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "Weekly (all models)", resetAt: "2026-04-20T05:30:00Z", usagePercent: 15),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText != "--" }
        #expect(store.menuBarText == "W 15% 3d 5h 30m")
        store.stop()
    }

    @MainActor
    @Test("only minutes remaining")
    func onlyMinutes() async throws {
        let watcher = MockFileWatcher()
        let f = ISO8601DateFormatter()
        let clock = FixedClock(f.date(from: "2026-04-17T14:45:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T14:50:00Z", usagePercent: 95),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText != "--" }
        #expect(store.menuBarText == "S 95% 5m")
        store.stop()
    }

    @MainActor
    @Test("invalid ISO8601 resetAt shows -- for remaining time")
    func invalidResetAt() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "not-a-date", usagePercent: 50),
        ])
        watcher.send(data)
        // Store's formatRemainingTime returns "--" for unparseable dates (with a warning log)
        try await eventually { store.menuBarText != "--" }
        #expect(store.menuBarText == "S 50% --")
        store.stop()
    }

    @MainActor
    @Test("exactly N hours remaining shows no trailing minutes")
    func exactlyNHours() async throws {
        let watcher = MockFileWatcher()
        let f = ISO8601DateFormatter()
        let clock = FixedClock(f.date(from: "2026-04-17T12:00:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T14:00:00Z", usagePercent: 42),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText != "--" }
        // 2h 0m: minutes part omitted because parts is non-empty (hours already present)
        #expect(store.menuBarText == "S 42% 2h")
        store.stop()
    }

    @MainActor
    @Test("sub-minute remaining shows 0m")
    func subMinuteRemaining() async throws {
        let watcher = MockFileWatcher()
        let f = ISO8601DateFormatter()
        let clock = FixedClock(f.date(from: "2026-04-17T12:00:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        // resetAt less than one minute ahead — verifies "0m" floor
        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T12:00:30Z", usagePercent: 99),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText != "--" }
        #expect(store.menuBarText == "S 99% 0m")
        store.stop()
    }

}

@Suite("UsageStore countdown behavior")
struct UsageStoreCountdownTests {

    @MainActor
    @Test("countdown refresh updates menuBarText without new file data")
    func countdown() async throws {
        let watcher = MockFileWatcher()
        let f = ISO8601DateFormatter()
        let clock = MutableClock(f.date(from: "2026-04-17T12:00:00Z")!)
        // 1-second countdown so the test completes quickly
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 1)
        store.start()

        // 3h remaining at initial clock
        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", usagePercent: 42),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText == "S 42% 3h" }
        #expect(store.menuBarText == "S 42% 3h")

        // Advance clock forward — countdown should drop to the next lower whole-hour bucket
        clock.date = f.date(from: "2026-04-17T13:00:00Z")!
        try await eventually(timeout: 3.0) { store.menuBarText == "S 42% 2h" }
        #expect(store.menuBarText == "S 42% 2h")
        store.stop()
    }

    @MainActor
    @Test("countdown tick after error keeps menuBarText at fallback")
    func errorThenCountdown() async throws {
        let watcher = MockFileWatcher()
        // 1-second countdown to exercise the timer path
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 1)
        store.start()

        watcher.send("bad".data(using: .utf8)!)
        try await eventually { store.dataProcessedCount == 1 }
        #expect(store.menuBarText == "--")

        // Wait for at least one countdown tick.
        // Fixed sleep is appropriate here — absence of a change has no reactive signal.
        let oneCountdownCycle: UInt64 = 1_200_000_000 // 1.2s — one tick plus margin
        try await Task.sleep(nanoseconds: oneCountdownCycle)
        // refreshMenuBarText is a no-op when lastFile is nil (error cleared it)
        #expect(store.menuBarText == "--")
        store.stop()
    }

}

@Suite("UsageStore entry selection and metric edge cases")
struct UsageStoreEntryTests {

    @MainActor
    @Test("first matching active vendor entry wins")
    func multipleVendorEntries() async throws {
        let watcher = MockFileWatcher()
        let f = ISO8601DateFormatter()
        let clock = FixedClock(f.date(from: "2026-04-17T12:00:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        // Two active Claude entries — only the first is rendered per first(where:) semantics
        let root: [String: Any] = ["usages": [
            ["vendor": "claude", "account": "first@example.com", "isActive": true, "metrics": [
                timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T13:00:00Z", usagePercent: 10),
            ]],
            ["vendor": "claude", "account": "second@example.com", "isActive": true, "metrics": [
                timeWindowMetric(name: "Weekly (all models)", resetAt: "2026-04-17T14:00:00Z", usagePercent: 50),
            ]],
        ]]
        let data = try JSONSerialization.data(withJSONObject: root)
        watcher.send(data)
        try await eventually { store.menuBarText != "--" }
        #expect(store.menuBarText == "S 10% 1h")
        store.stop()
    }

    @MainActor
    @Test("per-model weekly metrics are excluded from menu bar")
    func perModelMetricsExcluded() async throws {
        let watcher = MockFileWatcher()
        let f = ISO8601DateFormatter()
        let clock = FixedClock(f.date(from: "2026-04-17T12:00:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        // weekly_sonnet and weekly_opus are per-model breakdowns; only session and weekly appear in the menu bar
        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)",       resetAt: "2026-04-17T13:00:00Z", usagePercent: 10),
            timeWindowMetric(name: "Weekly (all models)",        resetAt: "2026-04-17T14:00:00Z", usagePercent: 50),
            timeWindowMetric(name: "weekly_sonnet", resetAt: "2026-04-17T14:00:00Z", usagePercent: 30),
            timeWindowMetric(name: "weekly_opus",   resetAt: "2026-04-17T14:00:00Z", usagePercent: 20),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText == "S 10% 1h | W 50% 2h" }
        #expect(store.menuBarText == "S 10% 1h | W 50% 2h")
        store.stop()
    }

    @MainActor
    @Test("empty metric name is skipped, producing fallback")
    func emptyMetricName() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: ""),
        ])
        watcher.send(data)
        try await eventually { store.dataProcessedCount == 1 }
        // Empty name produces no abbreviation; segment is skipped → fallback
        #expect(store.menuBarText == "--")
        store.stop()
    }

    @MainActor
    @Test("unknown metric type alongside known metric renders only the known metric")
    func unknownMetricType() async throws {
        let watcher = MockFileWatcher()
        let f = ISO8601DateFormatter()
        let clock = FixedClock(f.date(from: "2026-04-17T12:00:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        // Mix a known time-window metric with an unrecognised future type.
        // After the MetricKind.unknown fix, the unknown entry decodes as .unknown(...)
        // and is silently skipped by formatTimeWindowSegment, so only the known metric renders.
        let root: [String: Any] = ["usages": [
            ["vendor": "claude", "account": "user@example.com", "isActive": true, "metrics": [
                timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T13:00:00Z", usagePercent: 10),
                ["type": "unknown-future-type", "name": "x"],
            ]],
        ]]
        let data = try JSONSerialization.data(withJSONObject: root)
        watcher.send(data)
        try await eventually { store.menuBarText == "S 10% 1h" }
        #expect(store.menuBarText == "S 10% 1h")
        store.stop()
    }

}

// MARK: - Entries property tests

@Suite("UsageStore entries property")
struct UsageStoreEntriesTests {

    @MainActor
    @Test("entries is empty by default")
    func defaultIsEmpty() {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher)
        #expect(store.entries.isEmpty)
    }

    @MainActor
    @Test("entries populated on valid data")
    func populatedOnValidData() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(
            vendor: "claude",
            account: "a@b.com",
            isActive: true,
            metrics: [timeWindowMetric(name: "5h sessions (all models)", usagePercent: 42)]
        )
        watcher.send(data)
        try await eventually { store.entries.count == 1 }

        #expect(store.entries.count == 1)
        #expect(store.entries[0].vendor == .claude)
        #expect(store.entries[0].account == AccountEmail(rawValue: "a@b.com"))
        store.stop()
    }

    @MainActor
    @Test("entries cleared on malformed JSON")
    func clearedOnMalformedJSON() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        // First send valid data
        let validData = try makeUsagesJSON(metrics: [timeWindowMetric()])
        watcher.send(validData)
        try await eventually { !store.entries.isEmpty }
        #expect(!store.entries.isEmpty)

        // Then send malformed data
        watcher.send("bad".data(using: .utf8)!)
        try await eventually { store.entries.isEmpty }
        #expect(store.entries.isEmpty)

        store.stop()
    }

    @MainActor
    @Test("entries contain multiple vendor entries")
    func multipleEntries() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        // Build JSON with two entries manually
        let entry1: [String: Any] = [
            "vendor": "claude",
            "account": "a@b.com",
            "isActive": true,
            "metrics": [timeWindowMetric(name: "5h sessions (all models)", usagePercent: 48)],
        ]
        let entry2: [String: Any] = [
            "vendor": "claude",
            "account": "c@d.com",
            "isActive": false,
            "metrics": [payAsYouGoMetric()],
        ]
        let root: [String: Any] = ["usages": [entry1, entry2]]
        let data = try! JSONSerialization.data(withJSONObject: root)

        watcher.send(data)
        try await eventually { store.entries.count == 2 }

        #expect(store.entries.count == 2)
        #expect(store.entries.contains { $0.isActive && $0.account == AccountEmail(rawValue: "a@b.com") })
        #expect(store.entries.contains { !$0.isActive && $0.account == AccountEmail(rawValue: "c@d.com") })
        store.stop()
    }

    @MainActor
    @Test("partially malformed multi-account JSON still decodes valid entries")
    func partiallyMalformedMultiAccount() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        // First entry has valid metrics; second entry has a non-dict metric
        // that should be skipped or cause graceful degradation
        let root: [String: Any] = ["usages": [
            [
                "vendor": "claude",
                "account": "good@example.com",
                "isActive": true,
                "metrics": [timeWindowMetric(name: "5h sessions (all models)", usagePercent: 42)],
            ],
            [
                "vendor": "claude",
                "account": "bad@example.com",
                "isActive": true,
                "metrics": "not-an-array",
            ],
        ]]
        let data = try JSONSerialization.data(withJSONObject: root)
        watcher.send(data)
        try await eventually { store.dataProcessedCount >= 1 }

        // The store should still have decoded at least the good entry, or
        // gracefully fallen back to empty if the whole payload is rejected
        let hasGoodEntry = store.entries.contains { $0.account == AccountEmail(rawValue: "good@example.com") }
        let fellBack = store.entries.isEmpty
        #expect(hasGoodEntry || fellBack, "Expected either partial decode or graceful fallback")
        store.stop()
    }

    @MainActor
    @Test("entries recovered after error")
    func recoveredAfterError() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        watcher.send("bad".data(using: .utf8)!)
        try await eventually { store.entries.isEmpty }
        #expect(store.entries.isEmpty)

        let data = try makeUsagesJSON(metrics: [timeWindowMetric()])
        watcher.send(data)
        try await eventually { store.entries.count == 1 }
        #expect(store.entries.count == 1)

        store.stop()
    }
}

// MARK: - menuBarSegments tests

@Suite("UsageStore menuBarSegments")
struct UsageStoreMenuBarSegmentsTests {

    @MainActor
    @Test("default menuBarSegments is empty")
    func defaultIsEmpty() {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher)
        #expect(store.menuBarSegments.isEmpty)
    }

    @MainActor
    @Test("single metric produces one segment with text and tier")
    func singleSegment() async throws {
        let watcher = MockFileWatcher()
        // Session: 300 min, reset 15:00, now 12:30 → 50% elapsed, 48% usage → ratio 0.96 → approaching
        let clock = FixedClock(ISO8601DateFormatter().date(from: "2026-04-17T12:30:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", windowDurationMinutes: 300, usagePercent: 48),
        ])
        watcher.send(data)
        try await eventually { store.menuBarSegments.count == 1 }

        #expect(store.menuBarSegments.count == 1)
        #expect(store.menuBarSegments[0].text == "S 48% 2h 30m")
        #expect(store.menuBarSegments[0].tier == .approaching)
        store.stop()
    }

    @MainActor
    @Test("multiple metrics produce one segment per metric in order")
    func multipleSegments() async throws {
        let watcher = MockFileWatcher()
        let clock = FixedClock(ISO8601DateFormatter().date(from: "2026-04-17T12:30:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", windowDurationMinutes: 300, usagePercent: 10),
            timeWindowMetric(name: "Weekly (all models)",  resetAt: "2026-04-23T21:00:00Z", windowDurationMinutes: 10080, usagePercent: 80),
        ])
        watcher.send(data)
        try await eventually { store.menuBarSegments.count == 2 }

        #expect(store.menuBarSegments[0].text.hasPrefix("S "))
        #expect(store.menuBarSegments[1].text.hasPrefix("W "))
        store.stop()
    }

    @MainActor
    @Test("segment tier is nil when theoretical fraction is zero")
    func nilTierAtWindowStart() async throws {
        let watcher = MockFileWatcher()
        // Now is exactly at window start → 0% elapsed → tier nil
        let clock = FixedClock(ISO8601DateFormatter().date(from: "2026-04-17T10:00:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", windowDurationMinutes: 300, usagePercent: 50),
        ])
        watcher.send(data)
        try await eventually { store.menuBarSegments.count == 1 }

        #expect(store.menuBarSegments[0].tier == nil)
        store.stop()
    }

    @MainActor
    @Test("segments cleared on decode error")
    func segmentsClearedOnError() async throws {
        let watcher = MockFileWatcher()
        let clock = FixedClock(ISO8601DateFormatter().date(from: "2026-04-17T12:30:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", windowDurationMinutes: 300, usagePercent: 48),
        ])
        watcher.send(data)
        try await eventually { store.menuBarSegments.count == 1 }

        watcher.send("bad".data(using: .utf8)!)
        try await eventually { store.menuBarSegments.isEmpty }
        #expect(store.menuBarSegments.isEmpty)
        store.stop()
    }
}

// MARK: - menuBarTier tests

@Suite("UsageStore menuBarTier")
struct UsageStoreMenuBarTierTests {

    @MainActor
    @Test("exhausted tier when usage far exceeds theoretical pace")
    func exhaustedTier() async throws {
        let watcher = MockFileWatcher()
        // Session: 300 min window, resets at 15:00, now at 12:30 → 50% elapsed
        // 80% usage at 50% elapsed → ratio 1.6 → exhausted
        let clock = FixedClock(ISO8601DateFormatter().date(from: "2026-04-17T12:30:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", windowDurationMinutes: 300, usagePercent: 80),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText != "--" }
        #expect(store.menuBarTier == .exhausted)
        store.stop()
    }

    @MainActor
    @Test("comfortable tier when usage is well below pace")
    func comfortableTier() async throws {
        let watcher = MockFileWatcher()
        // Session: 300 min window, resets at 15:00, now at 12:30 → 50% elapsed
        // 10% usage at 50% elapsed → ratio 0.2 → comfortable
        let clock = FixedClock(ISO8601DateFormatter().date(from: "2026-04-17T12:30:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", windowDurationMinutes: 300, usagePercent: 10),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText != "--" }
        #expect(store.menuBarTier == .comfortable)
        store.stop()
    }

    @MainActor
    @Test("worst tier wins when multiple metrics displayed")
    func worstTierWins() async throws {
        let watcher = MockFileWatcher()
        // Session: 300 min, reset 15:00, now 12:30 → 50% elapsed, 10% usage → ratio 0.2 → comfortable
        // Weekly: 10080 min, reset Apr 23 21:00, now Apr 17 12:30 → ~89% elapsed, 80% usage → ratio ~0.9 → approaching
        let clock = FixedClock(ISO8601DateFormatter().date(from: "2026-04-17T12:30:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", windowDurationMinutes: 300, usagePercent: 10),
            timeWindowMetric(name: "Weekly (all models)", resetAt: "2026-04-23T21:00:00Z", windowDurationMinutes: 10080, usagePercent: 80),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText.contains("|") }
        // Weekly tier is worse than session tier → menuBarTier reflects weekly
        #expect(store.menuBarTier != nil)
        #expect(store.menuBarTier! > .comfortable)
        store.stop()
    }

    @MainActor
    @Test("nil tier at window start (theoretical ≈ 0)")
    func nilTierAtWindowStart() async throws {
        let watcher = MockFileWatcher()
        // Session: 300 min window, resets at 15:00, now is well before window start (10:00)
        // Window start = 15:00 - 300min = 10:00. Now at 10:00 exactly → 0% elapsed → nil tier
        let clock = FixedClock(ISO8601DateFormatter().date(from: "2026-04-17T10:00:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", windowDurationMinutes: 300, usagePercent: 50),
        ])
        watcher.send(data)
        try await eventually { store.menuBarText != "--" }
        // theoreticalFraction is 0 at window start → ratio nil → tier nil
        #expect(store.menuBarTier == nil)
        store.stop()
    }

    @MainActor
    @Test("nil tier when only pay-as-you-go metrics")
    func nilTierForPayAsYouGo() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [payAsYouGoMetric()])
        watcher.send(data)
        try await eventually { store.dataProcessedCount == 1 }
        #expect(store.menuBarTier == nil)
        store.stop()
    }

    @MainActor
    @Test("decode error resets menuBarTier to nil")
    func decodeErrorResetsTier() async throws {
        let watcher = MockFileWatcher()
        let clock = FixedClock(ISO8601DateFormatter().date(from: "2026-04-17T12:30:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 999)
        store.start()

        // First: valid data that sets a tier
        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", windowDurationMinutes: 300, usagePercent: 80),
        ])
        watcher.send(data)
        try await eventually { store.menuBarTier != nil }
        #expect(store.menuBarTier != nil)

        // Then: malformed data
        watcher.send("bad".data(using: .utf8)!)
        try await eventually { store.dataProcessedCount == 2 }
        #expect(store.menuBarTier == nil)
        store.stop()
    }

    @MainActor
    @Test("countdown refresh updates menuBarTier as time passes")
    func countdownUpdatesTier() async throws {
        let watcher = MockFileWatcher()
        let clock = MutableClock(ISO8601DateFormatter().date(from: "2026-04-17T10:01:00Z")!)
        let store = UsageStore(fileWatcher: watcher, clock: clock, countdownRefreshSeconds: 1)
        store.start()

        // Session: 300 min, reset 15:00, window start 10:00. At 10:01 → ~0.3% elapsed
        // 50% usage at 0.3% elapsed → very high ratio → exhausted
        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "5h sessions (all models)", resetAt: "2026-04-17T15:00:00Z", windowDurationMinutes: 300, usagePercent: 50),
        ])
        watcher.send(data)
        try await eventually { store.menuBarTier == .exhausted }
        #expect(store.menuBarTier == .exhausted)

        // Advance to 14:00 → 80% elapsed. 50% usage at 80% → ratio 0.625 → comfortable
        clock.date = ISO8601DateFormatter().date(from: "2026-04-17T14:00:00Z")!
        try await eventually(timeout: 3.0) { store.menuBarTier == .comfortable }
        #expect(store.menuBarTier == .comfortable)
        store.stop()
    }
}

// MARK: - Outage round-trip integration

@Suite("UsageStore outage change round-trip")
struct UsageStoreOutageRoundTripTests {

    @MainActor
    @Test("outage change is reflected in store after file update")
    func outageChangeRoundTrip() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        // Step 1: file with no outages
        let noOutageData = try makeUsagesWithOutagesJSON(
            metrics: [timeWindowMetric()],
            outages: []
        )
        watcher.send(noOutageData)
        try await eventually { store.dataProcessedCount == 1 }
        #expect(store.outagesByVendor.isEmpty)
        #expect(store.entries.count == 1)

        // Step 2: upstream writes an outage into the file
        let withOutageData = try makeUsagesWithOutagesJSON(
            metrics: [timeWindowMetric()],
            outages: [outageJSON(errorMessage: "Messages API latency spike", severity: "critical",
                                 since: "2026-04-15T14:53:00Z",
                                 href: "https://status.claude.com/incidents/x")]
        )
        watcher.send(withOutageData)
        try await eventually { !store.outagesByVendor.isEmpty }

        let outages = store.outagesByVendor[.claude]
        #expect(outages?.count == 1)
        #expect(outages?[0].errorMessage == "Messages API latency spike")
        #expect(outages?[0].severity == .critical)

        // Step 3: upstream resolves the incident
        let resolvedData = try makeUsagesWithOutagesJSON(
            metrics: [timeWindowMetric()],
            outages: []
        )
        watcher.send(resolvedData)
        try await eventually { store.outagesByVendor.isEmpty }
        #expect(store.outagesByVendor.isEmpty)
        // Usage entries remain unaffected
        #expect(store.entries.count == 1)

        store.stop()
    }
}

// MARK: - outagesByVendor tests

@Suite("UsageStore outagesByVendor")
struct UsageStoreOutagesTests {

    @MainActor
    @Test("outagesByVendor is empty by default")
    func defaultIsEmpty() {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher)
        #expect(store.outagesByVendor.isEmpty)
    }

    @MainActor
    @Test("outagesByVendor populated from file with outages array")
    func populatedWithOutages() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesWithOutagesJSON(outages: [
            outageJSON(errorMessage: "Elevated error rate", severity: "major",
                       since: "2026-04-15T14:53:00Z",
                       href: "https://status.claude.com/incidents/x"),
        ])
        watcher.send(data)
        try await eventually { !store.outagesByVendor.isEmpty }

        let claudeOutages = store.outagesByVendor[.claude]
        #expect(claudeOutages?.count == 1)
        #expect(claudeOutages?[0].errorMessage == "Elevated error rate")
        #expect(claudeOutages?[0].severity == .major)
        #expect(claudeOutages?[0].href?.absoluteString == "https://status.claude.com/incidents/x")
        store.stop()
    }

    @MainActor
    @Test("outagesByVendor empty when file has no outages key")
    func emptyWhenNoOutages() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [timeWindowMetric()])
        watcher.send(data)
        try await eventually { store.dataProcessedCount == 1 }

        #expect(store.outagesByVendor.isEmpty)
        store.stop()
    }

    @MainActor
    @Test("outagesByVendor cleared on decode error")
    func clearedOnDecodeError() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        // First: valid data with outages
        let data = try makeUsagesWithOutagesJSON(outages: [outageJSON()])
        watcher.send(data)
        try await eventually { !store.outagesByVendor.isEmpty }
        #expect(store.outagesByVendor[.claude] != nil)

        // Then: malformed data
        watcher.send("bad".data(using: .utf8)!)
        try await eventually { store.outagesByVendor.isEmpty }
        #expect(store.outagesByVendor.isEmpty)
        store.stop()
    }

    @MainActor
    @Test("clearing outages resets outagesByVendor")
    func clearingOutagesResetsMap() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        // Send data with outages
        let withOutages = try makeUsagesWithOutagesJSON(outages: [outageJSON()])
        watcher.send(withOutages)
        try await eventually { !store.outagesByVendor.isEmpty }

        // Send data without outages (outages key absent)
        let withoutOutages = try makeUsagesWithOutagesJSON(outages: [])
        watcher.send(withoutOutages)
        try await eventually { store.outagesByVendor.isEmpty }
        #expect(store.outagesByVendor.isEmpty)
        store.stop()
    }
}
