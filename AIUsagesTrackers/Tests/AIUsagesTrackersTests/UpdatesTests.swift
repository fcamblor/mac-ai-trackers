import Foundation
import Testing
@testable import AIUsagesTrackersLib

// MARK: - AppVersion

@Suite("AppVersion")
struct AppVersionTests {
    @Test("parses semver with optional v prefix")
    func parses() {
        let a = AppVersion(string: "1.2.3")
        let b = AppVersion(string: "v1.2.3")
        #expect(a?.major == 1 && a?.minor == 2 && a?.patch == 3)
        #expect(b?.rawValue == "1.2.3")
    }

    @Test("comparison ignores pre-release suffixes")
    func compares() {
        let v123 = AppVersion(string: "1.2.3")!
        let v124 = AppVersion(string: "1.2.4")!
        let v200 = AppVersion(string: "v2.0.0")!
        let v123beta = AppVersion(string: "1.2.3-beta")!
        #expect(v123 < v124)
        #expect(v124 < v200)
        // Pre-release suffix is preserved in rawValue but the parsed core is equal.
        #expect(!(v123 < v123beta) && !(v123beta < v123))
    }

    @Test("returns nil on garbage")
    func rejectsGarbage() {
        #expect(AppVersion(string: "") == nil)
        #expect(AppVersion(string: "abc") == nil)
    }

    @Test("missing minor / patch default to zero")
    func partial() {
        let v = AppVersion(string: "1")
        #expect(v?.major == 1 && v?.minor == 0 && v?.patch == 0)
    }
}

// MARK: - UpdateChecker

// swiftlint:disable:next w4_unchecked_sendable — URLProtocol subclass; static state accessed only from this @Suite(.serialized) suite
final class UpdatesMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?
    nonisolated(unsafe) static var errorToThrow: Error?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let error = Self.errorToThrow {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let handler = Self.handler else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let (data, response) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("UpdateChecker", .serialized)
struct UpdateCheckerTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdatesMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeChecker(session: URLSession) -> UpdateChecker {
        let dir = NSTemporaryDirectory() + "ai-tracker-updates-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let logger = FileLogger(filePath: "\(dir)/test.log", minLevel: .debug)
        return UpdateChecker(
            session: session,
            endpointURLString: "https://api.github.com/repos/test/test/releases/latest",
            logger: logger
        )
    }

    private func mockJSON(_ body: String, status: Int = 200) {
        UpdatesMockURLProtocol.errorToThrow = nil
        UpdatesMockURLProtocol.handler = { _ in
            let data = body.data(using: .utf8)!
            let resp = HTTPURLResponse(
                url: URL(string: "https://api.github.com")!,
                statusCode: status, httpVersion: nil, headerFields: nil
            )!
            return (data, resp)
        }
    }

    private static let releaseBody: String = """
    {
      "tag_name": "v1.5.0",
      "html_url": "https://github.com/test/test/releases/tag/v1.5.0",
      "published_at": "2026-04-22T10:15:00Z",
      "assets": [
        {"name": "AI-Usages-Tracker.zip", "browser_download_url": "https://example.com/zip"},
        {"name": "AI-Usages-Tracker.zip.sha256", "browser_download_url": "https://example.com/sha"}
      ]
    }
    """

    @Test("returns AvailableUpdate when remote is newer")
    func newerVersion() async throws {
        mockJSON(Self.releaseBody)
        let checker = makeChecker(session: makeSession())
        let result = try await checker.checkForUpdate(currentVersion: AppVersion(string: "1.4.0")!)
        #expect(result.latestVersion.rawValue == "1.5.0")
        #expect(result.update?.version.rawValue == "1.5.0")
        #expect(result.update?.downloadURL.absoluteString == "https://example.com/zip")
        #expect(result.update?.sha256URL?.absoluteString == "https://example.com/sha")
        #expect(result.update?.releaseURL.absoluteString == "https://github.com/test/test/releases/tag/v1.5.0")
    }

    @Test("returns nil update when remote equals current but exposes latest version")
    func equalVersion() async throws {
        mockJSON(Self.releaseBody)
        let checker = makeChecker(session: makeSession())
        let result = try await checker.checkForUpdate(currentVersion: AppVersion(string: "1.5.0")!)
        #expect(result.update == nil)
        #expect(result.latestVersion.rawValue == "1.5.0")
    }

    @Test("returns nil update when current is ahead but exposes latest version")
    func currentAhead() async throws {
        mockJSON(Self.releaseBody)
        let checker = makeChecker(session: makeSession())
        let result = try await checker.checkForUpdate(currentVersion: AppVersion(string: "2.0.0")!)
        #expect(result.update == nil)
        #expect(result.latestVersion.rawValue == "1.5.0")
    }

    @Test("HTTP non-200 throws unexpectedResponse")
    func httpError() async throws {
        mockJSON("{}", status: 503)
        let checker = makeChecker(session: makeSession())
        await #expect(throws: UpdateCheckerError.self) {
            try await checker.checkForUpdate(currentVersion: AppVersion(string: "1.0.0")!)
        }
    }

    @Test("missing zip asset throws missingDownloadAsset")
    func missingAsset() async throws {
        mockJSON("""
        {
          "tag_name": "v9.9.9",
          "html_url": "https://example.com",
          "published_at": null,
          "assets": []
        }
        """)
        let checker = makeChecker(session: makeSession())
        await #expect(throws: UpdateCheckerError.self) {
            try await checker.checkForUpdate(currentVersion: AppVersion(string: "1.0.0")!)
        }
    }

    @Test("network error throws networkError")
    func networkFailure() async throws {
        UpdatesMockURLProtocol.handler = nil
        UpdatesMockURLProtocol.errorToThrow = URLError(.notConnectedToInternet)
        defer { UpdatesMockURLProtocol.errorToThrow = nil }
        let checker = makeChecker(session: makeSession())
        await #expect(throws: UpdateCheckerError.self) {
            try await checker.checkForUpdate(currentVersion: AppVersion(string: "1.0.0")!)
        }
    }
}

