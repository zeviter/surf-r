import SwiftUI
import WebKit
import Combine
import AppKit

extension Notification.Name {
    /// Posted by the ⌘L menu command to focus the address bar.
    static let focusOmnibox = Notification.Name("focusOmnibox")
    /// Posted by the ⌘T menu command to open a new tab.
    static let newTab = Notification.Name("newTab")
    /// Posted by the ⌘W menu command to close the active tab.
    static let closeTab = Notification.Name("closeTab")
    /// Posted by the ⌘D menu command to bookmark/unbookmark the active tab's page.
    static let toggleBookmark = Notification.Name("toggleBookmark")
}

private let homeURL = URL(string: "https://duckduckgo.com")!

/// One browser tab. Owns its own `WKWebView` with an isolated `.nonPersistent()`
/// data store, so tabs never share cookies/cache, plus its own omnibox/URL state.
@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView

    @Published var title: String
    @Published var addressText: String
    @Published var url: URL

    /// True once this tab has completed a navigation to a real http(s) page.
    /// A tab that hasn't navigated and has no typed address text is "pristine".
    var hasNavigated = false
    /// Monotonic activation stamp; higher = more recently active (rail ordering).
    var activationOrder = 0

    private var observations: [NSKeyValueObservation] = []

    /// Sentinel URL for a blank/pristine tab that hasn't navigated anywhere.
    static let blankURL = URL(string: "about:blank")!

    /// A blank, pristine tab: builds an isolated web view but loads nothing, so it
    /// stays out of the rail until it navigates (see `BrowserState` pristine rule).
    convenience init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        let webView = WebContentView(frame: .zero, configuration: config)
        self.init(webView: webView, url: Self.blankURL, loadInitialRequest: false)
        self.addressText = ""   // pristine: empty omnibox, no typed text
    }

    /// A normal tab: builds its own isolated web view and loads `url`.
    convenience init(url: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // ← isolated per tab; no shared cookies/cache

        #if DEBUG
        // Restore the right-click "Inspect Element" item (opens Web Inspector in-app, no Safari).
        // Private preference set via KVC so the selector isn't statically linked; DEBUG-only.
        // Must be set before the web view snapshots its configuration.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        let webView = WebContentView(frame: .zero, configuration: config)
        self.init(webView: webView, url: url, loadInitialRequest: true)
    }

    /// A pop-up tab: adopts the web view WebKit created for an allowed `window.open`.
    /// WebKit drives the initial load itself, so we must not call `load`.
    convenience init(adopting webView: WKWebView, initialURL: URL?) {
        self.init(webView: webView, url: initialURL ?? homeURL, loadInitialRequest: false)
    }

    private init(webView: WKWebView, url: URL, loadInitialRequest: Bool) {
        self.webView = webView

        #if DEBUG
        // 2d: let Safari's Web Inspector attach to this tab. DEBUG-only — never in release.
        webView.isInspectable = true
        #endif

        // Apply the ad-blocking content rules to this tab (now or once compiled).
        ContentBlocker.shared.apply(to: webView)

        self.url = url
        self.addressText = url.absoluteString
        self.title = url.host() ?? "New Tab"

        // Keep the tab's title and omnibox in sync as the page navigates.
        // WebKit delivers these KVO callbacks on the main thread.
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

        if loadInitialRequest {
            webView.load(URLRequest(url: url))
        }
    }

    /// Load a parsed URL in this tab.
    func navigate(to newURL: URL) {
        url = newURL
        addressText = newURL.absoluteString
        webView.load(URLRequest(url: newURL))
    }
}

/// One host's tile in the rail: its favicon, tab count, and the most-recently
/// active tab to switch to when clicked (subdomain-aware — see ui-wireframes §2).
struct HostGroup: Identifiable {
    let host: String
    let tabCount: Int
    let representativeTabID: Tab.ID   // most-recently-active tab in this host
    let isActive: Bool               // contains the active tab
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

    /// Gates `window.open` pop-ups (F4) and handles JS dialogs for every tab.
    let popupGate = PopupGate()
    /// Records successful page loads into history (slice 1: data layer only).
    let historyRecorder = HistoryRecorder()
    /// Tracks the active tab's URL so the bookmark menu/title reflects its state.
    private var activeURLBinding: AnyCancellable?
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
        activationCounter = 1
        first.activationOrder = 1
        wire(first)
        bindActiveURL()
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

    /// Adopt an allowed pop-up as a new tab with its own isolated ephemeral store.
    /// Called by `PopupGate` from `createWebViewWith`; WebKit then drives its load.
    func adoptPopup(configuration: WKWebViewConfiguration, initialURL: URL?) -> WKWebView {
        configuration.websiteDataStore = .nonPersistent()   // isolate like every other tab
        #if DEBUG
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif
        let webView = WebContentView(frame: .zero, configuration: configuration)
        let tab = Tab(adopting: webView, initialURL: initialURL)
        tabs.append(tab)
        wire(tab)               // subscription marks it real (it already has a URL)
        activeTabID = tab.id
        return webView
    }

    // MARK: - Rail: grouping, ordering, pristine rule

