import Foundation
import CryptoKit

// MARK: - Parameters & persisted metadata

/// Argon2id cost parameters. Stored in the clear alongside the wrapped key (salt + params are not
/// secret); Slice 2 persists these in `vault_meta`.
public struct KDFParams: Codable, Equatable, Sendable {
    public var memoryKiB: UInt32
    public var iterations: UInt32
    public var parallelism: UInt32
    public var algorithm: String

    public init(memoryKiB: UInt32, iterations: UInt32, parallelism: UInt32, algorithm: String = "argon2id") {
        self.memoryKiB = memoryKiB
        self.iterations = iterations
        self.parallelism = parallelism
        self.algorithm = algorithm
    }

    /// Comfortable on the M1 Pro and stays sub-second (vault-spec §2): m = 64 MiB, t = 3, p = 1.
    public static let defaultMacOS = KDFParams(memoryKiB: 64 * 1024, iterations: 3, parallelism: 1)

    /// OWASP floor for weaker (older iOS) hardware (vault-spec §2): m = 19 MiB, t = 2, p = 1.
    public static let floorMobile = KDFParams(memoryKiB: 19 * 1024, iterations: 2, parallelism: 1)
}

/// Everything needed to re-derive the two password-based doors to the vault key. The biometric copy
/// (door 3) is **not** here — it lives in the Keychain, wrapped by a Secure-Enclave key (Slice 4).
/// Maps to the `vault_meta` table; persistence is Slice 2.
public struct VaultMeta: Codable, Equatable, Sendable {
    public var schemaVersion: Int

    // Door 1 — master password.
    public var kdfSaltMaster: Data
    public var kdfParamsMaster: KDFParams
    public var wrappedVaultKeyMaster: Data        // AES-256-GCM combined blob (nonce ‖ ct ‖ tag)

    // Door 2 — recovery code.
    public var kdfSaltRecovery: Data
    public var kdfParamsRecovery: KDFParams
    public var wrappedVaultKeyRecovery: Data      // AES-256-GCM combined blob

    public init(schemaVersion: Int,
                kdfSaltMaster: Data, kdfParamsMaster: KDFParams, wrappedVaultKeyMaster: Data,
                kdfSaltRecovery: Data, kdfParamsRecovery: KDFParams, wrappedVaultKeyRecovery: Data) {
        self.schemaVersion = schemaVersion
        self.kdfSaltMaster = kdfSaltMaster
        self.kdfParamsMaster = kdfParamsMaster
        self.wrappedVaultKeyMaster = wrappedVaultKeyMaster
        self.kdfSaltRecovery = kdfSaltRecovery
        self.kdfParamsRecovery = kdfParamsRecovery
        self.wrappedVaultKeyRecovery = wrappedVaultKeyRecovery
    }
}

/// An encrypted item: its per-item key wrapped under the vault key, plus the AEAD payload. No separate
/// nonce field — GCM's `.combined` form carries the 96-bit nonce inline (vault-spec §6 Slice 1 amendment).
public struct SealedItem: Codable, Equatable, Sendable {
    public var wrappedItemKey: Data               // AES-256-GCM combined blob
    public var ciphertext: Data                   // AES-256-GCM combined blob

    public init(wrappedItemKey: Data, ciphertext: Data) {
        self.wrappedItemKey = wrappedItemKey
        self.ciphertext = ciphertext
    }
}

// MARK: - Door 3 seam (Secure Enclave biometric copy — filled in Slice 4)

/// Abstraction over a "door" that wraps/unwraps a copy of the vault key. Slice 1 ships only the two
/// password-based doors (master, recovery) inline. Slice 4 supplies a `SecureEnclaveKeyWrapper`
/// conforming to this — ECIES-wrapping the vault key to a P-256 SE key, gated by `.biometryCurrentSet`
/// — in its own file that may import Security/LocalAuthentication. Keeping the seam here (import-clean)
/// means the biometric door is an *addition*, not a restructure.
public protocol VaultKeyWrapper: Sendable {
    func wrap(_ vaultKey: SymmetricKey) throws -> Data
    func unwrap(_ wrapped: Data) throws -> SymmetricKey
}

