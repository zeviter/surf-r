import Foundation

// MARK: - Health flags (per-item intrinsic signals; the bitfield stored in items.health_flags)

/// Per-item intrinsic health signals, persisted as the `items.health_flags` bitfield (vault-spec §6,
/// Slice 9). **Reused is deliberately NOT here** — reuse is a *relationship between items*, derived on
/// read by grouping `audit_cache` reuse tokens (`AuditEngine.reusedItemIDs`), never decryption.
///
/// All four flags are computed at save / edit / import / backfill (when the plaintext is in hand) and
/// then read with **zero decryption** by both the Security Check surface and the WF-4 list badges.
public struct HealthFlags: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The stored password is short or low-entropy (`AuditEngine.isWeak`).
    public static let weak           = HealthFlags(rawValue: 1 << 0)
    /// The site supports TOTP (bundled 2FA Directory) but this item has no stored one-time code.
    public static let twoFAAvailable = HealthFlags(rawValue: 1 << 1)
    /// This item already carries a TOTP seed.
    public static let hasTOTP        = HealthFlags(rawValue: 1 << 2)
    /// The item's host is empty / unresolvable (messy import, e.g. `sn`) — "needs attention".
    public static let junkHost       = HealthFlags(rawValue: 1 << 3)
}

// MARK: - AuditEngine (pure classification; no keys, no PSL, no I/O — fully unit-testable)

/// The pure policy core for the vault Security Check (vault-spec §10 WF-9). It owns the three signal
/// definitions (weak · reused · 2FA-available) plus junk-host classification, as side-effect-free
/// functions. Keyed derivations (the reuse token / audit key) live in `VaultCrypto`; registrable-domain
/// resolution (PSL) lives in the app and is passed in already-resolved — so this type stays headless.
public enum AuditEngine {

    // MARK: Weak — reuse the generator's entropy math (length × log2(observed pool)); no zxcvbn.

    /// Below this many bits ⇒ weak (one of the two weak triggers). Tunable constant.
    public static let weakBitsThreshold = 50.0
    /// Shorter than this ⇒ weak regardless of computed entropy. Tunable constant.
    public static let weakMinLength = 8

    /// Canonical bytes a password is hashed/compared as: NFC-normalised UTF-8 (matching `deriveKEK`),
    /// so two visually identical passwords produce the same reuse token. No trimming — a leading space
    /// is a genuinely different password.
    public static func normalizedPasswordData(_ password: String) -> Data {
        Data(password.precomposedStringWithCanonicalMapping.utf8)
    }

    /// Observed-entropy estimate with the **same** formula the Slice-6 generator uses
    /// (`length × log2(poolSize)`), where the pool is the sum of the character-class sizes actually
    /// present in the password. Deliberately simple and structural — not a zxcvbn dictionary estimate.
    /// Empty ⇒ 0.
    public static func observedEntropyBits(for password: String) -> Double {
        guard !password.isEmpty else { return 0 }
        var hasLower = false, hasUpper = false, hasDigit = false, hasSymbol = false, hasOther = false
        for s in password.unicodeScalars {
            switch s {
            case "a"..."z": hasLower = true
            case "A"..."Z": hasUpper = true
            case "0"..."9": hasDigit = true
            default: if s.isASCII { hasSymbol = true } else { hasOther = true }
            }
        }
        var pool = 0
        if hasLower  { pool += 26 }
        if hasUpper  { pool += 26 }
        if hasDigit  { pool += 10 }
        if hasSymbol { pool += 33 }    // count of printable ASCII punctuation + space
        if hasOther  { pool += 100 }   // coarse bucket for non-ASCII (accented/emoji/CJK)
        guard pool > 1 else { return 0 }
        return Double(password.count) * log2(Double(pool))
    }

    /// Weak iff **too short OR below the entropy floor**. An empty password (e.g. a TOTP-only item) is
    /// **not** weak — there is no password to be weak. Pure + boundary-tested.
    public static func isWeak(password: String) -> Bool {
        guard !password.isEmpty else { return false }
        if password.count < weakMinLength { return true }
        return observedEntropyBits(for: password) < weakBitsThreshold
    }

    // MARK: Reused — group opaque keyed tokens; an item is reused iff its token appears on ≥2 items.

    /// Item IDs whose reuse token is shared by **≥2** items (i.e. the password is reused). Items absent
    /// from the map (no password ⇒ no token) are ignored. Operates only on opaque keyed tokens — never
    /// a password, never decryption.
    public static func reusedItemIDs<ID: Hashable>(tokensByItem: [ID: Data]) -> Set<ID> {
        let counts = tokenCounts(tokensByItem)
        return Set(tokensByItem.filter { counts[$0.value, default: 0] >= 2 }.keys)
    }

    /// How many items share each item's password (including itself): `1` = unique, `N` = shared with
    /// `N-1` others. Drives the "shares a password with N others" copy without revealing the password.
    public static func reuseGroupSizes<ID: Hashable>(tokensByItem: [ID: Data]) -> [ID: Int] {
        let counts = tokenCounts(tokensByItem)
        return tokensByItem.mapValues { counts[$0, default: 1] }
    }

