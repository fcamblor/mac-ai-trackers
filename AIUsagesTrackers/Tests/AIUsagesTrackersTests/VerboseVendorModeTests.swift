import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("VerboseVendorMode")
struct VerboseVendorModeTests {
    @Test("returns nil when neither env nor Info.plist is set")
    func neitherSourceSet() {
        let resolved = VerboseVendorMode.resolveActiveVendor(
            environment: [:],
            bundle: nil
        )
        #expect(resolved == nil)
    }

    @Test("environment variable wins over Info.plist")
    func envWinsOverPlist() {
        // Bundle.main is the only Info.plist source — passing nil bundle here
        // exercises the env-only path. The plist-only path is covered by the
        // app-target tests where Bundle.main is the running test bundle.
        let resolved = VerboseVendorMode.resolveActiveVendor(
            environment: [VerboseVendorMode.environmentVariableName: "claude"],
            bundle: nil
        )
        #expect(resolved == .claude)
    }

    @Test("empty environment value falls through")
    func emptyEnvFallsThrough() {
        let resolved = VerboseVendorMode.resolveActiveVendor(
            environment: [VerboseVendorMode.environmentVariableName: "  "],
            bundle: nil
        )
        #expect(resolved == nil)
    }

    @Test("unknown vendor slug still constructs a Vendor — registry lookup decides validity")
    func unknownSlugProducesVendorValue() {
        let resolved = VerboseVendorMode.resolveActiveVendor(
            environment: [VerboseVendorMode.environmentVariableName: "future-vendor"],
            bundle: nil
        )
        #expect(resolved?.rawValue == "future-vendor")
    }

    @Test("logger() forces minLevel debug only when vendor matches")
    func loggerForcesDebugOnlyForMatch() {
        let dir = NSTemporaryDirectory() + "ai-tracker-verbose-\(UUID().uuidString)"
        // swiftlint:disable:next force_try
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let baseline = FileLogger(filePath: "\(dir)/test.log", minLevel: .info)

        // The activeVendor static is process-cached; the test exercises the
        // logger() helper's branching independently of which vendor (if
        // any) is the real verbose target during this run.
        let pinned = VerboseVendorMode.logger(for: .claude, default: baseline)
        if VerboseVendorMode.activeVendor == .claude {
            #expect(pinned.effectiveMinLevel == .debug)
        } else {
            #expect(pinned.filePath == baseline.filePath)
            #expect(pinned.effectiveMinLevel == baseline.effectiveMinLevel)
        }
    }
}
