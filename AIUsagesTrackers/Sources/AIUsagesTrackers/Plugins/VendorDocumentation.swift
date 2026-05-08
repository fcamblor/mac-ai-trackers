import Foundation

/// Pointer to a vendor's dated research snapshot under `docs/vendors/<slug>.md`.
/// The slug is the relative path component (without extension); the contract
/// conformance test resolves it to the on-disk file and parses the
/// `Last verified:` line out of the H1's preamble.
public struct VendorDocumentation: Sendable, Equatable, Hashable {
    public let vendor: Vendor
    public let slug: String

    public init(vendor: Vendor, slug: String) {
        self.vendor = vendor
        self.slug = slug
    }

    /// Repository-relative path the doc must exist at.
    public var relativePath: String { "docs/vendors/\(slug).md" }
}
