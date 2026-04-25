import Testing
@testable import AIUsagesTrackers
import AIUsagesTrackersLib

@Suite("VendorBranding")
struct VendorBrandingTests {
    @Test("maps Claude to its branded asset and label")
    func mapsClaude() {
        let brand = VendorBranding.brand(for: .claude)

        #expect(brand?.assetName == "claude-mark")
        #expect(brand?.displayName == "Claude Code")
        #expect(brand?.tintHex == "DA7756")
    }

    @Test("maps Codex to its branded asset and label")
    func mapsCodex() {
        let brand = VendorBranding.brand(for: .codex)

        #expect(brand?.assetName == "codex-mark")
        #expect(brand?.displayName == "Codex")
        #expect(brand?.tintHex == "10A37F")
    }

    @Test("falls back cleanly for unknown vendors")
    func fallsBackForUnknownVendor() {
        let vendor = Vendor(rawValue: "unknown")

        #expect(VendorBranding.brand(for: vendor) == nil)
        #expect(VendorBranding.displayName(for: vendor) == "unknown")
    }
}
