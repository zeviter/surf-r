
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
- ◐ **Password manager — vault (F5).** ✓ **Built** (vault-spec §11 Slices 1–9): Argon2id/CryptoKit
  vault, master + Secure-Enclave biometric unlock, Recovery Kit, list/detail/add-edit, CSV import,
  generator, TOTP (+ Google Authenticator migration), in-browser fill + save, **and Security Check**
  (weak/reused/2FA-available + junk-host hygiene). **Remaining vault slice: 10 (system AutoFill
  extension).**
- ☐ **Password manager — system AutoFill extension (F5, vault Slice 10).** `ASCredentialProviderExtension`
  (+ passkeys) so credentials fill across all apps; relocate `LoginPayload` to `SurfrCore`. Apple-gated.
  - ☐ **`LoginPayload` still uses a bare `JSONEncoder()` (re-seal churn).** The TV typed payloads
    (payment/address/secureNote/bankAccount) encode via the deterministic `.sortedKeys`
    `encodeTypedPayload` helper, but `LoginPayload` (still in the app target) does not — so a no-op
    decrypt→re-encode→re-seal of an unchanged login can yield different ciphertext. Apply the same
    `.sortedKeys` treatment **when `LoginPayload` relocates to `SurfrCore`** in this extraction. (Flagged
    by the TV-2 deterministic-encoding fix; low priority until the move.)
- ◐ **Typed vault — Secure Notes / Addresses / Payment Methods** (`docs/typed-vault-wireframes.md`,
  WF-11+). **TV-1 done** (data model + LastPass `NoteType` parsing + one-time re-classification).
  **TV-2a done** — segmented vault list (WF-12) + type picker (WF-13, Payment disabled) + Secure Note &
  Address detail/edit/copy (WF-15/16) + nav inheritance (WF-19). **TV-2b done** — Payment detail/edit
  (WF-17): masked card-number/CVV with **biometric reveal/copy** (the Slice-5 path), local **prefix
  card-network detection**, and a **cleartext last-4/network hint** (derived at save + backfilled once for
  migrated cards) so the Payment row renders `network · •••• last4` with **no decryption**; picker Payment
  option enabled. All four current types now have full views. **TV-2-VAL done** — vault-wide **soft**
  field validation + structured inputs (payment expiry/valid-from month+year pickers, read-only prefix
  network, digit-grouped card number with soft Luhn, digit CVV; address **country picker**): GUIDES +
  WARNS in amber, **never blocks save**, existing malformed imports stay openable/editable (pure
  `CardValidation` / `FieldCheck` in `SurfrCore`). **TV-2c done** — first-class **Bank Account** (fifth
  structured type, modelled on TV-2b Payment): masked **account number / IBAN / PIN** with biometric
  reveal/copy, **"Routing Number"→Sort code** parse (shown `XX-XX-XX`), low-sensitivity sort code / SWICT
  shown plainly, cleartext **account-last-4 hint** (`items.account_last4`, derived + backfilled) for
  zero-decryption Bank rows, fifth "Bank" segment + picker option, soft `BankValidation` (sort code / account
  number / SWIFT / IBAN-soft / PIN; account-type picker), and a one-time guarded `NoteType:Bank Account`
  re-classification (V2 marker). **The typed vault is now fully built** (all 5 types: login/note/address/
  payment/bank). **TV-3a done** — **in-browser** card/address click-to-fill (WF-18): autocomplete-token
  detection in the isolated world (token-first, conservative — no card/address icon on search/login/
  newsletter fields), native per-group overlay icon (card/pin glyph), multi-choice picker (cleartext
  hint/label only — zero-decryption), and group fill via `callAsyncJavaScript` (`<select>` country/expiry
  matched by option); never auto-fills; **county never web-filled** (no token); **bank accounts never
  web-filled** (in-vault copy only). Pure `CardFill`/`AddressFill` mappers in `SurfrCore`. **Remaining
  vault work = the SYSTEM autofill block: S10-2** (`ASCredentialProviderExtension` target, Apple-gated)
  **+ S10-3** (QuickType / fill flows) — login/passkey only (Apple doesn't vend cards/addresses to other
  apps); the in-browser TV-3a path is separate and complete.
  - ☐ **TV-3b — cross-origin payment-iframe card fill (DEFERRED, low priority; gated on a spike).** TV-3a
    fills main + same-origin frames only, so card fields inside a **cross-origin PCI iframe** (Shopify
    `*.shopifycs.com` / Stripe Elements / Adyen hosted fields) get no icon (same boundary as Slice-8
    cross-origin login iframes; documented in `known-issues.md` — not a regression). **Precondition — do NOT
    scope TV-3b until a small time-boxed SPIKE answers: can Stripe Elements / Shopify hosted card fields even
    be programmatically filled?** They're framework-controlled inputs that may use native value-setters /
    custom events / anti-fraud rejection of injected input. **If the spike shows the fields reject
    programmatic fill → TV-3b is CLOSED, not deferred** (the rest of the slice would build nothing). **If
    fillable**, scope: track typed anchors **per `WKFrameInfo`** (stop dropping subframe anchors); fill via
    `callAsyncJavaScript(in: crossOriginFrame)`; the **per-field-icon GEOMETRY across the iframe boundary is
    the worst part** (no clean `WKFrameInfo`→`<iframe>` rect API) → **MVP via a NON-geometry affordance**
    (a shortcut / "fill card" badge targeting the detected card subframe, **not** the per-field icon);
    **user-initiated only, scoped to recognized payment-field iframes** (a trust-boundary expansion). Reuses
    the same deferral reasoning as Slice-8 cross-origin iframe fill.
  - ☐ **(post-v1) First-class long-tail editors** (Passport / Bank Account / Wi-Fi / SSH Key / SSN …):
    v1 keeps them as generic Secure Notes with the raw body preserved verbatim; structured editors deferred.
  - ☐ **(post-v1) "Convert type" flow** (e.g. note → payment): v1 is create-as-type only; a mis-imported
    item is fixed by re-creating it.
  - **Interim placeholder:** as of TV-2b every current type (login/note/address/payment) has a full
    detail view; the generic `TypedInterimView` is now **defensive only** — it covers a *future*
    first-class type (e.g. Bank Account, TV-2c) until that type's view ships. It is an honest "full view
    coming" message, never a decryption-failure message.
