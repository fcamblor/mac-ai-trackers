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

/// One segment of the menu bar label — a single metric's formatted text and its tier.
public struct MenuBarSegment: Sendable {
    public let text: String
    public let tier: ConsumptionTier?
}

/// Formats the active Claude account's time-window metrics for the menu bar.
/// Example: `S 48% 2h 13m | W 7% 6d 6h 13m`. Falls back to `"--"` when data is
/// unavailable, malformed, or no active account is found.
@Observable
@MainActor
public final class UsageStore {
    public private(set) var menuBarText: String = "--"
    public private(set) var menuBarTier: ConsumptionTier?
    public private(set) var menuBarSegments: [MenuBarSegment] = []
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
    private static let rawPreviewMaxBytes = 200

    private static func rawPreview(_ data: Data) -> String {
        let slice = data.prefix(rawPreviewMaxBytes)
        if let text = String(data: slice, encoding: .utf8) {
            return "utf8:\(text.debugDescription)"
        }
        let hex = slice.map { String(format: "%02x", $0) }.joined()
        return "hex:\(hex)"
    }

    private static let targetVendor: Vendor = .claude
    // Only top-level aggregate metrics belong in the compact menu bar label; per-model breakdowns live in the popover only
    private static let menuBarMetricNames: Set<String> = ["5h sessions (all models)", "Weekly (all models)"]

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
            menuBarSegments = result.segments
        } catch {
            let preview = Self.rawPreview(data)
            logger.log(.error, "UsageStore: JSON decode failed: \(error) — bytes=\(data.count), preview=\(preview)")
            lastFile = nil
            entries = []
            menuBarText = Self.fallbackText
            menuBarTier = nil
            menuBarSegments = []
        }
    }

    private func refreshMenuBarText() {
        guard let file = lastFile else { return }
        let result = format(file: file)
        menuBarText = result.text
        menuBarTier = result.tier
        menuBarSegments = result.segments
    }

    // MARK: - Formatting

    private struct FormatResult {
        let segments: [MenuBarSegment]
        let text: String
        let tier: ConsumptionTier?
    }

    private func format(file: UsagesFile) -> FormatResult {
        guard let entry = file.usages.first(where: {
            $0.vendor == Self.targetVendor && $0.isActive
        }) else {
            return FormatResult(segments: [], text: Self.fallbackText, tier: nil)
        }

        let now = clock.now()
        var segments: [MenuBarSegment] = []

        for metric in entry.metrics {
            guard let segment = formatTimeWindowSegment(metric, now: now) else { continue }
            segments.append(segment)
        }

        let worstTier = segments.compactMap(\.tier).max()
        let text = segments.isEmpty ? Self.fallbackText : segments.map(\.text).joined(separator: " | ")
        return FormatResult(segments: segments, text: text, tier: segments.isEmpty ? nil : worstTier)
    }

    private func formatTimeWindowSegment(_ metric: UsageMetric, now: Date) -> MenuBarSegment? {
        if case let .unknown(t) = metric {
            logger.log(.debug, "UsageStore: skipping unknown metric type '\(t)'")
        }
        guard case let .timeWindow(name, resetAt, windowDuration, usagePercent) = metric else {
            return nil
        }
        guard Self.menuBarMetricNames.contains(name) else { return nil }

        let abbreviation = name.prefix(1).uppercased()
        // A metric with an empty name cannot be abbreviated — skip to avoid a leading space in output
        guard !abbreviation.isEmpty else { return nil }

        let remaining = formatRemainingTime(resetAt: resetAt, now: now)
        let text = "\(abbreviation) \(usagePercent.rawValue)% \(remaining)"

        let theoretical = theoreticalFraction(resetAt: resetAt, windowDuration: windowDuration, now: now)
        let tier = consumptionRatio(actualPercent: usagePercent, theoreticalFraction: theoretical)
            .map { consumptionTier(ratio: $0) }

        return MenuBarSegment(text: text, tier: tier)
    }

    private func formatRemainingTime(resetAt: ISODate, now: Date) -> String {
        guard resetAt.date != nil else {
            logger.log(.warning, "UsageStore: invalid ISO8601 resetAt value: \(resetAt.rawValue)")
            return "--"
        }
        return AIUsagesTrackersLib.formatRemainingTime(resetAt: resetAt, now: now)
    }
}
