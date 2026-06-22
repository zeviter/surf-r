import Foundation

/// What to do with a credential captured at login submit (Slice 8b). Pure + unit-tested; the gate
/// supplies the already-decrypted existing creds for the page's registrable domain.
enum SaveDecision: Equatable {
    case noPrompt              // an identical credential already exists — say nothing
    case save                  // new credential for this site
    case update(itemID: UUID)  // same username, different password → offer to update that item
    case neverListed           // the site is on the per-site "never save" list

    /// Classify a captured `{username, password}` against existing creds (same registrable domain).
    static func classify(username: String, password: String,
                         existing: [(id: UUID, username: String, password: String)],
                         neverListed: Bool) -> SaveDecision {
        if neverListed { return .neverListed }
        // Belt-and-suspenders: if this exact password already exists for the host, it's a dup — never
        // re-offer a just-filled credential, even with an empty/different captured username (e.g. a
        // two-step page-2 capture). (Trade-off: a genuinely new account that REUSES an existing
        // password on the same site won't be offered — documented; password reuse is discouraged.)
        if existing.contains(where: { $0.password == password }) { return .noPrompt }
        if let match = existing.first(where: { $0.username == username }) { return .update(itemID: match.id) }
        return .save
    }
}
