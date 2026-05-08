import Foundation

/// Resolves which vendor (if any) the application should log at `.debug`
/// level for payload-bearing exchanges. Two activation sources, in order:
///
/// 1. `AI_TRACKER_VENDOR_DEBUG=<vendor-slug>` environment variable —
///    power-user override on standard builds.
/// 2. `AITrackerVendorDebug` Info.plist key — set by nightly tester
///    builds attached to a `type:new-assistant` PR, scoped to the vendor
///    under test.
///
/// In a release build with neither source set, `activeVendor` is `nil`
/// and no vendor logs payloads — verbose logging is opt-in and never
/// ships by accident with a stable release. See
/// `docs/VENDOR-PLUGIN-CONTRACT.md` §10.
public enum VerboseVendorMode {
    public static let environmentVariableName = "AI_TRACKER_VENDOR_DEBUG"
    public static let infoPlistKey = "AITrackerVendorDebug"

    /// Returns the vendor under verbose logging, or `nil` when neither
    /// activation source is set. Resolved once at first access; subsequent
    /// reads see the same value (a process-wide setting that does not
    /// change at runtime).
    public static let activeVendor: Vendor? = resolveActiveVendor(
        environment: ProcessInfo.processInfo.environment,
        bundle: .main
    )

    /// Test-friendly resolver — production code uses the cached
    /// `activeVendor` static. Exposed `internal` so the test suite can
    /// exercise both activation sources without touching the real env or
    /// the main bundle's Info.plist.
    static func resolveActiveVendor(
        environment: [String: String],
        bundle: Bundle?
    ) -> Vendor? {
        if let raw = environment[environmentVariableName],
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            return Vendor(rawValue: raw)
        }
        if let raw = bundle?.object(forInfoDictionaryKey: infoPlistKey) as? String,
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            return Vendor(rawValue: raw)
        }
        return nil
    }

    /// Returns a `FileLogger` with `minLevel: .debug` forced when the
    /// supplied vendor matches `activeVendor`, otherwise `defaultLogger`
    /// unchanged. The forced logger writes to the same on-disk path as
    /// the default — testers attach the same file to their PR, only the
    /// content changes.
    public static func logger(for vendor: Vendor, default defaultLogger: FileLogger) -> FileLogger {
        guard activeVendor == vendor else { return defaultLogger }
        return FileLogger(filePath: defaultLogger.filePath, minLevel: .debug)
    }
}
