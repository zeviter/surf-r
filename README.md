
# surf-r

A privacy-first web browser for macOS, built on WebKit. Local-privacy and
anti-tracking by default — **not** an anonymity tool. Honest about what that means.

---

## What surf-r is

surf-r is a lightweight WebKit (WKWebView) browser focused on **local privacy**:
minimising what's stored, what tracks you, and what leaks to the local network — while
staying genuinely usable day to day.

- **Ephemeral by default.** Every site loads in a non-persistent store — no cookies,
  history, or site data survive unless *you* opt a site in. Close the tab, it's gone.
- **Per-tab isolation.** Each tab gets its own isolated cookie/storage jar by default —
  stronger separation than typical container extensions.
- **Opt-in persistence (the hybrid trust model).** Sites you explicitly **trust** (and
  only those) get a persistent, shared store so you stay logged in across sessions —
  everything else stays ephemeral. You decide, per site, with one shortcut. This kills
  the "logged out of everything, need a second browser" problem without giving up
  privacy by default.
- **Ad & tracker blocking** out of the box (EasyList + EasyPrivacy + cookie-consent
  lists, via WKContentRuleList and cosmetic filtering).
- **HTTPS-only** with an explicit, deliberate override for sites that don't support it —
  and a clear "insecure" indicator when you choose to proceed.
- **URL tracking-parameter stripping** (utm_*, fbclid, gclid, …) on navigation, scoped
  so it never breaks logins or auth redirects.
- **Private search by default** (DuckDuckGo).
- **Pop-up blocking**, a chromeless single-rail UI, and a summon-only omnibox.

## What surf-r is *not*

It's important to be straight about this, because privacy tools that overpromise erode
trust:

- **Not an anonymity tool.** surf-r does **not** hide your IP address or make you blend
  into a crowd. If you need anonymity / anti-fingerprinting at the Tor or Mullvad level,
  use those — that is genuinely their lane, and a WebKit browser cannot match it.
- **Limited fingerprinting resistance.** surf-r runs on Apple's WebKit and inherits
  Safari/WebKit's built-in anti-fingerprinting and Intelligent Tracking Prevention. It
  deliberately adds **no extra entropy** (no custom UA quirks, minimal custom APIs), but
  it cannot rewrite canvas/WebGL/font APIs to build a uniform "crowd" fingerprint the way
  Gecko-based hardened browsers can. WebKit's protections are what you get.
- **No deep request-level blocking or extensions.** WKWebView does not expose per-request
  interception or the WebExtensions ecosystem, so surf-r can't do uBlock-Origin-depth
  filtering, CNAME uncloaking, or run extensions. Static filter lists (capped by Apple at
  150k rules per content blocker) are the ceiling, and surf-r uses them well.

These aren't bugs — they're the honest boundaries of a privacy-respecting WebKit browser.
Knowing them is part of using the right tool for your threat model.

## Telemetry & network behaviour

- **Zero telemetry. No analytics. No phone-home.** surf-r does not collect, log, or
  transmit usage data anywhere.
- The **only** network requests surf-r itself makes — beyond the websites you choose to
  visit — are **filter-list updates** (EasyList / EasyPrivacy / cookie-consent lists)
  fetched from their public sources. Nothing else originates from the app.
- This is verifiable: watch surf-r's outbound connections (`nettop`, Little Snitch, etc.)
  and you'll see only the sites you visit plus those filter-list sources.

## Open source

surf-r is fully open source under the [MIT licence](LICENSE). No hidden components, no
proprietary blobs. Read the code, build it yourself, verify the claims above.

---

*surf-r is a personal project — a local-privacy browser for people who want ephemeral,
ad-free, trust-on-your-terms browsing on macOS, and who'd rather know exactly what their
browser does than take it on faith.*
