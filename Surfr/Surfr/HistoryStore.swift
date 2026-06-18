import Foundation
import GRDB

/// One history row. One row per URL; a revisit upserts (see `recordVisit`).
/// `host` is stored bare so a favicon can be resolved later (no favicon work here).
struct HistoryEntry: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: Int64?
    var url: String
    var title: String
    var host: String
    var lastVisited: Date
    var visitCount: Int

    static let databaseTableName = "history"

    enum Columns {
        static let url = Column("url")
        static let title = Column("title")
        static let host = Column("host")
        static let lastVisited = Column("lastVisited")
        static let visitCount = Column("visitCount")
    }
}

/// Local-only, persistent browsing history — slice 1 of the rail/spotlight/
/// bookmarks/history phase. Pure data layer: **no AppKit/SwiftUI/WebKit imports**,
/// so it can move into `SurfrCore` later. All DB work runs off the main thread on
/// GRDB's serialized queue.
///
/// Privacy: history is local-only and never synced; any logging of visited
/// URLs/titles is DEBUG-only and never emitted in release.
final class HistoryStore {
    static let shared = HistoryStore()

    /// How long visited pages are retained before `prune` expires them.
    /// Generous default — safe to change.
    static let retentionInterval: TimeInterval = 365 * 24 * 60 * 60   // 365 days

    private let dbQueue: DatabaseQueue?

    private init() {
        do {
            let queue = try DatabaseQueue(path: Self.databaseURL().path)
            try Self.migrator.migrate(queue)
            dbQueue = queue
        } catch {
            dbQueue = nil
            #if DEBUG
            print("[History] failed to open database: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Record (or upsert) a visit: first visit inserts with `visitCount = 1`; a
    /// revisit increments `visitCount` and refreshes `lastVisited` + `title`.
    func recordVisit(url: URL, title: String?) async {
        guard let dbQueue else { return }
        let absolute = url.absoluteString
        let host = url.host ?? ""
        let resolvedTitle = (title?.isEmpty == false) ? title! : host
        let now = Date()
        do {
            try await dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO history (url, title, host, lastVisited, visitCount)
                    VALUES (?, ?, ?, ?, 1)
                    ON CONFLICT(url) DO UPDATE SET
                        visitCount = visitCount + 1,
                        lastVisited = excluded.lastVisited,
                        title = excluded.title,
                        host = excluded.host
                    """, arguments: [absolute, resolvedTitle, host, now])
            }
            #if DEBUG
            print("[History] recorded \(absolute)")
            #endif
        } catch {
            #if DEBUG
            print("[History] recordVisit failed: \(error)")
            #endif
        }
    }

    /// Most recent visits first.
    func recent(limit: Int) async -> [HistoryEntry] {
        await read(default: []) { db in
            try HistoryEntry
                .order(HistoryEntry.Columns.lastVisited.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Substring match over title + URL, most recent first.
    func search(query: String, limit: Int) async -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%\(Self.escapeLike(trimmed))%"
        return await read(default: []) { db in
            try HistoryEntry
                .filter(sql: "(title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\')",
                        arguments: [pattern, pattern])
                .order(HistoryEntry.Columns.lastVisited.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Delete a single entry by row id.
    func delete(id: Int64) async {
        guard let dbQueue else { return }
        _ = try? await dbQueue.write { db in
            try HistoryEntry.deleteOne(db, key: id)
        }
    }

    /// Delete all history.
    func clear() async {
        guard let dbQueue else { return }
        _ = try? await dbQueue.write { db in
            try HistoryEntry.deleteAll(db)
        }
    }

    /// Expire entries last visited before `date` (auto-expiry / retention).
    func prune(olderThan date: Date) async {
        guard let dbQueue else { return }
        do {
            let deleted = try await dbQueue.write { db in
                try HistoryEntry
                    .filter(HistoryEntry.Columns.lastVisited < date)
                    .deleteAll(db)
            }
            #if DEBUG
            print("[History] pruned \(deleted) entr\(deleted == 1 ? "y" : "ies") older than retention window")
            #endif
        } catch {
            #if DEBUG
            print("[History] prune failed: \(error)")
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
            print("[History] read failed: \(error)")
            #endif
            return defaultValue
        }
    }

    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// `Application Support/Surfr/history.sqlite` (sandbox container) — same
    /// `Surfr` directory the blocklist cache lives under.
    private static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Surfr", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_history") { db in
            try db.create(table: "history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()   // upsert key
                t.column("title", .text).notNull()
                t.column("host", .text).notNull()
                t.column("lastVisited", .datetime).notNull()
                t.column("visitCount", .integer).notNull()
            }
            try db.create(index: "history_on_lastVisited", on: "history", columns: ["lastVisited"])
        }
        return migrator
    }

    // MARK: - Self-test (DEBUG only)

    #if DEBUG
    /// Exercises the full API on temporary `*.invalid` test data and logs each
    /// step's PASS/FAIL, then deletes only its own rows. Never calls `clear()`,
    /// so it cannot wipe real history.
    func runSelfTest() async {
        func step(_ s: String) { print("[History][selftest] \(s)") }
        step("starting")

        let tag = "surfr-selftest"
        let u1 = URL(string: "https://\(tag).invalid/alpha")!
        let u2 = URL(string: "https://\(tag).invalid/beta")!

        // record + upsert (u1 visited twice)
        await recordVisit(url: u1, title: "Alpha Page")
        await recordVisit(url: u2, title: "Beta Page")
        await recordVisit(url: u1, title: "Alpha Page v2")

        var hits = await search(query: tag, limit: 50)
        step("record/search: \(hits.count) test entries (expected 2) — \(hits.count == 2 ? "PASS" : "FAIL")")

        let alpha = hits.first { $0.url == u1.absoluteString }
        let upsertOK = alpha?.visitCount == 2 && alpha?.title == "Alpha Page v2"
        step("upsert: visitCount=\(alpha?.visitCount ?? -1), title=\"\(alpha?.title ?? "nil")\" "
            + "(expected 2 / \"Alpha Page v2\") — \(upsertOK ? "PASS" : "FAIL")")

        let recentTopTest = (await recent(limit: 50)).first { $0.host == "\(tag).invalid" }
        step("recent: newest test entry = \(recentTopTest?.url ?? "nil") "
            + "(expected \(u1.absoluteString)) — \(recentTopTest?.url == u1.absoluteString ? "PASS" : "FAIL")")

        let betaHits = await search(query: "Beta Page", limit: 50)
        step("search(title): found u2 = \(betaHits.contains { $0.url == u2.absoluteString }) — "
            + "\(betaHits.contains { $0.url == u2.absoluteString } ? "PASS" : "FAIL")")

        if let betaID = hits.first(where: { $0.url == u2.absoluteString })?.id {
            await delete(id: betaID)
        }
        hits = await search(query: tag, limit: 50)
        step("delete: \(hits.count) test entries remain (expected 1) — \(hits.count == 1 ? "PASS" : "FAIL")")

        for entry in hits { if let id = entry.id { await delete(id: id) } }
        let remaining = await search(query: tag, limit: 50).count
        step("cleanup: \(remaining) test entries remain (expected 0) — \(remaining == 0 ? "PASS" : "FAIL")")
        step("done")
    }
    #endif
}
