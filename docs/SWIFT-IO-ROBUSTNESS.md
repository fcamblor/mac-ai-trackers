# Swift I/O robustness

## Atomic file writes

When writing data files (JSON, logs, config), always write to a temporary file first, then atomically rename. This prevents corruption if the process is killed mid-write.

```swift
// BAD — partial write on crash
try data.write(to: targetURL)

// GOOD — atomic rename
let tempURL = targetURL.appendingPathExtension("tmp")
try data.write(to: tempURL)
try FileManager.default.moveItem(at: tempURL, to: targetURL)

// ALSO GOOD — Foundation's built-in atomic option
try data.write(to: targetURL, options: .atomic)
```

## File locking: avoid TOCTOU and always set a timeout

When using `flock()` or any advisory lock:
- Never check-then-act (TOCTOU). Acquire the lock, then perform the operation, then release.
- Always set a timeout on lock acquisition. A hung process holding a lock must not block all future runs forever.
- Use `defer` to guarantee unlock.

```swift
// GOOD pattern
let fd = open(path, O_RDWR | O_CREAT, 0o644)
guard fd >= 0 else { throw IOError.cannotOpen(path) }
defer { close(fd) }

// Non-blocking attempt with retry + timeout
let deadline = Date().addingTimeInterval(5.0)
while flock(fd, LOCK_EX | LOCK_NB) != 0 {
    guard Date() < deadline else { throw IOError.lockTimeout(path) }
    try await Task.sleep(for: .milliseconds(50))
}
defer { flock(fd, LOCK_UN) }
```

## Efficient collection merges

When merging two collections by a key, use a dictionary for O(n+m) lookup instead of nested loops O(n*m).

```swift
// BAD — O(n*m)
for new in incoming {
    if let idx = existing.firstIndex(where: { $0.id == new.id }) {
        existing[idx] = new
    } else {
        existing.append(new)
    }
}

// GOOD — O(n+m)
var indexById = Dictionary(uniqueKeysWithValues: existing.enumerated().map { ($0.element.id, $0.offset) })
for item in incoming {
    if let idx = indexById[item.id] {
        existing[idx] = item
    } else {
        indexById[item.id] = existing.count
        existing.append(item)
    }
}
```
