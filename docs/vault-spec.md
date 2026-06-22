# vault-spec.md — surf-r password vault &amp; AutoFill (F5)

> Authoritative design spec for the **password vault + system AutoFill** (F5; `spec.md` §6 Phases
> 7–9). Referenced by `CLAUDE.md`. **Design-stage:** everything here is ☐ not-yet-built — this
> document settles the architecture before slicing. Visual wireframes live in the companion PDF
> (`surf-r-password-vault-spec.pdf`); the textual wireframe descriptions in §10 are the
> implementation reference. Verify Apple framework APIs (AuthenticationServices, LocalAuthentication,
> CryptoKit, Security/Keychain) against current docs before relying on snippets.
>
> **Relationship to existing docs:** realises **F5**; details `spec.md` §6 **Phase 7** (vault) and
> **Phase 8** (autofill); reframes **Phase 9** sync as AirDrop-first rather than CloudKit-first. Does
> **not** alter the hybrid trust model (`spec.md` §4) — the vault is a self-contained subsystem and
> does not change how web-content `WKWebsiteDataStore`s are bound.
>
> Status legend: ✓ done · ◐ partial · ☐ not started.

---

## 0. Decisions locked

| Topic | Decision |
|----|----|
| **Sync model** | **Local-only in v1.** No sync server, no CloudKit. Cross-device sharing arrives later as an *encrypted export over AirDrop* to the iOS app. Storage format is designed so this drops in without a rewrite. |
| **Hosting / cost** | **None.** The whole vault runs on-device via CryptoKit + Secure Enclave. The only spend is the Apple Developer Program (~$99/yr), a platform fee, not hosting. |
| **Passkeys** | **Deferred to v2.** v1 is classic passwords + TOTP + generator. Passkeys are *additive* (they coexist with passwords per-site), so the schema reserves room now and they slot in later with no migration. |
| **Unlock** | **Biometric-primary, master-password root.** Face ID / Touch ID gates a *stored key*; it does not replace the KDF. The master password remains the true root of trust. |
| **Recovery** | **Printable Recovery Kit.** A high-entropy recovery code wraps a second copy of the vault key. Lowest-friction option that keeps zero-knowledge intact — no escrow, no third party. |
| **Hardware** | **M1 Pro fully supported.** Apple silicon since M1 has the Secure Enclave + AES acceleration; no parameter compromises; Argon2id unlock stays well under a second. |

The "envelope" is **local cryptography, not a cloud service.** The master password encrypts a small
*vault key*; the vault key encrypts the entries. The split means a master-password change re-wraps one
small key (not every entry), and lets the recovery code wrap a *second* copy of that same vault key.

---

## 1. Scope &amp; non-goals

### In scope — v1
| Capability | Notes |
|----|----|
| Encrypted local vault | Two-tier envelope; AES-256-GCM items; GRDB store in an App Group container. |
| Master password + biometric unlock | Argon2id KEK; Secure-Enclave-wrapped key for Face ID / Touch ID. |
| Recovery Kit | Printable PDF with a recovery code that independently unwraps the vault. |
| Login items | Title, host(s), username, password, notes, favicon, health flags. |
| TOTP | RFC 6238 codes stored as `otpauth://` URIs, encrypted with the item. |
| Generator | Random-character and diceware passphrase modes with a live entropy readout. |
| In-browser fill | surf-r's own WKWebView login forms, via JS field detection + the browser's own fill/save UI. |
| System AutoFill | `ASCredentialProviderExtension` so credentials fill in other apps and Safari (Apple-Dev-gated). |
| Security audit | Local weak / reused detection (a "Watchtower"-style surface). |

### Out of scope — later
- **v1.5** — Encrypted AirDrop export/import to the iOS app (the cross-device story).
- **v2** — Passkeys / WebAuthn provider (`ASPasskeyCredential`). Schema designed to accept them.
- **later** — Breach monitoring (e.g. HIBP k-anonymity) — needs a network lookup; deferred for the local-only posture.
- **later** — Trusted-contact / escrow recovery — needs a server / third party; out of the local-only model.

### Principles (inherited from `spec.md` / `CLAUDE.md`)
- **Privacy is the default.** The vault collects nothing, phones home to nothing, encrypted at rest.
- **Don't roll your own crypto.** CryptoKit for AEAD/HKDF/P-256; Keychain + Secure Enclave for key
  material; a *vendored, vetted* Argon2id for the one primitive CryptoKit lacks. Never log secrets,
  keys, or plaintext credentials.
- **Own the stack.** Self-owned vault; no dependence on iCloud Keychain or any third-party manager.
- **Vertical slices.** Each slice builds, runs, and is testable before the next; small commits to `main`.

---

## 2. Vault crypto &amp; key hierarchy

Envelope pattern (as 1Password / Proton Pass / Bitwarden): a password-derived key never encrypts data
directly — it only wraps a random vault key, which in turn protects per-item keys.

### The hierarchy
```
                          ┌─────────────────────────────────────────────┐
  master pw ─Argon2id→ KEK ─AES-256-GCM wrap─►  ┌──────────────┐         │
  (+16-byte salt)                                │  VAULT KEY   │  wraps  │
                                                 │  256-bit     ├───────► every
  recovery code ─Argon2id→ KEK′ ─wrap (copy 2)─► │  random,     │  item   item key
                                                 │  on-device   │  key    (256-bit)
  Secure Enclave P-256 ─ECIES wrap (copy 3)────► └──────────────┘         │ ─► AES-256-GCM
                                                                          │    item payload
                          └─────────────────────────────────────────────┘
```
**Three doors to the same vault key:**
1. **Master password** — `Argon2id → KEK → unwrap vault key`. The root of trust; always works. Everyday + recovery anchor.
2. **Biometric** — Secure Enclave P-256 unwraps a *stored copy* of the vault key. Convenience (Face ID / Touch ID).
3. **Recovery code** — independent KDF unwraps a *third copy*. Used only to reset a lost master. Printed Recovery Kit, kept offline.

Losing any single door never exposes the others, and no door is ever stored unwrapped.

### Primitives &amp; parameters
| Element | Spec |
|----|----|
| **KDF (master pw → KEK)** | **Argon2id.** Default `m=64 MiB, t=3, p=1` on macOS (comfortable on M1 Pro); floor at OWASP `m=19 MiB, t=2, p=1` (or `46 MiB, t=1, p=1`) on older iOS hardware. Per-vault random 16-byte salt, stored alongside the wrapped key. |
| **KDF (recovery code → KEK′)** | Same Argon2id, separate salt. The recovery code is itself high-entropy, so the KDF is defence-in-depth. |
| **Vault &amp; item keys** | `SymmetricKey(size: .bits256)` from CryptoKit's CSPRNG. Generated once; never leave the device unwrapped. |
| **AEAD** | **AES-256-GCM** via `AES.GCM.seal` — hardware-accelerated on Apple silicon. Fresh random 96-bit nonce per seal (never reuse a key+nonce pair); 128-bit tag. `ChaChaPoly` is the documented alternative. |
| **Sub-key derivation** | HKDF-SHA256 for domain-separated sub-keys (e.g. metadata-index key vs. payload key). |
| **Not in CryptoKit** | **Argon2id must be vendored** (reference `phc-winner-argon2` or swift-sodium). Everything else above is native. |

