import Foundation
import Testing
@testable import AIUsagesTrackersLib

@MainActor
@Suite("MenuBarRefreshController — dedup")
struct MenuBarRefreshControllerTests {
    private func makeKey(
        text: String = "x",
        separator: String = " | ",
        isDark: Bool = true,
        isUnconfigured: Bool = false,
        segments: [MenuBarSegment] = [
            MenuBarSegment(text: "Claude", tier: nil, showDot: true, vendorIcon: nil)
        ]
    ) -> MenuBarRenderKey {
        MenuBarRenderKey(
            segments: segments,
            text: text,
            separator: separator,
            isDark: isDark,
            isUnconfigured: isUnconfigured
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
            mutated: MenuBarRenderKey(segments: k.segments, text: "after", separator: k.separator, isDark: k.isDark, isUnconfigured: k.isUnconfigured)
        )
    }

    @Test("Changing separator invalidates dedup")
    func separatorChangeInvalidates() {
        let k = makeKey(separator: " | ")
        assertFieldInvalidatesDedup(
            field: "separator",
            original: k,
            mutated: MenuBarRenderKey(segments: k.segments, text: k.text, separator: " · ", isDark: k.isDark, isUnconfigured: k.isUnconfigured)
        )
    }

    @Test("Flipping isDark invalidates dedup")
    func isDarkChangeInvalidates() {
        let k = makeKey(isDark: true)
        assertFieldInvalidatesDedup(
            field: "isDark",
            original: k,
            mutated: MenuBarRenderKey(segments: k.segments, text: k.text, separator: k.separator, isDark: false, isUnconfigured: k.isUnconfigured)
        )
    }

    @Test("Flipping isUnconfigured invalidates dedup")
    func isUnconfiguredChangeInvalidates() {
        let k = makeKey(isUnconfigured: false)
        assertFieldInvalidatesDedup(
            field: "isUnconfigured",
            original: k,
            mutated: MenuBarRenderKey(segments: k.segments, text: k.text, separator: k.separator, isDark: k.isDark, isUnconfigured: true)
        )
    }

    @Test("Changing segments invalidates dedup")
    func segmentsChangeInvalidates() {
        let k = makeKey()
        let other = [MenuBarSegment(text: "Codex", tier: nil, showDot: false, vendorIcon: nil)]
        assertFieldInvalidatesDedup(
            field: "segments",
            original: k,
            mutated: MenuBarRenderKey(segments: other, text: k.text, separator: k.separator, isDark: k.isDark, isUnconfigured: k.isUnconfigured)
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
