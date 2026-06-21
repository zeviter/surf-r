import SwiftUI
import WebKit
import Combine
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted by the ⌘L menu command to focus the address bar.
    static let focusOmnibox = Notification.Name("focusOmnibox")
    /// Posted by the ⌘T menu command to open a new tab.
    static let newTab = Notification.Name("newTab")
    /// Posted by the ⌘W menu command to close the active tab.
    static let closeTab = Notification.Name("closeTab")
    /// Posted by the ⌘D menu command to bookmark/unbookmark the active tab's page.
    static let toggleBookmark = Notification.Name("toggleBookmark")
    /// Posted by the trust menu command: toggle persistent-session trust for the
    /// active tab's domain (slice C1).
    static let toggleTrust = Notification.Name("toggleTrust")
    /// Posted by the ⌘[ menu command: navigate the active tab back.
    static let goBack = Notification.Name("goBack")
    /// Posted by the ⌘] menu command: navigate the active tab forward.
    static let goForward = Notification.Name("goForward")
    /// Slice 9a — reload variants on the active tab's web view.
    static let reloadPage = Notification.Name("reloadPage")
    static let reloadHard = Notification.Name("reloadHard")
    static let reloadEmptyCache = Notification.Name("reloadEmptyCache")
    /// Slice 9a — open internal surfaces (switch to existing, no duplicate).
    static let openHistory = Notification.Name("openHistory")
    static let openTrusted = Notification.Name("openTrusted")
    static let openDownloads = Notification.Name("openDownloads")
    /// Slice 9a — shortcuts page is 9b; ⌘/ is registered but stubbed for now.
    static let openShortcuts = Notification.Name("openShortcuts")
    /// Vault (F5, Slice 3): open the password vault — routes to first-run / unlock / surface.
    static let openVault = Notification.Name("openVault")
    /// Vault (F5, debug): erase the vault (SQLite + Keychain) and return to a clean first-run.
    static let resetVault = Notification.Name("resetVault")
}

private let homeURL = URL(string: "https://duckduckgo.com")!

/// One browser tab. Owns a `WKWebView` whose data store depends on trust (slice C1):
/// trusted hosts share the persistent `WKWebsiteDataStore.default()`; untrusted
/// hosts use an isolated per-tab `.nonPersistent()` store. Because a web view's
/// store is fixed at creation, `webView` is swappable — recreated on the correct
/// store when a navigation crosses a trust boundary (see `BrowserState.rebind`).
@MainActor
final class Tab: ObservableObject, Identifiable {
    /// What a tab renders: a normal web view, or an internal SwiftUI "page" (e.g.
    /// the full-page history view) that has no real navigation/host.
    enum Kind: Equatable {
        case web
        case history
        case trustedSites
        case shortcuts
        case downloads
        case vault
    }

    let id = UUID()
    /// Fixed at creation. Internal-page kinds render SwiftUI instead of the web view
    /// and are never grouped in the rail or discarded as pristine.
    let kind: Kind

    /// The tab's live web view. `@Published` so the UI follows a store swap.
    @Published private(set) var webView: WKWebView
    /// Whether `webView` is bound to the shared persistent store (a trusted host).
    private(set) var usesPersistentStore: Bool
    /// True between a provisional navigation starting and it finishing/failing — i.e.
    /// while a redirect chain (e.g. an OAuth login) is in flight. The store decision
    /// is bound at the start of a chain; mid-chain redirects must NOT rebind, so a
    /// single login flow stays in one store (see the navigation delegate).
    var navigationChainInFlight = false
    /// Set to the original `http://` URL while an HTTPS upgrade is in flight; if that
    /// secure load fails the delegate shows the insecure-site interstitial for it.
    var httpsUpgradeOriginal: URL?

    @Published var title: String
    @Published var addressText: String
    @Published var url: URL

    /// True once this tab has begun a navigation to a real http(s) page.
    /// A tab that hasn't navigated and has no typed address text is "pristine".
    @Published var hasNavigated = false
    /// Monotonic activation stamp; higher = more recently active (rail ordering).
    var activationOrder = 0

    private var observations: [NSKeyValueObservation] = []

    /// Sentinel URL for a blank/pristine tab that hasn't navigated anywhere.
    static let blankURL = URL(string: "about:blank")!

    /// Safari UA token appended via `WKWebViewConfiguration.applicationNameForUserAgent`,
    /// so sites don't flag us as an unsupported/embedded browser. WebKit keeps the
    /// Mozilla/AppleWebKit/OS parts system-correct, producing a real Safari UA:
    ///   Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15
    ///   (KHTML, like Gecko) Version/26.0 Safari/605.1.15
    /// The macOS token is frozen at 10_15_7 by Safari itself — expected. Bump the
    /// Version/ number as Safari advances.
    static let safariUserAgentToken = "Version/26.0 Safari/605.1.15"

    /// A blank, pristine tab: ephemeral store, loads nothing, so it stays out of
    /// the rail until it navigates (see `BrowserState` pristine rule).
    convenience init() {
        self.init(url: Self.blankURL, persistent: false, adopting: nil, load: false)
        self.addressText = ""   // pristine: empty omnibox, no typed text
    }

    /// A normal tab: store chosen from the destination host's trust, then loads.
    convenience init(url: URL) {
        self.init(url: url, persistent: TrustStore.shared.isTrusted(url: url), adopting: nil, load: true)
    }

    /// A pop-up tab: adopts the web view WebKit created for an allowed `window.open`
    /// (its store was already chosen on the configuration). WebKit drives the load.
    convenience init(adopting webView: WKWebView, initialURL: URL?, persistent: Bool) {
        self.init(url: initialURL ?? homeURL, persistent: persistent, adopting: webView, load: false)
    }

    /// An internal SwiftUI page (e.g. the history view) opened as its own tab. It
    /// keeps an unused ephemeral web view (so the rest of the app's `tab.webView`
    /// accesses stay valid) but renders its page chrome instead.
    convenience init(page kind: Kind, title: String) {
        self.init(url: Self.blankURL, persistent: false, adopting: nil, load: false, kind: kind)
        self.addressText = ""
        self.title = title
    }

    private init(url: URL, persistent: Bool, adopting: WKWebView?, load: Bool, kind: Kind = .web) {
        self.kind = kind
        self.url = url
        self.addressText = url.absoluteString
        self.title = url.host() ?? "New Tab"
        self.usesPersistentStore = persistent
        self.webView = adopting ?? Tab.makeWebView(persistent: persistent)
        configureCurrentWebView()
        if load, adopting == nil {
            ContentBlocker.shared.loadGated(url, in: webView)   // first paint gated on seed (slice C)
        }
    }

    /// Build a fresh web view on the requested store (persistent ↔ ephemeral),
    /// with the Safari UA and DEBUG inspector preference baked into its config.
    static func makeWebView(persistent: Bool) -> WebContentView {
        let config = WKWebViewConfiguration()
        // Trusted → single shared persistent store (cookies/SSO survive + are
        // shared across trusted tabs). Untrusted → fresh isolated ephemeral store.
        config.websiteDataStore = persistent ? .default() : .nonPersistent()
        config.applicationNameForUserAgent = safariUserAgentToken
        #if DEBUG
        // Restore the right-click "Inspect Element" item; DEBUG-only, set before
        // the web view snapshots its configuration.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        return WebContentView(frame: .zero, configuration: config)
    }

