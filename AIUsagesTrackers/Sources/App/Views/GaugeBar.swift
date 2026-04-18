import SwiftUI
import AIUsagesTrackersLib

/// A horizontal progress bar with an actual fill and a theoretical consumption marker.
/// The theoretical marker is a thin vertical tick showing expected consumption based on elapsed time.
struct GaugeBar: View {
    let actual: Double
    let theoretical: Double
    var tier: ConsumptionTier?

    private static let barHeight: CGFloat = 6
    private static let markerWidth: CGFloat = 2.5
    private static let cornerRadius: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(.quaternary)

                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .fill(fillColor)
                    .frame(width: width * clamp(actual))

                // Skip marker when no window data — avoids a tick pinned to the left edge at 0.
                if theoretical > 0 {
                    RoundedRectangle(cornerRadius: Self.markerWidth / 2)
                        .fill(.primary)
                        .frame(width: Self.markerWidth, height: Self.barHeight + 4)
                        .offset(x: width * clamp(theoretical) - Self.markerWidth / 2)
                }
            }
        }
        .frame(height: Self.barHeight)
    }

    private var fillColor: Color {
        if let tier { return tier.color }
        return .accentColor
    }

    private func clamp(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }
}
