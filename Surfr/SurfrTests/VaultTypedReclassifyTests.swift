import XCTest
import SurfrCore
@testable import Surfr

/// Typed vault TV-1 — the in-app re-classification walk: imported secure notes (host "sn", body in
/// LoginPayload.notes — the Slice-9 shape) are refined into payment/address with structured fields,
/// losslessly, idempotently, and with the card number/CVV staying encrypted at rest. Logins untouched.
@MainActor
final class VaultTypedReclassifyTests: XCTestCase {
    private var tempDir: URL!
    private let master = "correct horse battery staple violet anchor"

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("surfr-typed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for k in ["SurfrVaultLastMasterAuth", VaultGate.hostRecoveryAttemptedKey, "SurfrTypedVaultReclassifiedV1"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        for k in ["SurfrVaultLastMasterAuth", VaultGate.hostRecoveryAttemptedKey, "SurfrTypedVaultReclassifiedV1"] {
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

    private let cardBody = """
    NoteType:Credit Card
    Name on Card:zeviter Jose
    Type:Visa
    Number:4111 1111 1111 1111
    Security Code:737
    Expiration Date:June,2028
    """
    private let addressBody = """
    NoteType:Address
    First Name:zeviter
    Address 1:221B Baker Street
    City / Town:London
    County:Greater London
    Zip / Postal Code:NW1 6XE
    Country:United Kingdom
    Phone:{"num":"+44 20 7946 0958","cc3l":"GBR"}
    """

    /// Seed an item the way the Slice-9 state leaves it: a host-"sn" item whose note body is in
    /// LoginPayload.notes. saveItem stores it as login; loadItems reclassifies host "sn" → secureNote.
    private func seedNote(_ gate: VaultGate, title: String, body: String) async {
        await gate.saveItem(id: nil, title: title, payload: LoginPayload(notes: body),
                            hosts: [SurfrCore.Host(host: "sn", isPrimary: true)])
    }
    private func item(_ gate: VaultGate, _ title: String) -> StoredItem? { gate.items.first { $0.title == title } }

    func test_reclassify_refinesCardAndAddress_leavesPlainNote_andLogin() async {
        let gate = await unlockedGate()
        await seedNote(gate, title: "Premier Card", body: cardBody)
        await seedNote(gate, title: "Home", body: addressBody)
        await seedNote(gate, title: "Wifi", body: "SSID: home\nPassword: hunter2")   // plain → stays note
        // A genuine login must be untouched.
        await gate.saveItem(id: nil, title: "GitHub", payload: LoginPayload(username: "u", password: "Str0ng-Pass-9!"),
                            hosts: [SurfrCore.Host(host: "github.com", isPrimary: true)])

        // Slice-9 host-"sn" classification already happened in loadItems.
        XCTAssertEqual(item(gate, "Premier Card")?.type, VaultItemType.secureNote)

        await gate.reclassifyTypedItems()

        // Card → payment, with structured fields; the body-derived sensitive fields decode back.
        XCTAssertEqual(item(gate, "Premier Card")?.type, VaultItemType.payment)
        let card = gate.decryptPayment(item(gate, "Premier Card")!)
        XCTAssertEqual(card?.cardholderName, "zeviter Jose")
        XCTAssertEqual(card?.number, "4111 1111 1111 1111")
        XCTAssertEqual(card?.cvv, "737")
        XCTAssertEqual(card?.cardType, "Visa")
        XCTAssertEqual(card?.rawBody, cardBody)             // lossless

        // Address → address, discrete fields incl. county (UK) and parsed phone.
        XCTAssertEqual(item(gate, "Home")?.type, VaultItemType.address)
        let addr = gate.decryptAddress(item(gate, "Home")!)
        XCTAssertEqual(addr?.line1, "221B Baker Street")
        XCTAssertEqual(addr?.city, "London")
        XCTAssertEqual(addr?.county, "Greater London")
        XCTAssertNil(addr?.stateProvince)
        XCTAssertEqual(addr?.phone, "+44 20 7946 0958")
        XCTAssertEqual(addr?.phoneCountry, "GBR")

        // Plain note stays a secureNote; genuine login untouched.
        XCTAssertEqual(item(gate, "Wifi")?.type, VaultItemType.secureNote)
        XCTAssertEqual(item(gate, "GitHub")?.type, VaultItemType.login)
        XCTAssertEqual(gate.decryptPayload(item(gate, "GitHub")!)?.password, "Str0ng-Pass-9!")
    }

    func test_reclassify_isIdempotent() async {
        let gate = await unlockedGate()
        await seedNote(gate, title: "Premier Card", body: cardBody)
        await gate.reclassifyTypedItems()
        let cipher1 = item(gate, "Premier Card")!.sealed.ciphertext
        XCTAssertEqual(item(gate, "Premier Card")?.type, VaultItemType.payment)

        await gate.reclassifyTypedItems()   // second pass: item is no longer secureNote → skipped
        XCTAssertEqual(item(gate, "Premier Card")?.type, VaultItemType.payment)
        XCTAssertEqual(item(gate, "Premier Card")!.sealed.ciphertext, cipher1, "idempotent: not re-encrypted")
    }

    /// Sensitive payment fields never reach a cleartext column — scan the real DB files for the card
    /// number + CVV after re-classification.
    func test_reclassify_cardNumberAndCVV_notInCleartext() async {
        let gate = await unlockedGate()
        await seedNote(gate, title: "Premier Card", body: cardBody)
        await gate.reclassifyTypedItems()

        for sentinel in ["4111 1111 1111 1111", "4111111111111111", "737"] {
            let bytes = Data(sentinel.utf8)
            for suffix in ["", "-wal"] {
                let url = tempDir.appendingPathComponent("vault.sqlite\(suffix)")
                if let file = try? Data(contentsOf: url) {
                    XCTAssertNil(file.range(of: bytes), "‘\(sentinel)’ leaked into vault.sqlite\(suffix)")
                }
            }
        }
    }
}
