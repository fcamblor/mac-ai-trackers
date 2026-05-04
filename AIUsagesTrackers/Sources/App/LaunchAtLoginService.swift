import AIUsagesTrackersLib
import AppKit
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginService: LaunchAtLoginManaging {
    static let shared = LaunchAtLoginService()

    var isEnabled: Bool {
        // Unified state — BTM (modern SMAppService entry) OR a legacy System
        // Events login item (the fallback target when `register()` runs from a
        // non-bundled binary, e.g. `swift run`). Without the legacy check, the
        // idempotence guard would re-register and stack duplicates in dev.
        if isBTMRegistered { return true }
        return hasLegacyLoginItem()
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled == isEnabled { return }

        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    // MARK: - Private

    private var isBTMRegistered: Bool {
        // `.requiresApproval` means the entry is registered but the user hasn't
        // confirmed it in System Settings yet — treat it as enabled so we don't
        // re-register and stack a duplicate entry.
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    /// Queries System Events for legacy login items matching this app. Requires
    /// Automation permission (TCC); on first call macOS prompts the user. If the
    /// query fails (denied, sandboxed, scripting bridge unavailable) we conservatively
    /// return `false` — the worst case is one extra `register()` call, which the
    /// next invocation's idempotence check will catch via BTM status.
    private func hasLegacyLoginItem() -> Bool {
        let script = """
        tell application "System Events"
            return (count of (every login item whose name contains "AIUsagesTrackers" or name contains "AI Usages Tracker")) > 0
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var error: NSDictionary?
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            Loggers.app.log(.warning, "Failed to query legacy login items via System Events: \(error)")
            return false
        }
        return result.booleanValue
    }
}
