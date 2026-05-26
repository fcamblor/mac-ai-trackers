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
        showVendorIcon: Bool = false,
        outageWarningText: String? = nil
    ) -> RenderedChip {
        RenderedChip(
            vendor: .claude,
            showVendorIcon: showVendorIcon,
            outageWarningText: outageWarningText,
            segments: [segment]
        )
    }

    @Test("segment tier drives the pill bitmap — different tiers → different bitmaps")
    func tierChangesBitmap() {
        let comfortable = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: MenuBarSegment(text: "42%", tier: .comfortable))],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: true
        )
        let critical = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: MenuBarSegment(text: "42%", tier: .critical))],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: true
        )
        #expect(bitmapData(comfortable) != bitmapData(critical))
    }

    @Test("chip outage warning widens the rendered label")
    func outageWarningWidensChip() {
        let base = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: MenuBarSegment(text: "100%", tier: nil))],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: false
        )
        let warned = MenuBarLabelRenderer.render(
            chips: [makeChip(
                segment: MenuBarSegment(text: "100%", tier: nil),
                outageWarningText: "⚠️"
            )],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: false
        )

        #expect(warned.size.width > base.size.width)
    }

    @Test("paper and slate backgrounds change the header zone bitmap when a warning is shown")
    func backgroundChangesHeaderBitmap() {
        let segment = MenuBarSegment(text: "42%", tier: .comfortable)
        let paper = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: segment, outageWarningText: "⚠️")],
            background: .paper,
            fallbackText: "--",
            isDarkMenuBar: false
        )
        let slate = MenuBarLabelRenderer.render(
            chips: [makeChip(segment: segment, outageWarningText: "⚠️")],
            background: .slate,
            fallbackText: "--",
            isDarkMenuBar: false
        )
        #expect(bitmapData(paper) != bitmapData(slate))
    }

    @Test("tierOverride forces the segment pill colour regardless of the segment tier")
    func tierOverrideOverridesSegmentTier() {
        let segment = MenuBarSegment(text: "42%", tier: .comfortable)
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
