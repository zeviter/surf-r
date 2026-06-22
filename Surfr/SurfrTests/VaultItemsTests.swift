import XCTest
import AppKit
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

    func test_copyUsername_landsAndConfirms() {
        let model = VaultItemDetailModel()
        model.load(payload: LoginPayload(username: "alice@example.com", password: "p"), hosts: [])
        model.copyUsername()
        XCTAssertEqual(model.copyConfirmation, "Username copied")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "alice@example.com", "username must actually land on the clipboard")
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

    func test_revealDirect_whenAuthNotRequired() async {
        let gate = await unlockedGate()
        gate.requireAuthToReveal = false
        await gate.saveItem(id: nil, title: "X", payload: LoginPayload(password: "secret"), hosts: [])
        let model = VaultItemDetailModel()
        model.load(payload: gate.decryptPayload(gate.items[0])!, hosts: [])
        await model.requestReveal(gate: gate)
        XCTAssertEqual(model.revealed, "secret")
        XCTAssertFalse(model.awaitingMaster)
    }

    /// 6a/6b: auth required + no biometric → master-password fallback (never a dead-end); wrong master
    /// errors, correct master reveals.
    func test_revealMasterFallback_whenAuthRequired() async {
        let gate = await unlockedGate()        // mock biometric unavailable → biometric branch skipped
        gate.requireAuthToReveal = true
        await gate.saveItem(id: nil, title: "X", payload: LoginPayload(password: "secret"), hosts: [])
        let model = VaultItemDetailModel()
        model.load(payload: gate.decryptPayload(gate.items[0])!, hosts: [])

        await model.requestReveal(gate: gate)
        XCTAssertTrue(model.awaitingMaster)
        XCTAssertNil(model.revealed)

        await model.submitMaster("wrong-password", gate: gate)
        XCTAssertTrue(model.masterError)
        XCTAssertNil(model.revealed)

        await model.submitMaster(master, gate: gate)
        XCTAssertEqual(model.revealed, "secret")
        XCTAssertFalse(model.awaitingMaster)
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

    /// Regression: unlocking from the locked card must STAY on the vault surface (locked-card →
    /// unlocked-list), not eject to new-tab. The decision hinges on "already on the vault tab?".
    func test_unlockTransitionMap_staysInVaultWhenAlreadyOnIt() {
        // Lock→unlock happens on the vault tab → do NOT navigate (no eject).
        XCTAssertFalse(BrowserState.shouldNavigateToVaultAfterUnlock(activeKind: .vault))
        // First open from a web/new-tab page → navigate to the vault surface.
        XCTAssertTrue(BrowserState.shouldNavigateToVaultAfterUnlock(activeKind: .web))
    }

    // MARK: - CSV import (Slice 5b)

    private func candidate(_ title: String, host: String, user: String, pw: String) -> ImportCandidate {
        ImportCandidate(title: title, hosts: [SurfrCore.Host(host: host, isPrimary: true)],
                        payload: LoginPayload(username: user, password: pw, urls: ["https://\(host)"]))
    }

    func test_import_roundTrip() async {
        let gate = await unlockedGate()
        let summary = await gate.importLogins([
            candidate("GitHub", host: "github.com", user: "alice", pw: "p1"),
            candidate("X", host: "x.com", user: "bob", pw: "p2"),
        ])
        XCTAssertEqual(summary.imported, 2)
        XCTAssertEqual(summary.skippedDuplicates, 0)
        XCTAssertFalse(summary.failed)
        XCTAssertEqual(gate.items.count, 2)
        let gh = gate.items.first { $0.title == "GitHub" }!
        XCTAssertEqual(gate.decryptPayload(gh)?.password, "p1")
    }

    func test_import_skipsExactDuplicates() async {
        let gate = await unlockedGate()
        let rows = [candidate("GitHub", host: "github.com", user: "alice", pw: "p1")]
        _ = await gate.importLogins(rows)
        let second = await gate.importLogins(rows)         // same file again
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.skippedDuplicates, 1)
        XCTAssertEqual(gate.items.count, 1, "exact duplicate must not double")
    }

    /// The flagged edge: same title+host+username but DIFFERENT password is a distinct credential —
    /// it must NOT be deduped away.
    func test_import_sameUserDifferentPassword_isNotDuplicate() async {
        let gate = await unlockedGate()
        let summary = await gate.importLogins([
            candidate("Site", host: "site.com", user: "u", pw: "first"),
            candidate("Site", host: "site.com", user: "u", pw: "second"),
        ])
        XCTAssertEqual(summary.imported, 2, "different password ⇒ not a duplicate")
        XCTAssertEqual(summary.skippedDuplicates, 0)
        let passwords = Set(gate.items.compactMap { gate.decryptPayload($0)?.password })
        XCTAssertEqual(passwords, ["first", "second"])
    }

    // MARK: - TOTP import (Slice 7)

    private func sampleTOTP(issuer: String, account: String) -> TOTP {
        TOTP(secret: Data("12345678901234567890".utf8), issuer: issuer, account: account)
    }

    func test_totpImport_createNewItem() async {
        let gate = await unlockedGate()
        let s = await gate.importTOTP([TOTPImportDecision(totp: sampleTOTP(issuer: "GitHub", account: "alice"),
                                                          suggestion: nil, attachTo: nil)])
        XCTAssertEqual(s.imported, 1)
        XCTAssertEqual(gate.items.count, 1)
        XCTAssertEqual(gate.items[0].title, "GitHub")
        XCTAssertNotNil(gate.decryptPayload(gate.items[0])?.totp)
    }

    func test_totpImport_attachToExisting_preservesFields() async {
        let gate = await unlockedGate()
        await gate.saveItem(id: nil, title: "GitHub", payload: LoginPayload(username: "u", password: "p"),
                            hosts: [SurfrCore.Host(host: "github.com", isPrimary: true)])
        let existing = gate.items[0]
        let s = await gate.importTOTP([TOTPImportDecision(totp: sampleTOTP(issuer: "GitHub", account: "u"),
                                                          suggestion: existing.id, attachTo: existing.id)])
        XCTAssertEqual(s.imported, 1)
        XCTAssertEqual(gate.items.count, 1, "attached, not a new item")
        let p = gate.decryptPayload(gate.items.first { $0.id == existing.id }!)
        XCTAssertNotNil(p?.totp)
        XCTAssertEqual(p?.password, "p", "existing password preserved on attach")
    }

    func test_suggestedMatch_exactlyOneOrNil() async {
        let gate = await unlockedGate()
        await gate.saveItem(id: nil, title: "GitHub", payload: LoginPayload(password: "p"),
                            hosts: [SurfrCore.Host(host: "github.com", isPrimary: true)])
        XCTAssertNotNil(gate.suggestedMatchForTOTP(issuer: "GitHub"))     // title match
        XCTAssertNil(gate.suggestedMatchForTOTP(issuer: "Nonexistent"))
        XCTAssertNil(gate.suggestedMatchForTOTP(issuer: ""))
    }

    func test_decodeTOTPs_migrationAndSingle() {
        XCTAssertEqual(TOTPImportCoordinator.decodeTOTPs(from: "otpauth://totp/X?secret=JBSWY3DPEHPK3PXP").count, 1)
        XCTAssertTrue(TOTPImportCoordinator.decodeTOTPs(from: "not a uri").isEmpty)
    }

    /// Migration/repair: an item stored with an un-normalized host (legacy LastPass import) is healed
    /// to its registrable domain on load, so autofill matching works.
    func test_loadItems_repairsLegacyHosts() async {
        let gate = await unlockedGate()
        await gate.saveItem(id: nil, title: "Amazon", payload: LoginPayload(password: "p"),
                            hosts: [SurfrCore.Host(host: "www.amazon.co.uk", isPrimary: true)])
        // saveItem → loadItems self-heals www.amazon.co.uk → amazon.co.uk (and persists it).
        XCTAssertEqual(gate.items.first?.hosts.map(\.host), ["amazon.co.uk"])
        await gate.loadItems()   // idempotent — stays normalized
        XCTAssertEqual(gate.items.first?.hosts.map(\.host), ["amazon.co.uk"])
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
