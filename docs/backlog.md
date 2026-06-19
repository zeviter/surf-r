
# backlog.md — surf-r outstanding work

> Living list of everything deferred, parked, or not-yet-built, gathered from the build so far.
> Referenced alongside `docs/known-issues.md` (which tracks *bugs/limitations*; this tracks *work*).
> Status: ☐ todo · ◐ in progress / queued · ✓ done (kept briefly for context, then pruned).

---

## A. Active plan — current session's queue (rail / shortcuts)

- ◐ **9a — Shortcut registry + missing shortcuts + rail polish.** Central single-source-of-truth
  shortcut list; add `⌘R` reload, `⌘⇧R` hard reload, `⌘⌥R` empty-cache-and-hard-reload, `⌘Y`
  history, `⌘⇧Y` trusted sites, `⌘⇧J` downloads, `⌘/` shortcuts page. Rail icons turn **green when
  their page is active** (history, downloads, trusted, new-tab, shortcuts). Fixed default rail
  order: **history → downloads → trusted → new tab**. Opening an already-open internal page
  switches to it (no duplicates).
- ☐ **9b — Shortcuts page.** Renders the registry via `PageScaffold` (searchable, grouped,
  consistent with history/trusted).
- ☐ **9b2 — shortcut editing** (remap with conflict + reserved-key detection, reset-to-default) —
  deferred; the override layer built in 9a supports it.
- ☐ **9c — Downloads as a page + ephemeral internal surfaces.** Convert downloads to a full
  searchable page (keep the rail popover with recent downloads + clear-all + a "See all downloads"
  button that opens the page). Apply the **single-instance ephemeral rule** to all internal pages
  (history, trusted, downloads, shortcuts, new-tab): reached by shortcut/icon, auto-closed when you
  navigate away, never left as a stray tab.
- ☐ **9d — Drag-to-rearrange rail order** (with persistence). Deferred as its own slice — drag
  interaction + saved ordering is fiddlier than it looks.

## B. Major unbuilt features (from the original browser spec)

- ☐ **IP obfuscation / routing (F1).** `WKWebsiteDataStore.proxyConfigurations` → self-hosted
  WireGuard or Tor (SOCKS5); plus **WebRTC leak hardening** and **DNS-over-HTTPS**. (UA
  normalisation partially done via the Safari UA fix.) Not started.
- ☐ **Password manager — vault (F5).** Encrypted local store (CryptoKit + Keychain + Secure
  Enclave), password generator, TOTP, Face/Touch ID gate. Not started.
- ☐ **Password manager — system autofill (F5).** `ASCredentialProviderExtension` (+ passkeys) so
  credentials fill across all apps. Not started.
- ☐ **Cross-device sync (F5/F6/F8).** CloudKit private DB, end-to-end encrypted, for vault +
  bookmarks + settings. Not started. (History stays local by design.)
- ☐ **iOS app + `SurfrCore` extraction.** Everything is macOS-only so far; the data layers were
  written import-clean to move into a shared package later. The whole iOS target is unbuilt.
- ☐ **Anti-adblock evasion (spec Phase 3).** Documented in `spec.md`, not built — bait-request
  stubbing + a maintained anti-adblock filter list. Pairs with the in-app inspector.
- ☐ **Anti-fingerprinting (v2).** Canvas/timezone/client-hint surface spoofing. Original spec
  scoped this to v2.

## C. Deferred polish & fixes

- ☐ **Persistent download history (was 2c).** Downloads are in-memory and reset on quit — decide
  the privacy tradeoff, then a GRDB `DownloadStore`. More relevant now downloads becomes a page.
- ☐ **Exact registrable-domain via swift-psl.** `TrustStore.registrableDomain` is a pragmatic
  eTLD+1 subset, not the full Public Suffix List. swift-psl is already a transitive dep; link it
  for exact handling of unusual multi-label TLDs.
- ☐ **OAuth redirect-chain rebind transient.** Crossing into an untrusted identity-provider domain
  mid-login can briefly land the session in the wrong store (the "cookies not supported, fixed
  after reloads" symptom). Mitigated by trusting the IdP (google/github). Real fix if it recurs:
  don't rebind the store while a redirect chain is in flight.
- ☐ **Federated-login UX.** Trusting a site isn't enough if it logs in via a different provider —
  you must trust the IdP too. Consider auto-trusting a small set of common identity providers, or
  detecting OAuth chains.
- ☐ **Spotlight suggestion ranking.** Currently basic recency + substring; refine ordering/quality.
- ☐ **Advanced cosmetic filtering.** Only basic `css-display-none` is applied. Scriptlets, `:has()`,
  extended CSS need document-start JS injection — its own slice with a privacy review.
- ☐ **Cold-start first-paint blocking.** On a fresh launch the first tab can paint before the
  content-rule list attaches; subsequent loads are covered. Make first paint deterministic.
- ☐ **Background blocklist refresh.** Currently fetches on launch with a 24h cache; consider
  refreshing while running.
- ☐ **App icon.** Logo exists; needs placing into `Assets.xcassets/AppIcon.appiconset` at the
  required sizes (manual Xcode step).
- ☐ **Custom title bar (unlocks).** Would enable a **centered window title** and a real **trusted
  badge graphic** in the title (currently text-only, "· Trusted: <Domain>"), both blocked by
  Tahoe's plain-text leading-aligned system title.
- ☐ **Confirm `⌘W` semantics.** Verify close-tab vs close-window behaves as intended (note a prior
  coexistence between Surfr's close-tab and SwiftUI's window-close).

## D. Known limitations (documented; by-design or low priority)

- **Schemeless single-label hosts** (e.g. `intranet`, `devbox:3000`) parse as searches — workaround
  is an `https://` prefix. (`known-issues.md`)
- **SVG-only favicons** fall back to the letter tile (AppKit can't render SVG). (`known-issues.md`)
- **Gmail / Google OAuth** may resist a webview regardless of UA — Google actively blocks embedded
  browsers. Non-Google logins are unaffected once trusted.
- **Debug-build converter slowness** — SafariConverterLib is slow in Debug (minutes); release
  converts in seconds; the seed protects meanwhile. Cosmetic only.
