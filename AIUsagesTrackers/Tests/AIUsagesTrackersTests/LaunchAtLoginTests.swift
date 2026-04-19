import Foundation
import Testing
@testable import AIUsagesTrackersLib

@MainActor
private final class MockLaunchAtLoginService: LaunchAtLoginManaging {
    var isEnabled: Bool

    private var shouldThrow = false

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if shouldThrow { throw MockError.refused }
        isEnabled = enabled
    }

    func simulateThrows() { shouldThrow = true }

    enum MockError: Error { case refused }
}

@Suite("LaunchAtLoginManaging")
struct LaunchAtLoginTests {

    @Test("setEnabled toggles isEnabled on success")
    @MainActor
    func toggleOnSuccess() throws {
        let service = MockLaunchAtLoginService()
        try service.setEnabled(true)
        #expect(service.isEnabled == true)

        try service.setEnabled(false)
        #expect(service.isEnabled == false)
    }

    @Test("preference updated only on successful toggle")
    @MainActor
    func toggleUpdatesPreference() throws {
        let prefs = InMemoryAppPreferences()
        let service = MockLaunchAtLoginService()

        try service.setEnabled(true)
        prefs.launchAtLogin = true
        #expect(prefs.launchAtLogin == true)

        // Failure path — preference must stay unchanged
        service.simulateThrows()
        do {
            try service.setEnabled(false)
            prefs.launchAtLogin = false
        } catch {
            // expected — preference not updated
        }
        #expect(prefs.launchAtLogin == true)
    }

    @Test("reconciliation syncs preference to service state")
    @MainActor
    func reconciliation() {
        let prefs = InMemoryAppPreferences(launchAtLogin: true)
        let service = MockLaunchAtLoginService(isEnabled: false)

        // Pattern from AppDelegate: trust the system over local prefs
        if prefs.launchAtLogin != service.isEnabled {
            prefs.launchAtLogin = service.isEnabled
        }

        #expect(prefs.launchAtLogin == false)
    }

    @Test("reconciliation is a no-op when already in sync")
    @MainActor
    func reconciliationNoOp() {
        let prefs = InMemoryAppPreferences(launchAtLogin: true)
        let service = MockLaunchAtLoginService(isEnabled: true)

        if prefs.launchAtLogin != service.isEnabled {
            prefs.launchAtLogin = service.isEnabled
        }

        #expect(prefs.launchAtLogin == true)
    }
}