// MARK: - InstallationDetector

private struct StubProcessRunner: ProcessRunning {
    let stdout: String
    let exit: Int32
    func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult {
        ProcessExecutionResult(stdout: Data(stdout.utf8), terminationStatus: exit, timedOut: false)
    }
}

/// Returns different stdouts depending on the executed binary — used to model
/// "shell returns brew path, brew returns caskroom" in a single runner.
private struct RoutingProcessRunner: ProcessRunning {
    let route: @Sendable (String, [String]) -> (stdout: String, exit: Int32)
    func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult {
        let result = route(executablePath, arguments)
        return ProcessExecutionResult(stdout: Data(result.stdout.utf8), terminationStatus: result.exit, timedOut: false)
    }
}

private struct ThrowingProcessRunner: ProcessRunning {
    func run(executablePath: String, arguments: [String], timeoutSeconds: Int) async throws -> ProcessExecutionResult {
        throw NSError(domain: "test", code: -1)
    }
}

@Suite("InstallationDetector")
struct InstallationDetectorTests {
    @Test("returns manual when brew binary is missing")
    func noBrew() async {
        let detector = InstallationDetector(
            bundlePath: "/Applications/Foo.app",
            process: StubProcessRunner(stdout: "", exit: 0),
            homebrewBinaryPaths: ["/no/such/path"],
            pathEnvironment: nil,
            loginShellPath: nil
        )
        let info = await detector.detect()
        #expect(info.kind == .manual)
    }

