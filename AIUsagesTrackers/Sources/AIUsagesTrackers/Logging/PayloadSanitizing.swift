import Foundation

/// Strips confidential fields from payloads (request body, response body,
/// headers, error messages) before they reach a log file. Sanitization is
/// enforced at the logger boundary via `LoggingProxy`, never at the call
/// site — a future contributor cannot bypass it with a "just this once"
/// debug log.
///
/// Implementations MUST be idempotent and side-effect free: passing a
/// sanitized output back through `sanitize` returns the same bytes. This
/// invariant is asserted by the per-vendor leakage test.
public protocol PayloadSanitizing: Sendable {
    func sanitize(_ payload: Data) -> Data
    func sanitize(_ headers: [String: String]) -> [String: String]
    func sanitize(_ message: String) -> String
}
