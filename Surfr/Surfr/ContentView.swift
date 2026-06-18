import SwiftUI
import WebKit
import Combine

extension Notification.Name {
    /// Posted by the ⌘L menu command to focus the address bar.
    static let focusOmnibox = Notification.Name("focusOmnibox")
    /// Posted by the ⌘T menu command to open a new tab.
    static let newTab = Notification.Name("newTab")
    /// Posted by the ⌘W menu command to close the active tab.
    static let closeTab = Notification.Name("closeTab")
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

    init(url: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // ← isolated per tab; no shared cookies/cache

        #if DEBUG
        // Restore the right-click "Inspect Element" item (opens Web Inspector in-app, no Safari).
        // Private preference set via KVC so the selector isn't statically linked; DEBUG-only.
        // Must be set before the web view snapshots its configuration.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        webView = WKWebView(frame: .zero, configuration: config)

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

        webView.load(URLRequest(url: url))
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
    @Published var activeTabID: Tab.ID

    init() {
        let first = Tab(url: homeURL)
        tabs = [first]
        activeTabID = first.id
    }

    var activeTab: Tab {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    func newTab() {
        let tab = Tab(url: homeURL)
        tabs.append(tab)
        activeTabID = tab.id
    }

    /// Close a tab; if it was the last one, keep the window alive with a fresh tab.
    func closeTab(_ id: Tab.ID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if tabs.isEmpty {
            let tab = Tab(url: homeURL)
            tabs = [tab]
            activeTabID = tab.id
        } else if activeTabID == id {
            activeTabID = tabs[min(idx, tabs.count - 1)].id
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
