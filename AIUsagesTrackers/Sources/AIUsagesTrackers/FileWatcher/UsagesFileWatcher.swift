import Foundation

// MARK: - Protocol (injectable for tests)

public protocol FileWatching: Sendable {
    func changes() -> AsyncStream<Data>
}

// MARK: - Production implementation

/// Watches a single file using FS events (DispatchSource) with a polling fallback.
///
/// Hybrid strategy: a `DispatchSource.makeFileSystemObjectSource` watches for
/// `.write` events. A fallback timer re-checks every `pollInterval` seconds in
/// case FS events are missed (network mounts, fd invalidation after atomic
/// replace). Duplicate reads are suppressed by comparing modification dates.
public final class UsagesFileWatcher: FileWatching, Sendable {
    private let path: String
    private let pollInterval: TimeInterval
    private let logger: FileLogger

    public static let defaultPollSeconds: TimeInterval = 30

    public init(
        path: String,
        pollInterval: TimeInterval = UsagesFileWatcher.defaultPollSeconds,
        logger: FileLogger = Loggers.app
    ) {
        self.path = path
        self.pollInterval = pollInterval
        self.logger = logger
    }

    public func changes() -> AsyncStream<Data> {
        let path = self.path
        let pollInterval = self.pollInterval
        let logger = self.logger

        return AsyncStream { continuation in
            let watcherTask = Task {
                // Protects lastModDate from concurrent access (GCD handler + cooperative pool)
                let lock = NSLock()
                var lastModDate: Date?
                var dispatchSource: DispatchSourceFileSystemObject?
                var fileDescriptor: Int32 = -1
                // Prevents repeated warnings when the file stays unreadable across poll ticks
                var contentReadFailed = false

                func emitIfChanged() {
                    lock.lock()
                    defer { lock.unlock() }

                    let attrs: [FileAttributeKey: Any]
                    do {
                        attrs = try FileManager.default.attributesOfItem(atPath: path)
                    } catch {
                        if !contentReadFailed {
                            logger.log(.warning, "FileWatcher: attributesOfItem failed on \(path): \(error)")
                            contentReadFailed = true
                        }
                        return
                    }
                    guard let modDate = attrs[.modificationDate] as? Date else {
                        return
                    }
                    if modDate != lastModDate {
                        if let data = FileManager.default.contents(atPath: path) {
                            lastModDate = modDate
                            contentReadFailed = false
                            continuation.yield(data)
                        } else {
                            if !contentReadFailed {
                                logger.log(.warning, "FileWatcher: contents(atPath:) returned nil for \(path)")
                                contentReadFailed = true
                            }
                        }
                    }
                }

                func openSource() -> (DispatchSourceFileSystemObject, Int32)? {
                    let fd = open(path, O_EVTONLY)
                    guard fd >= 0 else {
                        logger.log(.warning, "FileWatcher: open() failed on \(path): \(String(cString: strerror(errno)))")
                        return nil
                    }
                    // If cancelled before resume(), the cancel handler won't fire — guard against fd leak
                    guard !Task.isCancelled else {
                        close(fd)
                        return nil
                    }
                    let source = DispatchSource.makeFileSystemObjectSource(
                        fileDescriptor: fd,
                        eventMask: [.write, .delete, .rename],
                        queue: DispatchQueue.global(qos: .utility)
                    )
                    source.setEventHandler { emitIfChanged() }
                    source.setCancelHandler { close(fd) }
                    source.resume()
                    return (source, fd)
                }

                emitIfChanged()

                if let (src, fd) = openSource() {
                    dispatchSource = src
                    fileDescriptor = fd
                    logger.log(.debug, "FileWatcher: FS events active on \(path)")
                } else {
                    logger.log(.warning, "FileWatcher: FS source unavailable on \(path), using poll-only mode")
                }

                while !Task.isCancelled {
                    // CancellationError swallowed intentionally; checked on next loop iteration
                    // Cap at ~292 years to prevent UInt64 overflow for large pollInterval values
                    let maxNanos: Double = Double(UInt64.max)
                    let refreshNanos = UInt64(min(pollInterval * 1_000_000_000, maxNanos))
                    try? await Task.sleep(nanoseconds: refreshNanos)
                    guard !Task.isCancelled else { break }

                    emitIfChanged()

                    // Re-establish FS watcher if fd went stale (file was replaced).
                    // fcntl(F_GETFD) only checks the fd is open, not that it still refers to
                    // the file at `path`. After an atomic rename the old fd stays open (valid)
                    // but points to the displaced inode, so FS events for the new file are
                    // missed until the next poll. Inode comparison catches this case.
                    // FileManager is used for the path inode to avoid Darwin.stat() ambiguity.
                    let pathAttrs = try? FileManager.default.attributesOfItem(atPath: path)
                    let pathInode = pathAttrs.flatMap { $0[.systemFileNumber] as? Int }.map(UInt64.init)
                    var fdStatBuf = stat()
                    let fdInode: UInt64? = (fileDescriptor >= 0 && fstat(fileDescriptor, &fdStatBuf) == 0)
                        ? fdStatBuf.st_ino : nil
                    let fileExists = pathInode != nil
                    let fdValid = fileExists && fdInode == pathInode
                    if fileExists && !fdValid {
                        dispatchSource?.cancel()
                        if let (src, fd) = openSource() {
                            dispatchSource = src
                            fileDescriptor = fd
                            logger.log(.debug, "FileWatcher: re-opened FS source on \(path)")
                        }
                    }
                }

                dispatchSource?.cancel()
                continuation.finish()
            }

            continuation.onTermination = { _ in watcherTask.cancel() }
        }
    }
}
