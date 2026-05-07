import Foundation
import Testing
@testable import AIUsagesTrackersLib

@Suite("VendorRegistry — contract conformance", .serialized)
struct VendorRegistryConformanceTests {
    /// Walks up from the test source file until it finds a directory
    /// containing CLAUDE.md — that's the repo root, regardless of how
    /// the test bundle was assembled. Avoids hard-coding parent counts.
    private static func locateRepoRoot(file: String = #filePath) -> URL {
        var url = URL(fileURLWithPath: file)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            let marker = url.appendingPathComponent("CLAUDE.md")
            if FileManager.default.fileExists(atPath: marker.path) {
                return url
            }
        }
        Issue.record("Could not locate repo root from \(file)")
        return URL(fileURLWithPath: file).deletingLastPathComponent()
    }

    /// Registers every production bundle. Run inside the suite so the
    /// VendorRegistry under test reflects the same set AppDelegate
    /// publishes at startup, minus the poller-driven callbacks (this
    /// test cares about static shape, not lifecycle).
    private func populateRegistry() {
        VendorRegistry.resetForTesting()
        let claudeConnector = ClaudeCodeConnector()
        let codexConnector = CodexConnector()
        ClaudeCodePlugin.register(
            connector: claudeConnector,
            status: ClaudeStatusConnector(),
            monitor: ClaudeActiveAccountMonitor(fileManager: .shared)
        )
        CodexPlugin.register(
            connector: codexConnector,
            status: CodexStatusConnector(),
            monitor: CodexActiveAccountMonitor()
        )
    }

    @Test("registry exposes one bundle per known vendor")
    func registryHasAllVendors() {
        populateRegistry()
        let vendors = VendorRegistry.bundles.map(\.vendor.rawValue).sorted()
        #expect(vendors == ["claude", "codex"])
    }

    @Test("each branding asset resolves to a PDF file under App/Resources/VendorBranding/")
    func brandingAssetsExist() throws {
        populateRegistry()
        let assetsDir = Self.locateRepoRoot()
            .appendingPathComponent("AIUsagesTrackers/Sources/App/Resources/VendorBranding")
        for bundle in VendorRegistry.bundles {
            let asset = assetsDir.appendingPathComponent("\(bundle.branding.assetName).pdf")
            #expect(
                FileManager.default.fileExists(atPath: asset.path),
                "Branding asset missing for \(bundle.vendor.rawValue): \(asset.path)"
            )
        }
    }

    @Test("each vendor doc exists and carries a Last verified header")
    func vendorDocsExistAndAreDated() throws {
        populateRegistry()
        let docsDir = Self.locateRepoRoot().appendingPathComponent("docs/vendors")
        for bundle in VendorRegistry.bundles {
            let docPath = docsDir.appendingPathComponent("\(bundle.documentation.slug).md")
            guard FileManager.default.fileExists(atPath: docPath.path) else {
                Issue.record("Vendor doc missing for \(bundle.vendor.rawValue): \(docPath.path)")
                continue
            }
            let contents = (try? String(contentsOf: docPath, encoding: .utf8)) ?? ""
            #expect(
                contents.contains("**Last verified:**"),
                "Vendor doc \(docPath.lastPathComponent) is missing a `**Last verified:**` line"
            )
        }
    }

    @Test("each branding tintHex is a 6-digit upper-case hex value")
    func brandingTintHexShape() {
        populateRegistry()
        let pattern = #/^[0-9A-F]{6}$/#
        for bundle in VendorRegistry.bundles {
            #expect(
                (try? pattern.wholeMatch(in: bundle.branding.tintHex)) != nil,
                "Branding tintHex must be a 6-digit upper-case hex (got '\(bundle.branding.tintHex)') for \(bundle.vendor.rawValue)"
            )
        }
    }

    @Test("LoggingProxy of every bundle wraps a sanitizer that round-trips empty payload")
    func sanitizerRoundTripIsIdempotent() {
        populateRegistry()
        let empty = Data("{}".utf8)
        for bundle in VendorRegistry.bundles {
            let once = bundle.sanitizer.sanitize(empty)
            let twice = bundle.sanitizer.sanitize(once)
            #expect(once == twice, "Sanitizer for \(bundle.vendor.rawValue) is not idempotent on empty payload")
        }
    }
}
