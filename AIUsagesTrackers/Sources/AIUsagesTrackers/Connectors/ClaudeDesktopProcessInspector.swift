import Foundation

/// Reports which Claude Desktop profile directories currently have a running
/// app instance. Unlike the `claude` CLI (a single active account), several
/// Claude Desktop apps can run at once — one per `--user-data-dir` — so this
/// returns a *set* of active profile paths, and a profile may legitimately be
/// inactive (no running instance).
public protocol ClaudeDesktopProcessInspecting: Sendable {
    /// Standardized absolute paths of the profile directories whose Claude
    /// Desktop app is currently running.
    func activeProfilePaths() async -> Set<String>
}

/// Default inspector backed by `/bin/ps`. It matches the Electron main process
/// (`…/Claude.app/Contents/MacOS/Claude`) and reads its `--user-data-dir`; a
/// main process without that flag is the default profile.
public struct PSClaudeDesktopProcessInspector: ClaudeDesktopProcessInspecting {
    public static let defaultTimeoutSeconds = 5
    /// The default profile directory Claude Desktop uses when launched with no
    /// `--user-data-dir`, relative to home.
    public static let defaultProfileRelativePath = "Library/Application Support/Claude"
    /// Suffix of the Electron main executable path. The bundled Claude Code CLI
    /// is `…/MacOS/claude` (lower-case) and helper processes are
    /// `…/MacOS/Claude Helper (…)`, so an exact suffix match on the first token
    /// excludes both.
    private static let mainExecutableSuffix = "/Claude.app/Contents/MacOS/Claude"

    private let processRunner: ProcessRunning
    private let homeDirectoryPath: String
    private let timeoutSeconds: Int
    private let logger: FileLogger

    public init(
        processRunner: ProcessRunning = FoundationProcessRunner(),
        homeDirectoryPath: String? = nil,
        timeoutSeconds: Int = PSClaudeDesktopProcessInspector.defaultTimeoutSeconds,
        logger: FileLogger = Loggers.claudeDesktop
    ) {
        self.processRunner = processRunner
        self.homeDirectoryPath = homeDirectoryPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.timeoutSeconds = timeoutSeconds
        self.logger = logger
    }

    public func activeProfilePaths() async -> Set<String> {
        let result: ProcessExecutionResult
        do {
            result = try await processRunner.run(
                executablePath: "/bin/ps",
                arguments: ["-axww", "-o", "args="],
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            logger.log(.warning, "Process inspection failed: \(error)")
            return []
        }
        guard !result.timedOut, result.terminationStatus == 0,
              let output = String(data: result.stdout, encoding: .utf8) else {
            return []
        }
        let defaultPath = ("\(homeDirectoryPath)/\(Self.defaultProfileRelativePath)" as NSString).standardizingPath
        return Self.parseActivePaths(psOutput: output, defaultProfilePath: defaultPath)
    }

    /// Parses `ps -o args=` output into the set of active profile directories.
    /// Exposed for testing with synthetic process tables.
    static func parseActivePaths(psOutput: String, defaultProfilePath: String) -> Set<String> {
        var active: Set<String> = []
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let executable = trimmed.split(separator: " ", maxSplits: 1).first,
                  executable.hasSuffix(mainExecutableSuffix) else {
                continue
            }
            if let dir = userDataDir(fromArgs: trimmed) {
                active.insert((dir as NSString).standardizingPath)
            } else {
                active.insert(defaultProfilePath)
            }
        }
        return active
    }

    /// Extracts the `--user-data-dir` value, supporting both `--user-data-dir=X`
    /// and `--user-data-dir X` forms. Returns nil when the flag is absent.
    static func userDataDir(fromArgs args: String) -> String? {
        let flag = "--user-data-dir"
        guard let range = args.range(of: flag) else { return nil }
        let rest = args[range.upperBound...]
        if rest.first == "=" {
            let value = rest.dropFirst()
            return String(value.prefix(while: { $0 != " " }))
        }
        if rest.first == " " {
            let value = rest.dropFirst()
            let token = String(value.prefix(while: { $0 != " " }))
            return token.isEmpty ? nil : token
        }
        return nil
    }
}
