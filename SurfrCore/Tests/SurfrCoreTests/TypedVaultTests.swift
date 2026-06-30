import XCTest
@testable import SurfrCore

/// Typed vault TV-1 — `NoteType` classification + structured field extraction, the lossless rule, the
/// phone-JSON leniency, and round-trip stability of the typed payloads. Pure + headless.
///
/// Sample bodies are built from the **documented LastPass labels** (typed-vault-wireframes §1, kickoff
/// §2). The parser is label-robust (trim + case-insensitive), so the real export confirms field-by-field
/// during the hardware pass; these lock the logic.
final class TypedVaultTests: XCTestCase {

    // MARK: Sample bodies (real LastPass secure-note shape)

    private let creditCardBody = """
    NoteType:Credit Card
    Name on Card:Jane Doe
    Type:Visa
    Number:4111 1111 1111 1111
    Security Code:123
    Start Date:
    Expiration Date:June,2028
    Notes:travel card
    """

    private let ukAddressBody = """
    NoteType:Address
    Title:Mr.
    First Name:Jane
    Last Name:Jose
    Company:Surfr Ltd
    Address 1:221B Baker Street
    Address 2:Flat 2
    City / Town:London
    County:Greater London
    State:
    Zip / Postal Code:NW1 6XE
    Country:United Kingdom
    Email Address:jane@example.com
    Phone:{"num":"+44 20 7946 0958","cc3l":"GBR","ext":""}
    Gender:Male
    """

    private let bankAccountBody = """
    NoteType:Bank Account
    Bank Name:Barclays
    Account Type:Current
    Routing Number:20-00-00
    Account Number:12345678
    SWIFT Code:BUKBGB22
    IBAN Number:GB29NWBK60161331926819
    Pin:1234
    Branch Address:1 Churchill Place, London
    Branch Phone:+44 345 734 5345
    Notes:main account
    """

    // MARK: Classification

    func test_classify_creditCard_isPayment() {
        guard case .payment = TypedNoteParser.classify(title: "Premier Card", body: creditCardBody)
        else { return XCTFail("expected payment") }
    }

    func test_classify_address_isAddress() {
        guard case .address = TypedNoteParser.classify(title: "Home", body: ukAddressBody)
        else { return XCTFail("expected address") }
    }

    func test_classify_bankAccount_isBankAccount() {
        guard case .bankAccount = TypedNoteParser.classify(title: "Barclays Current", body: bankAccountBody)
        else { return XCTFail("expected bankAccount") }
    }

    func test_bankAccount_extractsEveryField_routingNumberMapsToSortCode() {
        guard case .bankAccount(let b) = TypedNoteParser.classify(title: "Barclays Current", body: bankAccountBody)
        else { return XCTFail() }
        XCTAssertEqual(b.bankName, "Barclays")
        XCTAssertEqual(b.accountType, "Current")
        XCTAssertEqual(b.sortCode, "20-00-00")              // LastPass "Routing Number" → sortCode
        XCTAssertEqual(b.accountNumber, "12345678")
        XCTAssertEqual(b.swift, "BUKBGB22")
        XCTAssertEqual(b.iban, "GB29NWBK60161331926819")
        XCTAssertEqual(b.pin, "1234")
        XCTAssertEqual(b.branchAddress, "1 Churchill Place, London")
        XCTAssertEqual(b.branchPhone, "+44 345 734 5345")
        XCTAssertEqual(b.notes, "main account")
        XCTAssertEqual(b.rawBody, bankAccountBody)          // lossless
    }

    func test_classify_plainNote_isSecureNote() {
        guard case .secureNote(let n) = TypedNoteParser.classify(title: "Wifi", body: "SSID: home\nPassword: hunter2")
        else { return XCTFail("expected secureNote") }
        XCTAssertEqual(n.title, "Wifi")
        XCTAssertEqual(n.body, "SSID: home\nPassword: hunter2")   // verbatim
    }

    func test_classify_missingOrGarbledNoteType_isSecureNote_neverMisfiled() {
        // Absent marker.
        guard case .secureNote = TypedNoteParser.classify(title: "x", body: "just some text") else { return XCTFail() }
        // Garbled / unknown NoteType ⇒ generic note, never mis-typed. (Passport is an unhandled long-tail
        // type; Bank Account is now first-class, so it's covered by its own test below.)
        guard case .secureNote = TypedNoteParser.classify(title: "x", body: "NoteType:Passport\nNumber:123") else { return XCTFail() }
        guard case .secureNote = TypedNoteParser.classify(title: "x", body: "Notetype :Credit Card\nNumber:1") else { return XCTFail() }
    }

    // MARK: Extraction — field by field

