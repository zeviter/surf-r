import XCTest
@testable import Surfr

final class FillAuthTests: XCTestCase {
    func test_settingOff_fillsDirectly_noMaster() {
        XCTAssertFalse(FillAuth.needsMasterFallback(requireAuth: false, biometricEnabled: true, biometricSucceeded: false))
        XCTAssertFalse(FillAuth.needsMasterFallback(requireAuth: false, biometricEnabled: false, biometricSucceeded: false))
    }

    func test_biometricSucceeded_noMaster() {
        XCTAssertFalse(FillAuth.needsMasterFallback(requireAuth: true, biometricEnabled: true, biometricSucceeded: true))
    }

    func test_biometricCancelled_fallsBackToMaster() {
        // "Use master password" pressed (or Touch ID failed) → must present the master fallback.
        XCTAssertTrue(FillAuth.needsMasterFallback(requireAuth: true, biometricEnabled: true, biometricSucceeded: false))
    }

    func test_noBiometric_fallsBackToMaster() {
        // Auth required but no biometric enrolled/enabled → master fallback (not a dead end, not a fill).
        XCTAssertTrue(FillAuth.needsMasterFallback(requireAuth: true, biometricEnabled: false, biometricSucceeded: false))
    }
}