    @Test("discovers brew via login shell when not in standard paths or PATH")
    func brewViaLoginShell() async throws {
        let tmp = NSTemporaryDirectory() + "brew-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let fakeBrew = tmp + "/brew"
        FileManager.default.createFile(atPath: fakeBrew, contents: Data())
        let fakeShell = tmp + "/zsh"
        FileManager.default.createFile(atPath: fakeShell, contents: Data())
        let caskroom = "\(tmp)/Caskroom"
        try FileManager.default.createDirectory(atPath: "\(caskroom)/ai-usages-tracker/1.2.3", withIntermediateDirectories: true)

        let runner = RoutingProcessRunner { exe, args in
            if exe == fakeShell, args == ["-l", "-i", "-c", "command -v brew"] {
                return (fakeBrew + "\n", 0)
            }
            if exe == fakeBrew, args == ["--caskroom"] {
                return (caskroom + "\n", 0)
            }
            return ("", 1)
        }
        let detector = InstallationDetector(
            bundlePath: "/Applications/AI Usages Tracker.app",
            process: runner,
            homebrewBinaryPaths: [],
            pathEnvironment: nil,
            loginShellPath: fakeShell
        )
        let info = await detector.detect()
        #expect(info.kind == .homebrewCask)
        #expect(await detector.brewExecutablePath() == fakeBrew)
    }

    @Test("ignores noisy login shell output when discovering brew")
    func brewViaNoisyLoginShell() async throws {
        let tmp = NSTemporaryDirectory() + "brew-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let fakeBrew = tmp + "/brew"
        FileManager.default.createFile(atPath: fakeBrew, contents: Data())
        let fakeShell = tmp + "/zsh"
        FileManager.default.createFile(atPath: fakeShell, contents: Data())

        let runner = RoutingProcessRunner { exe, args in
            if exe == fakeShell, args == ["-l", "-i", "-c", "command -v brew"] {
                return ("loading profile\n\(fakeBrew)\nprofile done\n", 0)
            }
            return ("", 1)
        }
        let detector = InstallationDetector(
            bundlePath: "/Applications/AI Usages Tracker.app",
            process: runner,
            homebrewBinaryPaths: [],
            pathEnvironment: nil,
            loginShellPath: fakeShell
        )
        #expect(await detector.brewExecutablePath() == fakeBrew)
    }

    @Test("returns homebrewCask when caskroom contains the cask directory")
    func brewMatch() async throws {
        let tmp = NSTemporaryDirectory() + "brew-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let fakeBrew = tmp + "/brew"
        FileManager.default.createFile(atPath: fakeBrew, contents: Data())

        let caskroom = "\(tmp)/Caskroom"
        try FileManager.default.createDirectory(atPath: "\(caskroom)/ai-usages-tracker/1.2.3", withIntermediateDirectories: true)
        // Cask installs the .app outside caskroom (in /Applications), so the
        // bundle path is intentionally unrelated to the caskroom directory.
        let detector = InstallationDetector(
            bundlePath: "/Applications/AI Usages Tracker.app",
            process: StubProcessRunner(stdout: caskroom + "\n", exit: 0),
            homebrewBinaryPaths: [fakeBrew],
            pathEnvironment: nil
        )
        let info = await detector.detect()
        #expect(info.kind == .homebrewCask)
    }

    @Test("returns homebrewCask when the running bundle is in the user Applications directory")
    func brewMatchInUserApplications() async throws {
        let tmp = NSTemporaryDirectory() + "brew-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let fakeBrew = tmp + "/brew"
        FileManager.default.createFile(atPath: fakeBrew, contents: Data())

        let caskroom = "\(tmp)/Caskroom"
        try FileManager.default.createDirectory(atPath: "\(caskroom)/ai-usages-tracker/1.2.3", withIntermediateDirectories: true)
        let detector = InstallationDetector(
            bundlePath: InstallationDetector.homebrewUserBundlePath,
            process: StubProcessRunner(stdout: caskroom + "\n", exit: 0),
            homebrewBinaryPaths: [fakeBrew],
            pathEnvironment: nil
        )
        let info = await detector.detect()
        #expect(info.kind == .homebrewCask)
    }

