import XCTest
import CryptoKit
@testable import SurfrCore

final class VaultCryptoTests: XCTestCase {

    // Fast KDF params for functional tests (correctness is independent of cost magnitude).
    // Real-world cost is exercised separately in `test_deriveKEK_timing_*`.
    private static let fastParams = KDFParams(memoryKiB: 256, iterations: 1, parallelism: 1)

    // Test-only: compare two symmetric keys by raw bytes.
    private func rawBytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    private func makeVault(master: String = "correct horse battery staple six",
                           recovery: String? = nil) throws -> (meta: VaultMeta, vaultKey: SymmetricKey, recovery: String) {
        let code = recovery ?? VaultCrypto.generateRecoveryCode()
        let created = try VaultCrypto.createVault(masterPassword: master, recoveryCode: code, params: Self.fastParams)
        return (created.meta, created.vaultKey, code)
    }

    // 1 — Vault-key wrap/unwrap round-trip (master door).
    func test_vaultKey_wrapUnwrap_roundTrip() throws {
        let kek = try VaultCrypto.deriveKEK(password: "master-pw", salt: VaultCrypto.newSalt(), params: Self.fastParams)
        let vaultKey = VaultCrypto.generateVaultKey()
        let wrapped = try VaultCrypto.wrapVaultKey(vaultKey, with: kek)
        let unwrapped = try VaultCrypto.unwrapVaultKey(wrapped, with: kek)
        XCTAssertEqual(rawBytes(vaultKey), rawBytes(unwrapped))
    }

