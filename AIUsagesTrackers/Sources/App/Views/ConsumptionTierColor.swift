import SwiftUI
import AppKit
import AIUsagesTrackersLib

extension ConsumptionTier {
    /// SwiftUI color for this severity tier.
    /// System colors adapt to light/dark mode automatically.
    /// `exhausted` uses `labelColor` — strongest system text color in both appearances.
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
        case .exhausted:   return .labelColor
        }
    }
}
