import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("ClaudeUsageResponseParser — plan and limit resets")
struct ClaudePlanAndResetsTests {
    private let parser = ClaudeUsageResponseParser()

    @Test("cedar_ember grants map to reset credits with expiry")
    func grantsMapToResetCredits() throws {
        let snapshot = try parser.parse(FixtureLoader.load("claude-usage-with-resets"))
        let resets = try #require(snapshot.resetCredits)
        #expect(resets.available == 1)
        #expect(resets.applicable == 1)
        let grant = try #require(resets.grants.first)
        #expect(grant.kind == .full)
        #expect(grant.expiresAt == "2026-10-22T16:00:00Z")
        #expect(grant.label?.hasPrefix("Claude Opus 5.5 launch") == true)
        #expect(snapshot.responseTier == "claude_team")
    }

    @Test("paused grant is not usable; empty grants → no reset credits")
    func pausedAndEmptyGrants() throws {
        let paused = try parser.parse(Data("""
        {"five_hour":{"utilization":1},"cedar_ember":{"grants":[
          {"type":"five_hour","resets_left":2,"ends_at":"2026-11-01T00:00:00+00:00","usable_now":true,"paused":true}]}}
        """.utf8))
        #expect(paused.resetCredits?.available == 2)
        #expect(paused.resetCredits?.applicable == 0)
        #expect(paused.resetCredits?.grants.first?.kind == .session)

        let empty = try parser.parse(Data(#"{"five_hour":{"utilization":1},"cedar_ember":{"grants":[]}}"#.utf8))
        #expect(empty.resetCredits == nil)
        let absent = try parser.parse(Data(#"{"five_hour":{"utilization":1},"cedar_ember":null}"#.utf8))
        #expect(absent.resetCredits == nil)
    }

    @Test("invalid optional grant counts keep the usable grants and usage", arguments: ["1e100", "-1", "1.5"])
    func invalidGrantCounts(raw: String) throws {
        let snapshot = try parser.parse(Data("""
        {"five_hour":{"utilization":12},"cedar_ember":{"grants":[
          {"resets_left":\(raw),"usable_now":true},
          {"resets_left":1,"usable_now":true}]}}
        """.utf8))
        #expect(snapshot.sessionPercent == 12)
        #expect(snapshot.resetCredits?.available == 1)
        #expect(snapshot.resetCredits?.applicable == 1)
        #expect(snapshot.resetCredits?.grants.count == 1)
    }

    @Test("overflowing grant totals do not crash or discard usage")
    func overflowingGrantTotal() throws {
        let snapshot = try parser.parse(Data("""
        {"five_hour":{"utilization":12},"cedar_ember":{"grants":[
          {"resets_left":5e18,"usable_now":true},
          {"resets_left":5e18,"usable_now":true}]}}
        """.utf8))
        #expect(snapshot.sessionPercent == 12)
        #expect(snapshot.resetCredits == nil)
    }

    @Test("plan resolution: credentials first, Max multiplier and Team tier from rateLimitTier")
    func planResolution() {
        typealias P = ClaudeUsageResponseParser
        #expect(P.plan(subscriptionType: "max", rateLimitTier: "default_claude_max_20x", responseTier: nil) == "max_20x")
        #expect(P.plan(subscriptionType: "max", rateLimitTier: "default_claude_max_5x", responseTier: nil) == "max_5x")
        #expect(P.plan(subscriptionType: "max", rateLimitTier: nil, responseTier: nil) == "max")
        #expect(P.plan(subscriptionType: "team", rateLimitTier: "default_claude_team_premium", responseTier: nil) == "team_premium")
        #expect(P.plan(subscriptionType: "team", rateLimitTier: "default_claude_max_5x", responseTier: nil) == "team_premium")
        #expect(P.plan(subscriptionType: "team", rateLimitTier: "default_claude_team", responseTier: nil) == "team_standard")
        #expect(P.plan(subscriptionType: "team", rateLimitTier: "default_raven", responseTier: nil) == "team_standard")
        #expect(P.plan(subscriptionType: "team", rateLimitTier: nil, responseTier: nil) == "team")
        #expect(P.plan(subscriptionType: "pro", rateLimitTier: nil, responseTier: "claude_team") == "pro")
        #expect(P.plan(subscriptionType: nil, rateLimitTier: nil, responseTier: "claude_enterprise") == "enterprise")
        #expect(P.plan(subscriptionType: nil, rateLimitTier: "default_claude_max_5x", responseTier: nil) == "max_5x")
        #expect(P.plan(subscriptionType: "  ", rateLimitTier: nil, responseTier: nil) == nil)
    }

    @Test("accountStatus is nil when neither plan nor resets are known")
    func accountStatusNilWhenNothingKnown() throws {
        let snapshot = try parser.parse(Data(#"{"five_hour":{"utilization":1}}"#.utf8))
        #expect(parser.accountStatus(from: snapshot, subscriptionType: nil, rateLimitTier: nil) == nil)
        #expect(parser.accountStatus(from: snapshot, subscriptionType: "pro", rateLimitTier: nil)?.plan == "pro")
    }

    @Test("usage URL carries the resets flag")
    func usageURL() {
        #expect(ClaudeUsageResponseParser.usageURL.absoluteString == "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")
    }
}

@Suite("ResetCredits")
struct ResetCreditsTests {
    @Test("nextExpiry picks the earliest grant with resets left")
    func nextExpiry() {
        let credits = ResetCredits(available: 2, applicable: 1, grants: [
            ResetGrant(kind: .full, label: nil, remaining: 1, expiresAt: "2026-11-01T00:00:00Z", usableNow: true),
            ResetGrant(kind: .session, label: nil, remaining: 0, expiresAt: "2026-10-01T00:00:00Z", usableNow: true),
            ResetGrant(kind: .session, label: nil, remaining: 1, expiresAt: "2026-10-20T00:00:00Z", usableNow: false),
            ResetGrant(kind: .full, label: nil, remaining: 1, expiresAt: nil, usableNow: true),
        ])
        #expect(credits.nextExpiry == "2026-10-20T00:00:00Z")
    }

    @Test("legacy payload without grants still decodes")
    func legacyDecode() throws {
        let decoded = try JSONDecoder().decode(ResetCredits.self, from: Data(#"{"available":3,"applicable":0}"#.utf8))
        #expect(decoded == ResetCredits(available: 3, applicable: 0))
    }
}
