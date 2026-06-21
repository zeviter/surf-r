import XCTest
import CryptoKit
import LocalAuthentication
@testable import Surfr

/// In-memory stand-in for the Secure Enclave door, so the gate's fallback logic can be tested without
/// hardware. The real SE/ECIES/Keychain path is verified on-device (driven run).
final class MockBiometricUnlock: BiometricUnlocking, @unchecked Sendable {
    var available = true
    private(set) var stored: SymmetricKey?
    /// When set, `unlock()` throws this instead of returning the stored key.
    var nextUnlockFailure: BiometricFailure?

    private(set) var enableCount = 0
    private(set) var disableCount = 0
    private(set) var unlockCount = 0
    private(set) var cancelCount = 0

    var isAvailable: Bool { available }
    var isEnabled: Bool { stored != nil }

    func enable(vaultKey: SymmetricKey) throws { stored = vaultKey; enableCount += 1 }
    func disable() { stored = nil; disableCount += 1 }
    func unlock() async throws -> SymmetricKey {
        unlockCount += 1
        if let f = nextUnlockFailure { throw f }
        guard let stored else { throw BiometricFailure.notEnabled }
        return stored
    }
    func cancel() { cancelCount += 1 }
}

/// Headless tests for the **inverted** error classification — the actual root cause across three
/// rounds. Only the genuine Secure-Enclave invalidation (AKSError -536362999 / "unable to compute
/// shared secret") may disable biometric; every cancel/interrupt must be benign.
final class BiometricClassifyTests: XCTestCase {
    private typealias C = SecureEnclaveBiometricUnlock

    func test_genuineInvalidation_byAKSCode() {
        XCTAssertEqual(C.classify(NSError(domain: "CryptoTokenKit", code: -536362999)), .invalidated)
    }

    func test_genuineInvalidation_byMessage() {
        let e = NSError(domain: "NSOSStatusErrorDomain", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "CryptoTokenKit: unable to compute shared secret"])
        XCTAssertEqual(C.classify(e), .invalidated)
    }

    func test_genuineInvalidation_nestedUnderlying() {
        let aks = NSError(domain: "com.apple.kernel.AppleKeyStore", code: -536362999)
        let top = NSError(domain: "CryptoTokenKit", code: -3, userInfo: [NSUnderlyingErrorKey: aks])
        XCTAssertEqual(C.classify(top), .invalidated)
    }

    func test_systemCancel_isNOTinvalidation() {   // the -4 "canceled by another authentication" bug
        XCTAssertEqual(C.classify(LAError(.systemCancel)), .userCancelled)
        XCTAssertEqual(C.classify(NSError(domain: LAError.errorDomain, code: -4)), .userCancelled)
    }

    func test_userAndAppCancel_areNOTinvalidation() {
        XCTAssertEqual(C.classify(LAError(.userCancel)), .userCancelled)
        XCTAssertEqual(C.classify(LAError(.appCancel)), .userCancelled)
        XCTAssertEqual(C.classify(NSError(domain: "X", code: Int(errSecUserCanceled))), .userCancelled)
    }

    func test_unknownFailure_isBenign_notInvalidation() {
        // Anything not the genuine SE failure must NOT disable biometric.
        XCTAssertNotEqual(C.classify(LAError(.biometryLockout)), .invalidated)
        XCTAssertNotEqual(C.classify(NSError(domain: "Whatever", code: -25293)), .invalidated)
    }
}

@MainActor
final class BiometricFallbackTests: XCTestCase {

    private var tempDir: URL!
    private let master = "correct horse battery staple violet anchor"

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("surfr-bio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "SurfrVaultLastMasterAuth")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removeObject(forKey: "SurfrVaultLastMasterAuth")
    }

    private func newGate(_ mock: MockBiometricUnlock, now: @escaping () -> Date = Date.init) -> VaultGate {
        VaultGate.makeForTests(storePath: tempDir.appendingPathComponent("vault.sqlite"), biometric: mock, now: now)
    }

    /// Drive first-run to an unlocked vault with biometric enabled.
    private func enrol(_ gate: VaultGate) async {
        await gate.load()
        gate.beginFirstRun()
        await gate.submitMaster(master)
        await gate.acknowledgeKit(enableBiometric: true)
    }

    func test_firstRunEnablesBiometric_thenBiometricUnlocks() async throws {
        let mock = MockBiometricUnlock()
        let gate = newGate(mock)
        await enrol(gate)

        XCTAssertEqual(gate.phase, .unlocked)
        XCTAssertTrue(gate.biometricEnabled)
        XCTAssertEqual(mock.enableCount, 1)

        gate.lockNow()
        XCTAssertEqual(gate.phase, .locked)
        XCTAssertTrue(gate.shouldOfferBiometric)

        let ok = await gate.unlockWithBiometric()
        XCTAssertTrue(ok)
        XCTAssertEqual(gate.phase, .unlocked)
    }

