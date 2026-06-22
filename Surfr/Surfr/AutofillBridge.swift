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
    /// Username-only fill for a two-step page-1 (no password sent to the page).
    static let fillUsernameInvocation = "return await __surfrFillUsername(username)"

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
    struct FrameContext { let frame: WKFrameInfo?; let scheme: String; let host: String; let hasPassword: Bool; let hasUsername: Bool }

    /// A fillable field's main-frame viewport rect + kind (8e) — GENERIC geometry, no vault data.
    struct FieldAnchor: Identifiable, Equatable {
        var id: String { kind }
        let kind: String   // "username" | "password"
        let x, y, w, h: Double
    }

    /// Drives the UI affordance (a login form matching some credential exists on this page).
    @Published private(set) var hasLoginForm = false
    /// Main-frame fillable-field anchors for the per-field key overlay (8e).
    @Published private(set) var fieldAnchors: [FieldAnchor] = []
    /// True while the page is scrolling — the native overlay hides (can't track async scroll smoothly).
    @Published private(set) var scrolling = false
    /// Field kinds surf-r just filled → their icons latch green ("we filled this", not auth state).
    @Published private(set) var filledFieldKinds: Set<String> = []

    private var contexts: [String: FrameContext] = [:]   // keyed by "scheme://host"; frame nil = main frame
    weak var webView: WKWebView?

    nonisolated func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        // WebKit delivers on the main thread.
        MainActor.assumeIsolated {
            let origin = message.frameInfo.securityOrigin
            let body = message.body as? [String: Any]
            // Save-on-submit (8b): the captured login credential — HTTPS only, native frame origin
            // (a page can't spoof its own origin). Routed to the shared save coordinator.
            switch body?["type"] as? String {
            case "submitted":
                guard origin.protocol == "https", !origin.host.isEmpty else { return }
                AutofillSaveCoordinator.shared.handleSubmit(
                    host: origin.host,
                    username: body?["username"] as? String ?? "",
                    password: body?["password"] as? String ?? "")
                return
            case "pageload":
                if message.frameInfo.isMainFrame { reset() }   // fresh load → clear green latch + stale anchors
                return
            case "scrolling":
                if message.frameInfo.isMainFrame { scrolling = true }
                return
            case "anchors":
                if message.frameInfo.isMainFrame { fieldAnchors = Self.parseAnchors(body); scrolling = false }
                return
            default:
                break   // "detected"
            }
            update(scheme: origin.protocol, host: origin.host,
                   hasPassword: body?["hasPassword"] as? Bool ?? false,
                   hasUsername: body?["hasUsername"] as? Bool ?? false,
                   frame: message.frameInfo.isMainFrame ? nil : message.frameInfo)
            // Only the main frame's anchors are in the overlay's coordinate space.
            if message.frameInfo.isMainFrame { fieldAnchors = Self.parseAnchors(body); scrolling = false }
        }
    }

    /// Fresh, on-demand detection at ⌘\ press — never relies on the last debounced observer scan
    /// (which races a dynamically-injected shadow-DOM login popup). Re-reads the main frame + any
    /// known subframes right now.
    func refreshDetection() async {
        guard let webView else { return }
        // Main frame — use the web view's own URL for the origin (authoritative, can't be spoofed).
        if let result = try? await webView.callAsyncJavaScript("return __surfrDetect()", arguments: [:], in: nil, contentWorld: AutofillBridge.world) as? [String: Any],
           let url = webView.url, let host = url.host, !host.isEmpty {
            update(scheme: url.scheme ?? "https", host: host,
                   hasPassword: result["hasPassword"] as? Bool ?? false,
                   hasUsername: result["hasUsername"] as? Bool ?? false, frame: nil)
        }
        // Known subframes captured by the push model.
        for ctx in contexts.values where ctx.frame != nil {
            guard let r = try? await webView.callAsyncJavaScript("return __surfrDetect()", arguments: [:], in: ctx.frame, contentWorld: AutofillBridge.world) as? [String: Any] else { continue }
            update(scheme: ctx.scheme, host: ctx.host,
                   hasPassword: r["hasPassword"] as? Bool ?? false,
                   hasUsername: r["hasUsername"] as? Bool ?? false, frame: ctx.frame)
        }
    }

    private func update(scheme: String, host: String, hasPassword: Bool, hasUsername: Bool, frame: WKFrameInfo?) {
        guard !host.isEmpty else { return }
        let key = "\(scheme)://\(host)"
        // Prefer the PASSWORD signal: when a username and a password field for the same origin live in
        // different frames (e.g. a same-origin login iframe), a later username-only report must not
        // overwrite the password context — that's exactly what mislabels a single-page login as
        // two-step. A bare "nothing here" report only clears a non-password context.
        if hasPassword {
            contexts[key] = FrameContext(frame: frame, scheme: scheme, host: host, hasPassword: true, hasUsername: hasUsername)
        } else if hasUsername {
            if contexts[key]?.hasPassword != true {
                contexts[key] = FrameContext(frame: frame, scheme: scheme, host: host, hasPassword: false, hasUsername: true)
            }
        } else if contexts[key]?.hasPassword != true {
            contexts.removeValue(forKey: key)
        }
        hasLoginForm = !contexts.isEmpty
    }

    /// Origins of frames that reported a login form — for diagnosing match misses.
    var detectedOrigins: [String] { contexts.values.map { "\($0.scheme)://\($0.host)" } }

    private static func parseAnchors(_ body: [String: Any]?) -> [FieldAnchor] {
        guard let raw = body?["anchors"] as? [[String: Any]] else { return [] }
        return raw.compactMap { d in
            guard let kind = d["kind"] as? String,
                  let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue,
                  let w = (d["w"] as? NSNumber)?.doubleValue, let h = (d["h"] as? NSNumber)?.doubleValue else { return nil }
            return FieldAnchor(kind: kind, x: x, y: y, w: w, h: h)
        }
    }

    func markFilled(_ kinds: Set<String>) { filledFieldKinds.formUnion(kinds) }

    /// Reset on navigation (stale frames/origins/anchors/green-state should not linger).
    func reset() {
        contexts.removeAll()
        hasLoginForm = false
        fieldAnchors = []
        scrolling = false
        filledFieldKinds = []
    }

    /// Matched credentials across detected login frames (deduped), each with the frame to fill (nil =
    /// main frame) and whether it's a username-only (two-step page-1) context. Password contexts rank
    /// first.
    func candidates(items: [StoredItem]) -> [(item: StoredItem, frame: WKFrameInfo?, usernameOnly: Bool)] {
        var out: [(StoredItem, WKFrameInfo?, Bool)] = []
        var seen = Set<UUID>()
        let ordered = contexts.values.sorted { $0.hasPassword && !$1.hasPassword }   // password contexts first
        for ctx in ordered {
            for item in AutofillMatcher.matches(scheme: ctx.scheme, host: ctx.host, items: items) where seen.insert(item.id).inserted {
                out.append((item, ctx.frame, !ctx.hasPassword))
            }
        }
        return out
    }

    /// Diagnostics for a match miss: the detected frame origins (→ registrable domain) vs the vault's
    /// credential domains, so a race (origin/items unsettled) is visible in the log.
    func matchDiagnostics(items: [StoredItem]) -> String {
        let detected = contexts.values.map { "\($0.scheme)://\($0.host)→\(TrustStore.registrableDomain(forHostOrURL: $0.host))" }
        let vault = Set(items.flatMap { $0.hosts.map { TrustStore.registrableDomain(forHostOrURL: $0.host) } }).sorted()
        return "detected=\(detected) vaultDomains=\(vault) items=\(items.count)"
    }

    /// Fill username + password into a specific origin-matched frame (nil = main frame). Returns the
    /// field kinds actually filled (→ their icons latch green).
    @discardableResult
    func fill(username: String, password: String, into frame: WKFrameInfo?) async -> Set<String> {
        guard let webView else { return [] }
        let result = try? await webView.callAsyncJavaScript(
            AutofillBridge.fillInvocation,
            arguments: ["username": username, "password": password],
            in: frame, contentWorld: AutofillBridge.world)
        return Self.filledKinds(from: result)
    }

    /// Fill ONLY the username (two-step page-1) — no password sent to the page.
    @discardableResult
    func fillUsername(_ username: String, into frame: WKFrameInfo?) async -> Set<String> {
        guard let webView else { return [] }
        let result = try? await webView.callAsyncJavaScript(
            AutofillBridge.fillUsernameInvocation,
            arguments: ["username": username],
            in: frame, contentWorld: AutofillBridge.world)
        return Self.filledKinds(from: result)
    }

    private static func filledKinds(from result: Any?) -> Set<String> {
        guard let d = result as? [String: Any] else { return [] }
        var kinds = Set<String>()
        if d["filledUsername"] as? Bool == true { kinds.insert("username") }
        if d["filledPassword"] as? Bool == true { kinds.insert("password") }
        return kinds
    }
}
