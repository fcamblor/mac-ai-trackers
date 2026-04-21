import SwiftUI
import AppKit

/// SwiftUI rendering of the application icon. Lives in its own target so both
/// the running app (assigning it to `NSApplication.shared.applicationIconImage`)
/// and the packaging tooling (exporting an `.iconset`) can share the same source
/// of truth instead of shipping a static `.icns` that drifts from the design.
public struct AppIconView: View {
    private static let canvasSize: CGFloat = 1024
    private static let squircleRadius: CGFloat = 228

    private static let cardWidth: CGFloat = 720
    private static let cardHeight: CGFloat = 560
    private static let cardCornerRadius: CGFloat = 72
    private static let cardStrokeWidth: CGFloat = 20
    private static let cardTiltDegrees: Double = -5

    private static let barInnerWidth: CGFloat = 560
    private static let barHeight: CGFloat = 72
    private static let barSpacing: CGFloat = 64
    private static let barLeadingInset: CGFloat = 80
    private static let barTopInset: CGFloat = 120
    private static let tickWidth: CGFloat = 10
    private static let tickOverhang: CGFloat = 12

    // Warm ivory → peach background; evokes a paper / instrument panel.
    private let backgroundTop = Color(red: 0.977, green: 0.967, blue: 0.945)
    private let backgroundBottom = Color(red: 0.935, green: 0.890, blue: 0.841)

    // Deep navy ink: card stroke + tick marks.
    private let ink = Color(red: 0.102, green: 0.161, blue: 0.259)
    // Neutral track beneath each progress bar.
    private let track = Color(red: 0.924, green: 0.902, blue: 0.863)

    // Bar fills mirror the app's status palette (green/yellow/blue) calibrated
    // for a warm background — more muted than the UI's systemGreen/Yellow/Blue.
    private let greenFill = Color(red: 0.353, green: 0.710, blue: 0.384)
    private let yellowFill = Color(red: 0.878, green: 0.745, blue: 0.298)
    private let blueFill = Color(red: 0.298, green: 0.557, blue: 0.867)

    public init() {}

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.squircleRadius, style: .continuous)
                .fill(LinearGradient(
                    colors: [backgroundTop, backgroundBottom],
                    startPoint: .top,
                    endPoint: .bottom
                ))

            tiltedCard
        }
        .frame(width: Self.canvasSize, height: Self.canvasSize)
    }

    private var tiltedCard: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous)
                        .strokeBorder(ink, lineWidth: Self.cardStrokeWidth)
                )

            progressBar(fillRatio: 112.0 / Self.barInnerWidth,
                        tickRatio: 218.0 / Self.barInnerWidth,
                        color: greenFill)
                .offset(x: Self.barLeadingInset, y: Self.barTopInset)

            progressBar(fillRatio: 334.0 / Self.barInnerWidth,
                        tickRatio: 394.0 / Self.barInnerWidth,
                        color: yellowFill)
                .offset(x: Self.barLeadingInset,
                        y: Self.barTopInset + Self.barHeight + Self.barSpacing)

            progressBar(fillRatio: 202.0 / Self.barInnerWidth,
                        tickRatio: 288.0 / Self.barInnerWidth,
                        color: blueFill)
                .offset(x: Self.barLeadingInset,
                        y: Self.barTopInset + 2 * (Self.barHeight + Self.barSpacing))
        }
        .frame(width: Self.cardWidth, height: Self.cardHeight)
        .rotationEffect(.degrees(Self.cardTiltDegrees))
    }

    private func progressBar(fillRatio: CGFloat, tickRatio: CGFloat, color: Color) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(track)

            Capsule()
                .fill(color)
                .frame(width: Self.barInnerWidth * fillRatio)

            RoundedRectangle(cornerRadius: Self.tickWidth / 2, style: .continuous)
                .fill(ink)
                .frame(width: Self.tickWidth,
                       height: Self.barHeight + 2 * Self.tickOverhang)
                .offset(x: Self.barInnerWidth * tickRatio - Self.tickWidth / 2)
        }
        .frame(width: Self.barInnerWidth, height: Self.barHeight)
    }
}

@MainActor
public enum AppIconRenderer {
    /// Rasterises `AppIconView` to an `NSImage` at the requested pixel size.
    /// The view's intrinsic size is 1024 points, so the renderer's scale
    /// factor is the ratio between target pixels and 1024.
    public static func makeImage(pixelSize: CGFloat = 1024) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = pixelSize / 1024
        return renderer.nsImage
    }

    /// CGImage variant — needed by packaging tooling that writes PNG files
    /// through `CGImageDestination`.
    public static func makeCGImage(pixelSize: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = pixelSize / 1024
        return renderer.cgImage
    }
}

#Preview {
    AppIconView()
        .frame(width: 256, height: 256)
        .padding()
}
