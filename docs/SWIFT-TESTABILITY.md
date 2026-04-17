# Swift testability and test coverage

## Design for dependency injection from the start

Every external dependency (network, file system, keychain, system clock, process execution) must be injectable via a protocol. This is non-negotiable for testability.

```swift
// BAD — hard-coded dependency, untestable
actor ClaudeConnector {
    func fetch() async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}

// GOOD — injectable
protocol HTTPClient: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPClient {}

actor ClaudeConnector {
    private let httpClient: HTTPClient
    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }
}
```

Apply this to: `URLSession`, `Keychain` access, `FileManager`, `Process` execution, `Date()` / clock.

## Reuse expensive objects — do not instantiate per call

`ISO8601DateFormatter`, `JSONDecoder`, `JSONEncoder`, and similar heavyweight objects must be created once and reused. Do not instantiate them inside functions called repeatedly.

## Test every public method's primary path

When creating a new type, every public method must have at least one test covering the success path. In particular:
- Network-fetching methods (`fetchUsages`, `fetchToken`, etc.)
- File I/O methods (write, read, rotate, merge)
- Lifecycle methods (start/stop idempotence)
- Error paths for external failures (network down, disk full, lock contention)

## Force-unwrap only with compile-time-provable safety

Never force-unwrap (`!`) on runtime values. For URL literals that are known-valid at compile time, use a clearly documented pattern:

```swift
// Acceptable — string literal, provably valid
private static let apiBase = URL(string: "https://api.example.com")! // known-valid literal

// BAD — runtime input, may fail
let url = URL(string: userInput)! // crash on bad input
```

Even for literals, prefer a static `let` over inline force-unwrap to centralize the assumption.

## Comment WHY, not WHAT

Do not write comments that restate what the code does. Comments must explain *why* a non-obvious decision was made. If the code is self-explanatory, no comment is needed.

```swift
// BAD
// Create the directory
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

// GOOD — no comment needed, the code is self-explanatory

// GOOD — explains a non-obvious choice
// Using LOCK_NB to avoid blocking the cooperative thread pool; retry with backoff instead.
while flock(fd, LOCK_EX | LOCK_NB) != 0 { ... }
```

## Name magic numbers

Every numeric literal (other than 0, 1, true, false) must be a named constant explaining its purpose.

```swift
// BAD
if fileSize > 5_242_880 { rotate() }

// GOOD
private static let maxLogFileSizeBytes = 5_242_880 // 5 MB
if fileSize > Self.maxLogFileSizeBytes { rotate() }
```