    // 2 — Item round-trip (item-key wrap + payload seal/open).
    func test_item_encryptDecrypt_roundTrip() throws {
        let v = try makeVault()
        let payload = Data(#"{"username":"a@b.com","password":"hunter2"}"#.utf8)
        let item = try VaultCrypto.encryptNewItem(payload, vaultKey: v.vaultKey)
        let recovered = try VaultCrypto.decryptItem(item, vaultKey: v.vaultKey)
        XCTAssertEqual(payload, recovered)
        // The ciphertext must not contain the plaintext.
        XCTAssertNil(item.ciphertext.range(of: Data("hunter2".utf8)))
    }

    // 3 — Tamper / auth-tag failure on each wrapped/sealed blob.
    func test_tamper_authTagFailure() throws {
        let v = try makeVault()
        let item = try VaultCrypto.encryptNewItem(Data("secret".utf8), vaultKey: v.vaultKey)

        func flipLastByte(_ data: Data) -> Data {
            var d = data; d[d.count - 1] ^= 0xFF; return d
        }

        // Tampered wrapped vault key.
        XCTAssertThrowsError(try VaultCrypto.unlockWithMaster("correct horse battery staple six",
                                                              meta: { var m = v.meta; m.wrappedVaultKeyMaster = flipLastByte(m.wrappedVaultKeyMaster); return m }()))
        // Tampered wrapped item key.
        XCTAssertThrowsError(try VaultCrypto.decryptItem(SealedItem(wrappedItemKey: flipLastByte(item.wrappedItemKey),
                                                                    ciphertext: item.ciphertext),
                                                         vaultKey: v.vaultKey))
        // Tampered item ciphertext.
        XCTAssertThrowsError(try VaultCrypto.decryptItem(SealedItem(wrappedItemKey: item.wrappedItemKey,
                                                                    ciphertext: flipLastByte(item.ciphertext)),
                                                         vaultKey: v.vaultKey))
    }

    // 4 — Wrong master password is rejected.
    func test_wrongMasterPassword_throws() throws {
        let v = try makeVault(master: "the-right-one")
        XCTAssertThrowsError(try VaultCrypto.unlockWithMaster("the-wrong-one", meta: v.meta))
        // Sanity: the right one still works.
        let key = try VaultCrypto.unlockWithMaster("the-right-one", meta: v.meta)
        XCTAssertEqual(rawBytes(key), rawBytes(v.vaultKey))
    }

    // 5 — Master-password change re-wraps copy 1 only; recovery copy untouched.
    func test_masterPasswordChange_rewrap() throws {
        let v = try makeVault(master: "old-master")
        let newMeta = try VaultCrypto.rewrapForNewMaster(vaultKey: v.vaultKey,
                                                         newPassword: "new-master",
                                                         meta: v.meta,
                                                         params: Self.fastParams)
        // Old master no longer works; new master unlocks the same vault key.
        XCTAssertThrowsError(try VaultCrypto.unlockWithMaster("old-master", meta: newMeta))
        XCTAssertEqual(rawBytes(try VaultCrypto.unlockWithMaster("new-master", meta: newMeta)), rawBytes(v.vaultKey))
        // Recovery copy is unchanged and still opens the same vault key.
        XCTAssertEqual(newMeta.wrappedVaultKeyRecovery, v.meta.wrappedVaultKeyRecovery)
        XCTAssertEqual(rawBytes(try VaultCrypto.unlockWithRecovery(v.recovery, meta: newMeta)), rawBytes(v.vaultKey))
    }

    // 6 — Recovery-code door opens the same vault key as the master door.
    func test_recoveryCode_unlocksSameVaultKey() throws {
        let v = try makeVault()
        let viaMaster = try VaultCrypto.unlockWithMaster("correct horse battery staple six", meta: v.meta)
        let viaRecovery = try VaultCrypto.unlockWithRecovery(v.recovery, meta: v.meta)
        XCTAssertEqual(rawBytes(viaMaster), rawBytes(viaRecovery))
        XCTAssertEqual(rawBytes(viaRecovery), rawBytes(v.vaultKey))

        // Both doors decrypt the same item payload.
        let payload = Data("shared-secret".utf8)
        let item = try VaultCrypto.encryptNewItem(payload, vaultKey: viaMaster)
        XCTAssertEqual(try VaultCrypto.decryptItem(item, vaultKey: viaRecovery), payload)
    }

    // 7 — Full recovery reset: new master works, recovery still works, old master fails.
    func test_recoverAndResetMaster() throws {
        let v = try makeVault(master: "forgotten-master")
        let reset = try VaultCrypto.recoverAndResetMaster(recoveryCode: v.recovery,
                                                          newPassword: "fresh-master",
                                                          meta: v.meta)
        XCTAssertEqual(rawBytes(reset.vaultKey), rawBytes(v.vaultKey))
        XCTAssertThrowsError(try VaultCrypto.unlockWithMaster("forgotten-master", meta: reset.meta))
        XCTAssertEqual(rawBytes(try VaultCrypto.unlockWithMaster("fresh-master", meta: reset.meta)), rawBytes(v.vaultKey))
        XCTAssertEqual(rawBytes(try VaultCrypto.unlockWithRecovery(v.recovery, meta: reset.meta)), rawBytes(v.vaultKey))
    }

    // 8 — Salt and nonce uniqueness (no reuse).
    func test_saltAndNonce_uniqueness() throws {
        // Distinct salts across vault creations.
        let a = try makeVault(); let b = try makeVault()
        XCTAssertNotEqual(a.meta.kdfSaltMaster, b.meta.kdfSaltMaster)
        XCTAssertNotEqual(a.meta.kdfSaltMaster, a.meta.kdfSaltRecovery)
        XCTAssertNotEqual(a.meta.wrappedVaultKeyMaster, a.meta.wrappedVaultKeyRecovery)

        // Sealing identical plaintext twice yields different ciphertext (fresh random nonce).
        let key = VaultCrypto.generateItemKey()
        let p = Data("same-plaintext".utf8)
        XCTAssertNotEqual(try VaultCrypto.sealItem(p, itemKey: key), try VaultCrypto.sealItem(p, itemKey: key))
    }

    // 9 — KDF determinism and parameter binding.
    func test_kdf_determinism_and_paramBinding() throws {
        let salt = VaultCrypto.newSalt()
        let k1 = try VaultCrypto.deriveKEK(password: "pw", salt: salt, params: Self.fastParams)
        let k2 = try VaultCrypto.deriveKEK(password: "pw", salt: salt, params: Self.fastParams)
        XCTAssertEqual(rawBytes(k1), rawBytes(k2), "same pw+salt+params must be deterministic")

        // Changing each cost parameter must change the derived key (params are honored).
        let moreMemory = try VaultCrypto.deriveKEK(password: "pw", salt: salt, params: KDFParams(memoryKiB: 512, iterations: 1, parallelism: 1))
        let moreIters  = try VaultCrypto.deriveKEK(password: "pw", salt: salt, params: KDFParams(memoryKiB: 256, iterations: 2, parallelism: 1))
        XCTAssertNotEqual(rawBytes(k1), rawBytes(moreMemory))
        XCTAssertNotEqual(rawBytes(k1), rawBytes(moreIters))

        // Different salt → different key.
        let otherSalt = try VaultCrypto.deriveKEK(password: "pw", salt: VaultCrypto.newSalt(), params: Self.fastParams)
        XCTAssertNotEqual(rawBytes(k1), rawBytes(otherSalt))
    }

    // 10 — Recovery-code format / entropy.
    func test_recoveryCode_format() {
        let code = VaultCrypto.generateRecoveryCode()
        let groups = code.split(separator: "-")
        XCTAssertEqual(groups.count, 7)
        XCTAssertTrue(groups.allSatisfy { $0.count == 5 })

        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        XCTAssertTrue(code.replacingOccurrences(of: "-", with: "").allSatisfy { allowed.contains($0) })

        // 35 symbols × 5 bits = 175 bits — comfortably above the 128-bit bar.
        XCTAssertGreaterThanOrEqual(35 * 5, 128)

        // Two generated codes differ (CSPRNG, not constant).
        XCTAssertNotEqual(code, VaultCrypto.generateRecoveryCode())
    }

    // 11a — Recovery code canonicalization: format/transcription variations of the SAME code unlock.
    func test_recoveryCode_canonicalization_toleratesFormatting() throws {
        let code = VaultCrypto.generateRecoveryCode()          // e.g. "BXGES-VM6ZS-…"
        let created = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: code, params: Self.fastParams)

        // Variants a careless copy/paste or retype might produce — all must still unlock.
        let variants = [
            code,                                              // exact
            code.replacingOccurrences(of: "-", with: ""),      // hyphens dropped at a PDF line-wrap
            code.lowercased(),                                 // case lost
            "  \(code)\n",                                     // stray whitespace/newline
            code.replacingOccurrences(of: "-", with: " "),     // hyphens became spaces
        ]
        for v in variants {
            let key = try VaultCrypto.unlockWithRecovery(v, meta: created.meta)
            XCTAssertEqual(rawBytes(key), rawBytes(created.vaultKey), "variant failed to unlock: \(v)")
        }

        // Crockford look-alike mapping is applied (O→0, I/L→1; hyphens/spaces dropped).
        XCTAssertEqual(VaultCrypto.canonicalRecoveryCode("o0-Il L"), "00111")
    }