    @Test("returns manual when cask is installed but the running bundle is a manual copy")
    func installedCaskWithManualBundleCopy() async throws {
        let tmp = NSTemporaryDirectory() + "brew-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let fakeBrew = tmp + "/brew"
        FileManager.default.createFile(atPath: fakeBrew, contents: Data())

        let caskroom = "\(tmp)/Caskroom"
        try FileManager.default.createDirectory(atPath: "\(caskroom)/ai-usages-tracker/1.2.3", withIntermediateDirectories: true)
        let detector = InstallationDetector(
            bundlePath: "\(tmp)/Downloads/AI Usages Tracker.app",
            process: StubProcessRunner(stdout: caskroom + "\n", exit: 0),
            homebrewBinaryPaths: [fakeBrew],
            pathEnvironment: nil
        )
        let info = await detector.detect()
        #expect(info.kind == .manual)
    }

    @Test("returns homebrewCask when brew is found through PATH")
    func brewFromPath() async throws {
        let tmp = NSTemporaryDirectory() + "brew-\(UUID().uuidString)"
        let binDir = tmp + "/bin"
        try FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let fakeBrew = binDir + "/brew"
        FileManager.default.createFile(atPath: fakeBrew, contents: Data())

        let caskroom = "\(tmp)/Caskroom"
        try FileManager.default.createDirectory(atPath: "\(caskroom)/ai-usages-tracker/1.2.3", withIntermediateDirectories: true)
        let detector = InstallationDetector(
            bundlePath: "/Applications/AI Usages Tracker.app",
            process: StubProcessRunner(stdout: caskroom + "\n", exit: 0),
            homebrewBinaryPaths: [],
            pathEnvironment: binDir
        )
        let info = await detector.detect()
        #expect(info.kind == .homebrewCask)
        #expect(await detector.brewExecutablePath() == fakeBrew)
    }

    @Test("returns manual when caskroom does not contain the cask directory")
    func brewMismatch() async throws {
        let tmp = NSTemporaryDirectory() + "brew-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let fakeBrew = tmp + "/brew"
        FileManager.default.createFile(atPath: fakeBrew, contents: Data())
        // Caskroom exists but the ai-usages-tracker subdir does not.
        let caskroom = "\(tmp)/Caskroom"
        try FileManager.default.createDirectory(atPath: caskroom, withIntermediateDirectories: true)

        let detector = InstallationDetector(
            bundlePath: "/Applications/AI Usages Tracker.app",
            process: StubProcessRunner(stdout: caskroom + "\n", exit: 0),
            homebrewBinaryPaths: [fakeBrew],
            pathEnvironment: nil
        )
        let info = await detector.detect()
        #expect(info.kind == .manual)
    }

    @Test("returns manual when brew --caskroom errors out")
    func brewThrows() async throws {
        let tmp = NSTemporaryDirectory() + "brew-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let fakeBrew = tmp + "/brew"
        FileManager.default.createFile(atPath: fakeBrew, contents: Data())

        let detector = InstallationDetector(
            bundlePath: "/Applications/Foo.app",
            process: ThrowingProcessRunner(),
            homebrewBinaryPaths: [fakeBrew],
            pathEnvironment: nil
        )
        let info = await detector.detect()
        #expect(info.kind == .manual)
    }
}

// MARK: - UpdateInstaller

@Suite("UpdateInstaller")
struct UpdateInstallerTests {
    private func makeUpdate(version: String = "1.5.0") -> AvailableUpdate {
        AvailableUpdate(
            version: AppVersion(string: version)!,
            releaseURL: URL(string: "https://example.com/release")!,
            downloadURL: URL(string: "https://example.com/zip")!,
            sha256URL: URL(string: "https://example.com/sha")!,
            publishedAt: nil
        )
    }

