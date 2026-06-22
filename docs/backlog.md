
# backlog.md — surf-r outstanding work

> Living list of everything deferred, parked, or not-yet-built, gathered from the build so far.
> Referenced alongside `docs/known-issues.md` (which tracks *bugs/limitations*; this tracks *work*).
> Status: ☐ todo · ◐ in progress / queued · ✓ done (kept briefly for context, then pruned).

---

## A. Active plan — current session's queue (rail / shortcuts)

- _Queue clear — the rail/shortcuts plan (9a–9d) is shipped. See B/C for remaining work._

## B. Major unbuilt features (from the original browser spec)

- ☐ **IP obfuscation / routing (F1).** `WKWebsiteDataStore.proxyConfigurations` → self-hosted
  WireGuard or Tor (SOCKS5); plus **WebRTC leak hardening** and **DNS-over-HTTPS**. (UA
  normalisation partially done via the Safari UA fix.) Not started.
- ◐ **Password manager — vault (F5).** ✓ **Built** (vault-spec §11 Slices 1–8e): Argon2id/CryptoKit
  vault, master + Secure-Enclave biometric unlock, Recovery Kit, list/detail/add-edit, CSV import,
  generator, TOTP (+ Google Authenticator migration), in-browser fill + save. **Remaining vault
  slices: 9 (security check) + 10 (system AutoFill extension).**
- ☐ **Password manager — security check (F5, vault Slice 9).** Local weak/reused/2FA-available
  surface (WF-9); **fold in import data hygiene** (junk `item_hosts` like `sn`/empty-string registrable
  domains from messy imports — clean up + a "needs attention" flag). See `known-issues.md`.
- ☐ **Password manager — system AutoFill extension (F5, vault Slice 10).** `ASCredentialProviderExtension`
  (+ passkeys) so credentials fill across all apps; relocate `LoginPayload` to `SurfrCore`. Apple-gated.
- ☐ **Cross-device sync (F5/F6/F8) — AirDrop-first.** v1 is local-only (no server, no CloudKit);
  cross-device arrives as an **encrypted AirDrop export** to the iOS app (items already per-item AEAD,
  so it drops in without a rewrite). A CloudKit E2E private-DB sync is a possible later option, not v1.
- ☐ **iOS app + `SurfrCore` extraction.** Everything is macOS-only so far; the data layers were
  written import-clean to move into a shared package later. The whole iOS target is unbuilt.
- ☐ **Anti-adblock evasion (spec Phase 3).** Documented in `spec.md`, not built — bait-request
  stubbing + a maintained anti-adblock filter list. Pairs with the in-app inspector.
- ☐ **Anti-fingerprinting (v2).** Canvas/timezone/client-hint surface spoofing. Original spec
  scoped this to v2.

## C. Deferred polish & fixes

- ☐ **Two-step new-login save-capture (vault, → v1.5).** Save-on-submit requires a non-empty adjacent
  username, so a *genuinely new* two-step login (username page 1, password page 2) isn't captured (8c
  still fills; manual add covers new ones). Needs stateful cross-page username-carry.
- ☐ **Save dedup edge — same password, different/new account on one host.** The belt-and-suspenders
  "password already stored for this host → no prompt" (which stops re-offering a just-filled credential)
  also suppresses a *new* account that reuses an existing password on the same site. Add it manually;
  revisit if it bites.
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
## C2. Browser feature shortcuts (separate stream — NOT vault work)

- ☐ **Web Inspector shortcut `⌘⇧I`.** The DEBUG Web Inspector already exists via `isInspectable`;
  this just wires the shortcut. **Decide:** keep it DEBUG-only, or expose in release (most browsers
  do) — flag the privacy/footgun tradeoff before exposing.
- ☐ **Save Page `⌘S`.** Reuses the existing **User-Selected-File Read/Write** entitlement +
  `NSSavePanel` path already added for the Recovery Kit — **no new entitlement**. Confirm during build.
- ☐ **Print / Print-to-PDF `⌘P`.** Reuses the `NSPrintOperation` path already touched for the
  Recovery Kit.

## C3. In-browser document view + edit (post-v1 — investigate best-in-class before building, NOT scheduled)

> Two distinct future feature streams. **Scope only — do not design or slice yet.** Both sit **after v1
> (Slices 9–10)** unless reprioritised. Each needs a "survey best-in-class first" investigation before
> any build.

