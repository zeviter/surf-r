import XCTest
import WebKit
@testable import Surfr

/// Deterministic, repeatable proof that the injected fill writes ONLY visible fields — the
/// hidden-field trap stays empty. Loads the real `Autofill.js` + the fixture into a WKWebView with an
/// `https://example.com` origin, runs `__surfrFill`, and asserts the outcome.
@MainActor
final class AutofillFillTests: XCTestCase {

    private var repoFile: (String) -> URL {
        // .../Surfr/SurfrTests/AutofillFillTests.swift → repo paths.
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()      // SurfrTests
        let surfrDir = testsDir.deletingLastPathComponent().appendingPathComponent("Surfr") // Surfr/Surfr
        return { surfrDir.appendingPathComponent($0) }
    }

    func test_fillsVisibleFieldsOnly_trapsStayEmpty() async throws {
        let js = try String(contentsOf: repoFile("Autofill.js"), encoding: .utf8)
        let html = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/autofill_fixture.html"), encoding: .utf8)

        let world = WKContentWorld.world(name: "TestAutofill")
        let config = WKWebViewConfiguration()
        // The script early-returns unless the `surfrAutofill` handler exists in its world — register a
        // no-op so it proceeds and defines __surfrFill.
        config.userContentController.add(NoopHandler(), contentWorld: world, name: "surfrAutofill")
        config.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))

        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 400), configuration: config)
        let delegate = NavDelegate()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/login")!)
        await delegate.waitForFinish()

        _ = try await webView.callAsyncJavaScript(
            "return await __surfrFill(username, password)",
            arguments: ["username": "alice@example.com", "password": "s3cretP@ss"],
            in: nil, contentWorld: world)

        func value(_ id: String) async throws -> String {
            (try await webView.evaluateJavaScript("document.getElementById('\(id)').value", in: nil, contentWorld: world) as? String) ?? "<nil>"
        }

        let pass = try await value("pass")
        let user = try await value("user")
        let trapDisplayNone = try await value("trap-displaynone")
        let trapOffscreen = try await value("trap-offscreen")
        let trapHidden = try await value("trap-hidden")
        XCTAssertEqual(pass, "s3cretP@ss", "visible password filled")
        XCTAssertEqual(user, "alice@example.com", "visible username filled")
        XCTAssertEqual(trapDisplayNone, "", "display:none trap must stay empty")
        XCTAssertEqual(trapOffscreen, "", "off-screen trap must stay empty")
        XCTAssertEqual(trapHidden, "", "hidden trap must stay empty")
    }
}

private final class NoopHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {}
}

private final class NavDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume(); continuation = nil
    }
    func waitForFinish() async {
        if finished { return }
        await withCheckedContinuation { continuation = $0 }
    }
}
