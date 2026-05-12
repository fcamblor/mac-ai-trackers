import Testing
@testable import AIUsagesTrackers
@testable import AIUsagesTrackersLib

@Suite("MenuBarLabelRenderer")
@MainActor
struct MenuBarLabelRendererTests {
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
