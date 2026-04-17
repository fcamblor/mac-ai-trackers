import Foundation

public actor UsagePoller {
    public let connectors: [any UsageConnector]
    public let interval: Duration
    public let fileManager: UsagesFileManager
    private let logger: FileLogger

    private var pollingTask: Task<Void, Never>?

    public init(
        connectors: [any UsageConnector],
        interval: Duration = .seconds(180),
        fileManager: UsagesFileManager = UsagesFileManager.shared,
        logger: FileLogger = Loggers.app
    ) {
        self.connectors = connectors
        self.interval = interval
        self.fileManager = fileManager
        self.logger = logger
    }

    public func start() {
        guard pollingTask == nil else {
            logger.log(.warning, "Poller already running")
            return
        }
        logger.log(.info, "Starting poller with interval \(interval)")
        pollingTask = Task {
            while !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled else { break }
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        logger.log(.info, "Poller stopped")
    }

    public func pollOnce(now: Date = Date()) async {
        logger.log(.debug, "Poll tick — fetching from \(connectors.count) connector(s)")

        let existingFile = await fileManager.read()
        let intervalSeconds = Double(interval.components.seconds)
        var skippedCount = 0
        let log = self.logger

        let entries: [VendorUsageEntry] = await withTaskGroup(of: [VendorUsageEntry].self) { group in
            for connector in connectors {
                if let account = connector.resolveActiveAccount(),
                   let cached = existingFile.usages.first(where: { $0.vendor == connector.vendor && $0.account == account }),
                   let acquiredDate = cached.lastAcquiredOn?.date,
                   now.timeIntervalSince(acquiredDate) < intervalSeconds {
                    let age = Int(now.timeIntervalSince(acquiredDate))
                    logger.log(.debug, "Skipping \(connector.vendor)/\(account) — fresh (age \(age)s < \(Int(intervalSeconds))s)")
                    skippedCount += 1
                    continue
                }
                group.addTask {
                    do {
                        return try await connector.fetchUsages()
                    } catch {
                        log.log(.error, "Connector \(connector.vendor) threw: \(error)")
                        return []
                    }
                }
            }
            var all: [VendorUsageEntry] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }

        guard !entries.isEmpty else {
            if skippedCount == connectors.count {
                logger.log(.debug, "All \(connectors.count) connector(s) up-to-date — skipping file write")
            } else {
                logger.log(.warning, "No entries returned from any connector")
            }
            return
        }

        await fileManager.update(with: entries)
        logger.log(.info, "Merged \(entries.count) entry/entries into usages file")
    }
}