    /// Per-web-view setup, re-runnable after a store swap: inspector, swipe nav,
    /// content blocking (on the web view's `userContentController`, independent of
    /// the data store), and KVO of title/URL. Resetting `observations` invalidates
    /// the old web view's observers.
    private func configureCurrentWebView() {
        let webView = self.webView
        #if DEBUG
        webView.isInspectable = true   // 2d: Safari Web Inspector can attach. DEBUG only.
        #endif
        webView.allowsBackForwardNavigationGestures = true
        ContentBlocker.shared.apply(to: webView)
        // HTTPS-only: the interstitial's "continue insecurely" button posts here.
        webView.configuration.userContentController.add(HTTPSUpgrader.shared, name: HTTPSUpgrader.messageName)

        observations = []
        observations.append(webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let t = webView.title, !t.isEmpty else { return }
                self?.title = t
            }
        })
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                // Only real http(s) pages update the omnibox/URL; about:blank (a
                // pristine tab) and host-less schemes are ignored so the tab stays
                // pristine and the omnibox stays empty.
                guard let u = webView.url, let host = u.host, !host.isEmpty else { return }
                self?.url = u
                self?.addressText = u.absoluteString
            }
        })
    }

    /// Load a parsed URL in this tab. Trust-boundary store selection happens in the
    /// navigation delegate (`decidePolicyFor navigationAction`), not here.
    func navigate(to newURL: URL) {
        url = newURL
        addressText = newURL.absoluteString
        ContentBlocker.shared.loadGated(newURL, in: webView)   // first paint gated on seed (slice C)
    }

    /// Swap this tab's web view onto the requested store, keeping the same `Tab`
    /// identity (rail/activation/bindings on `$url`/`$title` are preserved). The
    /// caller re-attaches delegates and triggers the load.
    func rebindStore(persistent: Bool) {
        usesPersistentStore = persistent
        webView = Tab.makeWebView(persistent: persistent)   // @Published swap → UI rebuilds
        configureCurrentWebView()
    }
}

/// One host's tile in the rail: its favicon, tab count, and the most-recently
/// active tab to switch to when clicked (subdomain-aware — see ui-wireframes §2).
struct HostGroup: Identifiable {
    let host: String
    let tabCount: Int
    let representativeTabID: Tab.ID   // most-recently-active tab in this host
    let isActive: Bool               // contains the active tab
    let isInsecure: Bool             // representative tab is on an http (user-continued) page
    var id: String { host }
}

/// Holds the open tabs and which one is active, and derives the rail's host groups.
@MainActor
final class BrowserState: ObservableObject {
    @Published var tabs: [Tab]
    @Published var activeTabID: Tab.ID {
        didSet {
            bindActiveURL()
            handleActiveChange(previous: oldValue)
        }
    }
    /// Host-grouped tiles for the rail, most-recently-active host first.
    @Published private(set) var hostGroups: [HostGroup] = []
    /// Addition 5: the macOS window title, mirroring the active tab's page title.
    /// New-tab page → "New Tab"; navigated but title-less → "Surfr"; else the title.
    @Published private(set) var windowTitle = "Surfr"

    /// Gates `window.open` pop-ups (F4) and handles JS dialogs for every tab.
    let popupGate = PopupGate()
    /// Records successful page loads into history (slice 1: data layer only).
    let historyRecorder = HistoryRecorder()
    /// Tracks the active tab's URL so the bookmark menu/title reflects its state.
    private var activeURLBinding: AnyCancellable?
    /// Addition 5: tracks the active tab's title so the window title updates live.
    private var activeTitleBinding: AnyCancellable?
    /// Observes the trust set so the window title's "· Trusted: …" suffix updates
    /// live when the active domain is trusted/untrusted.
    private var trustBinding: AnyCancellable?
    /// Per-tab URL subscriptions, so we can react when a pristine tab navigates.
    private var tabURLBindings: [Tab.ID: AnyCancellable] = [:]
    /// Monotonic activation counter; assigned to each tab as it becomes active
    /// (drives the representative tab, NOT the rail's tile order).
    private var activationCounter = 0
    /// Stable creation order for the rail: a host's position is fixed when it first
    /// appears and never changes on activation. Reopened hosts append at the bottom.
    private var hostCreationOrder: [String: Int] = [:]
    private var hostCreationCounter = 0