    /// Reuse **clusters** for the grouped UI: each returned array is the set of item IDs that share one
    /// password (groups of ≥2 only). Members are sorted within a cluster and clusters are ordered
    /// deterministically, so the result is stable (the UI re-sorts for display). The grouping key (the
    /// opaque token) never leaves this function — only the clustered IDs do, never the password.
    public static func reuseClusters<ID>(tokensByItem: [ID: Data], idOrder: (ID, ID) -> Bool) -> [[ID]]
        where ID: Hashable {
        var byToken: [Data: [ID]] = [:]
        for (id, token) in tokensByItem { byToken[token, default: []].append(id) }
        let clusters = byToken.values
            .filter { $0.count >= 2 }
            .map { $0.sorted(by: idOrder) }
        return clusters.sorted { a, b in
            if a.count != b.count { return a.count > b.count }       // larger clusters first
            guard let x = a.first, let y = b.first else { return false }
            return idOrder(x, y)
        }
    }

    private static func tokenCounts<ID: Hashable>(_ tokensByItem: [ID: Data]) -> [Data: Int] {
        var counts: [Data: Int] = [:]
        for token in tokensByItem.values { counts[token, default: 0] += 1 }
        return counts
    }

    // MARK: 2FA-available — set membership against the bundled snapshot; honesty: absence ≠ "no 2FA".

    /// 2FA-available iff the site supports TOTP (any of the item's already-resolved registrable domains
    /// is in `totpDomains`) **and** the item has no stored TOTP seed. The caller resolves domains via
    /// the same PSL resolver the trust model uses; absence from the dataset is **not** proof the site
    /// lacks 2FA (disclosed in the UI).
    public static func is2FAAvailable(registrableDomains: [String], hasTOTP: Bool, totpDomains: Set<String>) -> Bool {
        guard !hasTOTP else { return false }
        return registrableDomains.contains { totpDomains.contains($0.lowercased()) }
    }

    // MARK: Non-login recognition — LastPass exports Secure Notes / Cards / Addresses with host "sn".

    /// `sn` is LastPass's secure-note URL marker (`url=http://sn`) — Secure Notes, Credit Cards, and
    /// Addresses all export this way. It is a **non-login** marker, never a junk login host: such items
    /// are reclassified (`VaultItemType.secureNote`) and excluded from audit + autofill, not "repaired".
    public static func isNonLoginHostMarker(_ host: String) -> Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "sn"
    }

    // MARK: Junk host — "needs attention"; the app supplies PSL-resolved domains, this decides.

    /// A domain string that looks like a real registrable domain (non-empty and containing a dot). A
    /// single-label token like `sn` or an empty string fails this.
    public static func isLikelyRegistrableDomain(_ domain: String) -> Bool {
        !domain.isEmpty && domain.contains(".")
    }

    /// Junk-host decision from inputs the app computes (it owns PSL + decryption):
    ///  - `resolvedDomains` — each stored host reduced to its registrable domain (`""` if unresolvable).
    ///  - `rawHostsNonEmpty` — the item has at least one **non-empty** stored host string.
    ///  - `hasPassword` — the decrypted item carries a non-empty password.
    ///
    /// Rules: a valid resolved domain ⇒ not junk; else a non-empty-but-invalid host (e.g. `sn`) ⇒ junk;
    /// else (no hosts at all) ⇒ junk **only** if it's a login carrying a password (it lost its host).
    /// A hostless, passwordless item (e.g. a TOTP-only entry) is legitimately hostless ⇒ not junk.
    public static func isJunkHost(resolvedDomains: [String], rawHostsNonEmpty: Bool, hasPassword: Bool) -> Bool {
        if resolvedDomains.contains(where: isLikelyRegistrableDomain) { return false }
        if rawHostsNonEmpty { return true }
        return hasPassword
    }
}

// MARK: - Bundled 2FA Directory snapshot (MIT, 2factorauth) — no runtime network, fails loud

/// The bundled, reduced **2FA Directory** TOTP snapshot (vault-spec §10 WF-9). Domain-keyed TOTP
/// support, reduced to a `Set` of registrable domains at snapshot-build time. Refreshed only by a new
/// app build shipping a new file — **never a runtime lookup**. Loader **fails loud** if the resource is
/// missing / empty / malformed (we never silently ship a no-op 2FA check).
///
/// License + attribution: `SurfrCore/TWOFA_DIRECTORY_LICENSE.md`. The attribution string is shown in
/// the Security Check UI.
public enum TwoFADirectory {

    public struct Snapshot: Sendable {
        public let generated: String       // ISO date the snapshot was built (shown in the UI)
        public let domains: Set<String>    // registrable domains that support TOTP
    }

    /// Required attribution — reproduced verbatim in the Security Check surface and the license file.
    public static let attribution = "Data sourced from 2FA Directory by 2factorauth"

    public static let shared: Snapshot = load()
    public static var domains: Set<String> { shared.domains }
    public static var snapshotDate: String { shared.generated }

    private struct Raw: Decodable { let generated: String; let domains: [String] }

    private static func load() -> Snapshot {
        guard let url = Bundle.module.url(forResource: "twofa_totp_domains", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            preconditionFailure("2FA Directory TOTP snapshot missing/malformed in SurfrCore bundle")
        }
        let set = Set(raw.domains.map { $0.lowercased() }.filter { !$0.isEmpty })
        precondition(!set.isEmpty, "2FA Directory TOTP snapshot is empty — refusing a no-op 2FA check")
        return Snapshot(generated: raw.generated, domains: set)
    }
}
