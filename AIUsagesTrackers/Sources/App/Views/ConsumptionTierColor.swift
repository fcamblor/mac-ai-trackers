import SwiftUI
import AppKit
import AIUsagesTrackersLib

extension ConsumptionTier {
    /// SwiftUI color for this severity tier.
    /// System colors adapt to light/dark mode automatically.
    var color: Color {
        Color(nsColor)
    }

    /// AppKit color used when rasterising the menu bar label into an `NSImage`.
    /// Mirrors `color` but stays in AppKit so it can feed `NSAttributedString`.
    var nsColor: NSColor {
        switch self {
        case .comfortable: return .systemGreen
        case .onTrack:     return .systemBlue
        case .approaching: return .systemYellow
        case .over:        return .systemOrange
        case .critical:    return .systemRed
        // Purple keeps the bar visible in both light and dark mode; .labelColor (black in light
        // mode) made the theoretical-consumption tick invisible against the overflow background.
        case .exhausted:   return NSColor(red: 0x7B / 255.0, green: 0x2F / 255.0, blue: 0xBE / 255.0, alpha: 1.0)
        }
    }
}

extension Optional where Wrapped == ConsumptionTier {
    /// Single source of truth for the menu-bar dot color. The "unknown" case
    /// (no resolvable tier — e.g. percent shown as "???") gets a fixed mid-gray
    /// rather than falling back to the surrounding text color, so the dot looks
    /// the same in the real menu bar and in the Settings preview even when
    /// those two surfaces run in different appearances. The dot's contrasted
    /// border (see `MenuBarLabelRenderer`) keeps it visible against arbitrary
    /// menu-bar wallpapers regardless of fill color.
    var dotNSColor: NSColor {
        switch self {
        case .some(let tier): return tier.nsColor
        case .none:           return NSColor(white: 0.6, alpha: 1.0)
        }
    }
}
