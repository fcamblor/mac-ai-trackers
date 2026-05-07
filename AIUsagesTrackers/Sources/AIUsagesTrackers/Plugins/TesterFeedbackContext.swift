import Foundation

/// Activation context for the in-app tester feedback affordance described
/// in `docs/ASSISTANT-ONBOARDING.md` §6.4.
///
/// The feedback UI is visible iff **all three** Info.plist keys are
/// present and parseable in the running bundle:
///
/// - `AITrackerVendorDebug` — vendor slug under test (also drives
///   `VerboseVendorMode`).
/// - `AITrackerBuildCommit` — full 40-char commit SHA the DMG was built
///   from.
/// - `AITrackerOnboardingIssueURL` — fully-qualified GitHub issue URL
///   the tester should comment on.
///
/// All-or-nothing semantics are deliberate: a stable release MUST NOT
/// expose this affordance, and the cleanest way to enforce that at
/// runtime is to gate the entire UI on the presence of every key. The
/// release workflow asserts the trio is absent from any tagged build;
/// this resolver makes a partial set fail closed.
public struct TesterFeedbackContext: Sendable, Equatable {
    public let vendor: Vendor
    public let buildCommit: String
    public let issueURL: URL

    public static let vendorPlistKey = "AITrackerVendorDebug"
    public static let buildCommitPlistKey = "AITrackerBuildCommit"
    public static let issueURLPlistKey = "AITrackerOnboardingIssueURL"

    /// Cached resolution against the running app's main bundle. `nil` in
    /// tests (the test bundle's Info.plist does not carry the keys) and
    /// in stable releases by construction.
    public static let resolved: TesterFeedbackContext? = resolve(bundle: .main)

    public init(vendor: Vendor, buildCommit: String, issueURL: URL) {
        self.vendor = vendor
        self.buildCommit = buildCommit
        self.issueURL = issueURL
    }

    /// Test-friendly resolver. Returns `nil` if any key is missing,
    /// empty after trimming, or shaped unexpectedly (build commit must
    /// be 40 hex chars; issue URL must be the canonical
    /// `https://github.com/<owner>/<repo>/issues/<n>` form).
    public static func resolve(bundle: Bundle?) -> TesterFeedbackContext? {
        guard let bundle else { return nil }
        guard let vendorRaw = string(bundle, vendorPlistKey),
              let commitRaw = string(bundle, buildCommitPlistKey),
              let urlRaw = string(bundle, issueURLPlistKey) else {
            return nil
        }
        guard isFullCommitSha(commitRaw),
              let url = canonicalIssueURL(urlRaw) else {
            return nil
        }
        return TesterFeedbackContext(
            vendor: Vendor(rawValue: vendorRaw),
            buildCommit: commitRaw,
            issueURL: url
        )
    }

    public var shortCommit: String {
        String(buildCommit.prefix(8))
    }

    /// Resolved per-vendor connector log path the tester is asked to
    /// attach to the issue comment. Mirrors the path used by
    /// `Logger.<vendor>` in production.
    public func connectorLogURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("ai-usages-tracker", isDirectory: true)
            .appendingPathComponent("\(vendor.rawValue)-usages-connector.log", isDirectory: false)
    }

    private static func string(_ bundle: Bundle, _ key: String) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isFullCommitSha(_ value: String) -> Bool {
        guard value.count == fullCommitShaLength else { return false }
        return value.allSatisfy { $0.isHexDigit }
    }

    private static let fullCommitShaLength = 40

    private static func canonicalIssueURL(_ value: String) -> URL? {
        // Pattern: https://github.com/<owner>/<repo>/issues/<n>
        guard let url = URL(string: value),
              url.scheme == "https",
              url.host == "github.com" else {
            return nil
        }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 4,
              parts[2] == "issues",
              Int(parts[3]) != nil else {
            return nil
        }
        return url
    }
}