    // 11b — Regenerate Recovery Kit: a fresh recovery code re-wraps copy 2; old code dies, master intact.
    func test_rewrapForNewRecovery() throws {
        let oldCode = VaultCrypto.generateRecoveryCode()
        let v = try VaultCrypto.createVault(masterPassword: "master", recoveryCode: oldCode, params: Self.fastParams)

        let newCode = VaultCrypto.generateRecoveryCode()
        let newMeta = try VaultCrypto.rewrapForNewRecovery(vaultKey: v.vaultKey, newRecoveryCode: newCode,
                                                           meta: v.meta, params: Self.fastParams)

        XCTAssertThrowsError(try VaultCrypto.unlockWithRecovery(oldCode, meta: newMeta), "old code must stop working")
        XCTAssertEqual(rawBytes(try VaultCrypto.unlockWithRecovery(newCode, meta: newMeta)), rawBytes(v.vaultKey))
        // Master door untouched.
        XCTAssertEqual(newMeta.wrappedVaultKeyMaster, v.meta.wrappedVaultKeyMaster)
        XCTAssertEqual(rawBytes(try VaultCrypto.unlockWithMaster("master", meta: newMeta)), rawBytes(v.vaultKey))
    }

    // 11 — No-plaintext-logging guard: the crypto layer must not log.
    func test_cryptoLayer_hasNoLoggingCalls() throws {
        let here = URL(fileURLWithPath: #filePath)                       // …/Tests/SurfrCoreTests/VaultCryptoTests.swift
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/SurfrCore")
        for name in ["VaultCrypto.swift", "Argon2.swift", "VaultStore.swift", "VaultLock.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for needle in ["print(", "NSLog(", "os_log(", "debugPrint("] {
                XCTAssertFalse(text.contains(needle), "\(name) must not contain \(needle)")
            }
        }
    }

    // 12 (addition c) — Non-asserting timing: deriveKEK at the real macOS params should land sub-second
    // on the M1 Pro. Measured and printed, never asserted (CI-machine-independent).
    func test_deriveKEK_timing_defaultMacOS_nonAsserting() throws {
        let salt = VaultCrypto.newSalt()
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            _ = try VaultCrypto.deriveKEK(password: "a-realistic-master-passphrase",
                                          salt: salt, params: .defaultMacOS)
        }
        print("⏱  deriveKEK @ defaultMacOS (m=64MiB,t=3,p=1): \(elapsed)")
    }

    // Seam (Slice 1 deferred → Slice 2 fulfilled): the live vault-key residency and zero-on-lock are
    // owned by VaultLock. Formerly an XCTSkip; now a real passing test.
    //   (1) VaultKeyResidency.evict() deterministically zeroes the key bytes it owns.
    //   (2) VaultLock.lock() denies key access and drops to .locked.
    // Together: "lock eviction actually clears the key." Fuller coverage in VaultLockTests.
    func test_vaultKeyLifetime_isOwnedBy_VaultLock_slice2() throws {
        // (1) deterministic zeroing of the owned buffer
        let residency = VaultKeyResidency(VaultCrypto.generateVaultKey())
        XCTAssertFalse(residency.isZeroedForTest)
        residency.evict()
        XCTAssertTrue(residency.isZeroedForTest, "evict() must zero the residency buffer")

        // (2) VaultLock denies the key once locked
        let v = try makeVault(master: "seam-master")
        let lock = VaultLock()
        try lock.unlockWithMaster("seam-master", meta: v.meta)
        XCTAssertEqual(lock.state, .unlocked)
        let probe = try lock.withVaultKey { rawBytes($0) }
        XCTAssertEqual(probe, rawBytes(v.vaultKey))

        lock.lock()
        XCTAssertEqual(lock.state, .locked)
        XCTAssertThrowsError(try lock.withVaultKey { _ in }) { error in
            XCTAssertEqual(error as? VaultLockError, .locked)
        }
    }
}
