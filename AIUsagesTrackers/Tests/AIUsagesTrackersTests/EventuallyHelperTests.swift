import Foundation
import Testing

@Suite("eventually() helper")
struct EventuallyHelperTests {

    @MainActor
    @Test("returns immediately when condition is already true")
    func immediateSuccess() async throws {
        try await eventually { true }
    }

    @MainActor
    @Test("throws EventuallyTimeoutError with timeout context when condition never holds")
    func timeoutThrows() async {
        do {
            try await eventually(timeout: 0.05, interval: 0.01) { false }
            Issue.record("Expected EventuallyTimeoutError")
        } catch let error as EventuallyTimeoutError {
            #expect(error.timeout == 0.05)
            #expect(error.description.contains("0.05"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("async overload works with actor-isolated state")
    func asyncOverload() async throws {
        actor Counter {
            var value = 0
            func increment() { value += 1 }
        }
        let counter = Counter()
        Task {
            // swiftlint:disable:next w3_task_sleep_literal_in_tests — sequencing: simulate async delay before state change
            try await Task.sleep(for: .milliseconds(20))
            await counter.increment()
        }
        try await eventually { await counter.value > 0 }
    }
}
