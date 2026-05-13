import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("StatusSubscriptionResolver")
@MainActor
struct StatusSubscriptionResolverTests {
    private let groupRoot: StatusComponentID = "01KMKF9EBTCD8BN9PG8DJZXRSQ"
    private let webID: StatusComponentID = "01JVCV8YSWZFRSM1G5CVP253SK"
    private let apiID: StatusComponentID = "01KMP3KP5MGE23B80K1EK4S8PV"

    private func makeRegistry(
        cachePath: String,
        components: [StatusComponent]
    ) async -> StatusComponentRegistry {
        let cache = StatusComponentsFileManager(filePath: cachePath)
        let entry = StatusComponentsCacheEntry(
            platform: .incidentIO,
            host: "status.openai.com",
            groupRootID: groupRoot,
            lastRefreshedAt: ISODate(rawValue: "2026-05-13T00:00:00Z"),
            components: components
        )
        await cache.upsert(entry)
        // Discovery never invoked in these tests — pass a stub that explodes
        // to make accidental refreshes obvious.
        return StatusComponentRegistry(
            platform: .incidentIO,
            host: "status.openai.com",
            groupRootID: groupRoot,
            discovery: ExplodingDiscovery(),
            cache: cache
        )
    }

    private func tempCachePath() -> String {
        NSTemporaryDirectory() + "ai-tracker-resolver-\(UUID().uuidString).json"
    }

    @Test("empty set (not nil) when registry has no cached entry yet — drops all incidents")
    func emptyWhenCacheEmpty() async {
        let cache = StatusComponentsFileManager(filePath: tempCachePath())
        let registry = StatusComponentRegistry(
            platform: .incidentIO,
            host: "status.openai.com",
            groupRootID: groupRoot,
            discovery: ExplodingDiscovery(),
            cache: cache
        )
        let prefs = InMemoryAppPreferences()
        let resolver = StatusSubscriptionResolver.makeResolver(
            registry: registry, preferences: prefs
        )
        let result = await resolver()
        #expect(result == Set<StatusComponentID>())
    }

    @Test("default ON: every cached component is in the subscribed set when no overrides")
    func defaultOnForAllComponents() async {
        let registry = await makeRegistry(
            cachePath: tempCachePath(),
            components: [
                StatusComponent(id: webID, name: "Codex Web", groupID: groupRoot),
                StatusComponent(id: apiID, name: "Codex API", groupID: groupRoot)
            ]
        )
        let prefs = InMemoryAppPreferences()
        let resolver = StatusSubscriptionResolver.makeResolver(
            registry: registry, preferences: prefs
        )
        let result = await resolver()
        #expect(result == Set([webID, apiID]))
    }

    @Test("explicit false removes the component from the subscribed set")
    func explicitFalseExcludes() async {
        let registry = await makeRegistry(
            cachePath: tempCachePath(),
            components: [
                StatusComponent(id: webID, name: "Codex Web", groupID: groupRoot),
                StatusComponent(id: apiID, name: "Codex API", groupID: groupRoot)
            ]
        )
        let prefs = InMemoryAppPreferences(
            statusComponentSubscriptions: [webID.rawValue: false]
        )
        let resolver = StatusSubscriptionResolver.makeResolver(
            registry: registry, preferences: prefs
        )
        let result = await resolver()
        #expect(result == Set([apiID]))
    }

    @Test("newly discovered component (no preference entry) defaults to subscribed")
    func newlyDiscoveredDefaultsOn() async {
        let registry = await makeRegistry(
            cachePath: tempCachePath(),
            components: [
                StatusComponent(id: webID, name: "Codex Web", groupID: groupRoot),
                StatusComponent(id: apiID, name: "Codex API", groupID: groupRoot)
            ]
        )
        // Preferences only know about Codex Web; the newly cached Codex API
        // must still be subscribed by default.
        let prefs = InMemoryAppPreferences(
            statusComponentSubscriptions: [:]
        )
        let resolver = StatusSubscriptionResolver.makeResolver(
            registry: registry, preferences: prefs
        )
        let result = await resolver()
        #expect(result?.contains(apiID) == true)
    }
}

private struct ExplodingDiscovery: IncidentIOComponentsDiscovery {
    func discover(host: String, groupRootID: StatusComponentID) async throws -> [StatusComponent] {
        Issue.record("discovery was not expected to run in this test")
        return []
    }
}
