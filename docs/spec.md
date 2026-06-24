# spec.md — surf-r build specification

> Authoritative build spec, referenced by `CLAUDE.md`. Privacy-first browser for macOS (+ a planned
> iOS target), Swift + WebKit. Verify Apple framework APIs against current docs before relying on
> snippets.
>
> **This document is reality-first:** §2–§5 describe what is actually built today; §6 maps the
> original phased plan to DONE / REMAINING. `docs/ui-wireframes.md` remains authoritative for rail /
> spotlight / bookmarks / history / surfaces UI; `docs/backlog.md` tracks outstanding work;
> `docs/known-issues.md` tracks parked bugs/limitations.

---

## 1. Goal & principles

A browser where privacy is the default behaviour. Guiding principles:
- **Private by default, persistent only on explicit trust.** Each tab uses an isolated
  `WKWebsiteDataStore.nonPersistent()` store (no cookies on disk). The user can *trust* a site, which
  moves it to a single shared persistent store so logins/SSO survive relaunch (the **hybrid trust
  model**, §4). Nothing else is persisted to a site's benefit.
- **WebKit engine** (`WKWebView`). No Chromium/Gecko (Apple requires WebKit for third-party browsers
  outside the EU; acceptable for every feature here).
- **No telemetry, ever.** The product earns trust by collecting nothing. History is local-only.
- **User owns the stack** — self-hosted IP routing and a self-owned password vault are intended
  (not yet built, §6).

---

## 2. Feature requirements → mechanism (with build status)

Status: ✓ done · ◐ partial · ☐ not started.

| ID | Feature | Status | Mechanism (as built, or planned) |
|----|---------|--------|-----------|
| F2 | No cookies by default + per-site persistence | ✓ | Per-tab `nonPersistent()` store; trusted registrable domains share `WKWebsiteDataStore.default()`. The hybrid trust model — §4. (`Trust.swift`, store binding in `ContentView.swift`.) |
| F3 | Block ads / trackers / cookie banners | ✓ | EasyList + EasyPrivacy + EasyList-Cookie, each fetched and converted on-device with AdGuard `SafariConverterLib`, compiled into its **own** `WKContentRuleList` and applied together. Bundled seed + on-disk cache as last-good fallback; background refresh; cold-start first-paint gate. Basic cosmetic hiding (`css-display-none`) comes from the converter. (`ContentBlocker.swift`.) Advanced cosmetic (scriptlets/`:has()`) is ☐ (backlog). |
| F4 | Block ad pop-ups, allow trusted | ✓ | `WKUIDelegate` gate: allow only user-initiated link activations or allowlisted origins; programmatic `window.open` blocked. (`PopupGate` / `TrustPolicy` in `ContentView.swift`.) |
| F6 | Clean bookmarks on new tab | ✓ | Local-first GRDB `BookmarkStore`; the new-tab page shows the omnibox box + a bookmarks grid. (`BookmarkStore.swift`, `Spotlight.swift`.) CloudKit sync is ☐. |
| F7 | Organised history | ✓ | GRDB `HistoryStore` (indexed, substring search, date-grouped, 365-day auto-prune, local-only); full-page history surface. (`HistoryStore.swift`, `HistoryView.swift`.) |
| F8 | Omnibox shortcut | ✓ | `⌘L` summons the spotlight overlay (or focuses the permanent new-tab box); URL-vs-DuckDuckGo parser; `Enter` = current tab, `⌘Enter` = new tab. (`Spotlight.swift`, `Omnibox.swift`.) |
| F1 | IP obfuscation / routing | ☐ | Planned: per-app `WKWebsiteDataStore.proxyConfigurations` → SOCKS5 (Tor / self-hosted WireGuard) + WebRTC/DNS leak hardening. Not started. |
| F5 | Password manager (vault + system autofill) | ◑ | **Largely built** (see `docs/vault-spec.md` §11): CryptoKit/Argon2id vault, master + Secure-Enclave biometric unlock, Recovery Kit, list/detail/add-edit, CSV import, generator, TOTP (+ Google Authenticator migration), and **in-browser fill + save** (Slices 1–8e). **Remaining:** Slice 9 (security check) and Slice 10 system AutoFill extension (`ASCredentialProviderExtension`, Apple-gated); passkeys are v2. |
| F9 | Incognito mode (no-local-trace session, trust suspended) | ☐ | **MVP/v1 — scope only, design before slicing.** surf-r is already ephemeral-by-default for web state, so incognito is *not* another ephemeral toggle: it additionally leaves **no local trace** (no History / Downloads-history / favicon-cache writes, no bookmark-capture prompts) and **suspends trust** (trusted domains stay `nonPersistent` — no login/SSO persistence), with a clear, honest active-state indicator. Last-v1 surface alongside anti-fingerprinting (§6). |
| F10 | Anti-fingerprinting (two modes: Standard / Randomized) | ☐ | **v1 — designed, not built; lands after vault Slice 10.** Baseline = present as **stock Safari on WebKit** (large crowd) + ephemeral-by-default + engage WebKit's native AFP/ITP. **Standard** (default) adds zero entropy; **Randomized** (opt-in) injects deterministic, bucketed farbling on canvas/WebGL/WebAudio + high-entropy clamps in the existing isolated `WKContentWorld`, seeded per (registrable domain × visit session), with a trusted-site stable-fingerprint exemption. Honest tradeoff: Randomized can *increase* uniqueness. Full design + build tiers (FP-0/1/2) in §6. |

