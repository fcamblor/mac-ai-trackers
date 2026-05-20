import Foundation
import Security

public enum KeychainQueryError: Error, CustomStringConvertible {
    case accessDenied(service: String, status: OSStatus)
    case timeout(service: String, timeoutSeconds: Int)

    public var description: String {
        switch self {
        case let .accessDenied(svc, status):
            "Keychain access denied for service '\(svc)' (OSStatus \(status))"
        case let .timeout(svc, secs):
            "Keychain query timed out after \(secs)s for service '\(svc)'"
        }
    }
}

/// Read-only access to the macOS Keychain. Never calls SecItemAdd, SecItemUpdate, or SecItemDelete.
public protocol KeychainQuerying: Sendable {
    /// Returns the password data for every generic-password item stored under `service`.
    /// Returns an empty array when no item exists (equivalent to errSecItemNotFound).
    func allPasswords(service: String) async throws -> [Data]
}

public struct SystemKeychainQuery: KeychainQuerying {
    static let timeoutSeconds = 10

    public init() {}

    public func allPasswords(service: String) async throws -> [Data] {
        try await withCheckedThrowingContinuation { continuation in
            let callback = OneShotKeychainCallback()

            DispatchQueue.global(qos: .userInitiated).async {
                callback.resume(continuation, with: Self.queryKeychain(service: service))
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(Self.timeoutSeconds)) {
                callback.resume(
                    continuation,
                    with: .failure(KeychainQueryError.timeout(service: service, timeoutSeconds: Self.timeoutSeconds))
                )
            }
        }
    }

    private static func queryKeychain(service: String) -> Result<[Data], Error> {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnData: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return .success((result as? [Data]) ?? [])
        case errSecItemNotFound:
            return .success([])
        default:
            return .failure(KeychainQueryError.accessDenied(service: service, status: status))
        }
    }
}

private final class OneShotKeychainCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ continuation: CheckedContinuation<[Data], Error>, with result: Result<[Data], Error>) {
        lock.lock()
        let shouldResume = !didResume
        didResume = true
        lock.unlock()

        guard shouldResume else { return }
        continuation.resume(with: result)
    }
}