**Nonce discipline (load-bearing):** always let CryptoKit generate a random nonce per `seal`; never
derive nonces from a counter that could reset; never reuse a `(key, nonce)` pair. The per-item-key
design makes this trivially safe — each item has its own key and is re-sealed on every edit.

---

## 3. Key storage — Keychain &amp; Secure Enclave

The vault *file* lives on disk; the *keys* live in the Keychain, with the biometric copy gated by a
Secure Enclave key. The main app and the AutoFill extension share both via an App Group + shared
Keychain access group.

- **Device-bound, no iCloud, no backup.** Store wrapped keys with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (or `WhenPasscodeSetThisDeviceOnly`) so they never
  sync or land in a backup.
- **Biometric gate.** The biometric vault-key copy is protected by a `SecAccessControl` built with
  `.biometryCurrentSet` — this **invalidates** the stored key if Face ID / Touch ID enrolment changes,
  forcing a master-password re-auth (the behaviour 1Password / Bitwarden exhibit). Pair with an
  `LAContext` and `kSecUseAuthenticationContext` to avoid a blocking `SecItemCopyMatching`.
- **Secure Enclave reality.** The SE only generates/holds **P-256** keys and can sign or do ECDH — it
  **cannot store the symmetric vault key**. So create an SE key and **ECIES-wrap** the vault key to it
  (`kSecKeyAlgorithmECIESEncryptionStandardX963SHA256AESGCM`); store the wrapped blob. The SE is
  **unavailable in the Simulator** — all of this is hardware-tested.
- **Vault file protection.** Set the SQLite file's Data Protection class to `NSFileProtectionComplete`
  on iOS (decryption key evicted on device lock); macOS uses volume-key semantics.
- **Shared with the extension.** Vault file via an **App Group** container (`group.com.zeviter.surfr…`);
  key material via a **shared Keychain access group** (`keychain-access-groups` entitlement). The
  extension performs its own biometric gate.

**Why not put the vault in the Keychain?** The Keychain is for small secrets (keys, tokens), not a
growing item store with search/favicons/history. Keep *keys* in the Keychain and the *vault* in GRDB —
which also gives the query ergonomics the list/search UI needs and a clean basis for the AirDrop export.

---

## 4. Unlock model — biometric + master password

A small state machine: **LOCKED** (keys zeroed in memory) ↔ **UNLOCKED** (vault key in memory, items
decryptable). Three ways in (biometric and master password both reach UNLOCKED; the recovery code only
*resets a lost master*); many ways back to LOCKED, each zeroing in-memory keys.

### Policy
| Trigger | Behaviour |
|----|----|
| **First run** | Set master password → derive KEK → create + wrap vault key → offer biometric (store SE-wrapped copy) → **force Recovery Kit creation** before finishing. |
| **Everyday unlock** | Biometric prompt fires automatically; "Use master password" is always one tap away, no penalty on first miss. |
| **Master required again** | On reboot · after biometric enrolment changes (automatic via `.biometryCurrentSet`) · after a configurable interval (default **14 days**) · after N failed attempts. |
| **Auto-lock** | Lock on background / resign-active **and** a 5-minute idle timer (default). Options: Immediately / 1 / 5 / 15 / 30 / 60 min / On system lock. "Never" discouraged behind a warning. A ⌘-shortcut locks instantly. |
| **On lock** | Zero the vault key and any derived material from memory; the encrypted vault stays on disk. |

> **Slice 4 as-built — biometric design + accepted Apple-platform limitations** (verified on M1 Pro):
> - **Single source of truth.** Biometric auth-state is one value — `unavailable | available | enabled | invalidated` — that every view derives from; transitions go through one refresh. Error classification is **inverted/allowlisted**: only the genuine Secure-Enclave failure (AKSError `-536362999`, "unable to compute shared secret") disables biometric; **all** cancels/interrupts (`userCancel`, `systemCancel` "canceled by another authentication", `appCancel`, lockout, unknown) are benign no-ops that fall back to master and leave biometric enabled.
> - **Lazy enrolment-change detection (intended).** `.biometryCurrentSet` invalidation is detected only on the **next unlock attempt** — macOS pushes no enrolment-change event — and the app can only see "the set changed," not add-vs-remove. Standard password-manager behaviour. On detection: disable + "Touch ID was reset" + live **Re-enable** (recovers without restart once biometry is usable again, via a refresh on app-activate).
> - **Single implicit SE prompt.** Unlock uses one `SecKeyCreateDecryptedData` that drives the Touch ID prompt *and* the ECIES decrypt together. A two-step `evaluateAccessControl`→reuse approach (which would let the prompt cancel cleanly) **does not drive the ECIES decrypt on real Secure Enclave hardware**, so it's not used.
> - **Prompt dismissal is best-effort (deferred polish).** Because the prompt is the system-owned `LAContext` dialog inside the implicit decrypt, choosing master/recovery only *best-effort* dismisses it (`cancel()` invalidates the context); **Esc / typing-master may not reliably dismiss the floating prompt**. Master unlock still works regardless — cosmetic. A `DeviceOwnerAuthentication`-style clean fix is deferred to a later hardware-iteration round.

---

## 5. Recovery for a lost master password

Local-only + zero-knowledge ⇒ no server to reset against, so recovery must be something *you hold*.

**The Recovery Kit:**
1. At setup, generate a high-entropy **recovery code** (door 3 in §2).
2. Derive an independent KEK′ from it and wrap a **second copy of the vault key**.
3. If the master password is lost, the recovery code unwraps the vault and lets the user **set a new master password** (re-wrapping copy 1).
4. The code is presented as a printable **Recovery Kit PDF** (modeled on 1Password's Emergency Kit and Apple's recovery key).

| Option | Local-only? | Zero-knowledge? | Friction | Decision |
|----|----|----|----|----|
| Recovery Kit (code wraps 2nd copy) | Yes | Preserved | Low (one printout) | **Chosen — v1** |
| Encrypted vault export (AirDrop format) | Yes | Preserved | Low | Doubles as backup |
| Escrowed recovery key | No (needs store) | Weakened | Medium | Deferred |
| Trusted-contact / email | No | Broken / N/A | Low | Out of model |

