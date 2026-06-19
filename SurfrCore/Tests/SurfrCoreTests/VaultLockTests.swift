import XCTest
import CryptoKit
@testable import SurfrCore

final class VaultLockTests: XCTestCase {

    private static let fastParams = KDFParams(memoryKiB: 256, iterations: 1, parallelism: 1)

    private func rawBytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    private func makeVault(master: String = "master-pw") throws -> (meta: VaultMeta, vaultKey: SymmetricKey) {
        let created = try VaultCrypto.createVault(masterPassword: master, recoveryCode: "recovery-code", params: Self.fastParams)
        return (created.meta, created.vaultKey)
    }

    // 8 — Locked by default; a bad password does not unlock.
    func test_lockedByDefault_and_wrongPasswordStaysLocked() throws {
        let v = try makeVault(master: "right")
        let lock = VaultLock()
        XCTAssertEqual(lock.state, .locked)
        XCTAssertThrowsError(try lock.withVaultKey { _ in })

        XCTAssertThrowsError(try lock.unlockWithMaster("wrong", meta: v.meta))
        XCTAssertEqual(lock.state, .locked, "a failed unlock must leave the lock LOCKED")

        try lock.unlockWithMaster("right", meta: v.meta)
        XCTAssertEqual(lock.state, .unlocked)
    }

    // 6 — Unlock gives the right key; lock() evicts and denies access.
    func test_unlock_useKey_then_lockEvicts() throws {
        let v = try makeVault()
        let lock = VaultLock()

        try lock.unlockWithMaster("master-pw", meta: v.meta)
        // The key handed into the closure matches the real vault key and can decrypt.
        let payload = Data("a-secret".utf8)
        let item = try VaultCrypto.encryptNewItem(payload, vaultKey: v.vaultKey)
        let decrypted = try lock.withVaultKey { try VaultCrypto.decryptItem(item, vaultKey: $0) }
        XCTAssertEqual(decrypted, payload)

        lock.lock()
        XCTAssertEqual(lock.state, .locked)
        XCTAssertThrowsError(try lock.withVaultKey { _ in }) { XCTAssertEqual($0 as? VaultLockError, .locked) }
        // lock() is idempotent.
        lock.lock()
        XCTAssertEqual(lock.state, .locked)
    }

    // 6 (zeroing) — VaultKeyResidency.evict() deterministically zeroes the bytes it owns.
    func test_residency_evict_zeroesBuffer() throws {
        let key = VaultCrypto.generateVaultKey()
        let residency = VaultKeyResidency(key)

        // Before eviction: makeKey() reproduces the original key bytes.
        XCTAssertEqual(rawBytes(residency.makeKey()), rawBytes(key))
        XCTAssertFalse(residency.isZeroedForTest)

        residency.evict()
        XCTAssertTrue(residency.isZeroedForTest, "evict() must zero every byte of the residency buffer")
        // evict() is idempotent.
        residency.evict()
        XCTAssertTrue(residency.isZeroedForTest)
    }

    // 7 — Idle timeout fires; noteActivity() defers it; withVaultKey does NOT defer it.
    func test_idleTimeout_and_activityReset() throws {
        // Controllable clock.
        final class Clock: @unchecked Sendable { var t: Date = Date(timeIntervalSince1970: 1_000_000) }
        let clock = Clock()
        let v = try makeVault()
        let lock = VaultLock(autoLockInterval: 300, now: { clock.t })

        try lock.unlockWithMaster("master-pw", meta: v.meta)

        // Not yet idle.
        clock.t = clock.t.addingTimeInterval(299)
        XCTAssertFalse(lock.lockIfIdle())
        XCTAssertEqual(lock.state, .unlocked)

        // Crossing the threshold locks.
        clock.t = clock.t.addingTimeInterval(1)        // now +300
        XCTAssertTrue(lock.lockIfIdle())
        XCTAssertEqual(lock.state, .locked)

        // Re-unlock; activity defers the timeout.
        try lock.unlockWithMaster("master-pw", meta: v.meta)
        clock.t = clock.t.addingTimeInterval(290)
        lock.noteActivity()                            // resets lastActivity to now
        clock.t = clock.t.addingTimeInterval(290)      // 290 since activity (< 300)
        XCTAssertFalse(lock.lockIfIdle())
        XCTAssertEqual(lock.state, .unlocked)

        // withVaultKey must NOT count as activity: read, then advance past the window → it locks.
        _ = try lock.withVaultKey { rawBytes($0) }
        clock.t = clock.t.addingTimeInterval(300)      // 590 since the last noteActivity()
        XCTAssertTrue(lock.lockIfIdle(), "withVaultKey must not defer auto-lock")
        XCTAssertEqual(lock.state, .locked)
    }

    // Recovery-code unlock path through VaultLock.
    func test_unlockWithRecovery() throws {
        let created = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: "the-recovery-code", params: Self.fastParams)
        let lock = VaultLock()
        try lock.unlockWithRecovery("the-recovery-code", meta: created.meta)
        XCTAssertEqual(lock.state, .unlocked)
        let got = try lock.withVaultKey { self.rawBytes($0) }
        XCTAssertEqual(got, rawBytes(created.vaultKey))

        XCTAssertThrowsError(try VaultLock().unlockWithRecovery("wrong-code", meta: created.meta))
    }
}
