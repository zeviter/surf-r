import XCTest
import CryptoKit
@testable import SurfrCore

/// Slice 9 — the store's keyed audit cache: health-flag writes, reuse-token round-trips, the audit
/// bookkeeping row, and the **zero-leak** proof that the persisted token is the keyed HMAC, never the
/// password (nor a recoverable hash of it) — scanned over the real db files incl. the WAL.
final class VaultAuditStoreTests: XCTestCase {

    private static let fastParams = KDFParams(memoryKiB: 256, iterations: 1, parallelism: 1)
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("surfr-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tempDir) }

    private func newStore() throws -> VaultStore { try VaultStore(path: tempDir.appendingPathComponent("vault.sqlite")) }
    private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    private func seed(_ store: VaultStore, vaultKey: SymmetricKey, count: Int) async throws -> [StoredItem] {
        var items: [StoredItem] = []
        for i in 0..<count {
            let item = StoredItem(title: "Item \(i)", createdAt: at(1), modifiedAt: at(1),
                                  sealed: try VaultCrypto.encryptNewItem(Data("p\(i)".utf8), vaultKey: vaultKey),
                                  hosts: [Host(host: "site\(i).com", isPrimary: true)])
            try await store.upsert(item)
            items.append(item)
        }
        return items
    }

    func test_setHealth_writesFlagsAndToken_andTokensRoundTrip() async throws {
        let (_, vaultKey) = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: "r", params: Self.fastParams)
        let store = try newStore()
        let items = try await seed(store, vaultKey: vaultKey, count: 3)
        let auditKey = VaultCrypto.deriveAuditKey(vaultKey: vaultKey)

        // Item 0 & 1 share a password ⇒ same token; item 2 unique.
        let shared = VaultCrypto.auditReuseToken(normalizedPassword: AuditEngine.normalizedPasswordData("shared-pw"), auditKey: auditKey)
        let unique = VaultCrypto.auditReuseToken(normalizedPassword: AuditEngine.normalizedPasswordData("unique-pw"), auditKey: auditKey)

        try await store.setHealth(flags: HealthFlags.weak.rawValue, reuseToken: shared, forItemID: items[0].id, computedAt: at(2))
        try await store.setHealth(flags: 0, reuseToken: shared, forItemID: items[1].id, computedAt: at(2))
        try await store.setHealth(flags: HealthFlags([.twoFAAvailable]).rawValue, reuseToken: unique, forItemID: items[2].id, computedAt: at(2))

        let tokens = try await store.auditTokens()
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(AuditEngine.reusedItemIDs(tokensByItem: tokens), [items[0].id, items[1].id])

        // Flags persisted on the items.
        let reloaded = try await store.allItems()
        let flagsByID = Dictionary(uniqueKeysWithValues: reloaded.map { ($0.id, $0.healthFlags) })
        XCTAssertEqual(flagsByID[items[0].id], HealthFlags.weak.rawValue)
        XCTAssertEqual(flagsByID[items[2].id], HealthFlags.twoFAAvailable.rawValue)
    }

    func test_setHealth_nilToken_removesToken() async throws {
        let (_, vaultKey) = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: "r", params: Self.fastParams)
        let store = try newStore()
        let items = try await seed(store, vaultKey: vaultKey, count: 1)
        let auditKey = VaultCrypto.deriveAuditKey(vaultKey: vaultKey)
        let token = VaultCrypto.auditReuseToken(normalizedPassword: AuditEngine.normalizedPasswordData("pw"), auditKey: auditKey)

        try await store.setHealth(flags: 0, reuseToken: token, forItemID: items[0].id, computedAt: at(2))
        let afterSet = try await store.auditTokens()
        XCTAssertEqual(afterSet.count, 1)

