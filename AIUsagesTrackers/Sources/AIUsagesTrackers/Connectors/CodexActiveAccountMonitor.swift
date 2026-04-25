import Foundation

public actor CodexActiveAccountMonitor {
    // 15 s: short enough to react to account switches without hammering the disk.
    public static let defaultInterval: Duration = .seconds(15)

    private let codexHomePath: String?
    private let fileManager: FileManager
    private let logger: FileLogger
    private let interval: Duration
    /// Emits only the stable `account_id` switch signal so callers can invalidate
    /// any derived email cache and force a fresh fetch.
    private let onActiveAccountChanged: (@Sendable (AccountId) async -> Void)?

    private var monitorTask: Task<Void, Never>?
    private var lastObservedAccountId: AccountId?

    public init(
        codexHomePath: String? = nil,
        fileManager: FileManager = .default,
        logger: FileLogger = Loggers.codex,
        interval: Duration = CodexActiveAccountMonitor.defaultInterval,
        onActiveAccountChanged: (@Sendable (AccountId) async -> Void)? = nil
    ) {
        self.codexHomePath = codexHomePath ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
        self.fileManager = fileManager
        self.logger = logger
        self.interval = interval
        self.onActiveAccountChanged = onActiveAccountChanged
    }

    public func start() {
        guard monitorTask == nil else {
            logger.log(.warning, "Codex active-account monitor already running")
            return
        }
        logger.log(.info, "Starting Codex active-account monitor with interval \(interval)")
        monitorTask = Task {
            while !Task.isCancelled {
                await self.checkOnce()
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled else { break }
            }
        }
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        logger.log(.info, "Codex active-account monitor stopped")
    }

    public func checkOnce() async {
        guard let accountId = readAccountId() else {
            // Transient state during `codex login` — auth.json may be absent briefly.
            // Only trust positive signals; preserve the previous observed state otherwise.
            logger.log(.debug, "Codex account ID unresolved — keeping previous state")
            return
        }

        let previous = lastObservedAccountId
        lastObservedAccountId = accountId
        // Skip the callback on the first resolution (startup) — only fire on genuine switches.
        if let previous, previous != accountId {
            logger.log(.info, "Codex account switched: \(accountId)")
            await onActiveAccountChanged?(accountId)
        }
    }

    private func readAccountId() -> AccountId? {
        let home = fileManager.homeDirectoryForCurrentUser.path

        var candidates: [String] = []
        if let codexHome = codexHomePath {
            candidates.append("\(codexHome)/auth.json")
        }
        candidates.append("\(home)/.config/codex/auth.json")
        candidates.append("\(home)/.codex/auth.json")

        for path in candidates where fileManager.fileExists(atPath: path) {
            guard let data = fileManager.contents(atPath: path) else { continue }
            let jsonObject: Any
            do {
                jsonObject = try JSONSerialization.jsonObject(with: data)
            } catch {
                logger.log(.debug, "Failed to parse Codex auth at \(path): \(error)")
                continue
            }
            guard let json = jsonObject as? [String: Any],
                  let tokens = json["tokens"] as? [String: Any],
                  let accountId = tokens["account_id"] as? String,
                  !accountId.isEmpty else { continue }
            return AccountId(rawValue: accountId)
        }
        return nil
    }
}
