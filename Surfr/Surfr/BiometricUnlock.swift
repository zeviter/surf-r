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
    /// Cancel an in-flight `unlock()` prompt (e.g. the user chose master / recovery instead). The
    /// pending `unlock()` then throws a cancel, which is a benign no-op.
    func cancel()
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

    /// The Secure-Enclave error code that means the stored key can no longer derive the ECIES shared
    /// secret — i.e. a real `.biometryCurrentSet` invalidation (AKSError "unable to compute shared
    /// secret"). This is the ONLY failure that disables biometric.
    private static let invalidationAKSCode = -536362999

    private let contextLock = NSLock()
    private var activeContext: LAContext?

    func unlock() async throws -> SymmetricKey {
        guard let blob = loadBlob() else { throw BiometricFailure.notEnabled }

        let context = LAContext()
        context.localizedCancelTitle = "Use master password"   // our own fallback owns the cancel path
        wrapper.authenticationContext = context
        contextLock.withLock { activeContext = context }       // scoped lock — async-safe (Swift 6)
        defer { contextLock.withLock { activeContext = nil } }

        // Single implicit prompt: SecKeyCreateDecryptedData drives the Touch ID prompt AND the ECIES
        // decrypt in one step. (The two-step evaluateAccessControl→reuse approach didn't drive the SE
        // ECIES decrypt on real M1 Pro hardware, so we keep the one-prompt path that works.) cancel()
        // best-effort dismisses it by invalidating the context.
        let wrapper = self.wrapper
        return try await Task.detached(priority: .userInitiated) {
            do {
                return try wrapper.unwrap(blob)                 // blocks on the Touch ID prompt
            } catch {
                throw Self.classify(error)
            }
        }.value
    }

    /// Cancel the in-flight prompt (the user chose master/recovery). Clears `activeContext` first so a
    /// burst of calls (one per keystroke) only invalidates **once** — no `Code=-10 "Invalid context"`
    /// loop on an already-invalidated context.
    func cancel() {
        let ctx: LAContext? = contextLock.withLock {
            let c = activeContext
            activeContext = nil
            return c
        }
        ctx?.invalidate()
    }

    /// Classify an SE/LA failure — **inverted by design**: instead of denylisting cancels one code at a
    /// time, we **allowlist the single genuine invalidation** (the Secure Enclave can't compute the
    /// shared secret because `.biometryCurrentSet` changed). EVERYTHING else — user cancel (-2),
    /// system cancel / "canceled by another authentication" (-4), app cancel (-9), lockout, anything
    /// unknown — is benign: biometric STAYS enabled and we fall back to master. Only `.invalidated`
    /// disables, and only the real enrolment-change trips it.
    static func classify(_ error: Error) -> BiometricFailure {
        if isGenuineInvalidation(error) { return .invalidated }
        if isCancel(error) { return .userCancelled }   // silent no-op
        return .failed                                  // soft message, still enabled
    }

    /// True only for the real `.biometryCurrentSet` invalidation: AKSError `-536362999` or the
    /// "unable to compute shared secret" signature, anywhere in the underlying-error chain.
    static func isGenuineInvalidation(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 8 {
            if e.code == invalidationAKSCode { return true }
            let blob = "\(e.domain) \(e.code) \(e.userInfo)".lowercased()
            if blob.contains("unable to compute shared secret") || blob.contains("\(invalidationAKSCode)") {
                return true
            }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    /// Best-effort cancel/interrupt detection (used only to suppress the soft message; cancels never
    /// disable biometric either way).
    static func isCancel(_ error: Error) -> Bool {
        if let laError = error as? LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel: return true
            default: break
            }
        }
        let ns = error as NSError
        let cancelCodes: Set<Int> = [LAError.userCancel.rawValue, LAError.systemCancel.rawValue,
                                     LAError.appCancel.rawValue, Int(errSecUserCanceled)]
        if cancelCodes.contains(ns.code) { return true }
        if ns.localizedDescription.lowercased().contains("cancel") { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isCancel(underlying) }
        return false
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
