import Foundation
import GRDB

/// One bookmark row. One row per URL; re-adding the same URL upserts (see `add`).
/// `host` is stored bare so a favicon can be resolved later (no favicon work here).
struct Bookmark: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable {
    var id: Int64?
    var url: String
    var title: String
    var host: String
    var dateAdded: Date

    static let databaseTableName = "bookmark"

    enum Columns {
        static let url = Column("url")
        static let title = Column("title")
        static let host = Column("host")
        static let dateAdded = Column("dateAdded")
    }
}

/// Local-first, persistent bookmarks — slice 2 of the rail/spotlight/bookmarks/
/// history phase. Pure data layer: **no AppKit/SwiftUI/WebKit imports**, so it can
/// move into `SurfrCore` later (mirrors `HistoryStore`). All DB work runs off the
/// main thread on GRDB's serialized queue.
///
/// Privacy: any logging of bookmarked URLs/titles is DEBUG-only.
final class BookmarkStore {
    static let shared = BookmarkStore()

    private let dbQueue: DatabaseQueue?

    private init() {
        do {
            let queue = try DatabaseQueue(path: Self.databaseURL().path)
            try Self.migrator.migrate(queue)
            dbQueue = queue
        } catch {
            dbQueue = nil
            #if DEBUG
            print("[Bookmark] failed to open database: \(error)")
            #endif
        }
    }

    // MARK: - Public API

    /// Add a bookmark. Upserts on URL (no duplicate URLs): a re-add keeps the
    /// original `dateAdded` and refreshes `title`/`host`.
    func add(url: URL, title: String?) async {
        guard let dbQueue else { return }
        let absolute = url.absoluteString
        let host = url.host ?? ""
        let resolvedTitle = (title?.isEmpty == false) ? title! : host
        let now = Date()
        do {
            try await dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO bookmark (url, title, host, dateAdded)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(url) DO UPDATE SET
                        title = excluded.title,
                        host = excluded.host
                    """, arguments: [absolute, resolvedTitle, host, now])
            }
            #if DEBUG
            print("[Bookmark] added \(absolute)")
            #endif
        } catch {
            #if DEBUG
            print("[Bookmark] add failed: \(error)")
            #endif
        }
    }

    /// Remove a bookmark by row id.
    func remove(id: Int64) async {
        guard let dbQueue else { return }
        _ = try? await dbQueue.write { db in
            #if DEBUG
            let removed = try Bookmark.fetchOne(db, key: id)
            #endif
            try Bookmark.deleteOne(db, key: id)
            #if DEBUG
            if let removed { print("[Bookmark] removed \(removed.url)") }
            #endif
        }
    }

    /// Remove a bookmark by URL (used by the toggle action).
    func removeByURL(_ url: URL) async {
        guard let dbQueue else { return }
        let absolute = url.absoluteString
        _ = try? await dbQueue.write { db in
            try Bookmark.filter(Bookmark.Columns.url == absolute).deleteAll(db)
        }
        #if DEBUG
        print("[Bookmark] removed \(absolute)")
        #endif
    }

    /// Is this URL bookmarked?
    func isBookmarked(url: URL) async -> Bool {
        let absolute = url.absoluteString
        return await read(default: false) { db in
            try Bookmark.filter(Bookmark.Columns.url == absolute).fetchCount(db) > 0
        }
    }

    /// All bookmarks, most recently added first.
    func all() async -> [Bookmark] {
        await read(default: []) { db in
            try Bookmark.order(Bookmark.Columns.dateAdded.desc).fetchAll(db)
        }
    }

    /// Substring match over title + URL, most recently added first.
    func search(query: String) async -> [Bookmark] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%\(Self.escapeLike(trimmed))%"
        return await read(default: []) { db in
            try Bookmark
                .filter(sql: "(title LIKE ? ESCAPE '\\' OR url LIKE ? ESCAPE '\\')",
                        arguments: [pattern, pattern])
                .order(Bookmark.Columns.dateAdded.desc)
                .fetchAll(db)
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
            print("[Bookmark] read failed: \(error)")
            #endif
            return defaultValue
        }
    }

    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// `Application Support/Surfr/bookmarks.sqlite` (sandbox container) — same
    /// `Surfr` directory the history DB and blocklist cache live under.
    private static func databaseURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Surfr", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bookmarks.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_bookmark") { db in
            try db.create(table: "bookmark") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()   // upsert key
                t.column("title", .text).notNull()
                t.column("host", .text).notNull()
                t.column("dateAdded", .datetime).notNull()
            }
        }
        return migrator
    }

    // MARK: - Self-test (DEBUG only)

    #if DEBUG
    /// Exercises add → isBookmarked → all → search → remove on temporary
    /// `*.invalid` test data, logging each step's PASS/FAIL, then deletes only its
    /// own rows.
    func runSelfTest() async {
        func step(_ s: String) { print("[Bookmark][selftest] \(s)") }
        step("starting")

        let tag = "surfr-bm-selftest"
        let host = "\(tag).invalid"
        let u1 = URL(string: "https://\(host)/one")!
        let u2 = URL(string: "https://\(host)/two")!

        await add(url: u1, title: "One")
        await add(url: u2, title: "Two")
        await add(url: u1, title: "One v2")   // upsert: must not duplicate

        let bm1 = await isBookmarked(url: u1)
        step("add/isBookmarked: u1 bookmarked = \(bm1) (expected true) — \(bm1 ? "PASS" : "FAIL")")

        let mine = (await all()).filter { $0.host == host }
        step("all(): \(mine.count) test bookmarks (expected 2, upsert no dup) — \(mine.count == 2 ? "PASS" : "FAIL")")

        let titleHits = await search(query: "Two")
        let titleOK = titleHits.contains { $0.url == u2.absoluteString }
        step("search(title): found u2 = \(titleOK) — \(titleOK ? "PASS" : "FAIL")")

        if let id = mine.first(where: { $0.url == u2.absoluteString })?.id {
            await remove(id: id)
        }
        let stillU2 = await isBookmarked(url: u2)
        step("remove(id:): u2 bookmarked = \(stillU2) (expected false) — \(stillU2 ? "FAIL" : "PASS")")

        await removeByURL(u1)
        let remaining = (await all()).filter { $0.host == host }.count
        step("cleanup: \(remaining) test bookmarks remain (expected 0) — \(remaining == 0 ? "PASS" : "FAIL")")
        step("done")
    }
    #endif
}