**Honest tradeoff.** The Recovery Kit is a real second door — its security reduces to safeguarding the
printout. So the UI must (a) generate the code at high entropy, (b) make creating the kit a
**required, non-skippable** setup step, (c) urge physical / offline storage, and (d) **never** auto-save
it into the vault or iCloud. There is **no server backstop**: lose both the master password and the
kit, and the vault is unrecoverable by design.

> **Slice 4 as-built (recovery robustness).**
> - **Copy-safe code.** The recovery code is KDF'd against a **canonical form** (`VaultCrypto.canonicalRecoveryCode`: uppercase, Crockford look-alike mapping `O→0`/`I,L→1`, and *all* separators/whitespace stripped), so a code copied without a hyphen, in the wrong case, or with stray whitespace still unlocks. The kit PDF + on-screen code render on a **single line** so a copy keeps every separator. The entry field disables smart-dash/quote/replacement substitutions.
> - **Regenerate Recovery Kit** (authenticated, in-vault). A lost/compromised kit can be replaced: re-wrap **copy 2** of the vault key under a fresh code (`rewrapForNewRecovery`), persist, and produce a new kit PDF. The **old code stops working**; the master door is untouched.

---

## 6. Storage model &amp; schema

GRDB over SQLite (consistent with the existing `HistoryStore` / `BookmarkStore` / `DownloadStore`),
with per-item AES-256-GCM blobs. The schema reserves a typed item model so passkeys drop in without a
migration.

### Tables (sketch)
| Table | Columns |
|----|----|
| `vault_meta` | **per-door** salt + params: `kdf_salt_master`, `kdf_params_master`, `wrapped_vault_key_master`, `kdf_salt_recovery`, `kdf_params_recovery`, `wrapped_vault_key_recovery`, `schema_version`. (The biometric copy lives in the Keychain, not here.) |
| `items` | `id`, `type` (`login` · `passkey`* · reserved), `title`, `created_at`, `modified_at`, `wrapped_item_key`, `ciphertext` (encrypted payload), `health_flags`. |
| `item_hosts` | `item_id`, `host` (subdomain-aware, matching the favicon grouping unit), `is_primary` — drives URL matching for fill. |
| `audit_cache` | derived weak / reused signals, recomputed locally; never holds plaintext. |

\* `passkey` rows are reserved for v2: the encrypted payload simply carries different fields (RP id,
credential id, P-256 private-key blob, user handle, signature counter) under the *same* encryption
path — **no schema migration** needed when passkeys land.

> **Slice 1 amendment — no separate `nonce` column.** AES-256-GCM `seal` already returns the 96-bit
> nonce inline in its `.combined` form (`nonce ‖ ciphertext ‖ tag`). The crypto core stores that
> combined blob directly in `ciphertext`, so a standalone `nonce` column is redundant and has been
> dropped. Same applies to `wrapped_item_key` and the `vault_meta` wrapped-key columns — each is a
> combined GCM blob carrying its own nonce.
>
> **Slice 2 amendment — per-door salt + params in `vault_meta`.** The two password-based doors (master,
> recovery) each derive a KEK from an **independent** Argon2id salt and its own params, so `vault_meta`
> carries `kdf_salt_master`/`kdf_params_master` **and** `kdf_salt_recovery`/`kdf_params_recovery` (params
> persisted as JSON text). The original single-`kdf_salt` sketch was wrong; the as-built per-door columns
> above are correct. `schema_version` here is the **envelope/payload** version (distinct from the GRDB
> table-migration id); `VaultStore` rejects an unknown/newer value rather than misread a future format.
>
> **Slice 2 — cleartext metadata.** `items.title` and `item_hosts.host` are stored **in the clear** so the
> list renders and URL matching works while the vault is *locked*. Credentials (username/password/notes/
> TOTP) live only inside the encrypted `ciphertext` and never touch a cleartext column. The privacy cost
> of the cleartext metadata is disclosed in §13.

> **Slice 5 — list needs no decryption (intentional privacy property).** Because `title`/`host` are
> cleartext metadata, the vault **list renders without decrypting anything** — only the **detail view
> decrypts, one item at a time, on open** (and zeroes that plaintext on close). So at most one
> credential's payload is ever in cleartext in memory, briefly. This is the deliberate upside of the
> cleartext-metadata tradeoff in §13: minimal plaintext exposure, and the list/search stay fast.

**Login payload (decrypted shape — cleartext only in memory, only while unlocked):**
```json
{ "username": "...", "password": "...", "notes": "...",
  "totp": "otpauth://totp/...",  "urls": ["..."],
  "passwordChangedAt": "...", "custom": { } }
```

**AirDrop export format (v1.5).** Items are already AEAD-encrypted under per-item keys, so the export is
essentially the on-disk format wrapped under a one-time transfer key (derived from a transfer passphrase
or the recovery code). Nothing plaintext leaves the device; the receiving iOS app stays zero-knowledge.
The per-item-key hierarchy also makes *selective* export feasible later. AirDrop is peer-to-peer — no
relay, no cost.

---

## 7. AutoFill architecture

Two distinct fill paths, sharing the vault but driven differently.

### Path A — System AutoFill (other apps &amp; Safari)
- Subclass **`ASCredentialProviderViewController`** in a dedicated **Credential Provider extension**
  target. Enabled in Settings ▸ Passwords (iOS) / System Settings (macOS).
- **Flows:**
  - `prepareCredentialList(for:)` → show the (biometrically gated) picker.
  - `provideCredentialWithoutUserInteraction(for:)` → return silently if already unlocked; else throw
    `ASExtensionError.userInteractionRequired`.
  - `prepareInterfaceToProvideCredential(for:)` → show Face ID, then complete.
- **QuickType index.** Push `ASPasswordCredentialIdentity` (username + domain, **no password**) into
  the shared **`ASCredentialIdentityStore`** for the QuickType bar / macOS autocomplete.
- **Shared access.** Opens the same App Group vault and unwraps the same shared-Keychain biometric
  key, with its own `LAContext` gate. Memory-constrained and may be killed on app-switch — keep
  minimal; lock immediately when done.
- **macOS vs iOS.** Same API surface; QuickType *bar* is iOS, macOS surfaces autocomplete. On macOS,
  Safari uses the system AutoFill provider, so the extension covers Safari natively.

### Path B — In-browser (surf-r's own WKWebView) — **as-built (Slices 8a–8e)**
- A document-start **`WKUserScript`** in a dedicated **isolated `WKContentWorld`** (the page can't
  read/override/observe it) detects login fields and reports **structure only** (no values) via a
  **`WKScriptMessageHandler`**. Visibility is computed across the **composed tree** (pierces open shadow
  roots). Username-first (two-step) pages are detected with weighted signals.
