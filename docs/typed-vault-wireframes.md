# typed-vault-wireframes.md — surf-r typed vault (WF-11+)

> Authoritative UI/behaviour spec for the **typed vault**: extending the password vault into four
> item types — **Passwords · Secure Notes · Addresses · Payment Methods** — with click-to-fill
> (never auto-fill), a uniform ESC/back nav model, and the LastPass import mapping. Continues the
> vault-spec WF series (WF-1…WF-10) as **WF-11+**.
>
> **Authoritative for typed-vault UI/layout/behaviour.** Where this conflicts with `spec.md`'s
> feature table, this file wins for UI; `vault-spec.md` wins for vault architecture/crypto;
> `ui-wireframes.md` wins for the browser shell (rail/spotlight/tabs). **The "Build rules" blocks are
> what CC implements against — not the ASCII mockups** (same convention as `ui-wireframes.md`).
>
> Status: ☐ design, not yet built. Reuses existing vault patterns; no new visual language. A
> companion rendered PDF exists for human review; this `.md` is the source of truth.

---

## 0. Decisions locked

| Fork | Decision |
|----|----|
| **A · Fill** | **Never auto-fill anything.** Where a saved item can fill a field, surf-r shows the per-field overlay icon adjacent to that field (same affordance as logins). User clicks to fill. Multiple matching cards/addresses → the inline picker lets them choose. Click-to-fill still requires field detection — see TV-3. |
| **B · Taxonomy** | LastPass `NoteType:Credit Card` → **Payment**; `NoteType:Address` → **Address**; everything else (notes + the long tail: Bank Account, Passport, SSN, Wi-Fi, SSH Key, …) → **Secure Note** with the original body preserved verbatim. `NoteType:` is always line 1; parse as an exact first-line prefix. Missing/garbled marker → generic note (never misfile). |
| **C · Layout** | One vault surface; a segmented control (Passwords · Notes · Addresses · Payment) on the shared `PageScaffold`. Rail stays one key glyph. The `+` becomes a type picker. |
| **D · Search** | Sensitive fields (card number, CVV, structured PII) live encrypted-payload-only; reveal/copy biometric-gated like passwords. List search is **title/host/label only** — the Slice-5 zero-decryption list property survives. No full-text note/card search in v1. |

**Architectural reassurance — no crypto/store change.** `items.type` already exists
(`login · passkey · reserved`); the payload is a type-agnostic AES-256-GCM blob. New types are new
JSON shapes under the same envelope — exactly the property that lets passkeys drop in for v2. The
Slice-9 closeout already sets a `secureNote` marker on the imported `sn` items, so this work is
purely additive: re-classify by `NoteType`, build the editors.

---

## 1. Item model & the LastPass mapping — WF-11

Four user-facing types, one storage path. Classification happens at import + backfill by reading the
decrypted note body's first line.

| Type | Payload shape (inside the encrypted blob) | From LastPass |
|----|----|----|
| `login` *(existing)* | username, password, notes, totp, urls — unchanged | password entries |
| `payment` | nickname, cardholderName, number\*, type, expiry, startDate, cvv\*, notes | `NoteType:Credit Card` |
| `address` | label, firstName, lastName, company, line1, line2, city, county (opt·UK), stateProvince, postalCode, country, phone, email — **each discrete** | `NoteType:Address` |
| `secureNote` | title + free-text body (raw original preserved) | all other `NoteType:` + plain notes |

\* `number` and `cvv` are sensitive — masked, reveal/copy biometric-gated, never in a cleartext column.

**Build rules — WF-11 (parsing; headless-testable, TV-1)**
- Read decrypted note body; line 1 matches `^NoteType:Credit Card` → payment; `^NoteType:Address` →
  address; else → secureNote.
- For payment/address, extract the labelled lines (`Number:`, `Security Code:`, `Address 1:`,
  `City / Town:`, `County:`, `Zip / Postal Code:`, `Country:`, …) into structured fields. **Keep the
  raw body too** — if any line doesn't map, nothing is lost and the note body stays viewable.
- Phone fields arrive as JSON (`{"num":...,"cc3l":"GBR"}`) — parse leniently; on failure keep the raw
  string. Never drop data.
