import Foundation
import Testing
@testable import AIUsagesTrackers
@testable import AIUsagesTrackersLib

@Suite("AppDelegate update checks availability")
@MainActor
struct AppDelegateUpdateChecksTests {
    @Test("allows update checks when a regular app version is present")
    func regularVersionAllowsUpdateChecks() {
        let bundle = stubBundle(values: [
            "CFBundleShortVersionString": "1.2.3",
        ])

        #expect(AppDelegate.currentAppVersion(bundle: bundle)?.rawValue == "1.2.3")
        #expect(AppDelegate.areUpdateChecksUnavailable(bundle: bundle) == false)
    }

    @Test("disables update checks when the app version is missing")
    func missingVersionDisablesUpdateChecks() {
        let bundle = stubBundle(values: [:])

        #expect(AppDelegate.currentAppVersion(bundle: bundle) == nil)
        #expect(AppDelegate.areUpdateChecksUnavailable(bundle: bundle))
    }

    @Test("disables update checks for tester-debug builds even when a bundle version exists")
    func testerDebugBuildDisablesUpdateChecks() {
        let bundle = stubBundle(values: [
            "CFBundleShortVersionString": "0.1.0",
            TesterFeedbackContext.vendorPlistKey: "claude",
            TesterFeedbackContext.buildCommitPlistKey: String(repeating: "a", count: 40),
            TesterFeedbackContext.issueURLPlistKey: "https://github.com/owner/repo/issues/42",
        ])

        #expect(AppDelegate.currentAppVersion(bundle: bundle)?.rawValue == "0.1.0")
        #expect(AppDelegate.areUpdateChecksUnavailable(bundle: bundle))
    }

    private func stubBundle(values: [String: String]) -> Bundle {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-tracker-appdelegate-\(UUID().uuidString).bundle", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let plistURL = tmp.appendingPathComponent("Info.plist")
            let data = try PropertyListSerialization.data(
                fromPropertyList: values,
                format: .xml,
                options: 0
            )
            try data.write(to: plistURL, options: .atomic)
        } catch {
            Issue.record("stubBundle setup failed: \(error)")
        }
        // swiftlint:disable:next force_unwrapping
        return Bundle(url: tmp)!
    }
}
