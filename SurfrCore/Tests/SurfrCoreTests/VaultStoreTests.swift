import XCTest
import CryptoKit
@testable import SurfrCore

final class VaultStoreTests: XCTestCase {

    private static let fastParams = KDFParams(memoryKiB: 256, iterations: 1, parallelism: 1)

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("surfr-vaultstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func newStore(file: String = "vault.sqlite") throws -> VaultStore {
        try VaultStore(path: tempDir.appendingPathComponent(file))
    }

    private func fixedDate(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    // 1 — Meta round-trip through disk.
    func test_meta_roundTrip() async throws {
        let (meta, _) = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: "r-code", params: Self.fastParams)

        let path = tempDir.appendingPathComponent("vault.sqlite")
        try await VaultStore(path: path).saveMeta(meta)

        // Reopen a fresh store on the same file.
        let reloaded = try await VaultStore(path: path).loadMeta()
        XCTAssertEqual(reloaded, meta)
    }

    func test_loadMeta_nilBeforeFirstRun() async throws {
        let store = try newStore()
        let hasVault = try await store.hasVault()
        let meta = try await store.loadMeta()
        XCTAssertFalse(hasVault)
        XCTAssertNil(meta)
    }

    // 2 — Full crypto round-trip: encrypt → store → reload → decrypt.
    func test_item_encryptStoreReloadDecrypt() async throws {
        let (meta, vaultKey) = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: "r", params: Self.fastParams)
        let path = tempDir.appendingPathComponent("vault.sqlite")
        let store = try VaultStore(path: path)
        try await store.saveMeta(meta)

        let payload = Data(#"{"username":"a@b.com","password":"hunter2","notes":"x"}"#.utf8)
        let sealed = try VaultCrypto.encryptNewItem(payload, vaultKey: vaultKey)
        let item = StoredItem(title: "Example",
                              createdAt: fixedDate(1_700_000_000),
                              modifiedAt: fixedDate(1_700_000_000),
                              sealed: sealed,
                              hosts: [Host(host: "example.com", isPrimary: true)])
        try await store.upsert(item)

        // Reopen and decrypt with a key obtained by unlocking the persisted meta.
        let store2 = try VaultStore(path: path)
        let reloadedMeta = try await store2.loadMeta()
        let unlockedKey = try VaultCrypto.unlockWithMaster("m", meta: try XCTUnwrap(reloadedMeta))
        let fetched = try await XCTUnwrapAsync(try await store2.item(id: item.id))
        let decrypted = try VaultCrypto.decryptItem(fetched.sealed, vaultKey: unlockedKey)
        XCTAssertEqual(decrypted, payload)
        XCTAssertEqual(fetched.title, "Example")
        XCTAssertEqual(fetched.hosts, [Host(host: "example.com", isPrimary: true)])
    }

    // 3 — Item CRUD + host cascade + host matching.
    func test_item_crud_and_hostCascade() async throws {
        let (_, vaultKey) = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: "r", params: Self.fastParams)
        let store = try newStore()

        func makeItem(title: String, host: String, modified: TimeInterval) throws -> StoredItem {
            StoredItem(title: title,
                       createdAt: fixedDate(1_700_000_000),
                       modifiedAt: fixedDate(modified),
                       sealed: try VaultCrypto.encryptNewItem(Data(title.utf8), vaultKey: vaultKey),
                       hosts: [Host(host: host, isPrimary: true)])
        }

        let a = try makeItem(title: "Alpha", host: "alpha.com", modified: 1_700_000_100)
        let b = try makeItem(title: "Beta", host: "beta.com", modified: 1_700_000_200)
        try await store.upsert(a)
        try await store.upsert(b)

        // Ordering: most-recently-modified first.
        let all = try await store.allItems()
        XCTAssertEqual(all.map(\.title), ["Beta", "Alpha"])

        // Host matching.
        let alphaMatch = try await store.itemsMatching(host: "alpha.com")
        XCTAssertEqual(alphaMatch.map(\.id), [a.id])
        let noMatch = try await store.itemsMatching(host: "nope.com")
        XCTAssertEqual(noMatch.count, 0)

        // Update modifies modified_at and replaces hosts.
        var aUpdated = a
        aUpdated.modifiedAt = fixedDate(1_700_000_300)
        aUpdated.hosts = [Host(host: "alpha.net", isPrimary: true)]
        try await store.upsert(aUpdated)
        let afterUpdate = try await store.allItems()
        XCTAssertEqual(afterUpdate.map(\.title), ["Alpha", "Beta"])                    // Alpha now newest
        let oldHost = try await store.itemsMatching(host: "alpha.com")
        XCTAssertEqual(oldHost.count, 0)                                              // old host gone
        let newHost = try await store.itemsMatching(host: "alpha.net")
        XCTAssertEqual(newHost.map(\.id), [a.id])

