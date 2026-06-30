# Known issues

Parked edge cases — documented for transparency, not scheduled for a fix yet.

## Omnibox parser (`Surfr/Surfr/Omnibox.swift`)

| Input example | Current behaviour | Severity | Notes / workaround |
|---|---|---|---|
| Schemeless single-label host, e.g. `devbox:3000`, `intranet`, `wiki/page` | Treated as a **DuckDuckGo search**, not navigation — the host heuristic needs a dotted name or the literal `localhost`. (`localhost`, `localhost:8080`, and IP literals like `192.168.1.1` already navigate correctly.) | Low — local/intranet dev only | Prefix with `https://` to force navigation. |
| Loopback **http** page won't load schemeless (HTTPS-only exemption gap) | The spec exempts loopback/`.local`/private-IP from HTTPS-only (`HTTPSUpgrade.isExempt`), so a local **http** dev page *should* load. But the omnibox prepends `https://` to all schemeless host input (incl. `localhost:8000/…`), so a schemeless local address becomes `https://` and fails against a plain-http server — the dev-convenience exemption is defeated for schemeless input. (Surfaced staging the TV-3a same-origin test.) | Low — local dev only | Type the **explicit `http://`** scheme (`http://localhost:8000/…`) — explicit-scheme http to a loopback host is correctly not upgraded and loads. Possible fix: default schemeless input whose host `isExempt` to `http://` instead of `https://`. |
| Single-word input, e.g. `news` | Treated as a **DuckDuckGo search** rather than an attempt to visit a host. | None — intended default | Working as designed; listed for transparency. Prefix `https://` or add a TLD to navigate. |

## Developer tooling (`Surfr/Surfr/ContentView.swift`)

| Issue | Current behaviour | Severity | Notes / workaround |
|---|---|---|---|
| Right-click "Inspect Element" uses private API | The `developerExtrasEnabled` preference is set via KVC in **DEBUG only** (compiled out of release); it's an undocumented WebKit key that may change or break on a future macOS version. | Low — DEBUG tooling only | If it stops working, fall back to Safari's Develop menu (the `isInspectable` path). |
| `⌘⇧I` Web Inspector is DEBUG-only + uses private API | C2 wired `⌘⇧I` to open the inspector via the private `_inspector` (`connect` → `show`), **DEBUG only**. The private API only opens it as a **connected detached window** — `attach` alone just toggles element-hover with no panel, so the **docked** pane that right-click "Inspect Element" gives isn't reachable programmatically. `⌘⇧I` opens the window; **right-click → Inspect Element remains the docked path.** (the registry definition, menu command, and handler are all `#if DEBUG`). Release builds have no `⌘⇧I` and no inspector. **Decision:** kept DEBUG-only — exposing a web inspector in release is a privacy/footgun tradeoff (and `isInspectable`/`developerExtrasEnabled` are DEBUG-gated anyway). | Low — by design | Both calls are `responds(to:)`-guarded, so a future private-API change degrades to a no-op (right-click "Inspect Element" remains the fallback). Revisit release exposure later if wanted. |

## Pop-up gate (`Surfr/Surfr/ContentView.swift`)

| Issue | Current behaviour | Severity | Notes / workaround |
|---|---|---|---|
| No "Pop-up blocked" recovery UI | Blocked pop-ups are logged to the console only; there's no transient banner with an "Open" action to recover a wrongly-blocked pop-up. | Low — follow-up | Deferred from Phase 2c to keep the slice focused. Recover by adding the origin to `TrustPolicy`, or re-trigger via a real link. Follow-up: add a transient indicator wired from `PopupGate` into the UI. |

## Favicons (`Surfr/Surfr/FaviconService.swift`)

| Issue | Current behaviour | Severity | Notes / workaround |
|---|---|---|---|
| SVG-only favicons aren't rendered | A host whose only icon is SVG resolves to `nil`, so the UI falls back to the letter tile (AppKit can't render SVG). | Low | Acceptable fallback; could add SVG rasterisation later. |

## In-browser autofill (`Surfr/Surfr/Autofill.js`)