// MARK: - Errors

public enum VaultCryptoError: Error, Equatable {
    case sealProducedNoCombinedRepresentation
}

// MARK: - VaultCrypto

/// Stateless crypto core for the password vault (vault-spec §2, §11 Slice 1).
///
/// Implements the **two-tier envelope**: an Argon2id-derived KEK AES-256-GCM-wraps a random 256-bit
/// vault key; the vault key wraps per-item keys; each item key AES-256-GCM-seals its payload. The same
/// vault key is reachable through independent "doors", each holding a separately-wrapped copy.
///
/// **Memory-zeroing policy (Slice 1 scope).** Every *transient* secret this layer materialises is
/// wiped before the call returns: the Argon2 KDF output, any raw key bytes copied out of a
/// `SymmetricKey` to be wrapped, and the recovery-code entropy buffer (`resetBytes`). The vendored
/// Argon2 C wipes its own internal scratch. The **live** vault key returned from `createVault` /
/// `unlock*` is a CryptoKit `SymmetricKey`, which zeroes its own backing store on deallocation — but
/// how long that key stays resident while UNLOCKED, and zeroing it on lock, is owned by the Slice 2
/// lock state machine (`VaultLock`), not by this stateless layer.
/// Seam test: `VaultCryptoTests.test_vaultKeyLifetime_isOwnedBy_VaultLock_slice2`.
public enum VaultCrypto {

    public static let currentSchemaVersion = 1
    public static let saltByteCount = 16

    // MARK: Random material (single CSPRNG source: CryptoKit)

    /// A fresh 16-byte salt from CryptoKit's CSPRNG (`SymmetricKey` is seeded from a secure RNG).
    public static func newSalt() -> Data {
        randomBytes(count: saltByteCount)
    }

    private static func randomBytes(count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    // MARK: KDF (doors 1 & 2 share this; different salt each)

    /// Argon2id: password (+ salt, params) → 256-bit KEK. The KDF output and password bytes are wiped
    /// once the `SymmetricKey` has copied them into its own secure storage.
    public static func deriveKEK(password: String, salt: Data, params: KDFParams) throws -> SymmetricKey {
        // NFC-normalise so the same typed password derives the same key across input methods.
        var pwData = Data(password.precomposedStringWithCanonicalMapping.utf8)
        defer { pwData.resetBytes(in: 0..<pwData.count) }

        var raw = try Argon2.deriveRawKey(password: pwData,
                                          salt: salt,
                                          memoryKiB: params.memoryKiB,
                                          iterations: params.iterations,
                                          parallelism: params.parallelism,
                                          length: 32)
        defer { raw.resetBytes(in: 0..<raw.count) }
        return SymmetricKey(data: raw)
    }

    // MARK: Key generation

    public static func generateVaultKey() -> SymmetricKey { SymmetricKey(size: .bits256) }
    public static func generateItemKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    // MARK: AEAD primitives (always fresh random nonce; store `.combined`)

    private static func seal(_ plaintext: Data, with key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)   // CryptoKit picks a random 96-bit nonce
        guard let combined = box.combined else { throw VaultCryptoError.sealProducedNoCombinedRepresentation }
        return combined
    }

