import AppKit
import AIUsagesTrackersLib

/// Rasterises the full menu bar label into a non-template `NSImage`. Each
/// configured chip is drawn as a single rounded pill enclosing every piece:
///   1. An optional "header" zone carrying the vendor icon and/or the outage
///      warning, painted with the user-selected `ChipBackground` palette
///      (paper/slate/system → off-white or slate-grey, picked against the menu
///      bar appearance).
///   2. One rectangular zone per rendered sub-segment, filled with the
///      segment's tier colour. The text colour for each zone is chosen
///      automatically to maximise contrast against the fill (pure black or
///      pure white). Segment zones share the chip's rounded outline — they're
///      clipped against it so the chip looks like one solid pill.
///
/// `MenuBarExtra`'s template tinting would strip the pill colours, so we keep
/// the existing `NSStatusItem` + custom rasterisation strategy and set
/// `isTemplate = false` on the output.
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
    // Pills are inset from the menu bar so they never butt against the
    // system-drawn separators on either side.
    private static let chipVerticalInset: CGFloat = 2
    // Horizontal breathing room between a zone's text content and the edges
    // of that zone. The leading and trailing edges of the chip inherit the
    // rounded corners, so they keep the larger padding; inner edges (where
    // two zones meet) get a tighter inset because there's no curvature
    // eating into the space.
    private static let zoneOuterHorizontalPadding: CGFloat = 6
    private static let zoneInnerHorizontalPadding: CGFloat = 3
    private static let chipCornerRadius: CGFloat = 7
    // Horizontal gap between two adjacent chips.
    private static let interChipGap: CGFloat = 4
    // Gap between the vendor icon and the outage warning inside the header
    // zone, when both are present.
    private static let headerIconWarningGap: String = " "
    // Outside padding around the rasterised image — keeps the pill from
    // touching the system clock or the next status item.
    private static let outerHorizontalPadding: CGFloat = 2

    static let unconfiguredCallToAction = "Configure AI Metrics"

    /// Background + text colour pair used by pills whose colour isn't derived
    /// from a tier — i.e. the chip header pill (vendor icon / outage warning)
    /// and segments that have no resolved tier (pay-as-you-go, unknown state).
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

    /// One painted zone inside a chip — the header (vendor icon + warning) or
    /// one of the segments. Zones sit side-by-side inside the chip's single
    /// rounded outline; the leftmost and rightmost are clipped against that
    /// outline so they pick up its corner curvature.
    private struct ZonePlan {
        let attributed: NSAttributedString
        let textSize: CGSize
        let fillColor: NSColor
        /// True for the chip header — it stays on the chip palette and is the
        /// only zone whose fill matches the chip's "default" pill colour.
        let isHeader: Bool
    }

    private static func renderChips(
        chips: [RenderedChip],
        palette: ResolvedChipPalette,
        tierOverride: ConsumptionTier?
    ) -> NSImage {
        let chipPlans: [[ZonePlan]] = chips.map { chip in
            buildZonePlans(chip: chip, palette: palette, tierOverride: tierOverride)
        }
        let zonePaddings: [[(left: CGFloat, right: CGFloat)]] = chipPlans.map { zones in
            (0..<zones.count).map { index in
                let left: CGFloat = index == 0
                    ? zoneOuterHorizontalPadding
                    : zoneInnerHorizontalPadding
                let right: CGFloat = index == zones.count - 1
                    ? zoneOuterHorizontalPadding
                    : zoneInnerHorizontalPadding
                return (left, right)
            }
        }
        let zoneWidths: [[CGFloat]] = chipPlans.enumerated().map { chipIndex, zones in
            zones.enumerated().map { zoneIndex, zone in
                let pad = zonePaddings[chipIndex][zoneIndex]
                return ceil(zone.textSize.width) + pad.left + pad.right
            }
        }
        let chipWidths: [CGFloat] = zoneWidths.map { $0.reduce(0, +) }
        let chipHeight = menuBarHeight - chipVerticalInset * 2

        var totalWidth: CGFloat = outerHorizontalPadding
        for (index, width) in chipWidths.enumerated() {
            if index > 0 { totalWidth += interChipGap }
            totalWidth += width
        }
        totalWidth += outerHorizontalPadding

        let image = NSImage(size: NSSize(width: max(totalWidth, 1), height: menuBarHeight))
        image.lockFocus()

        var x: CGFloat = outerHorizontalPadding
        for (chipIndex, zones) in chipPlans.enumerated() {
            if chipIndex > 0 { x += interChipGap }
            let chipWidth = chipWidths[chipIndex]
            guard chipWidth > 0 else { continue }
            let chipRect = NSRect(
                x: x,
                y: chipVerticalInset,
                width: chipWidth,
                height: chipHeight
            )
            let chipPath = NSBezierPath(
                roundedRect: chipRect,
                xRadius: chipCornerRadius,
                yRadius: chipCornerRadius
            )

            // Paint the chip background once with the palette colour so the
            // header zone (which never has its own fill) gets the right colour
            // without a per-zone draw. Segment zones overpaint a rectangle on
            // top, clipped to the chip's rounded outline.
            NSGraphicsContext.current?.saveGraphicsState()
            chipPath.addClip()
            palette.pillColor.setFill()
            chipRect.fill()

            var zoneX: CGFloat = x
            for (zoneIndex, zone) in zones.enumerated() {
                let zoneWidth = zoneWidths[chipIndex][zoneIndex]
                let zoneRect = NSRect(
                    x: zoneX,
                    y: chipRect.minY,
                    width: zoneWidth,
                    height: chipRect.height
                )
                if !zone.isHeader {
                    zone.fillColor.setFill()
                    zoneRect.fill()
                }
                let textHeight = ceil(zone.textSize.height)
                let textY = zoneRect.minY + (zoneRect.height - textHeight) / 2
                let leftPad = zonePaddings[chipIndex][zoneIndex].left
                zone.attributed.draw(at: NSPoint(x: zoneX + leftPad, y: textY))
                zoneX += zoneWidth
            }

            NSGraphicsContext.current?.restoreGraphicsState()
            x += chipWidth
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func buildZonePlans(
        chip: RenderedChip,
        palette: ResolvedChipPalette,
        tierOverride: ConsumptionTier?
    ) -> [ZonePlan] {
        var plans: [ZonePlan] = []

        if let header = headerAttributedString(chip: chip, palette: palette) {
            plans.append(ZonePlan(
                attributed: header,
                textSize: header.size(),
                fillColor: palette.pillColor,
                isHeader: true
            ))
        }

        for segment in chip.segments {
            let effectiveTier: ConsumptionTier? = tierOverride ?? segment.tier
            let fillColor: NSColor = effectiveTier?.nsColor ?? palette.pillColor
            let textColor: NSColor = effectiveTier?.chipTextNSColor ?? palette.textColor
            let attributed = NSAttributedString(
                string: segment.text,
                attributes: [.font: font, .foregroundColor: textColor]
            )
            plans.append(ZonePlan(
                attributed: attributed,
                textSize: attributed.size(),
                fillColor: fillColor,
                // Pay-as-you-go / unknown segments share the chip palette but
                // still want their fill drawn explicitly: a header sitting to
                // their left would otherwise bleed the palette through and we
                // get a coherent rectangle by overpainting either way. The
                // overpaint is the same colour, so it's visually a no-op.
                isHeader: false
            ))
        }

        return plans
    }

    /// Builds the attributed string drawn inside the chip header zone (vendor
    /// icon + optional outage warning). Returns `nil` when the chip carries
    /// neither piece — there's no header to draw in that case.
    private static func headerAttributedString(
        chip: RenderedChip,
        palette: ResolvedChipPalette
    ) -> NSAttributedString? {
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
        }

        if let warning = chip.outageWarningText, !warning.isEmpty {
            if result.length > 0 {
                result.append(NSAttributedString(string: headerIconWarningGap, attributes: defaultAttrs))
            }
            result.append(NSAttributedString(string: warning, attributes: defaultAttrs))
        }

        return result.length > 0 ? result : nil
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
