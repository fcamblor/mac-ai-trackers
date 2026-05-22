import Foundation
import Darwin
import AIUsagesTrackersLib

enum AppPidGuardError: Error, CustomStringConvertible {
    case alreadyRunning(pid: Int32, pidFilePath: String)

    var description: String {
        switch self {
        case let .alreadyRunning(pid, path):
            "Another instance is already running (PID \(pid), recorded in \(path))"
        }
    }
}

protocol BootTimeProvider {
    func bootTime() -> Date?
}

struct SystemBootTimeProvider: BootTimeProvider {
    func bootTime() -> Date? {
        var tv = timeval()
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec))
    }
}

final class AppPidGuard {
    let pidFilePath: String
    // Retained to keep signal sources alive for the process lifetime
    private var signalSources: [DispatchSourceSignal] = []
    private let bootTimeProvider: BootTimeProvider

    init(cacheDir: String, bootTimeProvider: BootTimeProvider = SystemBootTimeProvider()) {
        pidFilePath = "\(cacheDir)/app.pid"
        self.bootTimeProvider = bootTimeProvider
    }

    // Acquires the singleton slot. Throws if another live process holds it.
    func acquire() throws {
        if let data = FileManager.default.contents(atPath: pidFilePath),
           let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr)
        {
            if pidFilePreDatesLastBoot() {
                // File predates the current boot: any PID it contains is guaranteed stale regardless
                // of whether another process now holds that PID number (macOS recycles PIDs after reboot).
                Loggers.app.log(.info, "PID file at \(pidFilePath) predates last boot — stale slot, taking over")
            } else if kill(pid, 0) == 0 {
                Loggers.app.log(.warning, "PID file found at \(pidFilePath) with PID \(pid) — process is still alive, refusing to start")
                throw AppPidGuardError.alreadyRunning(pid: pid, pidFilePath: pidFilePath)
            } else {
                Loggers.app.log(.info, "PID file found at \(pidFilePath) with stale PID \(pid) (process gone) — taking the slot")
            }
        } else {
            Loggers.app.log(.debug, "No existing PID file at \(pidFilePath) — taking the slot")
        }
        let pidData = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
        try pidData.write(to: URL(fileURLWithPath: pidFilePath), options: .atomic)
        installSignalHandlers()
    }

    // Removes the PID file on clean shutdown. Failure is non-fatal (process is exiting).
    func release() {
        try? FileManager.default.removeItem(atPath: pidFilePath)
    }

    // MARK: - Private

    // Returns true when the PID file is older than the last system boot, meaning any PID it
    // records could not belong to a surviving instance of this app.
    private func pidFilePreDatesLastBoot() -> Bool {
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: pidFilePath),
            let fileDate = attrs[.modificationDate] as? Date,
            let boot = bootTimeProvider.bootTime()
        else { return false }
        return fileDate < boot
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            // Suppress default handling so DispatchSource can intercept
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                let name = sig == SIGTERM ? "SIGTERM" : "SIGINT"
                Loggers.app.log(.info, "Received \(name) — removing PID file and exiting")
                self?.release()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }
}
