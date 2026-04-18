import Foundation

// MARK: - Async polling helper

struct EventuallyTimeoutError: Error, CustomStringConvertible {
    let timeout: TimeInterval
    var description: String { "Condition not met within \(timeout)s" }
}

/// Polls `condition` on the main actor at `interval` until it returns true or `timeout` expires.
@MainActor
func eventually(
    timeout: TimeInterval = 2.0,
    interval: TimeInterval = 0.01,
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while true {
        if condition() { return }
        guard Date() < deadline else { throw EventuallyTimeoutError(timeout: timeout) }
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
        guard Date() < deadline else { throw EventuallyTimeoutError(timeout: timeout) }
        try await Task.sleep(for: .seconds(interval))
    }
}

// MARK: - Absence-confirmation delay

/// Absence-confirmation tests have no observable state to poll, so they wait a
/// fixed duration. A shared constant avoids repeating the rationale at each call site.
let absenceConfirmationDelay: Duration = .milliseconds(100)
