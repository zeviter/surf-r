import XCTest
import SurfrCore
@testable import Surfr

/// TV-2b — the Payment surface's data layer: cleartext last-4/network hint (derived at save + backfilled
/// for migrated cards), the full PAN/CVV staying encrypted-payload-only, and the detail model's masking
/// + reveal. The list row reads the hint with no decryption.
@MainActor
final class VaultPaymentTests: XCTestCase {
    private var tempDir: URL!
    private let master = "correct horse battery staple violet anchor"

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("surfr-tv2b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for k in ["SurfrVaultLastMasterAuth", VaultGate.hostRecoveryAttemptedKey, "SurfrTypedVaultReclassifiedV1"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func unlockedGate() async -> VaultGate {
        let mock = MockBiometricUnlock(); mock.available = false
        let gate = VaultGate.makeForTests(storePath: tempDir.appendingPathComponent("vault.sqlite"), biometric: mock)
        await gate.load(); gate.beginFirstRun(); await gate.submitMaster(master)
        await gate.acknowledgeKit(enableBiometric: false)
        return gate
    }
    private func card(_ gate: VaultGate, _ title: String) -> StoredItem? { gate.items.first { $0.title == title } }

    private let pan = "4111111111119876"     // Visa, last-4 9876 (distinct from any 1111 run)
    private let cvv = "737"

    func test_savePayment_storesCleartextHint_keepsPANandCVVEncrypted() async throws {
        let gate = await unlockedGate()
        await gate.savePayment(id: nil, title: "Premier Debit",
                               payload: PaymentPayload(nickname: "Premier Debit", cardholderName: "A Cardholder",
                                                       number: pan, cardType: "Premier Debit", expiry: "06/28", cvv: cvv))
        let c = try XCTUnwrap(card(gate, "Premier Debit"))
        XCTAssertEqual(c.type, VaultItemType.payment)
        // Cleartext hint — what the list row reads (NO decryption).
        XCTAssertEqual(c.last4, "9876")
        XCTAssertEqual(c.cardNetwork, CardNetwork.visa.rawValue)
        // The full payload still decrypts to the real number + CVV.
        XCTAssertEqual(gate.decryptPayment(c)?.number, pan)
        XCTAssertEqual(gate.decryptPayment(c)?.cvv, cvv)

        // Sentinel: the FULL PAN is absent from every cleartext DB file; the last-4 hint IS present
        // (in the main db or the WAL, wherever the write currently lives).
        var last4Found = false
        for suffix in ["", "-wal"] {
            let url = tempDir.appendingPathComponent("vault.sqlite\(suffix)")
            if let bytes = try? Data(contentsOf: url) {
                XCTAssertNil(bytes.range(of: Data(pan.utf8)), "full PAN leaked into vault.sqlite\(suffix)")
                if bytes.range(of: Data("9876".utf8)) != nil { last4Found = true }
            }
        }
        XCTAssertTrue(last4Found, "last-4 hint should be in cleartext (expected)")
    }

    func test_backfillPaymentHints_healsMigratedCardWithoutHint_idempotent() async throws {
        let gate = await unlockedGate()
        // Simulate the TV-1 reclassification output: a payment item stored WITHOUT a hint.
        let data = try PaymentPayload(nickname: "Old Card", number: pan, cvv: cvv).encoded()
        await gate.saveTypedItem(id: nil, type: VaultItemType.payment, title: "Old Card", payloadData: data, hosts: [])
        XCTAssertNil(card(gate, "Old Card")?.last4, "precondition: migrated card has no hint yet")

        await gate.backfillPaymentHints()
        XCTAssertEqual(card(gate, "Old Card")?.last4, "9876")
        XCTAssertEqual(card(gate, "Old Card")?.cardNetwork, CardNetwork.visa.rawValue)

        let cipher = card(gate, "Old Card")!.sealed.ciphertext
        await gate.backfillPaymentHints()   // idempotent: already has last4 → skipped, payload untouched
        XCTAssertEqual(card(gate, "Old Card")?.sealed.ciphertext, cipher)
    }

