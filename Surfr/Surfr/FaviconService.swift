import Foundation

/// Resolves and caches site favicons — slice 3 of the rail/spotlight/bookmarks/
/// history phase. **First-party only**: icons are fetched solely from the site's
/// own host, never from a third-party/aggregator, and cross-host redirects are not
/// followed. WKWebView exposes no favicon API, so we resolve manually.
///
/// Pure data/service layer: **no AppKit/SwiftUI/WebKit imports** (SurfrCore-ready).
/// It deals in `Data`; it does not render images. Raster format detection is by
/// magic bytes; SVG is rejected (AppKit can't render it) so the UI shows a letter
/// tile. The declared-icon read (`<link rel>` via `evaluateJavaScript`) lives in
/// the app layer and feeds `ingestDeclaredIcons`.
///
/// Privacy: any logging of fetched icon hosts/URLs is DEBUG-only.
final class FaviconService: @unchecked Sendable {
    static let shared = FaviconService()

    /// Re-fetch a host's icon at most this often. Generous on purpose.
    static let refreshTTL: TimeInterval = 30 * 24 * 60 * 60   // 30 days

    private let lock = NSLock()
    private var memory: [String: Data] = [:]                 // sanitised host -> raster bytes
    private var inFlight: [String: Task<Data?, Never>] = [:] // coalesced resolves per host
    private var negativeHosts: Set<String> = []              // hosts known to have no usable icon
    #if DEBUG
    private var _fetchAttempts = 0                           // for the self-test dedup check
    #endif

    private let redirectBlocker = SameHostRedirectBlocker()
    private let session: URLSession
    private let cacheDir: URL?

