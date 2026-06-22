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

// MARK: - Username-first (8c) detection weighting

extension AutofillFillTests {
    private static let testWorld = WKContentWorld.world(name: "TestAutofill")

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    /// Load a fixture at a given origin with the real Autofill.js in the isolated world; wait for the
    /// load + the first detection message.
    private func load(_ fixture: String, at baseURL: String) async throws -> (WKWebView, CapturingHandler) {
        let js = try String(contentsOf: repoFile("Autofill.js"), encoding: .utf8)
        let html = try String(contentsOf: fixtureURL(fixture), encoding: .utf8)
        let config = WKWebViewConfiguration()
        let handler = CapturingHandler()
        config.userContentController.add(handler, contentWorld: Self.testWorld, name: "surfrAutofill")
        config.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.testWorld))
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 400), configuration: config)
        let delegate = NavDelegate()
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: baseURL)!)
        await delegate.waitForFinish()
        for _ in 0..<50 where handler.lastDetected == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        return (webView, handler)
    }

    private func emailValue(_ webView: WKWebView) async throws -> String {
        (try await webView.evaluateJavaScript("document.getElementById('email').value", in: nil, contentWorld: Self.testWorld) as? String) ?? "<nil>"
    }

    /// STRONG signal (autocomplete=username) → detected + filled, regardless of URL.
    func test_usernameFirst_strong_detectsAndFills() async throws {
        let (webView, handler) = try await load("autofill_username_first.html", at: "https://example.com/")
        XCTAssertEqual(handler.lastDetected?["hasUsername"] as? Bool, true)
        XCTAssertEqual(handler.lastDetected?["hasPassword"] as? Bool, false)
        _ = try await webView.callAsyncJavaScript("return await __surfrFillUsername(username)",
                                                  arguments: ["username": "alice@example.com"], in: nil, contentWorld: Self.testWorld)
        let value = try await emailValue(webView)
        XCTAssertEqual(value, "alice@example.com")
    }

    /// WEAK signal (bare type=email) + login URL context → detected + filled.
    func test_weakEmail_withLoginContext_detects() async throws {
        let (webView, handler) = try await load("autofill_email_form.html", at: "https://example.com/account/login")
        XCTAssertEqual(handler.lastDetected?["hasUsername"] as? Bool, true, "bare email at a /login URL is corroborated")
        _ = try await webView.callAsyncJavaScript("return await __surfrFillUsername(username)",
                                                  arguments: ["username": "bob@example.com"], in: nil, contentWorld: Self.testWorld)
        let value = try await emailValue(webView)
        XCTAssertEqual(value, "bob@example.com")
    }

    /// The Barbican class of bug: a login popup whose fields live in an OPEN shadow root. Detection
    /// must pierce the shadow root and see the password → single-page (hasPassword, NOT username-first)
    /// → __surfrFill fills both shadow fields.
    func test_shadowDomLogin_detectedAsSinglePage_andFills() async throws {
        let (webView, handler) = try await load("autofill_shadow_login.html", at: "https://example.com/")
        XCTAssertEqual(handler.lastDetected?["hasPassword"] as? Bool, true, "password in shadow root must be detected")
        XCTAssertEqual(handler.lastDetected?["hasUsername"] as? Bool, false, "single-page, not two-step")
        _ = try await webView.callAsyncJavaScript("return await __surfrFill(username, password)",
                                                  arguments: ["username": "carol", "password": "sh4dowP@ss"], in: nil, contentWorld: Self.testWorld)
        let pass = (try await webView.evaluateJavaScript(
            "document.querySelector('login-popup').shadowRoot.getElementById('spass').value", in: nil, contentWorld: Self.testWorld) as? String) ?? "<nil>"
        let user = (try await webView.evaluateJavaScript(
            "document.querySelector('login-popup').shadowRoot.getElementById('suser').value", in: nil, contentWorld: Self.testWorld) as? String) ?? "<nil>"
        XCTAssertEqual(pass, "sh4dowP@ss")
        XCTAssertEqual(user, "carol")

        // On-demand detection (the ⌘\-at-press path) sees the shadow password too — same snapshot.
        let onDemand = try await webView.callAsyncJavaScript("return __surfrDetect()", arguments: [:], in: nil, contentWorld: Self.testWorld) as? [String: Any]
        XCTAssertEqual(onDemand?["hasPassword"] as? Bool, true)
        XCTAssertEqual(onDemand?["hasUsername"] as? Bool, false)
    }

    /// The Barbican "closed popup" bug: a shadow-DOM login whose host is display:none (popup closed but
    /// not removed). Composed-tree visibility must treat the fields as not present → no detection, and
    /// __surfrFill targets nothing (the shadow password stays empty). State 3 behaves like state 1.
    func test_shadowLogin_hiddenHost_offersAndFillsNothing() async throws {
        let (webView, handler) = try await load("autofill_shadow_hidden.html", at: "https://example.com/")
        XCTAssertEqual(handler.lastDetected?["hasPassword"] as? Bool, false, "hidden shadow host → no password field present")
        XCTAssertEqual(handler.lastDetected?["hasUsername"] as? Bool, false)
        _ = try await webView.callAsyncJavaScript("return await __surfrFill(username, password)",
                                                  arguments: ["username": "x", "password": "leak"], in: nil, contentWorld: Self.testWorld)
        let pass = (try await webView.evaluateJavaScript(
            "document.querySelector('login-popup').shadowRoot.getElementById('spass').value", in: nil, contentWorld: Self.testWorld) as? String) ?? "<nil>"
        XCTAssertEqual(pass, "", "must never fill a hidden shadow field")
    }

    /// Security regression guard: a home page with a "Log in" BUTTON + a search box (no actual login
    /// form) must NOT be treated as a login — host match alone must never offer/fill. Detection reports
    /// neither field, and __surfrFillUsername fills nothing (the search box stays empty).
    func test_homePage_loginButtonAndSearch_offersAndFillsNothing() async throws {
        let (webView, handler) = try await load("autofill_home_no_form.html", at: "https://www.barbican.org.uk/")
        XCTAssertEqual(handler.lastDetected?["hasPassword"] as? Bool, false)
        XCTAssertEqual(handler.lastDetected?["hasUsername"] as? Bool, false, "a Log in button + search box is NOT a login form")
        _ = try await webView.callAsyncJavaScript("return await __surfrFillUsername(username)",
                                                  arguments: ["username": "victim@example.com"], in: nil, contentWorld: Self.testWorld)
        let search = (try await webView.evaluateJavaScript("document.getElementById('search').value", in: nil, contentWorld: Self.testWorld) as? String) ?? "<nil>"
        XCTAssertEqual(search, "", "the search box must never receive a credential")
    }

    /// The proof of conservatism: the SAME bare-email markup as a newsletter (no login context) must
    /// NOT be treated as a login — no detection, and __surfrFillUsername fills nothing.
    func test_newsletter_noContext_doesNotDetectOrFill() async throws {
        let (webView, handler) = try await load("autofill_email_form.html", at: "https://shop.example.com/")
        XCTAssertEqual(handler.lastDetected?["hasUsername"] as? Bool, false, "newsletter email must not count as a login")
        _ = try await webView.callAsyncJavaScript("return await __surfrFillUsername(username)",
                                                  arguments: ["username": "spam@example.com"], in: nil, contentWorld: Self.testWorld)
        let value = try await emailValue(webView)
        XCTAssertEqual(value, "", "newsletter field must stay empty")
    }
}

private final class CapturingHandler: NSObject, WKScriptMessageHandler {
    private(set) var lastDetected: [String: Any]?
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            if let body = message.body as? [String: Any], body["type"] as? String == "detected" {
                lastDetected = body
            }
        }
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
