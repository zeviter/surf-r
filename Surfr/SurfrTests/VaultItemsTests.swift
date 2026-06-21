import XCTest
import SurfrCore
@testable import Surfr

@MainActor
final class LoginPayloadTests: XCTestCase {
    func test_roundTrip() throws {
        let p = LoginPayload(username: "u", password: "p", notes: "n",
                             totp: "otpauth://totp/x", urls: ["https://a.example"],
                             custom: ["k": "v"])
        XCTAssertEqual(try LoginPayload.decoded(from: try p.encoded()), p)
    }

    func test_detailModel_wipeClearsPlaintext() {
        let model = VaultItemDetailModel()
        model.load(payload: LoginPayload(username: "alice", password: "s3cret!"), hosts: [])
        XCTAssertEqual(model.username, "alice")
        XCTAssertFalse(model.isWiped)

        model.wipe()
        XCTAssertTrue(model.isWiped)
        XCTAssertEqual(model.username, "", "decrypted fields must be cleared on close")
        XCTAssertTrue(model.passwordIsWipedForTest, "password buffer must be memset-zeroed on close")
    }
}

@MainActor
final class VaultItemsTests: XCTestCase {
    private var tempDir: URL!
    private let master = "correct horse battery staple violet anchor"

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("surfr-items-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "SurfrVaultLastMasterAuth")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removeObject(forKey: "SurfrVaultLastMasterAuth")
    }

    /// Biometric not enabled, so reveal/decrypt paths never trigger a real Touch ID prompt in CI.
    private func unlockedGate() async -> VaultGate {
        let mock = MockBiometricUnlock(); mock.available = false
        let gate = VaultGate.makeForTests(storePath: tempDir.appendingPathComponent("vault.sqlite"), biometric: mock)
        await gate.load()
        gate.beginFirstRun()
        await gate.submitMaster(master)
        await gate.acknowledgeKit(enableBiometric: false)
        return gate
    }

    func test_addDecryptEditDelete() async {
        let gate = await unlockedGate()
        XCTAssertEqual(gate.phase, .unlocked)
        await gate.loadItems()
        XCTAssertTrue(gate.items.isEmpty)

        // Add
        await gate.saveItem(id: nil, title: "GitHub",
                            payload: LoginPayload(username: "u", password: "p", urls: ["https://github.com"]),
                            hosts: [SurfrCore.Host(host: "github.com", isPrimary: true)])
        XCTAssertEqual(gate.items.count, 1)
        let item = gate.items[0]
        XCTAssertEqual(item.title, "GitHub")
        XCTAssertEqual(item.hosts.first?.host, "github.com")

        // Decrypt round-trip (the only decryption path)
        let payload = gate.decryptPayload(item)
        XCTAssertEqual(payload?.username, "u")
        XCTAssertEqual(payload?.password, "p")
        let firstCiphertext = item.sealed.ciphertext

        // Edit → re-encrypts under a fresh per-item key (ciphertext changes)
        await gate.saveItem(id: item.id, title: "GitHub",
                            payload: LoginPayload(username: "u2", password: "p2"), hosts: [])
        let edited = gate.items.first { $0.id == item.id }!
        XCTAssertNotEqual(edited.sealed.ciphertext, firstCiphertext)
        XCTAssertEqual(gate.decryptPayload(edited)?.username, "u2")
        XCTAssertEqual(edited.createdAt, item.createdAt, "createdAt preserved across edit")

        // Delete
        await gate.deleteItem(item.id)
        XCTAssertTrue(gate.items.isEmpty)
    }

    func test_revealWorksDirectlyWhenBiometricNotEnabled() async {
        // With biometric not enabled, authenticateForReveal returns true without any prompt.
        let gate = await unlockedGate()
        let allowed = await gate.authenticateForReveal()
        XCTAssertTrue(allowed)
    }

    /// Regression for the trust-destroying bug: lock clears the in-memory list, but unlocking again
    /// in the same session must re-hydrate it — not look like "locking deleted my passwords."
    func test_lockThenUnlock_itemPersistsInList() async {
        let gate = await unlockedGate()
        await gate.saveItem(id: nil, title: "GitHub", payload: LoginPayload(username: "u", password: "p"), hosts: [])
        XCTAssertEqual(gate.items.count, 1)

        gate.lockNow()
        XCTAssertTrue(gate.items.isEmpty)           // cleared on lock (correct)

        let ok = await gate.unlock(master: master)  // unlock again in the same session
        XCTAssertTrue(ok)
        XCTAssertEqual(gate.items.count, 1, "items must re-hydrate on unlock, not only after a save")
        XCTAssertEqual(gate.items.first?.title, "GitHub")
    }

    func test_lockClearsItems() async {
        let gate = await unlockedGate()
        await gate.saveItem(id: nil, title: "X", payload: LoginPayload(password: "p"), hosts: [])
        XCTAssertEqual(gate.items.count, 1)
        gate.lockNow()
        XCTAssertTrue(gate.items.isEmpty)
        XCTAssertEqual(gate.phase, .locked)
    }
}