Privacy/UX features built **beyond** the original F-list (all ✓):
- **HTTPS-only by default** with interstitial + explicit per-site override and visible insecure
  indicators (`HTTPSUpgrade.swift`, ATS web-content exemption in `Surfr/Info.plist`).
- **URL tracking-parameter stripping** (`utm_*`, `fbclid`, `gclid`, …), scoped to user-initiated GET
  navigations only (`TrackingParams.swift`).
- **Safari User-Agent** so sites don't flag an embedded browser (`Tab.safariUserAgentToken`).
- **Persistent download history** with interrupted-on-quit handling (`DownloadStore.swift`,
  `Downloads.swift`, `DownloadsUI.swift`).
- **Central, override-ready keyboard-shortcut registry** with an editable shortcuts page
  (`Shortcuts.swift`, `ShortcutsView.swift`).
- **Web Inspector** attachable in DEBUG builds only (`isInspectable` + `developerExtrasEnabled`).

---

## 3. As-built UI & behaviour (macOS)

Near-chromeless; the only persistent chrome is a **48px left rail**. (`docs/ui-wireframes.md` is the
authoritative layout reference.)

- **Left rail.** Pinned internal-surface icons (history · downloads · trusted · shortcuts · new-tab),
  drag-reorderable with a persisted order, each turning green when its surface is the active tab.
  Below a divider: **host-grouped favicon tabs** — one tile per full host (subdomain-aware), stable
  creation order, blue active ring, a blue count badge (`99+` cap) when a host has ≥2 tabs, and a
  top-right status badge (green ✓ trusted / amber ⚠ insecure). First-party favicons via
  `FaviconService` with a letter-tile fallback. (`ContentView.swift`, `FaviconService.swift`.)
- **Tab flyout.** Clicking a multi-tab host opens an overlay listing that host's tabs (filter input,
  active-on-top, per-row close); single-tab hosts switch directly. Pristine (un-navigated) tabs are
  disposable.
- **Spotlight omnibox.** Summon-only via `⌘L`: a centered overlay over a dimmed page (pre-filled +
  selected current URL), or focus of the permanent box on the new-tab page. Ranked suggestions
  (recent history → bookmarks → DuckDuckGo) blending match quality + visit frequency. (`Spotlight.swift`.)
- **New-tab page.** Permanent omnibox box + responsive bookmarks grid (favicon + label; `⌘D` /
  right-click to add; ⌘-click a tile opens in a new tab).
- **Full-page internal surfaces** built on a shared `PageScaffold` (header + live search + grouped
  list + reusable row): **History**, **Trusted Sites**, **Keyboard Shortcuts**, **Downloads**
  (the downloads rail icon also keeps a popover with live progress + "See all"). (`PageScaffold.swift`,
  `HistoryView.swift`, `TrustedSitesView.swift`, `ShortcutsView.swift`, `DownloadsUI.swift`.)