    /// Creates a fresh script directory and a staged dummy `.app` so the
    /// finalize plan's existence check passes without us shipping a real bundle.
    private func makeScratch() throws -> (scriptDir: URL, stagedApp: String) {
        let scriptDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-tracker-installer-\(UUID().uuidString)", isDirectory: true)
        let stagingRoot = scriptDir.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let stagedApp = stagingRoot.appendingPathComponent("AI Usages Tracker.app", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        return (scriptDir, stagedApp.path)
    }

    @Test("homebrew finalize plan only relaunches (no swap, no admin)")
    func brewPlan() async throws {
        let (scriptDir, _) = try makeScratch()
        let installer = UpdateInstaller(scriptDirectory: scriptDir)
        let plan = try await installer.buildHomebrewFinalizationPlan(
            bundlePath: "/Applications/Foo.app",
            currentPID: 4242,
            update: makeUpdate()
        )
        let body = try String(contentsOfFile: plan.scriptPath, encoding: .utf8)
        #expect(body.contains("'/Applications/Foo.app'"))
        #expect(body.contains("kill -0 4242"))
        #expect(body.contains("/usr/bin/open"))
        // Pure relaunch: no curl/ditto/brew invocations.
        #expect(!body.contains("/bin/mv"))
        #expect(!body.contains("curl"))
        #expect(plan.requiresAdminPrivileges == false)
        let attrs = try FileManager.default.attributesOfItem(atPath: plan.scriptPath)
        let perms = (attrs[FileAttributeKey.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o755)
    }

    @Test("manual finalize plan swaps staged bundle and relaunches")
    func manualPlan() async throws {
        let (scriptDir, stagedApp) = try makeScratch()
        let installer = UpdateInstaller(scriptDirectory: scriptDir)
        let plan = try await installer.buildManualFinalizationPlan(
            stagedAppPath: stagedApp,
            bundlePath: "/Applications/Foo.app",
            currentPID: 4242,
            update: makeUpdate()
        )
        let body = try String(contentsOfFile: plan.scriptPath, encoding: .utf8)
        #expect(body.contains("'\(stagedApp)'"))
        #expect(body.contains("'/Applications/Foo.app'"))
        #expect(body.contains("kill -0 4242"))
        #expect(body.contains("/bin/mv"))
        #expect(body.contains("xattr -dr com.apple.quarantine"))
        // No download steps — those happen in the app before this script runs.
        #expect(!body.contains("curl"))
        #expect(!body.contains("ditto"))
    }

    @Test("manual finalize plan shell-quotes paths")
    func manualPlanShellQuotes() async throws {
        let (scriptDir, stagedApp) = try makeScratch()
        let installer = UpdateInstaller(scriptDirectory: scriptDir)
        let plan = try await installer.buildManualFinalizationPlan(
            stagedAppPath: stagedApp,
            bundlePath: "/Applications/Foo $(touch bad)'s.app",
            currentPID: 1,
            update: makeUpdate()
        )
        let body = try String(contentsOfFile: plan.scriptPath, encoding: .utf8)
        #expect(body.contains("'/Applications/Foo $(touch bad)'\\''s.app'"))
        #expect(!body.contains("\"/Applications/Foo $(touch bad)'s.app\""))
    }

    @Test("manual plan flags admin requirement when parent dir is not user-writable")
    func adminFlagSet() async throws {
        let (scriptDir, stagedApp) = try makeScratch()
        let installer = UpdateInstaller(scriptDirectory: scriptDir)
        let plan = try await installer.buildManualFinalizationPlan(
            stagedAppPath: stagedApp,
            bundlePath: "/private/var/db/AI Usages Tracker.app",
            currentPID: 1,
            update: makeUpdate()
        )
        #expect(plan.requiresAdminPrivileges == true)
    }

    @Test("manual plan does NOT flag admin when bundle lives in a user-writable dir")
    func noAdminInUserDir() async throws {
        let (scriptDir, stagedApp) = try makeScratch()
        let userBundleParent = NSTemporaryDirectory() + "user-apps-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: userBundleParent, withIntermediateDirectories: true)
        let installer = UpdateInstaller(scriptDirectory: scriptDir)
        let plan = try await installer.buildManualFinalizationPlan(
            stagedAppPath: stagedApp,
            bundlePath: "\(userBundleParent)/Foo.app",
            currentPID: 1,
            update: makeUpdate()
        )
        #expect(plan.requiresAdminPrivileges == false)
    }

    @Test("relaunch snippet drops privileges back to console user when run as root")
    func relaunchDropsPrivileges() async throws {
        let (scriptDir, stagedApp) = try makeScratch()
        let installer = UpdateInstaller(scriptDirectory: scriptDir)
        let plan = try await installer.buildManualFinalizationPlan(
            stagedAppPath: stagedApp,
            bundlePath: "/Applications/Foo.app",
            currentPID: 1,
            update: makeUpdate()
        )
        let body = try String(contentsOfFile: plan.scriptPath, encoding: .utf8)
        #expect(body.contains("launchctl asuser"))
        #expect(body.contains("/dev/console"))
    }

    @Test("manual plan rejects bundle paths that don't end in .app")
    func rejectsBadBundle() async throws {
        let (scriptDir, stagedApp) = try makeScratch()
        let installer = UpdateInstaller(scriptDirectory: scriptDir)
        await #expect(throws: UpdateInstallerError.self) {
            try await installer.buildManualFinalizationPlan(
                stagedAppPath: stagedApp,
                bundlePath: "/tmp/not-a-bundle",
                currentPID: 1,
                update: makeUpdate()
            )
        }
    }

    @Test("manual plan throws when staged bundle is missing")
    func rejectsMissingStaged() async throws {
        let scriptDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-tracker-installer-\(UUID().uuidString)", isDirectory: true)
        let installer = UpdateInstaller(scriptDirectory: scriptDir)
        await #expect(throws: UpdateInstallerError.self) {
            try await installer.buildManualFinalizationPlan(
                stagedAppPath: "/no/such/path/AI Usages Tracker.app",
                bundlePath: "/Applications/Foo.app",
                currentPID: 1,
                update: makeUpdate()
            )
        }
    }
}

