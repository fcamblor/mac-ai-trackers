import Foundation

/// Reads vendor credentials from external sources owned by the vendor's CLI
/// (env vars, keychain entries written by the vendor, on-disk config files
/// written by the vendor). The application MUST NOT write, refresh, rotate,
/// or persist tokens — those operations belong to the vendor's own tooling.
///
/// The associated `Credentials` type lets each vendor carry its own
/// domain-specific shape (OAuth token vs API key + org id vs token + login)
/// without lossy generalization. The contract conformance test verifies the
/// read-only invariant via the SwiftLint custom rule that flags writes
/// inside any `*CredentialLocator.swift` file.
public protocol CredentialLocator: Sendable {
    associatedtype Credentials: Sendable

    /// Reads credentials from external sources owned by the vendor's CLI.
    /// MUST NOT call `SecItemAdd` / `SecItemUpdate` / `SecItemDelete`,
    /// MUST NOT write to vendor config files,
    /// MUST NOT shell out to `<vendor> auth login`.
    func locate() async throws -> Credentials
}
