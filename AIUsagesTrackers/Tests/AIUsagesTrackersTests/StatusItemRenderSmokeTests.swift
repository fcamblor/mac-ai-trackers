import Foundation
import Testing
@testable import AIUsagesTrackersLib

/// Integration smoke test that launches the compiled AIUsagesTrackers binary,
/// lets it idle for a few seconds in a sandboxed cache directory, and asserts
/// that the menu bar render count exported by the running process stays low.
///
/// Before the dedup fix this counter grew to ~4800 in 8 seconds (600 renders/s
/// driven by the NSStatusItem → effectiveAppearance KVO feedback loop). After
/// the fix it stays at a handful of renders at idle, even with the appearance
/// observer firing many times.
///
/// Opt-in: set `RUN_SMOKE_TESTS=1` to run. The test is skipped by default
/// because it spawns a real AppKit process, which is intrusive (Keychain
/// prompts on a fresh machine, ~10 s wall time, requires a graphical session
/// for NSStatusBar) and may behave inconsistently on headless CI runners
/// where the `NSStatusItemReplicantShadowView` machinery is not exercised.
@MainActor
@Suite("Status item render smoke")
struct StatusItemRenderSmokeTests {

    /// Wall-clock window we let the app idle for. Long enough to observe four
    /// 2 s export ticks; the test reads the *last* counter value written.
    private static let observationWindowSeconds: UInt64 = 8

    /// Maximum renders we tolerate over the observation window. With the fix
    /// in place we expect 1–5 (initial paint + a handful of legitimate
    /// store mutations). Pre-fix value was ~4800.
    private static let renderCountUpperBound = 100

    @Test(
        "Render count stays bounded while the app idles",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_SMOKE_TESTS"] != nil)
    )
    func renderCountStaysBoundedAtIdle() async throws {
        let exeURL = try Self.locateAppBinary()
        let sandboxDir = try Self.makeSandboxDir()
        defer { try? FileManager.default.removeItem(at: sandboxDir) }

        let counterFile = sandboxDir.appendingPathComponent("render-count")

        let process = Process()
        process.executableURL = exeURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["AI_TRACKER_CACHE_DIR"] = sandboxDir.path
        env["AI_TRACKER_EXPORT_RENDER_COUNT"] = counterFile.path
        // Suppress connector noise — the smoke test is about the render loop only.
        env["AI_TRACKER_LOG_LEVEL"] = "error"
        process.environment = env

        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        // swiftlint:disable:next w3_task_sleep_literal_in_tests — wall-clock wait by design
        try await Task.sleep(nanoseconds: Self.observationWindowSeconds * 1_000_000_000)

        guard FileManager.default.fileExists(atPath: counterFile.path) else {
            Issue.record("render-count file never appeared at \(counterFile.path) — the app likely failed to start; check sandbox logs at \(sandboxDir.path)")
            return
        }

        let raw = try String(contentsOf: counterFile, encoding: .utf8)
        let lastLine = raw.split(whereSeparator: \.isNewline).last.map(String.init) ?? "0"
        let count = Int(lastLine) ?? -1

        #expect(
            count >= 0 && count < Self.renderCountUpperBound,
            "render count grew to \(count) in \(Self.observationWindowSeconds)s — the NSStatusItem feedback loop likely returned"
        )
    }

    // MARK: - Helpers

    /// Locates the compiled `AIUsagesTrackers` executable. Priority:
    /// 1. explicit `AIUT_BINARY_PATH` env var (CI sets this after building),
    /// 2. `.build/<triple>/debug/AIUsagesTrackers` relative to cwd,
    /// 3. `.build/<triple>/release/AIUsagesTrackers` relative to cwd.
    static func locateAppBinary() throws -> URL {
        if let explicit = ProcessInfo.processInfo.environment["AIUT_BINARY_PATH"],
           !explicit.isEmpty,
           FileManager.default.isExecutableFile(atPath: explicit)
        {
            return URL(fileURLWithPath: explicit)
        }
        let cwd = FileManager.default.currentDirectoryPath
        let triple = "arm64-apple-macosx"
        let candidates = [
            "\(cwd)/.build/\(triple)/debug/AIUsagesTrackers",
            "\(cwd)/.build/\(triple)/release/AIUsagesTrackers"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw SmokeTestError.binaryNotFound(searched: candidates.joined(separator: ", "))
    }

    static func makeSandboxDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aiut-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum SmokeTestError: Error, CustomStringConvertible {
    case binaryNotFound(searched: String)

    var description: String {
        switch self {
        case .binaryNotFound(let path):
            "AIUsagesTrackers binary not found at \(path) — run `swift build` before the smoke test"
        }
    }
}
