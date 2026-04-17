# Swift error handling

## Never swallow errors with `try?` on fallible operations

Using `try?` silently discards the error. This is only acceptable for truly optional operations (e.g., deleting a cache file). For any operation whose failure affects correctness, use `try` with explicit error handling.

Critical operations that must NEVER use `try?`:
- `FileManager.createDirectory` — if it fails, all subsequent writes fail silently
- `FileManager.moveItem` / `copyItem` — rotation/backup failures mean data loss
- Network requests — silent failure means stale or missing data
- Keychain operations — silent failure means auth is broken

```swift
// BAD — silent failure, subsequent code assumes directory exists
try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

// GOOD — propagate or handle explicitly
try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
```

## Never log success after a `catch` without `return`/`throw`

If a `catch` block logs an error but does not `return` or `throw`, execution falls through to subsequent code that may log success or assume the operation succeeded.

```swift
// BAD — logs "saved" even on failure
do {
    try save(data)
} catch {
    logger.error("save failed: \(error)")
}
logger.info("saved successfully") // reached on failure!

// GOOD — return in catch
do {
    try save(data)
    logger.info("saved successfully")
} catch {
    logger.error("save failed: \(error)")
    return
}
```

## Error types must carry diagnostic context

Custom error enums must include associated values with enough context to diagnose issues without access to logs.

```swift
// BAD — caller cannot distinguish causes or log details
enum ConnectorError: Error {
    case authenticationFailed
    case networkError
}

// GOOD — associated values carry context
enum ConnectorError: Error {
    case authenticationFailed(account: String, reason: String)
    case networkError(statusCode: Int, url: URL)
    case timeout(processPath: String, seconds: Int)
}
```

## Distinguish error causes precisely

When an operation can fail for multiple distinct reasons, create separate error cases. Do not conflate timeout, permission denial, and process failure into one case.
