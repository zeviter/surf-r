import Foundation
import WebKit

/// Strips known tracking/analytics query parameters from URLs at navigation time
/// (Stage-1 privacy). Conservative, curated seed derived from the AdGuard URL
/// Tracking / ClearURLs rulesets — only well-known marketing/click-ID params, never
/// functional ones, so it can't strip an auth `code`/`state`/`token`.
///
/// Scope is the safety story: stripping runs ONLY on user-initiated GET navigations
/// (address bar / link clicks). It is never applied to form submissions, POST
/// requests, or in-flight redirects (OAuth/SSO chains) — see `shouldStrip`.
enum TrackingParams {
    /// Prefix families (any param whose lowercased name starts with one of these).
    private static let prefixes = ["utm_", "mtm_", "pk_", "hsa_"]

    /// Exact param names (lowercased) — common click IDs and campaign trackers.
    private static let exact: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid",
        "yclid", "ysclid", "twclid", "ttclid", "rb_clickid", "wickedid",
        "igshid", "igsh", "mc_eid", "mc_cid", "mkt_tok",
        "_hsenc", "_hsmi", "hsctatracking",
        "vero_id", "vero_conv", "oly_anon_id", "oly_enc_id", "_openstat",
        "fb_action_ids", "fb_action_types", "fb_source", "fb_ref",
        "spm", "scm", "cmpid", "trk_contact", "trk_msg", "trk_module", "trk_sid",
        "ml_subscriber", "ml_subscriber_hash", "s_cid", "icid",
    ]

    private static func isTracking(_ name: String) -> Bool {
        let n = name.lowercased()
        if exact.contains(n) { return true }
        return prefixes.contains { n.hasPrefix($0) }
    }

    /// A cleaned URL with tracking params removed, or `nil` if there was nothing to
    /// strip (so the caller can skip the reload). Preserves order, other params, and
    /// the fragment; drops the `?` entirely if nothing remains.
    static func stripped(from url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems, !items.isEmpty else { return nil }
        let kept = items.filter { !isTracking($0.name) }
        guard kept.count != items.count else { return nil }
        comps.queryItems = kept.isEmpty ? nil : kept
        return comps.url
    }

    /// Whether to strip for this navigation. Yes only for user-initiated GETs:
    ///  • link clicks (`.linkActivated`);
    ///  • address-bar / bookmark / programmatic opens (`.other` that is NOT a
    ///    mid-chain redirect).
    /// No for form submissions, reloads, back/forward, POSTs, or redirects — those
    /// can carry auth/session params we must not touch.
    static func shouldStrip(_ action: WKNavigationAction, chainInFlight: Bool) -> Bool {
        let method = action.request.httpMethod?.uppercased()
        guard method == nil || method == "GET" else { return false }
        switch action.navigationType {
        case .linkActivated: return true
        case .other:         return !chainInFlight
        default:             return false   // formSubmitted, formResubmitted, reload, backForward
        }
    }
}