    init() {
        let first = Tab()   // blank, pristine
        tabs = [first]
        activeTabID = first.id
        popupGate.browser = self
        historyRecorder.browser = self   // for trust-boundary store rebinding
        activationCounter = 1
        first.activationOrder = 1
        wire(first)
        bindActiveURL()
        // Refresh the window title whenever the trust set changes (fires immediately).
        trustBinding = TrustStore.shared.$trustedDomains.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowTitle() }
        }
        recomputeHostGroups()
    }

    var activeTab: Tab {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    func newTab() {
        let tab = Tab()   // blank, pristine
        tabs.append(tab)
        wire(tab)
        activeTabID = tab.id   // didSet bumps activation, discards prior pristine, recomputes
    }

    /// Open the full-page history view (rail history icon / ⌘Y).
    func openHistoryPage() { openInternalPage(.history, title: "History") }

    /// Open the Trusted Sites page (rail shield icon / ⌘⇧Y).
    func openTrustedSitesPage() { openInternalPage(.trustedSites, title: "Trusted Sites") }

    /// Open the Keyboard Shortcuts page (⌘/ or the popover's "See all"; slice 9b).
    func openShortcutsPage() { openInternalPage(.shortcuts, title: "Keyboard Shortcuts") }

    /// Open the full Downloads page (⌘⇧J or the popover's "See all"; slice 9c).
    func openDownloadsPage() { openInternalPage(.downloads, title: "Downloads") }

    /// Open the Vault surface (F5). Only opened once unlocked — the gate overlay handles
    /// first-run/unlock before this is called.
    func openVaultPage() { openInternalPage(.vault, title: "Vault") }

    /// Open an internal-page surface: if one of this kind is already open, switch to
    /// it (no duplicate); otherwise create it. It's a host-less page — not in the
    /// rail favicon stack and not discarded as pristine.
    func openInternalPage(_ kind: Tab.Kind, title: String) {
        if let existing = tabs.first(where: { $0.kind == kind }) {
            activeTabID = existing.id
        } else {
            let tab = Tab(page: kind, title: title)
            tabs.append(tab)
            wire(tab)
            activeTabID = tab.id
        }
    }

    /// Navigate the active tab to `url` (Enter from the omnibox). A web tab loads in
    /// place. An internal page (history/trusted/etc.) can't load a web page in its
    /// own view, so it "gives way": we replace it in its slot with a fresh web tab.
    func navigateActiveTab(to url: URL) {
        let active = activeTab
        if active.kind == .web {
            active.navigate(to: url)
            return
        }
        let webTab = Tab(url: url)
        if let idx = tabs.firstIndex(where: { $0.id == active.id }) {
            tabs[idx] = webTab
        } else {
            tabs.append(webTab)
        }
        tabURLBindings[active.id] = nil
        wire(webTab)
        activeTabID = webTab.id   // didSet rebinds + recomputes; old internal tab is gone
    }

    /// Open `url` in a new foreground tab (⌘Enter from the omnibox).
    func openInNewTab(_ url: URL) {
        newTab()
        activeTab.navigate(to: url)
    }

    /// Close a tab; if it was the last one, keep the window alive with a fresh tab.
    func closeTab(_ id: Tab.ID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        tabURLBindings[id] = nil
        if tabs.isEmpty {
            let tab = Tab()
            tabs = [tab]
            wire(tab)
            activeTabID = tab.id          // didSet recomputes (logs any host removal)
        } else if activeTabID == id {
            activeTabID = tabs[min(idx, tabs.count - 1)].id   // didSet recomputes
        } else {
            recomputeHostGroups()         // closed a background tab
        }
    }

    /// Addition 1: close every tab in `host`'s group. Reuses `closeTab` per tab, so
    /// active-tab reassignment and the keep-window-alive rule (a fresh blank tab when
    /// the last tab closes) are inherited unchanged. `recomputeHostGroups` then drops
    /// the host's rail tile. IDs are snapshotted first since `closeTab` mutates `tabs`.
    func closeHost(_ host: String) {
        let target = host.lowercased()
        let ids = tabs
            .filter { $0.hasNavigated && $0.url.host?.lowercased() == target }
            .map(\.id)
        for id in ids { closeTab(id) }
    }

    /// Adopt an allowed pop-up as a new tab. Its store follows the destination
    /// host's trust (persistent for trusted, isolated ephemeral otherwise), chosen
    /// on the configuration before WebKit snapshots it. WebKit then drives the load.
    func adoptPopup(configuration: WKWebViewConfiguration, initialURL: URL?) -> WKWebView {
        let persistent = TrustStore.shared.isTrusted(url: initialURL)
        configuration.websiteDataStore = persistent ? .default() : .nonPersistent()
        configuration.applicationNameForUserAgent = Tab.safariUserAgentToken   // Safari UA on popups too
        #if DEBUG
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        let webView = WebContentView(frame: .zero, configuration: configuration)
        let tab = Tab(adopting: webView, initialURL: initialURL, persistent: persistent)
        tabs.append(tab)
        wire(tab)               // subscription marks it real (it already has a URL)
        activeTabID = tab.id
        return webView
    }

    /// Find the tab that owns `webView` (used by the navigation delegate).
    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.webView === webView }
    }

    /// Recreate `tab`'s web view on the correct store and load `url` there. Called
    /// when a navigation crosses a trust boundary (from `decidePolicyFor
    /// navigationAction`) or when the user toggles trust. Re-attaches delegates to
    /// the new web view; the `Tab`'s `$url`/`$title` bindings are unaffected.
    func rebind(_ tab: Tab, to url: URL, persistent: Bool) {
        tab.rebindStore(persistent: persistent)
        tab.webView.uiDelegate = popupGate
        tab.webView.navigationDelegate = historyRecorder
        #if DEBUG
        print("[Trust] rebound tab to \(persistent ? "persistent" : "ephemeral") store for \(url.host ?? "?")")
        #endif
        tab.webView.load(URLRequest(url: url))
    }

    // MARK: - Rail: grouping, ordering, pristine rule

    /// Mirror the active tab's current URL into `BookmarkState` (re-subscribing on
    /// every tab switch), so the bookmark command's title stays correct.
    private func bindActiveURL() {
        let tab = activeTab
        activeURLBinding = tab.$url.sink { [weak self] url in
            MainActor.assumeIsolated {
                BookmarkState.shared.activeURL = url
                // Addition 5: a pristine→loaded transition flips `hasNavigated` and
                // bumps the URL, so recompute the title on URL changes too.
                self?.refreshWindowTitle()
            }
        }
        // Addition 5: re-track the active tab's title and refresh immediately so the
        // window title follows both live title changes and tab switches.
        activeTitleBinding = tab.$title.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowTitle() }
        }
        refreshWindowTitle()
    }

    /// Addition 5: derive the window title from the active tab's state. Slice C1
    /// indicators: append a plain-text "· Trusted: <Primary>" when the active tab's
    /// domain is trusted (system titles are plain text — no badge graphic here).
    private func refreshWindowTitle() {
        let tab = activeTab
        if tab.kind != .web { windowTitle = tab.title; return }   // internal pages (History, Trusted Sites)
        let base: String
        if !tab.hasNavigated {
            base = "New Tab"
        } else {
            let trimmed = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
            base = trimmed.isEmpty ? "Surfr" : trimmed
        }
        // Persistent indicators (mutually exclusive — an http page is never trusted):
        //  • insecure http page the user continued to → "Not Secure";
        //  • trusted https domain → "Trusted: <Domain>".
        if tab.hasNavigated, let host = tab.url.host {
            if tab.url.scheme?.lowercased() == "http" {
                windowTitle = "\(base) · ⚠ Not Secure"
            } else if TrustStore.shared.isTrusted(host: host) {
                let primary = TrustStore.primaryLabel(forDomain: TrustStore.registrableDomain(for: host))
                windowTitle = "\(base) · Trusted: \(primary)"
            } else {
                windowTitle = base
            }
        } else {
            windowTitle = base
        }
    }

    /// Route a tab's callbacks through the shared gate + history recorder, and
    /// watch its URL so we notice when a pristine tab first navigates.
    private func wire(_ tab: Tab) {
        tab.webView.uiDelegate = popupGate
        tab.webView.navigationDelegate = historyRecorder
        tabURLBindings[tab.id] = tab.$url.sink { [weak self, weak tab] _ in
            MainActor.assumeIsolated {
                guard let self, let tab else { return }
                self.handleTabURL(tab)
            }
        }
    }

    /// A tab's URL changed: if it just became real, mark it, warm its favicon, and
    /// log the join. Always refresh grouping (the host may have changed).
    private func handleTabURL(_ tab: Tab) {
        if !tab.hasNavigated, let host = tab.url.host, !host.isEmpty {
            tab.hasNavigated = true
            railLog("tab joined host \(host)")
            FaviconService.shared.prefetch(host: host)
        }
        recomputeHostGroups()
    }

    private func handleActiveChange(previous: Tab.ID) {
        // Stamp the newly active tab as most-recent.
        if let active = tabs.first(where: { $0.id == activeTabID }) {
            activationCounter += 1
            active.activationOrder = activationCounter
        }
        // Slice 9c: auto-close the surface we just left if it's ephemeral — an
        // internal page (history/trusted/downloads/shortcuts) or an untouched
        // pristine new-tab page. This keeps internal surfaces single-instance and
        // stops them piling up as stray tabs. (When an internal page "gives way" to
        // a web page via `navigateActiveTab`, the old tab is already gone, so this
        // is a no-op for that case.)
        if previous != activeTabID,
           let prev = tabs.first(where: { $0.id == previous }), isEphemeralSurface(prev) {
            discard(prev)
        }
        recomputeHostGroups()
    }

    /// An ephemeral surface auto-closes when it's no longer the active tab: every
    /// internal page, plus a pristine new-tab page. Applied generically, so any
    /// future internal `Kind` inherits the behaviour without special-casing.
    private func isEphemeralSurface(_ tab: Tab) -> Bool {
        tab.kind != .web || isPristine(tab)
    }

    /// Pristine = a plain web tab that never navigated AND has no typed-but-
    /// uncommitted address text. The typed-URL preservation rule for real new tabs
    /// is unchanged (a tab with typed text is not pristine, so it's not discarded).
    private func isPristine(_ tab: Tab) -> Bool {
        tab.kind == .web && !tab.hasNavigated
            && tab.addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func discard(_ tab: Tab) {
        tabs.removeAll { $0.id == tab.id }
        tabURLBindings[tab.id] = nil
        railLog("ephemeral surface auto-closed (\(tab.kind == .web ? "new-tab" : "internal page"))")
    }

    /// Group real (navigated) tabs by full host; one tile per host, in stable
    /// **creation order** (first-opened on top; never reorders on activation).
    /// Logs any host group that disappeared.
    private func recomputeHostGroups() {
        var byHost: [String: [Tab]] = [:]
        for tab in tabs where tab.hasNavigated {
            guard let host = tab.url.host?.lowercased(), !host.isEmpty else { continue }
            byHost[host, default: []].append(tab)
        }
        // Fix each host's strip position the first time it appears.
        for host in byHost.keys.sorted() where hostCreationOrder[host] == nil {
            hostCreationCounter += 1
            hostCreationOrder[host] = hostCreationCounter
        }
        var groups = byHost.map { host, hostTabs -> HostGroup in
            // Representative tab (for click-to-switch) is still the most-recent.
            let representative = hostTabs.max { $0.activationOrder < $1.activationOrder }!
            return HostGroup(
                host: host,
                tabCount: hostTabs.count,
                representativeTabID: representative.id,
                isActive: hostTabs.contains { $0.id == activeTabID },
                isInsecure: representative.url.scheme?.lowercased() == "http"
            )
        }
        groups.sort { (hostCreationOrder[$0.host] ?? 0) < (hostCreationOrder[$1.host] ?? 0) }

        let removed = Set(hostGroups.map(\.host)).subtracting(groups.map(\.host))
        for host in removed {
            hostCreationOrder[host] = nil   // reopened later → fresh slot at the bottom
            railLog("host group removed \(host)")
        }

        hostGroups = groups
    }

    private func railLog(_ message: String) {
        #if DEBUG
        print("[Rail] \(message)")
        #endif
    }
}

/// Observes successful page loads of real http(s) pages: records history and
/// ingests the page's first-party declared favicons. Adds these hooks only — no
/// other navigation behaviour is changed.
final class HistoryRecorder: NSObject, WKNavigationDelegate {
    /// For trust-boundary store rebinding (slice C1). Weak — `BrowserState` owns us.
    weak var browser: BrowserState?

    /// Reads `<link rel>` icon hrefs, apple-touch-icon first (usually higher-res),
    /// resolved to absolute URLs by the DOM.
    private static let iconLinkJS = """
    (function () {
      function hrefs(sel) {
        return Array.prototype.map.call(document.querySelectorAll(sel), function (l) { return l.href; });
      }
      return hrefs("link[rel~='apple-touch-icon'], link[rel~='apple-touch-icon-precomposed']")
        .concat(hrefs("link[rel~='icon']"));
    })()
    """

