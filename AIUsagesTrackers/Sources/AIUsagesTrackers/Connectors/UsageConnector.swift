import Foundation

public protocol UsageConnector: Sendable {
    var vendor: Vendor { get }
    func fetchUsages() async throws -> [VendorUsageEntry]
    func resolveActiveAccount() -> AccountEmail?
}