    /// Mirror the active tab's current URL into `BookmarkState` (re-subscribing on
    /// every tab switch), so the bookmark command's title stays correct.
    private func bindActiveURL() {
        activeURLBinding = activeTab.$url.sink { url in
            MainActor.assumeIsolated { BookmarkState.shared.activeURL = url }
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
        // Discard the tab we just left if it's an untouched pristine tab.
        if previous != activeTabID,
           let prev = tabs.first(where: { $0.id == previous }), isPristine(prev) {
            discard(prev)
        }
        recomputeHostGroups()
    }

    /// Pristine = never navigated AND no typed-but-uncommitted address text. A tab
    /// with typed text is NOT pristine and is never discarded (text preserved).
    private func isPristine(_ tab: Tab) -> Bool {
        !tab.hasNavigated && tab.addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func discard(_ tab: Tab) {
        tabs.removeAll { $0.id == tab.id }
        tabURLBindings[tab.id] = nil
        railLog("pristine tab discarded")
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
                isActive: hostTabs.contains { $0.id == activeTabID }
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Skip blank/new-tab/about:blank and non-web schemes; record real pages only.
        guard let url = webView.url,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return }

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
    /// The active tab's current URL, so the menu title can reflect its state.
    @Published var activeURL: URL?

    /// Whether the active tab's page is bookmarked (drives the menu item title).
    var isActiveBookmarked: Bool {
        guard let activeURL else { return false }
        return bookmarkedURLs.contains(activeURL.absoluteString)
    }

    private init() {}

    /// Populate the mirror from the store; call once at launch.
    func load() async {
        bookmarkedURLs = Set(await BookmarkStore.shared.all().map(\.url))
    }

    /// Toggle the bookmark for a page; ignores blank/about:blank/non-web pages.
    func toggle(url: URL, title: String?) async {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return }
        let key = url.absoluteString
        if bookmarkedURLs.contains(key) {
            await BookmarkStore.shared.removeByURL(url)
            bookmarkedURLs.remove(key)
        } else {
            await BookmarkStore.shared.add(url: url, title: title)
            bookmarkedURLs.insert(key)
        }
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
struct OmniboxBar: View {
    @ObservedObject var tab: Tab
    @FocusState.Binding var focused: Bool

    var body: some View {
        TextField("Search DuckDuckGo or enter address", text: $tab.addressText)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit {
                guard let url = Omnibox.resolve(tab.addressText) else { return }
                tab.navigate(to: url)
                focused = false
            }
            .padding(8)
    }
}

/// One host tile in the rail: favicon (or letter-tile fallback), active highlight,
/// and a count badge when the host has ≥2 tabs. Clicking switches to the host's
/// most-recently-active tab.
struct FaviconTile: View {
    let host: String
    let isActive: Bool
    let tabCount: Int
    let onTap: () -> Void

    @State private var iconData: Data?

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
                Text(tabCount > 99 ? "99+" : "\(tabCount)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.blue))
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
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
struct RailView: View {
    @ObservedObject var browser: BrowserState
    /// Host whose tab flyout is currently open (nil = none). UI-only state.
    @State private var flyoutHost: String?

    var body: some View {
        VStack(spacing: 8) {
            // History — placeholder this slice; the full-page history view is later.
            Button {
                // TODO(history-view slice): open the full-page history view in a NEW tab.
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 16))
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)
            .help("History (not wired up yet)")

            // New tab — same behaviour as ⌘T.
            Button(action: browser.newTab) {
                Image(systemName: "plus")
                    .font(.system(size: 16))
                    .frame(width: 32, height: 28)
            }
            .buttonStyle(.plain)
            .help("New Tab (⌘T)")

            Divider().frame(width: 30)

            // Favicon stack — one tile per host, scrolls if it overflows.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(browser.hostGroups) { group in
                        FaviconTile(
                            host: group.host,
                            isActive: group.isActive,
                            tabCount: group.tabCount,
                            onTap: {
                                // Single-tab host switches directly; multi-tab opens the flyout.
                                if group.tabCount >= 2 {
                                    flyoutHost = group.host
                                } else {
                                    browser.activeTabID = group.representativeTabID
                                }
                            }
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
            Text("\(host) · \(count) tab\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

struct ContentView: View {
    @StateObject private var browser = BrowserState()
    @FocusState private var omniboxFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            RailView(browser: browser)
            Divider()
            VStack(spacing: 0) {
                OmniboxBar(tab: browser.activeTab, focused: $omniboxFocused)
                Divider()
                WebView(webView: browser.activeTab.webView)
                    .id(browser.activeTabID)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .task {
            // Compile the bundled seed ad-block list and apply it to every tab.
            await ContentBlocker.shared.prepare()
        }
        .task {
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
        .onReceive(NotificationCenter.default.publisher(for: .toggleBookmark)) { _ in
            let webView = browser.activeTab.webView
            guard let url = webView.url else { return }
            let title = webView.title
            Task { await BookmarkState.shared.toggle(url: url, title: title) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusOmnibox)) { _ in
            omniboxFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTab)) { _ in
            browser.newTab()
            omniboxFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeTab)) { _ in
            browser.closeTab(browser.activeTabID)
        }
    }
}

#Preview {
    ContentView()
}
