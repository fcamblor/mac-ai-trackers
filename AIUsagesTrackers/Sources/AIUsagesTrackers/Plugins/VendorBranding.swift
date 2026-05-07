import Foundation

/// Vector branding for a vendor — visible from connectors AND the UI.
/// AppKit-free on purpose: rendering helpers (`tintedNSImage`, etc.) live in
/// the App target which composes this value with `NSImage` / `NSColor` lookups.
public struct VendorBranding: Sendable, Equatable, Hashable {
    public let vendor: Vendor
    public let displayName: String
    public let tintHex: String
    public let assetName: String

    public init(
        vendor: Vendor,
        displayName: String,
        tintHex: String,
        assetName: String
    ) {
        self.vendor = vendor
        self.displayName = displayName
        self.tintHex = tintHex
        self.assetName = assetName
    }
}