    func test_paymentDetailModel_masksByDefault_andRevealsWhenAuthNotRequired() async {
        let gate = await unlockedGate()
        gate.requireAuthToReveal = false      // direct reveal (no biometric/master gate)
        await gate.savePayment(id: nil, title: "Card", payload: PaymentPayload(nickname: "Card", number: pan, cvv: cvv))
        let model = PaymentDetailModel()
        model.load(card(gate, "Card")!, gate: gate)

        XCTAssertEqual(model.network, .visa)
        XCTAssertEqual(model.last4, "9876")
        XCTAssertEqual(model.maskedNumber, "•••• •••• •••• 9876")   // masked
        XCTAssertEqual(model.maskedCVV, "•••")
        XCTAssertNil(model.numberRevealed)

        await model.requestReveal(.number, gate: gate)
        XCTAssertEqual(model.numberRevealed, pan)                  // full PAN on reveal
        await model.requestReveal(.cvv, gate: gate)
        XCTAssertEqual(model.cvvRevealed, cvv)

        model.wipe()
        XCTAssertTrue(model.secretsWipedForTest)                   // secrets zeroed on close
    }

    /// The load-bearing TV-2-VAL rule at the data layer: a card with junk fields SAVES (never blocked)
    /// and round-trips so it stays editable; the validators flag the junk (the UI surfaces it amber).
    func test_savePayment_neverBlocks_withJunkFields_andStaysEditable() async throws {
        let gate = await unlockedGate()
        await gate.savePayment(id: nil, title: "Junk",
                               payload: PaymentPayload(nickname: "Junk", number: "jkjfkdskfjdskfjlkds",
                                                       cardType: "fsdf", expiry: "ofdsfds", cvv: "zz"))
        let c = try XCTUnwrap(card(gate, "Junk"))          // saved despite junk
        XCTAssertEqual(c.type, VaultItemType.payment)
        XCTAssertEqual(c.last4, "")                        // no digits → empty hint
        XCTAssertNil(c.cardNetwork)
        let p = try XCTUnwrap(gate.decryptPayment(c))      // editable: junk round-trips so it can be fixed
        XCTAssertEqual(p.number, "jkjfkdskfjdskfjlkds")
        XCTAssertEqual(p.expiry, "ofdsfds")
        XCTAssertTrue(CardValidation.cardNumber(p.number).isSuspect)   // flagged (soft), not blocked
        XCTAssertTrue(CardValidation.expiry(p.expiry).isSuspect)
    }

    /// Deletion diagnosis: an edit-save preserves EVERY PaymentPayload field — incl. rawBody and the
    /// imported cardType — through the encrypted payload (so a re-save never drops data). The expiry is
    /// stored canonically and a NEW expiry persists across reload.
    func test_savePayment_preservesAllFields_andCanonicalExpiryRoundTrips() async throws {
        let gate = await unlockedGate()
        // A fully-populated card (as if imported), with a raw month-name expiry + a preserved rawBody.
        let original = PaymentPayload(nickname: "Barclays", cardholderName: "A Cardholder",
                                      number: pan, cardType: "Premier Debit", expiry: "June, 2023",
                                      startDate: "06/2020", cvv: cvv, notes: "spare card",
                                      rawBody: "NoteType:Credit Card\n…full imported body…")
        await gate.savePayment(id: nil, title: "Barclays", payload: original)
        let id = try XCTUnwrap(card(gate, "Barclays")).id

        // Simulate an edit that changes ONLY the expiry (canonical from the picker), carrying the rest.
        var edited = try XCTUnwrap(gate.decryptPayment(card(gate, "Barclays")!))
        edited.expiry = "07/2026"
        await gate.savePayment(id: id, title: "Barclays", payload: edited)

        let back = try XCTUnwrap(gate.decryptPayment(gate.items.first { $0.id == id }!))
        XCTAssertEqual(back.cardholderName, "A Cardholder")     // every field survived…
        XCTAssertEqual(back.number, pan)
        XCTAssertEqual(back.cardType, "Premier Debit")          // imported product label preserved
        XCTAssertEqual(back.startDate, "06/2020")
        XCTAssertEqual(back.cvv, cvv)
        XCTAssertEqual(back.notes, "spare card")
        XCTAssertEqual(back.rawBody, "NoteType:Credit Card\n…full imported body…")   // rawBody carried through
        XCTAssertEqual(back.expiry, "07/2026")                  // …and the new expiry persisted
    }

    func test_paymentItems_areNotAudited() async {
        let gate = await unlockedGate()
        await gate.savePayment(id: nil, title: "Card",
                               payload: PaymentPayload(nickname: "Card", number: pan, cvv: cvv))
        await gate.runSecurityCheck()
        XCTAssertTrue(gate.audit.isEmpty)
        XCTAssertEqual(HealthFlags(rawValue: card(gate, "Card")!.healthFlags).rawValue, 0)
    }
}