        // Delete cascades hosts.
        try await store.deleteItem(id: a.id)
        let deleted = try await store.item(id: a.id)
        XCTAssertNil(deleted)
        let orphanHosts = try await store.itemsMatching(host: "alpha.net")
        XCTAssertEqual(orphanHosts.count, 0)
        let remaining = try await store.allItems()
        XCTAssertEqual(remaining.map(\.title), ["Beta"])
    }

    // 4 — No secret material on disk (main file + WAL + sidecars).
    func test_noPlaintextOnDisk_includingWAL() async throws {
        let (meta, vaultKey) = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: "r", params: Self.fastParams)
        let store = try newStore()
        try await store.saveMeta(meta)

        // High-entropy random sentinel so a match cannot be coincidence.
        let sentinel = VaultCrypto.generateRecoveryCode(groups: 8, groupSize: 6)   // ~240 bits, unique
        let sentinelBytes = Data(sentinel.utf8)
        let payload = Data(#"{"username":"u","password":"\#(sentinel)"}"#.utf8)
        let item = StoredItem(title: "Sentinel Item",
                              createdAt: fixedDate(1_700_000_000),
                              modifiedAt: fixedDate(1_700_000_000),
                              sealed: try VaultCrypto.encryptNewItem(payload, vaultKey: vaultKey),
                              hosts: [Host(host: "sentinel.example", isPrimary: true)])
        try await store.upsert(item)

        // Flush the WAL into the main db, then scan EVERY db file (main + -wal + -shm + -journal).
        try await store.walCheckpointForReview()

        let vaultKeyBytes = vaultKey.withUnsafeBytes { Data($0) }
        var scannedFiles: [String] = []
        for url in store.databaseFileURLsForReview where FileManager.default.fileExists(atPath: url.path) {
            let bytes = try Data(contentsOf: url)
            scannedFiles.append("\(url.lastPathComponent) (\(bytes.count)B)")
            XCTAssertNil(bytes.range(of: sentinelBytes), "secret sentinel leaked into \(url.lastPathComponent)")
            XCTAssertNil(bytes.range(of: vaultKeyBytes), "vault key bytes leaked into \(url.lastPathComponent)")
        }
        XCTAssertTrue(scannedFiles.contains { $0.hasPrefix("vault.sqlite ") }, "main db not scanned")

        // Print the scan result for the review record.
        print("🔎 no-plaintext scan covered: \(scannedFiles.joined(separator: ", ")) — sentinel & vault key ABSENT")
    }

    // 5 — Persisted VaultMeta contains only non-secret material; dump it for review.
    func test_meta_onDisk_hasNoSecretMaterial() async throws {
        let (meta, vaultKey) = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: "r", params: Self.fastParams)
        let store = try newStore()
        try await store.saveMeta(meta)

        let dump = try await store.dumpMetaColumnsForReview()
        print("🧾 serialized VaultMeta on disk:\n\(dump)")

        // The live vault key must not appear anywhere in the dumped/serialized meta.
        let vaultKeyHex = vaultKey.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        XCTAssertFalse(dump.contains(vaultKeyHex), "vault key bytes must never be serialized to vault_meta")

        // Sanity: the dump exposes exactly the expected, non-secret fields.
        for field in ["schema_version", "kdf_salt_master", "kdf_params_master", "wrapped_vault_key_master",
                      "kdf_salt_recovery", "kdf_params_recovery", "wrapped_vault_key_recovery"] {
            XCTAssertTrue(dump.contains(field), "missing \(field) in meta dump")
        }
        XCTAssertTrue(dump.contains("\"algorithm\":\"argon2id\""), "kdf params should be JSON with argon2id")
    }

    // 9 — Schema/version story.
    func test_migrator_idempotent_onReopen() async throws {
        let path = tempDir.appendingPathComponent("vault.sqlite")
        _ = try VaultStore(path: path)           // creates tables
        _ = try VaultStore(path: path)           // re-running the migrator must not throw
        let store = try VaultStore(path: path)
        let hasVault = try await store.hasVault()
        XCTAssertFalse(hasVault)
    }

    func test_loadMeta_rejectsNewerSchemaVersion() async throws {
        var (meta, _) = try VaultCrypto.createVault(masterPassword: "m", recoveryCode: "r", params: Self.fastParams)
        meta.schemaVersion = VaultCrypto.currentSchemaVersion + 1   // pretend a future build wrote this
        let store = try newStore()
        try await store.saveMeta(meta)

        do {
            _ = try await store.loadMeta()
            XCTFail("expected unsupportedSchemaVersion")
        } catch let error as VaultStoreError {
            XCTAssertEqual(error, .unsupportedSchemaVersion(found: VaultCrypto.currentSchemaVersion + 1,
                                                            supported: VaultCrypto.currentSchemaVersion))
        }
    }

    // Async XCTUnwrap helper.
    private func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?,
                                   file: StaticString = #filePath, line: UInt = #line) async throws -> T {
        let value = try await expression()
        return try XCTUnwrap(value, file: file, line: line)
    }
}
