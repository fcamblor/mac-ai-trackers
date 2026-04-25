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

/// One segment of the menu bar label — a single metric's formatted text, its tier,
/// and whether the leading colored dot should be drawn. Pay-as-you-go segments
/// render without a dot; time-window segments respect the user's `showDot` toggle.
public struct MenuBarSegment: Sendable, Equatable {
    public let text: String
    public let tier: ConsumptionTier?
    public let showDot: Bool
    public let vendorIcon: Vendor?

    public init(text: String, tier: ConsumptionTier?, showDot: Bool, vendorIcon: Vendor? = nil) {
        self.text = text
        self.tier = tier
        self.showDot = showDot
        self.vendorIcon = vendorIcon
    }
}

/// Formats the user-configured menu bar segments. Iterates the segments declared
/// in `AppPreferences.menuBarSegments`, resolves each against the latest usages
/// file contents, and exposes the rendered label text + per-segment payloads.
/// Falls back to `"--"` when no segment can be rendered.
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
    public private(set) var outagesByVendor: [Vendor: [Outage]] = [:]

    // MARK: Dependencies

    private let fileWatcher: FileWatching
    private let clock: ClockProvider
    private let logger: FileLogger
    private let preferences: any AppPreferences
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

    // Latest decoded file kept for countdown refresh without re-reading disk
    private var lastFile: UsagesFile?

    private var watchTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    public init(
        fileWatcher: FileWatching,
        clock: ClockProvider = SystemClock(),
        logger: FileLogger = Loggers.app,
        preferences: (any AppPreferences)? = nil,
        countdownRefreshSeconds: UInt64 = UsageStore.defaultCountdownRefreshSeconds
    ) {
        self.fileWatcher = fileWatcher
        self.clock = clock
        self.logger = logger
        // Default preferences mirror the pre-settings-window behaviour (S + W for
        // currently-active Claude account) so existing callers and tests that
        // don't supply a preferences store still get meaningful output.
        self.preferences = preferences ?? Self.makeDefaultPreferences()
        self.countdownRefreshSeconds = countdownRefreshSeconds
    }

    private static func makeDefaultPreferences() -> any AppPreferences {
        InMemoryAppPreferences(
            menuBarSegments: MenuBarSegmentsSeeder.defaultSegments(),
            menuBarSegmentsInitialized: true
        )
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

        trackPreferencesChanges()
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
            outagesByVendor = file.outagesByVendor
            applyFormat()
        } catch {
            let preview = Self.rawPreview(data)
            logger.log(.error, "UsageStore: JSON decode failed: \(error) — bytes=\(data.count), preview=\(preview)")
            lastFile = nil
            entries = []
            outagesByVendor = [:]
            menuBarText = Self.fallbackText
            menuBarTier = nil
            menuBarSegments = []
        }
    }

    private func refreshMenuBarText() {
        guard lastFile != nil else { return }
        applyFormat()
    }

    /// Re-runs formatting whenever `preferences.menuBarSegments` changes so the
    /// menu bar updates as the user edits the segment configuration. Tracking
    /// fires once per registration — re-arm inside the callback.
    private func trackPreferencesChanges() {
        withObservationTracking {
            _ = preferences.menuBarSegments
            _ = preferences.menuBarSeparator
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshMenuBarText()
                self.trackPreferencesChanges()
            }
        }
    }

    // MARK: - Formatting

    private func applyFormat() {
        let now = clock.now()
        let configs = preferences.menuBarSegments
        var rendered: [MenuBarSegment] = []
        for config in configs {
            let resolution = MenuBarSegmentResolver.resolve(config: config, entries: entries, now: now)
            if let segment = resolution.rendered {
                rendered.append(segment)
            } else if let issue = resolution.issue {
                logger.log(.debug, "UsageStore: skipping segment \(config.metricName) — \(issue)")
            }
        }
        menuBarSegments = rendered
        menuBarText = rendered.isEmpty ? Self.fallbackText : rendered.map(\.text).joined(separator: preferences.menuBarSeparator)
        menuBarTier = rendered.compactMap(\.tier).max()
    }
}