// MARK: - UpdateState

@Suite("UpdateState")
@MainActor
struct UpdateStateTests {
    private func makeUpdate(_ version: String) -> AvailableUpdate {
        AvailableUpdate(
            version: AppVersion(string: version)!,
            releaseURL: URL(string: "https://example.com")!,
            downloadURL: URL(string: "https://example.com/zip")!,
            sha256URL: nil,
            publishedAt: nil
        )
    }

    @Test("dismissCurrent moves version into dismissedVersions and clears phase")
    func dismiss() {
        let state = UpdateState()
        state.setAvailable(makeUpdate("1.2.3"), latestVersion: AppVersion(string: "1.2.3"), kind: .manual, checkedAt: Date())
        state.setReadyToRestart(stagedAppPath: "/tmp/staged.app")
        state.dismissCurrent()
        #expect(state.dismissedVersions.contains("1.2.3"))
        #expect(state.pendingUpdate == nil)
        #expect(state.stagedAppPath == nil)
        #expect(state.phase == .idle)
    }

    @Test("isInstallInProgress reflects in-flight phases")
    func progressFlag() {
        let state = UpdateState()
        #expect(state.isInstallInProgress == false)
        state.setPreparing()
        #expect(state.isInstallInProgress == true)
        state.setDownloading(received: 1024, total: 4096)
        #expect(state.isInstallInProgress == true)
        state.setVerifying()
        #expect(state.isInstallInProgress == true)
        state.setExtracting()
        #expect(state.isInstallInProgress == true)
        state.setRunningHomebrew(lastLine: "Pouring …")
        #expect(state.isInstallInProgress == true)
        state.setReadyToRestart(stagedAppPath: nil)
        #expect(state.isInstallInProgress == false)
        #expect(state.isReadyToRestart == true)
        state.setRestarting()
        #expect(state.isInstallInProgress == true)
        state.setFailed("boom")
        #expect(state.isInstallInProgress == false)
    }

    @Test("setReadyToRestart records staged path")
    func readyRecordsStaged() {
        let state = UpdateState()
        state.setReadyToRestart(stagedAppPath: "/tmp/X.app")
        #expect(state.stagedAppPath == "/tmp/X.app")
        #expect(state.isReadyToRestart)
    }

    @Test("pendingUpdate hides dismissed versions")
    func hidesDismissed() {
        let state = UpdateState(dismissedVersions: ["1.2.3"])
        state.setAvailable(makeUpdate("1.2.3"), latestVersion: AppVersion(string: "1.2.3"), kind: .manual, checkedAt: Date())
        #expect(state.pendingUpdate == nil)
    }
}
