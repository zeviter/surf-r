import Foundation
import GRDB

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
