import AppKit
import AIUsagesTrackersLib

/// Rasterises the full menu bar label into a non-template `NSImage`.
/// MenuBarExtra's label was unusable: template tinting stripped the per-tier
/// dot colors, and mixed HStacks silently truncated segments past the first.
/// With a custom `NSStatusItem`, we control `isTemplate = false` so hues
/// survive and we pick the text color from the status button's effective
/// appearance (which tracks the menu bar, not the app).
@MainActor
enum MenuBarLabelRenderer {
    private static let font: NSFont = .menuBarFont(ofSize: 0)
    private static let separator = " | "
    private static let dot = "● "
    private static let horizontalPadding: CGFloat = 4
    private static let height: CGFloat = 18

    static func render(
        segments: [MenuBarSegment],
        fallbackText: String,
        isDarkMenuBar: Bool
    ) -> NSImage {
        let textColor: NSColor = isDarkMenuBar ? .white : .black
        let attributed = attributedString(
            segments: segments,
            fallbackText: fallbackText,
            textColor: textColor
        )
        let textSize = attributed.size()
        let width = ceil(textSize.width) + horizontalPadding * 2
        let size = NSSize(width: max(width, 1), height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        let textY = (height - ceil(textSize.height)) / 2
        attributed.draw(at: NSPoint(x: horizontalPadding, y: textY))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func attributedString(
        segments: [MenuBarSegment],
        fallbackText: String,
        textColor: NSColor
    ) -> NSAttributedString {
        guard !segments.isEmpty else {
            return NSAttributedString(
                string: fallbackText,
                attributes: [.font: font, .foregroundColor: textColor]
            )
        }
        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: separator,
                    attributes: [.font: font, .foregroundColor: textColor]
                ))
            }
            if segment.showDot {
                let dotColor = segment.tier?.nsColor ?? textColor
                result.append(NSAttributedString(
                    string: dot,
                    attributes: [.font: font, .foregroundColor: dotColor]
                ))
            }
            result.append(NSAttributedString(
                string: segment.text,
                attributes: [.font: font, .foregroundColor: textColor]
            ))
        }
        return result
    }
}
