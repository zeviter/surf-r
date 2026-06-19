import XCTest
@testable import Surfr

final class PasswordStrengthTests: XCTestCase {

    private func estimate(_ s: String) -> PasswordStrength { PasswordStrengthEstimator.estimate(s) }

    func test_empty_isVeryWeak() {
        let s = estimate("")
        XCTAssertEqual(s.level, .veryWeak)
        XCTAssertEqual(s.estimatedBits, 0)
        XCTAssertFalse(s.isPassphraseLike)
    }

    func test_shortAndSequential_isWeak() {
        XCTAssertLessThanOrEqual(estimate("abc").level, .weak)
        XCTAssertLessThanOrEqual(estimate("password").level, .fair)
        XCTAssertLessThanOrEqual(estimate("aaaaaaaa").level, .weak)   // repeats penalised
    }

    func test_sixWordPassphrase_isStrongGuidance() {
        let s = estimate("correct horse battery staple violet anchor")
        XCTAssertTrue(s.isPassphraseLike)
        XCTAssertGreaterThanOrEqual(s.level, .good)
    }

    func test_passphraseDetection_needsMultipleWords() {
        XCTAssertTrue(estimate("river table candle orbit").isPassphraseLike)
        XCTAssertFalse(estimate("rivertablecandleorbit").isPassphraseLike)
    }

    func test_moreEntropy_scoresHigher() {
        // A longer mixed string should estimate at least as many bits as a short one.
        XCTAssertGreaterThan(estimate("aA1!aA1!aA1!aA1!").estimatedBits, estimate("aA1!").estimatedBits)
        // A random-ish mix should outrank a same-length single-character run.
        XCTAssertGreaterThan(estimate("xQ9*zB2?wK5%").level.rawValue, estimate("aaaaaaaaaaaa").level.rawValue)
    }

    func test_hint_alwaysPresent() {
        XCTAssertFalse(estimate("").hint.isEmpty)
        XCTAssertFalse(estimate("hunter2").hint.isEmpty)
        XCTAssertFalse(estimate("a long passphrase of several words here").hint.isEmpty)
    }
}