    // MARK: - Downloads (slice A)
    //
    // Downloads are wired into THIS same navigation delegate — a web view has only
    // one navigationDelegate, so the download-decision methods live here alongside
    // history recording rather than on a second delegate. WebKit converts a response
    // or navigation action into a `WKDownload`; `DownloadManager` owns the rest.

    /// A response the web view can't render (e.g. a zip/binary) becomes a download;
    /// everything displayable is allowed through unchanged (the prior default).
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    /// Decide each navigation action, in order:
    ///  1. download-attribute / explicit download actions → `.download`;
    ///  2. trust-boundary crossing (slice C1) → `.cancel` + recreate the tab's web
    ///     view on the correct store and load there;
    ///  3. otherwise → `.allow` (unchanged).
    ///
    /// The store-binding hook lives here because this fires for *every* main-frame
    /// navigation — omnibox loads, link clicks, redirects, bookmark opens — so one
    /// check covers them all. We compare the destination host's required store
    /// (`TrustStore.isTrusted`) to the web view's current store and swap only on a
    /// genuine mismatch. Cancelling *before* the response means untrusted cookies
    /// never write to the persistent store, and trusted pages always persist.
    /// Same-store navigations (incl. SSO redirect chains within a registrable
    /// domain) just `.allow` — no swap, no jank.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // Only main-frame http(s) navigations can change a tab's store. Subframes
        // (iframes) and non-web schemes never trigger a swap.
        if let browser, let tab = browser.tab(for: webView),
           navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {

            // HTTPS-only (Stage-1): upgrade http → https before anything else. We
            // preserve the request (method/body) so a form POST isn't downgraded to
            // a GET, then re-enter with the secure URL (idempotent — won't loop).
            if scheme == "http", HTTPSUpgrader.shared.shouldUpgrade(url) {
                var secure = navigationAction.request
                secure.url = HTTPSUpgrader.secureURL(url)
                decisionHandler(.cancel)
                tab.httpsUpgradeOriginal = url   // remembered so a failure shows the interstitial
                webView.load(secure)
                return
            }

            // Tracking-param stripping (Stage-1): only user-initiated GET navigations
            // (address bar / link clicks), never forms/POSTs/redirects — so it can't
            // touch auth/session params. Re-entry with the clean URL is idempotent.
            if TrackingParams.shouldStrip(navigationAction, chainInFlight: tab.navigationChainInFlight),
               let cleaned = TrackingParams.stripped(from: url) {
                decisionHandler(.cancel)
                #if DEBUG
                print("[Tracking] stripped params: \(url.absoluteString) → \(cleaned.absoluteString)")
                #endif
                webView.load(URLRequest(url: cleaned))
                return
            }

            // Persistent store requires BOTH a trusted domain AND https — an insecure
            // http page (only reachable via explicit "continue insecurely") never
            // enters the persistent store, even on an otherwise-trusted domain.
            let wantPersistent = scheme == "https" && TrustStore.shared.isTrusted(host: url.host)
            // Redirect-chain guard (slice C): a `.other` navigation while a chain is
            // already in flight is a redirect hop (e.g. an OAuth 302). Do NOT rebind
            // mid-chain, or the login lands in the wrong store ("cookies not
            // supported, fixed after reloads"). The store stays as decided at chain
            // start; a real mismatch is reconciled once the chain settles (didFinish).
            // A genuine user navigation (link/form/back-forward/reload) is never a
            // redirect hop, so it still rebinds immediately even while a page loads.
            let isRedirectHop = tab.navigationChainInFlight && navigationAction.navigationType == .other
            if wantPersistent != tab.usesPersistentStore && !isRedirectHop {
                decisionHandler(.cancel)
                browser.rebind(tab, to: url, persistent: wantPersistent)
                return
            }
        }
        decisionHandler(.allow)
    }

    // MARK: - Navigation-chain tracking (for the redirect-chain rebind guard)

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        browser?.tab(for: webView)?.navigationChainInFlight = true
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let tab = browser?.tab(for: webView)
        tab?.navigationChainInFlight = false

        // HTTPS-only: if the secure load we forced just failed, show the insecure-site
        // interstitial for the original http URL (never a silent http fallback).
        if let tab, let original = tab.httpsUpgradeOriginal {
            tab.httpsUpgradeOriginal = nil
            let failingHost = ((error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
                .flatMap(URL.init(string:))?.host?.lowercased()
            let secureHost = HTTPSUpgrader.secureURL(original).host?.lowercased()
            // Only intercept the upgrade's own failure (not an unrelated nav).
            if failingHost == nil || failingHost == secureHost {
                webView.loadHTMLString(HTTPSUpgrader.interstitialHTML(httpURL: original), baseURL: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        browser?.tab(for: webView)?.navigationChainInFlight = false
    }

    /// WebKit hands us the download once a response is converted: start tracking it.
    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        DownloadManager.shared.register(download)
    }

    /// Same, for a navigation action converted into a download.
    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        DownloadManager.shared.register(download)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The redirect chain has settled.
        let tab = browser?.tab(for: webView)
        tab?.navigationChainInFlight = false
        tab?.httpsUpgradeOriginal = nil   // HTTPS upgrade succeeded (or unrelated finish)

        // Skip blank/new-tab/about:blank and non-web schemes; record real pages only.
        guard let url = webView.url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return }

        // Deferred rebind (slice C): a chain we let ride in its start store may have
        // settled on a host whose trust wants the *other* store (e.g. trusted A
        // redirected to and stayed on untrusted D). Reconcile now — once, after the
        // chain ends — so the dwelt-on page ends up in the correct store, without
        // having rebound mid-chain. The persistent store requires https too, so an
        // insecure http page on a trusted domain settles ephemeral, never persistent.
        let wantPersistent = scheme == "https" && TrustStore.shared.isTrusted(host: host)
        if let browser, let tab, wantPersistent != tab.usesPersistentStore {
            browser.rebind(tab, to: url, persistent: wantPersistent)
            return
        }

        let title = webView.title
        Task { await HistoryStore.shared.recordVisit(url: url, title: title) }

        // Favicon: read the page's declared first-party icons and ingest them.
        Task { @MainActor in
            let hrefs = (try? await webView.evaluateJavaScript(Self.iconLinkJS)) as? [String] ?? []
            let candidates = hrefs.compactMap { URL(string: $0) }
            await FaviconService.shared.ingestDeclaredIcons(host: host, candidateURLs: candidates)
        }
    }
}

/// `WKWebView` subclass that adds a "Bookmark Page" / "Remove Bookmark" item to
/// the page's right-click menu — same context menu the DEBUG Inspect Element item
/// lives in. Bookmarking is a real feature, so this is not DEBUG-gated.
final class WebContentView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        MainActor.assumeIsolated {
            // Only offer bookmarking on real http(s) pages.
            guard let url = self.url,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty else { return }
            let bookmarked = BookmarkState.shared.bookmarkedURLs.contains(url.absoluteString)
            let item = NSMenuItem(title: bookmarked ? "Remove Bookmark" : "Bookmark Page",
                                  action: #selector(toggleBookmarkFromMenu),
                                  keyEquivalent: "")
            item.target = self
            menu.insertItem(.separator(), at: 0)
            menu.insertItem(item, at: 0)
        }
    }

    @objc private func toggleBookmarkFromMenu() {
        MainActor.assumeIsolated {
            guard let url = self.url else { return }
            let title = self.title
            Task { await BookmarkState.shared.toggle(url: url, title: title) }
        }
    }
}

/// In-memory bookmark state for synchronous UI (the bookmark menu title and the
/// right-click item). Mirrors the persisted set; `BookmarkStore` is the record of
/// truth. App-layer only — not part of the SurfrCore-ready data layer.
@MainActor
final class BookmarkState: ObservableObject {
    static let shared = BookmarkState()

    /// URLs currently bookmarked — mirror of the store, for synchronous lookups.
    @Published private(set) var bookmarkedURLs: Set<String> = []
    /// Full bookmark records, most-recently-added first (store's natural order).
    /// Drives the new-tab bookmarks grid (slice 6); updates live on add/remove.
    @Published private(set) var bookmarks: [Bookmark] = []
    /// The active tab's current URL, so the menu title can reflect its state.
    @Published var activeURL: URL?

