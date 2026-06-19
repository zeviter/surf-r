
# backlog.md — surf-r outstanding work

> Living list of everything deferred, parked, or not-yet-built, gathered from the build so far.
> Referenced alongside `docs/known-issues.md` (which tracks *bugs/limitations*; this tracks *work*).
> Status: ☐ todo · ◐ in progress / queued · ✓ done (kept briefly for context, then pruned).

---

## A. Active plan — current session's queue (rail / shortcuts)

- ☐ **9b2 — shortcut editing** (remap with conflict + reserved-key detection, reset-to-default) —
  deferred; the override layer built in 9a supports it.
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

- ☐ **Federated-login UX.** Trusting a site isn't enough if it logs in via a different provider —
  you must trust the IdP too. Consider auto-trusting a small set of common identity providers, or
  detecting OAuth chains.
- ☐ **Advanced cosmetic filtering.** Only basic `css-display-none` is applied. Scriptlets, `:has()`,
  extended CSS need document-start JS injection — its own slice with a privacy review.
- ☐ **App icon.** Logo exists; needs placing into `Assets.xcassets/AppIcon.appiconset` at the
  required sizes (manual Xcode step).
- ☐ **Custom title bar (unlocks).** Would enable a **centered window title** and a real **trusted
  badge graphic** in the title (currently text-only, "· Trusted: <Domain>"), both blocked by
  Tahoe's plain-text leading-aligned system title.
## D. Known limitations (documented; by-design or low priority)

- **Schemeless single-label hosts** (e.g. `intranet`, `devbox:3000`) parse as searches — workaround
  is an `https://` prefix. (`known-issues.md`)
- **SVG-only favicons** fall back to the letter tile (AppKit can't render SVG). (`known-issues.md`)
- **Gmail / Google OAuth** may resist a webview regardless of UA — Google actively blocks embedded
  browsers. Non-Google logins are unaffected once trusted.
- **Debug-build converter slowness** — SafariConverterLib is slow in Debug (minutes); release
  converts in seconds; the seed protects meanwhile. Cosmetic only.

## Recently completed (short-term context; pruned over time)

- ✓ **Exact registrable domains via swift-psl.** Linked the `PublicSuffixList` product;
  `TrustStore.registrableDomain` now uses `effectiveTLDPlusOne` (full PSL), with the old heuristic
  as fallback. Common domains resolve identically, so existing trusted entries are unaffected.
- ✓ **OAuth redirect-chain rebind guard.** Store decision is bound at chain start; mid-chain
  redirect hops no longer rebind (fixes "cookies not supported, fixed after reloads"). A real
  trust mismatch is reconciled once the chain settles (didFinish).
- ✓ **Spotlight suggestion ranking.** Blended score: match quality (host/title prefix > contains),
  visit frequency (`visitCount`), bookmark boost; recent-history → bookmarks tie-break, search last.
- ✓ **Cold-start first-paint blocking.** `prepare()` split into gated last-good (seed/cache) +
  ungated network refresh; the first page load waits for the seed to apply, then is a no-op.
- ✓ **Background blocklist refresh.** Re-checks staleness on app-foreground and a 6h timer, reusing
  the launch fetch→convert→last-good path; DEBUG-logged, no UI.
- ✓ **`⌘W` semantics.** Verified ⌘W = Close Tab (authoritative; AppKit's window-close is
  shortcut-less, Close All is ⌘⌥W). Added browser-standard ⌘⇧W = Close Window.

- ✓ **9a — Shortcut registry + missing shortcuts + rail polish.** Single-source-of-truth registry
  with an override layer; added reload (`⌘R`/`⌘⇧R`/`⌘⌥R`) and page shortcuts (`⌘Y`/`⌘⇧Y`/`⌘⇧J`/`⌘/`);
  rail icons green-when-active; default order history → downloads → trusted → new tab; open-already-
  open switches instead of duplicating.
- ✓ **9b — Shortcuts popover + searchable page.** Cheatsheet popover + full page via `PageScaffold`,
  grouped and searchable, rendering the registry's effective bindings. (Editing is 9b2, still open.)
- ✓ **9c — Downloads as a page + ephemeral internal surfaces.** Downloads page via `PageScaffold`
  (popover kept, with "See all"); single-instance ephemeral rule for all internal surfaces — reached
  by shortcut/icon, auto-closed on switch-away, never left as a stray tab.
- ✓ **Persistent download history.** GRDB `DownloadStore` (`downloads.sqlite`) mirrors
  `HistoryStore`/`BookmarkStore`; survives relaunch. In-progress rows left by a quit migrate to
  `interrupted`; clear-all + 90-day launch prune; missing files shown as unavailable, not deleted.
