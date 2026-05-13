import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("IncidentIOComponentsDiscovery — RSC parser")
struct IncidentIOComponentsDiscoveryTests {
    private let codexGroupRootID: StatusComponentID = "01KMKF9EBTCD8BN9PG8DJZXRSQ"

    /// Mirrors the on-page shape: child components live inside the group's
    /// `components` array and only carry `component_id` + `name` (no
    /// per-component `group_id`). The enclosing group object exposes the
    /// `id` / `name` we anchor on.
    private func makeCodexGroupJSON(extraSiblingGroups: String = "") -> String {
        """
        {
          "groups": [
            {
              "components": [
                {"component_id":"01JVCV8YSWZFRSM1G5CVP253SK","name":"Codex Web","hidden":false},
                {"component_id":"01KMKFAMWKQ81YWSE1Z18R6VHR","name":"App","hidden":false},
                {"component_id":"01KMP3KP5MGE23B80K1EK4S8PV","name":"Codex API","hidden":false}
              ],
              "description":"$undefined",
              "hidden":false,
              "id":"01KMKF9EBTCD8BN9PG8DJZXRSQ",
              "name":"Codex"
            }\(extraSiblingGroups)
          ]
        }
        """
    }

    @Test("extracts every Codex child from the group's components array")
    func extractsCodexChildren() {
        let payload = makeCodexGroupJSON()
        let components = IncidentIOPageComponentsDiscovery.extractComponents(
            fromUnescapedPayload: payload,
            groupRootID: codexGroupRootID
        )
        #expect(components.count == 3)
        #expect(components.contains { $0.name == "Codex Web" })
        #expect(components.contains { $0.name == "App" })
        #expect(components.contains { $0.name == "Codex API" })
        #expect(components.allSatisfy { $0.groupID == codexGroupRootID })
    }

    @Test("ignores components in sibling groups whose id differs")
    func ignoresOtherGroups() {
        let unrelatedGroup = """
        ,
        {
          "components": [
            {"component_id":"01KRG0AZKH41DV4D9SNJSXM33Q","name":"Audio","hidden":false}
          ],
          "id":"01ZZZZZZZZZZZZZZZZZZZZZZZZ",
          "name":"APIs"
        }
        """
        let payload = makeCodexGroupJSON(extraSiblingGroups: unrelatedGroup)
        let components = IncidentIOPageComponentsDiscovery.extractComponents(
            fromUnescapedPayload: payload,
            groupRootID: codexGroupRootID
        )
        #expect(components.count == 3)
        #expect(!components.contains { $0.name == "Audio" })
    }

    @Test("unescapes \\\" inside an HTML script-tag style payload")
    func unescapesScriptPayload() {
        // Simulates the RSC payload as it appears inside a JS string literal,
        // where every `"` is escaped to `\\"`. Group + nested components.
        let html = #"""
        <script>self.__next_f.push([1,"a:{\"groups\":[{\"components\":[{\"component_id\":\"01JVCV8YSWZFRSM1G5CVP253SK\",\"name\":\"Codex Web\"}],\"id\":\"01KMKF9EBTCD8BN9PG8DJZXRSQ\",\"name\":\"Codex\"}]}"])</script>
        """#
        let components = IncidentIOPageComponentsDiscovery.extractComponents(
            fromHTML: html,
            groupRootID: codexGroupRootID
        )
        #expect(components.count == 1)
        #expect(components[0].id.rawValue == "01JVCV8YSWZFRSM1G5CVP253SK")
        #expect(components[0].name == "Codex Web")
    }

    @Test("returns empty when the group root ID is absent (tampered fixture)")
    func tamperedFixtureReturnsEmpty() {
        let payload = """
        {
          "groups": [
            {
              "components": [{"component_id":"01XXXXXXXXXXXXXXXXXXXXXXXX","name":"Unrelated"}],
              "id":"01YYYYYYYYYYYYYYYYYYYYYYYY",
              "name":"Other"
            }
          ]
        }
        """
        let components = IncidentIOPageComponentsDiscovery.extractComponents(
            fromUnescapedPayload: payload,
            groupRootID: codexGroupRootID
        )
        #expect(components.isEmpty)
    }

    @Test("returns empty when the group has an empty components array")
    func emptyComponentsArray() {
        let payload = """
        {"groups":[{"components":[],"id":"01KMKF9EBTCD8BN9PG8DJZXRSQ","name":"Codex"}]}
        """
        let components = IncidentIOPageComponentsDiscovery.extractComponents(
            fromUnescapedPayload: payload,
            groupRootID: codexGroupRootID
        )
        #expect(components.isEmpty)
    }

    @Test("parses the real status.openai.com HTML fixture end-to-end")
    func parsesRealFixture() throws {
        let url = try #require(Bundle.module.url(
            forResource: "openai-status-page",
            withExtension: "html",
            subdirectory: "Fixtures"
        ))
        let html = try String(contentsOf: url, encoding: .utf8)
        let components = IncidentIOPageComponentsDiscovery.extractComponents(
            fromHTML: html,
            groupRootID: codexGroupRootID
        )
        let names = Set(components.map(\.name))
        // The five Codex children documented in the roadmap. The exact set
        // may evolve upstream; assert the historical core membership rather
        // than an exact match so a new addition doesn't break the build.
        #expect(names.contains("Codex Web"))
        #expect(names.contains("App"))
        #expect(names.contains("Codex API"))
        #expect(names.contains("CLI"))
        #expect(names.contains("VS Code extension"))
    }

    @Test("deduplicates a component_id repeated within the group")
    func dedupesRepeatedComponent() {
        let payload = """
        {"groups":[{"components":[
          {"component_id":"01JVCV8YSWZFRSM1G5CVP253SK","name":"Codex Web"},
          {"component_id":"01JVCV8YSWZFRSM1G5CVP253SK","name":"Codex Web (dup)"}
        ],"id":"01KMKF9EBTCD8BN9PG8DJZXRSQ","name":"Codex"}]}
        """
        let components = IncidentIOPageComponentsDiscovery.extractComponents(
            fromUnescapedPayload: payload,
            groupRootID: codexGroupRootID
        )
        #expect(components.count == 1)
    }
}
