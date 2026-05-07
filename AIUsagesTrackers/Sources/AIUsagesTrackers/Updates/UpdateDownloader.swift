import Foundation
import CryptoKit

/// Events emitted while preparing a manual install: progress while bytes are
/// being downloaded, then a single `verifying` and `extracting` notification.
public enum UpdateDownloadEvent: Sendable, Equatable {
    case progress(receivedBytes: Int64, totalBytes: Int64?)
    case verifying
    case extracting
}

public typealias UpdateDownloadEventHandler = @Sendable (UpdateDownloadEvent) -> Void

public enum UpdateDownloaderError: Error, Equatable {
    case downloadFailed(message: String)
    case unexpectedHTTPStatus(code: Int)
    case shaDownloadFailed(message: String)
    case shaParseFailed(raw: String)
    case shaMismatch(expected: String, actual: String)
    case extractionFailed(message: String)
    case noAppBundleInArchive
    case fileSystemError(message: String)
}

/// Downloads a release zip with progress callbacks, verifies its SHA256, then
/// extracts the contained `.app` bundle into a staging directory. The staged
/// path is returned so the caller can swap it into place via the finalize
/// script after the user confirms the restart.
public actor UpdateDownloader {
    private let sessionConfiguration: URLSessionConfiguration
    private let stagingRoot: URL
    private let process: ProcessRunning
    private let fileManager: FileManager
    private let logger: FileLogger
    private let dittoPath: String

    public init(
        sessionConfiguration: URLSessionConfiguration = .default,
        stagingRoot: URL? = nil,
        process: ProcessRunning = FoundationProcessRunner(),
        fileManager: FileManager = .default,
        logger: FileLogger = Loggers.app,
        dittoPath: String = "/usr/bin/ditto"
    ) {
        self.sessionConfiguration = sessionConfiguration
        self.stagingRoot = stagingRoot ?? UpdateInstaller.defaultStagingDirectory()
        self.process = process
        self.fileManager = fileManager
        self.logger = logger
        self.dittoPath = dittoPath
    }

    /// Downloads the release zip, verifies its SHA256 (when available), extracts
    /// it, and returns the path to the staged `.app` bundle ready to swap in.
    public func downloadAndStage(
        update: AvailableUpdate,
        onEvent: @escaping UpdateDownloadEventHandler
    ) async throws -> URL {
        let workDir = stagingRoot.appendingPathComponent(update.version.rawValue, isDirectory: true)
        // Start clean: a previous failed attempt may have left half-extracted state.
        try? fileManager.removeItem(at: workDir)
        do {
            try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            throw UpdateDownloaderError.fileSystemError(message: "create staging dir: \(error)")
        }

        let zipURL = workDir.appendingPathComponent("release.zip")
        try await downloadFile(from: update.downloadURL, to: zipURL, onEvent: onEvent)

        if let shaURL = update.sha256URL {
            onEvent(.verifying)
            try await verifySHA256(file: zipURL, expectedFrom: shaURL, workDir: workDir)
        }

        onEvent(.extracting)
        let extractedDir = workDir.appendingPathComponent("extracted", isDirectory: true)
        try? fileManager.removeItem(at: extractedDir)
        try fileManager.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        try await extractZip(zipURL: zipURL, into: extractedDir)

        guard let stagedApp = try findAppBundle(in: extractedDir) else {
            throw UpdateDownloaderError.noAppBundleInArchive
        }
        logger.log(.info, "Update staged at \(stagedApp.path)")
        return stagedApp
    }

    // MARK: - Download

    private func downloadFile(
        from url: URL,
        to destination: URL,
        onEvent: @escaping UpdateDownloadEventHandler
    ) async throws {
        let observer = DownloadObserver(onEvent: onEvent)
        let session = URLSession(configuration: sessionConfiguration, delegate: observer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let tempURL: URL
        do {
            tempURL = try await observer.runDownload(session: session, url: url)
        } catch let error as UpdateDownloaderError {
            throw error
        } catch {
            throw UpdateDownloaderError.downloadFailed(message: String(describing: error))
        }

        // The system removes the temp file once the delegate returns, so the
        // observer already moved it to a stable path; here we just rename it
        // into the destination atomically.
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: tempURL, to: destination)
        } catch {
            throw UpdateDownloaderError.fileSystemError(message: "move downloaded zip: \(error)")
        }
    }

    // MARK: - SHA256

    private func verifySHA256(file: URL, expectedFrom shaURL: URL, workDir: URL) async throws {
        let data: Data
        do {
            let (raw, response) = try await URLSession(configuration: sessionConfiguration).data(from: shaURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateDownloaderError.unexpectedHTTPStatus(code: http.statusCode)
            }
            data = raw
        } catch let error as UpdateDownloaderError {
            throw error
        } catch {
            throw UpdateDownloaderError.shaDownloadFailed(message: String(describing: error))
        }
        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Format is typically "<hex>  filename" or just "<hex>".
        guard let firstToken = raw.split(whereSeparator: { $0.isWhitespace }).first else {
            throw UpdateDownloaderError.shaParseFailed(raw: raw)
        }
        let expected = String(firstToken).lowercased()
        guard expected.allSatisfy({ $0.isHexDigit }), expected.count == 64 else {
            throw UpdateDownloaderError.shaParseFailed(raw: raw)
        }
        let actual = try sha256Hex(of: file)
        guard actual.lowercased() == expected else {
            throw UpdateDownloaderError.shaMismatch(expected: expected, actual: actual)
        }
    }

    private func sha256Hex(of fileURL: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw UpdateDownloaderError.fileSystemError(message: "open zip for hashing: \(error)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        // 1 MiB chunks: large enough to amortize syscalls, small enough to keep
        // the resident set in check on large zips.
        let chunkSize = 1 * 1024 * 1024
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Extract

    private func extractZip(zipURL: URL, into destDir: URL) async throws {
        let result: ProcessExecutionResult
        do {
            result = try await process.run(
                executablePath: dittoPath,
                arguments: ["-x", "-k", zipURL.path, destDir.path],
                timeoutSeconds: 120
            )
        } catch {
            throw UpdateDownloaderError.extractionFailed(message: String(describing: error))
        }
        guard !result.timedOut, result.terminationStatus == 0 else {
            throw UpdateDownloaderError.extractionFailed(
                message: "ditto exit=\(result.terminationStatus) timedOut=\(result.timedOut)"
            )
        }
    }

    private func findAppBundle(in directory: URL) throws -> URL? {
        // The zip layout is `<archive root>/AI Usages Tracker.app`, but be
        // tolerant of a single nested wrapper directory in case the build
        // pipeline ever changes.
        let directContents: [URL]
        do {
            directContents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw UpdateDownloaderError.fileSystemError(message: "list extracted dir: \(error)")
        }
        if let app = directContents.first(where: { $0.pathExtension == "app" }) {
            return app
        }
        for child in directContents where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let nested = try fileManager.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)
            if let app = nested.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        return nil
    }
}

