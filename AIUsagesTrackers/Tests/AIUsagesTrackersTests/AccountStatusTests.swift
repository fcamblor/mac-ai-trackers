import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("AccountStatus")
struct AccountStatusTests {
    @Test("round-trips every field through JSON")
    func roundTrip() throws {
        let status = AccountStatus(
            plan: "prolite",
            block: AccountBlock(reason: .rateLimit, resumesAt: "2026-10-03T18:07:04Z"),
            unavailableModels: [ModelAvailability(model: "gpt-6-astra", availableAt: "2026-10-03T18:07:04Z", creditsWouldEnable: true)],
            resetCredits: ResetCredits(available: 3, applicable: 1),
            credits: CreditsSummary(
                unlimited: false,
                overageLimitReached: true,
                approxLocalMessages: MessageRange(lower: 65, upper: 339),
                approxCloudMessages: nil
            )
        )
        let data = try JSONEncoder().encode(status)
        #expect(try JSONDecoder().decode(AccountStatus.self, from: data) == status)
    }

    @Test("decodes an empty object with defaults and omits empty model list on encode")
    func emptyObject() throws {
        let decoded = try JSONDecoder().decode(AccountStatus.self, from: Data("{}".utf8))
        #expect(decoded == AccountStatus())
        let encoded = try #require(String(data: JSONEncoder().encode(decoded), encoding: .utf8))
        #expect(!encoded.contains("unavailableModels"))
    }

    @Test("entry without accountStatus key still decodes (legacy usages.json)")
    func legacyEntryDecodes() throws {
        let json = #"{"vendor":"codex","account":"a@b.com","isActive":true,"metrics":[]}"#
        let entry = try JSONDecoder().decode(VendorUsageEntry.self, from: Data(json.utf8))
        #expect(entry.accountStatus == nil)
    }

    @Test("unknown block reason decodes without throwing")
    func unknownBlockReason() throws {
        let json = #"{"reason":"future_reason"}"#
        let block = try JSONDecoder().decode(AccountBlock.self, from: Data(json.utf8))
        #expect(block.reason == BlockReason(rawValue: "future_reason"))
        #expect(block.resumesAt == nil)
    }

    @Test("PlanType display names: known slugs mapped, unknown capitalised")
    func planDisplayNames() {
        #expect(PlanType(rawValue: "prolite").displayName == "Pro Lite")
        #expect(PlanType(rawValue: "PLUS").displayName == "Plus")
        #expect(PlanType(rawValue: "ultra").displayName == "Ultra")
    }

    @Test("MessageRange normalises inverted bounds")
    func messageRangeOrdering() {
        let range = MessageRange(lower: 10, upper: 2)
        #expect(range.lower == 2 && range.upper == 10)
        #expect(MessageRange(lower: 0, upper: 0).isZero)
    }

    @Test("formatResumeTime: same day → HH:mm, other day → date + time, unparseable → --")
    func resumeTimeFormatting() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-04-17T12:00:00Z"))
        let sameDay = ISODate(date: now.addingTimeInterval(60))
        #expect(formatResumeTime(sameDay, now: now).count == 5)
        let later = ISODate(date: now.addingTimeInterval(3 * 86_400))
        #expect(formatResumeTime(later, now: now).count > 5)
        #expect(formatResumeTime("garbage", now: now) == "--")
    }
}
