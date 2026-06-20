import XCTest
import CryptoKit
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
