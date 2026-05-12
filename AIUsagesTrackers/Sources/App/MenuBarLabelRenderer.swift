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
    private static let horizontalPadding: CGFloat = 4
    private static let height: CGFloat = 18
    // Diameter of the colored dot as a fraction of the font's cap height.
    // Slightly bigger than the cap height so the disc reads as a deliberate
    // status indicator rather than a punctuation glyph.
    private static let dotDiameterRatio: CGFloat = 1.15
    // Thin enough not to swallow small fills, thick enough to stay legible
    // against arbitrary menu-bar wallpapers — including ones that happen to
    // match the dot's fill color.
    private static let dotStrokeLineWidth: CGFloat = 1.0
    // Horizontal whitespace after the dot, before the segment's text.
    private static let dotTrailingGap: String = " "
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

    /// Renders the colored pastille as a filled disc with a contrasted outline.
    /// The fill carries the dot's identity (its tier, or the unknown gray); the
    /// stroke carries the surrounding text color so the disc stays legible
    /// even when its fill blends into the menu-bar wallpaper. The stroke is
    /// inset by half its width so the visible diameter matches `diameter`.
    private static func makeDotImage(
        fillColor: NSColor,
        strokeColor: NSColor,
        diameter: CGFloat
    ) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        let inset = dotStrokeLineWidth / 2
        let ovalRect = NSRect(
            x: inset,
            y: inset,
            width: diameter - 2 * inset,
            height: diameter - 2 * inset
        )
        let path = NSBezierPath(ovalIn: ovalRect)
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = dotStrokeLineWidth
        path.stroke()
        image.unlockFocus()
        image.isTemplate = false
        return image
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
               let icon = VendorBrandingResolver.tintedNSImage(for: vendor, height: font.capHeight) {
                let attachment = NSTextAttachment()
                attachment.image = icon
                let pad = VendorBrandingResolver.iconGlowPadding
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
            if let warning = segment.outageWarningText, !warning.isEmpty {
                result.append(NSAttributedString(
                    string: warning + "\u{2009}",
                    attributes: [.font: font, .foregroundColor: textColor]
                ))
            }
            if segment.showDot {
                // Fill is data-driven (see Optional<ConsumptionTier>.dotNSColor)
                // so menu bar and Settings preview always agree. The stroke
                // tracks the surrounding text color, giving the dot a
                // contrasted outline against menu-bar wallpapers that happen
                // to match its fill (e.g. a green wallpaper behind a green
                // "comfortable" tier, or any wallpaper behind the "unknown"
                // mid-gray). Drawn as a custom NSImage attachment because
                // NSAttributedString.strokeWidth on a "●" glyph is absorbed
                // by the glyph's own fill — only a true bezier stroke gives
                // a visible outline.
                let diameter = ceil(font.capHeight * dotDiameterRatio)
                let dotImage = makeDotImage(
                    fillColor: segment.tier.dotNSColor,
                    strokeColor: textColor,
                    diameter: diameter
                )
                let attachment = NSTextAttachment()
                attachment.image = dotImage
                attachment.bounds = CGRect(
                    x: 0,
                    y: (font.capHeight - diameter) / 2,
                    width: diameter,
                    height: diameter
                )
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(
                    string: dotTrailingGap,
                    attributes: [.font: font, .foregroundColor: textColor]
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
