import Foundation
import SurfrCore

/// Host matching for in-browser autofill — the anti-leak core. The single rule: a credential is
/// offerable **only** when the page frame's registrable domain (eTLD+1) **exactly equals** the
/// credential's. No fuzzy/substring/edit-distance matching, ever — that's how creds leak to
/// look-alikes. HTTPS-only. Pure + exhaustively unit-tested.
enum AutofillMatcher {

    /// True iff both values resolve to the same non-empty registrable domain (eTLD+1). Both sides are
    /// normalized from host-or-URL, so a stored `www.` host or a full sign-in URL still matches.
    static func hostsMatch(_ a: String, _ b: String) -> Bool {
        let da = TrustStore.registrableDomain(forHostOrURL: a).lowercased()
        let db = TrustStore.registrableDomain(forHostOrURL: b).lowercased()
        return !da.isEmpty && da == db
    }

    /// Credentials offerable for a frame's origin. Empty unless the scheme is `https` and the host's
    /// registrable domain matches at least one of a credential's hosts. Both sides reduce to the
    /// registrable domain (stored hosts may be messy/imported URLs). Ranked by recency then title.
    static func matches(scheme: String?, host: String?, items: [StoredItem]) -> [StoredItem] {
        guard scheme?.lowercased() == "https", let host, !host.isEmpty else { return [] }
        let pageDomain = TrustStore.registrableDomain(forHostOrURL: host).lowercased()
        guard !pageDomain.isEmpty else { return [] }

        return items
            .filter { item in
                item.hosts.contains { TrustStore.registrableDomain(forHostOrURL: $0.host).lowercased() == pageDomain }
            }
            .sorted { a, b in
                if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
    }
}
