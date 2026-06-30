import WebKit

/// Exact in-page match count via WebKit's **own** (private, undocumented) find counter — used only by the
/// find bar to show "3/17" so the number matches what the native find actually highlights (a JS DOM count
/// can't reconcile with WebKit's find on real web apps). These are methods on Apple's own `WKWebView`
/// (the WebKit framework you already link) — **not a dependency**. Fully defended: if the private selectors
/// are ever missing/renamed, or the callback never arrives, `count` returns `nil` and the find bar shows
/// no number (native highlighting + cycling still work). No injected JS, no page-world exposure.
@MainActor
final class WebFindCounter: NSObject {
    private var pending: CheckedContinuation<Int?, Never>?
    private var resolved = false

    /// `_WKFindOptions.CaseInsensitive` (bit 0) — we only want the total, case-insensitively.
    private static let caseInsensitive: UInt = 1
    private static let maxCount: UInt = 100_000   // cap; pages with more matches report this many

    private static let countSel = NSSelectorFromString("_countStringMatches:options:maxCount:")
    private static let setDelegateSel = NSSelectorFromString("_setFindDelegate:")

    /// Total matches, or `nil` if the private API is unavailable (caller then shows no count). A fresh
    /// instance per call avoids delegate races across overlapping keystrokes.
    func count(_ query: String, in webView: WKWebView) async -> Int? {
        guard !query.isEmpty else { return 0 }
        guard webView.responds(to: Self.countSel), webView.responds(to: Self.setDelegateSel) else { return nil }

        setFindDelegate(webView, self)
        let result: Int? = await withCheckedContinuation { cont in
            pending = cont
            invokeCount(webView, query)
            // Safety: if the delegate never calls back, don't hang the find bar.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.resolve(nil)
            }
        }
        setFindDelegate(webView, nil)   // stop being the find delegate
        return result
    }

    private func resolve(_ value: Int?) {
        guard !resolved else { return }
        resolved = true
        pending?.resume(returning: value)
        pending = nil
    }

    // MARK: - Private-method invocation via IMP (3-arg / primitive-arg calls Swift can't `perform`)

    private func invokeCount(_ webView: WKWebView, _ query: String) {
        guard let m = class_getInstanceMethod(type(of: webView), Self.countSel) else { resolve(nil); return }
        typealias Fn = @convention(c) (AnyObject, Selector, NSString, UInt, UInt) -> Void
        let fn = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        fn(webView, Self.countSel, query as NSString, Self.caseInsensitive, Self.maxCount)
    }

    private func setFindDelegate(_ webView: WKWebView, _ delegate: AnyObject?) {
        guard let m = class_getInstanceMethod(type(of: webView), Self.setDelegateSel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let fn = unsafeBitCast(method_getImplementation(m), to: Fn.self)
        fn(webView, Self.setDelegateSel, delegate)
    }

    // MARK: - _WKFindDelegate callbacks (called by WebKit via these exact selectors)

    @objc(_webView:didCountMatches:forString:)
    func _webView(_ webView: WKWebView, didCountMatches matches: UInt, forString string: String) {
        resolve(Int(matches))
    }

    @objc(_webView:didFailToFindString:)
    func _webView(_ webView: WKWebView, didFailToFindString string: String) {
        resolve(0)
    }
}