// MARK: - Download observer

/// Bridges URLSession's delegate-based download progress callbacks to the
/// async/await world while keeping the staged temp file alive past the
/// delegate's `didFinishDownloadingTo` call (the system deletes the original
/// shortly after that callback returns).
// swiftlint:disable:next w4_unchecked_sendable — internal-only helper, all mutable state guarded by `lock`
private final class DownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onEvent: UpdateDownloadEventHandler
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var resumed = false
    private var stableURL: URL?

    init(onEvent: @escaping UpdateDownloadEventHandler) {
        self.onEvent = onEvent
        super.init()
    }

    func runDownload(session: URLSession, url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            self.continuation = cont
            let task = session.downloadTask(with: url)
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        onEvent(.progress(receivedBytes: totalBytesWritten, totalBytes: total))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession returns a temp file that gets deleted as soon as the
        // delegate method returns, so we must move it synchronously here.
        let stable = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-tracker-dl-\(UUID().uuidString).zip")
        do {
            try FileManager.default.moveItem(at: location, to: stable)
        } catch {
            resume(.failure(UpdateDownloaderError.fileSystemError(message: "stage download: \(error)")))
            return
        }
        lock.lock()
        stableURL = stable
        lock.unlock()

        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: stable)
            resume(.failure(UpdateDownloaderError.unexpectedHTTPStatus(code: http.statusCode)))
            return
        }
        resume(.success(stable))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resume(.failure(UpdateDownloaderError.downloadFailed(message: String(describing: error))))
        }
        // Success path is handled in didFinishDownloadingTo; no-op here.
    }

    private func resume(_ result: Result<URL, Error>) {
        lock.lock()
        guard !resumed, let cont = continuation else { lock.unlock(); return }
        resumed = true
        continuation = nil
        lock.unlock()
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let err): cont.resume(throwing: err)
        }
    }
}