    func test_payment_extractsEveryField() {
        guard case .payment(let p) = TypedNoteParser.classify(title: "Premier Card", body: creditCardBody)
        else { return XCTFail() }
        XCTAssertEqual(p.nickname, "Premier Card")             // from the title
        XCTAssertEqual(p.cardholderName, "Jane Doe")
        XCTAssertEqual(p.cardType, "Visa")
        XCTAssertEqual(p.number, "4111 1111 1111 1111")
        XCTAssertEqual(p.cvv, "123")
        XCTAssertEqual(p.expiry, "06/2028")                    // "June,2028" normalized to canonical MM/YYYY
        XCTAssertEqual(p.startDate, "")
        XCTAssertEqual(p.notes, "travel card")
        XCTAssertEqual(p.rawBody, creditCardBody)              // lossless
    }

    func test_payment_expiry_normalizedToCanonical_orKeptRawIfUnparseable() {
        let body = "NoteType:Credit Card\nNumber:4111 1111 1111 1111\nExpiration Date:June-2023\nStart Date:ofdsfds"
        guard case .payment(let p) = TypedNoteParser.classify(title: "X", body: body) else { return XCTFail() }
        XCTAssertEqual(p.expiry, "06/2023")     // month name → canonical
        XCTAssertEqual(p.startDate, "ofdsfds")  // unparseable → kept raw (flagged, not lost)
    }

    func test_address_extractsEveryField_discrete() {
        guard case .address(let a) = TypedNoteParser.classify(title: "Home", body: ukAddressBody)
        else { return XCTFail() }
        XCTAssertEqual(a.label, "Home")
        XCTAssertEqual(a.firstName, "Jane")
        XCTAssertEqual(a.lastName, "Jose")
        XCTAssertEqual(a.company, "Surfr Ltd")
        XCTAssertEqual(a.line1, "221B Baker Street")
        XCTAssertEqual(a.line2, "Flat 2")
        XCTAssertEqual(a.city, "London")
        XCTAssertEqual(a.postalCode, "NW1 6XE")
        XCTAssertEqual(a.country, "United Kingdom")
        XCTAssertEqual(a.email, "jane@example.com")
    }

    // MARK: county vs stateProvince — separate, independently nullable

    func test_address_ukFillsCounty_leavesStateNil() {
        guard case .address(let a) = TypedNoteParser.classify(title: "Home", body: ukAddressBody)
        else { return XCTFail() }
        XCTAssertEqual(a.county, "Greater London")
        XCTAssertNil(a.stateProvince, "blank State: line ⇒ nil, not empty string")
    }

    func test_address_usFillsStateLeavesCountyNil() {
        let usBody = """
        NoteType:Address
        First Name:Sam
        Address 1:1 Infinite Loop
        City / Town:Cupertino
        State:CA
        Zip / Postal Code:95014
        Country:United States
        """
        guard case .address(let a) = TypedNoteParser.classify(title: "Work", body: usBody) else { return XCTFail() }
        XCTAssertEqual(a.stateProvince, "CA")
        XCTAssertNil(a.county, "absent County: line ⇒ nil")
    }

    // MARK: Phone JSON leniency

    func test_phone_jsonParsesNumberAndCountry() {
        guard case .address(let a) = TypedNoteParser.classify(title: "Home", body: ukAddressBody)
        else { return XCTFail() }
        XCTAssertEqual(a.phone, "+44 20 7946 0958")
        XCTAssertEqual(a.phoneCountry, "GBR")
    }

