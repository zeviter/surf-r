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

### Path B — In-browser (surf-r's own WKWebView)
- A document-start **`WKUserScript`** detects `input[type=password]`, `autocomplete="username"` /
  `"current-password"` fields and reports field metadata via a **`WKScriptMessageHandler`**.
- surf-r matches the host → ranks credentials by recency → shows an **inline suggestion in its own UI**
  (keyboard-first; a ⌘-shortcut summons for the current host), gated by biometrics.
- Fills via JS, then drives surf-r's **own** save-credential prompt. **WKWebView caveat:** native
  Password AutoFill fills sometimes but the system "save password" prompt usually doesn't fire — hence
  Path B owns its save UI for surf-r's surfaces.

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

| # | Slice | Ships · verified by | Effort |
|----|----|----|----|
| 1 | **Crypto core** | Argon2id vendoring + key hierarchy + seal/open. Headless; unit tests for wrap/unwrap, tamper detection, master-pw-change re-wrap. | med |
| 2 | Vault store + lock state | GRDB encrypted `items`; LOCKED/UNLOCKED machine; key-zeroing on lock. Tests for round-trip + lock eviction. | low |
| 3 | Master-pw unlock + Recovery Kit | First-run set-master, master unlock UI, mandatory Recovery Kit PDF. Verify recovery resets a "forgotten" master. | med |
| 4 | Biometric unlock | SE-wrapped copy, `LAContext`, `.biometryCurrentSet`. **Hardware-tested** (no SE in Simulator). | med |
| 5 | Vault list · detail · add/edit | The `PageScaffold` surfaces (WF-4/5/6). Favicons via existing service. | med |
| 6 | Generator | Random + passphrase, entropy readout, inline + standalone (WF-6). | low |
| 7 | TOTP | otpauth import (paste + QR), RFC 6238, countdown UI. | low |
| 8 | In-browser fill + save | `WKUserScript` field detection, inline suggestion (WF-7), own save prompt (WF-8). | med |
| 9 | Security check | Local weak/reused/2FA-available surface (WF-9). | low |
| 10 | System AutoFill extension | `ASCredentialProviderExtension` + identity-store index + biometric gate. Needs Apple-Dev enrolment + entitlements (§12). | high |

**v1.5** — Encrypted AirDrop export/import to the iOS app. **v2** — Passkeys (`ASPasskeyCredential`);
schema already accommodates.

**Start with Slice 1** (headless crypto core) — highest-risk, highest-leverage, no UI dependencies;
getting the key hierarchy right unblocks everything else.

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
- Written **import-clean** (no AppKit/SwiftUI/WebKit in crypto/store/lock layers) to ease the future
  `SurfrCore` move, consistent with `spec.md` §6 Phase 6 / §8.
- **No secrets in the repo**; respect `.gitignore`; stop and warn if a secret is staged.
- **No telemetry/analytics anywhere.**
- This file is authoritative for the vault; `spec.md` remains authoritative for overall scope/architecture,
  `ui-wireframes.md` for shared UI patterns, `backlog.md` for outstanding work, `known-issues.md` for bugs.

> **CLAUDE.md pointer to add:** under "Source of truth", add a line such as —
> `**`docs/vault-spec.md`** is authoritative for the password vault + AutoFill (F5) — read it before any vault/credential/autofill work.`
