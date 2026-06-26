import XCTest
@testable import SurfrCore

/// TV-2-VAL — the pure soft validators. Each GUIDES/WARNS (never gates); empty is always `.ok`; junk is
/// `.suspect`. Tested against valid values AND the real-import junk class.
final class FieldValidationTests: XCTestCase {

    func test_luhn() {
        XCTAssertTrue(CardValidation.luhn("4111111111111111"))
        XCTAssertTrue(CardValidation.luhn("5555 5555 5555 4444"))
        XCTAssertFalse(CardValidation.luhn("4111111111111112"))
    }

    func test_cardNumber_okValid_suspectJunk_okEmpty() {
        XCTAssertEqual(CardValidation.cardNumber("4111 1111 1111 1111"), .ok)
        XCTAssertEqual(CardValidation.cardNumber(""), .ok)                         // empty never nags
        XCTAssertTrue(CardValidation.cardNumber("jkjfkdskfjdskfjlkds").isSuspect)  // real junk
        XCTAssertTrue(CardValidation.cardNumber("4111").isSuspect)                 // too short
        XCTAssertTrue(CardValidation.cardNumber("4111111111111112").isSuspect)     // fails Luhn
    }

    func test_cvv() {
        XCTAssertEqual(CardValidation.cvv("123"), .ok)
        XCTAssertEqual(CardValidation.cvv("1234"), .ok)
        XCTAssertEqual(CardValidation.cvv(""), .ok)
        XCTAssertTrue(CardValidation.cvv("12").isSuspect)
        XCTAssertTrue(CardValidation.cvv("abc").isSuspect)
    }

    func test_expiry_ok_andJunk() {
        XCTAssertEqual(CardValidation.expiry("06/2028"), .ok)
        XCTAssertEqual(CardValidation.expiry("06/28"), .ok)
        XCTAssertEqual(CardValidation.expiry("June, 2028"), .ok)
        XCTAssertEqual(CardValidation.expiry(""), .ok)
        XCTAssertTrue(CardValidation.expiry("ofdsfds").isSuspect)                  // real junk
        XCTAssertTrue(CardValidation.expiry("13/2028").isSuspect)                  // month out of range
    }

    func test_parseMonthYear() {
        XCTAssertEqual(CardValidation.parseMonthYear("06/2028")?.month, 6)
        XCTAssertEqual(CardValidation.parseMonthYear("06/2028")?.year, 2028)
        XCTAssertEqual(CardValidation.parseMonthYear("6/28")?.year, 2028)          // 2-digit year → 2000+
        XCTAssertEqual(CardValidation.parseMonthYear("June, 2028")?.month, 6)
        XCTAssertEqual(CardValidation.parseMonthYear("2028/06")?.month, 6)         // YYYY/MM
        XCTAssertNil(CardValidation.parseMonthYear("ofdsfds"))
    }

    func test_canonicalMonthYear() {
        XCTAssertEqual(CardValidation.canonicalMonthYear("June, 2023"), "06/2023")   // month name → MM/YYYY
        XCTAssertEqual(CardValidation.canonicalMonthYear("June-2023"), "06/2023")
        XCTAssertEqual(CardValidation.canonicalMonthYear("6/23"), "06/2023")
        XCTAssertEqual(CardValidation.canonicalMonthYear("07/2026"), "07/2026")       // already canonical round-trips
        XCTAssertEqual(CardValidation.canonicalMonthYear("ofdsfds"), "")              // unparseable → "" (caller keeps raw)
        XCTAssertEqual(CardValidation.canonicalMonthYear(""), "")
    }

    /// The picker write/read symmetry the editor relies on: canonical → parse → canonical is stable.
    func test_canonical_roundTrip() {
        let canon = CardValidation.canonicalMonthYear("07/2026")
        let parsed = CardValidation.parseMonthYear(canon)
        XCTAssertEqual(parsed?.month, 7)
        XCTAssertEqual(parsed?.year, 2026)
        XCTAssertEqual(CardValidation.canonicalMonthYear(canon), "07/2026")
    }

    func test_grouped_formatsInto4s() {
        XCTAssertEqual(CardDetection.grouped("4111111111111111"), "4111 1111 1111 1111")
        XCTAssertEqual(CardDetection.grouped("4111-1111-111"), "4111 1111 111")
        XCTAssertEqual(CardDetection.grouped(""), "")
    }
}
