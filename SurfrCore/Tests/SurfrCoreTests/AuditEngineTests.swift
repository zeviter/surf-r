import XCTest
import CryptoKit
@testable import SurfrCore

/// Slice 9 — the pure audit policy (weak / reused / 2FA-available / junk-host), the keyed reuse-token
/// derivations, and the bundled 2FA Directory loader. All headless and deterministic.
final class AuditEngineTests: XCTestCase {

    // MARK: Weak — boundary behaviour around the length floor and the entropy threshold.

    func test_isWeak_empty_isNotWeak() {
        // A TOTP-only item has no password — there is nothing to be "weak".
        XCTAssertFalse(AuditEngine.isWeak(password: ""))
    }

    func test_isWeak_tooShort_isWeak_evenIfMixed() {
        // 7 chars trips the length floor regardless of character variety.
        XCTAssertTrue(AuditEngine.isWeak(password: "Aa1!Aa1"))   // 7 chars
    }

    func test_isWeak_eightLowercase_belowEntropyFloor_isWeak() {
        // 8 × log2(26) ≈ 37.6 bits < 50.
        XCTAssertTrue(AuditEngine.isWeak(password: "abcdefgh"))
    }

    func test_isWeak_eightAllClasses_aboveFloor_isNotWeak() {
        // 8 × log2(95) ≈ 52.6 bits ≥ 50, length ≥ 8.
        XCTAssertFalse(AuditEngine.isWeak(password: "Aa1!Aa1!"))
    }

    func test_isWeak_longLowercasePassphrase_isNotWeak() {
        // 16 × log2(26) ≈ 75 bits — length carries it past the floor.
        XCTAssertFalse(AuditEngine.isWeak(password: "correcthorsebatte"))   // 17 lowercase
    }

    func test_observedEntropy_growsWithPoolAndLength() {
        XCTAssertGreaterThan(AuditEngine.observedEntropyBits(for: "Aa1!Aa1!"),
                             AuditEngine.observedEntropyBits(for: "aaaaaaaa"))
        XCTAssertGreaterThan(AuditEngine.observedEntropyBits(for: "aaaaaaaaaaaaaaaa"),
                             AuditEngine.observedEntropyBits(for: "aaaaaaaa"))
    }

    // MARK: Reused — grouping opaque tokens.

    func test_reusedItemIDs_sharedTokenGroups_singletonsDont() {
        let a = UUID(), b = UUID(), c = UUID()
        let shared = Data("T".utf8), unique = Data("U".utf8)
        let tokens: [UUID: Data] = [a: shared, b: shared, c: unique]
        XCTAssertEqual(AuditEngine.reusedItemIDs(tokensByItem: tokens), [a, b])
    }

    func test_reuseGroupSizes_countShares() {
        let a = UUID(), b = UUID(), c = UUID()
        let shared = Data("T".utf8), unique = Data("U".utf8)
        let sizes = AuditEngine.reuseGroupSizes(tokensByItem: [a: shared, b: shared, c: unique])
        XCTAssertEqual(sizes[a], 2)
        XCTAssertEqual(sizes[b], 2)
        XCTAssertEqual(sizes[c], 1)
    }

