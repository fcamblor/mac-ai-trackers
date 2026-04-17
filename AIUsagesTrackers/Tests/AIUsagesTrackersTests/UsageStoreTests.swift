import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - Test doubles

/// A mock FileWatching that lets tests push arbitrary Data payloads.
struct MockFileWatcher: FileWatching {
    let stream: AsyncStream<Data>
    let continuation: AsyncStream<Data>.Continuation

    init() {
        var cont: AsyncStream<Data>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    func changes() -> AsyncStream<Data> { stream }

    func send(_ data: Data) { continuation.yield(data) }
    func finish() { continuation.finish() }
}

/// A clock fixed at a given date, for deterministic remaining-time formatting.
struct FixedClock: ClockProvider {
    let date: Date
    init(_ date: Date) { self.date = date }
    func now() -> Date { date }
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

private func timeWindowMetric(
    name: String = "session",
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
            timeWindowMetric(name: "session", resetAt: "2026-04-17T15:00:00Z", usagePercent: 48),
        ])
        watcher.send(data)

        try await Task.sleep(nanoseconds: 50_000_000)

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
            timeWindowMetric(name: "session", resetAt: "2026-04-17T15:00:00Z", usagePercent: 48),
            timeWindowMetric(name: "weekly", resetAt: "2026-04-23T21:00:00Z", usagePercent: 7),
        ])
        watcher.send(data)
        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)

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
            timeWindowMetric(name: "session", resetAt: "2026-04-17T15:00:00Z", usagePercent: 48),
            payAsYouGoMetric(),
        ])
        watcher.send(data)
        try await Task.sleep(nanoseconds: 50_000_000)

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
            timeWindowMetric(name: "session", resetAt: "2026-04-17T10:00:00Z", usagePercent: 100),
        ])
        watcher.send(data)
        try await Task.sleep(nanoseconds: 50_000_000)

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
            timeWindowMetric(name: "session", resetAt: "2026-04-17T12:47:00Z", usagePercent: 50),
        ])
        watcher.send(data)
        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)

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
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.menuBarText == "--")

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "session", resetAt: "2026-04-17T13:00:00Z", usagePercent: 10),
        ])
        watcher.send(data)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.menuBarText == "S 10% 1h")

        store.stop()
    }
}

@Suite("UsageStore lifecycle")
struct UsageStoreLifecycleTests {

    @MainActor
    @Test("start is idempotent")
    func startIdempotent() {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()
        store.start()
        store.stop()
    }

    @MainActor
    @Test("stop is idempotent")
    func stopIdempotent() {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()
        store.stop()
        store.stop()
    }

    @MainActor
    @Test("stop before start is safe")
    func stopBeforeStart() {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
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
            timeWindowMetric(name: "daily", resetAt: "2026-04-18T00:00:00Z", usagePercent: 0),
        ])
        watcher.send(data)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.menuBarText == "D 0% 1d")
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

        // 3 days, 5 hours, 30 minutes in the future
        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "weekly", resetAt: "2026-04-20T05:30:00Z", usagePercent: 15),
        ])
        watcher.send(data)
        try await Task.sleep(nanoseconds: 50_000_000)

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
            timeWindowMetric(name: "session", resetAt: "2026-04-17T14:50:00Z", usagePercent: 95),
        ])
        watcher.send(data)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.menuBarText == "S 95% 5m")
        store.stop()
    }

    @MainActor
    @Test("invalid ISO8601 resetAt shows 0m")
    func invalidResetAt() async throws {
        let watcher = MockFileWatcher()
        let store = UsageStore(fileWatcher: watcher, countdownRefreshSeconds: 999)
        store.start()

        let data = try makeUsagesJSON(metrics: [
            timeWindowMetric(name: "session", resetAt: "not-a-date", usagePercent: 50),
        ])
        watcher.send(data)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.menuBarText == "S 50% 0m")
        store.stop()
    }

}
