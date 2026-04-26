import Foundation

/// Drives `SnapshotRecorder` on a fixed cadence, independent of the user's
/// polling interval. Reads the current file state from `UsagesFileManager` and
/// forwards it to the recorder every tick.
public actor SnapshotScheduler {
    /// The roadmap pins the snapshot cadence at once per minute, decoupled from
    /// the user-configurable `RefreshInterval`. Kept internal so tests can override
    /// via the initializer.
    public static let defaultInterval: Duration = .seconds(60)

    private let fileManager: UsagesFileManager
    private let recorder: any SnapshotRecording
    private let clock: ClockProvider
    private let interval: Duration
    private let logger: FileLogger

    private var task: Task<Void, Never>?

    public init(
        fileManager: UsagesFileManager,
        recorder: any SnapshotRecording,
        clock: ClockProvider = SystemClock(),
        interval: Duration = SnapshotScheduler.defaultInterval,
        logger: FileLogger = Loggers.app
    ) {
        self.fileManager = fileManager
        self.recorder = recorder
        self.clock = clock
        self.interval = interval
        self.logger = logger
    }

    public func start() {
        guard task == nil else {
            logger.log(.debug, "SnapshotScheduler: already running")
            return
        }
        let interval = self.interval
        task = Task { [self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                await self.tickOnce()
            }
        }
        logger.log(.info, "SnapshotScheduler: started")
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Single tick — public so callers can force a snapshot and tests can avoid
    /// waiting on the real timer.
    public func tickOnce() async {
        let file = await fileManager.read()
        await recorder.recordSnapshot(from: file, now: clock.now())
    }
}