- surf-r matches the page frame's **exact registrable domain** against the vault (anti-leak: never a
  look-alike, suffix-attack, or `http://`), ranks by recency, and offers via three entry points — **⌘\**,
  a **rail availability badge**, and a **per-field native-overlay key icon** (drawn over the web view,
  not in page DOM) — all routing through one shared **on-demand detect-at-press** + fill path.
- Fill is **biometric-gated, with a master-password fallback** (never a dead end); fills via
  `callAsyncJavaScript` in the isolated world (password passed as an argument, never the clipboard).
- **Save/update** is surf-r's **own** prompt (WKWebView's system "save" rarely fires), driven by a
  **tight gesture-based capture** — a real submit gesture of a form with exactly one visible password +
  adjacent username (multi-password change/signup excluded); options **Save / Not now / Never**.

> **Slice 8a as-built (detect + host-match + fill; save is 8b).** The two load-bearing concerns:
>
> **Every-page JS — isolated & minimal.** The detector (`Autofill.js`) is injected at document-start
> into **all frames** in a **dedicated isolated `WKContentWorld`** (`AutofillBridge.world`). This is the
> keystone control: the page world **cannot read, override, or post to** our script or handler — the
> handler is registered only in that world. The script **egresses nothing** (only `postMessage` to
> native), adds **no globals to the page world** (not fingerprintable), and **detection reports
> structure only** (`{ hasPassword }` + origin) — never values/keystrokes. `__surfrFill` writes
> **visible fields only** and returns booleans. SPA support is a single `MutationObserver` with an
> **aggressive 800 ms coalescing debounce** (≤1 structure-only rescan per window — cheap on heavy
> SPAs); the callback can't widen into reading content. iframes: detected per-frame; **fill is main +
> same-origin only** (cross-origin iframe fill deferred). Shadow DOM: open roots best-effort.
>
> **Host match — anti-leak.** `AutofillMatcher` offers a credential **only** when the frame's
> registrable domain (eTLD+1, via `TrustStore.registrableDomain`) **exactly equals** the credential's,
> over **HTTPS only**. No fuzzy/substring/edit-distance matching. Matching uses the **native**
> `WKFrameInfo.securityOrigin` (a page can't spoof its own origin), and fill targets that
> origin-matched frame. Look-alikes (`evil-example.com`), suffix attacks (`example.com.evil.com` →
> `evil.com`), typo-squats, wrong-TLD, and `http://` are all rejected — proven by the
> `AutofillMatcherTests` matrix. **Both sides are normalized from host-or-URL** before the exact
> compare (`registrableDomain(forHostOrURL:)`), so a stored `www.` host or a full LastPass sign-in URL
> still reduces to the same registrable domain (the import stores the bare registrable domain, and
> `loadItems` self-heals legacy un-normalized hosts) — normalization, not loosening.
>
> **Fill.** Inline keyboard-first picker (⌘\\, `AutofillSuggestionView`), shows **title+host only** (no
> decryption until pick). On pick: biometric gate (`biometricAuthenticateForReveal`, when enabled;
> master-fallback-for-fill on non-biometric Macs is a follow-on) → decrypt → fill via
> **`callAsyncJavaScript(arguments:)`** in the isolated world (password passed as an **argument**,
> never string-interpolated, never the clipboard) → "Filled" toast. surf-r doesn't retain the password
> after the call.
>
> **Threat model.** A page can't reach the handler (isolated world); a spoofed "field present" message
> can at most make the ⌘\\ affordance appear (extraction still needs user summon + biometric + exact
> host match + visible-field-only fill). The **hidden-field trap** (page hides a password field to
> capture the fill) is defeated by visible-only fill — proven deterministically by `AutofillFillTests`
> (loads the fixture at an `https://example.com` origin, fills, asserts traps stay empty).
>
> **Slice 8c as-built — two-step / username-first flows.** Detection now also recognizes a username-
> first page-1 (Amazon, Google, Microsoft, many SSO) with **weighted signals**: a visible field with
> `autocomplete="username"`/`"email"` is a **strong, trusted** login signal; a **bare `type="email"`/
> text** field is **weak** and only counts as a login username with corroborating **login context**
> (URL/title contains signin/login/auth/account/sso, the form `action` does, or a visible "Sign in"
> heading/button). A **newsletter/contact** email box (no context) is therefore **not** offered — proven
> by `AutofillFillTests` (same bare-email markup fires at a `/login` URL, stays silent at a plain URL).
> ⌘\\ on a username-first page fills **only the username** (`__surfrFillUsername` — the password is not
> sent to page 1); no auto-submit. Page 2 (password) uses the existing path: a second ⌘\\ fills the
> password. Cross-page auto-complete (remember the pick, auto-fill page 2) is deliberately deferred.
> The "no candidates" message distinguishes a **detection** miss ("No login field detected") from a
> **match** miss ("No saved login matches this page") so failures are diagnosable.
>
> **8c follow-ups (purely structural — no site-specific code anywhere in detection):**
> - **Shadow-DOM popups.** Detection/fill now **pierce open shadow roots** (`deepQueryAll`) — a login
>   popup that is a web component (password input inside a shadow root) is correctly seen as
>   **single-page** (password present), not mislabeled username-first. Closed shadow roots remain
>   inaccessible (documented). The single rule stays structural: *visible password field present →
>   single-page (fill both); username only, no password anywhere → two-step.*
> - **Same-origin frame split.** If a username and password for one origin live in different frames, the
>   controller **prefers the password signal** (a later username-only report can't overwrite a password
>   context) so it's not mislabeled two-step.
> - **Fill auth = reveal/copy policy, exactly.** Setting **off + unlocked → fill immediately, no
>   prompt**; **on → Touch ID** (refuse if no biometric). No extra prompts beyond the reveal policy.
> - **⌘\\ on a locked vault** unlocks and then **returns to the page and fills** (no eject into the
>   vault surface) — same surface-restore family as the Slice-5 nav fixes.
> - **On-demand detection at press (race fix).** ⌘\\ no longer relies on the last debounced (800ms)
>   observer scan — it runs a **fresh `__surfrDetect()`** in the main frame (+ known subframes) at press
>   time, so a dynamically-injected shadow-DOM login popup that's still settling isn't read stale
>   (the intermittent "no saved login"/mis-detected-two-step symptom). Also hydrates vault items before
>   matching, retries once after ~350ms if fields are present but unmatched, and (DEBUG) logs detected
>   origin→registrable-domain vs vault domains so any residual race is visible. The push observer
>   remains for the live affordance.
> - **Offer/fill require a REAL login form (anti-phishing gate).** Host match alone never offers or
>   fills — a credential surfaces only when detection finds an actual visible login field on the
>   host-matched page. Username-only (two-step) corroboration is **page/form-anchored**: a login
>   URL/title, the field's own form posting to a login endpoint, or a sign-in **heading** (h1/h2/legend)
>   — explicitly **not** a page-level "Log in" button/link (every home page has one; using button text
>   corroborated a home page's search box as a username field). **Search/query boxes are excluded** from
>   detection and fill. So a home page with a "Log in" button + search box offers nothing, and fill only
>   ever targets detected login fields — proven by `test_homePage_loginButtonAndSearch_offersAndFillsNothing`.
> - **Visibility is computed across the COMPOSED tree (shadow boundaries).** A field can look visible
>   inside its own shadow root while the popup's shadow host (or any ancestor) is hidden — e.g. a login
>   popup that's been *closed but only hidden, not removed*. `isVisible` walks field → ancestors →
>   shadow host → … → document and rejects the field if any node is `display:none` / `visibility:hidden`
>   / `opacity:0` / zero-size / off-screen. So a closed (hidden-host) popup behaves like no form at all —
>   no offer, no "filled into invisible fields" (the hidden-field-trap class). Proven by
>   `test_shadowLogin_hiddenHost_offersAndFillsNothing`. `isVisible` also uses the browser's
>   `Element.checkVisibility()` (adds `content-visibility`) and rejects fields inside a `height:0`/
>   `width:0` clipped ancestor (`test_collapsedAncestor_offersAndFillsNothing`).
> - **Documented limit:** a dynamic open-shadow-root popup that **hides rather than removes** its fields
>   on close, via a mechanism none of the above detect (e.g. Barbican), may still report a fill into a
>   no-longer-visible field — workaround: fill while the popup is open. Cross-origin iframe and
>   closed-shadow-root logins remain unsupported. See `known-issues.md`.

> **Slice 8b as-built (save / update prompt — WF-8).** surf-r drives its **own** quiet save prompt; this
> is the only place the every-page JS reads field **values**, gated tightly:
> - **Trigger:** an explicit submit GESTURE — form `submit`, Enter in a password field, or a submit-ish
>   button click — of a form with **exactly one VISIBLE password** (excludes change/signup forms with
>   current+new+confirm) and a non-empty value + adjacent username. Reuses `isVisible` (hidden-field
>   trap-safe). **No `beforeunload`/navigation heuristic** — a gesture is stronger evidence and avoids
>   spurious prompts from abandoned half-filled forms. HTTPS only; the host is the **native** frame
>   origin (unspoofable). A **setting "Offer to save logins" (default on)** disables capture.
> - **Decision (`SaveDecision`, pure + tested):** vs existing same-registrable-domain creds — exact dup
>   (same username **and** password) → no prompt; same username, different password → **Update**; new →
>   **Save**; per-site **Never** list → no prompt. The dup check decrypts existing items; the decrypted
>   JSON Data is **zeroed immediately** (`decryptPayload` `defer resetBytes`) and the plaintext copies
>   dropped right after.
> - **Captured-secret lifetime:** held in a `WipeableSecret` with a **bounded ~90s timeout** and
>   **zero-on-every-exit** — save / Never / dismiss(✕) / tab-switch / auto-lock / timeout / replacement /
>   `deinit` all wipe it. The only retained copy.
> - **UX:** unobtrusive bottom bar with **three labeled outcomes** — **Not now** (dismiss this prompt
>   only; re-offers next qualifying login; never writes the never-list), **Never** (persisted per-site
>   suppression), **Save/Update**. Auto-dismiss if ignored (no re-nag). Locked vault → **"Unlock &
>   Save"** (unlock, then store on the same page; decision recomputed post-unlock so a dup is still
>   skipped — no eject). Proven: single-password login captures; change-form (3 passwords), signup (2
>   passwords), hidden-password, and **password-only pages** do **not** (`test_save_*`).
> - **Capture requires a non-empty adjacent username** — a **password-only page** (e.g. a two-step
>   login's page 2) can't be deduped, so capturing it would spuriously re-offer the just-filled
>   credential. Belt-and-suspenders: a password already stored for the host is a **dup regardless of
>   username**. **Deferred to v1.5:** stateful cross-page username-carry for capturing a *genuinely new*
>   two-step login (8c still fills them; manual add covers new ones). **Edge:** a new account that
>   *reuses* an existing password on the same site won't be auto-offered (password reuse is discouraged).

> **Slice 8e as-built (per-field click-to-fill key icon).** A key icon drawn **adjacent to each
> detected fillable field**, rendered in surf-r's **native chrome overlaid on the web view** (NOT page
> DOM) — the page's JS can't query, read, or `MutationObserver`-detect it, so it doesn't disclose that
> surf-r ran or that a credential exists (a closed-shadow-root *host* would still be observable; only a
> native layer is invisible). The element is a **generic key glyph — no username/count/account**.
> Isolated-world JS reports field **anchors** (`{kind,x,y,w,h}` viewport rects) inside the `detected`
> message + on scroll/resize; the native overlay positions icons by those rects. **Scroll:** a native
> overlay can't track WebKit's async scroll, so on scroll the icons **hide** and **re-anchor on settle**
> (~140ms). **Colour (honest signal):** amber = a saved login is available for this field; on a
> **successful fill** the field's icon latches **green** = "surf-r filled this" (a fact we own — NOT
> "you're signed in"); stays amber if fill fails; cleared on navigation. **Click → the same
> `.fillCredential` path** as ⌘\ (on-demand detect + auth gate + JS fill) — third trigger, one
> implementation; a single match fills directly, multiple show the picker. Per-field, per-page (two-step
> gets it on each page); main-frame only (subframe anchors aren't in the overlay's coordinate space);
> gated by vault-unlocked. Headless: anchor kinds/rects + fill-result (`test_fieldAnchors_*`,
> `test_fill_returnsFilledKinds`); positioning/scroll is driven-run.
> **8e fixes:** (a) the fill auth gate now has a real **master-password fallback** — biometric cancel
> ("Use master password") or no-biometric presents a master prompt (`FillAuth.needsMasterFallback`,
> tested) instead of silently aborting (it was a dead button). (b) the **green latch clears on every
> page load/reload** via a `pageload` message (the URL-KVO misses same-URL reload), so green never
> outlives the field's contents. (c) the icon sits **just past the field's trailing edge** (narrow-form
> fallback: tuck inside) so it doesn't overlap the site's reveal-eye/clear-X.