- Missing, misspelled, or absent `NoteType:` → secureNote. Misfiling is worse than generic.
- Classification + extraction is a pure function over the decrypted body — unit-test against the real
  LastPass export samples.

---

## 2. The vault list — segmented by type — WF-12

```
┌────┬─────────────────────────────────────────────────────────────┐
│ ▢  │  Vault            ● security check   +                       │
│ ▢  │  ┌──────────────┬───────┬────────────┬──────────┐           │
│ ── │  │ Passwords 142│Notes18│Addresses 3 │Payment 4 │           │
│ ▣  │  └──────────────┴───────┴────────────┴──────────┘           │   ▣ = vault (green, active)
│ ▢  │  ⌕ Search titles…                                            │
│ ▢  │  ┌───────────────────────────────────────────────┐          │
│    │  │ [G]  github.com        zeviter@…       [STRONG]  │          │
│    │  │ [f]  figma.com         zeviter@…       [REUSED]  │          │
│    │  │ [b]  bank.example      zeviter · 2FA   [ TOTP ]  │          │
│    │  └───────────────────────────────────────────────┘          │
└────┴─────────────────────────────────────────────────────────────┘
```
*WF-12 · Passwords segment active. One `PageScaffold` surface; the segmented control swaps the list;
rail stays a single key glyph (green = active surface). Login rows unchanged from WF-4.*

### Per-type row anatomy
| Segment | Row = | Right side |
|----|----|----|
| Passwords | favicon tile + title(host) + username | health badge (green STRONG / amber WEAK·REUSED / blue TOTP) |
| Notes | note glyph + title + 1-line snippet (title only if body sensitive) | — |
| Addresses | pin glyph + label + "Name · City" | fill-available hint (TV-3) |
| Payment | card-type glyph + nickname + "•••• last4" | fill-available hint (TV-3) |

**Build rules — WF-12**
- Single surface, single rail icon. Segmented control sits in the `PageScaffold` header, above the
  search field; selection persists for the session.
- Each segment shows its count; an empty segment shows an "all clear / nothing here yet" empty state,
  not a blank.
- Search filters the **active segment** by **title/host/label only** (D) — never decrypts payloads to
  search. The list renders from cleartext metadata exactly as Slice 5.
- The `+` opens the type picker (WF-13). The security-check shield (Slice 9) stays in the header and
  audits the **Passwords segment only**.
- Reuse the existing favicon tile, badge vocabulary, active states. Address/Payment rows use generic
  glyphs (no favicon).

---

## 3. Add-new — the type picker — WF-13

```
┌─────────────────────────────┐
│ New item…                   │
├─────────────────────────────┤
│ 🔑  Password                │
│ ✎   Secure Note             │
│ 📍  Address                 │
│ 💳  Payment Method          │
└─────────────────────────────┘
```
*WF-13 · Clicking `+` opens this small picker (reuse the dimmed-overlay / menu treatment). Each choice
routes to the matching editor (WF-6 login · WF-15 note · WF-16 address · WF-17 payment).*

**Build rules — WF-13**
- Four choices → four editors. New item is created with the chosen `type`; no "convert type" flow in
  v1.
- ESC / click-away dismisses the picker with no item created (per the nav model, WF-19).
- Default focus on the first option; ↑↓ + ↵ select (keyboard-first).

---

## 4. Login detail / edit — unchanged — WF-14 (ref WF-5/6)

