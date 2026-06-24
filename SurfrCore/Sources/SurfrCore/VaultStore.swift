import Foundation
import GRDB

// MARK: - Item type markers

/// The `items.type` vocabulary. Only `login` participates in autofill + the Security Check audit;
/// everything else is stored and displayed but not audited/filled. `secureNote` is the catch-all
/// non-login marker (LastPass exports Secure Notes / Credit Cards / Addresses as notes with host
/// `sn`); the upcoming typed-vault slice refines it into note/address/payment by parsing the body.
public enum VaultItemType {
    public static let login = "login"
    public static let secureNote = "secureNote"   // non-login catch-all (host "sn"); not audited/filled
    public static let payment = "payment"         // LastPass NoteType:Credit Card (typed vault TV-1)
    public static let address = "address"         // LastPass NoteType:Address (typed vault TV-1)
    public static let passkey = "passkey"         // reserved (v2)
}

// MARK: - Public item model (ciphertext only — never a decrypted payload)

/// One host associated with an item (drives URL matching for fill, Slice 8). Cleartext metadata.
public struct Host: Equatable, Sendable {
    public var host: String
    public var isPrimary: Bool
    public init(host: String, isPrimary: Bool = false) {
        self.host = host
        self.isPrimary = isPrimary
    }
}

/// A row-ready vault item: cleartext **metadata** (title/hosts/dates) plus the encrypted `SealedItem`.
/// The store reads and writes only this — it never holds a decrypted credential payload. Decryption is
/// the caller's job via `VaultCrypto.decryptItem`.
public struct StoredItem: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var type: String            // "login" (default) · "passkey" (reserved) · …
    public var title: String           // cleartext metadata (see vault-spec §13 disclosure)
    public var createdAt: Date
    public var modifiedAt: Date
    public var sealed: SealedItem      // wrappedItemKey + ciphertext (GCM .combined), from VaultCrypto
    public var hosts: [Host]           // cleartext metadata
    public var healthFlags: Int        // bitmask; populated in Slice 9

    public init(id: UUID = UUID(),
                type: String = "login",
                title: String,
                createdAt: Date,
                modifiedAt: Date,
                sealed: SealedItem,
                hosts: [Host] = [],
                healthFlags: Int = 0) {
        self.id = id
        self.type = type
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.sealed = sealed
        self.hosts = hosts
        self.healthFlags = healthFlags
    }

    /// Only login items are autofilled + audited (vault-spec §7/§10). Non-login items (e.g. imported
    /// secure notes / cards) are stored and shown, but excluded from matching, badges, and the audit.
    public var isLogin: Bool { type == VaultItemType.login }
}

public enum VaultStoreError: Error, Equatable {
    /// The persisted `vault_meta.schema_version` is newer than this build understands. We refuse to
    /// read it rather than misinterpret a future envelope/payload format.
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case malformedRow(String)
}

// MARK: - VaultStore

/// GRDB-backed persistence for the encrypted vault (vault-spec §6, as amended). Import-clean
/// (Foundation + GRDB only — no AppKit/SwiftUI/WebKit, no CryptoKit: this layer never touches keys or
/// plaintext, only ciphertext blobs and cleartext metadata). All DB work runs on GRDB's serialized
/// queue. **No logging in this file** — see the no-logging guard test.
public final class VaultStore: Sendable {

    private let dbQueue: DatabaseQueue   // GRDB's DatabaseQueue is Sendable + internally serialized
    private let dbURL: URL               // immutable