    /// Whether the active tab's page is bookmarked (drives the menu item title).
    var isActiveBookmarked: Bool {
        guard let activeURL else { return false }
        return bookmarkedURLs.contains(activeURL.absoluteString)
    }

    private init() {}

    /// Populate the mirror from the store; call once at launch.
    func load() async { await reload() }

    /// Toggle the bookmark for a page; ignores blank/about:blank/non-web pages.
    func toggle(url: URL, title: String?) async {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return }
        if bookmarkedURLs.contains(url.absoluteString) {
            await BookmarkStore.shared.removeByURL(url)
        } else {
            await BookmarkStore.shared.add(url: url, title: title)
        }
        await reload()
    }

    /// Remove a specific bookmark (new-tab grid "Remove bookmark").
    func remove(_ bookmark: Bookmark) async {
        if let id = bookmark.id {
            await BookmarkStore.shared.remove(id: id)
        } else if let url = URL(string: bookmark.url) {
            await BookmarkStore.shared.removeByURL(url)
        }
        await reload()
    }

    /// Re-read the store into both the URL set and the ordered records, so the
    /// menu state and the grid stay consistent from one source of truth.
    private func reload() async {
        let all = await BookmarkStore.shared.all()
        bookmarks = all
        bookmarkedURLs = Set(all.map(\.url))
    }
}

/// Minimal origin allowlist for pop-ups (F4). Starts empty — a pop-up is allowed
/// only when user-initiated, unless its origin is explicitly trusted here.
final class TrustPolicy {
    private var allowedHosts: Set<String> = []

    func allow(host: String) { allowedHosts.insert(host.lowercased()) }

    func allows(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }
}

/// `WKUIDelegate` shared by every tab. Gates `window.open`: a new tab opens only
/// for user-initiated link activations or trusted origins; programmatic pop-ups
/// and pop-unders are blocked (return `nil`) and logged. Also forwards native
/// alert/confirm/prompt so installing this delegate doesn't disable JS dialogs.
final class PopupGate: NSObject, WKUIDelegate {
    weak var browser: BrowserState?
    let trustPolicy = TrustPolicy()

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // This callback arrives on the main thread.
        MainActor.assumeIsolated {
            let target = navigationAction.request.url
            let userInitiated = navigationAction.navigationType == .linkActivated
            let trusted = target.map(trustPolicy.allows) ?? false

            guard userInitiated || trusted else {
                print("[PopupGate] blocked pop-up: \(target?.absoluteString ?? "about:blank") — "
                    + "programmatic window.open (not a user link activation)")
                return nil
            }
            return browser?.adoptPopup(configuration: configuration, initialURL: target)
        }
    }

    // MARK: JS dialog passthrough — keep alert/confirm/prompt working

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            completionHandler(field.stringValue)
        } else {
            completionHandler(nil)
        }
    }
}

/// Hosts a tab's long-lived `WKWebView`. The view is re-made (via `.id`) when the
/// active tab changes, so each tab keeps its own page without reloading.
struct WebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// The address bar for the active tab. Observes the tab so it reflects live URL changes.
/// One host tile in the rail: favicon (or letter-tile fallback), active highlight,
/// and a count badge when the host has ≥2 tabs. Clicking switches to the host's
/// most-recently-active tab.
struct FaviconTile: View {
    let host: String
    let isActive: Bool
    let tabCount: Int
    /// True when this host's current page is insecure (http, user-continued).
    let isInsecure: Bool
    let onTap: () -> Void
    /// Addition 1: close every tab in this host group (right-click item — also
    /// reaches single-tab hosts, which never open the flyout).
    let onCloseHost: () -> Void

    @State private var iconData: Data?
    /// Observe trust so the badge appears/disappears live on trust/untrust.
    @ObservedObject private var trustStore = TrustStore.shared

    private static let size: CGFloat = 32        // tile cell (unchanged)
    private static let iconSize: CGFloat = 20    // favicon/letter inset inside the tile
    private static let iconRadius: CGFloat = 5
    private static let ringSize: CGFloat = 26    // active highlight ring (around the icon)
    private static let ringRadius: CGFloat = 7

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                // Favicon (or letter), inset and clipped so the border never touches it.
                iconContent
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: Self.iconRadius))
                // Active highlight: a ring around the icon with clear breathing room.
                RoundedRectangle(cornerRadius: Self.ringRadius)
                    .strokeBorder(Color.blue, lineWidth: 2)
                    .frame(width: Self.ringSize, height: Self.ringSize)
                    .opacity(isActive ? 1 : 0)
            }
            .frame(width: Self.size, height: Self.size)

            if tabCount >= 2 {
                CountBadge(count: tabCount).offset(x: 3, y: 3)
            }
        }
        .frame(width: 40, height: 40)
        // Top-RIGHT corner badge (count badge stays bottom-right, so they never
        // collide). Insecure and trusted are mutually exclusive — http can't be
        // trusted — so they share this corner: amber ⚠ when insecure, green ✓ when
        // trusted, neither otherwise. Inset inside the 40×40 frame so it isn't clipped.
        .overlay(alignment: .topTrailing) {
            if isInsecure {
                InsecureBadge().offset(x: -1, y: 1)
            } else if trustStore.isTrusted(host: host) {
                TrustedBadge().offset(x: -1, y: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        // Addition 1: right-click → close the whole host group. Gives single-tab
        // hosts (no flyout) the same close-all affordance the flyout header offers.
        .contextMenu {
            Button("Close \(tabCount) tab\(tabCount == 1 ? "" : "s")", role: .destructive,
                   action: onCloseHost)
        }
        .help(host)
        .task(id: host) { await loadIcon() }
        .onReceive(NotificationCenter.default.publisher(for: .faviconUpdated).receive(on: RunLoop.main)) { note in
            // A favicon was cached after this tile rendered — swap it in, this tile only.
            guard (note.userInfo?["host"] as? String)?.lowercased() == host.lowercased() else { return }
            if let data = FaviconService.shared.cachedFaviconData(forHost: host) {
                iconData = data
            }
        }
    }

    /// Real favicon if we have usable raster bytes, else the letter-tile fallback.
    /// Sized/clipped by the caller so both look consistent inside the tile.
    @ViewBuilder private var iconContent: some View {
        if let data = iconData ?? FaviconService.shared.cachedFaviconData(forHost: host),
           let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Self.letterColor(for: host)
                Text(Self.letter(for: host))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private func loadIcon() async {
        if let cached = FaviconService.shared.cachedFaviconData(forHost: host) {
            iconData = cached
            return
        }
        iconData = await FaviconService.shared.favicon(forHost: host)
    }

    /// First letter of the primary domain label (admin.shopify.com → "S").
    static func letter(for host: String) -> String {
        let labels = host.split(separator: ".")
        let primary = labels.count >= 2 ? labels[labels.count - 2] : (labels.first ?? Substring(host))
        return primary.first.map { String($0).uppercased() } ?? "?"
    }

    /// Stable per-host tile colour from the service's colour seed.
    static func letterColor(for host: String) -> Color {
        let seed = FaviconService.shared.colorSeed(forHost: host)
        return Color(hue: Double(seed % 360) / 360.0, saturation: 0.55, brightness: 0.75)
    }
}

/// The 48px left rail (ui-wireframes §1): history + new-tab pinned at the top,
/// then the scrolling, host-grouped favicon stack. Replaces the old top tab bar.
/// The fixed internal-surface rail icons (9d). Their order is user-reorderable by
/// drag and persisted; the default (declaration) order is history → downloads →
/// trusted → shortcuts → new tab. The dynamic favicon host tiles below are NOT part
/// of this — they keep their host-creation order.
enum RailSurface: String, CaseIterable, Identifiable, Codable {
    case history, downloads, trusted, shortcuts, vault, newTab
    var id: String { rawValue }

    /// SF Symbol for the floating drag preview (matches each icon's glyph).
    var symbol: String {
        switch self {
        case .history: return "clock"
        case .downloads: return "arrow.down.circle"
        case .trusted: return "checkmark.shield"
        case .shortcuts: return "keyboard"
        case .vault: return "key"
        case .newTab: return "plus"
        }
    }
}

/// Live reorder: as the dragged surface hovers over `item`, move it there (animated
/// snap). The drop just clears the drag state and persists. The payload isn't read —
/// `dragging` carries identity — so this is robust regardless of provider contents.
private struct RailReorderDropDelegate: DropDelegate {
    let item: RailSurface
    @Binding var order: [RailSurface]
    @Binding var dragging: RailSurface?
    let onReorder: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: item) else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        onReorder()
        return true
    }
}

