import Foundation

public protocol StatusConnector: Sendable {
    var vendor: Vendor { get }
    func fetchOutages() async throws -> [Outage]
}

public enum StatusConnectorError: Error, CustomStringConvertible {
    case unexpectedResponse(statusCode: Int, url: String)
    case networkError(underlying: Error, url: String)
    case parseError(underlying: Error, url: String)
    case invalidURL(rawValue: String)

    public var description: String {
        switch self {
        case let .unexpectedResponse(code, url):
            "Status endpoint returned HTTP \(code) for \(url)"
        case let .networkError(err, url):
            "Status endpoint network error for \(url): \(err)"
        case let .parseError(err, url):
            "Status endpoint parse error for \(url): \(err)"
        case let .invalidURL(raw):
            "Invalid status endpoint URL: \(raw)"
        }
    }
}
