import Foundation
import Observation

public struct AccountKey: Hashable, Sendable {
    public let vendor: Vendor
    public let account: AccountEmail

    public init(vendor: Vendor, account: AccountEmail) {
        self.vendor = vendor
        self.account = account
    }
}

/// Tracks which (vendor, account) pairs are currently being fetched so the UI
/// can display a per-account spinner during both auto-poll and forced refresh.
@Observable
@MainActor
public final class RefreshState {
    public private(set) var inFlight: Set<AccountKey> = []

    public init() {}

    public func begin(_ key: AccountKey) {
        inFlight.insert(key)
    }

    public func end(_ key: AccountKey) {
        inFlight.remove(key)
    }

    public func isRefreshing(vendor: Vendor, account: AccountEmail) -> Bool {
        inFlight.contains(AccountKey(vendor: vendor, account: account))
    }
}
