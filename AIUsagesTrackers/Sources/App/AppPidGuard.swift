import Foundation

enum AppPidGuardError: Error, CustomStringConvertible {
    case alreadyRunning(pid: Int32, pidFilePath: String)

    var description: String {
        switch self {
        case let .alreadyRunning(pid, path):
            "Another instance is already running (PID \(pid), recorded in \(path))"
        }
    }
}

struct AppPidGuard {
    let pidFilePath: String

    init(cacheDir: String) {
        pidFilePath = "\(cacheDir)/app.pid"
    }

    // Acquires the singleton slot. Throws if another live process holds it.
    func acquire() throws {
        if let data = FileManager.default.contents(atPath: pidFilePath),
           let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr),
           kill(pid, 0) == 0
        {
            throw AppPidGuardError.alreadyRunning(pid: pid, pidFilePath: pidFilePath)
        }
        // Either no PID file, stale PID (process gone), or unreadable — take the slot.
        let pidData = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        try pidData.write(to: URL(fileURLWithPath: pidFilePath), options: .atomic)
    }

    // Removes the PID file on clean shutdown. Failure is non-fatal (process is exiting).
    func release() {
        try? FileManager.default.removeItem(atPath: pidFilePath)
    }
}
