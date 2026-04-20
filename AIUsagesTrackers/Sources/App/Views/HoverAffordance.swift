import SwiftUI

/// Adds a subtle macOS-native hover affordance (rounded fill + pointing-hand cursor)
/// so borderless icon/text buttons read as clickable. Mirrors the toolbar icon
/// behaviour in Safari, Finder and Notes.
struct HoverAffordance: ViewModifier {
    var cornerRadius: CGFloat = 5
    var horizontalPadding: CGFloat = 5
    var verticalPadding: CGFloat = 3
    var isEnabled: Bool = true

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let enterDuration: Double = 0.15
    private static let exitDuration: Double = 0.11
    private static let hoverScale: CGFloat = 1.04

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovering && isEnabled ? 0.10 : 0))
            )
            .scaleEffect(isHovering && isEnabled ? Self.hoverScale : 1.0)
            .animation(
                reduceMotion
                    ? .linear(duration: 0.01)
                    : .easeOut(duration: isHovering ? Self.enterDuration : Self.exitDuration),
                value: isHovering
            )
            .onHover { hovering in
                isHovering = hovering
                guard isEnabled else {
                    NSCursor.arrow.set()
                    return
                }
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    /// Applies a hover background + cursor change so the view reads as clickable.
    /// Pass `isEnabled: false` to suppress the affordance (e.g. while a refresh is in flight).
    func hoverAffordance(
        cornerRadius: CGFloat = 5,
        horizontalPadding: CGFloat = 5,
        verticalPadding: CGFloat = 3,
        isEnabled: Bool = true
    ) -> some View {
        modifier(HoverAffordance(
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            isEnabled: isEnabled
        ))
    }
}
