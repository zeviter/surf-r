import WebKit

/// Phase 2a: compiles the bundled seed ad-blocking list and applies it to every
/// tab's web view. The seed is EasyList, pre-converted to WebKit content-blocker
/// JSON (see `Resources/easylist-seed.json`). One list, no chunking.
///
/// Runtime fetch/updates, the last-good fallback, EasyPrivacy, cosmetic filtering,
/// and chunking arrive in Phase 2b.
@MainActor
final class ContentBlocker {
    static let shared = ContentBlocker()

    /// The compiled list, once ready. Backfilled onto registered web views.
    private(set) var ruleList: WKContentRuleList?

    private let identifier = "easylist-seed"
    private var prepared = false
    /// Web views to (re)apply the list to once compilation finishes.
    private let registered = NSHashTable<WKWebView>.weakObjects()

    private init() {}

    /// Compile the bundled seed list once and apply it to any web view already
    /// registered. Safe to call repeatedly; only the first call does work.
    func prepare() async {
        guard !prepared else { return }
        prepared = true

        guard let url = Bundle.main.url(forResource: identifier, withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("Seed content-blocker list missing from bundle")
            prepared = false
            return
        }

        do {
            guard let compiled = try await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
                NSLog("ContentBlocker: compiler returned no rule list")
                prepared = false
                return
            }
            ruleList = compiled
            for webView in registered.allObjects {
                webView.configuration.userContentController.add(compiled)
            }
        } catch {
            // Phase 2b adds fetch + last-good fallback; for 2a a failure simply
            // means no blocking this run. Allow a later retry.
            NSLog("ContentBlocker: failed to compile seed list: \(error)")
            prepared = false
        }
    }

    /// Apply the rule list to a web view now (if ready) and register it so it gets
    /// the list once compilation finishes. Call for every tab, new ones included.
    func apply(to webView: WKWebView) {
        registered.add(webView)
        if let ruleList {
            webView.configuration.userContentController.add(ruleList)
        }
    }
}
