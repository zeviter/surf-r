import XCTest
import SurfrCore
@testable import Surfr

/// The anti-leak guarantee, provable on demand. A credential is offerable ONLY on an exact
/// registrable-domain match over HTTPS — never to a look-alike, suffix-attack, or wrong scheme.
@MainActor
final class AutofillMatcherTests: XCTestCase {

    private func item(_ title: String, _ hosts: [String], modified: TimeInterval = 0) -> StoredItem {
        StoredItem(title: title, createdAt: Date(timeIntervalSince1970: 0),
                   modifiedAt: Date(timeIntervalSince1970: modified),
                   sealed: SealedItem(wrappedItemKey: Data(), ciphertext: Data()),
                   hosts: hosts.map { SurfrCore.Host(host: $0, isPrimary: true) })
    }

    private func offers(_ scheme: String, _ host: String, _ credHost: String) -> Bool {
        !AutofillMatcher.matches(scheme: scheme, host: host, items: [item("X", [credHost])]).isEmpty
    }

    func test_exactMatch_offers() {
        XCTAssertTrue(offers("https", "example.com", "example.com"))
    }

    func test_subdomain_accepted_bothDirections() {
        XCTAssertTrue(offers("https", "login.example.com", "example.com"))   // page subdomain
        XCTAssertTrue(offers("https", "example.com", "accounts.example.com")) // cred subdomain
        XCTAssertTrue(offers("https", "mail.example.com", "accounts.example.com"))
    }

    func test_lookalike_rejected() {
        XCTAssertFalse(offers("https", "evil-example.com", "example.com"))
        XCTAssertFalse(offers("https", "examp1e.com", "example.com"))         // typo squat
        XCTAssertFalse(offers("https", "example.org", "example.com"))         // different TLD
    }

    func test_suffixAttack_rejected() {
        // registrableDomain("example.com.evil.com") == "evil.com" ≠ "example.com" → no offer.
        XCTAssertFalse(offers("https", "example.com.evil.com", "example.com"))
        XCTAssertFalse(offers("https", "example.com.attacker.io", "example.com"))
    }

    func test_http_rejected() {
        XCTAssertFalse(offers("http", "example.com", "example.com"))
        XCTAssertFalse(offers(nil ?? "", "example.com", "example.com"))
    }

    func test_emptyOrNilHost_rejected() {
        XCTAssertTrue(AutofillMatcher.matches(scheme: "https", host: nil, items: [item("X", ["example.com"])]).isEmpty)
        XCTAssertTrue(AutofillMatcher.matches(scheme: "https", host: "", items: [item("X", ["example.com"])]).isEmpty)
    }

    func test_multiLabelETLD_isExact() {
        XCTAssertTrue(offers("https", "www.bbc.co.uk", "bbc.co.uk"))
        XCTAssertFalse(offers("https", "evil-bbc.co.uk", "bbc.co.uk"))
        // co.uk is a public suffix — two different orgs under it must NOT match.
        XCTAssertFalse(offers("https", "foo.co.uk", "bar.co.uk"))
    }

    func test_rankedByRecency() {
        let items = [item("Old", ["example.com"], modified: 100),
                     item("New", ["example.com"], modified: 999),
                     item("Mid", ["example.com"], modified: 500)]
        let titles = AutofillMatcher.matches(scheme: "https", host: "example.com", items: items).map(\.title)
        XCTAssertEqual(titles, ["New", "Mid", "Old"])
    }

    // The reported bug: page www.amazon.co.uk + a stored www./full-URL host must still match
    // amazon.co.uk (both sides reduce to the registrable domain).
    func test_normalizedHosts_match_butAntiLeakIntact() {
        XCTAssertTrue(offers("https", "www.amazon.co.uk", "www.amazon.co.uk"))
        XCTAssertTrue(offers("https", "www.amazon.co.uk", "https://www.amazon.co.uk/ap/signin?openid.return_to=x"))
        XCTAssertTrue(offers("https", "amazon.co.uk", "www.amazon.co.uk"))
        // A path that merely mentions the domain on a different host must NOT match.
        XCTAssertFalse(offers("https", "www.amazon.co.uk", "https://evil.com/amazon.co.uk"))
    }

    // The exact Barbican case: stored full URL with a NON-www subdomain AND a path, page on www.
    // Both reduce to barbican.org.uk → must match. (org.uk is a multi-label public suffix.)
    func test_barbican_subdomainPlusPathURL_matches() {
        XCTAssertTrue(offers("https", "www.barbican.org.uk", "https://tickets.barbican.org.uk/j348343jwjfn"))
        XCTAssertTrue(offers("https", "www.barbican.org.uk", "tickets.barbican.org.uk"))
        XCTAssertTrue(offers("https", "tickets.barbican.org.uk", "https://www.barbican.org.uk/"))
        // hostComponent extracts the subdomain host; registrableDomain reduces it to the org domain.
        XCTAssertEqual(TrustStore.hostComponent(from: "https://tickets.barbican.org.uk/j348343jwjfn"), "tickets.barbican.org.uk")
        XCTAssertEqual(TrustStore.registrableDomain(forHostOrURL: "https://tickets.barbican.org.uk/j348343jwjfn"), "barbican.org.uk")
        // Anti-leak intact: a different org under org.uk does NOT match.
        XCTAssertFalse(offers("https", "www.barbican.org.uk", "evil-barbican.org.uk"))
        XCTAssertFalse(offers("https", "www.barbican.org.uk", "https://tickets.othersite.org.uk/x"))
    }

    func test_hostsMatch_unit() {
        XCTAssertTrue(AutofillMatcher.hostsMatch("a.example.com", "b.example.com"))
        XCTAssertFalse(AutofillMatcher.hostsMatch("example.com", "evil-example.com"))
        XCTAssertFalse(AutofillMatcher.hostsMatch("", "example.com"))
    }
}