No change. Listed so the nav model and segmented list treat it as one of the four. Username (copy),
password (masked, reveal/copy biometric-gated), TOTP (live code + ring), website, notes, the inline
generator on edit. The per-field fill icon and `⌘\` behave exactly as Slice 8.

---

## 5. Secure Note — detail / edit — WF-15

```
┌────┬──────────────────────────────────────────────┐
│ ▢  │  ✎  Passport (UK)            Edit   Delete…   │
│ ▣  │  TITLE                                        │
│    │  Passport (UK)                                │
│    │  NOTE                                         │
│    │  NoteType:Passport                            │
│    │  Number: ###### #####                         │
│    │  Country: GB                                  │
│    │  Expiry: June, 2031                           │
│    │  Notes: in the safe                           │
└────┴──────────────────────────────────────────────┘
```
*WF-15 · A notepad: title + free-text body. Imported long-tail items (Passport, Bank Account, Wi-Fi,
…) show their preserved raw body — no structured editor. Read in detail; edit is a plain multi-line
text field.*

**Build rules — WF-15**
- Two fields: title (cleartext metadata, searchable) + body (encrypted payload, **not** searchable).
  Free-text read/write — a notepad in the vault.
- Body is sensitive-by-default: gated by vault-unlock (you're already past the lock to view detail).
  Copy-whole-note allowed; mark the clipboard concealed + 30s auto-clear like passwords.
- No structured parsing in the editor — the raw imported body is the source of truth. (Structured
  Bank Account / Wi-Fi editors are explicitly out of v1; backlog.)
- Excluded from the security audit and from autofill matching (type ≠ login).

---

## 6. Address — detail / edit — WF-16

```
┌────┬──────────────────────────────────────────────┐
│ ▢  │  📍  Home                   Edit   Delete…    │
│ ▣  │  NAME              zeviter [last]        copy   │
│    │  ADDRESS LINE 1    [line 1]            copy   │
│    │  CITY / DISTRICT   London              copy   │
│    │  COUNTY (UK,opt)   Greater London      copy   │
│    │  POSTAL CODE       XX# #XX             copy   │
│    │  COUNTRY           United Kingdom      copy   │
│    │  EMAIL             zeviter@example.com   copy   │
└────┴──────────────────────────────────────────────┘
```
*WF-16 · Discrete structured fields mapped from the LastPass Address note — each fillable separately.
Per-field copy. Empty fields omitted in detail (a UK address shows County, not State).*

**Build rules — WF-16**
- Discrete fields (each its own column in the payload, **none concatenated**): label, first/last name,
  company, **address line 1**, **address line 2 (optional)**, **city/district**,
  **county (optional — UK)**, **state/province**, **postal/ZIP**, **country**, phone, email. County and
  state coexist as separate nullable fields (UK has county-no-state; US the reverse) — never fold one
  into the other.
- Detail omits empty fields; edit shows all. Populate from the parsed note; keep the raw imported body
  recoverable for anything that didn't map.
- All field values are encrypted-payload; per-field copy (concealed clipboard). **Not** in any
  cleartext-searchable column — only the label/title is searchable.
- Store values as entered — no auto-formatting of postcode/phone.
- Click-to-fill into web address forms = TV-3; discrete fields are what make a clean per-field mapping
  possible (see WF-18). Storage/display/edit/copy here do not depend on TV-3.

---

## 7. Payment Method — detail / edit — WF-17

```
┌────┬──────────────────────────────────────────────┐
│ ▢  │  💳  Premier Debit          Edit   Delete…    │
│ ▣  │  CARDHOLDER     zeviter [last]           copy   │
│    │  CARD NUMBER    ••••  ••••  ••••  1234  reveal·copy │
│    │  SECURITY CODE  •••                    reveal·copy │
│    │  EXPIRY         06 / 28   · valid from 06/23  │
└────┴──────────────────────────────────────────────┘
```
*WF-17 · Card number + security code are masked, reveal/copy biometric-gated — exactly the password
treatment. List shows only "•••• last4". Card type auto-detected from the number (or chosen).*

**Build rules — WF-17**
- Sensitive = card number + CVV: masked by default, **reveal and copy both biometric-gated** (the
  password reveal path), concealed clipboard + auto-clear. Never in a cleartext column; list shows only
  last-4.
- Non-sensitive (nickname, cardholder, expiry, card type) shown plainly once unlocked; per-field copy.
- Card type detected from the number prefix (Visa/MC/Amex…) for the glyph + last-4 display;
  user-overridable. Detection is local, no network.
- Excluded from the security audit (type ≠ login) — this is the fix for "weak password on a credit
  card".
- Click-to-fill into web payment forms = TV-3.

---

## 8. Click-to-fill — per-field icon + multi-choice — WF-18 · TV-3

```
  checkout.example › Payment
  ┌─────────────────────────────────────────────┐
  │ Card number  [💳]   ← native overlay icon    │   amber = a saved card can fill here
  │ Expiry · CVV                                 │
  └─────────────────────────────────────────────┘
        ┌────────────────────────────────────────────┐
        │ surf-r · fill card for checkout.example     │   ☺ Face ID to fill
        │  💳 Premier Debit   ···· 1234               │
        │  💳 Amex Gold       ···· 9008               │
        └────────────────────────────────────────────┘
