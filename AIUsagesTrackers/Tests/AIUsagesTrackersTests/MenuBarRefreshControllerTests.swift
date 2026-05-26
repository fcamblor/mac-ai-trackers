import Foundation
import Testing
@testable import AIUsagesTrackersLib

@MainActor
@Suite("MenuBarRefreshController — dedup")
struct MenuBarRefreshControllerTests {
    private func makeChip(
        vendor: Vendor = .claude,
        segmentText: String = "Claude",
        tier: ConsumptionTier? = nil
    ) -> RenderedChip {
        RenderedChip(
            vendor: vendor,
            showVendorIcon: false,
            outageWarningText: nil,
            segments: [MenuBarSegment(text: segmentText, tier: tier)]
        )
    }

    private func makeKey(
        text: String = "x",
        background: ChipBackground = .paper,
        isDark: Bool = true,
        isUnconfigured: Bool = false,
        tierOverride: ConsumptionTier? = nil,
        chips: [RenderedChip]? = nil
    ) -> MenuBarRenderKey {
        MenuBarRenderKey(
            chips: chips ?? [makeChip()],
            text: text,
            background: background,
            isDark: isDark,
            isUnconfigured: isUnconfigured,
            tierOverride: tierOverride
        )
    }

    @Test("First refresh always runs onRender exactly once")
    func firstRefreshAlwaysFires() {
        var calls: [MenuBarRenderKey] = []
        let sut = MenuBarRefreshController { calls.append($0) }
        let key = makeKey()

        sut.refresh(key: key)

        #expect(calls == [key])
        #expect(sut.renderCount == 1)
    }

    @Test("1000 identical refreshes only render once — the dedup that broke the feedback loop")
    func identicalRefreshesAreDeduped() {
        var calls = 0
        let sut = MenuBarRefreshController { _ in calls += 1 }
        let key = makeKey()

        for _ in 0..<1000 {
            sut.refresh(key: key)
        }

        #expect(calls == 1)
        #expect(sut.renderCount == 1)
    }

    private func assertFieldInvalidatesDedup(
        field: String,
        original: MenuBarRenderKey,
        mutated: MenuBarRenderKey
    ) {
        var calls = 0
        let sut = MenuBarRefreshController { _ in calls += 1 }
        sut.refresh(key: original)
        sut.refresh(key: mutated)
        sut.refresh(key: mutated)
        #expect(calls == 2, "field=\(field) — expected exactly 2 renders, got \(calls)")
    }

    @Test("Changing text invalidates dedup")
    func textChangeInvalidates() {
        let k = makeKey(text: "before")
        assertFieldInvalidatesDedup(
            field: "text",
            original: k,
            mutated: MenuBarRenderKey(
                chips: k.chips, text: "after", background: k.background,
                isDark: k.isDark, isUnconfigured: k.isUnconfigured, tierOverride: k.tierOverride
            )
        )
    }

    @Test("Changing background invalidates dedup")
    func backgroundChangeInvalidates() {
        let k = makeKey(background: .paper)
        assertFieldInvalidatesDedup(
            field: "background",
            original: k,
            mutated: MenuBarRenderKey(
                chips: k.chips, text: k.text, background: .slate,
                isDark: k.isDark, isUnconfigured: k.isUnconfigured, tierOverride: k.tierOverride
            )
        )
    }

    @Test("Flipping isDark invalidates dedup")
    func isDarkChangeInvalidates() {
        let k = makeKey(isDark: true)
        assertFieldInvalidatesDedup(
            field: "isDark",
            original: k,
            mutated: MenuBarRenderKey(
                chips: k.chips, text: k.text, background: k.background,
                isDark: false, isUnconfigured: k.isUnconfigured, tierOverride: k.tierOverride
            )
        )
    }

    @Test("Flipping isUnconfigured invalidates dedup")
    func isUnconfiguredChangeInvalidates() {
        let k = makeKey(isUnconfigured: false)
        assertFieldInvalidatesDedup(
            field: "isUnconfigured",
            original: k,
            mutated: MenuBarRenderKey(
                chips: k.chips, text: k.text, background: k.background,
                isDark: k.isDark, isUnconfigured: true, tierOverride: k.tierOverride
            )
        )
    }

    @Test("Changing chips invalidates dedup")
    func chipsChangeInvalidates() {
        let k = makeKey()
        let other = [makeChip(segmentText: "Codex")]
        assertFieldInvalidatesDedup(
            field: "chips",
            original: k,
            mutated: MenuBarRenderKey(
                chips: other, text: k.text, background: k.background,
                isDark: k.isDark, isUnconfigured: k.isUnconfigured, tierOverride: k.tierOverride
            )
        )
    }

    @Test("Changing a segment tier invalidates dedup — drives the pill background")
    func tierChangeInvalidates() {
        let plain = [makeChip(segmentText: "S", tier: .comfortable)]
        let critical = [makeChip(segmentText: "S", tier: .critical)]
        let k = makeKey(chips: plain)
        assertFieldInvalidatesDedup(
            field: "tier",
            original: k,
            mutated: MenuBarRenderKey(
                chips: critical, text: k.text, background: k.background,
                isDark: k.isDark, isUnconfigured: k.isUnconfigured, tierOverride: k.tierOverride
            )
        )
    }

    @Test("Changing tierOverride invalidates dedup — pacing color cycle")
    func tierOverrideChangeInvalidates() {
        let k = makeKey(tierOverride: nil)
        assertFieldInvalidatesDedup(
            field: "tierOverride",
            original: k,
            mutated: MenuBarRenderKey(
                chips: k.chips, text: k.text, background: k.background,
                isDark: k.isDark, isUnconfigured: k.isUnconfigured, tierOverride: .critical
            )
        )
    }

    @Test("Appearance KVO filter ignores fires that don't move dark/aqua")
    func appearanceFilterIgnoresUnchangedFlag() {
        let sut = MenuBarRefreshController { _ in }
        sut.refresh(key: makeKey(isDark: true))

        // 100 KVO fires reporting the same isDark = true — none should warrant a refresh.
        for _ in 0..<100 {
            #expect(sut.shouldHandleAppearanceChange(isDark: true) == false)
        }
    }

    @Test("Appearance KVO filter authorises refresh on actual dark/aqua flip")
    func appearanceFilterAuthorisesOnFlip() {
        let sut = MenuBarRefreshController { _ in }
        sut.refresh(key: makeKey(isDark: true))

        #expect(sut.shouldHandleAppearanceChange(isDark: false) == true)
        // After a flip is consumed, further fires at the same value are filtered again.
        #expect(sut.shouldHandleAppearanceChange(isDark: false) == false)
        #expect(sut.shouldHandleAppearanceChange(isDark: true) == true)
    }
}