/// Catch-all so dropping anywhere else on the rail ends the drag cleanly (clears the
/// dimmed source) instead of leaving stale drag state.
private struct RailEndDropDelegate: DropDelegate {
    @Binding var dragging: RailSurface?
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return false }
}

struct RailView: View {
    @ObservedObject var browser: BrowserState
    /// Host whose tab flyout is currently open (nil = none). UI-only state.
    @State private var flyoutHost: String?
    /// Whether the downloads manager popover is open. UI-only state.
    @State private var showDownloads = false
    /// Whether the shortcuts cheatsheet popover is open. UI-only state.
    @State private var showShortcuts = false
    /// User-chosen order of the internal-surface icons (9d), loaded from + saved to
    /// UserDefaults. Missing/unknown entries are reconciled against `allCases`.
    @State private var surfaceOrder: [RailSurface] = RailView.loadOrder()
    /// The surface currently being dragged (drives the dim + reorder logic).
    @State private var dragging: RailSurface?

    private static let orderKey = "SurfrRailSurfaceOrder"

    var body: some View {
        VStack(spacing: 8) {
            // Internal-surface icons — drag to reorder (9d); order persists.
            ForEach(surfaceOrder) { surface in
                surfaceIcon(surface)
                    .opacity(dragging == surface ? 0.45 : 1)
                    .onDrag {
                        dragging = surface
                        return NSItemProvider(object: surface.rawValue as NSString)
                    } preview: {
                        // A plain glyph as the floating drag image (clear affordance).
                        Image(systemName: surface.symbol)
                            .font(.system(size: 16))
                            .frame(width: 32, height: 28)
                    }
                    .onDrop(of: [.text], delegate: RailReorderDropDelegate(
                        item: surface, order: $surfaceOrder, dragging: $dragging, onReorder: persistOrder))
            }

            Divider().frame(width: 30)

            // Favicon stack — one tile per host, scrolls if it overflows.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(browser.hostGroups) { group in
                        FaviconTile(
                            host: group.host,
                            isActive: group.isActive,
                            tabCount: group.tabCount,
                            isInsecure: group.isInsecure,
                            onTap: {
                                // Single-tab host switches directly; multi-tab opens the flyout.
                                if group.tabCount >= 2 {
                                    flyoutHost = group.host
                                } else {
                                    browser.activeTabID = group.representativeTabID
                                }
                            },
                            // Addition 1: right-click close-all for this host group.
                            onCloseHost: { browser.closeHost(group.host) }
                        )
                        .popover(isPresented: flyoutBinding(for: group.host), arrowEdge: .trailing) {
                            TabFlyout(browser: browser, host: group.host) { flyoutHost = nil }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 48)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: browser.hostGroups.map(\.host)) { _, hosts in
            // If the flyout's host disappeared (its last tab closed), drop the stale state.
            if let open = flyoutHost, !hosts.contains(open) { flyoutHost = nil }
        }
        // Dropping on the rail's non-icon space ends a reorder drag cleanly.
        .onDrop(of: [.text], delegate: RailEndDropDelegate(dragging: $dragging))
    }

    /// Render one internal-surface icon with its full behaviour (active-green,
    /// popovers, badges, click). Order/drag is applied by the caller.
    @ViewBuilder private func surfaceIcon(_ surface: RailSurface) -> some View {
        switch surface {
        case .history:
            railIconButton("clock", help: "History",
                           isActive: browser.activeTab.kind == .history,
                           action: browser.openHistoryPage)
        case .downloads:
            // Icon opens the popover (recent + live progress); "See all" / ⌘⇧J open
            // the page. Keeps its ring / count / completed states + 9a active-green.
            DownloadsRailIcon(isActive: browser.activeTab.kind == .downloads) {
                showDownloads = true
                DownloadManager.shared.acknowledge()
            }
            .popover(isPresented: $showDownloads, arrowEdge: .trailing) {
                DownloadsPopover {
                    showDownloads = false
                    browser.openDownloadsPage()
                }
            }
        case .trusted:
            railIconButton("checkmark.shield", help: "Trusted Sites",
                           isActive: browser.activeTab.kind == .trustedSites,
                           action: browser.openTrustedSitesPage)
        case .shortcuts:
            railIconButton("keyboard", help: "Keyboard Shortcuts",
                           isActive: browser.activeTab.kind == .shortcuts,
                           action: { showShortcuts = true })
                .popover(isPresented: $showShortcuts, arrowEdge: .trailing) {
                    ShortcutsCheatsheet {
                        showShortcuts = false
                        browser.openShortcutsPage()
                    }
                }
        case .vault:
            // Posts .openVault so ContentView's gate routing decides first-run / unlock / surface.
            railIconButton("key", help: "Vault",
                           isActive: browser.activeTab.kind == .vault,
                           action: { NotificationCenter.default.post(name: .openVault, object: nil) })
        case .newTab:
            railIconButton("plus", help: "New Tab (⌘T)",
                           isActive: browser.activeTab.kind == .web && !browser.activeTab.hasNavigated,
                           action: browser.newTab)
        }
    }

    // MARK: - Order persistence (9d)

    /// Load the saved order, reconciled against `allCases`: unknown entries dropped,
    /// missing ones appended in default order (so a fresh install / a newly-added
    /// surface yields the default history → downloads → trusted → shortcuts → new tab).
    private static func loadOrder() -> [RailSurface] {
        let saved = (UserDefaults.standard.stringArray(forKey: orderKey) ?? [])
            .compactMap { RailSurface(rawValue: $0) }
        var result: [RailSurface] = []
        for s in saved where !result.contains(s) { result.append(s) }
        for s in RailSurface.allCases where !result.contains(s) { result.append(s) }
        return result
    }

    private func persistOrder() {
        UserDefaults.standard.set(surfaceOrder.map(\.rawValue), forKey: Self.orderKey)
    }

    /// A pinned rail icon button. `isActive` tints it green (reusing the trusted/
    /// completed green) when its surface is the active tab.
    private func railIconButton(_ systemName: String, help: String,
                                isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16))
                .foregroundStyle(isActive ? Color.green : Color.primary)
                .frame(width: 32, height: 28)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Presents the flyout for `host` when it's the open one; dismissal clears it.
    private func flyoutBinding(for host: String) -> Binding<Bool> {
        Binding(get: { flyoutHost == host }, set: { if !$0 { flyoutHost = nil } })
    }
}

/// Per-host tab flyout (ui-wireframes §3): header + live filter + tab rows. Floats
/// over the page via a popover (no reflow; click-away / Esc dismiss for free).
struct TabFlyout: View {
    @ObservedObject var browser: BrowserState
    let host: String
    let onSelect: () -> Void

    @State private var filter = ""

    /// This host's tabs, active pinned on top, then most-recently-active.
    private var hostTabs: [Tab] {
        browser.tabs
            .filter { $0.hasNavigated && $0.url.host?.lowercased() == host }
            .sorted { a, b in
                if a.id == browser.activeTabID { return true }
                if b.id == browser.activeTabID { return false }
                return a.activationOrder > b.activationOrder
            }
    }

