import XCTest
import SurfrCore
@testable import Surfr

/// TV-2c — the Bank Account surface's data layer: cleartext account-last-4 hint (derived at save +
/// backfilled for migrated accounts), the full account number / IBAN / PIN staying encrypted-payload-only,
/// the detail model's masking + reveal of all three secrets, the never-block save rule, audit exclusion,
/// and the `NoteType:Bank Account` re-classification off the secureNote catch-all.
@MainActor
final class VaultBankAccountTests: XCTestCase {
    private var tempDir: URL!
    private let master = "correct horse battery staple violet anchor"
    private let v2Key = VaultGate.typedReclassifiedKeyV2

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("surfr-tv2c-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for k in ["SurfrVaultLastMasterAuth", VaultGate.hostRecoveryAttemptedKey, "SurfrTypedVaultReclassifiedV1", v2Key] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        for k in ["SurfrTypedVaultReclassifiedV1", v2Key] { UserDefaults.standard.removeObject(forKey: k) }
    }

    private func unlockedGate() async -> VaultGate {
        let mock = MockBiometricUnlock(); mock.available = false
        let gate = VaultGate.makeForTests(storePath: tempDir.appendingPathComponent("vault.sqlite"), biometric: mock)
        await gate.load(); gate.beginFirstRun(); await gate.submitMaster(master)
        await gate.acknowledgeKit(enableBiometric: false)
        return gate
    }
    private func item(_ gate: VaultGate, _ title: String) -> StoredItem? { gate.items.first { $0.title == title } }

    // Distinct sentinels: full account number / IBAN / PIN must never reach cleartext; only last-4 (4756) may.
    private let acct = "29384756"
    private let iban = "GB29NWBK60161331926819"
    private let pin  = "8675"

    private func sampleBank(_ name: String) -> BankAccountPayload {
        BankAccountPayload(bankName: name, accountType: "Current", sortCode: "200000",
                           accountNumber: acct, swift: "BUKBGB22", iban: iban, pin: pin,
                           branchAddress: "1 Churchill Place", branchPhone: "+44 345 734 5345", notes: "main")
    }

    func test_saveBankAccount_storesCleartextLast4_keepsSecretsEncrypted() async throws {
        let gate = await unlockedGate()
        await gate.saveBankAccount(id: nil, title: "Barclays", payload: sampleBank("Barclays"))
        let b = try XCTUnwrap(item(gate, "Barclays"))
        XCTAssertEqual(b.type, VaultItemType.bankAccount)
        XCTAssertEqual(b.accountLast4, "4756")             // cleartext hint — what the list row reads (NO decrypt)
        // The full payload still decrypts to the real secrets.
        XCTAssertEqual(gate.decryptBankAccount(b)?.accountNumber, acct)
        XCTAssertEqual(gate.decryptBankAccount(b)?.iban, iban)
        XCTAssertEqual(gate.decryptBankAccount(b)?.pin, pin)

        // Sentinel: the FULL account number, IBAN, and PIN are absent from every cleartext DB file; the
        // last-4 hint IS present (wherever the write currently lives — main db or WAL).
        var last4Found = false
        for suffix in ["", "-wal"] {
            let url = tempDir.appendingPathComponent("vault.sqlite\(suffix)")
            guard let bytes = try? Data(contentsOf: url) else { continue }
            XCTAssertNil(bytes.range(of: Data(acct.utf8)), "full account number leaked into vault.sqlite\(suffix)")
            XCTAssertNil(bytes.range(of: Data(iban.utf8)), "IBAN leaked into vault.sqlite\(suffix)")
            XCTAssertNil(bytes.range(of: Data(pin.utf8)), "PIN leaked into vault.sqlite\(suffix)")
            if bytes.range(of: Data("4756".utf8)) != nil { last4Found = true }
        }
        XCTAssertTrue(last4Found, "account last-4 hint should be in cleartext (expected)")
    }

    func test_backfillBankAccountHints_healsMigratedWithoutHint_idempotent() async throws {
        let gate = await unlockedGate()
        // Simulate the reclassification output: a bankAccount item stored WITHOUT a hint.
        let data = try sampleBank("Old Bank").encoded()
        await gate.saveTypedItem(id: nil, type: VaultItemType.bankAccount, title: "Old Bank", payloadData: data, hosts: [])
        XCTAssertNil(item(gate, "Old Bank")?.accountLast4, "precondition: migrated account has no hint yet")

        await gate.backfillBankAccountHints()
        XCTAssertEqual(item(gate, "Old Bank")?.accountLast4, "4756")

        let cipher = item(gate, "Old Bank")!.sealed.ciphertext
        await gate.backfillBankAccountHints()   // idempotent: already has hint → skipped, payload untouched
        XCTAssertEqual(item(gate, "Old Bank")?.sealed.ciphertext, cipher)
    }

