import WebKit
import Combine
import SurfrCore

/// Wires the autofill user script + message handler into a web view, in a dedicated **isolated
/// content world**. This isolation is the keystone control: the page world cannot see, override, or
/// post to our handler — `addScriptMessageHandler(_:contentWorld:name:)` exposes the handler only
/// inside `world`, and the user script's globals (incl. `__surfrFill`) live only there.
enum AutofillBridge {
    static let messageName = "surfrAutofill"
    static let world = WKContentWorld.world(name: "SurfrAutofill")

    /// `__surfrFill` is defined by the user script in `world`; native calls it with safely-passed
    /// arguments (never string-interpolated — no injection, nothing to log).
    static let fillInvocation = "return await __surfrFill(username, password)"

    static let userScriptSource: String = {
        guard let url = Bundle.main.url(forResource: "Autofill", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Autofill.js missing from the app bundle")
        }
        return source
    }()

    static func install(on webView: WKWebView, handler: WKScriptMessageHandler) {
        let ucc = webView.configuration.userContentController
        ucc.addUserScript(WKUserScript(source: userScriptSource, injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false, in: world))
        ucc.add(handler, contentWorld: world, name: messageName)
    }
}

/// Per-tab autofill state: tracks which frames reported a login form (by their **native** origin —
/// never the page-reported string, so a page can't spoof its own origin), matches them to vault
/// credentials, and performs the fill into the matched-origin frame.
@MainActor
final class AutofillController: NSObject, ObservableObject, WKScriptMessageHandler {
    struct FrameContext { let frame: WKFrameInfo; let scheme: String; let host: String }

    /// Drives the UI affordance (a login form matching some credential exists on this page).
    @Published private(set) var hasLoginForm = false

    private var contexts: [String: FrameContext] = [:]   // keyed by "scheme://host"
    weak var webView: WKWebView?

    nonisolated func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit delivers on the main thread.
        MainActor.assumeIsolated {
            let origin = message.frameInfo.securityOrigin
            let hasPassword = (message.body as? [String: Any])?["hasPassword"] as? Bool ?? false
            update(scheme: origin.protocol, host: origin.host, hasPassword: hasPassword, frame: message.frameInfo)
        }
    }

    private func update(scheme: String, host: String, hasPassword: Bool, frame: WKFrameInfo) {
        guard !host.isEmpty else { return }
        let key = "\(scheme)://\(host)"
        if hasPassword {
            contexts[key] = FrameContext(frame: frame, scheme: scheme, host: host)
        } else {
            contexts.removeValue(forKey: key)
        }
        hasLoginForm = !contexts.isEmpty
    }

    /// Reset on navigation (stale frames/origins should not linger).
    func reset() {
        contexts.removeAll()
        hasLoginForm = false
    }

    /// Matched credentials across detected login frames (deduped), each paired with the frame to fill.
    func candidates(items: [StoredItem]) -> [(item: StoredItem, frame: WKFrameInfo)] {
        var out: [(StoredItem, WKFrameInfo)] = []
        var seen = Set<UUID>()
        for ctx in contexts.values {
            for item in AutofillMatcher.matches(scheme: ctx.scheme, host: ctx.host, items: items) where seen.insert(item.id).inserted {
                out.append((item, ctx.frame))
            }
        }
        return out
    }

    /// Fill into a specific origin-matched frame, in the isolated world.
    func fill(username: String, password: String, into frame: WKFrameInfo) async {
        guard let webView else { return }
        _ = try? await webView.callAsyncJavaScript(
            AutofillBridge.fillInvocation,
            arguments: ["username": username, "password": password],
            in: frame, contentWorld: AutofillBridge.world)
    }
}