- **Ephemeral internal-surface rule.** Each internal surface (and the new-tab page) is
  single-instance: opening one switches to it if already open, and it auto-closes when it stops being
  the active tab — never left as a stray tab. (`BrowserState` in `ContentView.swift`.)
- **Navigation.** Back/forward via `⌘←`/`⌘→` (primary, editable) **and** `⌘[`/`⌘]` (hard-wired
  aliases), plus two-finger swipe and mouse side-buttons. Reload `⌘R`, hard reload `⌘⇧R`, empty-cache
  reload `⌘⌥R`. Window title mirrors the active tab's page title, with `· Trusted: <Domain>` or
  `· ⚠ Not Secure` appended.
- **Keyboard shortcuts** are resolved through the registry's effective binding (override ?? default)
  everywhere — menu bar and key handlers never hardcode keys — so edits take effect live and persist.
  The shortcuts page allows recording new combos with conflict + reserved-key detection and reset.

---

## 4. Hybrid trust model (core architecture)

Any navigation- or data-touching work **must respect this model.**

- **Default = ephemeral & isolated.** Every tab's web view is created with its own
  `WKWebsiteDataStore.nonPersistent()` store. Untrusted sites leave nothing on disk and don't share
  state across tabs.
- **Trusted = shared persistent store.** A user can trust a site (`⌘⇧T` / menu / Trusted Sites page).
  Trust is keyed by **registrable domain** (eTLD+1 via `swift-psl`'s `PublicSuffixList`, subdomain-
  spanning so `accounts.google.com` and `mail.google.com` share `google.com`). Trusted domains use the
  single shared `WKWebsiteDataStore.default()`, so logins/SSO persist across relaunch and across
  trusted tabs. The trusted set persists in UserDefaults (domain → trusted-on date).
- **Store binding & rebinding.** A web view's store is fixed at creation, so the store is chosen from
  the destination host's trust at first navigation, and the web view is **recreated on the correct
  store** when a navigation crosses a trust boundary — handled in the navigation delegate's
  `decidePolicyFor navigationAction`. A redirect-chain guard avoids rebinding mid-OAuth (the store is
  bound at chain start; a genuine mismatch is reconciled once the chain settles).
- **HTTP can never be trusted/persisted.** Only HTTPS origins can enter the persistent store; an
  insecure http page (only reachable via explicit "continue insecurely", §5) is forced to the
  ephemeral store even on an otherwise-trusted domain. Attempting to trust an http page shows a
  warning toast and does nothing.
- **Indicators.** Green ✓ badge on rail/bookmark tiles for trusted hosts; amber ⚠ badge + `· ⚠ Not
  Secure` title for insecure pages (mutually exclusive); a trust/untrust confirmation toast; a
  blocked-trust warning toast. Untrusting a domain clears its persisted data.

Source: `Trust.swift` (store + matching + PSL), `TrustUI.swift` (badges + toast), store binding /
rebind / indicators in `ContentView.swift`.

---

## 5. Privacy mechanisms (as built)

- **Content blocking (F3).** Three independent `WKContentRuleList`s (EasyList ≈63k, EasyPrivacy ≈55k,
  EasyList-Cookie ≈9k rules) — each well under the 150k per-list cap, so no chunking is needed yet
  (the split-into-multiple-lists approach is available if any single list grows past the cap). Each
  source: bundled seed → on-disk cache → runtime fetch+convert, with last-good fallback on any
  failure; cosmetic `css-display-none` rules come from the converter (`advancedBlocking: false`).
  Background refresh on app-foreground + a 6h timer. Cold-start first paint is gated on the seed/cache
  being applied so the first tab can't paint un-blocked.
- **Pop-up gate (F4).** Programmatic `window.open` is blocked; user-initiated or allowlisted origins
  pass. (No recovery banner yet — see `known-issues.md`.)
