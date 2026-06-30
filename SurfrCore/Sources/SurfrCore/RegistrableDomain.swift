import Foundation
import PublicSuffixList

/// Pure registrable-domain (eTLD+1) normalization — the shared anti-leak core of the hybrid trust model
/// AND the autofill host matcher. Relocated out of the app's `TrustStore` in Slice 10-1 so the app and
/// the coming AutoFill extension share **one** eTLD+1 implementation (the app's `TrustStore` now delegates
/// here — single source of truth). Import-clean (Foundation + PublicSuffixList only; no AppKit/WebKit),
/// which is exactly what lets it be shared with an extension. Behaviour is unchanged from the prior
/// `TrustStore` statics — this is a relocation, not a rewrite.
public enum RegistrableDomain {

    /// Reduce a bare host to its registrable domain (eTLD+1) via the full Public Suffix List.
    ///
    /// Falls back to the pragmatic eTLD+1 heuristic when PSL can't produce a result — e.g. the host is
    /// itself a public suffix, has too few labels, or is an IP / single-label name. The fallback preserves
    /// the prior behaviour for those edge cases, and ordinary registrable domains (`google.com` →
    /// `google.com`) resolve identically under both, so existing trusted entries still match.
    public static func registrableDomain(for host: String) -> String {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let etldPlusOne = PublicSuffixList.effectiveTLDPlusOne(h), !etldPlusOne.isEmpty {
            return etldPlusOne
        }
        return heuristicRegistrableDomain(h)
    }

    /// Registrable domain from a value that may be a bare host, `host:port`, or a full URL (with
    /// scheme / path / query / userinfo). Robustly extracts the host first, then reduces. Used wherever
    /// stored credential hosts (which may be messy LastPass-imported URLs) must reduce to the same
    /// registrable domain as a live page origin — keeping the match exact, not fuzzy.
    public static func registrableDomain(forHostOrURL value: String) -> String {
        registrableDomain(for: hostComponent(from: value))
    }

    /// Extract the bare host from a host/URL string (drop scheme, path/query/fragment, userinfo, port).
    public static func hostComponent(from value: String) -> String {
        var s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }                  // drop scheme
        if let i = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<i]) } // authority only
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }         // drop userinfo
        if let colon = s.lastIndex(of: ":") { s = String(s[..<colon]) }                   // drop port
        return s.lowercased()
    }

    /// Primary label of a registrable domain, capitalised, for display
    /// (`google.com` → "Google", `example.co.uk` → "Example").
    public static func primaryLabel(forDomain domain: String) -> String {
        guard let first = domain.split(separator: ".").first, !first.isEmpty else { return domain }
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// Pre-PSL fallback: common multi-label suffixes via a small embedded set, else the last two labels.
    private static func heuristicRegistrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiLabelSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    private static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "gov.uk", "ac.uk", "me.uk", "ltd.uk", "plc.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
        "co.kr", "co.nz", "co.za", "co.in",
        "com.br", "com.cn", "com.mx", "com.tr", "com.sg", "com.hk", "com.tw",
    ]
}