- ☐ **(A) Markdown editor — view + edit `.md`.** Editor surface + live preview + save-back. surf-r
  already *renders* markdown (markdownviewer / `.md` downloads); this is the contained next step.
  **Open questions for design time:** CommonMark vs GFM scope (tables / task-lists / footnotes);
  code-fence syntax highlighting; in-place save vs export; where the editor lives (internal
  `PageScaffold` surface vs dedicated pane). Low–moderate complexity; **no privacy seam** (local text
  in/out).
- ☐ **(B) PDF view + annotate / fill / sign / redact.** View, annotate, fill form fields, sign, and
  redact PDFs in-browser. Likely **Apple PDFKit** (`PDFView` / `PDFAnnotation` / form fields) per the
  Apple-native principle — covers view/annotate/fill cheaply. **Two research-worthy hard parts flagged
  for the investigation:** (1) **redaction must be TRUE redaction** — remove content from the PDF
  content stream, not draw a box over still-extractable text; naïve box-over-text is a well-known
  data-leak failure and would violate surf-r's "structural, not aspirational" privacy stance, so if
  redaction ships it must genuinely remove the data or not claim the word; (2) **"sign" needs a scope
  decision** — visual/drawn signature (image stamp, easy) vs. cryptographic digital signature
  (PKI/certificate, tamper-evident, much harder) — pick at design time. Moderate–high complexity
  (redaction + crypto-signing are the research parts). Exported/generated docs as **PDF openable in
  Chrome** (per user pref).

## D. Known limitations (documented; by-design or low priority)

- **Schemeless single-label hosts** (e.g. `intranet`, `devbox:3000`) parse as searches — workaround
  is an `https://` prefix. (`known-issues.md`)
- **SVG-only favicons** fall back to the letter tile (AppKit can't render SVG). (`known-issues.md`)
- **Gmail / Google OAuth** may resist a webview regardless of UA — Google actively blocks embedded
  browsers. Non-Google logins are unaffected once trusted.
- **Debug-build converter slowness** — SafariConverterLib is slow in Debug (minutes); release
  converts in seconds; the seed protects meanwhile. Cosmetic only.

## Recently completed (short-term context; pruned over time)

- ✓ **F5 password vault — Slices 1–8e** (`docs/vault-spec.md` §11). Argon2id/CryptoKit envelope crypto
  (`SurfrCore`), GRDB store + lock state machine, master-password unlock + mandatory Recovery Kit,
  Secure-Enclave biometric unlock, list/detail/add-edit, CSV import (LastPass/Bitwarden/Chrome/Safari),
  password+passphrase generator (bundled EFF list), TOTP + native Google Authenticator migration, and
  in-browser fill + save (8a detect/host-match/fill, 8c two-step, 8b save prompt, 8d rail badge, 8e
  per-field native overlay). Remaining: Slice 9 + 10.

- ✓ **Privacy Stage-1 (three wins).** (1) HTTPS-only by default — main-frame http upgraded to
  https; failure shows an interstitial with explicit per-site "continue insecurely" (no silent
  fallback); loopback/.local/private IPs exempt. (2) Tracking-param stripping (utm_*/fbclid/gclid/…)
  scoped to user-initiated GET navigations only — never forms/POSTs/redirects, so auth flows are
  safe. (3) Cookie-consent blocking via the EasyList Cookie list (third independent WKContentRuleList,
  ~9.1k rules; EasyList ~63k + EasyPrivacy ~55k + Cookie ~9k, each under the 150k per-list cap — no
  chunking). All reuse the existing navigation-delegate / content-blocker pipelines.

- ✓ **9b2 — shortcut editing.** Each row on the shortcuts page records a new combo (click the combo →
  capture via a focused NSView that grabs the keystroke before the menu). Writes go to the 9a
  override layer, so the menu/key handlers update live and persist across relaunch. Validates:
  requires a ⌘/⌃/⌥ modifier, rejects reserved system combos (⌘Q/⌘W/⌘H/⌘Tab/⌘Space) and conflicts
  (names the holder; no silent double-bind). Per-row reset-to-default + global "Reset All".

- ✓ **9d — Drag-to-reorder rail icons.** The five internal-surface icons (history, downloads,
  trusted, shortcuts, new-tab) reorder by drag via `RailSurface` + a live `DropDelegate`; order
  persists in UserDefaults (`SurfrRailSurfaceOrder`), reconciled against `allCases`. Default stays
  history → downloads → trusted → shortcuts → new tab. Favicon host tiles are unaffected; active-
  green/badges/popovers/clicks preserved.

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
