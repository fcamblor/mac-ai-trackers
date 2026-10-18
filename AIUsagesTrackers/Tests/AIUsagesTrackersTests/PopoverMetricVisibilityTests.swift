import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("PopoverMetricVisibility")
struct PopoverMetricVisibilityTests {
    @Test("hide/unhide per family; Claude TUI and Desktop share the family")
    func toggling() {
        var visibility = PopoverMetricVisibility()
        visibility.setHidden(true, rowName: "Weekly share · Chats", family: Vendor.claudeTUI.accountFamily)
        #expect(visibility.isHidden("Weekly share · Chats", vendor: .claudeDesktop))
        #expect(!visibility.isHidden("Weekly share · Chats", vendor: .codex))
        visibility.setHidden(false, rowName: "Weekly share · Chats", family: Vendor.claudeTUI.accountFamily)
        #expect(visibility.hiddenByFamily.isEmpty)
    }

    @Test("round-trips through JSON with stable ordering")
    func codable() throws {
        let visibility = PopoverMetricVisibility(hiddenByFamily: ["codex": ["b", "a"]])
        let data = try JSONEncoder().encode(visibility)
        #expect(String(data: data, encoding: .utf8)?.contains(#"["a","b"]"#) == true)
        #expect(try JSONDecoder().decode(PopoverMetricVisibility.self, from: data) == visibility)
    }

    @Test("catalog lists displayed rows per family, plus already-hidden rows")
    func catalog() {
        let codex = VendorUsageEntry(
            vendor: .codex, account: "a@b.com",
            metrics: [.payAsYouGo(name: "Credits balance", currentAmount: 1, currency: "credits")],
            accountStatus: AccountStatus(credits: CreditsSummary(
                unlimited: true, overageLimitReached: false, approxLocalMessages: nil, approxCloudMessages: nil
            ))
        )
        let claude = VendorUsageEntry(
            vendor: .claudeDesktop, account: "a@b.com",
            metrics: [.timeWindow(name: "Weekly (all models)", resetAt: nil, windowDuration: 10080, usagePercent: 1)]
        )
        let visibility = PopoverMetricVisibility(hiddenByFamily: ["claude": ["Weekly share · Cowork"]])
        let catalog = PopoverRowCatalog.build(entries: [codex, claude], visibility: visibility)

        #expect(catalog.map(\.family) == ["codex", "claude"])
        #expect(catalog[0].rowNames == ["Credits balance", PopoverStatusRow.messagesLeft])
        #expect(catalog[1].rowNames == ["Weekly (all models)", "Weekly share · Cowork"])
        #expect(catalog[1].representativeVendor == .claudeTUI)
    }
}
