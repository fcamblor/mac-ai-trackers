import Foundation
import os

/// Compile-time list of every assistant the application knows how to
/// poll. Adding a vendor is exactly: implement the contract under the
/// vendor's own `*Plugin` namespace, then call
/// `VendorRegistry.register(_:)` during application startup. No edits to
/// `AppDelegate`, `Loggers`, or any cross-cutting subsystem are required
/// beyond their declared plugin points.
///
/// The registry starts empty so the framework compiles before any
/// connector is migrated onto the contract. Population happens once per
/// application lifecycle from `AppDelegate.applicationDidFinishLaunching`.
public enum VendorRegistry {
    /// Storage protected by an `OSAllocatedUnfairLock` — registration is
    /// startup-only, but reads happen from the cooperative thread pool
    /// (poller, monitors) without hopping isolation.
    private static let storage = OSAllocatedUnfairLock<[VendorBundle]>(initialState: [])

    public static var bundles: [VendorBundle] {
        storage.withLock { $0 }
    }

    /// Registers a bundle. Idempotent on the `vendor` key — calling twice
    /// with the same vendor replaces the previously registered bundle so
    /// tests can inject mocks without leaking across runs.
    public static func register(_ bundle: VendorBundle) {
        storage.withLock { current in
            current.removeAll { $0.vendor == bundle.vendor }
            current.append(bundle)
        }
    }

    /// Test hook — clears the registry so a `setUp()` can prime it from
    /// scratch. Production code never calls this.
    public static func resetForTesting() {
        storage.withLock { $0.removeAll() }
    }

    public static func bundle(for vendor: Vendor) -> VendorBundle? {
        storage.withLock { current in
            current.first { $0.vendor == vendor }
        }
    }
}