    func test_userCancel_fallsToMaster_staysEnabled() async throws {
        let mock = MockBiometricUnlock()
        let gate = newGate(mock)
        await enrol(gate)
        gate.lockNow()

        mock.nextUnlockFailure = .userCancelled
        let ok = await gate.unlockWithBiometric()
        XCTAssertFalse(ok)
        XCTAssertEqual(gate.phase, .locked)
        XCTAssertTrue(gate.biometricEnabled, "cancel must NOT disable biometric")
        XCTAssertFalse(gate.needsBiometricReenroll)

        // Master fallback still works with no penalty.
        let mok = await gate.unlock(master: master)
        XCTAssertTrue(mok)
        XCTAssertEqual(gate.phase, .unlocked)
    }

    func test_invalidation_disables_offersReenroll_masterStillWorks() async throws {
        let mock = MockBiometricUnlock()
        let gate = newGate(mock)
        await enrol(gate)
        gate.lockNow()

        mock.nextUnlockFailure = .invalidated
        let ok = await gate.unlockWithBiometric()
        XCTAssertFalse(ok)
        XCTAssertFalse(gate.biometricEnabled, "invalidation must disable biometric")
        XCTAssertTrue(gate.needsBiometricReenroll)
        XCTAssertEqual(mock.disableCount, 1)
        XCTAssertEqual(gate.phase, .locked)

        // Master unlock works, then re-enable clears the re-enroll flag.
        let masterOK = await gate.unlock(master: master)
        XCTAssertTrue(masterOK)
        gate.enableBiometric()
        XCTAssertTrue(gate.biometricEnabled)
        XCTAssertFalse(gate.needsBiometricReenroll)
        XCTAssertEqual(mock.enableCount, 2)   // first-run + re-enable
    }

    func test_unavailable_skipsBiometric() async throws {
        let mock = MockBiometricUnlock()
        let gate = newGate(mock)
        await enrol(gate)
        gate.lockNow()

        mock.available = false
        await gate.load()                       // refresh availability
        XCTAssertFalse(gate.shouldOfferBiometric)
        let ok = await gate.unlockWithBiometric()
        XCTAssertFalse(ok, "unavailable biometric must be skipped, not attempted")
        XCTAssertEqual(mock.unlockCount, 0)
    }

    func test_regenerateRecoveryKit_oldCodeDies_newWorks() async throws {
        let mock = MockBiometricUnlock()
        let gate = newGate(mock)
        await gate.load()
        gate.beginFirstRun()
        await gate.submitMaster(master)
        let oldCode = gate.recoveryCodeForDisplay              // captured before commit clears it
        await gate.acknowledgeKit(enableBiometric: false)
        XCTAssertEqual(gate.phase, .unlocked)

        let newCode = await gate.regenerateRecoveryKit()
        let unwrappedNew = try XCTUnwrap(newCode)
        XCTAssertNotEqual(unwrappedNew, oldCode)

        // Old recovery code no longer resets the master; the new one does (and a copy-mangled form too).
        gate.lockNow()
        let oldReset = await gate.resetWithRecovery(code: oldCode, newMaster: "brand new master phrase here")
        XCTAssertFalse(oldReset, "old recovery code must stop working after regeneration")

        gate.lockNow()
        let mangled = unwrappedNew.replacingOccurrences(of: "-", with: "").lowercased()   // copy dropped hyphens + case
        let newReset = await gate.resetWithRecovery(code: mangled, newMaster: "brand new master phrase here")
        XCTAssertTrue(newReset, "new recovery code must work even when copy-mangled")
        XCTAssertEqual(gate.phase, .unlocked)
    }

    func test_masterRequiredInterval_skipsBiometric() async throws {
        // Fixed clock; force last master auth to be older than the 14-day interval.
        let nowDate = Date(timeIntervalSince1970: 2_000_000_000)
        let mock = MockBiometricUnlock()
        let gate = newGate(mock, now: { nowDate })
        await enrol(gate)
        gate.lockNow()
        XCTAssertTrue(gate.shouldOfferBiometric)   // just authed → within interval

        // Backdate the last master auth beyond the interval.
        UserDefaults.standard.set(nowDate.addingTimeInterval(-15 * 24 * 60 * 60), forKey: "SurfrVaultLastMasterAuth")
        XCTAssertTrue(gate.masterRequired)
        XCTAssertFalse(gate.shouldOfferBiometric, "master required after the interval → biometric skipped")
    }
}
