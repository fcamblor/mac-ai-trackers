import SwiftUI
import AIUsagesTrackersLib

extension ConsumptionTier {
    /// SwiftUI color for this severity tier.
    /// System colors adapt to light/dark mode automatically.
    /// `exhausted` uses `labelColor` — strongest system text color in both appearances.
    var color: Color {
        switch self {
        case .comfortable: return .green
        case .onTrack:     return .blue
        case .approaching: return .yellow
        case .over:        return .orange
        case .critical:    return .red
        case .exhausted:   return Color(NSColor.labelColor)
        }
    }
}
