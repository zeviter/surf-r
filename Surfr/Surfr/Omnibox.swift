import Foundation

/// Parses omnibox input into something to load: either the URL the user typed,
/// or a DuckDuckGo search for it. Privacy-first: search defaults to DuckDuckGo.
///
/// Lives in the app target for now; moves to `SurfrCore` in Phase 5.
enum Omnibox {
    /// Resolve raw address-bar text to a loadable URL.
    /// Returns `nil` only for empty input.
    static func resolve(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 1. Explicit web scheme → trust it as typed.
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" || scheme == "file" {
            return url
        }

        // 2. Looks like a bare host/domain → load over https.
        if looksLikeURL(text),
           let url = URL(string: "https://\(text)") {
            return url
        }

        // 3. Otherwise → DuckDuckGo search.
        return searchURL(for: text)
    }

    /// Build a DuckDuckGo query URL for arbitrary text.
    static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }

    /// Heuristic: does this read as a hostname/URL rather than a search phrase?
    private static func looksLikeURL(_ text: String) -> Bool {
        // Searches usually contain spaces; hosts never do.
        guard !text.contains(" ") else { return false }

        // localhost (optionally with port/path) is a host.
        if text == "localhost" || text.hasPrefix("localhost:") || text.hasPrefix("localhost/") {
            return true
        }

        // Take the host portion (before any path) and require a dotted name
        // with non-empty labels, e.g. "example.com", "sub.example.com/path".
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
    }
}
