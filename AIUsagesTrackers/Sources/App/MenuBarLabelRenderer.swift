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
    private static let dot = "● "
    private static let horizontalPadding: CGFloat = 4
    private static let height: CGFloat = 18
    static let unconfiguredCallToAction = "Configure AI Metrics"

    static func render(
        segments: [MenuBarSegment],
        separator: String,
        fallbackText: String,
        isDarkMenuBar: Bool,
        isUnconfigured: Bool = false
    ) -> NSImage {
        let textColor: NSColor = isDarkMenuBar ? .white : .black
        let attributed: NSAttributedString
        if isUnconfigured && segments.isEmpty {
            attributed = unconfiguredAttributedString(textColor: textColor)
        } else {
            attributed = attributedString(
                segments: segments,
                separator: separator,
                fallbackText: fallbackText,
                textColor: textColor
            )
        }
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

    private static func unconfiguredAttributedString(textColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let gear = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        if let gear {
            let configured = gear.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            ) ?? gear
            configured.isTemplate = true
            let tinted = NSImage(size: configured.size, flipped: false) { rect in
                configured.draw(in: rect)
                textColor.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.isTemplate = false
            let attachment = NSTextAttachment()
            attachment.image = tinted
            attachment.bounds = CGRect(
                x: 0,
                y: -1,
                width: tinted.size.width,
                height: tinted.size.height
            )
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(
                string: " ",
                attributes: [.font: font, .foregroundColor: textColor]
            ))
        }
        result.append(NSAttributedString(
            string: unconfiguredCallToAction,
            attributes: [.font: font, .foregroundColor: textColor]
        ))
        return result
    }

    private static func attributedString(
        segments: [MenuBarSegment],
        separator: String,
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
            if index > 0, !separator.isEmpty {
                result.append(NSAttributedString(
                    string: separator,
                    attributes: [.font: font, .foregroundColor: textColor]
                ))
            }
            if let vendor = segment.vendorIcon,
               let icon = VendorBranding.tintedNSImage(for: vendor, height: font.capHeight) {
                let attachment = NSTextAttachment()
                attachment.image = icon
                let pad = VendorBranding.iconGlowPadding
                attachment.bounds = CGRect(
                    x: -pad,
                    y: -pad,
                    width: icon.size.width,
                    height: icon.size.height
                )
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(
                    string: "\u{2009}",
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
