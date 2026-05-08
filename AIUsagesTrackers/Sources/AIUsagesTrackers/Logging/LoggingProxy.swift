import Foundation

/// One captured HTTP exchange to log via `LoggingProxy.logExchange(_:)`.
/// The proxy serializes this into the deterministic format required by
/// `docs/VENDOR-PLUGIN-CONTRACT.md` §6 so testers' attached log files
/// stay parseable.
public struct PayloadLogEntry: Sendable {
    public let method: String
    public let url: URL
    public let statusCode: Int
    public let latencyMillis: Int
    public let requestHeaders: [String: String]
    public let requestBody: Data?
    public let responseHeaders: [String: String]
    public let responseBody: Data?

    public init(
        method: String,
        url: URL,
        statusCode: Int,
        latencyMillis: Int,
        requestHeaders: [String: String] = [:],
        requestBody: Data? = nil,
        responseHeaders: [String: String] = [:],
        responseBody: Data? = nil
    ) {
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.latencyMillis = latencyMillis
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
    }
}

/// Sanitization-enforcing wrapper around a `FileLogger`. Connectors and
/// credential locators MUST log payload-bearing entries through the
/// proxy — the SwiftLint custom rule blocks direct `logger.log(.debug,
/// "...payload...")` calls inside `*Connector.swift` and
/// `*CredentialLocator.swift` files.
///
/// Bypassing the proxy is a contract violation: every byte that reaches
/// the underlying `FileLogger` via this type goes through `sanitizer`
/// first, so a future contributor cannot accidentally emit a raw secret.
public struct LoggingProxy: Sendable {
    private let logger: FileLogger
    private let sanitizer: any PayloadSanitizing
    /// `.debug` for verbose-vendor mode; `.info` for everyone else. The
    /// wiring layer (see `docs/VENDOR-PLUGIN-CONTRACT.md` §10) reads the
    /// activation source at startup and constructs proxies accordingly.
    private let payloadLevel: LogLevel
    /// Above this size, response bodies are emitted as `<truncated, N bytes>`.
    /// Verbose-vendor mode generates large files quickly; truncation caps
    /// the per-line cost while still showing structure for short payloads.
    public static let bodyTruncateBytes = 16 * 1024

    public init(logger: FileLogger, sanitizer: any PayloadSanitizing, payloadLevel: LogLevel = .debug) {
        self.logger = logger
        self.sanitizer = sanitizer
        self.payloadLevel = payloadLevel
    }

    /// Pass-through for non-payload log lines that don't require
    /// sanitization (lifecycle messages, counters, etc.). Connectors are
    /// free to call this directly.
    public func log(_ level: LogLevel, _ message: String) {
        logger.log(level, sanitizer.sanitize(message))
    }

    /// Logs a complete HTTP exchange in the deterministic format mandated
    /// by the contract — every field passes through the sanitizer first.
    public func logExchange(_ entry: PayloadLogEntry) {
        let sanitizedRequestHeaders = sanitizer.sanitize(entry.requestHeaders)
        let sanitizedResponseHeaders = sanitizer.sanitize(entry.responseHeaders)
        let header = "\(entry.method) \(entry.url.absoluteString) -> HTTP \(entry.statusCode) in \(entry.latencyMillis)ms"
        let lines: [String] = [
            header,
            "  request headers: \(formatHeaders(sanitizedRequestHeaders))",
            "  request body: \(formatBody(entry.requestBody))",
            "  response headers: \(formatHeaders(sanitizedResponseHeaders))",
            "  response body: \(formatBody(entry.responseBody))",
        ]
        logger.log(payloadLevel, lines.joined(separator: "\n"))
    }

    /// Logs an arbitrary payload with a caller-supplied prefix — used by
    /// connectors that capture a body outside the structured exchange
    /// shape (e.g. parse-error dumps).
    public func logPayload(_ level: LogLevel, _ prefix: String, payload: Data) {
        let sanitized: String
        if payload.count > Self.bodyTruncateBytes {
            sanitized = "<truncated, \(payload.count) bytes>"
        } else {
            let masked = sanitizer.sanitize(payload)
            sanitized = String(data: masked, encoding: .utf8) ?? "<non-UTF8, \(payload.count) bytes>"
        }
        logger.log(level, "\(prefix): \(sanitizer.sanitize(sanitized))")
    }

    private func formatHeaders(_ headers: [String: String]) -> String {
        guard !headers.isEmpty else { return "<none>" }
        let sortedKeys = headers.keys.sorted()
        let pairs = sortedKeys.map { "\"\($0)\":\"\(headers[$0] ?? "")\"" }
        return "{" + pairs.joined(separator: ",") + "}"
    }

    private func formatBody(_ body: Data?) -> String {
        guard let body, !body.isEmpty else { return "<empty>" }
        if body.count > Self.bodyTruncateBytes {
            return "<truncated, \(body.count) bytes>"
        }
        let sanitized = sanitizer.sanitize(body)
        guard let text = String(data: sanitized, encoding: .utf8) else {
            return "<non-UTF8, \(body.count) bytes>"
        }
        return sanitizer.sanitize(text)
    }
}
