import Testing
import Foundation
@testable import AIUsagesTrackers

@Suite("AppPidGuard")
struct AppPidGuardTests {

    private struct FixedBootTimeProvider: BootTimeProvider {
        let date: Date
        func bootTime() -> Date? { date }
    }

    private func makeGuard(in dir: URL, bootTime: Date) -> AppPidGuard {
        AppPidGuard(cacheDir: dir.path, bootTimeProvider: FixedBootTimeProvider(date: bootTime))
    }

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePIDFile(pid: Int32, to dir: URL) throws {
        let url = dir.appendingPathComponent("app.pid")
        try Data("\(pid)\n".utf8).write(to: url, options: .atomic)
    }

    private func spawnAndWaitForDeadPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    @Test("no existing PID file — takes the slot")
    func noFileAcquiresSlot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let guard_ = makeGuard(in: dir, bootTime: Date(timeIntervalSinceNow: -3600))
        try guard_.acquire()
        defer { guard_.release() }

        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("app.pid").path))
    }

    @Test("PID file predates last boot — takes the slot even when PID is live")
    func preBootFileTakesSlot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write our own live PID; without the pre-boot check this would throw alreadyRunning.
        try writePIDFile(pid: ProcessInfo.processInfo.processIdentifier, to: dir)

        // Setting boot time in the future makes any file written before now look pre-boot.
        let guard_ = makeGuard(in: dir, bootTime: Date(timeIntervalSinceNow: 60))
        try guard_.acquire()
        defer { guard_.release() }
    }

    @Test("post-boot PID file with live PID — throws alreadyRunning")
    func livePostBootPIDThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writePIDFile(pid: ProcessInfo.processInfo.processIdentifier, to: dir)

        let guard_ = makeGuard(in: dir, bootTime: Date(timeIntervalSinceNow: -3600))
        #expect(throws: AppPidGuardError.self) {
            try guard_.acquire()
        }
    }

    @Test("post-boot PID file with dead PID — takes the slot")
    func deadPostBootPIDTakesSlot() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pid = try spawnAndWaitForDeadPID()
        try writePIDFile(pid: pid, to: dir)

        let guard_ = makeGuard(in: dir, bootTime: Date(timeIntervalSinceNow: -3600))
        try guard_.acquire()
        defer { guard_.release() }
    }
}