```
*WF-18 · The native overlay icon sits adjacent to a detected card field. Click → if one match, fill
after the auth gate; if several, the inline picker (extending WF-7) lets the user choose. Green latch
after fill = "surf-r filled this".*

> **This is the heavy, separable piece.** For logins, detection keys on `input[type=password]`.
> Cards/addresses have no such anchor — detecting a "card number" or "street address" field on an
> arbitrary web form is materially harder and more false-positive-prone. So TV-3 is its own sub-slice
> and can be deferred without blocking the rest of the typed vault. The reassuring half: the
> **multi-choice picker already exists** (the `⌘\` picker for multiple matching logins) — TV-3 extends
> it with card/address rows, not a new UI.

**Build rules — WF-18 (TV-3)**
- **Never auto-fill.** Detection only surfaces the per-field icon; fill happens on explicit click,
  through the same auth gate (biometric + master fallback) as login fill. Honors "Require auth to
  reveal/copy/fill".
- Field detection: use `autocomplete` tokens first as the strong signal — card: `cc-number`,
  `cc-csc`, `cc-exp`; address: `address-line1`, `address-line2`, `address-level2` (city),
  `address-level1` (state/province), `postal-code`, `country`. **County has no standard token** — it
  fills by label heuristic only, or not at all (acceptable). Heuristic name/label matching is weak
  corroboration elsewhere. Detect in the isolated `WKContentWorld`, structure-only, exactly like
  Slice 8.
- Multiple matches → the inline picker; card rows show type + ••••last4 (never the full number until
  fill), address rows show label + city. Single match fills directly.
- Honesty: amber icon = "a saved card/address can fill this field" (a fact surf-r owns); green latch =
  "surf-r filled this" — never "this is correct/valid". Same rule as the login green latch.
- Fill writes via `callAsyncJavaScript(arguments:)` in the isolated world — values passed as
  arguments, never the clipboard, never string-built. Main + same-origin frames only (cross-origin
  iframe deferred, as Slice 8).
- No card/address web-fill before TV-1/TV-2 ship; gate this sub-slice behind a working store + editors.

---

## 9. Uniform ESC / back navigation — WF-19

Vault navigation is a **stack**. Back button and ESC both pop exactly one level per press, down to the
tab you came from. This formalises bug-1 (back from a Security-Check item) and the ESC requests, and
every new editor inherits it.

```
        Item editor  (edit fields · generator)
              ▲  ESC / Back
        Item detail  (login · note · address · payment)
              ▲  ESC / Back
        Vault list (segment)  |  Security Check
              │   ← item opened from here returns HERE (origin threaded through)
              ▲  ESC / Back   (closes the vault surface)
        The tab you were on before  (new-tab page or a web tab — ESC does nothing further)
