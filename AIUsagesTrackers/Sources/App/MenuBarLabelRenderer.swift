import AppKit
import AIUsagesTrackersLib

/// Rasterises the full menu bar label into a non-template `NSImage`. Each
/// configured chip is drawn as a rounded pill ("chip background") containing
/// the vendor icon + optional outage warning + every rendered sub-segment.
/// The colours that fill the pill and tint the text come from `ChipBackground`
/// — three curated palettes keep the tier colours legible without per-chip
/// tuning.
///
/// `MenuBarExtra`'s template tinting would strip the pill background and the
/// per-tier dot colours, so we keep the existing `NSStatusItem` + custom
/// rasterisation strategy and set `isTemplate = false` on the output.
@MainActor
enum MenuBarLabelRenderer {
    private static let font: NSFont = .menuBarFont(ofSize: chipFontSize)
    // Slightly below the default menu bar font (~13pt) so two chips with
    // multiple sub-segments stay within a reasonable horizontal budget while
    // staying comfortable to read against the pill background.
    private static let chipFontSize: CGFloat = 12
    // Vendor icons are sized from the font, but capHeight alone yields a
    // shape that reads as smaller than text glyphs at the same point size —
    // multi-stroke logos (Codex, Claude) lose detail. Bumping above capHeight
    // gives the icon the visual weight of an emoji rather than a punctuation
    // glyph.
    private static let vendorIconHeightRatio: CGFloat = 1.35
    private static let menuBarHeight: CGFloat = 22
    // The pill is inset from the menu bar so it never butts against the
    // system-drawn separators on either side.
    private static let chipVerticalInset: CGFloat = 2
    private static let chipHorizontalPaddingH: CGFloat = 6
    private static let chipCornerRadius: CGFloat = 7
    // Horizontal gap between two adjacent chips.
    private static let interChipGap: CGFloat = 4
    // Diameter of the tier dot as a fraction of the font's cap height.
    private static let dotDiameterRatio: CGFloat = 1.15
    // Narrow space between a dot and the text that follows it.
    private static let dotTrailingGap: String = " "
    // Thin space between two adjacent sub-segments inside the same chip.
    private static let intraChipSegmentGap: String = "  "
    // Gap between the vendor icon (or outage warning) and the first segment.
    private static let chipLeadInGap: String = " "
    // Outside padding around the rasterised image — keeps the pill from
    // touching the system clock or the next status item.
    private static let outerHorizontalPadding: CGFloat = 2

    static let unconfiguredCallToAction = "Configure AI Metrics"

    /// Resolved palette derived from `ChipBackground` + the menu bar
    /// appearance. Both colours are concrete (no light/dark/auto runtime
    /// switching past this point) so the renderer can ask once and stop
    /// branching.
    struct ResolvedChipPalette {
        let pillColor: NSColor
        let textColor: NSColor
    }

    static func resolvePalette(
        background: ChipBackground,
        isDarkMenuBar: Bool
    ) -> ResolvedChipPalette {
        switch background {
        case .paper:
            return ResolvedChipPalette(pillColor: paperPill, textColor: darkOnPaper)
        case .slate:
            return ResolvedChipPalette(pillColor: slatePill, textColor: lightOnSlate)
        case .system:
            return isDarkMenuBar
                ? ResolvedChipPalette(pillColor: slatePill, textColor: lightOnSlate)
                : ResolvedChipPalette(pillColor: paperPill, textColor: darkOnPaper)
        }
    }

    // Curated pill / text colour pairs. Pure black/white avoided to keep the
    // pill feeling like part of the wallpaper rather than a print artefact.
    private static let paperPill = NSColor(white: 0.98, alpha: 1.0)
    private static let darkOnPaper = NSColor(white: 0.08, alpha: 1.0)
    private static let slatePill = NSColor(red: 0.16, green: 0.18, blue: 0.20, alpha: 1.0)
    private static let lightOnSlate = NSColor(white: 0.96, alpha: 1.0)

    // MARK: - Public API

    static func render(
        chips: [RenderedChip],
        background: ChipBackground,
        fallbackText: String,
        isDarkMenuBar: Bool,
        tierOverride: ConsumptionTier? = nil,
        isUnconfigured: Bool = false
    ) -> NSImage {
        let menuBarTextColor: NSColor = isDarkMenuBar ? .white : .black

        // Unconfigured state stays outside the pill metaphor — drawing a chip
        // around the gear + "Configure" text would visually claim the feature
        // is in a working state, which it isn't.
        if isUnconfigured && chips.isEmpty {
            let attributed = unconfiguredAttributedString(textColor: menuBarTextColor)
            return rasterise(attributed: attributed, height: menuBarHeight)
        }

        if chips.isEmpty {
            let attributed = NSAttributedString(
                string: fallbackText,
                attributes: [.font: font, .foregroundColor: menuBarTextColor]
            )
            return rasterise(attributed: attributed, height: menuBarHeight)
        }

        let palette = resolvePalette(background: background, isDarkMenuBar: isDarkMenuBar)
        return renderChips(
            chips: chips,
            palette: palette,
            tierOverride: tierOverride
        )
    }

    // MARK: - Chip composition