    private static func open(_ combined: Data, with key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)            // throws on auth-tag failure (wrong key / tamper)
    }

    // MARK: Key wrapping

    private static func wrapKey(_ key: SymmetricKey, with wrappingKey: SymmetricKey) throws -> Data {
        var raw = key.withUnsafeBytes { Data($0) }
        defer { raw.resetBytes(in: 0..<raw.count) }
        return try seal(raw, with: wrappingKey)
    }

    private static func unwrapKey(_ wrapped: Data, with wrappingKey: SymmetricKey) throws -> SymmetricKey {
        var raw = try open(wrapped, with: wrappingKey)
        defer { raw.resetBytes(in: 0..<raw.count) }
        return SymmetricKey(data: raw)
    }

    public static func wrapVaultKey(_ vaultKey: SymmetricKey, with kek: SymmetricKey) throws -> Data {
        try wrapKey(vaultKey, with: kek)
    }
    public static func unwrapVaultKey(_ wrapped: Data, with kek: SymmetricKey) throws -> SymmetricKey {
        try unwrapKey(wrapped, with: kek)
    }
    public static func wrapItemKey(_ itemKey: SymmetricKey, with vaultKey: SymmetricKey) throws -> Data {
        try wrapKey(itemKey, with: vaultKey)
    }
    public static func unwrapItemKey(_ wrapped: Data, with vaultKey: SymmetricKey) throws -> SymmetricKey {
        try unwrapKey(wrapped, with: vaultKey)
    }

    // MARK: Item payloads

    public static func sealItem(_ plaintext: Data, itemKey: SymmetricKey) throws -> Data {
        try seal(plaintext, with: itemKey)
    }
    public static func openItem(_ combined: Data, itemKey: SymmetricKey) throws -> Data {
        try open(combined, with: itemKey)
    }

    /// Convenience: mint a per-item key, wrap it under the vault key, and seal the payload — the full
    /// tier-2 path producing a row-ready `SealedItem`.
    public static func encryptNewItem(_ plaintext: Data, vaultKey: SymmetricKey) throws -> SealedItem {
        let itemKey = generateItemKey()
        let wrapped = try wrapItemKey(itemKey, with: vaultKey)
        let ciphertext = try sealItem(plaintext, itemKey: itemKey)
        return SealedItem(wrappedItemKey: wrapped, ciphertext: ciphertext)
    }

    public static func decryptItem(_ item: SealedItem, vaultKey: SymmetricKey) throws -> Data {
        let itemKey = try unwrapItemKey(item.wrappedItemKey, with: vaultKey)
        return try openItem(item.ciphertext, itemKey: itemKey)
    }

    // MARK: Envelope orchestration (the two-tier flow end-to-end)

    /// First-run: generate the vault key, two independent salts, derive both KEKs, and wrap a copy of
    /// the same vault key under each. Returns the persisted metadata and the live vault key.
    public static func createVault(masterPassword: String,
                                   recoveryCode: String,
                                   params: KDFParams = .defaultMacOS) throws -> (meta: VaultMeta, vaultKey: SymmetricKey) {
        let vaultKey = generateVaultKey()
        let saltMaster = newSalt()
        let saltRecovery = newSalt()

        let kekMaster = try deriveKEK(password: masterPassword, salt: saltMaster, params: params)
        let kekRecovery = try deriveKEK(password: canonicalRecoveryCode(recoveryCode), salt: saltRecovery, params: params)

        let meta = VaultMeta(
            schemaVersion: currentSchemaVersion,
            kdfSaltMaster: saltMaster, kdfParamsMaster: params,
            wrappedVaultKeyMaster: try wrapVaultKey(vaultKey, with: kekMaster),
            kdfSaltRecovery: saltRecovery, kdfParamsRecovery: params,
            wrappedVaultKeyRecovery: try wrapVaultKey(vaultKey, with: kekRecovery)
        )
        return (meta, vaultKey)
    }

    /// Door 1 — everyday unlock. Throws on a wrong password (auth-tag failure).
    public static func unlockWithMaster(_ password: String, meta: VaultMeta) throws -> SymmetricKey {
        let kek = try deriveKEK(password: password, salt: meta.kdfSaltMaster, params: meta.kdfParamsMaster)
        return try unwrapVaultKey(meta.wrappedVaultKeyMaster, with: kek)
    }

    /// Door 2 — recovery code unlock (used to reset a lost master). Throws on a wrong code. The code is
    /// canonicalized first (see `canonicalRecoveryCode`), so formatting/transcription variations match.
    public static func unlockWithRecovery(_ code: String, meta: VaultMeta) throws -> SymmetricKey {
        let kek = try deriveKEK(password: canonicalRecoveryCode(code), salt: meta.kdfSaltRecovery, params: meta.kdfParamsRecovery)
        return try unwrapVaultKey(meta.wrappedVaultKeyRecovery, with: kek)
    }

    /// Re-wrap **only copy 2** (the recovery door) with a fresh code + salt — the "regenerate Recovery
    /// Kit" path. The master copy is untouched; the old recovery code stops working. Requires the
    /// already-unlocked vault key.
    public static func rewrapForNewRecovery(vaultKey: SymmetricKey,
                                            newRecoveryCode: String,
                                            meta: VaultMeta,
                                            params: KDFParams? = nil) throws -> VaultMeta {
        let effectiveParams = params ?? meta.kdfParamsRecovery
        let salt = newSalt()
        let kek = try deriveKEK(password: canonicalRecoveryCode(newRecoveryCode), salt: salt, params: effectiveParams)

        var updated = meta
        updated.kdfSaltRecovery = salt
        updated.kdfParamsRecovery = effectiveParams
        updated.wrappedVaultKeyRecovery = try wrapVaultKey(vaultKey, with: kek)
        return updated
    }

    /// Master-password change: re-wrap **only copy 1** (fresh salt + KEK from the new password). The
    /// recovery copy is untouched. Requires the already-unlocked vault key, so no old password needed.
    public static func rewrapForNewMaster(vaultKey: SymmetricKey,
                                          newPassword: String,
                                          meta: VaultMeta,
                                          params: KDFParams? = nil) throws -> VaultMeta {
        let effectiveParams = params ?? meta.kdfParamsMaster
        let salt = newSalt()
        let kek = try deriveKEK(password: newPassword, salt: salt, params: effectiveParams)

        var updated = meta
        updated.kdfSaltMaster = salt
        updated.kdfParamsMaster = effectiveParams
        updated.wrappedVaultKeyMaster = try wrapVaultKey(vaultKey, with: kek)
        return updated
    }

    /// Recovery flow: unlock with the recovery code, then set a new master password (re-wrapping copy 1).
    public static func recoverAndResetMaster(recoveryCode: String,
                                             newPassword: String,
                                             meta: VaultMeta) throws -> (meta: VaultMeta, vaultKey: SymmetricKey) {
        let vaultKey = try unlockWithRecovery(recoveryCode, meta: meta)
        let updated = try rewrapForNewMaster(vaultKey: vaultKey, newPassword: newPassword, meta: meta)
        return (updated, vaultKey)
    }

    // MARK: Recovery code (vault-spec §14 default: grouped alphanumeric)

    /// Crockford base-32 alphabet (omits `I L O U` to avoid transcription ambiguity). 32 symbols → a
    /// clean 5 bits per character.
    private static let recoveryAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Canonical form a recovery code is KDF'd against, so display/transcription differences don't
    /// break unlock: uppercase, map the Crockford look-alikes (`O→0`, `I/L→1`), and keep **only**
    /// alphabet symbols (dropping hyphens, spaces, newlines, smart-dashes — anything else). Both
    /// generation and unlock derive the KEK from this form, so a code copied without a hyphen, in a
    /// different case, or with stray whitespace still matches.
    public static func canonicalRecoveryCode(_ s: String) -> String {
        let allowed = Set(recoveryAlphabet)
        var out = ""
        out.reserveCapacity(s.count)
        for raw in s.uppercased() {
            let mapped: Character
            switch raw {
            case "O": mapped = "0"
            case "I", "L": mapped = "1"
            default: mapped = raw
            }
            if allowed.contains(mapped) { out.append(mapped) }
        }
        return out
    }

    /// A high-entropy printable recovery code, e.g. `A1B2C-…` in `groups` of `groupSize`. Default
    /// 7×5 = 35 chars × 5 bits ≈ **175 bits**. CSPRNG-sourced; intended for the printed Recovery Kit.
    public static func generateRecoveryCode(groups: Int = 7, groupSize: Int = 5) -> String {
        let count = groups * groupSize
        var entropy = randomBytes(count: count)
        defer { entropy.resetBytes(in: 0..<entropy.count) }

        var chars: [Character] = []
        chars.reserveCapacity(count)
        for byte in entropy {
            chars.append(recoveryAlphabet[Int(byte) & 31])   // low 5 bits → uniform over 32 symbols
        }
        return stride(from: 0, to: count, by: groupSize)
            .map { String(chars[$0..<min($0 + groupSize, count)]) }
            .joined(separator: "-")
    }
}