```
*WF-19 · One level per press. An item opened from Security Check returns to Security Check, not the
list (origin threaded through, same family as the Slice-5 surface-restore fixes).*

**Build rules — WF-19**
- ESC and the Back affordance share one stack popper. One press = one level.
- **Active search swallows the first ESC**: if a search field has focus/content, ESC clears+closes the
  search; the *next* ESC begins popping the stack. Applies to vault-list search and Security-Check
  search.
- **Origin threading:** opening an item records its originating surface (list-segment or Security
  Check); Back/ESC returns there. Fixes bug-1.
- An overlay (type picker, fill picker, generator popover) is the top of the stack — ESC dismisses it
  first, then normal popping resumes.
- At the vault-list top level, ESC closes the vault surface and restores the prior tab (the
  ephemeral-internal-surface rule). Spamming ESC walks all the way out and then stops.
- Reuse existing dismissal conventions (Spotlight/flyout ESC) — do not invent a new pattern. The Back
  button and ESC must never diverge.

---

## 10. Architecture & privacy invariants

- **No crypto/store change.** `type` is metadata on existing items; per-type payloads are new JSON
  shapes under the same AES-256-GCM envelope. No schema migration beyond adding type-classification +
  extracted fields to the encrypted payload.
- **Zero-decryption list preserved.** Lists render from cleartext metadata (title/host/label + last-4
  + type). Search is title/host/label only. No payload is decrypted to draw or filter a list — the
  Slice-5 property holds across all four segments.
- **Sensitive data stays encrypted-payload-only.** Card number, CVV, address PII, note bodies never
  touch a cleartext column. Reveal/copy of card number + CVV is biometric-gated like passwords. The
  `vault-spec.md` §13 metadata-leak disclosure does **not** grow past title/host/label.
- **Audit + autofill are login-only.** The Slice-9 security check and the login matcher consider
  `type==login` exclusively. Cards/addresses/notes are never weak/reused/2FA-flagged and never offered
  to a login form. (Click-to-fill for cards/addresses is the separate TV-3 path.)
- **No network, no auto-fill.** Card-type detection is local (number prefix). Filling is always
  click-initiated and auth-gated.

---

## 11. Build tiering & sequencing

Three sub-slices. TV-1 + TV-2 deliver the entire store/display/edit/copy story with **no field
detection**. TV-3 is the heavy, deferrable web-fill piece.

| Sub-slice | Ships | Effort |
|----|----|----|
| **TV-1** | Data model + type classification + LastPass `NoteType` parsing (payment/address field extraction; everything else → note with raw body). Headless, unit-tested against the real export samples. Re-classify the `secureNote`-marked items from the Slice-9 closeout. | low–med |
| **TV-2** | Segmented vault list (WF-12) + type picker (WF-13) + per-type detail/edit/copy (WF-15/16/17) + the uniform ESC/back nav model (WF-19). No web fill. **Most of the user-visible value.** | med |
| **TV-3** | Click-to-fill for cards/addresses (WF-18): card/address web-form field detection in the isolated world + per-field overlay icon + multi-choice picker. Separable; deferrable without blocking TV-1/TV-2. | med–high |

**Sequencing**
- Lands **after Slice 9 commits**. Recommended before Slice 10 (it fixes real imported-data handling
  every LastPass user hits and is not Apple-gated), unless you'd rather finish the password story
  (Slice 10) first.
- Slice 10's system AutoFill extension stays **password/passkey-only** — Apple's
  `ASCredentialProviderExtension` doesn't vend cards/addresses to other apps; those are in-vault
  click-to-fill only.
- Each sub-slice is a vertical slice: builds, hardware-verified on the real migrated vault, committed
  before the next.

---

## 12. Open questions for review

| Question | Lean |
|----|----|
| Long-tail types (Passport, SSN, Bank Account, Wi-Fi…) — generic Secure Note for v1, or any first-class? | Generic note (raw body preserved); first-class editors are post-v1 backlog. |
| TV-3 (card/address web-fill) in this v1 push, or defer web-fill and ship TV-1/TV-2 first? | A commits to click-to-fill, so it's in the design — but TV-3 is structured to defer cleanly. |
| Note body — biometric-gate the whole body on open, or rely on vault-unlock only? | Vault-unlock only; copy is concealed-clipboard. Flag if you want a per-note reveal gate. |
| Card type — auto-detect from number, with manual override? | Auto-detect (local prefix match) + override. No network. |
| "Convert type" (note → payment) flow? | Out of v1. Create-as-type only; mis-imports are editable by re-create. |

---

## 13. Cross-references
- `vault-spec.md` — authoritative for vault crypto/store/AutoFill architecture (this file does not
  alter it; types are new payload shapes under the same envelope).
- `ui-wireframes.md` — authoritative for the browser shell (rail/spotlight/tabs); this file extends its
  WF series as WF-11+.
- `spec.md` §2/§6 — F5 feature row + phase status.
- `backlog.md` — typed-vault entry + the post-v1 deferrals (first-class long-tail editors, "convert
  type").
- `known-issues.md` — the resolved `sn`-as-junk-host item (now recognized as `secureNote`).
