import Foundation

/// A vendor + account pair that the user has chosen to hide from the popover list.
/// Stored in preferences as a JSON-encoded array.
public struct IgnoredAccount: Codable, Equatable, Hashable, Sendable {
    public let vendor: Vendor
    public let account: AccountEmail

    public init(vendor: Vendor, account: AccountEmail) {
        self.vendor = vendor
        self.account = account
    }
}
