import Foundation

public enum BrewUpgradeEvent: Sendable, Equatable {
    case outputLine(String)
}

public typealias BrewUpgradeEventHandler = @Sendable (BrewUpgradeEvent) -> Void

public enum BrewUpgradeRunnerError: Error, Equatable {
    case launchFailed(message: String)
    case nonZeroExit(status: Int32, lastLine: String?)
}

/// Runs `brew upgrade --cask <name>` in-process so the caller can stream the
/// progress lines into the UI. Unlike the previous detached-script approach,
/// the app stays alive during the upgrade — `brew` happily replaces the
/// currently-running `.app` bundle on macOS (the running mach-o is mmaped, so
/// the on-disk swap doesn't fault the live process).
public actor BrewUpgradeRunner {
    private let logger: FileLogger

    public init(logger: FileLogger = Loggers.app) {
        self.logger = logger
    }

    /// Runs `brew update` (best effort, errors ignored) followed by
    /// `brew upgrade --cask <caskName>`. Each non-empty stdout/stderr line is
    /// forwarded through `onEvent`. Throws on non-zero exit from upgrade.
    public func runUpgrade(
        brewExecutablePath: String,
        caskName: String,
        onEvent: @escaping BrewUpgradeEventHandler
    ) async throws {
        // `brew update` is a courtesy refresh: failures (offline, GitHub
        // throttling) shouldn't block the actual upgrade attempt.
        _ = try? await runStreaming(
            executablePath: brewExecutablePath,
            arguments: ["update"],
            onEvent: onEvent
        )

        let result = try await runStreaming(
            executablePath: brewExecutablePath,
            arguments: ["upgrade", "--cask", caskName],
            onEvent: onEvent
        )
        guard result.status == 0 else {
            logger.log(.warning, "brew upgrade exit=\(result.status) lastLine=\(result.lastLine ?? "")")
            throw BrewUpgradeRunnerError.nonZeroExit(status: result.status, lastLine: result.lastLine)
        }
    }

    private struct StreamingResult: Sendable {
        let status: Int32
        let lastLine: String?
    }

    private func runStreaming(
        executablePath: String,
        arguments: [String],
        onEvent: @escaping BrewUpgradeEventHandler
    ) async throws -> StreamingResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<StreamingResult, Error>) in
            DispatchQueue.global().async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = stderr

                let collector = LineCollector(onEvent: onEvent)
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { return }
                    collector.feed(chunk)
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { return }
                    collector.feed(chunk)
                }

                do {
                    try process.run()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: BrewUpgradeRunnerError.launchFailed(message: String(describing: error)))
                    return
                }
                process.waitUntilExit()
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                collector.flushTrailing()

                cont.resume(returning: StreamingResult(
                    status: process.terminationStatus,
                    lastLine: collector.lastLine
                ))
            }
        }
    }
}

/// Buffers raw bytes coming off two pipes, splits on newlines, and forwards
/// each non-empty line. The trailing partial chunk (no final newline) is
/// emitted by `flushTrailing()` after the process exits.
// swiftlint:disable:next w4_unchecked_sendable — internal helper, all mutable state guarded by lock
private final class LineCollector: @unchecked Sendable {
    private let onEvent: BrewUpgradeEventHandler
    private let lock = NSLock()
    private var buffer = Data()
    private var _lastLine: String?

    init(onEvent: @escaping BrewUpgradeEventHandler) {
        self.onEvent = onEvent
    }

    var lastLine: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastLine
    }

    func feed(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                _lastLine = line
                lines.append(line)
            }
        }
        lock.unlock()
        for line in lines { onEvent(.outputLine(line)) }
    }

    func flushTrailing() {
        lock.lock()
        let leftover = buffer
        buffer.removeAll()
        lock.unlock()
        if leftover.isEmpty { return }
        let line = String(decoding: leftover, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return }
        lock.lock()
        _lastLine = line
        lock.unlock()
        onEvent(.outputLine(line))
    }
}