    func test_bankAccountDetailModel_masksByDefault_andRevealsAllThreeSecrets() async {
        let gate = await unlockedGate()
        gate.requireAuthToReveal = false      // direct reveal (no biometric/master gate)
        await gate.saveBankAccount(id: nil, title: "Barclays", payload: sampleBank("Barclays"))
        let model = BankAccountDetailModel()
        model.load(item(gate, "Barclays")!, gate: gate)

        XCTAssertEqual(model.accountLast4, "4756")
        XCTAssertEqual(model.maskedAccount, "•••• 4756")   // masked
        XCTAssertNil(model.numberRevealed)
        XCTAssertEqual(model.sortCode, "20-00-00")         // shown plainly, formatted

        await model.requestReveal(.account, gate: gate)
        XCTAssertEqual(model.numberRevealed, acct)         // full account number on reveal
        await model.requestReveal(.iban, gate: gate)
        XCTAssertEqual(model.ibanRevealed, iban)
        await model.requestReveal(.pin, gate: gate)
        XCTAssertEqual(model.pinRevealed, pin)

        model.wipe()
        XCTAssertTrue(model.secretsWipedForTest)           // all three secrets zeroed on close
    }

    /// The load-bearing TV-2-VAL rule at the data layer: junk fields SAVE (never blocked) and round-trip so
    /// the item stays editable; the validators flag the junk (the UI surfaces it amber).
    func test_saveBankAccount_neverBlocks_withJunkFields_andStaysEditable() async throws {
        let gate = await unlockedGate()
        await gate.saveBankAccount(id: nil, title: "Junk",
                                   payload: BankAccountPayload(bankName: "Junk", sortCode: "zz",
                                                               accountNumber: "abc", swift: "??", iban: "GB", pin: "xx"))
        let b = try XCTUnwrap(item(gate, "Junk"))          // saved despite junk
        XCTAssertEqual(b.type, VaultItemType.bankAccount)
        XCTAssertEqual(b.accountLast4, "")                 // no digits → empty hint
        let p = try XCTUnwrap(gate.decryptBankAccount(b))  // editable: junk round-trips so it can be fixed
        XCTAssertEqual(p.accountNumber, "abc")
        XCTAssertTrue(BankValidation.accountNumber(p.accountNumber).isSuspect)   // flagged (soft), not blocked
        XCTAssertTrue(BankValidation.sortCode(p.sortCode).isSuspect)
        XCTAssertTrue(BankValidation.iban(p.iban).isSuspect)
    }

    func test_bankAccountItems_areNotAudited() async {
        let gate = await unlockedGate()
        await gate.saveBankAccount(id: nil, title: "Barclays", payload: sampleBank("Barclays"))
        await gate.runSecurityCheck()
        XCTAssertTrue(gate.audit.isEmpty)
        XCTAssertEqual(HealthFlags(rawValue: item(gate, "Barclays")!.healthFlags).rawValue, 0)
    }

    /// The re-classification walk: a `NoteType:Bank Account` secure note (Slice-9 host-"sn" shape, body in
    /// LoginPayload.notes) is promoted to a bankAccount with structured fields, losslessly, with the
    /// account number / IBAN / PIN staying encrypted at rest.
    func test_reclassify_refinesBankAccount_fromSecureNote() async throws {
        let gate = await unlockedGate()
        let body = """
        NoteType:Bank Account
        Bank Name:Barclays
        Account Type:Current
        Routing Number:20-00-00
        Account Number:\(acct)
        SWIFT Code:BUKBGB22
        IBAN Number:\(iban)
        Pin:\(pin)
        """
        await gate.saveItem(id: nil, title: "Barclays", payload: LoginPayload(notes: body),
                            hosts: [SurfrCore.Host(host: "sn", isPrimary: true)])
        // Slice-9 host-"sn" classification already happened in loadItems.
        XCTAssertEqual(item(gate, "Barclays")?.type, VaultItemType.secureNote)

        await gate.reclassifyTypedItems()

        XCTAssertEqual(item(gate, "Barclays")?.type, VaultItemType.bankAccount)
        let b = try XCTUnwrap(gate.decryptBankAccount(item(gate, "Barclays")!))
        XCTAssertEqual(b.bankName, "Barclays")
        XCTAssertEqual(b.sortCode, "20-00-00")             // Routing Number → sortCode
        XCTAssertEqual(b.accountNumber, acct)
        XCTAssertEqual(b.iban, iban)
        XCTAssertEqual(b.pin, pin)
        XCTAssertEqual(b.rawBody, body)                    // lossless

        // Sensitive fields never reach a cleartext column.
        for sentinel in [acct, iban, pin] {
            for suffix in ["", "-wal"] {
                let url = tempDir.appendingPathComponent("vault.sqlite\(suffix)")
                if let file = try? Data(contentsOf: url) {
                    XCTAssertNil(file.range(of: Data(sentinel.utf8)), "‘\(sentinel)’ leaked into vault.sqlite\(suffix)")
                }
            }
        }
    }
}
