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

/// One segment of the menu bar label — a single metric's formatted text, its
/// tier, and whether the leading colored dot should be drawn. Pay-as-you-go
/// segments render without a dot; time-window segments respect the user's
/// `showDot` toggle. Vendor icon and outage warning are no longer carried
/// here: they are chip-level chrome owned by `RenderedChip`.
public struct MenuBarSegment: Sendable, Equatable {
    public let text: String
    public let tier: ConsumptionTier?
    public let showDot: Bool
    /// Resolved from `TimeWindowDisplay.colorizeText`. When true and `tier`
    /// is non-nil, the renderer tints the segment text with the tier color.
    public let colorizeText: Bool

    public init(
        text: String,
        tier: ConsumptionTier?,
        showDot: Bool,
        colorizeText: Bool = false
    ) {
        self.text = text
        self.tier = tier
        self.showDot = showDot
        self.colorizeText = colorizeText
    }
}

/// A chip ready to be drawn on the menu bar: vendor icon + optional outage
/// warning + a non-empty list of rendered sub-segments. Built by `UsageStore`
/// from a `ResolvedMenuBarChip`, then handed to `MenuBarLabelRenderer`.
public struct RenderedChip: Sendable, Equatable {
    public let vendor: Vendor
    public let showVendorIcon: Bool
    /// Non-nil only when the chip opted into the warning AND the vendor
    /// currently has at least one active outage.
    public let outageWarningText: String?
    public let segments: [MenuBarSegment]

    public init(
        vendor: Vendor,
        showVendorIcon: Bool,
        outageWarningText: String?,
        segments: [MenuBarSegment]
    ) {
        self.vendor = vendor
        self.showVendorIcon = showVendorIcon
        self.outageWarningText = outageWarningText
        self.segments = segments
    }
}

/// Formats the user-configured menu bar chips. Iterates the chips declared
/// in `AppPreferences.menuBarChips`, resolves each against the latest usages
/// file contents, and exposes the rendered chips for the menu bar renderer.
/// Falls back to `"--"` (and an empty chip list) when no chip can be rendered.
@Observable
@MainActor
public final class UsageStore {
    public private(set) var menuBarText: String = "--"
    public private(set) var menuBarTier: ConsumptionTier?
    public private(set) var menuBarChips: [RenderedChip] = []
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
        // Pre-settings-window defaults: one Claude chip with two segments
        // (5h session + Weekly) for the currently-active account. Kept inline
        // so onboarding can ship an empty seed via
        // `MenuBarChipsSeeder.defaultChips()` without breaking tests and
        // callers that rely on `UsageStore` rendering meaningful output
        // without an explicit preferences store.
        let chip = MenuBarChipConfig(
            vendor: .claude,
            segments: [
                MenuBarChipSegmentConfig(
                    account: .currentlyActive,
                    metricName: "5h sessions (all models)",
                    display: .timeWindow(TimeWindowDisplay(letter: "S"))
                ),
                MenuBarChipSegmentConfig(
                    account: .currentlyActive,
                    metricName: "Weekly (all models)",
                    display: .timeWindow(TimeWindowDisplay(letter: "W"))
                ),
            ]
        )
        return InMemoryAppPreferences(
            menuBarChips: [chip],
            menuBarChipsInitialized: true
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
            menuBarChips = []
        }
    }

    private func refreshMenuBarText() {
        guard lastFile != nil else { return }
        applyFormat()
    }

    /// Re-runs formatting whenever `preferences.menuBarChips` changes so the
    /// menu bar updates as the user edits the chip configuration. Tracking
    /// fires once per registration — re-arm inside the callback.
    private func trackPreferencesChanges() {
        withObservationTracking {
            _ = preferences.menuBarChips
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
        let chipConfigs = preferences.menuBarChips
        var renderedChips: [RenderedChip] = []
        var allSegmentTexts: [String] = []
        var maxTier: ConsumptionTier?
        for chipConfig in chipConfigs {
            let resolution = MenuBarChipResolver.resolve(
                chip: chipConfig,
                entries: entries,
                outagesByVendor: outagesByVendor,
                now: now
            )
            var renderedSegments: [MenuBarSegment] = []
            for resolvedSegment in resolution.segments {
                if let segment = resolvedSegment.rendered {
                    renderedSegments.append(segment)
                    allSegmentTexts.append(segment.text)
                    if let tier = segment.tier {
                        maxTier = maxTier.map { Swift.max($0, tier) } ?? tier
                    }
                } else if let issue = resolvedSegment.issue {
                    logger.log(.debug, "UsageStore: skipping segment \(resolvedSegment.config.metricName) — \(issue)")
                }
            }
            // A chip with zero rendered segments is dropped from the menu bar
            // entirely (rather than drawn as an empty pill) — same end-state
            // as the legacy per-segment skip.
            guard !renderedSegments.isEmpty else { continue }
            renderedChips.append(RenderedChip(
                vendor: chipConfig.vendor,
                showVendorIcon: chipConfig.showVendorIcon,
                outageWarningText: resolution.outageWarningText,
                segments: renderedSegments
            ))
        }
        menuBarChips = renderedChips
        // `menuBarText` is kept around for plain-text consumers (e.g. tests,
        // refresh dedup keys). Chips drop the configurable separator, so we
        // join segment texts with a single space — purely an aggregation
        // signal, never rendered to the user as-is.
        menuBarText = allSegmentTexts.isEmpty ? Self.fallbackText : allSegmentTexts.joined(separator: " ")
        menuBarTier = maxTier
    }
}