        // A later edit clears the password (e.g. became TOTP-only) ⇒ token removed.
        try await store.setHealth(flags: HealthFlags.hasTOTP.rawValue, reuseToken: nil, forItemID: items[0].id, computedAt: at(3))
        let afterClear = try await store.auditTokens()
        XCTAssertTrue(afterClear.isEmpty)
    }

    func test_auditMeta_roundTrip_and_clearTokens() async throws {
        let (_, vaultKey) = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: "r", params: Self.fastParams)
        let store = try newStore()
        let items = try await seed(store, vaultKey: vaultKey, count: 1)
        let auditKey = VaultCrypto.deriveAuditKey(vaultKey: vaultKey)
        let check = VaultCrypto.auditKeyCheck(auditKey: auditKey)

        let beforeMeta = try await store.loadAuditMeta()
        XCTAssertNil(beforeMeta)
        try await store.saveAuditMeta(keyCheck: check, checkedAt: at(100))
        let loaded = try await store.loadAuditMeta()
        XCTAssertEqual(loaded?.keyCheck, check)
        XCTAssertEqual(loaded?.checkedAt, at(100))

        try await store.setHealth(flags: 0,
                                  reuseToken: VaultCrypto.auditReuseToken(normalizedPassword: Data("x".utf8), auditKey: auditKey),
                                  forItemID: items[0].id, computedAt: at(2))
        try await store.clearAuditTokens()
        let clearedTokens = try await store.auditTokens()
        XCTAssertTrue(clearedTokens.isEmpty)
        // clearAuditTokens leaves the bookkeeping row intact.
        let metaAfterClear = try await store.loadAuditMeta()
        XCTAssertNotNil(metaAfterClear)
    }

    func test_wipeAll_clearsAuditMetaAndTokens() async throws {
        let (_, vaultKey) = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: "r", params: Self.fastParams)
        let store = try newStore()
        let items = try await seed(store, vaultKey: vaultKey, count: 1)
        let auditKey = VaultCrypto.deriveAuditKey(vaultKey: vaultKey)
        try await store.setHealth(flags: 0,
                                  reuseToken: VaultCrypto.auditReuseToken(normalizedPassword: Data("x".utf8), auditKey: auditKey),
                                  forItemID: items[0].id, computedAt: at(2))
        try await store.saveAuditMeta(keyCheck: VaultCrypto.auditKeyCheck(auditKey: auditKey), checkedAt: at(100))

        try await store.wipeAll()
        let tokensAfterWipe = try await store.auditTokens()
        XCTAssertTrue(tokensAfterWipe.isEmpty)
        let metaAfterWipe = try await store.loadAuditMeta()
        XCTAssertNil(metaAfterWipe)
    }

    /// The sentinel proof: a token derived from a high-entropy password never lets that password (nor
    /// a recoverable form of it) reach disk — only the keyed HMAC does. Scans main db + WAL + sidecars.
    func test_auditToken_onDisk_isKeyedHMAC_notThePassword() async throws {
        let (_, vaultKey) = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: "r", params: Self.fastParams)
        let store = try newStore()
        let items = try await seed(store, vaultKey: vaultKey, count: 1)
        let auditKey = VaultCrypto.deriveAuditKey(vaultKey: vaultKey)

        let sentinel = VaultCrypto.generateRecoveryCode(groups: 8, groupSize: 6)   // ~240-bit unique password
        let sentinelBytes = AuditEngine.normalizedPasswordData(sentinel)
        let token = VaultCrypto.auditReuseToken(normalizedPassword: sentinelBytes, auditKey: auditKey)
        try await store.setHealth(flags: HealthFlags.weak.rawValue, reuseToken: token, forItemID: items[0].id, computedAt: at(2))

        try await store.walCheckpointForReview()
        let bareHash = Data(SHA256.hash(data: sentinelBytes))   // an unsalted hash must not be present either
        var scanned: [String] = []
        var tokenFoundSomewhere = false
        for url in store.databaseFileURLsForReview where FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            scanned.append(url.lastPathComponent)
            XCTAssertNil(bytes.range(of: sentinelBytes), "password sentinel leaked into \(url.lastPathComponent)")
            XCTAssertNil(bytes.range(of: bareHash), "an unsalted hash of the password reached \(url.lastPathComponent)")
            if bytes.range(of: token) != nil { tokenFoundSomewhere = true }
        }
        // The keyed token IS the value persisted (in the main db) — so we know we scanned real data,
        // and what's on disk is the HMAC, not the password.
        XCTAssertTrue(tokenFoundSomewhere, "the keyed token should be the value on disk")
        print("🔎 audit_cache scan covered \(scanned.joined(separator: ", ")) — keyed token present, password & bare-hash ABSENT")
    }
}