    func test_reuseClusters_groupsSharedPasswords_largestFirst_singletonsExcluded() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        let t1 = Data("one".utf8), t2 = Data("two".utf8), uniq = Data("uniq".utf8)
        // t1 shared by 3 (a,b,c), t2 shared by 2 (d,e), uniq by 1 (excluded).
        let clusters = AuditEngine.reuseClusters(
            tokensByItem: [a: t1, b: t1, c: t1, d: t2, e: t2, UUID(): uniq]
        ) { $0.uuidString < $1.uuidString }
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters[0].count, 3)            // larger cluster first
        XCTAssertEqual(clusters[1].count, 2)
        XCTAssertEqual(Set(clusters[0]), [a, b, c])
        XCTAssertEqual(Set(clusters[1]), [d, e])
    }

    func test_isNonLoginHostMarker_recognizesLastPassSecureNote() {
        XCTAssertTrue(AuditEngine.isNonLoginHostMarker("sn"))
        XCTAssertTrue(AuditEngine.isNonLoginHostMarker(" SN "))
        XCTAssertFalse(AuditEngine.isNonLoginHostMarker("snapchat.com"))
        XCTAssertFalse(AuditEngine.isNonLoginHostMarker(""))
    }

    // MARK: 2FA-available.

    func test_is2FAAvailable_domainInSet_noTOTP_flagged() {
        XCTAssertTrue(AuditEngine.is2FAAvailable(registrableDomains: ["github.com"],
                                                 hasTOTP: false, totpDomains: ["github.com"]))
    }

    func test_is2FAAvailable_hasTOTP_notFlagged() {
        XCTAssertFalse(AuditEngine.is2FAAvailable(registrableDomains: ["github.com"],
                                                  hasTOTP: true, totpDomains: ["github.com"]))
    }

    func test_is2FAAvailable_domainAbsent_notFlagged() {
        // Absence from the dataset is NOT proof a site lacks 2FA — but we don't flag it.
        XCTAssertFalse(AuditEngine.is2FAAvailable(registrableDomains: ["obscure.example"],
                                                  hasTOTP: false, totpDomains: ["github.com"]))
    }

    // MARK: Junk host.

    func test_isJunkHost_validDomain_notJunk() {
        XCTAssertFalse(AuditEngine.isJunkHost(resolvedDomains: ["google.com"], rawHostsNonEmpty: true, hasPassword: true))
    }

    func test_isJunkHost_invalidNonEmptyHost_isJunk() {
        // e.g. "sn" — present but unresolvable to a real registrable domain.
        XCTAssertTrue(AuditEngine.isJunkHost(resolvedDomains: ["sn"], rawHostsNonEmpty: true, hasPassword: true))
    }

    func test_isJunkHost_noHostButHasPassword_isJunk() {
        XCTAssertTrue(AuditEngine.isJunkHost(resolvedDomains: [], rawHostsNonEmpty: false, hasPassword: true))
    }

    func test_isJunkHost_noHostNoPassword_isNotJunk() {
        // Hostless TOTP-only / passwordless item is legitimately hostless.
        XCTAssertFalse(AuditEngine.isJunkHost(resolvedDomains: [], rawHostsNonEmpty: false, hasPassword: false))
    }

    func test_isLikelyRegistrableDomain() {
        XCTAssertTrue(AuditEngine.isLikelyRegistrableDomain("example.co.uk"))
        XCTAssertFalse(AuditEngine.isLikelyRegistrableDomain("sn"))
        XCTAssertFalse(AuditEngine.isLikelyRegistrableDomain(""))
    }

    // MARK: Keyed reuse token (VaultCrypto) — equality only, never the password, key-dependent.

    func test_reuseToken_samePasswordSameKey_equal_differentPasswordDiffers() {
        let auditKey = VaultCrypto.deriveAuditKey(vaultKey: SymmetricKey(size: .bits256))
        let t1 = VaultCrypto.auditReuseToken(normalizedPassword: AuditEngine.normalizedPasswordData("hunter2longpw"), auditKey: auditKey)
        let t2 = VaultCrypto.auditReuseToken(normalizedPassword: AuditEngine.normalizedPasswordData("hunter2longpw"), auditKey: auditKey)
        let t3 = VaultCrypto.auditReuseToken(normalizedPassword: AuditEngine.normalizedPasswordData("different-pw!"), auditKey: auditKey)
        XCTAssertEqual(t1, t2)
        XCTAssertNotEqual(t1, t3)
        XCTAssertEqual(t1.count, 32)   // HMAC-SHA256
    }

    func test_reuseToken_isKeyed_notABareHashOfThePassword() {
        let password = "S3cret-Password-123"
        let key1 = VaultCrypto.deriveAuditKey(vaultKey: SymmetricKey(size: .bits256))
        let key2 = VaultCrypto.deriveAuditKey(vaultKey: SymmetricKey(size: .bits256))
        let normalized = AuditEngine.normalizedPasswordData(password)

        // Different audit keys ⇒ different tokens (so it isn't an unsalted hash anyone could recompute).
        XCTAssertNotEqual(VaultCrypto.auditReuseToken(normalizedPassword: normalized, auditKey: key1),
                          VaultCrypto.auditReuseToken(normalizedPassword: normalized, auditKey: key2))

        // The token is not a bare SHA-256 of the password either.
        let bareHash = Data(SHA256.hash(data: normalized))
        XCTAssertNotEqual(VaultCrypto.auditReuseToken(normalizedPassword: normalized, auditKey: key1), bareHash)

        // The token bytes do not contain the password bytes.
        let token = VaultCrypto.auditReuseToken(normalizedPassword: normalized, auditKey: key1)
        XCTAssertNil(token.range(of: normalized))
    }

    func test_auditKey_stableAcrossMasterPasswordChange() throws {
        // The vault key is re-WRAPPED on a master-password change, never regenerated, so the audit key
        // (derived from the vault key) is stable — the cache survives a master change. (vault-spec §6.)
        let params = KDFParams(memoryKiB: 256, iterations: 1, parallelism: 1)
        let (meta, vaultKey) = try VaultCrypto.createVault(masterPassword: "old-master", recoveryCode: "r-code", params: params)
        let before = VaultCrypto.deriveAuditKey(vaultKey: vaultKey)

        let newMeta = try VaultCrypto.rewrapForNewMaster(vaultKey: vaultKey, newPassword: "new-master", meta: meta)
        let reVaultKey = try VaultCrypto.unlockWithMaster("new-master", meta: newMeta)
        let after = VaultCrypto.deriveAuditKey(vaultKey: reVaultKey)

        XCTAssertEqual(before.withUnsafeBytes { Data($0) }, after.withUnsafeBytes { Data($0) })
        // And the self-check is correspondingly stable.
        XCTAssertEqual(VaultCrypto.auditKeyCheck(auditKey: before), VaultCrypto.auditKeyCheck(auditKey: after))
    }

    // MARK: Bundled 2FA Directory snapshot — present, non-empty, dated, attributed; fails loud if not.

    func test_twoFADirectory_loadsNonEmptyDatedSnapshot() {
        XCTAssertGreaterThan(TwoFADirectory.domains.count, 500)
        XCTAssertTrue(TwoFADirectory.domains.contains("zoom.us"))   // present + TOTP in the source
        XCTAssertEqual(TwoFADirectory.snapshotDate, "2026-06-24")
        XCTAssertEqual(TwoFADirectory.attribution, "Data sourced from 2FA Directory by 2factorauth")
    }
}
