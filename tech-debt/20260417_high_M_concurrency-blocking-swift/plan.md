---
title: Concurrency and blocking issues in Logger, FileManager and Connector
date: 2026-04-18
---

## Drift from original debt description

File paths in the debt entry are wrong. The actual module is `AIUsagesTrackersLib` located
at `AIUsagesTrackers/Sources/AIUsagesTrackers/`. All three source issues are still present.

`ClaudeCodeConnector` has **two** `nonisolated(unsafe) static let` formatters (lines 15–21),
not one as stated. Both are used exclusively from the actor-isolated `normalizeISO8601` helper,
so there is no active data race, but the fragility remains.

`UsagesFileManager` uses `data.write(to:options:.atomic)` which performs an atomic rename and
replaces the file inode. Flocking the JSON file's own fd is therefore ineffective for external
readers. A separate lock file (`usages.json.lock`) must be used as the advisory mutex.

## Overall approach

Fix each issue in isolation with a separate commit so that each change is reviewable and
bisectable on its own. Start with the simplest (Logger one-liner), then the formatter
replacement (pure deletion + local allocation), then the flock addition (largest change,
introduces an async helper and a new error type).

## Phases and commits

### Phase 1: Logger — replace blocking queue.sync

**Goal**: Eliminate the cooperative-thread-pool blocker in `FileLogger.append()`.

#### Commit 1 — `fix(logger): replace queue.sync with queue.async in append()`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Logging/Logger.swift`
- Changes:
  - Line 56: change `queue.sync {` to `queue.async {`
  - No other changes. The serial queue already guarantees ordering; callers have never
    needed a return value from `append()`, so fire-and-forget is correct.
  - `Self.isoFormatter` inside the closure remains safe — it is only ever accessed from
    within this serial queue.
- Risk: None. The surrounding logic is identical; only the dispatch strategy changes.

#### Commit 2 — `test(logger): add 20-concurrent-task stress test for log()`
- Files: `AIUsagesTrackers/Tests/AIUsagesTrackersTests/LoggerTests.swift`
- Changes: add the following test case inside `@Suite("FileLogger")`:
  ```swift
  @Test("log() is safe under 20 concurrent calls from a TaskGroup")
  func concurrentLogging() async {
      let path = makeTempPath()
      let logger = FileLogger(filePath: path, minLevel: .debug)
      await withTaskGroup(of: Void.self) { group in
          for i in 0..<20 {
              group.addTask {
                  logger.log(.info, "message \(i)")
              }
          }
      }
      #expect(FileManager.default.fileExists(atPath: path))
      let content = try! String(contentsOfFile: path, encoding: .utf8)
      #expect(!content.isEmpty)
  }
  ```
- Risk: This test will fail under Thread Sanitizer if a data race is introduced. Run with
  `swift test --sanitize thread` to validate.

---

### Phase 2: ClaudeCodeConnector — remove nonisolated(unsafe) static formatters

**Goal**: Eliminate `nonisolated(unsafe)` from the two `ISO8601DateFormatter` statics in
`ClaudeCodeConnector`. `normalizeISO8601` is called at most twice per polling interval
(cold path), so per-call allocation is explicitly recommended in `docs/SWIFT-CONCURRENCY.md`.

#### Commit 3 — `fix(connector): replace nonisolated(unsafe) formatters with per-call instances`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Connectors/ClaudeCodeConnector.swift`
- Changes:
  1. Delete lines 15–21 (both `nonisolated(unsafe) private static let isoFormatter` and
     `isoFormatterFractional` declarations, including the closing `}()`).
  2. Rewrite `normalizeISO8601` to allocate formatters locally:
     ```swift
     private static func normalizeISO8601(_ raw: String) -> ISODate {
         let fractional: ISO8601DateFormatter = {
             let f = ISO8601DateFormatter()
             f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
             return f
         }()
         let standard = ISO8601DateFormatter()
         if let date = fractional.date(from: raw) ?? standard.date(from: raw) {
             return ISODate(rawValue: standard.string(from: date))
         }
         return ISODate(rawValue: raw)
     }
     ```
  3. No other changes. The method stays `private static`; callers (`parseAPIResponse`) are
     unchanged.
- Risk: Minor allocation overhead per API call — acceptable given polling interval.

---

### Phase 3: UsagesFileManager — add flock with timeout

**Goal**: Protect external readers (widgets, scripts) from observing a partially replaced
file by acquiring an advisory lock on a dedicated lock file before any read or write.