> **Slice 8d as-built (login-available badge).** *(8e adds the per-field icon as the primary affordance;
> this stays as the host-level hint, now shown on **any** tab state via the host's representative web
> tab — clicking switches to it, then fills.)* A quiet, clickable **key glyph** on the **host's rail
> tile** (native chrome, bottom-leading; reuses the badge vocabulary alongside the
> trust ✓ / insecure ⚠ / count badges). Its signal is **identical to the ⌘\ offer**: vault unlocked +
> a real detected login form whose registrable host matches a stored credential (`LoginKeyBadge` shows
> iff `AutofillController.candidates(items:)` is non-empty — the same matcher path; never host-match-
> alone, never on form-less pages). **Privacy:** renders a key only — never the username, a count, or
> which account; derived in native, shown in native, nothing in page DOM. **Clickable:** posts the same
> `.fillCredential` as ⌘\ → identical on-demand detection + biometric/auth gate + picker + JS fill
> (one shared path; mouse and keyboard reach the same flow). **Edges:** clears on navigation to a
> non-matching host (controller resets); reflects per-page detection on two-step logins (shows on
> whichever page has a fillable field); **independent of the "Require auth to reveal/copy/fill"
> setting** — the badge shows availability, auth happens at click-time.

### v2 design-ahead — passkeys
Later, the extension declares `ProvidesPasskeys` (in `NSExtension ▸ ASCredentialProviderExtensionCapabilities`)
and implements `prepareInterface(forPasskeyRegistration:)` + the assertion path, returning
`ASPasskeyRegistrationCredential` / `ASPasskeyAssertionCredential` and indexing via
`ASPasskeyCredentialIdentity`. Note third-party providers **can't yet act as the cross-device (QR
hybrid) authenticator** — that's reserved for iCloud Keychain. Building the extension target now makes
v2 an addition, not a restructure.

