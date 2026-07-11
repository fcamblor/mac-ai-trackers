import SwiftUI
import AIUsagesTrackersLib

/// A horizontal progress bar with an actual fill and a theoretical consumption marker.
/// The theoretical marker is a thin vertical tick showing expected consumption based on elapsed time.
///
/// Uses Canvas instead of GeometryReader to avoid LazyLayoutViewCache invalidation cycles
/// when rendered inside a LazyVStack in a ScrollView. GeometryReader creates child
/// AttributeGraph nodes whose size updates propagate dirty flags back into the scroll view,
/// causing requestImmediateUpdate on every display frame (100% CPU). Canvas receives its
/// size once from the layout system and draws in a single pass with no child nodes.
struct GaugeBar: View {
    let actual: Double
    let theoretical: Double
    var tier: ConsumptionTier?

    private static let barHeight: CGFloat = 6
    private static let markerWidth: CGFloat = 2.5
    private static let cornerRadius: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let cr = Self.cornerRadius

            context.fill(
                RoundedRectangle(cornerRadius: cr).path(in: CGRect(x: 0, y: 0, width: w, height: h)),
                with: .style(.quaternary)
            )

            let fillW = w * clamp(actual)
            if fillW > 0 {
                context.fill(
                    RoundedRectangle(cornerRadius: cr).path(in: CGRect(x: 0, y: 0, width: fillW, height: h)),
                    with: .color(fillColor)
                )
            }

            // Skip marker when no window data — avoids a tick pinned to the left edge at 0.
            if theoretical > 0 {
                let mx = w * clamp(theoretical) - Self.markerWidth / 2
                context.fill(
                    RoundedRectangle(cornerRadius: Self.markerWidth / 2)
                        .path(in: CGRect(x: mx, y: -2, width: Self.markerWidth, height: h + 4)),
                    with: .foreground
                )
            }
        }
        .frame(height: Self.barHeight)
    }

    private var fillColor: Color {
        tier?.color ?? .accentColor
    }

    private func clamp(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }
}
