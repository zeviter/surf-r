import XCTest
import SurfrCore
@testable import Surfr

/// TV-2a — the note/address editor save paths through the gate (`saveTypedItem`): correct type,
/// lossless round-trip, county/state independence, no audit for non-login items. (The UI itself is
/// driven-run; this locks the data round-trip the editors rely on.)
@MainActor
final class VaultTypedEditTests: XCTestCase {
    private var tempDir: URL!
    private let master = "correct horse battery staple violet anchor"

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("surfr-tv2a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for k in ["SurfrVaultLastMasterAuth", VaultGate.hostRecoveryAttemptedKey, "SurfrTypedVaultReclassifiedV1"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func unlockedGate() async -> VaultGate {
        let mock = MockBiometricUnlock(); mock.available = false
        let gate = VaultGate.makeForTests(storePath: tempDir.appendingPathComponent("vault.sqlite"), biometric: mock)
        await gate.load(); gate.beginFirstRun(); await gate.submitMaster(master)
        await gate.acknowledgeKit(enableBiometric: false)
        return gate
    }
    private func item(_ gate: VaultGate, _ title: String) -> StoredItem? { gate.items.first { $0.title == title } }

    func test_secureNote_saveAndReload_bodyPersists() async throws {
        let gate = await unlockedGate()
        let body = "NoteType:Passport\nNumber:123456789\nCountry:GB"
        await gate.saveTypedItem(id: nil, type: VaultItemType.secureNote, title: "Passport (UK)",
                                 payloadData: try LoginPayload(notes: body).encoded(), hosts: [])
        let note = try XCTUnwrap(item(gate, "Passport (UK)"))
        XCTAssertEqual(note.type, VaultItemType.secureNote)
        XCTAssertFalse(note.isLogin)
        XCTAssertEqual(gate.decryptPayload(note)?.notes, body)

        // Edit the body → save with the same id → reload → persists.
        await gate.saveTypedItem(id: note.id, type: VaultItemType.secureNote, title: "Passport (UK)",
                                 payloadData: try LoginPayload(notes: body + "\nNotes:in the safe").encoded(), hosts: note.hosts)
        XCTAssertEqual(gate.decryptPayload(item(gate, "Passport (UK)")!)?.notes, body + "\nNotes:in the safe")
    }

    func test_address_saveAndReload_discreteFields_countyVsState() async throws {
        let gate = await unlockedGate()
        let addr = AddressPayload(label: "Home", firstName: "Jane", lastName: "Jose",
                                  line1: "221B Baker Street", city: "London",
                                  county: "Greater London", stateProvince: nil,
                                  postalCode: "NW1 6XE", country: "United Kingdom",
                                  phone: "+44 20 7946 0958", phoneCountry: "GBR", email: "a@example.com",
                                  rawBody: "NoteType:Address\n…")
        await gate.saveTypedItem(id: nil, type: VaultItemType.address, title: "Home",
                                 payloadData: try addr.encoded(), hosts: [])
        let stored = try XCTUnwrap(item(gate, "Home"))
        XCTAssertEqual(stored.type, VaultItemType.address)
        let back = try XCTUnwrap(gate.decryptAddress(stored))
        XCTAssertEqual(back.line1, "221B Baker Street")
        XCTAssertEqual(back.county, "Greater London")
        XCTAssertNil(back.stateProvince)                 // independent nullable — UK has no state
        XCTAssertEqual(back.phoneCountry, "GBR")
        XCTAssertEqual(back.rawBody, "NoteType:Address\n…")   // raw preserved
    }

    /// An address whose phone was stored as an all-empty JSON blob (the TV-1 lenient-parse misfire)
    /// heals to an empty field on read — so already-migrated addresses display correctly without a
    /// re-migration; a real number is left untouched.
    func test_address_emptyJSONPhone_healsOnRead() async throws {
        let gate = await unlockedGate()
        let dirty = AddressPayload(label: "Home", line1: "1 Street", city: "London",
                                   phone: #"{"num":"","ext":"","cc3l":""}"#, rawBody: "")
        await gate.saveTypedItem(id: nil, type: VaultItemType.address, title: "Home",
                                 payloadData: try dirty.encoded(), hosts: [])
        let healed = try XCTUnwrap(gate.decryptAddress(item(gate, "Home")!))
        XCTAssertEqual(healed.phone, "")           // not the raw JSON
        XCTAssertNil(healed.phoneCountry)

        let good = AddressPayload(label: "Work", phone: "+44 20 7946 0958", phoneCountry: "GBR")
        await gate.saveTypedItem(id: nil, type: VaultItemType.address, title: "Work",
                                 payloadData: try good.encoded(), hosts: [])
        XCTAssertEqual(gate.decryptAddress(item(gate, "Work")!)?.phone, "+44 20 7946 0958")
    }

    func test_typedItems_areNotAudited() async {
        let gate = await unlockedGate()
        // A weak-looking "password" inside a note body must NEVER be audited.
        await gate.saveTypedItem(id: nil, type: VaultItemType.secureNote, title: "Wifi",
                                 payloadData: (try? LoginPayload(notes: "Password:abc").encoded()) ?? Data(), hosts: [])
        await gate.runSecurityCheck()
        XCTAssertTrue(gate.audit.weak.isEmpty)
        XCTAssertTrue(gate.audit.isEmpty)
        XCTAssertEqual(HealthFlags(rawValue: item(gate, "Wifi")!.healthFlags).rawValue, 0)
    }
}
