import Foundation

// MARK: - Async polling helper

struct EventuallyTimeoutError: Error {}

/// Polls `condition` on the main actor at `interval` until it returns true or `timeout` expires.
/// Uses `Task.sleep(for:)` with a Duration parameter to avoid embedding numeric literals
/// in the sleep call (which would trigger SwiftLint W3).
@MainActor
func eventually(
    timeout: TimeInterval = 2.0,
    interval: TimeInterval = 0.01,
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while true {
        if condition() { return }
        guard Date() < deadline else { throw EventuallyTimeoutError() }
        try await Task.sleep(for: .seconds(interval))
    }
}

/// Non-isolated overload for tests that need `await` inside the condition
/// (e.g. reading actor-isolated properties).
func eventually(
    timeout: TimeInterval = 2.0,
    interval: TimeInterval = 0.01,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while true {
        if await condition() { return }
        guard Date() < deadline else { throw EventuallyTimeoutError() }
        try await Task.sleep(for: .seconds(interval))
    }
}

// MARK: - Absence-confirmation delay

/// Named constant for tests that confirm the absence of an event.
/// These tests have no observable state to poll — they wait a fixed duration
/// then assert nothing changed. The value must exceed one processing cycle
/// but stay short enough to keep test suites fast.
let absenceConfirmationDelay: Duration = .milliseconds(100)
