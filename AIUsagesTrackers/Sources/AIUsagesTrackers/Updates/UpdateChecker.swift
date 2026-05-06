import Foundation

public struct UpdateCheckResult: Sendable, Equatable {
    public let latestVersion: AppVersion
    public let update: AvailableUpdate?

    public init(latestVersion: AppVersion, update: AvailableUpdate?) {
        self.latestVersion = latestVersion
        self.update = update
    }
}

public struct AvailableUpdate: Sendable, Equatable {
    public let version: AppVersion
    public let releaseURL: URL
    public let downloadURL: URL
    public let sha256URL: URL?
    public let publishedAt: Date?

    public init(version: AppVersion, releaseURL: URL, downloadURL: URL, sha256URL: URL?, publishedAt: Date?) {
        self.version = version
        self.releaseURL = releaseURL
        self.downloadURL = downloadURL
        self.sha256URL = sha256URL
        self.publishedAt = publishedAt
    }
}

public enum UpdateCheckerError: Error, Equatable {
    case invalidEndpoint(rawValue: String)
    case networkError(message: String, url: String)
    case unexpectedResponse(statusCode: Int, url: String)
    case parseError(message: String, url: String)
    case missingDownloadAsset(tag: String)
    case malformedTag(tag: String)
}

public actor UpdateChecker {
    private let session: URLSession
    private let endpointURLString: String
    private let logger: FileLogger
    private let downloadAssetName: String

    private static let requestTimeoutSeconds: TimeInterval = 10
    public static let defaultEndpoint = "https://api.github.com/repos/fcamblor/mac-ai-trackers/releases/latest"
    public static let defaultDownloadAssetName = "AI-Usages-Tracker.zip"

    public init(
        session: URLSession = .shared,
        endpointURLString: String = UpdateChecker.defaultEndpoint,
        downloadAssetName: String = UpdateChecker.defaultDownloadAssetName,
        logger: FileLogger = Loggers.app
    ) {
        self.session = session
        self.endpointURLString = endpointURLString
        self.downloadAssetName = downloadAssetName
        self.logger = logger
    }

    /// Returns the latest version published on GitHub, plus an `AvailableUpdate`
    /// payload only when it is strictly greater than `currentVersion`.
    public func checkForUpdate(currentVersion: AppVersion) async throws -> UpdateCheckResult {
        guard let url = URL(string: endpointURLString) else {
            throw UpdateCheckerError.invalidEndpoint(rawValue: endpointURLString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeoutSeconds
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        logger.log(.debug, "Checking for updates at \(endpointURLString)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.log(.warning, "Update check network error: \(error)")
            throw UpdateCheckerError.networkError(message: String(describing: error), url: endpointURLString)
        }

        let httpCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard httpCode == 200 else {
            logger.log(.warning, "Update check HTTP \(httpCode)")
            throw UpdateCheckerError.unexpectedResponse(statusCode: httpCode, url: endpointURLString)
        }

        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            logger.log(.error, "Update check parse error: \(error)")
            throw UpdateCheckerError.parseError(message: String(describing: error), url: endpointURLString)
        }

        guard let version = AppVersion(string: release.tag_name) else {
            throw UpdateCheckerError.malformedTag(tag: release.tag_name)
        }
        guard version > currentVersion else {
            logger.log(.info, "Already up to date (current=\(currentVersion), latest=\(version))")
            return UpdateCheckResult(latestVersion: version, update: nil)
        }

        guard let zipAsset = release.assets.first(where: { $0.name == downloadAssetName }),
              let zipURL = URL(string: zipAsset.browser_download_url) else {
            throw UpdateCheckerError.missingDownloadAsset(tag: release.tag_name)
        }
        let shaAssetName = "\(downloadAssetName).sha256"
        let shaURL: URL? = release.assets
            .first(where: { $0.name == shaAssetName })
            .flatMap { URL(string: $0.browser_download_url) }
        let releaseURL = URL(string: release.html_url) ?? zipURL

        logger.log(.info, "Update available: \(version) (current=\(currentVersion))")
        let publishedAt: Date? = release.published_at.flatMap { raw in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: raw)
        }
        let update = AvailableUpdate(
            version: version,
            releaseURL: releaseURL,
            downloadURL: zipURL,
            sha256URL: shaURL,
            publishedAt: publishedAt
        )
        return UpdateCheckResult(latestVersion: version, update: update)
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
        let published_at: String?
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }
}
