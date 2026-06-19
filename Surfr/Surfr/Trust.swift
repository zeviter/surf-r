import Foundation
import WebKit
import Combine

/// Persistent allowlist of *trusted registrable domains* for the hybrid session
/// model (slice C1). Trusted domains share the single persistent
/// `WKWebsiteDataStore.default()` (so auth/SSO survives relaunch and is shared
/// across trusted tabs); everything else stays in per-tab `.nonPersistent()`.
///
/// Storage: **UserDefaults**, not GRDB. The set is tiny (a handful of short
/// strings), needs no querying/indexing, and — critically — the trust check runs
/// synchronously on the navigation hot path (`decidePolicyFor navigationAction`),
/// where an async GRDB read would be awkward. An in-memory `Set` backs O(1)
/// matching; UserDefaults is just the on-disk mirror.
///
/// Privacy: any logging of trusted domains is DEBUG-only.
@MainActor
final class TrustStore: ObservableObject {
    static let shared = TrustStore()

    /// One trusted domain with the date it was trusted (slice 8).
    struct TrustedSite: Identifiable {
        let domain: String
        let trustedOn: Date
        var id: String { domain }
    }

    /// Source of truth: trusted registrable domain (lowercased) → trusted-on date.
    @Published private(set) var trustedDomains: [String: Date]

    /// Just the trusted domains, for matching. `isTrusted` is unchanged.
    var domains: Set<String> { Set(trustedDomains.keys) }

    /// Trusted sites, most-recently-trusted first (drives the Trusted Sites page).
    var trustedSites: [TrustedSite] {
        trustedDomains
            .map { TrustedSite(domain: $0.key, trustedOn: $0.value) }
            .sorted { $0.trustedOn > $1.trustedOn }
    }

    /// V2 stores a domain→date map. V1 stored a bare `[String]` set (no dates).
    private let mapKey = "SurfrTrustedDomainsV2"
    private let legacyKey = "SurfrTrustedDomains"

    private init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.dictionary(forKey: "SurfrTrustedDomainsV2") {
            // V2: load the date map.
            var map: [String: Date] = [:]
            for (key, value) in raw where value is Date {
                map[key.lowercased()] = value as? Date
            }
            trustedDomains = map.compactMapValues { $0 }
        } else if let legacy = defaults.stringArray(forKey: "SurfrTrustedDomains") {
            // Migrate V1 set → V2 map. We don't know the original trust dates, so
            // stamp already-trusted domains with "now" (a sensible default) and
            // rewrite in the new format.
            let now = Date()
            trustedDomains = Dictionary(uniqueKeysWithValues: legacy.map { ($0.lowercased(), now) })
            defaults.set(trustedDomains, forKey: "SurfrTrustedDomainsV2")
            defaults.removeObject(forKey: "SurfrTrustedDomains")
        } else {
            trustedDomains = [:]
        }
    }

    // MARK: - Matching (subdomain-spanning)

    /// A host is trusted if it equals a stored domain or is a subdomain of one
    /// (`host == d` or `host` ends with `"." + d`). Subdomain-spanning is
    /// deliberate: auth redirects move across subdomains (e.g.
    /// `accounts.google.com` → `mail.google.com`), so exact-host trust would break
    /// sign-in. This is intentionally looser than the rail's full-host grouping.
    func isTrusted(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func isTrusted(url: URL?) -> Bool { isTrusted(host: url?.host) }

    // MARK: - Mutation

    /// Trust the registrable domain covering `host` (so all its subdomains match),
    /// recording the trusted-on date (now).
    func trust(host: String) {
        let domain = Self.registrableDomain(for: host)
        guard !domain.isEmpty else { return }
        trustedDomains[domain] = Date()
        persist()
        #if DEBUG
        print("[Trust] now trusting \(domain)")
        #endif
    }

    /// Stop trusting the domain(s) covering `host`, and purge their persisted
    /// cookies/data from the shared store so the session is truly forgotten.
    func untrust(host: String) {
        let lowerHost = host.lowercased()
        let domain = Self.registrableDomain(for: host)
        // Remove the derived registrable domain plus any stored entry that covers
        // this host (in case it was trusted under a different derivation).
        let removed = trustedDomains.keys.filter { $0 == domain || lowerHost == $0 || lowerHost.hasSuffix("." + $0) }
        for d in removed { trustedDomains[d] = nil }
        persist()
        for d in removed { Self.clearPersistentData(forDomain: d) }
        #if DEBUG
        if !removed.isEmpty { print("[Trust] stopped trusting \(removed.sorted().joined(separator: ", "))") }
        #endif
    }

    private func persist() {
        UserDefaults.standard.set(trustedDomains, forKey: mapKey)
    }

    // MARK: - Persistent-store data clearing

    /// Remove cookies/cache/storage for `domain` (and its subdomains) from the
    /// shared persistent store. Uses the async data-record API to avoid Sendable
    /// pitfalls; records are matched by their `displayName` (the registrable
    /// domain WebKit assigns).
    static func clearPersistentData(forDomain domain: String) {
        Task { @MainActor in
            let store = WKWebsiteDataStore.default()
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            let records = await store.dataRecords(ofTypes: types)
            let matching = records.filter { record in
                let name = record.displayName.lowercased()
                return name == domain || name.hasSuffix("." + domain) || domain.hasSuffix("." + name)
            }
            guard !matching.isEmpty else { return }
            await store.removeData(ofTypes: types, for: matching)
            #if DEBUG
            print("[Trust] cleared persisted data for \(domain) (\(matching.count) record(s))")
            #endif
        }
    }

    // MARK: - Registrable domain (pragmatic eTLD+1)

    /// Best-effort registrable domain (eTLD+1). Handles the common multi-label
    /// public suffixes (e.g. `co.uk`) via a small embedded set; otherwise takes
    /// the last two labels.
    ///
    /// NOTE: this is **not** the full Public Suffix List. The project's
    /// `swift-psl` is only a transitive dependency (not linked to the app target),
    /// so a later slice can link it and swap this out for complete coverage.
    /// Subdomain matching (`isTrusted`) tolerates imperfect derivation because it
    /// matches the stored domain and any subdomain of it.
    static func registrableDomain(for host: String) -> String {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = h.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return h }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiLabelSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// Primary label of a registrable domain, capitalised, for display
    /// (`google.com` → "Google", `example.co.uk` → "Example").
    static func primaryLabel(forDomain domain: String) -> String {
        guard let first = domain.split(separator: ".").first, !first.isEmpty else { return domain }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    private static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "gov.uk", "ac.uk", "me.uk", "ltd.uk", "plc.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
        "co.kr", "co.nz", "co.za", "co.in",
        "com.br", "com.cn", "com.mx", "com.tr", "com.sg", "com.hk", "com.tw",
    ]
}