---

## 8. Password &amp; passphrase generator

Two modes; entropy shown live; length does the work rather than arbitrary composition rules.

- **Random characters.** Default **16–20 chars**, full set (≈95 chars ≈6.5 bits/char → ~105 bits at 16).
  Per-class toggles; **require ≥1 of each** selected class; **exclude ambiguous** (`0 O l 1 I`) option.
- **Diceware passphrase.** Default **5–6 words** (EFF list: 6 words ≈77 bits; +12.9 bits/word).
  Separator + capitalization options. Master-password guidance: **6+ words** (~77 bits).
- Both modes show a **live entropy estimate (bits)** + a strength meter (zxcvbn-style). CryptoKit CSPRNG;
  the word list is **bundled (no network)**.

> **Slice 6 as-built.** Pure logic in **SurfrCore** (`PasswordGenerator.swift`), UI inline in the
> add/edit form (`GeneratorView.swift` popover; no standalone surface). **Entropy is computed
> directly** (`length × log2(poolSize)`; passphrase `words × log2(7776)`) rather than zxcvbn-estimated
> — we control the generation process, so it's exact; the "≥1 of each class" guarantee makes the
> random figure a documented **<1-bit overestimate**. Strength bands by bits: **<40 Weak · 40–60 Fair
> · 60–80 Strong · 80+ Excellent**. **Randomness:** `SecRandomCopyBytes` (CryptoKit exposes no
> integer RNG — its randomness *is* the system CSPRNG) with **rejection sampling** for unbiased
> indices; the guaranteed-placement Fisher–Yates shuffle uses the **same** unbiased index (no bias
> reintroduced at shuffle time). **Random:** length 8–64 (default 20); symbol set
> `!@#$%^&*()-_=+[]{};:,.?/` (no quotes/backslash/space, for paste/parse robustness); exclude-ambiguous
> set `0 O o l I 1 |`; the UI **prevents disabling the last character class** (visible message, not a
> silent re-enable). **Diceware:** 4–10 words (default 6), separators hyphen/period/underscore/space,
> capitalization none/Title/random-word. **EFF large wordlist** (7776 words) bundled as a SurfrCore
> SwiftPM resource (`Bundle.module`), **CC-BY 3.0** (attribution in
> `SurfrCore/EFF_WORDLIST_LICENSE.md`); the loader **fails loud** if the count isn't exactly 7776.

---

## 9. TOTP handling

- **Storage.** Seed as an `otpauth://totp/…` URI (label, Base32 secret, issuer, algorithm, digits,
  period), encrypted under the parent item's key. Import via QR scan or pasted URI.
- **Generation.** Per **RFC 6238**; defaults **6 digits / 30 s / SHA-1** (max compatibility); honor
  8-digit / SHA-256/512 when the URI specifies.
- **Display / fill.** Current code with a countdown ring; one-tap copy; offer to fill after the password.
- **Single-vault tradeoff.** Keeping TOTP beside the password collapses two factors into one if the
  vault is breached. Make it **optional and clearly disclosed**, mark TOTP items so a future setting
  could require a separate unlock, and **never log seeds**.

> **Slice 7 as-built.** RFC-6238 generation (SHA-1/256/512, 6/8 digits) + `otpauth://` parse + Base32
> live in SurfrCore (`TOTP.swift`), verified against the RFC test vectors. **Google Authenticator
> migration** is decoded **natively**: `otpauth-migration://offline?data=…` → base64 → a hand-written
> minimal protobuf reader for `MigrationPayload` (`OTPMigration.swift`, no protobuf dependency) →
> standard `otpauth://`s. Import sources: **paste** or a **QR decoded from an image** via Vision
> (`VNDetectBarcodesRequest`) — **no camera entitlement**. **Image hygiene matches the CSV path:** the
> screenshot is read once under a single security-scoped window, its bytes wiped after decode, decoded
> secrets dropped after store, and the user is **prompted to delete** the image afterward (never auto;
> SSD caveat). Multi-entry migration → a preview that **defaults to create-new** and only **offers**
> an attach to a confidently-matched login (exactly-one match; never silent auto-attach). The live
> code + countdown ring use `TimelineView(.periodic)` scoped to the open detail — **no background
> ticking** after navigating away; the secret is cleared on the zero-on-disappear path.

---

## 10. UI / UX (wireframe reference)

Everything reuses surf-r's established language: the 48px left rail, full-page surfaces on the shared
`PageScaffold` (header + live search + grouped list), host-grouped favicon tiles, the green ✓ / amber ⚠
badge vocabulary, the dimmed-overlay treatment (as the Spotlight omnibox), keyboard-first interaction.
Visual versions are in the PDF; these are the implementation notes.

- **WF-1 · Rail integration.** The vault is one more pinned internal-surface icon (key glyph), behaving
  like history/downloads/trusted/shortcuts — drag-reorderable, green-when-active, single-instance
  ephemeral (`RailSurface`, `BrowserState`).
- **WF-2 · First-run flow.** Master password (strength meter, 6+ word guidance) → enable biometric →
  **mandatory** Recovery Kit PDF → done. The kit step is **non-skippable**.
- **WF-3 · Unlock screen.** Minimal centered card over the dimmed page (same overlay as Spotlight).
  Biometric automatic; master-password fallback one tap away, no first-miss penalty.
