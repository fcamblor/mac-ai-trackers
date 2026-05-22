import AppKit
import Testing
@testable import AIUsagesTrackers
@testable import AIUsagesTrackersLib

@Suite("MenuBarLabelRenderer")
@MainActor
struct MenuBarLabelRendererTests {
    private func bitmapData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }

    @Test("segment.colorizeText paints tier-coloured text — bitmap differs from plain render")
    func colorizeChangesBitmapWhenTierPresent() {
        let plain = MenuBarLabelRenderer.render(
            segments: [MenuBarSegment(text: "42%", tier: .comfortable, showDot: true, colorizeText: false)],
            separator: " | ",
            fallbackText: "--",
            isDarkMenuBar: true
        )
        let colorized = MenuBarLabelRenderer.render(
            segments: [MenuBarSegment(text: "42%", tier: .comfortable, showDot: true, colorizeText: true)],
            separator: " | ",
            fallbackText: "--",
            isDarkMenuBar: true
        )
        // Sizes should match (we did not change the layout), but the pixels
        // must differ — green-on-dark plus an outline cannot equal white-on-dark.
        #expect(plain.size == colorized.size)
        #expect(bitmapData(plain) != bitmapData(colorized))
    }

    @Test("colorize without dot still tints the text — Dot and Color are independent")
    func colorizeWithoutDotStillTintsText() {
        let plain = MenuBarLabelRenderer.render(
            segments: [MenuBarSegment(text: "42%", tier: .comfortable, showDot: false, colorizeText: false)],
            separator: " | ",
            fallbackText: "--",
            isDarkMenuBar: true
        )
        let colorized = MenuBarLabelRenderer.render(
            segments: [MenuBarSegment(text: "42%", tier: .comfortable, showDot: false, colorizeText: true)],
            separator: " | ",
            fallbackText: "--",
            isDarkMenuBar: true
        )
        // Tier is preserved when the dot is off, so flipping colorizeText
        // must visibly recolour the text — same contract as with the dot on.
        #expect(bitmapData(plain) != bitmapData(colorized))
    }

    @Test("segment.colorizeText has no visible effect when tier is nil")
    func colorizeNoOpWhenTierMissing() {
        let plain = MenuBarLabelRenderer.render(
            segments: [MenuBarSegment(text: "$12.34", tier: nil, showDot: false, colorizeText: false)],
            separator: " | ",
            fallbackText: "--",
            isDarkMenuBar: true
        )
        let colorized = MenuBarLabelRenderer.render(
            segments: [MenuBarSegment(text: "$12.34", tier: nil, showDot: false, colorizeText: true)],
            separator: " | ",
            fallbackText: "--",
            isDarkMenuBar: true
        )
        #expect(bitmapData(plain) == bitmapData(colorized))
    }

    @Test("segment outage warning widens the rendered label")
    func outageWarningWidensSegment() {
        let base = MenuBarLabelRenderer.render(
            segments: [MenuBarSegment(text: "100%", tier: nil, showDot: false)],
            separator: " | ",
            fallbackText: "--",
            isDarkMenuBar: false
        )
        let warned = MenuBarLabelRenderer.render(
            segments: [MenuBarSegment(
                text: "100%",
                tier: nil,
                showDot: false,
                outageWarningText: "⚠️"
            )],
            separator: " | ",
            fallbackText: "--",
            isDarkMenuBar: false
        )

        #expect(warned.size.width > base.size.width)
    }
}