- ☐ **2FA Directory snapshot goes stale (vault Slice 9 upkeep).** The bundled
  `SurfrCore/.../twofa_totp_domains.json` (TOTP-supporting registrable domains, MIT, dated 2026-06-24)
  has **no runtime refresh by design** — re-snapshot from the 2fa.directory v4 API and re-bundle on a
  periodic cadence (a new build ships the new file). Low priority; the date is shown in the UI.
- ☐ **Cross-device sync (F5/F6/F8) — AirDrop-first.** v1 is local-only (no server, no CloudKit);
  cross-device arrives as an **encrypted AirDrop export** to the iOS app (items already per-item AEAD,
  so it drops in without a rewrite). A CloudKit E2E private-DB sync is a possible later option, not v1.
- ☐ **iOS app + `SurfrCore` extraction.** Everything is macOS-only so far; the data layers were
  written import-clean to move into a shared package later. The whole iOS target is unbuilt.
- ☐ **Anti-adblock evasion (spec Phase 3).** Documented in `spec.md`, not built — bait-request
  stubbing + a maintained anti-adblock filter list. Pairs with the in-app inspector.
- ☐ **Incognito mode (F9, v1 MVP — scope only, design before slicing).** surf-r is **already
  ephemeral-by-default**, so incognito is *not* another ephemeral toggle: a session that additionally
  leaves **no local trace** (no History / Downloads-history / favicon-cache writes, no bookmark-capture
  prompts) and **suspends trust** (trusted domains stay `nonPersistent` — no login/SSO persistence;
  Randomized-mode trusted exemption therefore does **not** apply in incognito), with a clear, honest
  active-state indicator (still **not** anonymity — network/ISP/site still see the user). **Open
  questions** (record, don't resolve): separate incognito **window** vs in-place toggle (*lean:*
  window); visual indicator / rail treatment; vault behaviour (*lean:* fill allowed, save-**capture**
  suppressed); default fingerprint mode (honour global; trust off → Randomized applies fully); zero-
  trace verification (sentinel-grep / WAL discipline). Mirrors the **C3 earmark style** — scope, not a
  slice plan. Full scope in `spec.md` §6. **MVP-critical.**
- ☐ **Anti-fingerprinting (F10, v1 — designed, not built; promoted from v2).** Two user-selectable
  modes. **Standard** (default, recommended) — present as **stock Safari on WebKit**, add **zero
  entropy**, ephemeral state, engage WebKit's native AFP/ITP; blend into the Safari crowd. **Randomized**
  (advanced, opt-in) — deterministic, **bucketed** "farbling" on the passive surfaces AFP doesn't cover
  (canvas / WebGL / WebAudio readback + high-entropy navigator/screen clamps), injected document-start
  in the **existing isolated `WKContentWorld`** (reuse the autofill seam), **seeded per (registrable
  domain × visit session)** so close-and-return yields a new fingerprint; **trusted sites keep a single
  stable fingerprint**. **Honest tradeoff:** Randomized can **increase** uniqueness / break sites → opt-
  in, never a strict upgrade; Standard stays default. **Build tiers (measurement-first):** **FP-0**
  fingerprint measurement harness (probe surf-r vs stock Safari on the same Tahoe build; resolves the
  **UNVERIFIED** question of how much Safari-26 AFP a third-party `WKWebView` inherits — **build first**),
  **FP-1** Standard-mode hardening (UA/`Accept-Language` entropy, add-nothing-observable), **FP-2**
  Randomized mode (gated behind FP-0 numbers). MVP toggle = **global**; per-site override deferred (see
  §C). Full design in `spec.md` §6.
- ☐ **Anti-fingerprinting — per-site override (deferred from F10 v1).** Brave-style per-site shields /
  per-site Standard-vs-Randomized choice. v1 ships a **global** toggle only; revisit post-v1.

