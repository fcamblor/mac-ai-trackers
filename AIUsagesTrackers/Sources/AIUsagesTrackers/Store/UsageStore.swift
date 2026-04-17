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
    // MARK: Published state

    public private(set) var menuBarText: String = "--"

    // MARK: Dependencies

    private let fileWatcher: FileWatching
    private let clock: ClockProvider
    private let logger: FileLogger
    private let countdownRefreshSeconds: UInt64

    public static let defaultCountdownRefreshSeconds: UInt64 = 60
    private static let fallbackText = "--"
    private static let targetVendor = "claude"
    // @MainActor guarantees single-threaded access; safe despite NSFormatter not being thread-safe
    private static let isoFormatter = ISO8601DateFormatter()

    // Latest decoded file kept for countdown refresh without re-reading disk
    private var lastFile: UsagesFile?

    // MARK: Tasks

    private var watchTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    // MARK: Init

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

    // MARK: - Processing

    private func handleNewData(_ data: Data) {
        do {
            let file = try JSONDecoder().decode(UsagesFile.self, from: data)
            lastFile = file
            menuBarText = format(file: file)
        } catch {
            logger.log(.error, "UsageStore: JSON decode failed: \(error)")
            lastFile = nil
            menuBarText = Self.fallbackText
        }
    }

    private func refreshMenuBarText() {
        guard let file = lastFile else { return }
        menuBarText = format(file: file)
    }

    // MARK: - Formatting

    private func format(file: UsagesFile) -> String {
        guard let entry = file.usages.first(where: {
            $0.vendor == Self.targetVendor && $0.isActive
        }) else {
            return Self.fallbackText
        }

        let segments = entry.metrics.compactMap { metric -> String? in
            formatTimeWindowSegment(metric)
        }

        return segments.isEmpty ? Self.fallbackText : segments.joined(separator: " | ")
    }

    private func formatTimeWindowSegment(_ metric: UsageMetric) -> String? {
        guard case let .timeWindow(name, resetAt, _, usagePercent) = metric else {
            return nil
        }

        let abbreviation = name.prefix(1).uppercased()
        let remaining = formatRemainingTime(resetAt: resetAt)
        return "\(abbreviation) \(usagePercent)% \(remaining)"
    }

    private func formatRemainingTime(resetAt isoString: String) -> String {
        guard let resetDate = Self.isoFormatter.date(from: isoString) else {
            logger.log(.warning, "UsageStore: invalid ISO8601 resetAt value: \(isoString)")
            return "0m"
        }

        let now = clock.now()
        let totalSeconds = Int(resetDate.timeIntervalSince(now))

        guard totalSeconds > 0 else { return "0m" }

        let secondsPerMinute = 60
        let secondsPerHour = 3600
        let secondsPerDay = 86400

        let days = totalSeconds / secondsPerDay
        let hours = (totalSeconds % secondsPerDay) / secondsPerHour
        let minutes = (totalSeconds % secondsPerHour) / secondsPerMinute

        var parts: [String] = []
        if days > 0 { parts.append("\(days)d") }
        if hours > 0 { parts.append("\(hours)h") }
        // Always show minutes unless we have days+hours already
        if minutes > 0 || parts.isEmpty { parts.append("\(minutes)m") }

        return parts.joined(separator: " ")
    }
}
