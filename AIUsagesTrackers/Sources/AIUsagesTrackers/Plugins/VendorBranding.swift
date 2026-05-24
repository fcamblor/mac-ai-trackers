import Foundation

/// Vector branding for a vendor — visible from connectors AND the UI.
/// AppKit-free on purpose: rendering helpers (`tintedNSImage`, etc.) live in
/// the App target which composes this value with `NSImage` / `NSColor` lookups.
public struct VendorBranding: Sendable, Equatable, Hashable {
    public let vendor: Vendor
    public let displayName: String
    public let tintHex: String
    public let assetName: String

    /// `assetName` defaults to `vendor.defaultBrandingAssetName`
    /// (`<rawValue>-mark`). Callers should rely on the default so the
    /// PDF filename in `App/Resources/VendorBranding/` cannot drift
    /// from the vendor slug.
    public init(
        vendor: Vendor,
        displayName: String,
        tintHex: String,
        assetName: String? = nil
    ) {
        self.vendor = vendor
        self.displayName = displayName
        self.tintHex = tintHex
        self.assetName = assetName ?? vendor.defaultBrandingAssetName
    }
}
