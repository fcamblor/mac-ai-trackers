import Foundation

public actor CopilotActiveAccountMonitor: ActiveAccountMonitoring {
    nonisolated public let vendor: Vendor = .copilot

    // 15 s mirrors the Codex/Claude monitors — short enough to react to
    // `gh auth switch` without hammering the disk.
    public static let defaultInterval: Duration = .seconds(15)

    private let environment: [String: String]
    private let hostsFilePathOverride: String?
    private let fileManager: FileManager
    private let logger: FileLogger
    private let interval: Duration
    /// Emits the new active GitHub login so callers can invalidate any cached
    /// identity and force a fresh fetch.
    private let onActiveAccountChanged: (@Sendable (AccountEmail) async -> Void)?

    private var monitorTask: Task<Void, Never>?
    private var lastObservedLogin: AccountEmail?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hostsFilePathOverride: String? = nil,
        fileManager: FileManager = .default,
        logger: FileLogger = Loggers.copilot,
        interval: Duration = CopilotActiveAccountMonitor.defaultInterval,
        onActiveAccountChanged: (@Sendable (AccountEmail) async -> Void)? = nil
    ) {
        self.environment = environment
        self.hostsFilePathOverride = hostsFilePathOverride
        self.fileManager = fileManager
        self.logger = logger
        self.interval = interval
        self.onActiveAccountChanged = onActiveAccountChanged
    }

    public func start() {
        guard monitorTask == nil else {
            logger.log(.warning, "Copilot active-account monitor already running")
            return
        }
        logger.log(.info, "Starting Copilot active-account monitor with interval \(interval)")
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
        logger.log(.info, "Copilot active-account monitor stopped")
    }

    public func checkOnce() async {
        guard let login = readActiveLogin() else {
            // `gh auth switch` rewrites hosts.yml; during the brief window between
            // unlink and relink we may see no `user:` line. Trust positive signals
            // only — preserve the previous observed state otherwise.
            logger.log(.debug, "Copilot active login unresolved — keeping previous state")
            return
        }

        let previous = lastObservedLogin
        lastObservedLogin = login
        // Skip the first resolution (startup) to avoid a redundant forced poll
        // — only fire on genuine switches.
        if let previous, previous != login {
            logger.log(.info, "Copilot active login switched: \(login)")
            await onActiveAccountChanged?(login)
        }
    }

    private func readActiveLogin() -> AccountEmail? {
        for path in hostsFileCandidatePaths() where fileManager.fileExists(atPath: path) {
            guard let data = fileManager.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8) else {
                logger.log(.debug, "Failed to read gh hosts.yml at \(path)")
                continue
            }
            let config = CopilotCredentialLocator.parseHostsYAML(text)
            if let login = config.activeLogin, !login.isEmpty {
                return AccountEmail(rawValue: login)
            }
        }
        return nil
    }

    private func hostsFileCandidatePaths() -> [String] {
        if let override = hostsFilePathOverride {
            return [override]
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        if let ghConfigDir = environment["GH_CONFIG_DIR"], !ghConfigDir.isEmpty {
            paths.append("\(ghConfigDir)/hosts.yml")
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            paths.append("\(xdg)/gh/hosts.yml")
        }
        paths.append("\(home)/.config/gh/hosts.yml")
        return paths
    }
}
