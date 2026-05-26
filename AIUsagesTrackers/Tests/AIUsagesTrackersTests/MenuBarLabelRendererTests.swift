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

    private func makeChip(
        segment: MenuBarSegment,
        outageWarningText: String? = nil
    ) -> RenderedChip {
        RenderedChip(
            vendor: .claude,
            showVendorIcon: false,
            outageWarningText: outageWarningText,
            segments: [segment]
        )
    }

    @Test("segment.colorizeText paints tier-coloured text — bitmap differs from plain render")
    func colorizeChangesBitmapWhenTierPresent() {
        let plain = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: MenuBarSegment(text: "42%", tier: .comfortable, showDot: true, colorizeText: false))],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: true
        )
        let colorized = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: MenuBarSegment(text: "42%", tier: .comfortable, showDot: true, colorizeText: true))],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: true
        )
        #expect(plain.size == colorized.size)
        #expect(bitmapData(plain) != bitmapData(colorized))
    }

    @Test("colorize without dot still tints the text — Dot and Color are independent")
    func colorizeWithoutDotStillTintsText() {
        let plain = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: MenuBarSegment(text: "42%", tier: .comfortable, showDot: false, colorizeText: false))],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: true
        )
        let colorized = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: MenuBarSegment(text: "42%", tier: .comfortable, showDot: false, colorizeText: true))],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: true
        )
        #expect(bitmapData(plain) != bitmapData(colorized))
    }

    @Test("segment.colorizeText has no visible effect when tier is nil")
    func colorizeNoOpWhenTierMissing() {
        let plain = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: MenuBarSegment(text: "$12.34", tier: nil, showDot: false, colorizeText: false))],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: true
        )
        let colorized = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: MenuBarSegment(text: "$12.34", tier: nil, showDot: false, colorizeText: true))],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: true
        )
        #expect(bitmapData(plain) == bitmapData(colorized))
    }

    @Test("chip outage warning widens the rendered label")
    func outageWarningWidensChip() {
        let base = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: MenuBarSegment(text: "100%", tier: nil, showDot: false))],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: false
        )
        let warned = MenuBarLabelRenderer.render(
            chips: [makeChip(
                segment: MenuBarSegment(text: "100%", tier: nil, showDot: false),
                outageWarningText: "⚠️"
            )],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: false
        )

        #expect(warned.size.width > base.size.width)
    }

    @Test("paper and slate backgrounds produce different bitmaps for the same chip")
    func backgroundChangesBitmap() {
        let segment = MenuBarSegment(text: "42%", tier: .comfortable, showDot: true)
        let paper = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: segment)],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: false
        )
        let slate = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: segment)],
            background: .slate,
            fallbackText: "--",
            isDarkMenuBar: false
        )
        #expect(bitmapData(paper) != bitmapData(slate))
    }

    @Test("tierOverride forces the dot colour regardless of segment tier")
    func tierOverrideOverridesSegmentTier() {
        let segment = MenuBarSegment(text: "42%", tier: .comfortable, showDot: true, colorizeText: true)
        let withoutOverride = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: segment)],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: false,
            tierOverride: nil
        )
        let withOverride = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: segment)],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: false,
            tierOverride: .critical
        )
        #expect(bitmapData(withoutOverride) != bitmapData(withOverride))
    }

    @Test("unconfigured state renders without a pill")
    func unconfiguredRenders() {
        let image = MenuBarLabelRenderer.render(
            chips: [],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: false,
            isUnconfigured: true
        )
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }
}
