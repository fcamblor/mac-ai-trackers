# Swift concurrency safety

## Never block the cooperative thread pool

Swift concurrency uses a fixed-size thread pool. Blocking calls starve other tasks.

- **Never** call `Process.waitUntilExit()` or any synchronous blocking API from an `async` context or inside an `actor`. Wrap blocking work in a `DispatchQueue` or `Task.detached` with a continuation.
- **Never** call `readDataToEndOfFile()` *after* `waitUntilExit()` — this deadlocks when the pipe buffer is full. Always read pipes *before* waiting for process termination.

```swift
// BAD — blocks the cooperative thread pool
func run() async throws -> Data {
    process.launch()
    let data = pipe.fileHandleForReading.readDataToEndOfFile() // deadlock risk
    process.waitUntilExit() // blocks a cooperative thread
    return data
}

// GOOD — async with continuation, read before wait
func run() async throws -> Data {
    return try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            process.launch()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: data)
        }
    }
}
```

## NSFormatter and other non-thread-safe Foundation types

`DateFormatter`, `ISO8601DateFormatter`, `NumberFormatter`, and similar `NSFormatter` subclasses are **not thread-safe**. If used from concurrent contexts:

- Make them `static let` on a dedicated serial queue, OR
- Create a new instance each time (acceptable for cold paths), OR
- Use Swift's `nonisolated(unsafe)` only if you prove single-threaded access.

Never share a formatter across threads without synchronization.

```swift
// BAD — data race
actor MyActor {
    private let formatter = ISO8601DateFormatter()
    func format(_ date: Date) -> String {
        formatter.string(from: date) // races if called from nonisolated context
    }
}

// GOOD — one instance per call (simple, safe)
func format(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: date)
}

// GOOD — static on serial queue (reusable, safe)
enum DateFormatting {
    private static let queue = DispatchQueue(label: "formatter")
    private static let formatter = ISO8601DateFormatter()
    static func format(_ date: Date) -> String {
        queue.sync { formatter.string(from: date) }
    }
}
```

## Do not use `weak self` inside actors

Actors are reference types with their own isolation. Using `[weak self]` in closures inside an actor is unnecessary and misleading — the actor manages its own lifetime. Use `[self]` or capture nothing.

## Always add a timeout when launching external processes

When spawning a `Process`, always set a timeout mechanism (e.g., `DispatchSource.makeTimerSource` or `Task.sleep` + cancellation). A hung child process must not hang the app forever.
