import Foundation
import CArgon2

/// Thin, import-clean Swift wrapper over the vendored Argon2id reference C (`CArgon2`).
///
/// Exposes **raw key derivation only** — the password-hash *string* / encoding API is intentionally
/// not surfaced; the vault never stores or compares Argon2 encoded strings, it derives KEK bytes.
/// This is the one primitive CryptoKit lacks; everything else in the vault uses CryptoKit.
enum Argon2 {
    /// The salt floor enforced by the reference implementation (`ARGON2_MIN_SALT_LENGTH`). The vault
    /// uses 16-byte salts, comfortably above this.
    static let minimumSaltBytes = 8

    enum Failure: Error, Equatable {
        /// The C routine returned a non-`ARGON2_OK` status; carries the raw Argon2 error code.
        case derivationFailed(code: Int32)
        case saltTooShort
    }

    /// Derive `length` bytes (default 32 → a 256-bit key) with Argon2id over the reference C.
    ///
    /// - The caller owns `password` / `salt`. The returned key is the only output; on failure the
    ///   partially-written buffer is wiped before throwing.
    /// - `memoryKiB`, `iterations`, `parallelism` map to Argon2's `m_cost`, `t_cost`, `p`.
    static func deriveRawKey(password: Data,
                             salt: Data,
                             memoryKiB: UInt32,
                             iterations: UInt32,
                             parallelism: UInt32,
                             length: Int = 32) throws -> Data {
        guard salt.count >= minimumSaltBytes else { throw Failure.saltTooShort }

        var out = Data(count: length)
        let status: Int32 = out.withUnsafeMutableBytes { outRaw in
            password.withUnsafeBytes { pwdRaw in
                salt.withUnsafeBytes { saltRaw in
                    argon2id_hash_raw(
                        iterations,                 // t_cost
                        memoryKiB,                  // m_cost (KiB)
                        parallelism,                // p
                        pwdRaw.baseAddress, password.count,
                        saltRaw.baseAddress, salt.count,
                        outRaw.baseAddress, length
                    )
                }
            }
        }

        guard status == 0 /* ARGON2_OK */ else {
            out.resetBytes(in: 0..<out.count)
            throw Failure.derivationFailed(code: status)
        }
        return out
    }
}
