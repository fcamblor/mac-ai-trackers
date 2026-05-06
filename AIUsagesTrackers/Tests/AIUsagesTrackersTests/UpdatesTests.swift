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
            homebrewBinaryPaths: ["/no/such/path"]
        )
        let info = await detector.detect()
        #expect(info.kind == .manual)
    }

    @Test("returns homebrewCask when bundle lives under caskroom")
    func brewMatch() async throws {
        // Create a fake brew binary file path so fileExists returns true.
        let tmp = NSTemporaryDirectory() + "brew-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let fakeBrew = tmp + "/brew"
        FileManager.default.createFile(atPath: fakeBrew, contents: Data())

        let caskroom = "/opt/homebrew/Caskroom"
        let bundlePath = "\(caskroom)/ai-usages-tracker/1.2.3/AI Usages Tracker.app"
        let detector = InstallationDetector(
            bundlePath: bundlePath,
            process: StubProcessRunner(stdout: caskroom + "\n", exit: 0),
            homebrewBinaryPaths: [fakeBrew]
        )
        let info = await detector.detect()
        #expect(info.kind == .homebrewCask)
    }

    @Test("returns manual when bundle lives outside caskroom")
    func brewMismatch() async throws {
        let tmp = NSTemporaryDirectory() + "brew-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let fakeBrew = tmp + "/brew"
        FileManager.default.createFile(atPath: fakeBrew, contents: Data())

        let detector = InstallationDetector(
            bundlePath: "/Applications/Foo.app",
            process: StubProcessRunner(stdout: "/opt/homebrew/Caskroom\n", exit: 0),
            homebrewBinaryPaths: [fakeBrew]
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
            homebrewBinaryPaths: [fakeBrew]
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

    @Test("homebrew plan invokes brew upgrade --cask in script")
    func brewPlan() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-tracker-installer-\(UUID().uuidString)", isDirectory: true)
        let installer = UpdateInstaller(scriptDirectory: dir)
        let plan = try await installer.buildPlan(
            for: makeUpdate(),
            installation: InstallationInfo(kind: .homebrewCask, bundlePath: "/Applications/Foo.app"),
            brewExecutablePath: "/opt/homebrew/bin/brew",
            currentPID: 4242
        )
        let body = try String(contentsOfFile: plan.scriptPath, encoding: .utf8)
        #expect(body.contains("upgrade --cask ai-usages-tracker"))
        #expect(body.contains("/opt/homebrew/bin/brew"))
        #expect(body.contains("/Applications/Foo.app"))
        #expect(body.contains("kill -0 4242"))
        let attrs = try FileManager.default.attributesOfItem(atPath: plan.scriptPath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o755)
    }

    @Test("homebrew plan falls back to manual when brew is unavailable")
    func brewFallback() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-tracker-installer-\(UUID().uuidString)", isDirectory: true)
        let installer = UpdateInstaller(scriptDirectory: dir)
        let plan = try await installer.buildPlan(
            for: makeUpdate(),
            installation: InstallationInfo(kind: .homebrewCask, bundlePath: "/Applications/Foo.app"),
            brewExecutablePath: nil,
            currentPID: 1
        )
        let body = try String(contentsOfFile: plan.scriptPath, encoding: .utf8)
        #expect(body.contains("curl"))
        #expect(body.contains("ditto"))
    }

    @Test("manual plan downloads, verifies sha256, and replaces bundle")
    func manualPlan() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-tracker-installer-\(UUID().uuidString)", isDirectory: true)
        let installer = UpdateInstaller(scriptDirectory: dir)
        let plan = try await installer.buildPlan(
            for: makeUpdate(),
            installation: InstallationInfo(kind: .manual, bundlePath: "/Applications/Foo.app"),
            brewExecutablePath: nil,
            currentPID: 1
        )
        let body = try String(contentsOfFile: plan.scriptPath, encoding: .utf8)
        #expect(body.contains("https://example.com/zip"))
        #expect(body.contains("https://example.com/sha"))
        #expect(body.contains("shasum -a 256"))
        #expect(body.contains("/Applications/Foo.app"))
    }

    @Test("plan flags admin requirement when parent dir is not user-writable")
    func adminFlagSet() async throws {
        // /private/var/db is root-owned and not writable by regular users.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-tracker-installer-\(UUID().uuidString)", isDirectory: true)
        let installer = UpdateInstaller(scriptDirectory: dir)
        let plan = try await installer.buildPlan(
            for: makeUpdate(),
            installation: InstallationInfo(kind: .manual, bundlePath: "/private/var/db/AI Usages Tracker.app"),
            brewExecutablePath: nil,
            currentPID: 1
        )
        #expect(plan.requiresAdminPrivileges == true)
    }

    @Test("plan does NOT flag admin when bundle lives in a user-writable dir")
    func noAdminInUserDir() async throws {
        let userBundleParent = NSTemporaryDirectory() + "user-apps-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: userBundleParent, withIntermediateDirectories: true)
        let bundlePath = "\(userBundleParent)/Foo.app"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-tracker-installer-\(UUID().uuidString)", isDirectory: true)
        let installer = UpdateInstaller(scriptDirectory: dir)
        let plan = try await installer.buildPlan(
            for: makeUpdate(),
            installation: InstallationInfo(kind: .manual, bundlePath: bundlePath),
            brewExecutablePath: nil,
            currentPID: 1
        )
        #expect(plan.requiresAdminPrivileges == false)
    }

    @Test("homebrew plan never flags admin requirement")
    func brewNoAdmin() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-tracker-installer-\(UUID().uuidString)", isDirectory: true)
        let installer = UpdateInstaller(scriptDirectory: dir)
        let plan = try await installer.buildPlan(
            for: makeUpdate(),
            installation: InstallationInfo(kind: .homebrewCask, bundlePath: "/private/var/db/Foo.app"),
            brewExecutablePath: "/opt/homebrew/bin/brew",
            currentPID: 1
        )
        #expect(plan.requiresAdminPrivileges == false)
    }

    @Test("relaunch snippet drops privileges back to console user when run as root")
    func relaunchDropsPrivileges() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-tracker-installer-\(UUID().uuidString)", isDirectory: true)
        let installer = UpdateInstaller(scriptDirectory: dir)
        let plan = try await installer.buildPlan(
            for: makeUpdate(),
            installation: InstallationInfo(kind: .manual, bundlePath: "/Applications/Foo.app"),
            brewExecutablePath: nil,
            currentPID: 1
        )
        let body = try String(contentsOfFile: plan.scriptPath, encoding: .utf8)
        #expect(body.contains("launchctl asuser"))
        #expect(body.contains("/dev/console"))
    }

    @Test("manual plan rejects bundle paths that don't end in .app")
    func rejectsBadBundle() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ai-tracker-installer-\(UUID().uuidString)", isDirectory: true)
        let installer = UpdateInstaller(scriptDirectory: dir)
        await #expect(throws: UpdateInstallerError.self) {
            try await installer.buildPlan(
                for: makeUpdate(),
                installation: InstallationInfo(kind: .manual, bundlePath: "/tmp/not-a-bundle"),
                brewExecutablePath: nil,
                currentPID: 1
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

    @Test("dismissCurrent moves version into dismissedVersions")
    func dismiss() {
        let state = UpdateState()
        state.setAvailable(makeUpdate("1.2.3"), latestVersion: AppVersion(string: "1.2.3"), kind: .manual, checkedAt: Date())
        state.dismissCurrent()
        #expect(state.dismissedVersions.contains("1.2.3"))
        #expect(state.pendingUpdate == nil)
    }

    @Test("pendingUpdate hides dismissed versions")
    func hidesDismissed() {
        let state = UpdateState(dismissedVersions: ["1.2.3"])
        state.setAvailable(makeUpdate("1.2.3"), latestVersion: AppVersion(string: "1.2.3"), kind: .manual, checkedAt: Date())
        #expect(state.pendingUpdate == nil)
    }
}
