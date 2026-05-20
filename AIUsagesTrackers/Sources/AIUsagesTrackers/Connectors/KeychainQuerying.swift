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
        try await withThrowingTaskGroup(of: [Data].self) { group in
            group.addTask { try await Self.queryKeychain(service: service) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds) * 1_000_000_000)
                throw KeychainQueryError.timeout(service: service, timeoutSeconds: Self.timeoutSeconds)
            }
            for try await result in group {
                group.cancelAll()
                return result
            }
            return []
        }
    }

    private static func queryKeychain(service: String) async throws -> [Data] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
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
                    continuation.resume(returning: (result as? [Data]) ?? [])
                case errSecItemNotFound:
                    continuation.resume(returning: [])
                default:
                    continuation.resume(throwing: KeychainQueryError.accessDenied(service: service, status: status))
                }
            }
        }
    }
}
