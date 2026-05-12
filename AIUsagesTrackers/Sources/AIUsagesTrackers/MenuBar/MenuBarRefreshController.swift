import Foundation

/// Identity of a menu bar render: every field that influences the produced
/// image must appear here so equality means "the bitmap would be identical".
public struct MenuBarRenderKey: Equatable, Sendable {
    public let segments: [MenuBarSegment]
    public let text: String
    public let separator: String
    public let isDark: Bool
    public let isUnconfigured: Bool

    public init(
        segments: [MenuBarSegment],
        text: String,
        separator: String,
        isDark: Bool,
        isUnconfigured: Bool
    ) {
        self.segments = segments
        self.text = text
        self.separator = separator
        self.isDark = isDark
        self.isUnconfigured = isUnconfigured
    }
}

/// De-duplicates menu bar status item renders.
///
/// Reassigning `NSStatusItem.button.image` is not free: AppKit recomposes the
/// status item replicant view, which flips `button.effectiveAppearance` and
/// re-fires the KVO that triggered the render. Without dedup the feedback loop
/// pegs the main thread at ~600 renders/s. Two independent locks guard against
/// this and against any future caller pattern that re-asks for an identical
/// render:
///
/// 1. `refresh(key:)` skips the callback when `key` matches the last accepted
///    render — so the loop is bounded by *real* input changes.
/// 2. `shouldHandleAppearanceChange(isDark:)` lets the appearance KVO observer
///    discard fires where the resolved dark/aqua flag has not actually moved.
@MainActor
public final class MenuBarRefreshController {
    private let onRender: @MainActor (MenuBarRenderKey) -> Void

    /// Total number of accepted renders since instantiation. Exposed for
    /// diagnostics and integration smoke tests; tests assert against bounded
    /// growth under idle conditions.
    public private(set) var renderCount: Int = 0

    private var lastRenderedKey: MenuBarRenderKey?
    private var lastResolvedIsDark: Bool?

    public init(onRender: @escaping @MainActor (MenuBarRenderKey) -> Void) {
        self.onRender = onRender
    }

    /// QUALIFICATION-ONLY REGRESSION — DO NOT MERGE.
    /// Dedup guards intentionally removed to re-introduce the
    /// NSStatusItem render feedback loop and verify that the
    /// `StatusItemRenderSmoke` test discriminates on a GHA runner.
    public func refresh(key: MenuBarRenderKey) {
        lastRenderedKey = key
        lastResolvedIsDark = key.isDark
        renderCount += 1
        onRender(key)
    }

    /// QUALIFICATION-ONLY REGRESSION — DO NOT MERGE.
    public func shouldHandleAppearanceChange(isDark: Bool) -> Bool {
        lastResolvedIsDark = isDark
        return true
    }
}