    private static func renderChips(
        chips: [RenderedChip],
        palette: ResolvedChipPalette,
        tierOverride: ConsumptionTier?
    ) -> NSImage {
        let chipContents: [(NSAttributedString, CGSize)] = chips.map { chip in
            let attributed = chipAttributedString(
                chip: chip,
                palette: palette,
                tierOverride: tierOverride
            )
            return (attributed, attributed.size())
        }

        let chipPillHeight = menuBarHeight - chipVerticalInset * 2
        var totalWidth: CGFloat = outerHorizontalPadding
        for (index, content) in chipContents.enumerated() {
            if index > 0 { totalWidth += interChipGap }
            totalWidth += ceil(content.1.width) + chipHorizontalPaddingH * 2
        }
        totalWidth += outerHorizontalPadding

        let image = NSImage(size: NSSize(width: max(totalWidth, 1), height: menuBarHeight))
        image.lockFocus()

        var x: CGFloat = outerHorizontalPadding
        for (index, content) in chipContents.enumerated() {
            if index > 0 { x += interChipGap }
            let pillWidth = ceil(content.1.width) + chipHorizontalPaddingH * 2
            let pillRect = NSRect(
                x: x,
                y: chipVerticalInset,
                width: pillWidth,
                height: chipPillHeight
            )
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: chipCornerRadius, yRadius: chipCornerRadius)
            palette.pillColor.setFill()
            pillPath.fill()

            let textHeight = ceil(content.1.height)
            let textY = pillRect.minY + (pillRect.height - textHeight) / 2
            content.0.draw(at: NSPoint(x: x + chipHorizontalPaddingH, y: textY))
            x += pillWidth
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Builds the attributed string drawn inside a single chip pill.
    /// Composition order: vendor icon (optional) + outage warning (optional)
    /// + segments separated by a thin space.
    private static func chipAttributedString(
        chip: RenderedChip,
        palette: ResolvedChipPalette,
        tierOverride: ConsumptionTier?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: palette.textColor,
        ]

        if chip.showVendorIcon,
           let icon = VendorBrandingResolver.tintedNSImage(
                for: chip.vendor,
                height: ceil(font.capHeight * vendorIconHeightRatio)
           ) {
            let attachment = NSTextAttachment()
            attachment.image = icon
            // Pull the icon down so its visual centre sits on the cap-height
            // line — without this offset the bigger glyph hangs above the
            // text baseline and the chip looks top-heavy.
            let verticalOffset = -(icon.size.height - font.capHeight) / 2
            attachment.bounds = CGRect(
                x: 0,
                y: verticalOffset,
                width: icon.size.width,
                height: icon.size.height
            )
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: chipLeadInGap, attributes: defaultAttrs))
        }

        if let warning = chip.outageWarningText, !warning.isEmpty {
            result.append(NSAttributedString(string: warning + chipLeadInGap, attributes: defaultAttrs))
        }

        for (index, segment) in chip.segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: intraChipSegmentGap, attributes: defaultAttrs))
            }
            result.append(segmentAttributedString(
                segment: segment,
                palette: palette,
                tierOverride: tierOverride
            ))
        }
        return result
    }

    private static func segmentAttributedString(
        segment: MenuBarSegment,
        palette: ResolvedChipPalette,
        tierOverride: ConsumptionTier?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: palette.textColor,
        ]

        // The override forces a specific tier (used by the dev "cycle pacing
        // colours" timer). Production code keeps the tier resolved by the
        // chip resolver.
        let effectiveTier: ConsumptionTier? = tierOverride ?? segment.tier

        if segment.showDot {
            let diameter = ceil(font.capHeight * dotDiameterRatio)
            let dotImage = makeDotImage(
                fillColor: effectiveTier.dotNSColor,
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
            result.append(NSAttributedString(string: dotTrailingGap, attributes: defaultAttrs))
        }

        if !segment.text.isEmpty {
            let textAttrs: [NSAttributedString.Key: Any]
            if segment.colorizeText, let tier = effectiveTier {
                textAttrs = [.font: font, .foregroundColor: tier.nsColor]
            } else {
                textAttrs = defaultAttrs
            }
            result.append(NSAttributedString(string: segment.text, attributes: textAttrs))
        }

        return result
    }

    // MARK: - Dot drawing

    /// Solid disc filled with the tier colour. The chip pill already provides
    /// a contrasted background, so no stroke is needed (the original
    /// implementation drew one to defend against arbitrary wallpapers).
    private static func makeDotImage(fillColor: NSColor, diameter: CGFloat) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        let path = NSBezierPath(ovalIn: NSRect(origin: .zero, size: size))
        fillColor.setFill()
        path.fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: - Unconfigured state

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

    private static func rasterise(attributed: NSAttributedString, height: CGFloat) -> NSImage {
        let textSize = attributed.size()
        let width = ceil(textSize.width) + outerHorizontalPadding * 2
        let size = NSSize(width: max(width, 1), height: height)
        let image = NSImage(size: size)
        image.lockFocus()
        let textY = (height - ceil(textSize.height)) / 2
        attributed.draw(at: NSPoint(x: outerHorizontalPadding, y: textY))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