| Issue | Current behaviour | Severity | Notes / workaround |
|---|---|---|---|
| Dynamic shadow-DOM popup that hides (not removes) its fields on close | Fill may still offer/fill on an **open-shadow-root** login popup that **hides rather than removes** its fields on close, if the site's hide mechanism isn't detectable via composed-tree traversal (we reject `display:none` / `visibility:hidden` / `opacity:0` / `content-visibility` via `checkVisibility`, zero-size, off-screen, and `height:0`/`width:0` clipped ancestors). A residual mechanism (e.g. Barbican's login popup) can report a "filled" into a no-longer-visible field. **Also:** the per-field key icon (8e) + rail badge may not appear on such a dynamic shadow-DOM popup (passive push-detection lag), though **⌘\ fills correctly** (on-demand detection). | Low — confusing, latent hidden-field-trap class; the *general* visible-only protection holds | **Workaround: fill while the popup is open, or use ⌘\.** The general hidden-field-trap protection (composed-tree visibility) is in place; this is a specific uncovered hide mechanism. |
| Cross-origin iframe logins | A login form in a **cross-origin iframe** isn't filled (detection runs per-frame but matching/fill is main + same-origin only). | Low | Deferred from 8a; documented. |
| Card fill into cross-origin **payment** iframes (TV-3a) | Card fill (TV-3a) draws its overlay anchor for **main + same-origin frames only** — the same boundary as cross-origin login iframes. On checkouts that render card number/expiry/CVC inside a **cross-origin, PCI-scoped iframe** (Shopify `*.shopifycs.com`, Stripe Elements, Adyen hosted fields), the card icon **correctly does NOT appear** (honest: *doesn't-offer*, not *offers-then-no-ops*); **main-document address fields still fill**. By design, not a regression. | Low — by design | Copy the card from the vault (biometric reveal/copy) or type it manually. Cross-origin payment-iframe fill is the deferred **TV-3b** backlog item (gated on a fillability spike). |
| Closed shadow-root logins | Fields inside a **closed** shadow root are invisible to detection/fill (only open roots are pierced). | Low | Inherent — closed roots are inaccessible by design. |

## Vault import — non-login items & hostless logins (`Surfr/Surfr/CSVImport.swift`, `VaultGate`)

| Issue | Current behaviour | Severity | Notes / workaround |
|---|---|---|---|
| LastPass Secure Notes / Cards / Addresses import with host `sn` | LastPass exports Secure Notes, Credit Cards, and Addresses as secure notes with `url=http://sn`. **Slice 9 recognizes `host == "sn"` as a non-login marker**: such items are reclassified `type = secureNote`, **excluded** from the Security Check audit (never flagged weak/reused/2FA/needs-attention — a card number is never scanned as a password) **and** from autofill matching, while remaining visible in the vault. They are **not** treated as junk login hosts. | Resolved (recognized) | Full type-specialization (Note/Address/Payment editors, parsing the `NoteType` body) is the upcoming **typed-vault** slice; for now they're stored + displayed as-is. |
| Hostless / unresolvable **login** items | A genuine login whose `item_hosts` is empty (an early import where URL parsing stored nothing) is surfaced under Security Check "Needs attention"; the unambiguous case (a payload URL that parses to a real registrable domain) is **auto-fixed** by `loadItems` / the audit walk. A login with no host and no recoverable URL is surfaced for a manual website edit, never guessed. | Low — affects autofill match for those rows only | Edit the item's website to fix the host. Empty-string-host login handling is unchanged by the `sn` recognition above. |

## Save-on-submit (`Surfr/Surfr/Autofill.js`, Slice 8b)

| Issue | Current behaviour | Severity | Notes / workaround |
|---|---|---|---|
| Genuinely-new two-step login (username on page 1, password on page 2) isn't captured | Capture requires a non-empty adjacent username, so a password-only page 2 doesn't trigger "Save" (this is also what stops the spurious re-offer of a just-filled credential). | Low | Deferred to v1.5 (stateful cross-page username-carry). 8c still **fills** two-step logins; **manual add** covers brand-new ones. |
| New account reusing an existing password on the same site | The belt-and-suspenders dedup treats "password already stored for this host" as a duplicate, so a second account that reuses the same password isn't auto-offered. | Low | Intentional (a just-filled credential must never be re-offered); password reuse is discouraged. Add the second account manually. |
