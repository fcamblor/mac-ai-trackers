import CommonCrypto
import Foundation

/// Reads the Electron `safeStorage` symmetric key the Claude Desktop app stores
/// in the macOS Keychain (generic password, service `Claude Safe Storage`).
///
/// Bootstrap contract (see `.claude/rules/swift-quality.md` §9): this performs a
/// `security … -w` secret read against a Keychain entry the user has NOT
/// pre-approved for the steady-state poll. It MUST therefore only be invoked
/// from a code path the user has explicitly enabled (the Claude Desktop source
/// toggle in the Coding Assistants tab) — never at bootstrap before any user
/// interaction.
public protocol SafeStorageKeyReading: Sendable {
    func readKey(service: String) async throws -> Data
}

public enum SafeStorageError: Error, CustomStringConvertible, Equatable {
    case keychainAccessDenied(service: String, exitCode: Int32)
    case keychainTimeout(service: String, timeoutSeconds: Int)
    case keychainEmpty(service: String)
    case notBase64(preview: String)
    case unsupportedCipherPrefix(found: String)
    case keyDerivationFailed(status: Int32)
    case decryptionFailed(status: Int32)
    case malformedPlaintext

    public var description: String {
        switch self {
        case let .keychainAccessDenied(svc, code):
            "Safe Storage key access denied for service '\(svc)' (exit \(code))"
        case let .keychainTimeout(svc, secs):
            "Safe Storage key access timed out after \(secs)s for service '\(svc)'"
        case let .keychainEmpty(svc):
            "Safe Storage key is empty for service '\(svc)'"
        case let .notBase64(preview):
            "Encrypted value is not valid base64 — preview: '\(preview.prefix(16))'"
        case let .unsupportedCipherPrefix(found):
            "Encrypted value has unsupported cipher prefix '\(found)' (expected 'v10')"
        case let .keyDerivationFailed(status):
            "PBKDF2 key derivation failed (status \(status))"
        case let .decryptionFailed(status):
            "AES-CBC decryption failed (status \(status))"
        case .malformedPlaintext:
            "Decrypted plaintext has invalid PKCS7 padding"
        }
    }
}

/// Default `SafeStorageKeyReading` backed by `/usr/bin/security`. The `-w` flag
/// prints the secret, which is why this type exists behind the user-gated path
/// only.
public struct SecuritySafeStorageKeyReader: SafeStorageKeyReading {
    public static let defaultTimeoutSeconds = 10

    private let processRunner: ProcessRunning
    private let timeoutSeconds: Int

    public init(
        processRunner: ProcessRunning = FoundationProcessRunner(),
        timeoutSeconds: Int = SecuritySafeStorageKeyReader.defaultTimeoutSeconds
    ) {
        self.processRunner = processRunner
        self.timeoutSeconds = timeoutSeconds
    }

    public func readKey(service: String) async throws -> Data {
        let result = try await processRunner.run(
            executablePath: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service, "-w"],
            timeoutSeconds: timeoutSeconds
        )
        if result.timedOut {
            throw SafeStorageError.keychainTimeout(service: service, timeoutSeconds: timeoutSeconds)
        }
        guard result.terminationStatus == 0 else {
            throw SafeStorageError.keychainAccessDenied(service: service, exitCode: result.terminationStatus)
        }
        guard let raw = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            let keyData = raw.data(using: .utf8) else {
            throw SafeStorageError.keychainEmpty(service: service)
        }
        return keyData
    }
}

/// Decrypts Electron `safeStorage` `v10` values on macOS. The scheme is fixed by
/// Electron/Chromium: PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16 bytes)
/// derives an AES-128 key; the ciphertext (after the 3-byte `v10` prefix) is
/// AES-128-CBC with a 16-byte IV of ASCII spaces and PKCS7 padding.
public struct AppleSafeStorageDecryptor: Sendable {
    public static let cipherPrefix = "v10"
    private static let salt = "saltysalt"
    private static let iterations: UInt32 = 1003
    private static let derivedKeyLength = 16
    /// Electron uses 16 bytes of ASCII space (0x20) as the fixed CBC IV.
    private static let ivByte: UInt8 = 0x20

    public init() {}

    /// Decrypts a base64-encoded `v10` value using the raw Keychain password
    /// bytes as the PBKDF2 input.
    public func decrypt(base64Value: String, keyPassword: Data) throws -> Data {
        guard let blob = Data(base64Encoded: base64Value) else {
            throw SafeStorageError.notBase64(preview: base64Value)
        }
        let prefixData = blob.prefix(Self.cipherPrefix.utf8.count)
        guard String(data: prefixData, encoding: .utf8) == Self.cipherPrefix else {
            let found = String(data: prefixData, encoding: .utf8) ?? "<non-utf8>"
            throw SafeStorageError.unsupportedCipherPrefix(found: found)
        }
        let ciphertext = blob.dropFirst(Self.cipherPrefix.utf8.count)
        let aesKey = try Self.deriveKey(password: keyPassword)
        return try Self.aesCBCDecrypt(ciphertext: Data(ciphertext), key: aesKey)
    }

    static func deriveKey(password: Data) throws -> Data {
        var derived = Data(count: derivedKeyLength)
        let saltBytes = Array(salt.utf8)
        let status = derived.withUnsafeMutableBytes { derivedPtr -> Int32 in
            password.withUnsafeBytes { passwordPtr -> Int32 in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                    password.count,
                    saltBytes,
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    iterations,
                    derivedPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    derivedKeyLength
                )
            }
        }
        guard status == kCCSuccess else {
            throw SafeStorageError.keyDerivationFailed(status: status)
        }
        return derived
    }

    static func aesCBCDecrypt(ciphertext: Data, key: Data) throws -> Data {
        let iv = Data(repeating: ivByte, count: kCCBlockSizeAES128)
        let outputCapacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var movedBytes = 0
        let status = output.withUnsafeMutableBytes { outPtr -> Int32 in
            ciphertext.withUnsafeBytes { inPtr -> Int32 in
                iv.withUnsafeBytes { ivPtr -> Int32 in
                    key.withUnsafeBytes { keyPtr -> Int32 in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, ciphertext.count,
                            outPtr.baseAddress, outputCapacity,
                            &movedBytes
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw SafeStorageError.decryptionFailed(status: status)
        }
        output.removeSubrange(movedBytes..<output.count)
        return output
    }
}