- **WF-4 · Vault list.** `PageScaffold` (header + live search + grouped list). Credential rows reuse the
  host-grouped favicon tile; right-hand badge reuses green/amber for password health; TOTP marked inline.
  `⌘F` search, ↑↓ navigate, ↵ open. Favicons via the existing `FaviconService`.
- **WF-5 · Item detail.** Username (copy), password (masked, reveal/copy **biometric-gated**), TOTP
  (live code + countdown ring, copy), website, notes, edit/delete. Health badge mirrors the trust-badge
  styling.
- **WF-6 · Add/edit + inline generator.** Form fields + a generator popover: mode toggle (random /
  passphrase), length slider, class toggles, exclude-ambiguous, live entropy badge (green). "Use
  password" writes straight into the field.
- **WF-7 · In-browser fill (Path B).** surf-r-owned inline suggestion anchored to the focused field,
  Face-ID-gated, summonable by shortcut (e.g. `⌘\`). Filled in-page via JS — never via the system
  clipboard. Distinct from the system QuickType bar.
- **WF-8 · Save-credential prompt.** surf-r drives this on form submit (native save prompt unreliable).
  Quiet, dismissible, with a per-site "never".
- **WF-9 · Security check ("Watchtower"-style).** `PageScaffold` list grouped Weak / Reused / 2FA-available,
  amber/blue vocabulary. **Local-only** checks; breach (HIBP) lookups deferred (need a network call).
- **WF-10 · Recovery Kit.** The printable artifact from first run: grouped high-entropy code, a place to
  note the master password, blunt instructions ("no backstop", "anyone with this code + your device can
  open the vault").

**UX principles carried over:** keyboard-first everywhere; don't make the secure path the hard path
(biometric unlock + one-keystroke fill); reuse existing components rather than inventing patterns; make
invisible risk visible without nagging.

---

## 11. Build slices &amp; sequencing

Vertical, each buildable/testable on the Mac before the next; crypto + storage land first as headless,
unit-tested cores; UI follows; the Apple-gated extension lands last in v1.

Status through 2026-06: **Slices 1–8 done** (8 expanded into 8a–8e — see below); **9–10 remain**.

| # | Slice | Status | Ships · verified by | Effort |
|----|----|----|----|----|
| 1 | **Crypto core** | ✅ done | Argon2id vendoring + key hierarchy + seal/open. Headless; unit tests for wrap/unwrap, tamper detection, master-pw-change re-wrap. | med |
| 2 | Vault store + lock state | ✅ done | GRDB encrypted `items`; LOCKED/UNLOCKED machine; key-zeroing on lock. Tests for round-trip + lock eviction. | low |
| 3 | Master-pw unlock + Recovery Kit | ✅ done | First-run set-master, master unlock UI, mandatory Recovery Kit PDF. Verify recovery resets a "forgotten" master. | med |
| 4 | Biometric unlock | ✅ done | SE-wrapped copy, `LAContext`, `.biometryCurrentSet`. **Hardware-tested** (no SE in Simulator). | med |
| 5 | Vault list · detail · add/edit | ✅ done | The `PageScaffold` surfaces (WF-4/5/6). Favicons via existing service. | med |
| 5b | **CSV import** | ✅ done | LastPass / Bitwarden / Chrome / Safari CSV (auto-detected); column-mapping → bulk atomic encrypt-and-store. Plaintext-file discipline (read-once, prompt-to-delete). 1Password + manual mapping deferred. | med |
| 6 | Generator | ✅ done | Random + passphrase, direct-entropy readout, inline popover (WF-6). Bundled EFF wordlist (CC-BY). | low |
| 7 | TOTP | ✅ done | `otpauth://` import (paste + QR-from-image), **native Google Authenticator `otpauth-migration://`** decode, RFC-6238, countdown UI. | low |
| 8a | In-browser detect + host-match + fill | ✅ done | Isolated-world `WKContentWorld` detection (structure-only), exact-registrable-host anti-leak, on-demand detect-at-press, inline picker (WF-7), ⌘\. | med |
| 8c | Two-step / username-first fill | ✅ done | Username-only page detection (weighted: autocomplete strong, bare-email needs login context), fill username on page 1. | low |
| 8b | Save / update prompt | ✅ done | surf-r's own save bar (WF-8); gesture-based capture (tight: single visible password + adjacent username; multi-password excluded); Save / Not now / Never. | med |
| 8d | Rail availability badge | ✅ done | Host-level "saved login available" key on the rail tile (native chrome), all tab states. | low |
| 8e | Per-field native-overlay icon | ✅ done | Key icon adjacent to each field (native overlay, not page DOM); amber=available / green=surf-r-filled; master-password fill fallback. | med |
| 9 | Security check | ☐ remaining | Local weak/reused/2FA-available surface (WF-9); junk-host import hygiene. | low |
| 10 | System AutoFill extension | ☐ remaining | `ASCredentialProviderExtension` + identity-store index + biometric gate; relocate `LoginPayload` to `SurfrCore`. Needs Apple-Dev enrolment + entitlements (§12). | high |

**v1.5** — Encrypted AirDrop export/import to the iOS app; **two-step new-login save-capture** (stateful
cross-page username-carry). **v2** — Passkeys (`ASPasskeyCredential`); schema already accommodates.

**Start with Slice 1** (headless crypto core) — highest-risk, highest-leverage, no UI dependencies;
getting the key hierarchy right unblocks everything else.

> **Slice 5b as-built (CSV import).** Plaintext-file lifecycle is the design center: the CSV is read
> **once**, read-only + uncached, under a **single security-scoped access window** held from pick →
> parse → import → delete (released on every exit path); the raw bytes are wiped after parse and the
> decrypted candidates dropped right after they're stored. Nothing is copied/moved/logged (only
> counts). After import, the user is **prompted** to delete the original (never auto), with an honest
> SSD/APFS secure-erase caveat. Rows encrypt under fresh per-item keys and commit in **one atomic
> `upsertMany` transaction** (a failure changes nothing). Dedupe is **exact-match across all fields
> incl. password** (same title/host/username but a different password is a distinct credential, not a
> dupe). Formats auto-detected: LastPass + Bitwarden + Chrome + Safari (most-specific header match;
> unknown → "unrecognized format" error); manual column-mapping + 1Password deferred. A correct
> RFC-4180 parser (iterating **unicode scalars**, so `\r\n` isn't grapheme-clustered) handles quoted
> commas/newlines. Bulk import fetches **zero** favicons — the list fetches lazily on row-appear,
> now bounded by a `FaviconService` concurrency cap. LastPass omits TOTP seeds → a blanket re-add
> note (Slice 7). 25 MB file cap; 0-row file → clean "no rows" message.

---

## 12. Human-only steps (pause and hand to the user)

- Apple Developer Program enrolment and any signing identity / certificate creation.
- Creating the **App Group** + **shared Keychain access group**, and first-time capability prompts.
- Adding the **AutoFill credential-provider extension** target capability (and later the passkey capability).
- Testing biometric + Secure Enclave flows **on real hardware** (the Simulator has no SE).
- Anything requiring payment or acceptance of Apple's terms.

> **Slice 4 as-built notes (entitlements).**
> - **Keychain access group:** `com.zeviter.surfr.vault` (entitlement form `$(AppIdentifierPrefix)com.zeviter.surfr.vault`), added via Xcode ▸ Signing & Capabilities ▸ Keychain Sharing. The code resolves the full team-prefixed group at runtime, so no Team ID is committed. The biometric door's SE key + ECIES blob live in this group (data-protection keychain, `WhenUnlockedThisDeviceOnly`) so the **AutoFill extension (Slice 10)** can share them — the extension target must declare the **same** group.
> - **App Sandbox file access:** enabling Keychain Sharing turns on **App Sandbox**, which defaults *User Selected File* access to **read-only**. The Recovery Kit's `NSSavePanel` needs **read/write** (a read-only sandbox crashes the save panel with `EXC_BREAKPOINT`). Set **App Sandbox ▸ File Access ▸ User Selected File = Read/Write** (`ENABLE_USER_SELECTED_FILES = readwrite`). The **iOS target** uses the document picker instead, and the **AutoFill extension (Slice 10)** has its own sandbox/entitlement set — both must be configured when they're added.
> - **Sandbox container path + reset.** Once sandboxed, `Application Support` resolves to the **container** (`~/Library/Containers/com.zeviter.surfr/Data/Library/Application Support/Surfr/`), not `~/Library/Application Support/Surfr/`. Deleting the non-container `vault.sqlite` therefore does **not** wipe the app's vault, and the Keychain biometric material (SE key + blob, access group `com.zeviter.surfr.vault`) is separate from the SQLite vault entirely. A correct reset must clear **both**: use the in-app **Reset Vault (Debug)** affordance (`⌃⌥⌘R`), which calls `VaultStore.wipeAll()` + the biometric `disable()`. `load()` also self-heals an orphaned half-state (Keychain material with no vault file → purge → clean first-run).

---

## 13. Threat model &amp; honest limitations

| Protects against | Does **not** protect against |
|----|----|
| Device-at-rest theft (vault encrypted; master/biometric gate; keys zeroed on lock). | On-device malware / keylogger while the vault is unlocked. |
| Casual snooping (auto-lock; biometric reveal/copy gating). | A coerced master password or a stolen Recovery Kit — the kit is a real second door. |
| Cloud-leak exposure (nothing uploaded; no server to breach). | Two-factor independence when TOTP shares the vault — disclosed and optional. |
| Vendor lock-in / telemetry (self-owned; collects nothing). | Total loss if **both** master password and Recovery Kit are lost — unrecoverable by design. |
| Exposure of credential *contents* at rest (usernames/passwords/notes/TOTP are AES-256-GCM encrypted; only ciphertext is on disk). | **Metadata leak from the raw DB file.** Item titles and associated hosts are stored as cleartext metadata (§6), so an attacker with the database file but **not** the vault key can still learn *which sites you have entries for* — just not the credentials themselves. |

State these honestly in any user-facing copy, consistent with `spec.md` §9.

---

## 14. Open questions for review

Six forks to confirm before slicing. Recommendation noted on each; none blocks starting Slice 1.

| Question | Recommendation |
|----|----|
| Auto-lock default, and allow "Never"? | **5-min idle + lock on background**; allow "Never" only behind a warning. |
| Recovery code format | Grouped alphanumeric (WF-10). A diceware word-list is the readable alternative. |
| TOTP: opt-in per item, or on by default? | **Opt-in per item**, with the single-vault tradeoff disclosed. |
| Master-password strength enforcement | Soft floor (zxcvbn + 6-word guidance), not a hard rule. |
| Vault favicons: network `FaviconService`, or monogram-only? | Reuse **`FaviconService`** (already privacy-scoped); offer a monogram-only toggle. |
| Security check scope in v1 | **Local weak/reused/2FA-available only**; defer breach (HIBP) lookups. |

---

## 15. Conventions &amp; cross-references

- New planned source files (under the single `Surfr` target until `SurfrCore` extraction): `VaultCrypto.swift`,
  `VaultStore.swift` (GRDB), `VaultLock.swift` (state machine), `RecoveryKit.swift`, `Generator.swift`,
  `TOTP.swift`, vault UI on `PageScaffold` (`VaultListView.swift`, `VaultItemView.swift`, etc.), the
  in-page fill script + handler, and a separate `SurfrAutoFill` extension target.
  > **Slice 1 amendment.** The headless crypto core (`VaultCrypto.swift`) and its vendored Argon2id C
  > target land **early** in a local `SurfrCore` SwiftPM package — the seed of the eventual Phase-6
  > extraction — so the crypto is genuinely headless and CLI-unit-testable from day one. This is a
  > deliberate, narrow exception to "single `Surfr` target until extraction": **only the vault crypto
  > moves in now**; store/lock/UI and everything else stay in the `Surfr` target until Phase 6. The
  > app target links the package when later slices need it.
  > **Slice 2/5/6/7 amendment.** `VaultStore.swift` (Slice 2), the **generator** (Slice 6, in
  > `PasswordGenerator.swift` + the bundled EFF wordlist resource), and the **TOTP/`otpauth`/Base32/
  > `otpauth-migration` decoder** (Slice 7, in `TOTP.swift` + `OTPMigration.swift`) **also live in
  > `SurfrCore`** — they're pure, headless, and testable via `swift test` (RFC-6238 vectors, the
  > migration protobuf, generator entropy + unbiased-index stats). `LoginPayload` is import-clean in
  > the app target for now, relocating to `SurfrCore` with the AutoFill extension (Slice 10). UI
  > (incl. `VaultItemView`, the import flows, `GeneratorView`) stays in the app target.
- Written **import-clean** (no AppKit/SwiftUI/WebKit in crypto/store/lock layers) to ease the future
  `SurfrCore` move, consistent with `spec.md` §6 Phase 6 / §8.
- **No secrets in the repo**; respect `.gitignore`; stop and warn if a secret is staged.
- **No telemetry/analytics anywhere.**
- This file is authoritative for the vault; `spec.md` remains authoritative for overall scope/architecture,
  `ui-wireframes.md` for shared UI patterns, `backlog.md` for outstanding work, `known-issues.md` for bugs.

> **CLAUDE.md pointer to add:** under "Source of truth", add a line such as —
> `**`docs/vault-spec.md`** is authoritative for the password vault + AutoFill (F5) — read it before any vault/credential/autofill work.`