    func test_phone_malformed_keepsRawString_noDataLoss() {
        XCTAssertEqual(TypedNoteParser.parsePhone("0123456789").number, "0123456789")
        XCTAssertNil(TypedNoteParser.parsePhone("0123456789").country)
        // Broken JSON ⇒ keep the raw text, don't crash.
        XCTAssertEqual(TypedNoteParser.parsePhone(#"{"num":broken"#).number, #"{"num":broken"#)
    }

    func test_phone_emptyJSONObject_isEmpty_notRaw() {
        // An all-empty object is NO data, not a parse failure → empty field (omitted in detail), never
        // the raw JSON string.
        let r = TypedNoteParser.parsePhone(#"{"num":"","ext":"","cc3l":""}"#)
        XCTAssertEqual(r.number, "")
        XCTAssertNil(r.country)
        // Whitespace-only num is likewise empty.
        XCTAssertEqual(TypedNoteParser.parsePhone(#"{"num":"  ","cc3l":"GBR"}"#).number, "")
    }

    // MARK: Lossless

    func test_lossless_unmappedLabelSurvivesInRawBody() {
        guard case .address(let a) = TypedNoteParser.classify(title: "Home", body: ukAddressBody)
        else { return XCTFail() }
        XCTAssertTrue(a.rawBody.contains("Gender:Male"), "an unmapped label must survive in rawBody")
        XCTAssertTrue(a.rawBody.contains("Title:Mr."), "honorific is not a structured field but is preserved")
    }

    // MARK: Round-trip stability

    func test_roundTrip_paymentEncodeDecodeStable() throws {
        guard case .payment(let p) = TypedNoteParser.classify(title: "Premier Card", body: creditCardBody)
        else { return XCTFail() }
        let again = try PaymentPayload.decoded(from: try p.encoded())
        XCTAssertEqual(p, again)
        // re-encode is byte-stable for an unchanged value.
        XCTAssertEqual(try again.encoded(), try p.encoded())
    }

    func test_roundTrip_addressEncodeDecodeStable() throws {
        guard case .address(let a) = TypedNoteParser.classify(title: "Home", body: ukAddressBody)
        else { return XCTFail() }
        let again = try AddressPayload.decoded(from: try a.encoded())
        XCTAssertEqual(a, again)
        XCTAssertNil(again.stateProvince)   // nullability survives the round-trip
    }

    func test_roundTrip_bankAccountEncodeDecodeStable() throws {
        guard case .bankAccount(let b) = TypedNoteParser.classify(title: "Barclays", body: bankAccountBody)
        else { return XCTFail() }
        let again = try BankAccountPayload.decoded(from: try b.encoded())
        XCTAssertEqual(b, again)
        // re-encode is byte-stable for an unchanged value (deterministic .sortedKeys encoding).
        XCTAssertEqual(try again.encoded(), try b.encoded())
    }

    // MARK: Multi-line Notes tail — the terminal free-form field (TV-2c fix)

    /// `Notes:` captures everything to end-of-body (internal newlines preserved), AND a note-tail line that
    /// merely *looks* like a label must NOT pollute a structured field (parsing stops at `Notes:`).
    func test_payment_multiLineNotes_capturedWhole_andNoFieldPollution() {
        let body = """
        NoteType:Credit Card
        Type:Visa
        Number:4111 1111 1111 1111
        Notes:first note line
        Security Code: not a real cvv
        second note line
        """
        guard case .payment(let p) = TypedNoteParser.classify(title: "X", body: body) else { return XCTFail() }
        XCTAssertEqual(p.cardType, "Visa")          // real field before Notes survives
        XCTAssertEqual(p.cvv, "")                   // "Security Code:" INSIDE the note must not set cvv
        XCTAssertEqual(p.notes, "first note line\nSecurity Code: not a real cvv\nsecond note line")
    }

    func test_address_multiLineNotes_capturedWhole() {
        let body = """
        NoteType:Address
        First Name:Jane
        Address 1:221B Baker Street
        Notes:near the station
        gate code: 1234
        ring twice
        """
        guard case .address(let a) = TypedNoteParser.classify(title: "Home", body: body) else { return XCTFail() }
        XCTAssertEqual(a.firstName, "Jane")
        XCTAssertEqual(a.line1, "221B Baker Street")
        XCTAssertEqual(a.notes, "near the station\ngate code: 1234\nring twice")
    }

    func test_bankAccount_multiLineNotes_emptyFirstLine_capturesTail() {
        // The instruction's shape: "Notes:" then content on following lines, incl. a label-looking line.
        let body = """
        NoteType:Bank Account
        Bank Name:Barclays
        Account Number:12345678
        Notes:
        balance: 500
        call branch
        """
        guard case .bankAccount(let b) = TypedNoteParser.classify(title: "B", body: body) else { return XCTFail() }
        XCTAssertEqual(b.bankName, "Barclays")
        XCTAssertEqual(b.accountNumber, "12345678")
        XCTAssertEqual(b.notes, "balance: 500\ncall branch")   // leading empty Notes: line trimmed; tail kept
    }

    func test_roundTrip_multiLineNotesSurvivesEncodeDecode() throws {
        let body = "NoteType:Bank Account\nBank Name:Barclays\nNotes:one\ntwo\nthree"
        guard case .bankAccount(let b) = TypedNoteParser.classify(title: "B", body: body) else { return XCTFail() }
        XCTAssertEqual(b.notes, "one\ntwo\nthree")
        let again = try BankAccountPayload.decoded(from: try b.encoded())
        XCTAssertEqual(again.notes, "one\ntwo\nthree")          // multi-line note survives the AEAD round-trip
    }

    /// The heal helper's inputs: `notesTail` exposes both the old buggy first-line value and the full tail.
    func test_notesTail_exposesFirstLineAndFull() {
        let t = TypedNoteParser.notesTail(fromBody: "NoteType:Credit Card\nNumber:4111\nNotes:main\nextra line")
        XCTAssertEqual(t?.firstLineValue, "main")
        XCTAssertEqual(t?.full, "main\nextra line")
        XCTAssertNil(TypedNoteParser.notesTail(fromBody: "NoteType:Credit Card\nNumber:4111"))  // no Notes line
    }

    /// Backward-compat: an address stored BEFORE the `notes` field existed (no `notes` key) still decodes,
    /// with an empty note (the heal then re-extracts it from rawBody).
    func test_address_decodesWithoutNotesKey_tolerant() throws {
        let legacyJSON = #"{"label":"Home","firstName":"Jane","lastName":"","company":"","line1":"1 St","line2":"","city":"London","postalCode":"NW1","country":"UK","phone":"","email":"","rawBody":"NoteType:Address\nNotes:hi"}"#
        let a = try AddressPayload.decoded(from: Data(legacyJSON.utf8))
        XCTAssertEqual(a.firstName, "Jane")
        XCTAssertEqual(a.notes, "")          // missing key → empty, not a decode failure
    }
}
