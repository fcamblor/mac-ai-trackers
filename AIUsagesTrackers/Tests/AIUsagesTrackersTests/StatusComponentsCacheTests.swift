import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("StatusComponentsFileManager")
struct StatusComponentsFileManagerTests {
    private func makeTempPath() -> String {
        NSTemporaryDirectory() + "ai-tracker-status-cache-\(UUID().uuidString).json"
    }

    @Test("read on a missing file returns an empty cache")
    func readMissing() async {
        let manager = StatusComponentsFileManager(filePath: makeTempPath())
        let cache = await manager.read()
        #expect(cache.entries.isEmpty)
    }

    @Test("upsert then read returns the same entry")
    func upsertRoundTrip() async {
        let manager = StatusComponentsFileManager(filePath: makeTempPath())
        let entry = StatusComponentsCacheEntry(
            platform: .incidentIO,
            host: "status.openai.com",
            groupRootID: "01KMKF9EBTCD8BN9PG8DJZXRSQ",
            lastRefreshedAt: ISODate(rawValue: "2026-05-13T00:00:00Z"),
            components: [
                StatusComponent(
                    id: "01JVCV8YSWZFRSM1G5CVP253SK",
                    name: "Codex Web",
                    groupID: "01KMKF9EBTCD8BN9PG8DJZXRSQ"
                )
            ]
        )
        await manager.upsert(entry)
        let cache = await manager.read()
        #expect(cache.entries.count == 1)
        #expect(cache.entries[0].components.first?.name == "Codex Web")
    }

    @Test("upsert with the same key replaces the previous entry")
    func upsertReplaces() async {
        let manager = StatusComponentsFileManager(filePath: makeTempPath())
        let first = StatusComponentsCacheEntry(
            platform: .incidentIO,
            host: "status.openai.com",
            groupRootID: "01ROOT0000000000000000ABCD",
            lastRefreshedAt: ISODate(rawValue: "2026-05-12T00:00:00Z"),
            components: []
        )
        let second = StatusComponentsCacheEntry(
            platform: .incidentIO,
            host: "status.openai.com",
            groupRootID: "01ROOT0000000000000000ABCD",
            lastRefreshedAt: ISODate(rawValue: "2026-05-13T00:00:00Z"),
            components: [
                StatusComponent(
                    id: "01CHILD000000000000000001",
                    name: "Codex Web",
                    groupID: "01ROOT0000000000000000ABCD"
                )
            ]
        )
        await manager.upsert(first)
        await manager.upsert(second)
        let cache = await manager.read()
        #expect(cache.entries.count == 1)
        #expect(cache.entries[0].lastRefreshedAt.rawValue == "2026-05-13T00:00:00Z")
        #expect(cache.entries[0].components.count == 1)
    }

    @Test("entries with different keys coexist")
    func differentKeysCoexist() async {
        let manager = StatusComponentsFileManager(filePath: makeTempPath())
        let openai = StatusComponentsCacheEntry(
            platform: .incidentIO,
            host: "status.openai.com",
            groupRootID: "01ROOTOPENAI00000000000000",
            lastRefreshedAt: ISODate(rawValue: "2026-05-13T00:00:00Z"),
            components: []
        )
        let other = StatusComponentsCacheEntry(
            platform: .incidentIO,
            host: "status.example.com",
            groupRootID: "01ROOTOTHER000000000000000",
            lastRefreshedAt: ISODate(rawValue: "2026-05-13T00:00:00Z"),
            components: []
        )
        await manager.upsert(openai)
        await manager.upsert(other)
        let cache = await manager.read()
        #expect(cache.entries.count == 2)
    }
}
