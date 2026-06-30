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

    // MARK: - Bank account (TV-2c) — soft validators

    func test_bank_sortCode() {
        XCTAssertEqual(BankValidation.sortCode("200000"), .ok)
        XCTAssertEqual(BankValidation.sortCode("20-00-00"), .ok)            // separators ignored
        XCTAssertEqual(BankValidation.sortCode(""), .ok)                    // empty never nags
        XCTAssertTrue(BankValidation.sortCode("2000").isSuspect)            // too short
        XCTAssertTrue(BankValidation.sortCode("abcdef").isSuspect)
    }

    func test_bank_formatSortCode() {
        XCTAssertEqual(BankValidation.formatSortCode("200000"), "20-00-00")
        XCTAssertEqual(BankValidation.formatSortCode("20-00-00"), "20-00-00")  // already grouped → stable
        XCTAssertEqual(BankValidation.formatSortCode("junk"), "junk")          // non-6-digit kept (never wiped)
    }

    func test_bank_accountNumber() {
        XCTAssertEqual(BankValidation.accountNumber("12345678"), .ok)      // UK 8-digit
        XCTAssertEqual(BankValidation.accountNumber("123456"), .ok)        // 6 ok (overseas vary)
        XCTAssertEqual(BankValidation.accountNumber("1234567890"), .ok)    // 10 ok
        XCTAssertEqual(BankValidation.accountNumber(""), .ok)
        XCTAssertTrue(BankValidation.accountNumber("12345").isSuspect)     // too short
        XCTAssertTrue(BankValidation.accountNumber("12345678901").isSuspect) // too long
        XCTAssertTrue(BankValidation.accountNumber("12ab5678").isSuspect)  // non-digit
    }

    func test_bank_swift() {
        XCTAssertEqual(BankValidation.swift("BUKBGB22"), .ok)              // 8
        XCTAssertEqual(BankValidation.swift("BUKBGB22XXX"), .ok)           // 11
        XCTAssertEqual(BankValidation.swift(""), .ok)
        XCTAssertTrue(BankValidation.swift("BUKB").isSuspect)             // wrong length
        XCTAssertTrue(BankValidation.swift("BUKB-GB22").isSuspect)        // non-alphanumeric
    }

    func test_bank_iban() {
        XCTAssertEqual(BankValidation.iban("GB29NWBK60161331926819"), .ok)
        XCTAssertEqual(BankValidation.iban("GB29 NWBK 6016 1331 9268 19"), .ok)   // spaces ignored
        XCTAssertEqual(BankValidation.iban(""), .ok)
        XCTAssertTrue(BankValidation.iban("GB").isSuspect)                        // too short
        XCTAssertTrue(BankValidation.iban("1229NWBK60161331926819").isSuspect)    // doesn't start with 2 letters
    }

    func test_bank_pin() {
        XCTAssertEqual(BankValidation.pin("1234"), .ok)
        XCTAssertEqual(BankValidation.pin(""), .ok)
        XCTAssertTrue(BankValidation.pin("12a4").isSuspect)
    }

    func test_bank_accountLast4() {
        XCTAssertEqual(BankValidation.accountLast4("12345678"), "5678")
        XCTAssertEqual(BankValidation.accountLast4("12-34-56-78"), "5678")   // digits only
        XCTAssertEqual(BankValidation.accountLast4("12"), "12")              // fewer than 4 → all digits
        XCTAssertEqual(BankValidation.accountLast4("junk"), "")
    }
}
