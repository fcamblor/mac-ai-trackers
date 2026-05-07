import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("TesterFeedbackContext")
struct TesterFeedbackContextTests {
    @Test("returns nil when bundle is nil")
    func nilBundle() {
        #expect(TesterFeedbackContext.resolve(bundle: nil) == nil)
    }

    @Test("returns nil when any single key is missing")
    func partialKeysFail() {
        let validCommit = String(repeating: "a", count: 40)
        let url = "https://github.com/owner/repo/issues/42"

        #expect(TesterFeedbackContext.resolve(bundle: stubBundle(values: [
            TesterFeedbackContext.buildCommitPlistKey: validCommit,
            TesterFeedbackContext.issueURLPlistKey: url,
        ])) == nil)

        #expect(TesterFeedbackContext.resolve(bundle: stubBundle(values: [
            TesterFeedbackContext.vendorPlistKey: "claude",
            TesterFeedbackContext.issueURLPlistKey: url,
        ])) == nil)

        #expect(TesterFeedbackContext.resolve(bundle: stubBundle(values: [
            TesterFeedbackContext.vendorPlistKey: "claude",
            TesterFeedbackContext.buildCommitPlistKey: validCommit,
        ])) == nil)
    }

    @Test("rejects a non-40-char build commit")
    func shortCommitRejected() {
        let bundle = stubBundle(values: [
            TesterFeedbackContext.vendorPlistKey: "claude",
            TesterFeedbackContext.buildCommitPlistKey: "abc123",
            TesterFeedbackContext.issueURLPlistKey: "https://github.com/owner/repo/issues/42",
        ])
        #expect(TesterFeedbackContext.resolve(bundle: bundle) == nil)
    }

    @Test("rejects a non-hex build commit of correct length")
    func nonHexCommitRejected() {
        let bundle = stubBundle(values: [
            TesterFeedbackContext.vendorPlistKey: "claude",
            TesterFeedbackContext.buildCommitPlistKey: String(repeating: "z", count: 40),
            TesterFeedbackContext.issueURLPlistKey: "https://github.com/owner/repo/issues/42",
        ])
        #expect(TesterFeedbackContext.resolve(bundle: bundle) == nil)
    }

    @Test("rejects an issue URL outside the canonical github.com/<o>/<r>/issues/<n> shape")
    func nonCanonicalURLRejected() {
        let validCommit = String(repeating: "a", count: 40)
        let cases = [
            "http://github.com/owner/repo/issues/42",       // wrong scheme
            "https://gitlab.com/owner/repo/issues/42",      // wrong host
            "https://github.com/owner/repo/pull/42",        // wrong path segment
            "https://github.com/owner/repo/issues/notnum",  // non-numeric id
            "https://github.com/owner/repo",                // truncated
        ]
        for raw in cases {
            let bundle = stubBundle(values: [
                TesterFeedbackContext.vendorPlistKey: "claude",
                TesterFeedbackContext.buildCommitPlistKey: validCommit,
                TesterFeedbackContext.issueURLPlistKey: raw,
            ])
            #expect(TesterFeedbackContext.resolve(bundle: bundle) == nil, "should reject: \(raw)")
        }
    }

    @Test("happy path resolves and exposes the short commit + log path")
    func happyPath() throws {
        let validCommit = String(repeating: "f", count: 40)
        let bundle = stubBundle(values: [
            TesterFeedbackContext.vendorPlistKey: "claude",
            TesterFeedbackContext.buildCommitPlistKey: validCommit,
            TesterFeedbackContext.issueURLPlistKey: "https://github.com/owner/repo/issues/42",
        ])
        let context = try #require(TesterFeedbackContext.resolve(bundle: bundle))
        #expect(context.vendor == .claude)
        #expect(context.buildCommit == validCommit)
        #expect(context.shortCommit == String(repeating: "f", count: 8))

        let home = URL(fileURLWithPath: "/Users/tester")
        let logURL = context.connectorLogURL(home: home)
        #expect(logURL.path == "/Users/tester/.cache/ai-usages-tracker/claude-usages-connector.log")
    }

    @Test("trims surrounding whitespace before parsing")
    func trimsWhitespace() throws {
        let validCommit = "  " + String(repeating: "0", count: 40) + "  "
        let bundle = stubBundle(values: [
            TesterFeedbackContext.vendorPlistKey: "  claude  ",
            TesterFeedbackContext.buildCommitPlistKey: validCommit,
            TesterFeedbackContext.issueURLPlistKey: " https://github.com/owner/repo/issues/1 ",
        ])
        let context = try #require(TesterFeedbackContext.resolve(bundle: bundle))
        #expect(context.vendor == .claude)
        #expect(context.buildCommit.count == 40)
    }

    /// Build a `Bundle` whose `object(forInfoDictionaryKey:)` returns the
    /// provided dictionary's values. Achieved by writing a temporary
    /// .bundle directory with a real Info.plist — the simplest path that
    /// avoids subclassing `Bundle` (whose API is mostly `final` from
    /// Swift's perspective).
    private func stubBundle(values: [String: String]) -> Bundle {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-tracker-stub-\(UUID().uuidString).bundle", isDirectory: true)
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