    private init() {
        let config = URLSessionConfiguration.ephemeral       // no cookies/disk cache
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config, delegate: redirectBlocker, delegateQueue: nil)
        cacheDir = Self.makeCacheDir()
    }

    // MARK: - Public API

    /// Instant, synchronous in-memory lookup (no I/O). `nil` → UI shows a letter tile.
    func cachedFaviconData(forHost host: String) -> Data? {
        let key = Self.sanitize(host)
        lock.lock(); defer { lock.unlock() }
        return memory[key]
    }

    /// Return the host's icon — memory, then disk (within TTL), then a fetch of
    /// `https://<host>/favicon.ico`. Concurrent calls for the same host coalesce.
    func favicon(forHost host: String) async -> Data? {
        let key = Self.sanitize(host)
        if let data = cachedFaviconData(forHost: host) { return data }
        if let data = loadDiskIfFresh(key) { setMemory(key, data); return data }
        if isNegative(key) { return nil }
        return await coalescedResolve(host: host, key: key, declared: [])
    }

    /// Fire-and-forget warm of a host's icon (e.g. for a bookmarked host).
    func prefetch(host: String) {
        Task { _ = await favicon(forHost: host) }
    }

    /// Ingest first-party declared icons read from a live page (on `didFinish`).
    /// Tries same-host candidates in order, then falls back to `/favicon.ico`.
    func ingestDeclaredIcons(host: String, candidateURLs: [URL]) async {
        let key = Self.sanitize(host)
        if cachedFaviconData(forHost: host) != nil { return }
        if let data = loadDiskIfFresh(key) { setMemory(key, data); return }
        _ = await coalescedResolve(host: host, key: key, declared: candidateURLs)
    }

    /// Stable per-host seed for the UI's letter-tile colour (deterministic across
    /// launches — not Swift's randomised hash).
    func colorSeed(forHost host: String) -> Int {
        var hash: UInt64 = 5381
        for byte in host.lowercased().utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Int(hash & 0x7FFF_FFFF)
    }

    // MARK: - Resolution

    private func coalescedResolve(host: String, key: String, declared: [URL]) async -> Data? {
        lock.lock()
        if let existing = inFlight[key] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<Data?, Never> { await self.performResolve(host: host, key: key, declared: declared) }
        inFlight[key] = task
        lock.unlock()

        let result = await task.value
        lock.lock(); inFlight.removeValue(forKey: key); lock.unlock()
        return result
    }

    private func performResolve(host: String, key: String, declared: [URL]) async -> Data? {
        // 1. Declared icons, same-host only, in preference order.
        for url in declared where url.host?.lowercased() == host.lowercased() {
            if let data = await fetchUsableRaster(from: url) {
                store(key: key, data: data, host: host, source: "declared")
                return data
            }
        }
        // 2. Fallback: the site's own /favicon.ico.
        if let favURL = URL(string: "https://\(host)/favicon.ico"),
           let data = await fetchUsableRaster(from: favURL) {
            store(key: key, data: data, host: host, source: "favicon.ico")
            return data
        }
        // 3. Nothing usable.
        lock.lock(); negativeHosts.insert(key); lock.unlock()
        #if DEBUG
        print("[Favicon] cached \(host) (0 bytes, source: none)")
        #endif
        return nil
    }

    /// Fetch and return the bytes only if they're a usable raster from the same
    /// host (no cross-host result, no SVG/text).
    private func fetchUsableRaster(from url: URL) async -> Data? {
        #if DEBUG
        lock.lock(); _fetchAttempts += 1; lock.unlock()
        #endif
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            // Defence-in-depth: reject if the final URL drifted to another host.
            if let finalHost = response.url?.host?.lowercased(),
               let wantHost = url.host?.lowercased(), finalHost != wantHost { return nil }
            guard Self.isUsableRaster(data) else { return nil }
            return data
        } catch {
            return nil
        }
    }

    // MARK: - Caches

    private func setMemory(_ key: String, _ data: Data) {
        lock.lock(); memory[key] = data; lock.unlock()
    }

    private func isNegative(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return negativeHosts.contains(key)
    }

    private func store(key: String, data: Data, host: String, source: String) {
        setMemory(key, data)
        if let dir = cacheDir {
            try? data.write(to: dir.appendingPathComponent(key))
        }
        #if DEBUG
        print("[Favicon] cached \(host) (\(data.count) bytes, source: \(source))")
        #endif
    }

    private func loadDiskIfFresh(_ key: String) -> Data? {
        guard let dir = cacheDir else { return nil }
        let file = dir.appendingPathComponent(key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < Self.refreshTTL,
              let data = try? Data(contentsOf: file),
              Self.isUsableRaster(data) else { return nil }
        return data
    }

    // MARK: - Helpers

    /// Detect a usable raster image by magic bytes. Rejects SVG/text/HTML.
    private static func isUsableRaster(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let b = [UInt8](data.prefix(16))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }   // PNG
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return true }         // JPEG
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }   // GIF
        if b.starts(with: [0x42, 0x4D]) { return true }               // BMP
        if b.starts(with: [0x00, 0x00, 0x01, 0x00]) { return true }   // ICO
        if b.starts(with: [0x00, 0x00, 0x02, 0x00]) { return true }   // CUR
        if b.count >= 12, b.starts(with: [0x52, 0x49, 0x46, 0x46]),   // WEBP (RIFF....WEBP)
           Array(b[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return true }
        return false   // SVG ("<?xml"/"<svg"), HTML error pages, etc.
    }

    private static func sanitize(_ host: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        let cleaned = String(host.lowercased().map { allowed.contains($0) ? $0 : "_" })
        return cleaned.isEmpty ? "_" : cleaned
    }

    private static func makeCacheDir() -> URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Surfr/Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Self-test (DEBUG only)

    #if DEBUG
    func fetchAttempts() -> Int { lock.lock(); defer { lock.unlock() }; return _fetchAttempts }

    func debugSeed(host: String, data: Data) {
        let key = Self.sanitize(host)
        setMemory(key, data)
        if let dir = cacheDir { try? data.write(to: dir.appendingPathComponent(key)) }
    }

    func debugClear(host: String) {
        let key = Self.sanitize(host)
        lock.lock(); memory[key] = nil; negativeHosts.remove(key); lock.unlock()
        if let dir = cacheDir { try? FileManager.default.removeItem(at: dir.appendingPathComponent(key)) }
    }

    /// Exercises cache logic deterministically/offline (seed → sync hit → concurrent
    /// dedup → nil for a missing host), plus one network-dependent live fetch.
    func runSelfTest() async {
        func step(_ s: String) { print("[Favicon][selftest] \(s)") }
        step("starting")

        // 1. Synthetic bytes → instant sync hit.
        let host = "surfr-fav-selftest.invalid"
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0, count: 24)
        debugSeed(host: host, data: png)
        let hit = cachedFaviconData(forHost: host)
        step("seed/cachedFaviconData: \(hit?.count ?? -1) bytes (expected \(png.count)) — \(hit == png ? "PASS" : "FAIL")")

        // 2. colorSeed is stable.
        let c1 = colorSeed(forHost: host), c2 = colorSeed(forHost: host)
        step("colorSeed stable: \(c1) == \(c2) — \(c1 == c2 ? "PASS" : "FAIL")")

        // 3. Concurrent dedup for an unknown host → exactly one underlying fetch.
        let missing = "surfr-fav-missing.invalid"
        let before = fetchAttempts()
        async let r1 = favicon(forHost: missing)
        async let r2 = favicon(forHost: missing)
        async let r3 = favicon(forHost: missing)
        let trio = await [r1, r2, r3]
        let attempts = fetchAttempts() - before
        step("dedup: \(attempts) fetch attempt(s) for 3 concurrent calls (expected 1) — \(attempts == 1 ? "PASS" : "FAIL")")
        step("missing host → nil: \(trio.allSatisfy { $0 == nil }) — \(trio.allSatisfy { $0 == nil } ? "PASS" : "FAIL")")

        // 4. One live, network-dependent fetch of a well-known host.
        let liveHost = "github.com"
        let live = await favicon(forHost: liveHost)
        step("live fetch \(liveHost): \(live?.count ?? 0) bytes — \(live != nil ? "PASS (network)" : "SKIP (offline / cross-host redirect)")")

        // Clean up only the test entries.
        debugClear(host: host)
        debugClear(host: missing)
        debugClear(host: liveHost)
        step("done")
    }
    #endif
}

/// Blocks cross-host redirects when fetching an icon, so a site can't bounce the
/// favicon request to a third party (privacy). Same-host redirects are followed.
private final class SameHostRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url?.host?.lowercased()
        let next = request.url?.host?.lowercased()
        completionHandler(original != nil && original == next ? request : nil)
    }
}
