import SwiftUI

/// Tabs exposed by the Settings window. Lives in the app target because the
/// settings UI is here, not in the library.
enum SettingsTab: Hashable {
    case general
    case codingAssistants
    case menubarHint
    case charts
    case status
    case updates
}

/// Lets non-SwiftUI callers (e.g. AppDelegate, the popover) request which tab
/// should be focused the next time the Settings window opens. The Settings
/// `TabView` binds its selection to `selectedTab`, so flipping this value
/// from anywhere on the main thread routes the navigation.
@Observable
@MainActor
final class SettingsRouter {
    static let shared = SettingsRouter()

    var selectedTab: SettingsTab = .general

    private init() {}
}
