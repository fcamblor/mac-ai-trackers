import Foundation
import ServiceManagement

// MARK: - Protocol

/// Abstracts SMAppService so tests can stub launch-at-login behaviour.
@MainActor
protocol LaunchAtLoginManaging: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

// MARK: - Production implementation

@MainActor
final class LaunchAtLoginService: LaunchAtLoginManaging {
    static let shared = LaunchAtLoginService()

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
