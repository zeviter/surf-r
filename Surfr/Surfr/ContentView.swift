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

    private var observations: [NSKeyValueObservation] = []

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
                guard let u = webView.url else { return }
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

/// Holds the open tabs and which one is active.
@MainActor
final class BrowserState: ObservableObject {
    @Published var tabs: [Tab]
    @Published var activeTabID: Tab.ID { didSet { bindActiveURL() } }

    /// Gates `window.open` pop-ups (F4) and handles JS dialogs for every tab.
    let popupGate = PopupGate()
    /// Records successful page loads into history (slice 1: data layer only).
    let historyRecorder = HistoryRecorder()
    /// Tracks the active tab's URL so the bookmark menu/title reflects its state.
    private var activeURLBinding: AnyCancellable?

    init() {
        let first = Tab(url: homeURL)
        tabs = [first]
        activeTabID = first.id
        popupGate.browser = self
        wire(first)
        bindActiveURL()
    }

    /// Mirror the active tab's current URL into `BookmarkState` (re-subscribing on
    /// every tab switch), so the bookmark command's title stays correct.
    private func bindActiveURL() {
        activeURLBinding = activeTab.$url.sink { url in
            MainActor.assumeIsolated { BookmarkState.shared.activeURL = url }
        }
    }

    var activeTab: Tab {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    func newTab() {
        let tab = Tab(url: homeURL)
        tabs.append(tab)
        activeTabID = tab.id
        wire(tab)
    }

    /// Close a tab; if it was the last one, keep the window alive with a fresh tab.
    func closeTab(_ id: Tab.ID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if tabs.isEmpty {
            let tab = Tab(url: homeURL)
            tabs = [tab]
            activeTabID = tab.id
            wire(tab)
        } else if activeTabID == id {
            activeTabID = tabs[min(idx, tabs.count - 1)].id
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
        activeTabID = tab.id
        wire(tab)
        return webView
    }

    /// Route a tab's pop-up/dialog callbacks through the shared gate, and its
    /// navigation events through the history recorder.
    private func wire(_ tab: Tab) {
        tab.webView.uiDelegate = popupGate
        tab.webView.navigationDelegate = historyRecorder
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

/// A single entry in the tab bar: title + close button, click to activate.
struct TabButton: View {
    @ObservedObject var tab: Tab
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.title)
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(isActive ? Color(nsColor: .selectedControlColor) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }
}

struct TabBar: View {
    @ObservedObject var browser: BrowserState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(browser.tabs) { tab in
                    TabButton(
                        tab: tab,
                        isActive: tab.id == browser.activeTabID,
                        select: { browser.activeTabID = tab.id },
                        close: { browser.closeTab(tab.id) }
                    )
                    Divider()
                }
                Button(action: browser.newTab) {
                    Image(systemName: "plus")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 30)
    }
}

struct ContentView: View {
    @StateObject private var browser = BrowserState()
    @FocusState private var omniboxFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TabBar(browser: browser)
            Divider()
            OmniboxBar(tab: browser.activeTab, focused: $omniboxFocused)
            Divider()
            WebView(webView: browser.activeTab.webView)
                .id(browser.activeTabID)
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