    /// Opens (creating if needed) the vault database at `path` and runs migrations.
    ///
    /// File location: the app passes `Application Support/Surfr/vault.sqlite`; tests pass a temp URL.
    /// The App Group container (for the AutoFill extension, §3) drops in here later — **seam**.
    /// Data Protection: macOS relies on FileVault volume-key semantics; iOS `NSFileProtectionComplete`
    /// is wired in the Phase-6 iOS target via the file's `.protectionKey` — **seam**, not set here.
    public init(path: URL) throws {
        self.dbURL = path
        var config = Configuration()
        config.foreignKeysEnabled = true                      // make item_hosts/audit_cache cascades fire
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")  // WAL: writes land in -wal until checkpoint
        }
        let queue = try DatabaseQueue(path: path.path, configuration: config)
        try Self.migrator.migrate(queue)
        self.dbQueue = queue
    }

    // MARK: vault_meta

    public func hasVault() async throws -> Bool {
        try await dbQueue.read { db in try MetaRow.fetchOne(db, key: MetaRow.singletonID) != nil }
    }

    /// The persisted envelope metadata, or `nil` before first-run. Throws `unsupportedSchemaVersion`
    /// if the row was written by a newer build.
    public func loadMeta() async throws -> VaultMeta? {
        let row = try await dbQueue.read { db in try MetaRow.fetchOne(db, key: MetaRow.singletonID) }
        guard let row else { return nil }
        guard row.schemaVersion <= VaultCrypto.currentSchemaVersion else {
            throw VaultStoreError.unsupportedSchemaVersion(found: row.schemaVersion,
                                                           supported: VaultCrypto.currentSchemaVersion)
        }
        return VaultMeta(
            schemaVersion: row.schemaVersion,
            kdfSaltMaster: row.kdfSaltMaster,
            kdfParamsMaster: try Self.decodeParams(row.kdfParamsMaster),
            wrappedVaultKeyMaster: row.wrappedVaultKeyMaster,
            kdfSaltRecovery: row.kdfSaltRecovery,
            kdfParamsRecovery: try Self.decodeParams(row.kdfParamsRecovery),
            wrappedVaultKeyRecovery: row.wrappedVaultKeyRecovery
        )
    }

    /// Upsert the singleton metadata row.
    public func saveMeta(_ meta: VaultMeta) async throws {
        let row = MetaRow(
            id: MetaRow.singletonID,
            schemaVersion: meta.schemaVersion,
            kdfSaltMaster: meta.kdfSaltMaster,
            kdfParamsMaster: try Self.encodeParams(meta.kdfParamsMaster),
            wrappedVaultKeyMaster: meta.wrappedVaultKeyMaster,
            kdfSaltRecovery: meta.kdfSaltRecovery,
            kdfParamsRecovery: try Self.encodeParams(meta.kdfParamsRecovery),
            wrappedVaultKeyRecovery: meta.wrappedVaultKeyRecovery
        )
        try await dbQueue.write { db in try row.save(db) }
    }

    // MARK: items

    /// All items, most-recently-modified first.
    public func allItems() async throws -> [StoredItem] {
        try await dbQueue.read { db in
            try ItemRow.order(sql: "modified_at DESC").fetchAll(db).map { try Self.assemble($0, db) }
        }
    }

    public func item(id: UUID) async throws -> StoredItem? {
        try await dbQueue.read { db in
            guard let row = try ItemRow.fetchOne(db, key: id.uuidString) else { return nil }
            return try Self.assemble(row, db)
        }
    }

    /// Items with a matching host (used by URL-matched fill, Slice 8).
    public func itemsMatching(host: String) async throws -> [StoredItem] {
        try await dbQueue.read { db in
            let ids = try String.fetchAll(db,
                sql: "SELECT DISTINCT item_id FROM item_hosts WHERE host = ?",
                arguments: [host])
            return try ids.compactMap { try ItemRow.fetchOne(db, key: $0) }.map { try Self.assemble($0, db) }
        }
    }

    /// Insert or update an item and (re)write its hosts. `modifiedAt` is caller-controlled.
    public func upsert(_ item: StoredItem) async throws {
        try await dbQueue.write { db in
            try ItemRow(item).save(db)
            try HostRow.filter(Column("item_id") == item.id.uuidString).deleteAll(db)
            for host in item.hosts {
                try HostRow(itemId: item.id.uuidString, host: host.host, isPrimary: host.isPrimary).insert(db)
            }
        }
    }

    /// Bulk insert/update in a **single transaction** — all-or-nothing. Used by CSV import: a failure
    /// part-way rolls the whole batch back, never leaving a partial import. (Per-item AES-GCM is
    /// microseconds, so one transaction is essentially free.)
    public func upsertMany(_ items: [StoredItem]) async throws {
        guard !items.isEmpty else { return }
        try await dbQueue.write { db in
            for item in items {
                try ItemRow(item).save(db)
                try HostRow.filter(Column("item_id") == item.id.uuidString).deleteAll(db)
                for host in item.hosts {
                    try HostRow(itemId: item.id.uuidString, host: host.host, isPrimary: host.isPrimary).insert(db)
                }
            }
        }
    }

    /// Replace an item's `item_hosts` rows (cleartext metadata; no key needed). Used by the host
    /// normalization/repair pass for legacy imports.
    public func updateHosts(_ hosts: [Host], forItemID id: UUID) async throws {
        try await dbQueue.write { db in
            try HostRow.filter(Column("item_id") == id.uuidString).deleteAll(db)
            for host in hosts {
                try HostRow(itemId: id.uuidString, host: host.host, isPrimary: host.isPrimary).insert(db)
            }
        }
    }

    /// Delete an item; its `item_hosts` / `audit_cache` rows cascade.
    public func deleteItem(id: UUID) async throws {
        _ = try await dbQueue.write { db in try ItemRow.deleteOne(db, key: id.uuidString) }
    }

    /// Wipe the entire vault (meta + all items/hosts/audit) — `hasVault()` returns false afterward.
    /// Used by the "Reset vault" affordance so a reset clears the on-disk vault wherever it actually
    /// lives (the sandbox container), paired with a Keychain purge for the biometric door.
    public func wipeAll() async throws {
        try await dbQueue.write { db in
            try ItemRow.deleteAll(db)      // item_hosts + audit_cache cascade via FK
            try MetaRow.deleteAll(db)
            try db.execute(sql: "DELETE FROM audit_meta")
        }
    }

    // MARK: audit cache (Slice 9 — keyed reuse tokens + health flags; ZERO decryption in this layer)

    /// All keyed reuse tokens, `item_id → reuse_token`. The audit surface and the WF-4 list badges
    /// group these (an item is "reused" iff its token appears on ≥2 items) **without decrypting
    /// anything**. The token is `HMAC-SHA256(audit_key, password)` — equality only, never the password.
    public func auditTokens() async throws -> [UUID: Data] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT item_id, reuse_token FROM audit_cache")
            var out: [UUID: Data] = [:]
            for r in rows {
                let idString: String = r["item_id"]
                guard let id = UUID(uuidString: idString) else { continue }
                out[id] = r["reuse_token"]
            }
            return out
        }
    }

    /// Persist one item's audit result in a single write: the intrinsic `health_flags` bitfield **and**
    /// its reuse token (passing `reuseToken: nil` removes the token — used for a password-less item).
    /// Called per item during the backfill walk and on every save/edit/import (steady-state keying).
    public func setHealth(flags: Int, reuseToken: Data?, forItemID id: UUID, computedAt: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE items SET health_flags = ? WHERE id = ?",
                           arguments: [flags, id.uuidString])
            if let token = reuseToken {
                try db.execute(sql: """
                    INSERT INTO audit_cache (item_id, reuse_token, computed_at) VALUES (?, ?, ?)
                    ON CONFLICT(item_id) DO UPDATE SET reuse_token = excluded.reuse_token,
                                                       computed_at = excluded.computed_at
                    """, arguments: [id.uuidString, token, computedAt])
            } else {
                try db.execute(sql: "DELETE FROM audit_cache WHERE item_id = ?", arguments: [id.uuidString])
            }
        }
    }

    /// Set an item's `type` (cleartext metadata; no key needed). Used to reclassify imported secure
    /// notes (host `sn`) as non-login so they leave the audit + autofill paths.
    public func setType(_ type: String, forItemID id: UUID) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "UPDATE items SET type = ? WHERE id = ?", arguments: [type, id.uuidString])
        }
    }

    /// Drop every reuse token (without touching `health_flags`). Used when the persisted audit-key
    /// self-check no longer matches — the cache is rebuilt from scratch under the live key.
    public func clearAuditTokens() async throws {
        try await dbQueue.write { db in try db.execute(sql: "DELETE FROM audit_cache") }
    }

    /// The audit bookkeeping row: the audit-key self-check and the last full-recompute time, or `nil`
    /// before the first Security Check. The store rejects tokens whose key-check doesn't match the live
    /// `audit_key` (the rotation invariant, vault-spec §6).
    public func loadAuditMeta() async throws -> (keyCheck: Data, checkedAt: Date)? {
        try await dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT key_check, checked_at FROM audit_meta WHERE id = 1")
            else { return nil }
            let keyCheck: Data = row["key_check"]
            let checkedAt: Date = row["checked_at"]
            return (keyCheck, checkedAt)
        }
    }

    public func saveAuditMeta(keyCheck: Data, checkedAt: Date) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO audit_meta (id, key_check, checked_at) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET key_check = excluded.key_check, checked_at = excluded.checked_at
                """, arguments: [keyCheck, checkedAt])
        }
    }

    // MARK: - Row assembly (static — never captures `self` into a GRDB closure)

    private static func assemble(_ row: ItemRow, _ db: Database) throws -> StoredItem {
        guard let uuid = UUID(uuidString: row.id) else {
            throw VaultStoreError.malformedRow("items.id is not a UUID: \(row.id)")
        }
        let hostRows = try HostRow
            .filter(Column("item_id") == row.id)
            .order(sql: "is_primary DESC, host ASC")
            .fetchAll(db)
        return StoredItem(
            id: uuid,
            type: row.type,
            title: row.title,
            createdAt: row.createdAt,
            modifiedAt: row.modifiedAt,
            sealed: SealedItem(wrappedItemKey: row.wrappedItemKey, ciphertext: row.ciphertext),
            hosts: hostRows.map { Host(host: $0.host, isPrimary: $0.isPrimary) },
            healthFlags: row.healthFlags
        )
    }

    private static func encodeParams(_ params: KDFParams) throws -> String {
        let data = try JSONEncoder().encode(params)
        guard let json = String(data: data, encoding: .utf8) else {
            throw VaultStoreError.malformedRow("could not encode KDFParams as UTF-8 JSON")
        }
        return json
    }

    private static func decodeParams(_ json: String) throws -> KDFParams {
        guard let data = json.data(using: .utf8) else {
            throw VaultStoreError.malformedRow("kdf_params is not UTF-8: \(json)")
        }
        return try JSONDecoder().decode(KDFParams.self, from: data)
    }

    // MARK: - Migrations

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_vault") { db in
            try db.create(table: "vault_meta") { t in
                t.primaryKey("id", .integer)
                t.check(sql: "id = 1")                              // enforce a single vault per store
                t.column("schema_version", .integer).notNull()     // VaultMeta envelope/payload version
                t.column("kdf_salt_master", .blob).notNull()
                t.column("kdf_params_master", .text).notNull()     // JSON
                t.column("wrapped_vault_key_master", .blob).notNull()
                t.column("kdf_salt_recovery", .blob).notNull()
                t.column("kdf_params_recovery", .text).notNull()   // JSON
                t.column("wrapped_vault_key_recovery", .blob).notNull()
            }
            try db.create(table: "items") { t in
                t.primaryKey("id", .text)                          // UUID string
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()                 // cleartext metadata
                t.column("created_at", .datetime).notNull()
                t.column("modified_at", .datetime).notNull()
                t.column("wrapped_item_key", .blob).notNull()      // GCM .combined
                t.column("ciphertext", .blob).notNull()            // GCM .combined (nonce inline)
                t.column("health_flags", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "items_on_modified_at", on: "items", columns: ["modified_at"])
            try db.create(table: "item_hosts") { t in
                t.column("item_id", .text).notNull()
                    .references("items", onDelete: .cascade)
                t.column("host", .text).notNull()                  // cleartext metadata
                t.column("is_primary", .boolean).notNull().defaults(to: false)
                t.primaryKey(["item_id", "host"])
            }
            try db.create(index: "item_hosts_on_host", on: "item_hosts", columns: ["host"])
            try db.create(table: "audit_cache") { t in             // defined now; populated in Slice 9
                t.column("item_id", .text).notNull()
                    .references("items", onDelete: .cascade)
                t.column("signal", .text).notNull()                // weak · reused · 2fa_available
                t.column("computed_at", .datetime).notNull()
                t.primaryKey(["item_id", "signal"])
            }
        }
        // Slice 9 — keyed audit cache. The original `audit_cache` (item_id, signal) was never
        // populated; reshape it to `item_id → reuse_token` (one keyed HMAC token per item, equality
        // only). `audit_meta` carries the audit-key self-check (rotation invariant) + last-check time.
        migrator.registerMigration("v2_audit_keyed") { db in
            try db.drop(table: "audit_cache")
            try db.create(table: "audit_cache") { t in
                t.column("item_id", .text).notNull()
                    .references("items", onDelete: .cascade)
                t.column("reuse_token", .blob).notNull()           // HMAC-SHA256(audit_key, password)
                t.column("computed_at", .datetime).notNull()
                t.primaryKey(["item_id"])                          // one token per item
            }
            try db.create(table: "audit_meta") { t in
                t.primaryKey("id", .integer)
                t.check(sql: "id = 1")                             // singleton
                t.column("key_check", .blob).notNull()             // HMAC(audit_key, fixed sentinel)
                t.column("checked_at", .datetime).notNull()
            }
        }
        return migrator
    }

    // MARK: - Review hooks (DEBUG only)

    #if DEBUG
    /// Human-readable dump of the persisted `vault_meta` columns — for eyeballing that nothing but
    /// salts, params, wrapped blobs, and the version reaches disk. Shows hex + byte lengths.
    public func dumpMetaColumnsForReview() async throws -> String {
        guard let row = try await dbQueue.read({ db in try MetaRow.fetchOne(db, key: MetaRow.singletonID) }) else {
            return "<no vault_meta row>"
        }
        func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
        return """
        vault_meta (singleton id=\(row.id))
          schema_version             : \(row.schemaVersion)
          kdf_salt_master            : \(hex(row.kdfSaltMaster))  (\(row.kdfSaltMaster.count) bytes)
          kdf_params_master          : \(row.kdfParamsMaster)
          wrapped_vault_key_master   : \(hex(row.wrappedVaultKeyMaster))  (\(row.wrappedVaultKeyMaster.count) bytes)
          kdf_salt_recovery          : \(hex(row.kdfSaltRecovery))  (\(row.kdfSaltRecovery.count) bytes)
          kdf_params_recovery        : \(row.kdfParamsRecovery)
          wrapped_vault_key_recovery : \(hex(row.wrappedVaultKeyRecovery))  (\(row.wrappedVaultKeyRecovery.count) bytes)
        """
    }

    /// Force a WAL checkpoint so all committed bytes land in the main db file (then the -wal scan is
    /// over a flushed log). Used by the no-plaintext-on-disk test.
    public func walCheckpointForReview() async throws {
        try await dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// The main db file plus every sidecar (`-wal`, `-shm`, `-journal`) that may exist, so a
    /// no-plaintext scan covers the write-ahead log, not just the main file.
    public var databaseFileURLsForReview: [URL] {
        let base = dbURL.path
        return [dbURL,
                URL(fileURLWithPath: base + "-wal"),
                URL(fileURLWithPath: base + "-shm"),
                URL(fileURLWithPath: base + "-journal")]
    }
    #endif
}

// MARK: - GRDB record types (internal; keep GRDB out of the public crypto types)

private struct MetaRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "vault_meta"
    static let singletonID: Int64 = 1

    var id: Int64
    var schemaVersion: Int
    var kdfSaltMaster: Data
    var kdfParamsMaster: String
    var wrappedVaultKeyMaster: Data
    var kdfSaltRecovery: Data
    var kdfParamsRecovery: String
    var wrappedVaultKeyRecovery: Data

    enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion = "schema_version"
        case kdfSaltMaster = "kdf_salt_master"
        case kdfParamsMaster = "kdf_params_master"
        case wrappedVaultKeyMaster = "wrapped_vault_key_master"
        case kdfSaltRecovery = "kdf_salt_recovery"
        case kdfParamsRecovery = "kdf_params_recovery"
        case wrappedVaultKeyRecovery = "wrapped_vault_key_recovery"
    }
}

private struct ItemRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "items"

    var id: String
    var type: String
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var wrappedItemKey: Data
    var ciphertext: Data
    var healthFlags: Int

    enum CodingKeys: String, CodingKey {
        case id, type, title, ciphertext
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case wrappedItemKey = "wrapped_item_key"
        case healthFlags = "health_flags"
    }

    init(_ item: StoredItem) {
        id = item.id.uuidString
        type = item.type
        title = item.title
        createdAt = item.createdAt
        modifiedAt = item.modifiedAt
        wrappedItemKey = item.sealed.wrappedItemKey
        ciphertext = item.sealed.ciphertext
        healthFlags = item.healthFlags
    }
}

private struct HostRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "item_hosts"

    var itemId: String
    var host: String
    var isPrimary: Bool

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case host
        case isPrimary = "is_primary"
    }
}
