import Foundation
import WebKit

/// HTTPS-only mode (Stage-1 privacy). Main-frame `http://` navigations are upgraded
/// to `https://` in the navigation delegate. If the secure load fails, the delegate
/// shows an interstitial offering an explicit per-site "continue insecurely" — we
/// never silently fall back to http.
///
/// This object is also the `WKScriptMessageHandler` the interstitial's button posts
/// to: it records the per-site bypass and loads the original http URL.
@MainActor
final class HTTPSUpgrader: NSObject, WKScriptMessageHandler {
    static let shared = HTTPSUpgrader()
    static let messageName = "surfrProceedInsecure"

    /// Hosts the user explicitly chose to load over http (per-site, this session).
    private var allowedInsecureHosts: Set<String> = []

    private override init() { super.init() }

    /// Should this URL be upgraded? Only public http hosts that the user hasn't
    /// already allowed; loopback/.local/private IPs are exempt for dev convenience.
    func shouldUpgrade(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else { return false }
        if Self.isExempt(host: host) { return false }
        if allowedInsecureHosts.contains(host) { return false }
        return true
    }

    /// Same URL with the scheme switched to https.
    static func secureURL(_ url: URL) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.scheme = "https"
        return comps?.url ?? url
    }

    /// Loopback / link-local / private / mDNS hosts skipped for dev convenience.
    static func isExempt(host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.hasSuffix(".local") { return true }                 // mDNS / Bonjour
        if host == "127.0.0.1" || host == "::1" || host == "[::1]" { return true }
        if host.hasPrefix("127.") { return true }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") { return true }
        if host.hasPrefix("172.") {                                  // 172.16.0.0 – 172.31.255.255
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) { return true }
        }
        return false
    }

    // MARK: - Interstitial "continue" button → message handler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              let string = message.body as? String,
              let url = URL(string: string), url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              let webView = message.webView else { return }
        allowedInsecureHosts.insert(host)   // per-site bypass for the rest of the session
        #if DEBUG
        print("[HTTPS] user chose to continue insecurely to \(host)")
        #endif
        webView.load(URLRequest(url: url))
    }

    // MARK: - Interstitial page

    /// A plain warning page shown when the HTTPS upgrade fails. The button posts the
    /// original http URL back through the message handler (no silent fallback).
    static func interstitialHTML(httpURL: URL) -> String {
        let display = httpURL.host ?? httpURL.absoluteString
        let jsURL = httpURL.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let shownURL = display
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          body { font: -apple-system-body, system-ui; margin: 0; height: 100vh;
                 display: flex; align-items: center; justify-content: center;
                 background: Canvas; color: CanvasText; }
          .card { max-width: 30rem; padding: 2rem; text-align: center; }
          h1 { font-size: 1.4rem; margin: 0 0 .5rem; }
          p { color: color-mix(in srgb, CanvasText 65%, transparent); line-height: 1.5; }
          .host { font-weight: 600; color: CanvasText; }
          button { margin-top: 1.5rem; font: inherit; font-size: .95rem; padding: .5rem 1rem;
                   border-radius: .5rem; border: 1px solid color-mix(in srgb, CanvasText 25%, transparent);
                   background: transparent; color: CanvasText; cursor: pointer; }
          .lock { font-size: 2.5rem; }
        </style></head>
        <body><div class="card">
          <div class="lock">🔒</div>
          <h1>This site doesn't support a secure connection</h1>
          <p><span class="host">\(shownURL)</span> couldn't be loaded over HTTPS.
             surf-r upgrades sites to HTTPS and won't connect insecurely on its own.</p>
          <button onclick="window.webkit.messageHandlers.\(messageName).postMessage('\(jsURL)')">
            Continue to the insecure site
          </button>
        </div></body></html>
        """
    }
}
