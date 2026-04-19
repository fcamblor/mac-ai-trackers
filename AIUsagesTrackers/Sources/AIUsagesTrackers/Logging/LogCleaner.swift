import Foundation

public actor LogCleaner {
    public static let retentionSeconds: TimeInterval = 7 * 24 * 60 * 60
    public static let tickIntervalDuration: Duration = .seconds(24 * 60 * 60)

    private let loggers: [FileLogger]
    private let retentionSeconds: TimeInterval
    private let tickInterval: Duration
    private let now: @Sendable () -> Date
    private let sleepFn: @Sendable (Duration) async throws -> Void
    private let logger: FileLogger
    private var task: Task<Void, Never>?

    public init(
        loggers: [FileLogger] = Loggers.managed,
        retentionSeconds: TimeInterval = LogCleaner.retentionSeconds,
        tickInterval: Duration = LogCleaner.tickIntervalDuration,
        now: @Sendable @escaping () -> Date = { Date() },
        sleep sleepFn: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        logger: FileLogger = Loggers.app
    ) {
        self.loggers = loggers
        self.retentionSeconds = retentionSeconds
        self.tickInterval = tickInterval
        self.now = now
        self.sleepFn = sleepFn
        self.logger = logger
    }

    public func cleanOnce() async {
        let cutoff = now().addingTimeInterval(-retentionSeconds)
        let appLogger = self.logger
        for fileLogger in loggers {
            // purgeEntries uses queue.sync internally — hop to a background
            // queue so we never block the cooperative thread pool
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try fileLogger.purgeEntries(olderThan: cutoff)
                    } catch {
                        appLogger.log(.error, "Log purge failed for \(fileLogger.filePath): \(error)")
                    }
                    continuation.resume()
                }
            }
        }
    }

    public func start() async {
        guard task == nil else {
            logger.log(.info, "Log cleaner already running")
            return
        }
        await cleanOnce()
        task = Task { [sleepFn, tickInterval, logger] in
            while !Task.isCancelled {
                do {
                    try await sleepFn(tickInterval)
                } catch is CancellationError {
                    break
                } catch {
                    logger.log(.error, "LogCleaner sleep interrupted: \(error)")
                    break
                }
                guard !Task.isCancelled else { break }
                await self.cleanOnce()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
