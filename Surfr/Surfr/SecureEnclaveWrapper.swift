import Foundation
import Security
import LocalAuthentication
import CryptoKit
import SurfrCore

/// Door 3 (vault-spec §2/§3): wraps the vault key to a **Secure Enclave** P-256 key via ECIES. Fills
/// the SurfrCore `VaultKeyWrapper` seam left in Slice 1.
///
/// The SE holds **only** the P-256 private key; the symmetric vault key is encrypted *to* its public
/// key and never stored in the enclave. The private key's access control requires biometrics
/// (`.biometryCurrentSet`), so it is invalidated if Face/Touch ID enrolment changes — forcing a
/// master re-auth. `wrap` (public-key encrypt) never prompts; `unwrap` (private-key decrypt) blocks on
/// the biometric prompt and must run off the main thread.
final class SecureEnclaveWrapper: VaultKeyWrapper, @unchecked Sendable {

    private let keyTag = "com.zeviter.surfr.vault.biometric.sekey".data(using: .utf8)!
    private let algorithm: SecKeyAlgorithm = .eciesEncryptionStandardX963SHA256AESGCM

    /// Set before `unwrap` so the biometric prompt uses our cancel-button label (our own master
    /// fallback) and so cancellation surfaces cleanly.
    var authenticationContext: LAContext?

    enum Failure: Error {
        case enclaveUnavailable
        case accessControl(String)
        case keyGenFailed(String)
        case noPublicKey
        case algorithmUnsupported
        case encryptFailed(String)
        case keyNotFound
        case decryptFailed(String)
    }

    /// Whether an SE key currently exists for us (does not prompt — loading a ref doesn't authenticate).
    var hasKey: Bool { (try? loadPrivateKey(context: nil)) != nil }

    // MARK: - VaultKeyWrapper

    func wrap(_ vaultKey: SymmetricKey) throws -> Data {
        let privateKey = try loadOrCreatePrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { throw Failure.noPublicKey }
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else { throw Failure.algorithmUnsupported }

        var keyData = vaultKey.withUnsafeBytes { Data($0) }
        defer { keyData.resetBytes(in: 0..<keyData.count) }

        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(publicKey, algorithm, keyData as CFData, &error) else {
            throw Failure.encryptFailed(Self.describe(error))
        }
        return cipher as Data
    }

    func unwrap(_ wrapped: Data) throws -> SymmetricKey {
        guard let privateKey = try loadPrivateKey(context: authenticationContext) else { throw Failure.keyNotFound }
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else { throw Failure.algorithmUnsupported }

        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(privateKey, algorithm, wrapped as CFData, &error) else {
            // Preserve the ORIGINAL error (domain/code/underlying) so the caller can tell a user
            // cancel (Code=-2) apart from a genuine .biometryCurrentSet invalidation (AKSError
            // -536362999). Stringifying here is what previously hid the cancel.
            if let cfError = error?.takeRetainedValue() { throw cfError as Error }
            throw Failure.decryptFailed("unknown")
        }
        var bytes = plain as Data
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        return SymmetricKey(data: bytes)
    }

    // MARK: - Key lifecycle

    func deleteKey() {
        let query = Keychain.withAccessGroup([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecUseDataProtectionKeychain as String: true,
        ])
        SecItemDelete(query as CFDictionary)
    }

    private func loadOrCreatePrivateKey() throws -> SecKey {
        if let existing = try loadPrivateKey(context: nil) { return existing }
        return try createPrivateKey()
    }

    private func createPrivateKey() throws -> SecKey {
        var acError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,           // no iCloud, no backup
            [.privateKeyUsage, .biometryCurrentSet],                // biometric-gated; invalidate on enrolment change
            &acError
        ) else { throw Failure.accessControl(Self.describe(acError)) }

        var privateKeyAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrAccessControl as String: access,
        ]
        if let group = Keychain.accessGroup { privateKeyAttrs[kSecAttrAccessGroup as String] = group }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: privateKeyAttrs,
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw Failure.keyGenFailed(Self.describe(error))
        }
        return key
    }

    private func loadPrivateKey(context: LAContext?) throws -> SecKey? {
        var query: [String: Any] = Keychain.withAccessGroup([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ])
        if let context { query[kSecUseAuthenticationContext as String] = context }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let result else { return nil }
            return (result as! SecKey)
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.decryptFailed("load key OSStatus \(status)")
        }
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        guard let error else { return "unknown" }
        return String(describing: error.takeRetainedValue())
    }
}
