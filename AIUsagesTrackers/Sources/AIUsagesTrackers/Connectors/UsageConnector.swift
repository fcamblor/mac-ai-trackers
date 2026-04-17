import Foundation

protocol UsageConnector: Sendable {
    var vendor: String { get }
    func fetchUsages() async throws -> [VendorUsageEntry]
    func resolveActiveAccount() -> String?
}