> **v1 finish line (sequencing).** Vault **Slice 9** (security check) → **Slice 10** (system AutoFill
> extension) → then **Incognito + Anti-fingerprinting**, the last two v1 surfaces, each **design-pass-
> then-slice**. They **interlock at the trust / Randomized boundary** (incognito suspends trust, which
> drops the Randomized trusted-site exemption); their relative order within that final block is **open**.

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
## C2. Browser feature shortcuts (separate stream — NOT vault work) — ✓ DONE

All five wired through the `ShortcutRegistry` (override ?? default), editable/visible on the shortcuts page.

- ✓ **Web Inspector shortcut `⌘⇧I`.** Wired **DEBUG-only** (recommended: the inspector is gated on
  `isInspectable`, also DEBUG). Opens via the private `_inspector` `show` (consistent with the existing
  DEBUG-only `developerExtrasEnabled` KVC), no-op if unavailable (right-click "Inspect Element" remains the
  fallback). Not compiled into release — the registry definition + menu command + handler are all `#if DEBUG`,
  so release never lists an inert binding. (Release exposure deferred — privacy/footgun tradeoff; see
  `known-issues.md`.)
- ✓ **Save Page `⌘S`.** Saves the current page as a **`.webarchive`** (native single-file complete page) via
  `WKWebView.createWebArchiveData` + `NSSavePanel` — reuses the User-Selected-File entitlement, **no new one**.
- ✓ **Print / Print-to-PDF `⌘P`.** Native `WKWebView.printOperation(with:)` run modal-to-window (reuses the
  `NSPrintOperation` path); the OS print panel owns PDF export.
- ✓ **In-page find `⌘F`.** Native **WebKit find** (`WKWebView.find(_:configuration:)`) — engine handles
  highlight / scroll-to-match / wrap; **no injected JS**. Find-bar overlay (spotlight field + Esc vocabulary):
  query field, next/previous (`⌘G` / `⌘⇧G`, Enter = next, ↑/↓ cycle), close on Esc. **Context-routed:** `⌘F`
  is in-page find on a web tab, vault search in the vault (the global menu shortcut would shadow the vault's
  `⌘F`, so the handler posts `.focusVaultSearch`), nothing on other surfaces (as before). **Limitation:** the
  public `WKFindResult` exposes only match-found, **not** a count/index, so the bar shows *found / no matches*
  rather than "3/17" — a numeric count would need private API or a JS find script (both rejected). Noted in
  `known-issues.md`.
- ✓ **Omnibox open-tab search (switch-to-tab).** "Open tabs" is a new source in the ranked Spotlight stack,
  ranked **above** history/bookmarks (stronger intent), matched by **title or URL** across all open tabs,
  deduped, capped at 4. **Plain Enter / click switches** to the existing tab (via `.switchToTab`; pristine
  source tab discarded by the existing rule); **⌘Enter** keeps its universal new-tab meaning (opens a fresh
  tab to that URL). Coexists with the flyout's per-host `⌘F`-for-tabs filter (not unified). Pure
  `matchingOpenTabs` matcher (unit-tested).

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

- ✓ **F5 vault — Slice 9 (Security Check + junk-host hygiene).** WF-9 sub-surface (Weak / Reused /
  2FA-available / Needs-attention), built on a **keyed-token, zero-decryption audit**: `health_flags`
  bitfield + an `audit_cache` of `HMAC-SHA256(audit_key, password)` reuse tokens (`audit_key =
  HKDF(vaultKey, "surfr-audit-v1")`), grouped on read so only password **equality** ever leaves the
  ciphertext — never the password, never a bare hash. Weak = the generator's entropy math (no zxcvbn);
  2FA-available = the registrable domain is in a **bundled 2FA Directory TOTP snapshot** (MIT,
  attributed, no runtime network). One-at-a-time backfill (one plaintext resident). **Type-correctness:**
  audit + autofill are **login-only** — LastPass Secure Notes / Cards / Addresses (host `sn`) are
  recognized as non-login (`type = secureNote`), excluded, and displayed as-is (so a card number is
  never scanned as a password); genuine **hostless logins** stay on the URL-derivable auto-fix / "needs
  attention" path. Reused renders as **clusters** ("N logins share a password"; value never shown).
  Vault nav is a **stack** (Back/ESC pop one level; item-from-Security-Check returns to it; ESC clears
  search first). Pure `AuditEngine` + `VaultNav` in the app + `SecurityCheckView`; WF-4 list badges
  render from cached flags/tokens with no decryption. hardware-verified (real migrated vault).
- ✓ **F5 password vault — Slices 1–8e** (`docs/vault-spec.md` §11). Argon2id/CryptoKit envelope crypto
  (`SurfrCore`), GRDB store + lock state machine, master-password unlock + mandatory Recovery Kit,
  Secure-Enclave biometric unlock, list/detail/add-edit, CSV import (LastPass/Bitwarden/Chrome/Safari),
  password+passphrase generator (bundled EFF list), TOTP + native Google Authenticator migration, and
  in-browser fill + save (8a detect/host-match/fill, 8c two-step, 8b save prompt, 8d rail badge, 8e
  per-field native overlay). Remaining: Slice 10.

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