    private var filteredTabs: [Tab] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return hostTabs }
        return hostTabs.filter {
            $0.title.lowercased().contains(query) || $0.url.absoluteString.lowercased().contains(query)
        }
    }

    var body: some View {
        let count = hostTabs.count
        VStack(alignment: .leading, spacing: 6) {
            // Addition 1: header shows "host · N tabs" plus a close-all control that
            // closes every tab in this group, then dismisses the flyout. `closeHost`
            // empties the group → the host's rail tile (favicon) is removed.
            HStack(spacing: 6) {
                Text("\(host) · \(count) tab\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    browser.closeHost(host)
                    onSelect()   // dismiss the flyout
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Close all \(count) tab\(count == 1 ? "" : "s")")
            }
            TextField("filter tabs", text: $filter)
                .textFieldStyle(.roundedBorder)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filteredTabs) { tab in
                        TabFlyoutRow(
                            tab: tab,
                            host: host,
                            isActive: tab.id == browser.activeTabID,
                            onSelect: { browser.activeTabID = tab.id; onSelect() },
                            onClose: { browser.closeTab(tab.id) }
                        )
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(10)
        .frame(width: 280)
    }
}

/// One row in the tab flyout: favicon + title (click switches) and an ✕ to close
/// that specific tab. Observes the tab so the title/URL stay live.
struct TabFlyoutRow: View {
    @ObservedObject var tab: Tab
    let host: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    rowIcon
                    Text(tab.title.isEmpty ? tab.url.absoluteString : tab.title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isActive ? Color.blue.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    /// All of a host's tabs share its favicon; fall back to the letter tile.
    @ViewBuilder private var rowIcon: some View {
        Group {
            if let data = FaviconService.shared.cachedFaviconData(forHost: host),
               let image = NSImage(data: data) {
                Image(nsImage: image).resizable()
            } else {
                ZStack {
                    FaviconTile.letterColor(for: host)
                    Text(FaviconTile.letter(for: host))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: 16, height: 16)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

/// The active tab's content: the new-tab page while pristine, else its web view.
/// Observes the `Tab` so it re-renders when `hasNavigated` flips or — crucially for
/// slice C1 — when `webView` is swapped onto a different store. The inner `.id`
/// keyed by the web view's identity forces the `NSViewRepresentable` to rebuild
/// (and thus display the new web view) on a swap.
struct ActiveTabContent: View {
    @ObservedObject var tab: Tab
    let onNavigate: (URL, Bool) -> Void
    let focusToken: Int

    var body: some View {
        switch tab.kind {
        case .history:
            // Internal page: clicking a row always opens in a NEW tab.
            HistoryPage(onOpenURL: { onNavigate($0, true) })
        case .trustedSites:
            TrustedSitesPage(onOpenURL: { onNavigate($0, true) })
        case .shortcuts:
            ShortcutsPage()   // view-only (9b); editing is 9b2
        case .downloads:
            DownloadsPage()   // 9c — full page; the rail keeps its popover
        case .vault:
            VaultSurfacePlaceholder()   // F5 Slice 3 — list/detail arrive in Slice 5
        case .web:
            if tab.hasNavigated {
                WebView(webView: tab.webView)
                    .id(ObjectIdentifier(tab.webView))
            } else {
                NewTabPage(tab: tab, onNavigate: onNavigate, focusToken: focusToken)
            }
        }
    }
}

/// Slice 9a — bundles the reload + open-surface notification handlers. These need
/// only `browser`, so collapsing them into one modifier keeps `ContentView.body`'s
/// modifier chain small enough for the Swift type-checker.
private struct BrowserCommandHandlers: ViewModifier {
    @ObservedObject var browser: BrowserState

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .reloadPage)) { _ in
                browser.activeTab.webView.reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .reloadHard)) { _ in
                browser.activeTab.webView.reloadFromOrigin()   // bypass cache
            }
            .onReceive(NotificationCenter.default.publisher(for: .reloadEmptyCache)) { _ in
                emptyCacheAndReload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openHistory)) { _ in
                browser.openHistoryPage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openTrusted)) { _ in
                browser.openTrustedSitesPage()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openDownloads)) { _ in
                browser.openDownloadsPage()   // ⌘⇧J opens the full page (9c)
            }
            .onReceive(NotificationCenter.default.publisher(for: .openShortcuts)) { _ in
                browser.openShortcutsPage()   // ⌘/ opens the full page (9b)
            }
    }

    /// Clear only the active tab's caches (not cookies — trusted sessions survive),
    /// then hard-reload. Cache clearing runs off-main via the async data API.
    private func emptyCacheAndReload() {
        let webView = browser.activeTab.webView
        let store = webView.configuration.websiteDataStore
        // Disk + memory + fetch caches are the live HTTP caches. (The old
        // WKWebsiteDataTypeOfflineWebApplicationCache was removed in macOS 26.2 —
        // AppCache is no longer a supported web feature, so there's nothing to clear
        // and no replacement type; dropping it keeps clear-data behaviour identical.)
        let cacheTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeFetchCache,
        ]
        Task { @MainActor in
            await store.removeData(ofTypes: cacheTypes, modifiedSince: .distantPast)
            webView.reloadFromOrigin()
        }
    }
}

struct ContentView: View {
    @StateObject private var browser = BrowserState()
    /// Context A overlay presented (only on a loaded page).
    @State private var showSpotlight = false
    /// Bumped on every ⌘L so the overlay re-focuses + selects-all on each summon.
    @State private var spotlightToken = 0
    /// Bumped to focus the new-tab permanent box (Context B) on ⌘L.
    @State private var newTabFocusToken = 0
    /// Addition 3: retained token for the app-local mouse side-button monitor.
    @State private var mouseNavMonitor: Any?
    /// Slice C1 indicators: the trust toast currently shown (nil = none).
    @State private var trustToast: TrustToast?
    /// F5 Slice 3: the password-vault coordinator (first-run / unlock / lock).
    @StateObject private var vault = VaultGate()
    /// Whether the vault gate overlay (first-run or unlock) is presented.
    @State private var showVault = false

