import XCTest
import SurfrCore
@testable import Surfr

/// TV-2c fix — the one-time heal that re-extracts a full multi-line `Notes` tail from the lossless
/// `rawBody` for items whose stored `notes` was truncated to its first line by the old parser. Verifies it
/// recovers the tail (no data was lost — rawBody had it), is idempotent, populates address notes that were
/// never extracted, and **never clobbers a user-edited note**.
@MainActor
final class VaultNotesHealTests: XCTestCase {
    private var tempDir: URL!
    private let master = "correct horse battery staple violet anchor"

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("surfr-heal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for k in ["SurfrVaultLastMasterAuth", VaultGate.hostRecoveryAttemptedKey, "SurfrTypedVaultReclassifiedV1",
                  VaultGate.typedReclassifiedKeyV2, VaultGate.typedNotesHealedKey] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        for k in ["SurfrTypedVaultReclassifiedV1", VaultGate.typedReclassifiedKeyV2, VaultGate.typedNotesHealedKey] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    private func unlockedGate() async -> VaultGate {
        let mock = MockBiometricUnlock(); mock.available = false
        let gate = VaultGate.makeForTests(storePath: tempDir.appendingPathComponent("vault.sqlite"), biometric: mock)
        await gate.load(); gate.beginFirstRun(); await gate.submitMaster(master)
        await gate.acknowledgeKit(enableBiometric: false)
        return gate
    }
    private func item(_ gate: VaultGate, _ title: String) -> StoredItem? { gate.items.first { $0.title == title } }

    /// A payment whose stored notes is the OLD truncated first line, but whose rawBody holds the full note.
    func test_heal_payment_recoversTruncatedNotesTail_idempotent() async throws {
        let gate = await unlockedGate()
        let rawBody = "NoteType:Credit Card\nNumber:4111111111111111\nNotes:line one\nline two\nline three"
        await gate.savePayment(id: nil, title: "Card",
                               payload: PaymentPayload(nickname: "Card", number: "4111111111111111",
                                                       notes: "line one", rawBody: rawBody))   // truncated stored notes
        XCTAssertEqual(gate.decryptPayment(item(gate, "Card")!)?.notes, "line one")   // precondition: truncated

        await gate.healTypedNotesFromRawBody()
        XCTAssertEqual(gate.decryptPayment(item(gate, "Card")!)?.notes, "line one\nline two\nline three")
        XCTAssertEqual(item(gate, "Card")?.last4, "1111")   // cleartext hint preserved through the re-seal

        let cipher = item(gate, "Card")!.sealed.ciphertext
        await gate.healTypedNotesFromRawBody()              // idempotent: already full → no re-write
        XCTAssertEqual(item(gate, "Card")?.sealed.ciphertext, cipher)
    }

    func test_heal_bankAccount_recoversTruncatedNotesTail() async throws {
        let gate = await unlockedGate()
        let rawBody = "NoteType:Bank Account\nBank Name:Barclays\nAccount Number:12345678\nNotes:\nbalance 500\ncall branch"
        // Old parser would have stored notes = "" (the empty Notes: line value) for this shape.
        await gate.saveBankAccount(id: nil, title: "Barclays",
                                   payload: BankAccountPayload(bankName: "Barclays", accountNumber: "12345678",
                                                               notes: "", rawBody: rawBody))
        await gate.healTypedNotesFromRawBody()
        XCTAssertEqual(gate.decryptBankAccount(item(gate, "Barclays")!)?.notes, "balance 500\ncall branch")
        XCTAssertEqual(item(gate, "Barclays")?.accountLast4, "5678")   // hint preserved
    }

    func test_heal_address_populatesNotesNeverExtractedBefore() async throws {
        let gate = await unlockedGate()
        let rawBody = "NoteType:Address\nAddress 1:1 St\nNotes:near the station\ngate code 1234"
        // Simulate a pre-fix address: notes never extracted (empty), full note only in rawBody.
        let data = try AddressPayload(label: "Home", line1: "1 St", notes: "", rawBody: rawBody).encoded()
        await gate.saveTypedItem(id: nil, type: VaultItemType.address, title: "Home", payloadData: data, hosts: [])
        XCTAssertEqual(gate.decryptAddress(item(gate, "Home")!)?.notes, "")   // precondition

        await gate.healTypedNotesFromRawBody()
        XCTAssertEqual(gate.decryptAddress(item(gate, "Home")!)?.notes, "near the station\ngate code 1234")
    }

    /// Data-safety: a note the user EDITED (so it no longer equals the old truncated extraction) must never
    /// be reverted to the rawBody original by the heal.
    func test_heal_doesNotClobberUserEditedNotes() async throws {
        let gate = await unlockedGate()
        let rawBody = "NoteType:Credit Card\nNumber:4111111111111111\nNotes:original line\nmore original"
        await gate.savePayment(id: nil, title: "Card",
                               payload: PaymentPayload(nickname: "Card", number: "4111111111111111",
                                                       notes: "my own edited note", rawBody: rawBody))
        await gate.healTypedNotesFromRawBody()
        // stored notes ("my own edited note") != the old first-line ("original line") → left untouched.
        XCTAssertEqual(gate.decryptPayment(item(gate, "Card")!)?.notes, "my own edited note")
    }

    /// A single-line note is already complete — the heal is a no-op (no spurious re-seal).
    func test_heal_singleLineNote_isNoOp() async throws {
        let gate = await unlockedGate()
        let rawBody = "NoteType:Credit Card\nNumber:4111111111111111\nNotes:just one line"
        await gate.savePayment(id: nil, title: "Card",
                               payload: PaymentPayload(nickname: "Card", number: "4111111111111111",
                                                       notes: "just one line", rawBody: rawBody))
        let cipher = item(gate, "Card")!.sealed.ciphertext
        await gate.healTypedNotesFromRawBody()
        XCTAssertEqual(item(gate, "Card")?.sealed.ciphertext, cipher)   // unchanged
    }
}
