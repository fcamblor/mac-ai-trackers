import Foundation
import Observation

// MARK: - Clock abstraction (testable time source)

/// Abstracts `Date.now` so tests can inject a fixed point in time.
public protocol ClockProvider: Sendable {
    func now() -> Date
}

public struct SystemClock: ClockProvider {
    public init() {}
    public func now() -> Date { Date() }
}

// MARK: - Store

/// Formats the active Claude account's time-window metrics for the menu bar.
/// Example: `S 48% 2h 13m | W 7% 6d 6h 13m`. Falls back to `"--"` when data is
/// unavailable, malformed, or no active account is found.
@Observable
@MainActor
public final class UsageStore {
    public private(set) var menuBarText: String = "--"
    public private(set) var menuBarTier: ConsumptionTier?
    /// Incremented each time handleNewData is called, whether the data is valid or malformed.
    /// Tests use this as a reliable signal that the store has consumed the latest yielded item.
    public private(set) var dataProcessedCount: Int = 0
    public private(set) var entries: [VendorUsageEntry] = []

    // MARK: Dependencies

    private let fileWatcher: FileWatching
    private let clock: ClockProvider
    private let logger: FileLogger
    private let countdownRefreshSeconds: UInt64

    public static let defaultCountdownRefreshSeconds: UInt64 = 60
    private static let fallbackText = "--"
    private static let targetVendor: Vendor = .claude
    // Only top-level aggregate metrics belong in the compact menu bar label; per-model breakdowns live in the popover only
    private static let menuBarMetricNames: Set<String> = ["session", "weekly"]

    // Latest decoded file kept for countdown refresh without re-reading disk
    private var lastFile: UsagesFile?

    private var watchTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    public init(
        fileWatcher: FileWatching,
        clock: ClockProvider = SystemClock(),
        logger: FileLogger = Loggers.app,
        countdownRefreshSeconds: UInt64 = UsageStore.defaultCountdownRefreshSeconds
    ) {
        self.fileWatcher = fileWatcher
        self.clock = clock
        self.logger = logger
        self.countdownRefreshSeconds = countdownRefreshSeconds
    }

    // MARK: Lifecycle

    /// Start watching the file and refreshing the countdown.
    /// Idempotent — calling again is a no-op.
    public func start() {
        guard watchTask == nil else { return }

        let watcher = fileWatcher
        // Self is captured strongly; stop() cancels both tasks to break the cycle
        watchTask = Task { [self] in
            for await data in watcher.changes() {
                guard !Task.isCancelled else { break }
                self.handleNewData(data)
            }
        }

        countdownTask = Task { [self] in
            let refreshNanos = self.countdownRefreshSeconds * 1_000_000_000
            while !Task.isCancelled {
                // CancellationError swallowed intentionally; checked on next loop iteration
                try? await Task.sleep(nanoseconds: refreshNanos)
                guard !Task.isCancelled else { break }
                self.refreshMenuBarText()
            }
        }
    }

    /// Stop all background tasks. Idempotent.
    public func stop() {
        watchTask?.cancel()
        watchTask = nil
        countdownTask?.cancel()
        countdownTask = nil
    }

    // Defensive: cancels tasks when the store is released without an explicit stop() call.
    @MainActor deinit { stop() }

    // MARK: - Processing

    private func handleNewData(_ data: Data) {
        dataProcessedCount += 1
        do {
            let file = try JSONDecoder().decode(UsagesFile.self, from: data)
            lastFile = file
            entries = file.usages
            let result = format(file: file)
            menuBarText = result.text
            menuBarTier = result.tier
        } catch {
            logger.log(.error, "UsageStore: JSON decode failed: \(error)")
            lastFile = nil
            entries = []
            menuBarText = Self.fallbackText
            menuBarTier = nil
        }
    }

    private func refreshMenuBarText() {
        guard let file = lastFile else { return }
        let result = format(file: file)
        menuBarText = result.text
        menuBarTier = result.tier
    }

    // MARK: - Formatting

    private struct FormatResult {
        let text: String
        let tier: ConsumptionTier?
    }

    private func format(file: UsagesFile) -> FormatResult {
        guard let entry = file.usages.first(where: {
            $0.vendor == Self.targetVendor && $0.isActive
        }) else {
            return FormatResult(text: Self.fallbackText, tier: nil)
        }

        let now = clock.now()
        var segments: [String] = []
        var worstTier: ConsumptionTier?

        for metric in entry.metrics {
            guard let segment = formatTimeWindowSegment(metric) else { continue }
            segments.append(segment)

            // Compute tier for this metric to track the worst across all displayed metrics
            if case let .timeWindow(_, resetAt, windowDuration, usagePercent) = metric {
                let theoretical = theoreticalFraction(resetAt: resetAt, windowDuration: windowDuration, now: now)
                if let ratio = consumptionRatio(actualPercent: usagePercent, theoreticalFraction: theoretical) {
                    let tier = consumptionTier(ratio: ratio)
                    worstTier = worstTier.map { max($0, tier) } ?? tier
                }
            }
        }

        let text = segments.isEmpty ? Self.fallbackText : segments.joined(separator: " | ")
        return FormatResult(text: text, tier: segments.isEmpty ? nil : worstTier)
    }

    private func formatTimeWindowSegment(_ metric: UsageMetric) -> String? {
        if case let .unknown(t) = metric {
            logger.log(.debug, "UsageStore: skipping unknown metric type '\(t)'")
        }
        guard case let .timeWindow(name, resetAt, _, usagePercent) = metric else {
            return nil
        }
        guard Self.menuBarMetricNames.contains(name) else { return nil }

        let abbreviation = name.prefix(1).uppercased()
        // A metric with an empty name cannot be abbreviated — skip to avoid a leading space in output
        guard !abbreviation.isEmpty else { return nil }
        let remaining = formatRemainingTime(resetAt: resetAt)
        return "\(abbreviation) \(usagePercent.rawValue)% \(remaining)"
    }

    private func formatRemainingTime(resetAt: ISODate) -> String {
        guard resetAt.date != nil else {
            logger.log(.warning, "UsageStore: invalid ISO8601 resetAt value: \(resetAt.rawValue)")
            return "--"
        }
        return AIUsagesTrackersLib.formatRemainingTime(resetAt: resetAt, now: clock.now())
    }
}
