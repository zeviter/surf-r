import XCTest
@testable import SurfrCore

/// Slice 10-1 — the relocated, shared autofill core: `LoginPayload` (now deterministic `.sortedKeys`,
/// backward-compatible decode) and the pure `RegistrableDomain` eTLD+1 logic moved out of the app's
/// `TrustStore`. Pure + headless; proves the move is behaviour-preserving.
final class LoginPayloadAndDomainTests: XCTestCase {

    // MARK: LoginPayload

    func test_loginPayload_roundTrips() throws {
        let p = LoginPayload(username: "u", password: "p", notes: "n", totp: "otpauth://x",
                             urls: ["https://example.com"], custom: ["k": "v"])
        XCTAssertEqual(try LoginPayload.decoded(from: p.encoded()), p)
    }

    /// `.sortedKeys` makes encoding a pure function of the value — including the unordered `custom`
    /// dictionary — so a no-op re-seal yields identical bytes (the re-seal-churn fix).
    func test_loginPayload_encodingIsDeterministic_acrossManyKeys() throws {
        let p = LoginPayload(username: "u", password: "p",
                             custom: ["z": "1", "a": "2", "m": "3", "b": "4", "y": "5"])
        let first = try p.encoded()
        for _ in 0..<20 { XCTAssertEqual(try p.encoded(), first, "encoding must be byte-stable") }
    }

    /// Decoding is content-based: JSON written by the OLD bare encoder (arbitrary key order, optional keys
    /// absent) still decodes — so pre-existing stored logins keep decrypting after the `.sortedKeys` change.
    func test_loginPayload_decodesLegacyUnsortedBytes_noMigration() throws {
        let legacy = #"{"urls":["https://x.com"],"password":"p","notes":"","username":"u","custom":{}}"#
        let p = try LoginPayload.decoded(from: Data(legacy.utf8))
        XCTAssertEqual(p.username, "u")
        XCTAssertEqual(p.password, "p")
        XCTAssertEqual(p.urls, ["https://x.com"])
        XCTAssertNil(p.totp)                 // absent optional → nil, not a decode failure
        XCTAssertNil(p.passwordChangedAt)
    }

    // MARK: RegistrableDomain (moved out of TrustStore; same behaviour)

    func test_registrableDomain_basicsAndMultiLabelETLD() {
        XCTAssertEqual(RegistrableDomain.registrableDomain(for: "www.example.com"), "example.com")
        XCTAssertEqual(RegistrableDomain.registrableDomain(for: "www.bbc.co.uk"), "bbc.co.uk")   // multi-label public suffix
        XCTAssertEqual(RegistrableDomain.registrableDomain(forHostOrURL: "https://tickets.barbican.org.uk/abc"),
                       "barbican.org.uk")
    }

    func test_hostComponent_stripsSchemePortPathUserinfo() {
        XCTAssertEqual(RegistrableDomain.hostComponent(from: "https://user@www.example.com:8443/path?q=1"),
                       "www.example.com")
        XCTAssertEqual(RegistrableDomain.hostComponent(from: "example.com"), "example.com")
    }

    func test_primaryLabel() {
        XCTAssertEqual(RegistrableDomain.primaryLabel(forDomain: "google.com"), "Google")
        XCTAssertEqual(RegistrableDomain.primaryLabel(forDomain: "example.co.uk"), "Example")
    }

    /// Anti-leak via the moved matcher: exact registrable-domain match over HTTPS only.
    func test_matcher_exactMatchOnly_overHTTPS() {
        let item = StoredItem(title: "X", createdAt: Date(timeIntervalSince1970: 0),
                              modifiedAt: Date(timeIntervalSince1970: 0),
                              sealed: SealedItem(wrappedItemKey: Data(), ciphertext: Data()),
                              hosts: [Host(host: "example.com", isPrimary: true)])
        XCTAssertFalse(AutofillMatcher.matches(scheme: "https", host: "example.com", items: [item]).isEmpty)
        XCTAssertTrue(AutofillMatcher.matches(scheme: "http", host: "example.com", items: [item]).isEmpty)   // not https
        XCTAssertTrue(AutofillMatcher.matches(scheme: "https", host: "evil-example.com", items: [item]).isEmpty) // look-alike
    }
}
