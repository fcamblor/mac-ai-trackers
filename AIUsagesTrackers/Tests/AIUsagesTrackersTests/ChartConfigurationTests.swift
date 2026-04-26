import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("ChartConfiguration")
struct ChartConfigurationTests {
    @Test("all-available selection round-trips through Codable")
    func allAvailableRoundTrip() throws {
        let original = ChartConfiguration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "All",
            selection: .allAvailable
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChartConfiguration.self, from: data)

        #expect(decoded == original)
    }

    @Test("custom series with style round-trips through Codable")
    func customSeriesRoundTrip() throws {
        let original = ChartConfiguration(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Custom",
            selection: .custom([
                ChartSeriesConfig(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                    vendor: .claude,
                    account: .specific("me@example.com"),
                    metricName: "Weekly (all models)",
                    label: "Claude weekly",
                    style: ChartSeriesStyle(color: .pink, lineStyle: .dotted)
                ),
            ])
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChartConfiguration.self, from: data)

        #expect(decoded == original)
    }

    @Test("custom series without label decodes with empty label")
    func customSeriesLegacyLabelDefault() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000004",
          "vendor": "claude",
          "account": {
            "kind": "specific",
            "email": "me@example.com"
          },
          "metricName": "Weekly (all models)",
          "style": {
            "color": "blue",
            "lineStyle": "solid"
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ChartSeriesConfig.self, from: json)

        #expect(decoded.label == "")
    }
}
