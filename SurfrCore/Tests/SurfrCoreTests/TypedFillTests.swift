import XCTest
@testable import SurfrCore

/// TV-3a — the pure card/address → fill-values mappers (the only headless part of the in-browser typed
/// fill; detection + DOM writing live in Autofill.js and are hardware-verified). Locks the shape: digits-
/// only PAN, the three expiry forms, omit-empty, name join, and county deliberately NOT web-filled.
final class TypedFillTests: XCTestCase {

    func test_cardFill_digitsOnlyNumber_threeExpiryForms_cvvWhenPresent() {
        let p = PaymentPayload(nickname: "Premier", cardholderName: "A Cardholder",
                               number: "4111 1111 1111 1111", expiry: "06/2028", cvv: "737")
        let v = CardFill.values(from: p)
        XCTAssertEqual(v["number"], "4111111111111111")   // digits only (spaces stripped)
        XCTAssertEqual(v["name"], "A Cardholder")
        XCTAssertEqual(v["cvv"], "737")
        XCTAssertEqual(v["expMonth"], "06")
        XCTAssertEqual(v["expYear"], "2028")
        XCTAssertEqual(v["exp"], "06/28")                 // combined MM/YY
    }

    func test_cardFill_omitsCVVAndExpiryWhenAbsentOrJunk() {
        let p = PaymentPayload(nickname: "C", number: "4111111111111111", expiry: "ofdsfds", cvv: "")
        let v = CardFill.values(from: p)
        XCTAssertNil(v["cvv"])         // never invented
        XCTAssertNil(v["exp"])         // unparseable expiry → no expiry keys
        XCTAssertNil(v["expMonth"])
        XCTAssertEqual(v["number"], "4111111111111111")
    }

    func test_addressFill_mapsFields_joinsName_omitsEmpty_neverFillsCounty() {
        let a = AddressPayload(label: "Home", firstName: "Jane", lastName: "Doe",
                               line1: "221B Baker Street", line2: "", city: "London",
                               county: "Greater London", stateProvince: nil, postalCode: "NW1 6XE",
                               country: "United Kingdom", phone: "+44 20 7946 0958", email: "jane@example.com")
        let v = AddressFill.values(from: a)
        XCTAssertEqual(v["line1"], "221B Baker Street")
        XCTAssertEqual(v["city"], "London")
        XCTAssertEqual(v["postal"], "NW1 6XE")
        XCTAssertEqual(v["country"], "United Kingdom")
        XCTAssertEqual(v["name"], "Jane Doe")             // first + last joined
        XCTAssertEqual(v["tel"], "+44 20 7946 0958")
        XCTAssertEqual(v["email"], "jane@example.com")
        XCTAssertNil(v["line2"])                          // empty omitted
        XCTAssertNil(v["state"])                          // nil omitted
        // County has no autocomplete token — it is NEVER web-filled (in-vault only).
        XCTAssertFalse(v.keys.contains("county"))
        XCTAssertFalse(v.values.contains("Greater London"))
    }

    func test_addressFill_usStateMapped() {
        let a = AddressPayload(label: "Work", firstName: "Sam", line1: "1 Infinite Loop", city: "Cupertino",
                               stateProvince: "CA", postalCode: "95014", country: "United States")
        let v = AddressFill.values(from: a)
        XCTAssertEqual(v["state"], "CA")
        XCTAssertEqual(v["name"], "Sam")                  // last name empty → just first
    }
}
