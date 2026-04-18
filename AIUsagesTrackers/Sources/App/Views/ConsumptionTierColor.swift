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
