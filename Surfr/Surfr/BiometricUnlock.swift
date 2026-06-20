import Foundation
import Security
import LocalAuthentication
import CryptoKit
import SurfrCore

/// Why a biometric unlock didn't yield the vault key — the gate maps each to a graceful outcome.
enum BiometricFailure: Error, Equatable {
    case unavailable     // no biometric hardware / not enrolled in the OS
    case notEnabled      // the user hasn't enabled biometric for the vault
    case userCancelled   // user dismissed the prompt → fall to master, no penalty, stay enabled
    case invalidated     // .biometryCurrentSet tripped (enrolment changed) → disable + offer re-enable
    case failed          // any other failure → fall to master
}

/// The app-facing biometric door. `VaultGate` depends on this; tests inject a mock.
protocol BiometricUnlocking: AnyObject, Sendable {
    /// Biometric hardware present and enrolled at the OS level.
    var isAvailable: Bool { get }
    /// A biometric-wrapped vault key exists for us (the user enabled it).
    var isEnabled: Bool { get }
    /// Wrap the live vault key to the Secure Enclave and store it. No biometric prompt.
    func enable(vaultKey: SymmetricKey) throws
    /// Remove the stored biometric key + blob.
    func disable()
    /// Prompt biometrics and return the vault key. Throws `BiometricFailure` on any non-success.
    func unlock() async throws -> SymmetricKey
}

/// Real biometric door: `SecureEnclaveWrapper` (ECIES to an SE P-256 key) + a Keychain-stored wrapped
/// blob. The SE key's `.biometryCurrentSet` access control is what enforces the biometric gate and the
/// enrolment-change invalidation.
final class SecureEnclaveBiometricUnlock: BiometricUnlocking, @unchecked Sendable {

    private let wrapper = SecureEnclaveWrapper()
    private let blobService = "com.zeviter.surfr.vault"
    private let blobAccount = "biometric-wrapped-vault-key"

    var isAvailable: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var isEnabled: Bool { loadBlob() != nil }

    func enable(vaultKey: SymmetricKey) throws {
        let blob = try wrapper.wrap(vaultKey)   // generates the SE key if needed; public-key encrypt, no prompt
        try storeBlob(blob)
    }

    func disable() {
        deleteBlob()
        wrapper.deleteKey()
    }

    func unlock() async throws -> SymmetricKey {
        guard let blob = loadBlob() else { throw BiometricFailure.notEnabled }

        let context = LAContext()
        context.localizedCancelTitle = "Use master password"   // our own fallback owns the cancel path
        wrapper.authenticationContext = context

        let wrapper = self.wrapper
        return try await Task.detached(priority: .userInitiated) {
            do {
                return try wrapper.unwrap(blob)                 // blocks on the Touch ID prompt
            } catch {
                throw Self.classify(error, biometryAvailableNow: { LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) })
            }
        }.value
    }

    /// Map an SE/LA error to a gate outcome. Cancellation must never disable biometric; an auth failure
    /// while biometry is still enrolled is treated as a `.biometryCurrentSet` invalidation (offer
    /// re-enable); lockout falls back to master without disabling.
    static func classify(_ error: Error, biometryAvailableNow: () -> Bool) -> BiometricFailure {
        if let laError = error as? LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel:        return .userCancelled
            case .biometryNotAvailable, .biometryNotEnrolled:   return .unavailable
            case .biometryLockout:                              return .failed
            default:                                            return .failed
            }
        }
        let ns = error as NSError
        if ns.code == errSecUserCanceled || ns.code == Int(errSecUserCanceled) { return .userCancelled }
        if case SecureEnclaveWrapper.Failure.keyNotFound = error { return .invalidated }
        // A decrypt that failed for a non-cancel reason while biometry is still enrolled most likely
        // means the stored key was invalidated by an enrolment change.
        return biometryAvailableNow() ? .invalidated : .unavailable
    }

    // MARK: - Keychain blob storage (data-protection keychain, our access group, ThisDeviceOnly)

    private func storeBlob(_ blob: Data) throws {
        deleteBlob()
        let attrs = Keychain.withAccessGroup([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: blobService,
            kSecAttrAccount as String: blobAccount,
            kSecValueData as String: blob,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ])
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw BiometricFailure.failed }
    }

    private func loadBlob() -> Data? {
        let query = Keychain.withAccessGroup([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: blobService,
            kSecAttrAccount as String: blobAccount,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ])
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess ? (result as? Data) : nil
    }

    private func deleteBlob() {
        let query = Keychain.withAccessGroup([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: blobService,
            kSecAttrAccount as String: blobAccount,
            kSecUseDataProtectionKeychain as String: true,
        ])
        SecItemDelete(query as CFDictionary)
    }
}
