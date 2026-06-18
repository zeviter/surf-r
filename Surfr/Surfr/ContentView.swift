import SwiftUI
import WebKit

extension Notification.Name {
    /// Posted by the ⌘L menu command to focus the address bar.
    static let focusOmnibox = Notification.Name("focusOmnibox")
}

/// SwiftUI wrapper around `WKWebView`. Loads `url` and reloads whenever it
/// changes. Uses a non-persistent data store so no cookies/cache hit disk.
struct WebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // ← no cookies/cache on disk
        let webView = WKWebView(frame: .zero, configuration: config)
        load(in: webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload when the requested URL actually changed.
        guard context.coordinator.loadedURL != url else { return }
        load(in: webView, context: context)
    }

    private func load(in webView: WKWebView, context: Context) {
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    final class Coordinator {
        var loadedURL: URL?
    }
}

struct ContentView: View {
    /// What the web view is currently loading.
    @State private var currentURL = URL(string: "https://duckduckgo.com")!
    /// The editable text in the address bar.
    @State private var addressText = "https://duckduckgo.com"
    @FocusState private var omniboxFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search DuckDuckGo or enter address", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .focused($omniboxFocused)
                .onSubmit(navigate)
                .padding(8)

            Divider()

            WebView(url: currentURL)
        }
        .frame(minWidth: 800, minHeight: 600)
        .onReceive(NotificationCenter.default.publisher(for: .focusOmnibox)) { _ in
            omniboxFocused = true
        }
    }

    /// Parse the address bar and load the result in the current window.
    private func navigate() {
        guard let url = Omnibox.resolve(addressText) else { return }
        currentURL = url
        addressText = url.absoluteString
        omniboxFocused = false
    }
}

#Preview {
    ContentView()
}
