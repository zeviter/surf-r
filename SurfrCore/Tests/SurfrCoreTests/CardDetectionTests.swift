import XCTest
@testable import SurfrCore

/// TV-2b — local, prefix-based card-network detection + last-4 extraction. Pure, no network.
final class CardDetectionTests: XCTestCase {

    func test_network_byPrefix() {
        XCTAssertEqual(CardDetection.network("4111 1111 1111 1111"), .visa)        // 4
        XCTAssertEqual(CardDetection.network("5555 5555 5555 4444"), .mastercard)  // 51-55
        XCTAssertEqual(CardDetection.network("2221 0000 0000 0009"), .mastercard)  // 2221-2720
        XCTAssertEqual(CardDetection.network("3782 822463 10005"), .amex)          // 34/37
        XCTAssertEqual(CardDetection.network("6011 0000 0000 0004"), .discover)    // 6011
        XCTAssertEqual(CardDetection.network("6512 0000 0000 0000"), .discover)    // 65
        XCTAssertEqual(CardDetection.network("3612 345678 9012"), .diners)         // 36
        XCTAssertEqual(CardDetection.network("3528 0000 0000 0007"), .jcb)         // 3528-3589
        XCTAssertEqual(CardDetection.network("6200 0000 0000 0005"), .unionpay)    // 62 (not in discover 6-range)
    }

    func test_discover_vs_unionpay_sixDigitRange() {
        XCTAssertEqual(CardDetection.network("622126 0000 00000"), .discover)      // 622126-622925 → Discover
        XCTAssertEqual(CardDetection.network("620000 0000 00000"), .unionpay)      // outside → UnionPay
    }

    func test_unknown_andShort() {
        XCTAssertEqual(CardDetection.network("9999 9999"), .unknown)
        XCTAssertEqual(CardDetection.network("1"), .unknown)
        XCTAssertEqual(CardDetection.network(""), .unknown)
    }

    func test_last4_andDigitsStripping() {
        XCTAssertEqual(CardDetection.last4("4111 1111 1111 1234"), "1234")
        XCTAssertEqual(CardDetection.digits("4111-1111-1111-1234"), "4111111111111234")
        XCTAssertEqual(CardDetection.last4("12"), "12")     // fewer than 4 → all digits
        XCTAssertEqual(CardDetection.last4(""), "")
    }

    func test_networkHintRoundTrip() {
        XCTAssertEqual(CardNetwork.from(hint: CardNetwork.visa.rawValue), .visa)
        XCTAssertEqual(CardNetwork.from(hint: nil), .unknown)
        XCTAssertEqual(CardNetwork.from(hint: "garbled"), .unknown)
    }
}