- **HTTPS-only.** Main-frame `http://` is upgraded to `https://` (request preserved, so form POSTs
  aren't downgraded); loopback/`.local`/private-IP hosts are exempt. On HTTPS failure an interstitial
  offers an explicit per-site "continue insecurely" — never a silent fallback — backed by a scoped
  `NSAllowsArbitraryLoadsInWebContent` ATS exemption (web-content only; the app's own URLSession
  traffic keeps full ATS). WebKit's active mixed-content blocking is unaffected.
- **Tracking-param stripping.** Curated AdGuard/ClearURLs-style seed; applied only to user-initiated
  GET navigations (`.linkActivated` or non-redirect `.other`), never to form submissions, POSTs, or
  redirects — so auth/session params can't be touched.
- **Safari UA.** `applicationNameForUserAgent` set so WebKit assembles a real Safari UA string.

---

## 6. Original phased plan → status

**Done (now described as reality in §3–§5):**
- **Phase 0 — macOS MVP.** ✓
- **Phase 1 — Navigation shell.** ✓ — omnibox (summon-only spotlight), multiple tabs (rail
  host-grouping), back/forward/reload. Security state is shown via the HTTPS / trust indicators
  rather than a separate TLS lock; there is no page-load progress bar.
- **Phase 2 — Blocking.** ✓ — 2a pipeline, 2b runtime fetch/convert + EasyPrivacy + cosmetic +
  fallback, 2c popup gate, 2d DEBUG Web Inspector. Multi-list chunking is available-by-design but not
  currently needed; advanced cosmetic filtering remains ☐ (backlog).
- **Phase 4 — Bookmarks & history.** ✓ — and extended well beyond the original scope: the rail +
  flyout, summon-only spotlight, bookmarks-on-new-tab, the hybrid trust model, and the full-page
  History / Trusted Sites / Shortcuts / Downloads surfaces with the ephemeral internal-surface rule.

**Built beyond the original plan (✓):** hybrid trust model, HTTPS-only, tracking-param stripping,
cookie-consent blocking, Safari UA, persistent download history, the shortcut registry + editable
page, drag-reorderable rail.

**Remaining (☐ not started) — design intent preserved below:**

### Phase 3 — Anti-adblock evasion (macOS)
- **Goal.** View pages that demand you disable your adblocker, without actually disabling blocking.
- **Realistic scope.** Anti-adblock is an arms race, not a toggle: defeat the *common* detection
  patterns, accepting that some stubborn sites still need case-by-case handling.
- **Detection methods to counter:** bait requests (decoy `ads.js`-style files), bait elements (decoy
  ad `<div>`s checked for being hidden/removed), missing-global checks (`adsbygoogle` / ad-SDK
  objects absent), and packaged anti-adblock scripts.
- **Approach:** (a) a maintained anti-adblock filter list (AdGuard / EasyList family); (b) for bait
  requests, harmless valid stub responses via request interception (`WKURLSchemeHandler`) and/or a
  document-start `WKUserScript` defining the probed globals.
- **Mechanism note.** Different from the declarative `WKContentRuleList` blocking — it **intercepts
  and injects**, and the injected JS runs on **every page**, so it carries its own privacy review
  (keep it minimal, no data egress, audit every script). Pairs with the DEBUG Web Inspector for
  diagnosing which bait a wall keys on.

### Phase 5 — IP routing (F1, macOS)
- `ProxyManager` wiring `WKWebsiteDataStore.proxyConfigurations` (SOCKS5) to the user's self-hosted
  WireGuard or a local Tor SOCKS port. WebRTC shim + DNS-through-tunnel. Guard against the known
  iOS 18.x `proxyConfigurations` crash pattern (set before first load; availability-gate).

### Phase 6 — `SurfrCore` extraction + iOS app
- Extract stable logic into a shared `SurfrCore` package; add the iOS SwiftUI target reusing it
  (`UIViewRepresentable` WKWebView); re-verify F1–F8 on iOS. Everything is in the single macOS
  `Surfr` target today; the data layers are already import-clean (no AppKit/SwiftUI/WebKit in
  `HistoryStore`/`BookmarkStore`/`DownloadStore`/`Omnibox`) to ease the move.

### Phase 7 — Password vault (F5) — ✅ done
- Encrypted store (CryptoKit AES-GCM; key wrapped by Secure Enclave / master password via Argon2id).
  Generator + TOTP. Face/Touch ID gate. **Built** as `docs/vault-spec.md` Slices 1–7 (crypto, store,
  master + biometric unlock, Recovery Kit, list/detail/add-edit, CSV import, generator, TOTP +
  Google Authenticator migration). App Group sharing lands with the extension (Phase 8).

### Phase 8 — Autofill (F5) — ◑ in-browser done; system extension remaining
- **In-browser fill + save done** (vault-spec Slices 8a–8e): isolated-world detection, exact-host
  anti-leak, ⌘\ / rail badge / per-field native-overlay icon, biometric+master fill, own save prompt.
- **Remaining (Slice 10):** `ASCredentialProviderExtension` targets (iOS + macOS); QuickType + full UI;
  passkeys (`ASPasskeyCredential`, iOS 17+). Fills detected login fields/QuickType/Safari, **not** the
  generic context-menu on arbitrary text fields (Apple-private) — as with all third-party managers.

### Phase 9 — Sync (reframed AirDrop-first)
- **v1: local-only, no server, no CloudKit.** Cross-device sharing arrives later as an **encrypted
  export over AirDrop** to the iOS app (items are already AEAD-encrypted per-item, so it drops in
  without a rewrite). A CloudKit private-DB (E2E, encrypt-before-upload) sync is a possible *later*
  option, not the v1 path.

### v1 finish line — sequencing
After the vault is complete (**Slice 9** security check → **Slice 10** system AutoFill extension), the
**last two v1 surfaces** are **Incognito mode** and **Anti-fingerprinting**, below. Both are
**design-pass-then-slice** (scope recorded here; design before slicing) and they **interlock at the
trust / Randomized boundary** — incognito suspends trust, which removes the Randomized trusted-site
exemption. Their relative order within this final block is **open** (note, don't resolve).

### Incognito mode (F9, v1 — MVP) — scope only, design before slicing
☐ not started. **MVP-critical.** Recorded as scope + open questions (mirrors the C3 earmark style);
**do not design or slice yet.**

- **Definition (load-bearing).** surf-r is **already ephemeral-by-default** for web state, so incognito
  is **not** another ephemeral-web toggle. Incognito = a session that *additionally* leaves **no local
  trace** and **suspends trust**:
  - No **History** entries written (`HistoryStore` suppressed).
  - No **Downloads-history** entries (the file still downloads if chosen, but is not logged).
  - No **favicon-cache** writes; no **bookmark-capture** prompts.
  - **Trust suspended** — trusted domains do **not** use the persistent shared store; everything stays
    `nonPersistent`, so no login/SSO persistence is written. (Therefore the Randomized-mode trusted
    exemption does **not** apply in incognito — Randomized, if on, applies fully.)
  - **Clear visual indication** that incognito is active, honest about scope (still **not** anonymity —
    network / ISP / site still see the user).
- **Open questions (record, don't resolve):**
  - Separate incognito **window** (own `BrowserState` + ephemeral everything) vs in-place mode toggle.
    *Lean:* separate window, given the chromeless single-window + rail model.
  - Visual indicator / rail treatment.
  - Vault + autofill behaviour (vault still unlockable? *lean:* fill allowed, save-**capture** suppressed
    so an incognito session writes no new creds unless explicit).
  - Default fingerprint mode in incognito (honour the global; trust suspended → Randomized applies fully).
  - Zero-trace verification: sentinel-grep / WAL discipline — confirm nothing persists.

### Anti-fingerprinting (F10, v1 — last v1 surface, after Slice 10) — designed, not built
☐ not started; **designed below, not built.** Promoted from v2 → v1.

- **Positioning.** `WKWebView` **cannot** build a Tor-style uniform crowd (we can't rewrite the engine).
  surf-r's baseline strength is that it already presents as **stock Safari on WebKit**, so users sit in
  the large Safari/WebKit crowd, and ephemeral-by-default already breaks cross-session linkage. Two
  user-selectable modes:
  - **Standard (default, recommended).** Present as stock Safari, add **zero entropy**, ephemeral state,
    engage WebKit's native AFP/ITP. Strategy = blend into the Safari crowd; defends against being
    **singled out by uniqueness**.
  - **Randomized (advanced, opt-in).** Deterministic "farbled" noise on the **passive surfaces AFP
    doesn't already cover** (2D canvas / WebGL / WebAudio readback; plus high-entropy navigator/screen
    clamps), injected **document-start in the existing isolated `WKContentWorld`** (reuse the autofill
    injection seam). Defends against **cross-site / cross-session correlation**. Rules:
    - **Seed** — deterministic per **(registrable domain × visit session)**. A *visit session* = the
      lifetime of that host's tab group; when the host's last tab closes the seed is discarded. Result:
      frame-to-frame consistent within one visit (no breakage), different across sites and sessions, and
      **close-and-return yields a new fingerprint**.
    - **Bucket, don't pure-randomize** — where raw noise would produce an implausible config, snap to a
      plausible "one-of-few" value (Brave's lesson) so the fingerprint stays realistic.
    - **Compose with the engine** — stack on whatever AFP already noises (FP-0 resolves what that is);
      never collide.
    - **Trusted-site exemption** — trusted sites present a **single stable fingerprint** (Standard
      presentation) even when Randomized is globally on; they're already identified by login, and a
      shifting fingerprint risks fraud / 2FA re-challenges. Trust is the boundary, consistent with the
      rest of surf-r. (Suspended in incognito, where trust itself is off.)
    - **Honest tradeoff (must be in user-facing copy)** — diverging from stock Safari can **increase**
      uniqueness and may break some sites, so Randomized is opt-in and **never framed as a strict
      upgrade**; Standard stays default. The toggle must not imply Randomized = strictly more private.
- **MVP toggle scope.** A **global** Standard/Randomized setting. Per-site override → backlog (deferred;
  no Brave-style per-site shields in v1).
- **Build tiering (measurement-first — slice plan, ☐):**
  - **FP-0 — Fingerprint measurement harness.** Probe surf-r's actual exposed surface (canvas / WebGL /
    audio / screen / fonts / navigator / headers) in the isolated world and compare to stock Safari on
    the same Tahoe build. Resolves how much Safari-26 AFP a third-party `WKWebView` actually inherits by
    default (**UNVERIFIED today** — note explicitly), and whether `nonPersistent` stores already engage
    private-browsing-grade protections. Baseline for all before/after measurement. No user-facing change.
    **Build FIRST regardless of the rest.**
  - **FP-1 — Standard-mode hardening.** Confirm UA adds no entropy; clamp reducible header entropy
    (`Accept-Language`); verify surf-r adds nothing observable (custom schemes; the native autofill
    overlay is already non-DOM, so clean); lean on the engine protections FP-0 confirms. Low breakage
    risk.
  - **FP-2 — Randomized mode.** The document-start farbling + clamps above, **gated behind FP-0 numbers**
    proving it **reduces (not increases)** uniqueness; measured before/after; reviewable injection.
- **Engine context (current — verify against current WebKit before relying on it).** Safari 26 ships
  **Advanced Fingerprinting Protection** on by default in Safari — noise into canvas/WebGL/audio readback
  for scripts it classifies as fingerprinters, plus screen/window-metric clamping and restricted
  high-entropy / referrer / query-param access. **ITP** is inherited by all `WKWebView` browsers since
  iOS 14. Third-party `WKWebView` inheritance of AFP is **not confirmed** and is exactly what FP-0
  measures.

---

## 7. Architecture

**Current (as built).** A single macOS SwiftUI app target `Surfr` (deployment macOS 14). WebKit
(`WKWebView`) via `NSViewRepresentable`. Linked packages: **GRDB** (stores), **SafariConverterLib**
(`ContentBlockerConverter`), **swift-psl** (`PublicSuffixList`, + transitive Punycode). Persistence:
`Application Support/Surfr/{history,bookmarks,downloads}.sqlite` and `…/Blocklist/` cache;
UserDefaults for trusted domains, shortcut overrides, and rail order; `WKWebsiteDataStore.default()`
for trusted-site cookies.

**Target (planned).** Extract stable logic into a shared `SurfrCore` package, add an iOS SwiftUI
target reusing it, and add AutoFill / content-blocker / proxy extensions + CloudKit sync.

```
            ┌──────────── SurfrCore (planned package) ──────────┐
            │ TabEngine · ProxyManager · ContentBlockerCompiler │
            │ VaultCrypto · SyncEngine · History/Bookmark/Download │
            │ OmniboxParser · TrustStore                         │
            └───▲───────────────▲────────────────────▲──────────┘
        ┌───────┴──┐      ┌──────┴───────┐     ┌──────┴───────────┐
        │ macOS app│      │  iOS app     │     │ Extensions:      │
        │ (built)  │      │ (planned)    │     │ AutoFill ×2 ·    │
        │ WKWebView│      │ WKWebView    │     │ Content Blocker ·│
        └──────────┘      └──────────────┘     │ Proxy/Network    │
                                               └──────────────────┘
```

---

## 8. Conventions
- Module/product name `Surfr`; display name "surf-r"; bundle base `com.zeviter.surfr`.
- Shared logic is written import-clean so it can move into `SurfrCore`; UI stays thin.
- No secrets in the repo (see `.gitignore`). No telemetry/analytics anywhere.
- Prefer Apple-native frameworks; vet any dependency for privacy.
- Keyboard bindings flow through `ShortcutRegistry` (override ?? default) — never hardcode keys in
  the menu or key handlers.

## 9. Security model (summary)
Protects against: cross-site cookie tracking (ephemeral-by-default + per-site trust), ad/tracker
requests and cookie-consent walls, unrequested pop-ups, insecure (http) connections (HTTPS-only),
URL tracking params, embedded-browser fingerprinting via UA, and **vault theft** (F5 built: Argon2id
KEK → AES-GCM envelope, Secure-Enclave-wrapped biometric key, key-zeroing on lock). Will also protect
(when built): IP exposure (F1); **device fingerprinting** (F10); **local-trace forensics** (F9
incognito). Does **not** provide: anonymity/crowd-blending (a self-hosted exit is a static IP), defence
against a malicious relay you don't control, or protection from on-device malware.

**Anti-fingerprinting — honest framing** (F10, §6): the claim is *"present as stock Safari + clear state
each session + add no entropy + engage WebKit's native protections, optionally randomized"* — **not**
Tor-grade anonymity or a uniform crowd. Standard mode blends into the Safari/WebKit crowd; Randomized
mode trades that blend for cross-site/cross-session correlation resistance and **can increase
uniqueness** and break some sites, so it is opt-in and never framed as a strict upgrade. Same
structural-not-aspirational rule as "green = surf-r filled this".

**Incognito — honest framing** (F9, §6): incognito leaves **no local trace** and **suspends trust** for
the session; it is **not anonymity** — the network, ISP, and visited sites still see the user. The
active-state indicator must say so.

**Vault — honest limitations** (see `docs/vault-spec.md` §13 + `docs/known-issues.md`): the vault has
**no recovery backstop** — lose both the master password and the Recovery Kit and it's unrecoverable by
design. **TOTP shares the vault**, so a single unlock exposes both factors (optional, disclosed). The
in-browser autofill **never injects into page DOM** and offers credentials only on an exact
registrable-host match with a real visible login form, but has documented gaps (dynamic shadow-DOM
hide-on-close popups, cross-origin iframes, closed shadow roots). State these honestly in user-facing
privacy copy.

## 10. Human-only steps
Apple Developer enrolment, signing identities/certs, first-time capability prompts (CloudKit,
AutoFill, Network Extension), and anything requiring payment or accepting Apple's terms. The build
agent pauses and hands these to the user.

## 11. Key decisions
- **Hybrid trust over pure-ephemeral.** Pure ephemeral broke logins (re-auth per tab / per launch);
  a per-site persistent allowlist (F2's "optional per-domain persistent") keeps privacy-by-default
  while letting trusted sites stay logged in. HTTP can never be trusted.
- **F3 fetch-and-convert at runtime, maintained converter, bundled seed.** EasyList changes
  constantly; fetching keeps it current. Conversion is delegated to AdGuard `SafariConverterLib`
  (never hand-rolled). A bundled seed blocks from first launch and is the initial last-good fallback.
- **Registrable-domain trust via the full PSL** (`swift-psl`), so unusual multi-label TLDs resolve
  correctly; a heuristic remains as fallback.
- **HTTPS-only escape hatch is explicit + scoped.** The ATS exemption is `…InWebContent` only, and
  http loads only after the user opts in per-site.
