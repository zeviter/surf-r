import Foundation
import GRDB

/// One persisted download row. Keyed by the `DownloadItem`'s UUID (string) so the
/// in-memory manager owns the id and can upsert/delete without a round-trip. `state`
/// is a `DownloadState` raw value; only terminal/transient rows are stored (a live
/// download writes an `inProgress` row at start, then updates it on finish/fail/cancel).
struct DownloadRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: String
    var filename: String
    var sourceURL: String?
    var sourceHost: String?
    var destinationPath: String?
    var totalBytes: Int64
    var receivedBytes: Int64
    var state: String
    var dateAdded: Date
    var dateCompleted: Date?

    static let databaseTableName = "download"
}

/// Local-only, persistent download history. Pure data layer — **no AppKit/SwiftUI/
/// WebKit imports** — so it can move into `SurfrCore` later, mirroring `HistoryStore`
/// and `BookmarkStore`. All DB work runs off the main thread on GRDB's serialized
/// queue. Privacy: any logging of filenames/URLs is DEBUG-only.
final class DownloadStore {
    static let shared = DownloadStore()

    /// Retention window for `prune` (change freely). Default 90 days.
    static let retentionInterval: TimeInterval = 90 * 24 * 60 * 60

    private let dbQueue: DatabaseQueue?

    private init() {
        do {
            let queue = try DatabaseQueue(path: Self.databaseURL().path)
            try Self.migrator.migrate(queue)
            dbQueue = queue
        } catch {
            dbQueue = nil
            #if DEBUG
            print("[Download] failed to open database: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Insert or update a row (keyed by `id`). Called when a download starts (as
    /// `inProgress`) and again on each terminal event with final state/bytes/date.
    func upsert(_ record: DownloadRecord) async {
        guard let dbQueue else { return }
        do {
            try await dbQueue.write { db in try record.upsert(db) }
        } catch {
            #if DEBUG
            print("[Download] upsert failed: \(error)")
            #endif
        }
    }

    /// All persisted downloads, newest activity first (completed/added date).
    func all() async -> [DownloadRecord] {
        await read(default: []) { db in
            try DownloadRecord.fetchAll(db, sql:
                "SELECT * FROM download ORDER BY COALESCE(dateCompleted, dateAdded) DESC")
        }
    }

    /// Remove one row by id (the row's ✕ when not running).
    func delete(id: String) async {
        guard let dbQueue else { return }
        _ = try? await dbQueue.write { db in
            try DownloadRecord.deleteOne(db, key: id)
        }
    }

    /// "Clear all": delete every finished/failed/cancelled/interrupted row, leaving
    /// any genuinely in-progress row (its live download keeps running and re-upserts
    /// on completion).
    func clearFinished() async {
        guard let dbQueue else { return }
        _ = try? await dbQueue.write { db in
            try DownloadRecord
                .filter(sql: "state <> ?", arguments: [DownloadStateRaw.inProgress])
                .deleteAll(db)
        }
    }

    /// Interrupted-on-quit: WKWebView downloads can't resume across termination, so
    /// any row left `inProgress` from a previous run is migrated to `interrupted`.
    /// Run once at launch, before loading.
    func migrateInterruptedOnLaunch() async {
        guard let dbQueue else { return }
        do {
            let changed = try await dbQueue.write { db -> Int in
                try db.execute(sql: """
                    UPDATE download
                    SET state = ?, dateCompleted = COALESCE(dateCompleted, dateAdded)
                    WHERE state = ?
                    """, arguments: [DownloadStateRaw.interrupted, DownloadStateRaw.inProgress])
                return db.changesCount
            }
            #if DEBUG
            if changed > 0 { print("[Download] migrated \(changed) interrupted download(s) from a prior run") }
            #endif
        } catch {
            #if DEBUG
            print("[Download] interrupted-migration failed: \(error)")
            #endif
        }
    }

    /// Drop rows older than `date` (auto-expiry / retention), matching the
    /// `HistoryStore.prune` pattern.
    func prune(olderThan date: Date) async {
        guard let dbQueue else { return }
        do {
            let deleted = try await dbQueue.write { db in
                try DownloadRecord.filter(sql: "dateAdded < ?", arguments: [date]).deleteAll(db)
            }
            #if DEBUG
            print("[Download] pruned \(deleted) download(s) older than retention window")
            #endif
        } catch {
            #if DEBUG
            print("[Download] prune failed: \(error)")
            #endif
        }
    }

    // MARK: - Helpers

    private func read<T: Sendable>(default defaultValue: T,
                                   _ block: @Sendable @escaping (Database) throws -> T) async -> T {
        guard let dbQueue else { return defaultValue }
        do {
            return try await dbQueue.read(block)
        } catch {
            #if DEBUG
            print("[Download] read failed: \(error)")
            #endif
            return defaultValue
        }
    }

    /// `Application Support/Surfr/downloads.sqlite` — same `Surfr` directory the
    /// history/bookmark DBs live under.
    private static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Surfr", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_download") { db in
            try db.create(table: "download") { t in
                t.primaryKey("id", .text)
                t.column("filename", .text).notNull()
                t.column("sourceURL", .text)
                t.column("sourceHost", .text)
                t.column("destinationPath", .text)
                t.column("totalBytes", .integer).notNull()
                t.column("receivedBytes", .integer).notNull()
                t.column("state", .text).notNull()
                t.column("dateAdded", .datetime).notNull()
                t.column("dateCompleted", .datetime)
            }
            try db.create(index: "download_on_dateAdded", on: "download", columns: ["dateAdded"])
        }
        return migrator
    }
}

/// Raw `state` strings shared with `DownloadState` — kept here so the pure data
/// layer doesn't import the UI-side enum but stays in sync with it.
enum DownloadStateRaw {
    static let inProgress = "inProgress"
    static let interrupted = "interrupted"
}