#### Commit 4 — `fix(file-manager): add flock with configurable timeout for external readers`
- Files: `AIUsagesTrackers/Sources/AIUsagesTrackers/Persistence/UsagesFileManager.swift`
- Changes (implement in this exact order within the file):

  **1. Add `import Darwin` at the top** (after `import Foundation`) for `open`, `flock`,
  `close`, `LOCK_SH`, `LOCK_EX`, `LOCK_NB`, `LOCK_UN`, `O_CREAT`, `O_RDWR`.

  **2. Add `FileManagerError` enum** (new top-level enum, place after the closing `}` of
  `UsagesFileManager`):
  ```swift
  enum FileManagerError: Error, CustomStringConvertible {
      case cannotOpenLockFile(path: String)
      case lockTimeout(path: String, timeoutSeconds: Double)

      var description: String {
          switch self {
          case let .cannotOpenLockFile(path):
              "Cannot open lock file at \(path)"
          case let .lockTimeout(path, secs):
              "Could not acquire flock on \(path) within \(secs)s"
          }
      }
  }
  ```

  **3. Update `UsagesFileManager` stored properties**: add two new properties immediately
  after the existing `private let logger: FileLogger` line:
  ```swift
  nonisolated public let lockPath: String
  private let lockTimeoutSeconds: TimeInterval
  ```

  **4. Update `init`**: add `lockTimeoutSeconds: TimeInterval = 5.0` parameter and
  initialize both new properties:
  ```swift
  init(
      filePath: String? = nil,
      logger: FileLogger = Loggers.app,
      lockTimeoutSeconds: TimeInterval = 5.0
  ) {
      // ... existing body unchanged ...
      self.lockPath = self.filePath + ".lock"
      self.lockTimeoutSeconds = lockTimeoutSeconds
  }
  ```
  Insert the two assignments after `self.logger = logger` (before the `createDirectory`
  block).

  **5. Add `withFileLock` private async helper** inside the actor body (place it in a new
  `// MARK: - Lock` section before `// MARK: - Unsafe`):
  ```swift
  // MARK: - Lock

  /// Acquires an advisory flock on the dedicated lock file, runs `body`, then releases.
  /// Uses a separate lock file because atomic writes replace the JSON inode, making
  /// flock on the data file itself ineffective for protecting external readers.
  private func withFileLock<T>(mode: Int32, body: () throws -> T) async throws -> T {
      let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o644)
      guard fd >= 0 else { throw FileManagerError.cannotOpenLockFile(path: lockPath) }
      defer { Darwin.close(fd) }

      let deadline = Date().addingTimeInterval(lockTimeoutSeconds)
      while flock(fd, mode | LOCK_NB) != 0 {
          guard Date() < deadline else {
              throw FileManagerError.lockTimeout(path: lockPath, timeoutSeconds: lockTimeoutSeconds)
          }
          try await Task.sleep(for: .milliseconds(50))
      }
      defer { flock(fd, LOCK_UN) }

      return try body()
  }
  ```

  **6. Update `read()`** to route through the shared lock:
  ```swift
  public func read() async -> UsagesFile {
      do {
          return try await withFileLock(mode: LOCK_SH) { readUnsafe() }
      } catch {
          logger.log(.warning, "flock read failed — returning empty file: \(error)")
          return UsagesFile()
      }
  }
  ```

  **7. Update `update(with:)`** to hold an exclusive lock for the full read-modify-write:
  ```swift
  public func update(with entries: [VendorUsageEntry]) async {
      do {
          try await withFileLock(mode: LOCK_EX) {
              var file = readUnsafe()
              file = merge(existing: file, incoming: entries)
              writeUnsafe(file)
          }
      } catch {
          logger.log(.warning, "flock update failed — skipping write: \(error)")
      }
  }
  ```

  **8. Update `updateIsActive(vendor:activeAccount:)`** similarly:
  ```swift
  public func updateIsActive(vendor: Vendor, activeAccount: AccountEmail?) async {
      do {
          try await withFileLock(mode: LOCK_EX) {
              var file = readUnsafe()
              var changed = false
              for i in file.usages.indices {
                  guard file.usages[i].vendor == vendor else { continue }
                  let newActive = file.usages[i].account == activeAccount
                  if file.usages[i].isActive != newActive {
                      file.usages[i].isActive = newActive
                      changed = true
                  }
              }
              if changed {
                  writeUnsafe(file)
              }
          }
      } catch {
          logger.log(.warning, "flock updateIsActive failed — skipping: \(error)")
      }
  }
  ```

  **9. Leave `readUnsafe()` and `writeUnsafe()` unchanged** — they remain synchronous
  private helpers; the locking layer above them owns all I/O serialization.

- Risk: `withFileLock` suspends while retrying. If lock files accumulate from killed
  processes, the advisory lock is released automatically by the OS on fd close — no cleanup
  needed. The `lockTimeoutSeconds` parameter allows tests to use short timeouts (e.g. 0.1 s).

---

## Validation

Build and test from `AIUsagesTrackers/`:
```bash
swift build
swift test
```

All existing tests in `UsagesFileManagerTests`, `LoggerTests`, `ClaudeCodeConnectorTests`,
`UsagePollerTests`, and `ClaudeActiveAccountMonitorTests` must pass.

Additionally verify acceptance criteria:

- `Logger.append()` uses `queue.async`: grep `queue\.async` in `Logging/Logger.swift` — must appear at the append site.
- Concurrent log test passes without data races: run `swift test --sanitize thread` (requires a toolchain with TSan support).
- `UsagesFileManager` acquires flock with timeout: grep `flock` in `Persistence/UsagesFileManager.swift` — must appear in `withFileLock`. Search for `FileManagerError` in the same file.
- `isoFormatter` / `isoFormatterFractional` statics removed: `grep -n "nonisolated(unsafe)" AIUsagesTrackers/Sources/AIUsagesTrackers/Connectors/ClaudeCodeConnector.swift` must return no matches.
