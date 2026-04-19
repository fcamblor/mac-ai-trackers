import Foundation

/// Abstracts the system login-item service so tests can stub launch-at-login behaviour.
@MainActor
public protocol LaunchAtLoginManaging: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}
