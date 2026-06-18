import WebKit
import Foundation
import ContentBlockerConverter

/// Phase 2b: keeps a set of ad/tracker-blocking content-rule lists applied to
/// every tab. Currently EasyList (ads + basic cosmetic element-hiding) and
/// EasyPrivacy (trackers). Each list is fetched from its canonical URL and
/// converted on-device with AdGuard's SafariConverterLib (a local, no-network
/// converter), then compiled into its **own** `WKContentRuleList` and applied
/// alongside the others — they are never merged.
///
/// Each list is fully independent: it fetches, converts, caches, compiles, and
/// falls back to its own last-good (on-disk cache, else the bundled seed) on any
/// failure. One list failing never affects the other, so the user is never left
/// unprotected.
///
/// "Basic cosmetic" here means the converter's standard `css-display-none`
/// element-hiding rules, which are included by default (no advanced blocking).
/// Not in this slice: scriptlets, extended CSS / `:has()`, and document-start
/// `WKUserScript` injection — those are a later slice.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    /// A source filter list.
    private struct Source: Sendable {
        let id: String     // stable key; also `<id>-seed.json` bundle + `<id>.json` cache
        let name: String   // human label for logs
        let url: URL       // canonical remote list
    }

    private let sources: [Source] = [
        Source(id: "easylist", name: "EasyList",
               url: URL(string: "https://easylist.to/easylist/easylist.txt")!),
        Source(id: "easyprivacy", name: "EasyPrivacy",
               url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!),
    ]

    // Per-list state, keyed by Source.id.
    private var compiled: [String: WKContentRuleList] = [:]
    private var appliedLabel: [String: String] = [:]
    private var appliedCount: [String: Int] = [:]

    private var prepared = false
    /// Web views to (re)apply the lists to as they compile / refresh.
    private let registered = NSHashTable<WKWebView>.weakObjects()

    private let cacheMaxAge: TimeInterval = 24 * 60 * 60   // ~24h

    private init() {}

    // MARK: - Lifecycle

    /// Prepare every list. Each list independently applies its best last-good
    /// immediately, then refreshes if stale. Lists run concurrently. Safe to call
    /// repeatedly; only the first call does work.
    func prepare() async {
        guard !prepared else { return }
        prepared = true

        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { await self.prepareList(source) }
            }
        }
    }

    private func prepareList(_ s: Source) async {
        // 1. Protect from the earliest moment using the best on-disk source that
        //    needs no network: a cached conversion if present, else the seed.
        if let cached = loadCache(s) {
            let count = await ruleCount(of: cached.json)
            let ok = await compileAndApply(s, json: cached.json,
                                           label: "cache (version \(cached.version))", count: count)
            if !ok { await applySeed(s) }
        } else {
            await applySeed(s)
        }

        // 2. Refresh from the network when the cache is missing/stale (or when the
        //    debug force-fail toggle is set, so the failure path is reachable even
        //    with a fresh cache). Any failure keeps this list's last-good in place.
        if isCacheStale(s) || forceFetchFailure {
            await refresh(s)
        } else {
            log("\(s.name): cache is fresh (< 24h); skipping fetch")
        }
    }

    private func applySeed(_ s: Source) async {
        let json = seedJSON(s)
        let count = await ruleCount(of: json)
        _ = await compileAndApply(s, json: json, label: "bundled seed", count: count)
    }

    /// Fetch → convert (off main) → compile → apply for one list, persisting only
    /// once it compiles. On any throw, this list's last-good stays applied.
    private func refresh(_ s: Source) async {
        do {
            log("\(s.name): fetching \(s.url.absoluteString)")
            let text = try await fetch(s)
            let version = parseVersion(from: text)
            log("\(s.name): fetched \(text.utf8.count) bytes, version \(version)")

            let lines = text.components(separatedBy: "\n")
            let converted = await convertOffMain(lines: lines)
            guard converted.count > 0 else { throw BlocklistError.emptyConversion }
            log("\(s.name): converted \(converted.count) content-blocker rules")

            let ok = await compileAndApply(s, json: converted.json,
                                           label: "fetched (version \(version))", count: converted.count)
            guard ok else { throw BlocklistError.emptyCompile }

            saveCache(s, json: converted.json, version: version)
            log("\(s.name): refresh complete")
        } catch {
            log("\(s.name): refresh failed (\(reason(error))); keeping last-good: \(appliedLabel[s.id] ?? "none")")
        }
    }

    // MARK: - Web view registration

    /// Register a tab's web view and apply every currently-compiled list (now or
    /// once ready). Call for every tab, newly created ones included.
    func apply(to webView: WKWebView) {
        registered.add(webView)
        install(on: webView)
    }

    // MARK: - Compile & apply

    @discardableResult
    private func compileAndApply(_ s: Source, json: String, label: String, count: Int) async -> Bool {
        do {
            guard let list = try await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: s.id, encodedContentRuleList: json) else {
                log("\(s.name): compile returned no list for \(label)")
                return false
            }
            log("\(s.name): compiled \(label) — \(count) rules")
            compiled[s.id] = list
            appliedLabel[s.id] = label
            appliedCount[s.id] = count
            for webView in registered.allObjects { install(on: webView) }
            logCombinedApplied()
            return true
        } catch {
            log("\(s.name): compile failed for \(label): \(reason(error))")
            return false
        }
    }

    /// Apply all currently-compiled lists to one web view (independent lists, all
    /// added; a block in one cannot be undone by another). Replaces any prior set.
    private func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        for s in sources {
            if let list = compiled[s.id] { controller.add(list) }
        }
    }

    private func logCombinedApplied() {
        let parts = sources.compactMap { s -> String? in
            guard compiled[s.id] != nil else { return nil }
            return "\(s.name):\(appliedCount[s.id] ?? 0)"
        }
        log("applied [\(parts.joined(separator: ", "))] to \(registered.allObjects.count) tab(s)")
    }

    // MARK: - Fetch & convert

    private func fetch(_ s: Source) async throws -> String {
        if forceFetchFailure { throw BlocklistError.forcedFailure }

        var request = URLRequest(url: s.url)
        request.timeoutInterval = 30
        // URLSession performs the request off the main thread.
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BlocklistError.badHTTPStatus(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw BlocklistError.notUTF8 }
        return text
    }

    /// Convert filter-list text to Safari content-blocker JSON on a background
    /// task — conversion is CPU-heavy and must stay off the main thread.
    /// `advancedBlocking: false` keeps standard `css-display-none` cosmetic rules
    /// while excluding scriptlets / extended CSS (a later slice).
    nonisolated private func convertOffMain(lines: [String]) async -> (json: String, count: Int) {
        await Task.detached(priority: .userInitiated) {
            let result = ContentBlockerConverter().convertArray(
                rules: lines,
                safariVersion: SafariVersion.autodetect(),
                advancedBlocking: false,
                maxJsonSizeBytes: nil
            )
            return (result.safariRulesJSON, result.safariRulesCount)
        }.value
    }

    /// Count rule objects in a content-blocker JSON array, off the main thread.
    nonisolated private func ruleCount(of json: String) async -> Int {
        await Task.detached(priority: .utility) {
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))).flatMap { $0 as? [Any] }?.count ?? 0
        }.value
    }

    // MARK: - Cache (Application Support, per list)

    private struct CacheMeta: Codable { let fetchedAt: Date; let version: String }

    private var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Surfr/Blocklist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func cacheJSONURL(_ s: Source) -> URL? { cacheDirectory?.appendingPathComponent("\(s.id).json") }
    private func cacheMetaURL(_ s: Source) -> URL? { cacheDirectory?.appendingPathComponent("\(s.id).meta.json") }

    private func loadCache(_ s: Source) -> (json: String, version: String)? {
        guard let jsonURL = cacheJSONURL(s), let metaURL = cacheMetaURL(s),
              let json = try? String(contentsOf: jsonURL, encoding: .utf8),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: metaData) else { return nil }
        return (json, meta.version)
    }

    private func isCacheStale(_ s: Source) -> Bool {
        guard let metaURL = cacheMetaURL(s), let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: data) else { return true }
        return Date().timeIntervalSince(meta.fetchedAt) > cacheMaxAge
    }

    private func saveCache(_ s: Source, json: String, version: String) {
        guard let jsonURL = cacheJSONURL(s), let metaURL = cacheMetaURL(s) else { return }
        do {
            try json.write(to: jsonURL, atomically: true, encoding: .utf8)
            let meta = try JSONEncoder().encode(CacheMeta(fetchedAt: Date(), version: version))
            try meta.write(to: metaURL)
            log("\(s.name): cached converted list (version \(version))")
        } catch {
            log("\(s.name): failed to write cache: \(reason(error))")
        }
    }

    // MARK: - Seed (bundled fallback, per list)

    private func seedJSON(_ s: Source) -> String {
        guard let url = Bundle.main.url(forResource: "\(s.id)-seed", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Seed content-blocker list missing from bundle: \(s.id)-seed.json")
            return "[]"
        }
        return json
    }

    // MARK: - Helpers

    /// EasyList/EasyPrivacy headers carry `! Version:` / `! Last modified:` near the top.
    private func parseVersion(from text: String) -> String {
        var version: String?
        var modified: String?
        for raw in text.components(separatedBy: "\n").prefix(40) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("! Version:") {
                version = String(line.dropFirst("! Version:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("! Last modified:") {
                modified = String(line.dropFirst("! Last modified:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return version ?? modified ?? "unknown"
    }

    private func reason(_ error: Error) -> String {
        (error as? BlocklistError)?.message ?? error.localizedDescription
    }

    private func log(_ message: String) {
        print("[Blocklist] \(message)")
        fflush(stdout)   // flush immediately so the lifecycle is visible live
    }

    /// Debug-only switch to force the fetch to fail, so the per-list fallback path
    /// can be exercised deterministically. Set the `--force-blocklist-fetch-failure`
    /// launch argument (or `SURFR_FORCE_BLOCKLIST_FAIL=1` env var) in the scheme.
    private var forceFetchFailure: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--force-blocklist-fetch-failure")
            || ProcessInfo.processInfo.environment["SURFR_FORCE_BLOCKLIST_FAIL"] == "1"
        #else
        return false
        #endif
    }
}

private enum BlocklistError: Error {
    case forcedFailure
    case badHTTPStatus(Int)
    case notUTF8
    case emptyConversion
    case emptyCompile

    var message: String {
        switch self {
        case .forcedFailure: return "forced failure (debug toggle)"
        case .badHTTPStatus(let code): return "HTTP status \(code)"
        case .notUTF8: return "response was not UTF-8"
        case .emptyConversion: return "conversion produced no rules"
        case .emptyCompile: return "compiler produced no rule list"
        }
    }
}
