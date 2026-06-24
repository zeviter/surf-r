import XCTest
import SurfrCore
@testable import Surfr

/// Slice 9 — the Security Check walk end-to-end through `VaultGate`: weak / reused / 2FA-available /
/// junk-host classification over real stored+encrypted items, plus the URL-derivable junk-host
/// auto-fix. Mirrors the "real imported data" path (`github.com` is in the bundled 2FA snapshot;
/// `weak.example` etc. are not).
@MainActor
final class VaultSecurityCheckTests: XCTestCase {
    private var tempDir: URL!
    private let master = "correct horse battery staple violet anchor"

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("surfr-audit-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: "SurfrVaultLastMasterAuth")
        UserDefaults.standard.removeObject(forKey: VaultGate.hostRecoveryAttemptedKey)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        UserDefaults.standard.removeObject(forKey: "SurfrVaultLastMasterAuth")
        UserDefaults.standard.removeObject(forKey: VaultGate.hostRecoveryAttemptedKey)
    }

    private func unlockedGate() async -> VaultGate {
        let mock = MockBiometricUnlock(); mock.available = false
        let gate = VaultGate.makeForTests(storePath: tempDir.appendingPathComponent("vault.sqlite"), biometric: mock)
        await gate.load(); gate.beginFirstRun(); await gate.submitMaster(master)
        await gate.acknowledgeKit(enableBiometric: false)
        return gate
    }

    private func add(_ gate: VaultGate, title: String, host: String?, password: String,
                     urls: [String] = [], totp: String? = nil) async {
        let hosts = host.map { [SurfrCore.Host(host: $0, isPrimary: true)] } ?? []
        await gate.saveItem(id: nil, title: title,
                            payload: LoginPayload(username: "u", password: password, totp: totp, urls: urls),
                            hosts: hosts)
    }

    private func titles(_ gate: VaultGate, _ ids: [UUID]) -> Set<String> {
        Set(ids.compactMap { id in gate.items.first { $0.id == id }?.title })
    }
    private func item(_ gate: VaultGate, _ title: String) -> StoredItem? { gate.items.first { $0.title == title } }

    func test_securityCheck_classifiesAllSignals_andAutoFixesJunkFromURL() async {
        let gate = await unlockedGate()

        // Weak: 3-char password, host not in the 2FA set.
        await add(gate, title: "Weak", host: "weak.example", password: "abc")
        // Reused pair: identical STRONG password (so weak doesn't conflate) on two distinct sites.
        await add(gate, title: "ReusedA", host: "reuseda.example", password: "ReusedP@ssw0rd!")
        await add(gate, title: "ReusedB", host: "reusedb.example", password: "ReusedP@ssw0rd!")
        // 2FA-available: github.com (in the snapshot), strong unique password, no TOTP.
        await add(gate, title: "GitHub", host: "github.com", password: "Gh-Str0ng-Uniq-9!")
        // Same site WITH a TOTP seed already ⇒ NOT 2FA-available.
        await add(gate, title: "GitHubTOTP", host: "github.com", password: "Gh-Other-Str0ng-7!",
                  totp: "otpauth://totp/x?secret=JBSWY3DPEHPK3PXP")
        // Genuine hostless LOGIN, no recoverable URL ⇒ stays "needs attention".
        await add(gate, title: "JunkNoURL", host: nil, password: "Junk-Str0ng-Pw-3!")
        // Hostless LOGIN BUT a payload URL parses to a real domain ⇒ host recovered (not junk).
        await add(gate, title: "JunkFixable", host: nil, password: "Fix-Str0ng-Pw-5!",
                  urls: ["https://www.fixme.org/login"])
        // LastPass secure note / card (host "sn", a card-number-looking "password") ⇒ NON-LOGIN:
        // reclassified, excluded from every audit signal, never scanned as a weak/reused password.
        await add(gate, title: "MyCard", host: "sn", password: "4111-1111-1111-1111", urls: ["http://sn"])

        await gate.runSecurityCheck()

        // Weak — only the short password (the card number is NOT scanned).
        XCTAssertEqual(titles(gate, gate.audit.weak), ["Weak"])
        // Reused — exactly the shared-password pair.
        XCTAssertEqual(titles(gate, gate.audit.reused), ["ReusedA", "ReusedB"])
        // Reused renders as one cluster of two (never the password value).
        XCTAssertEqual(gate.audit.reuseClusters.count, 1)
        XCTAssertEqual(titles(gate, gate.audit.reuseClusters.first ?? []), ["ReusedA", "ReusedB"])
        // 2FA-available — github.com without a code; the one with a code is excluded.
        XCTAssertEqual(titles(gate, gate.audit.twoFAAvailable), ["GitHub"])
        // Needs attention — the genuine hostless login only.
        XCTAssertEqual(titles(gate, gate.audit.junk), ["JunkNoURL"])

        // The non-login secure note is in NO audit group, but remains in the vault, reclassified.
        for group in [gate.audit.weak, gate.audit.reused, gate.audit.twoFAAvailable, gate.audit.junk] {
            XCTAssertFalse(titles(gate, group).contains("MyCard"))
        }
        XCTAssertEqual(item(gate, "MyCard")?.type, VaultItemType.secureNote)
        XCTAssertFalse(item(gate, "MyCard")!.isLogin)

        // Verify (not just assert) the card body is encrypted at rest: the card number appears in NO
        // cleartext DB bytes — only title/host are cleartext (§13). Recognizing it as non-login adds
        // no at-rest exposure.
        let cardSentinel = Data("4111-1111-1111-1111".utf8)
        for suffix in ["", "-wal"] {
            let url = tempDir.appendingPathComponent("vault.sqlite\(suffix)")
            if let bytes = try? Data(contentsOf: url) {
                XCTAssertNil(bytes.range(of: cardSentinel), "card number leaked into vault.sqlite\(suffix)")
            }
        }

        // Host recovered from the payload URL (hostless login auto-fix path).
        XCTAssertEqual(item(gate, "JunkFixable")?.hosts.map(\.host), ["fixme.org"])
        // The un-recoverable one stays hostless, surfaced for a manual fix.
        XCTAssertEqual(item(gate, "JunkNoURL")?.hosts.count, 0)

        // Reuse group size feeds the "shares with N others" copy.
        if let a = item(gate, "ReusedA") { XCTAssertEqual(gate.audit.reuseGroupSize[a.id], 2) }
        XCTAssertNotNil(gate.audit.lastChecked)

        // Lock clears the derived signals (session state, not persisted to the list).
        gate.lockNow()
        XCTAssertTrue(gate.audit.isEmpty)
        XCTAssertTrue(gate.reusedItemIDs.isEmpty)
    }

    /// Health flags persist on the items (read with zero decryption) and survive a lock/unlock — the
    /// WF-4 badge path never needs to decrypt.
    func test_healthFlags_persistAcrossLockUnlock_zeroDecryption() async {
        let gate = await unlockedGate()
        await add(gate, title: "Weak", host: "weak.example", password: "abc")
        await gate.runSecurityCheck()
        let weakID = item(gate, "Weak")!.id
        XCTAssertTrue(HealthFlags(rawValue: item(gate, "Weak")!.healthFlags).contains(.weak))

        gate.lockNow()
        let ok = await gate.unlock(master: master)
        XCTAssertTrue(ok)
        // After unlock, loadItems re-derives the summary from stored flags + tokens — no walk needed.
        XCTAssertTrue(HealthFlags(rawValue: gate.items.first { $0.id == weakID }!.healthFlags).contains(.weak))
        XCTAssertTrue(gate.audit.weak.contains(weakID))
    }
}
