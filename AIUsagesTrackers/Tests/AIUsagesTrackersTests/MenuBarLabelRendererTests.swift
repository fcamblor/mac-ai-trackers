import Testing
@testable import AIUsagesTrackers

@Suite("MenuBarLabelRenderer")
@MainActor
struct MenuBarLabelRendererTests {
    @Test("outage warning prefixes the unconfigured menu bar label")
    func outageWarningPrefixesUnconfiguredLabel() {
        let base = MenuBarLabelRenderer.render(
            segments: [],
            separator: " | ",
            fallbackText: "--",
            isDarkMenuBar: false,
            isUnconfigured: true
        )
        let prefixed = MenuBarLabelRenderer.render(
            segments: [],
            separator: " | ",
            fallbackText: "--",
            isDarkMenuBar: false,
            isUnconfigured: true,
            outageWarningPrefix: "WARN"
        )

        #expect(prefixed.size.width > base.size.width)
    }
}
