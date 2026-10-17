import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("ChartSeriesResolver")
struct ChartSeriesResolverTests {
    private static let now = Date(timeIntervalSince1970: 1_775_000_000)

    private static func point(
        vendor: Vendor = .claude,
        account: AccountEmail,
        metricName: String,
        value: Double
    ) -> UsageHistoryPoint {
        UsageHistoryPoint(
            timestamp: now.addingTimeInterval(value),
            vendor: vendor,
            account: account,
            metricName: metricName,
            metricKind: .timeWindow,
            value: value,
            unit: "%"
        )
    }

    private static func nullPoint(
        vendor: Vendor = .claude,
        account: AccountEmail,
        metricName: String,
        offset: Double
    ) -> UsageHistoryPoint {
        UsageHistoryPoint(
            timestamp: now.addingTimeInterval(offset),
            vendor: vendor,
            account: account,
            metricName: metricName,
            metricKind: .timeWindow,
            value: nil,
            unit: "%"
        )
    }

    @Test("allAvailable keeps all points grouped by history series")
    func allAvailableKeepsAllPoints() {
        let points = [
            Self.point(account: "a@example.com", metricName: "session", value: 10),
            Self.point(account: "b@example.com", metricName: "weekly", value: 20),
        ]
        let config = ChartConfiguration(title: "All", selection: .allAvailable)

        let resolved = ChartSeriesResolver.resolve(
            configuration: config,
            points: points,
            currentEntries: []
        )

        #expect(resolved.count == 2)
        #expect(resolved.flatMap(\.points).count == 2)
    }

    @Test("custom filters by vendor account and metric")
    func customFiltersByVendorAccountMetric() {
        let points = [
            Self.point(vendor: .claude, account: "a@example.com", metricName: "session", value: 10),
            Self.point(vendor: .claude, account: "b@example.com", metricName: "session", value: 20),
            Self.point(vendor: .codex, account: "a@example.com", metricName: "session", value: 30),
            Self.point(vendor: .claude, account: "a@example.com", metricName: "weekly", value: 40),
        ]
        let config = ChartConfiguration(
            title: "Custom",
            selection: .custom([
                ChartSeriesConfig(
                    vendor: .claude,
                    account: .specific("a@example.com"),
                    metricName: "session"
                ),
            ])
        )

        let resolved = ChartSeriesResolver.resolve(
            configuration: config,
            points: points,
            currentEntries: []
        )

        #expect(resolved.count == 1)
        #expect(resolved[0].points.map(\.value) == [10.0])
    }

    @Test("custom series merges the Claude family and de-duplicates by timestamp")
    func customMergesClaudeFamilyDeduped() {
        let points = [
            // Same account + metric + timestamp from both Claude vendors → one point.
            Self.point(vendor: .claude, account: "a@example.com", metricName: "session", value: 50),
            Self.point(vendor: .claudeDesktop, account: "a@example.com", metricName: "session", value: 50),
            // A later desktop-only point still contributes to the merged series.
            Self.point(vendor: .claudeDesktop, account: "a@example.com", metricName: "session", value: 60),
        ]
        let config = ChartConfiguration(
            title: "Custom",
            selection: .custom([
                ChartSeriesConfig(vendor: .claude, account: .specific("a@example.com"), metricName: "session"),
            ])
        )
        let resolved = ChartSeriesResolver.resolve(configuration: config, points: points, currentEntries: [])
        #expect(resolved.count == 1)
        #expect(resolved[0].points.map(\.value) == [50.0, 60.0])
    }

    @Test("currentlyActive resolves across the Claude family")
    func currentlyActiveResolvesAcrossFamily() {
        let points = [
            Self.point(vendor: .claudeDesktop, account: "me@example.com", metricName: "session", value: 25),
        ]
        let config = ChartConfiguration(
            title: "Active",
            selection: .custom([
                ChartSeriesConfig(vendor: .claude, account: .currentlyActive, metricName: "session"),
            ])
        )
        // Only a claude-desktop entry is active, but the series is scoped to the
        // canonical `.claude` vendor — family resolution must still find it.
        let resolved = ChartSeriesResolver.resolve(
            configuration: config,
            points: points,
            currentEntries: [VendorUsageEntry(vendor: .claudeDesktop, account: "me@example.com", isActive: true)]
        )
        #expect(resolved[0].points.map(\.value) == [25.0])
    }

    @Test("custom label overrides generated series label")
    func customLabelOverridesGeneratedLabel() {
        let points = [
            Self.point(account: "a@example.com", metricName: "session", value: 10),
        ]
        let config = ChartConfiguration(
            title: "Custom",
            selection: .custom([
                ChartSeriesConfig(
                    vendor: .claude,
                    account: .specific("a@example.com"),
                    metricName: "session",
                    label: "Claude sessions"
                ),
            ])
        )

        let resolved = ChartSeriesResolver.resolve(
            configuration: config,
            points: points,
            currentEntries: []
        )

        #expect(resolved[0].label == "Claude sessions")
    }

    @Test("currentlyActive resolves from current store entries")
    func currentlyActiveResolvesFromCurrentEntries() {
        let points = [
            Self.point(account: "old@example.com", metricName: "session", value: 10),
            Self.point(account: "active@example.com", metricName: "session", value: 20),
        ]
        let entries = [
            VendorUsageEntry(vendor: .claude, account: "old@example.com", isActive: false),
            VendorUsageEntry(vendor: .claude, account: "active@example.com", isActive: true),
        ]
        let config = ChartConfiguration(
            title: "Active",
            selection: .custom([
                ChartSeriesConfig(
                    vendor: .claude,
                    account: .currentlyActive,
                    metricName: "session"
                ),
            ])
        )

        let resolved = ChartSeriesResolver.resolve(
            configuration: config,
            points: points,
            currentEntries: entries
        )

        #expect(resolved[0].points.map(\.account) == ["active@example.com"])
    }

    @Test("allAvailable excludes series whose every point has a nil value")
    func allAvailableExcludesAllNullSeries() {
        let points = [
            Self.point(account: "a@example.com", metricName: "session", value: 10),
            Self.nullPoint(account: "b@example.com", metricName: "weekly", offset: 20),
        ]
        let config = ChartConfiguration(title: "All", selection: .allAvailable)

        let resolved = ChartSeriesResolver.resolve(
            configuration: config,
            points: points,
            currentEntries: []
        )

        #expect(resolved.count == 1)
        #expect(resolved[0].points.map(\.value) == [10.0])
    }

    @Test("currentlyActive with no active account produces empty series")
    func currentlyActiveMissingProducesEmptySeries() {
        let points = [
            Self.point(account: "a@example.com", metricName: "session", value: 10),
        ]
        let config = ChartConfiguration(
            title: "Active",
            selection: .custom([
                ChartSeriesConfig(
                    vendor: .claude,
                    account: .currentlyActive,
                    metricName: "session"
                ),
            ])
        )

        let resolved = ChartSeriesResolver.resolve(
            configuration: config,
            points: points,
            currentEntries: []
        )

        #expect(resolved.count == 1)
        #expect(resolved[0].points.isEmpty)
    }
}