    var body: some View {
        HStack(spacing: 0) {
            RailView(browser: browser)
            Divider()
            ZStack {
                // The content area is either the new-tab page (pristine tab) or the
                // loaded web view — no persistent address bar (zero chrome).
                // `ActiveTabContent` observes the tab so it follows a store swap.
                ActiveTabContent(tab: browser.activeTab, onNavigate: navigate,
                                 focusToken: newTabFocusToken)
                    .id(browser.activeTabID)

                // Context A: the summoned overlay, over the dimmed page. The
                // per-summon token id forces a fresh field + focus each time.
                if showSpotlight {
                    SpotlightOverlay(initialText: spotlightPrefill, focusToken: spotlightToken,
                                     onNavigate: navigate, onClose: closeSpotlight)
                        .id(spotlightToken)
                }

                // F5 Slice 3: the vault gate overlay (first-run / unlock), dimmed like Spotlight.
                if showVault {
                    VaultOverlay(gate: vault, onClose: closeVault)
                }

                // Slice C1 indicators: trust toast, top-right, auto-dismiss ~7s.
                if let toast = trustToast {
                    TrustToastView(toast: toast) { dismissTrustToast() }
                        .padding(.top, 16)
                        .padding(.trailing, 16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(toast.id)   // fresh identity → each toast slides/fades in anew
                        .task(id: toast.id) {
                            try? await Task.sleep(nanoseconds: 7_000_000_000)
                            // Don't tear down a newer toast: bail if this timer was
                            // cancelled (replaced) and only dismiss our own toast.
                            guard !Task.isCancelled else { return }
                            dismissTrustToast(id: toast.id)
                        }
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        // F5 Slice 3: make the vault coordinator available to the vault surface placeholder.
        .environmentObject(vault)
        // Addition 5: bind the macOS window title to the active tab's page title.
        .navigationTitle(browser.windowTitle)
        // Addition 3: install/remove the app-local mouse side-button monitor.
        .onAppear { installMouseNavMonitor() }
        .onDisappear { removeMouseNavMonitor() }
        .onChange(of: browser.activeTabID) { _, _ in showSpotlight = false }
        .task {
            // Compile the bundled seed ad-block list and apply it to every tab.
            await ContentBlocker.shared.prepare()
            ContentBlocker.shared.startBackgroundRefresh()   // periodic + on-foreground staleness re-check
        }
        .task {
            // Load persisted downloads: migrate prior-run in-progress → interrupted,
            // prune past the retention window, then populate the list (slice 9c+).
            await DownloadManager.shared.loadPersisted()
            // Expire history older than the retention window, once per launch.
            await HistoryStore.shared.prune(olderThan: Date().addingTimeInterval(-HistoryStore.retentionInterval))
            #if DEBUG
            // Optional non-interactive trigger for the history self-test (same as
            // the DEBUG menu item / ⌃⌥⌘H), e.g. `Surfr --run-history-selftest`.
            if CommandLine.arguments.contains("--run-history-selftest") {
                await HistoryStore.shared.runSelfTest()
            }
            #endif
        }
        .task {
            // Load the bookmark mirror so the menu/right-click reflect state.
            await BookmarkState.shared.load()
            #if DEBUG
            if CommandLine.arguments.contains("--run-bookmark-selftest") {
                await BookmarkStore.shared.runSelfTest()
            }
            if CommandLine.arguments.contains("--run-favicon-selftest") {
                await FaviconService.shared.runSelfTest()
            }
            #endif
        }
        .task { await vault.load() }
        // Re-mirror biometric state when returning to the app (e.g. after changing/re-adding a
        // fingerprint in System Settings) so the re-enable affordance recovers live. (Bug 2.)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vault.refreshBiometricState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .resetVault)) { _ in
            showVault = false
            Task { await vault.resetVault() }
        }
        // §4 background auto-lock. Conservative trigger: lock when the app is HIDDEN (⌘H / Hide) — a
        // deliberate step-away — not on every focus loss, so glancing at another app/window doesn't
        // drop the session. (Full resign-active + 5-min idle-timer options are a documented follow-on.)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            vault.lockNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openVault)) { _ in
            showSpotlight = false   // don't leave the omnibox overlay lingering under the vault overlay
            // Route by vault phase: unlocked → open the surface; new → first-run; locked → unlock.
            switch vault.phase {
            case .unlocked:
                browser.openVaultPage()
            case .uninitialized:
                vault.beginFirstRun()
                showVault = true
            case .locked, .firstRun:
                showVault = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleBookmark)) { _ in
            let webView = browser.activeTab.webView
            guard let url = webView.url else { return }
            let title = webView.title
            Task { await BookmarkState.shared.toggle(url: url, title: title) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusOmnibox)) { _ in
            // ⌘L is context-aware (Task 1):
            //  • new-tab page → focus the permanent box;
            //  • loaded web page → overlay pre-filled with the URL (see `spotlightPrefill`);
            //  • any internal surface (history/trusted/downloads/shortcuts) → overlay, empty.
            // The else-branch covers every non-new-tab surface, so future internal
            // pages get ⌘L for free.
            if browser.activeTab.kind == .web && !browser.activeTab.hasNavigated {
                newTabFocusToken += 1
            } else {
                spotlightToken += 1   // re-focus the overlay on every summon
                showSpotlight = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTab)) { _ in
            browser.newTab()
            showSpotlight = false
            newTabFocusToken += 1   // focus the fresh new-tab box
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeTab)) { _ in
            browser.closeTab(browser.activeTabID)
        }
        // Slice C1: toggle persistent-session trust for the active tab's domain,
        // then reload it in the now-correct store. Trusting → persistent (log in
        // once, then it persists); untrusting → ephemeral + the domain's persisted
        // data is cleared by `TrustStore.untrust`.
        .onReceive(NotificationCenter.default.publisher(for: .toggleTrust)) { _ in
            let tab = browser.activeTab
            guard let url = tab.url as URL?, let host = url.host, !host.isEmpty,
                  let scheme = url.scheme?.lowercased() else { return }
            let domain = TrustStore.registrableDomain(for: host)
            // Insecure http can't be trusted (stays ephemeral) — explain, don't no-op.
            if scheme == "http" {
                showTrustToast(TrustToast(domain: domain, kind: .blockedInsecure))
                return
            }
            guard scheme == "https" else { return }   // non-web schemes: ignore
            // Decide from the state BEFORE mutating; the toast fires only on this
            // explicit action (never on revisits to an already-trusted site).
            let wasTrusted = TrustStore.shared.isTrusted(host: host)
            if wasTrusted {
                TrustStore.shared.untrust(host: host)
                browser.rebind(tab, to: url, persistent: false)
                showTrustToast(TrustToast(domain: domain, kind: .untrusting))
            } else {
                TrustStore.shared.trust(host: host)
                browser.rebind(tab, to: url, persistent: true)
                showTrustToast(TrustToast(domain: domain, kind: .trusting))
            }
        }
        // Addition 3: keyboard ⌘[ / ⌘] back/forward on the active tab's web view.
        .onReceive(NotificationCenter.default.publisher(for: .goBack)) { _ in
            let webView = browser.activeTab.webView
            if webView.canGoBack { webView.goBack() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goForward)) { _ in
            let webView = browser.activeTab.webView
            if webView.canGoForward { webView.goForward() }
        }
        // Slice 9a/9c — reload variants + open-surface commands (incl. ⌘⇧J →
        // downloads page), collapsed into one modifier to keep `body` within the
        // type-checker's budget.
        .modifier(BrowserCommandHandlers(browser: browser))
    }

    // MARK: - App-level back/forward input (mouse side buttons + ⌘[ / ⌘] aliases)

    /// Catch back/forward inputs at the app level (a local NSEvent monitor), so they
    /// drive the active tab's history regardless of which view holds focus:
    ///   • mouse side buttons — macOS numbers them 3 (back) / 4 (forward);
    ///   • ⌘[ / ⌘] — always-on keyboard aliases for back/forward. The *primary*
    ///     bindings are ⌘← / ⌘→ (registry-driven menu items, user-editable); ⌘[ / ⌘]
    ///     are hard-wired here, not editable and not shown as separate rows.
    /// Only navigates when possible; consumes the event (returns nil) when it does,
    /// otherwise passes it through unchanged.
    private func installMouseNavMonitor() {
        guard mouseNavMonitor == nil else { return }
        mouseNavMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp, .keyDown]) { event in
            let webView = browser.activeTab.webView
            if event.type == .keyDown {
                // Plain ⌘ + bracket only (⌘⇧[ etc. are left alone).
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      let ch = event.charactersIgnoringModifiers else { return event }
                if ch == "[", webView.canGoBack { webView.goBack(); return nil }
                if ch == "]", webView.canGoForward { webView.goForward(); return nil }
                return event
            }
            switch event.buttonNumber {
            case 3:
                if webView.canGoBack { webView.goBack(); return nil }
            case 4:
                if webView.canGoForward { webView.goForward(); return nil }
            default:
                break
            }
            return event
        }
    }

    private func removeMouseNavMonitor() {
        if let monitor = mouseNavMonitor {
            NSEvent.removeMonitor(monitor)
            mouseNavMonitor = nil
        }
    }

    /// The ⌘L overlay pre-fill: the current URL on a loaded web page, empty on the
    /// new-tab page and on internal surfaces (no URL to pre-fill).
    private var spotlightPrefill: String {
        let tab = browser.activeTab
        return (tab.kind == .web && tab.hasNavigated) ? tab.url.absoluteString : ""
    }

    /// Enter → navigate the current tab; ⌘Enter → open in a new foreground tab.
    private func navigate(_ url: URL, newTab: Bool) {
        if newTab {
            browser.openInNewTab(url)
        } else {
            browser.navigateActiveTab(to: url)   // internal pages give way to the web page
        }
    }

    /// Close the overlay with no navigation and return focus to the web content.
    private func closeSpotlight() {
        showSpotlight = false
        let webView = browser.activeTab.webView
        DispatchQueue.main.async { webView.window?.makeFirstResponder(webView) }
    }

    /// Dismiss the vault gate overlay; if a successful unlock just happened, open the vault surface.
    private func closeVault() {
        showVault = false
        if vault.isUnlocked { browser.openVaultPage() }
    }

    /// Show a trust toast with a slide/fade in; replacing any current one restarts
    /// its auto-dismiss timer (the overlay's `.task(id:)` is keyed by toast id).
    private func showTrustToast(_ toast: TrustToast) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            trustToast = toast
        }
    }

    /// Dismiss the toast. With `id`, only dismiss if that toast is still the one
    /// shown (so a stale auto-dismiss timer can't tear down a newer toast); the
    /// ✕/click path passes no id and always dismisses the current toast.
    private func dismissTrustToast(id: UUID? = nil) {
        if let id, trustToast?.id != id { return }
        withAnimation(.easeOut(duration: 0.25)) { trustToast = nil }
    }
}

#Preview {
    ContentView()
}
