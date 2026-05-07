import Foundation

/// Lifecycle protocol every active-account monitor must satisfy. The
/// callback signature stays vendor-specific (each monitor accepts its own
/// `onActiveAccountChanged` closure during construction) — this protocol
/// only formalizes the start/stop contract so the registry can drive it
/// uniformly from `AppDelegate`.
public protocol ActiveAccountMonitoring: Sendable {
    var vendor: Vendor { get }

    /// Idempotent — calling twice is a no-op once the monitor task is running.
    func start() async

    /// Cancels the monitor task and clears any internal state. Calling stop()
    /// before start() is a no-op.
    func stop() async
}
