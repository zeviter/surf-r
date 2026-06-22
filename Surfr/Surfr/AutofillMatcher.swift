import Foundation
import SurfrCore

/// Host matching for in-browser autofill — the anti-leak core. The single rule: a credential is
/// offerable **only** when the page frame's registrable domain (eTLD+1) **exactly equals** the
/// credential's. No fuzzy/substring/edit-distance matching, ever — that's how creds leak to
/// look-alikes. HTTPS-only. Pure + exhaustively unit-tested.
enum AutofillMatcher {

    /// True iff both hosts resolve to the same non-empty registrable domain (eTLD+1).
    static func hostsMatch(_ a: String, _ b: String) -> Bool {
        let da = TrustStore.registrableDomain(for: a).lowercased()
        let db = TrustStore.registrableDomain(for: b).lowercased()
        return !da.isEmpty && da == db
    }

    /// Credentials offerable for a frame's origin. Empty unless the scheme is `https` and the host's
    /// registrable domain matches at least one of a credential's hosts. Ranked by recency
    /// (`modifiedAt` desc) then title.
    static func matches(scheme: String?, host: String?, items: [StoredItem]) -> [StoredItem] {
        guard scheme?.lowercased() == "https", let host, !host.isEmpty else { return [] }
        let pageDomain = TrustStore.registrableDomain(for: host).lowercased()
        guard !pageDomain.isEmpty else { return [] }

        return items
            .filter { item in
                item.hosts.contains { TrustStore.registrableDomain(for: $0.host).lowercased() == pageDomain }
            }
            .sorted { a, b in
                if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
    }
}
