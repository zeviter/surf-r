import WebKit
import Foundation
import ContentBlockerConverter

/// Phase 2b (slice 1): keeps an ad-blocking content-rule list applied to every
/// tab. At launch it refreshes from the canonical EasyList, converting it
/// on-device with AdGuard's SafariConverterLib (a local, no-network converter).
///
/// The user is never left unprotected: a last-good list is always applied first
/// — the on-disk cache if present, otherwise the bundled 2a seed — and any
/// failure (fetch, convert, or compile) just keeps that last-good list in place.
///
/// Not in this slice (later 2b work): EasyPrivacy, cosmetic filtering, multiple
/// lists, chunking.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    /// The compiled list currently applied. Backfilled onto registered web views.
    private(set) var ruleList: WKContentRuleList?
    /// Human-readable description of what's currently applied (for logging).
    private(set) var appliedSource: String?

    private var prepared = false
    /// Web views to (re)apply the list to as it compiles / refreshes.
    private let registered = NSHashTable<WKWebView>.weakObjects()

    private let easyListURL = URL(string: "https://easylist.to/easylist/easylist.txt")!
    private let seedIdentifier = "easylist-seed"
    private let runtimeIdentifier = "easylist-runtime"
    private let cacheMaxAge: TimeInterval = 24 * 60 * 60   // ~24h

    private init() {}

    // MARK: - Lifecycle

    /// Apply the best last-good list immediately, then refresh from the network if
    /// the cache is stale. Safe to call repeatedly; only the first call does work.
    func prepare() async {
        guard !prepared else { return }
        prepared = true

        // 1. Protect from the earliest moment using the best on-disk source that
        //    needs no network: a cached conversion if present, else the seed.
        if let cached = loadCache() {
            let ok = await compileAndApply(json: cached.json, identifier: runtimeIdentifier,
                                           source: "cache (version \(cached.version))")
            if !ok { await applySeed() }
        } else {
            await applySeed()
        }

        // 2. Refresh from the network when the cache is missing/stale (or when the
        //    debug force-fail toggle is set, so the failure path is reachable even
        //    with a fresh cache). Any failure keeps the last-good list from step 1.
        if isCacheStale() || forceFetchFailure {
            await refresh()
        } else {
            log("cache is fresh (< 24h); skipping fetch")
        }
    }

    private func applySeed() async {
        _ = await compileAndApply(json: seedJSON(), identifier: seedIdentifier, source: "bundled seed")
    }

    /// Fetch → convert (off main) → compile → apply, persisting only once it
    /// compiles. On any throw, the last-good list stays applied.
    private func refresh() async {
        do {
            log("fetching \(easyListURL.absoluteString)")
            let text = try await fetchEasyList()
            let version = parseVersion(from: text)
            log("fetched \(text.utf8.count) bytes, version \(version)")

            let lines = text.components(separatedBy: "\n")
            let converted = await convertOffMain(lines: lines)
            guard converted.count > 0 else { throw BlocklistError.emptyConversion }
            log("converted \(converted.count) content-blocker rules")

            let ok = await compileAndApply(
                json: converted.json,
                identifier: runtimeIdentifier,
                source: "fetched EasyList (\(converted.count) rules, version \(version))"
            )
            guard ok else { throw BlocklistError.emptyCompile }

            saveCache(json: converted.json, version: version)
            log("refresh complete")
        } catch {
            log("refresh failed (\(reason(error))); keeping last-good: \(appliedSource ?? "none")")
        }
    }

    // MARK: - Web view registration

    /// Register a tab's web view and apply the current list (now or once ready).
    /// Call for every tab, newly created ones included.
    func apply(to webView: WKWebView) {
        registered.add(webView)
        if let ruleList { install(ruleList, on: webView) }
    }

    // MARK: - Compile & apply

    @discardableResult
    private func compileAndApply(json: String, identifier: String, source: String) async -> Bool {
        do {
            guard let compiled = try await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
                log("compile returned no list for \(source)")
                return false
            }
            log("compiled \(source)")
            ruleList = compiled
            appliedSource = source
            for webView in registered.allObjects { install(compiled, on: webView) }
            log("applied \(source) to \(registered.allObjects.count) tab(s)")
            return true
        } catch {
            log("compile failed for \(source): \(reason(error))")
            return false
        }
    }

    /// Swap in `list` on a single web view, removing any prior list first.
    private func install(_ list: WKContentRuleList, on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        controller.add(list)
    }

    // MARK: - Fetch & convert

    private func fetchEasyList() async throws -> String {
        if forceFetchFailure { throw BlocklistError.forcedFailure }

        var request = URLRequest(url: easyListURL)
        request.timeoutInterval = 30
        // URLSession performs the request off the main thread.
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw BlocklistError.badHTTPStatus(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw BlocklistError.notUTF8 }
        return text
    }

    /// Convert EasyList text to Safari content-blocker JSON on a background task —
    /// conversion is CPU-heavy and must stay off the main thread.
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

    // MARK: - Cache (Application Support)

    private struct CacheMeta: Codable { let fetchedAt: Date; let version: String }

    private var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Surfr/Blocklist", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var cacheJSONURL: URL? { cacheDirectory?.appendingPathComponent("easylist.json") }
    private var cacheMetaURL: URL? { cacheDirectory?.appendingPathComponent("easylist.meta.json") }

    private func loadCache() -> (json: String, version: String)? {
        guard let jsonURL = cacheJSONURL, let metaURL = cacheMetaURL,
              let json = try? String(contentsOf: jsonURL, encoding: .utf8),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: metaData) else { return nil }
        return (json, meta.version)
    }

    private func isCacheStale() -> Bool {
        guard let metaURL = cacheMetaURL, let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(CacheMeta.self, from: data) else { return true }
        return Date().timeIntervalSince(meta.fetchedAt) > cacheMaxAge
    }

    private func saveCache(json: String, version: String) {
        guard let jsonURL = cacheJSONURL, let metaURL = cacheMetaURL else { return }
        do {
            try json.write(to: jsonURL, atomically: true, encoding: .utf8)
            let meta = try JSONEncoder().encode(CacheMeta(fetchedAt: Date(), version: version))
            try meta.write(to: metaURL)
            log("cached converted list (version \(version))")
        } catch {
            log("failed to write cache: \(reason(error))")
        }
    }

    // MARK: - Seed (bundled 2a fallback)

    private func seedJSON() -> String {
        guard let url = Bundle.main.url(forResource: seedIdentifier, withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Seed content-blocker list missing from bundle")
            return "[]"
        }
        return json
    }

    // MARK: - Helpers

    /// EasyList header carries `! Version:` / `! Last modified:` near the top.
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

    /// Debug-only switch to force the fetch to fail, so the fallback path can be
    /// exercised deterministically. Set the `--force-blocklist-fetch-failure`
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
