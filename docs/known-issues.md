# Known issues

Parked edge cases — documented for transparency, not scheduled for a fix yet.

## Omnibox parser (`Surfr/Surfr/Omnibox.swift`)

| Input example | Current behaviour | Severity | Notes / workaround |
|---|---|---|---|
| Schemeless single-label host, e.g. `devbox:3000`, `intranet`, `wiki/page` | Treated as a **DuckDuckGo search**, not navigation — the host heuristic needs a dotted name or the literal `localhost`. (`localhost`, `localhost:8080`, and IP literals like `192.168.1.1` already navigate correctly.) | Low — local/intranet dev only | Prefix with `https://` to force navigation. |
| Single-word input, e.g. `news` | Treated as a **DuckDuckGo search** rather than an attempt to visit a host. | None — intended default | Working as designed; listed for transparency. Prefix `https://` or add a TLD to navigate. |

## Developer tooling (`Surfr/Surfr/ContentView.swift`)

| Issue | Current behaviour | Severity | Notes / workaround |
|---|---|---|---|
| Right-click "Inspect Element" uses private API | The `developerExtrasEnabled` preference is set via KVC in **DEBUG only** (compiled out of release); it's an undocumented WebKit key that may change or break on a future macOS version. | Low — DEBUG tooling only | If it stops working, fall back to Safari's Develop menu (the `isInspectable` path). |

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
| Dynamic shadow-DOM popup that hides (not removes) its fields on close | Fill may still offer/fill on an **open-shadow-root** login popup that **hides rather than removes** its fields on close, if the site's hide mechanism isn't detectable via composed-tree traversal (we reject `display:none` / `visibility:hidden` / `opacity:0` / `content-visibility` via `checkVisibility`, zero-size, off-screen, and `height:0`/`width:0` clipped ancestors). A residual mechanism (e.g. Barbican's login popup) can report a "filled" into a no-longer-visible field. | Low — confusing, latent hidden-field-trap class; the *general* visible-only protection holds | **Workaround: fill while the popup is open.** The general hidden-field-trap protection (composed-tree visibility) is in place; this is a specific uncovered hide mechanism. |
| Cross-origin iframe logins | A login form in a **cross-origin iframe** isn't filled (detection runs per-frame but matching/fill is main + same-origin only). | Low | Deferred from 8a; documented. |
| Closed shadow-root logins | Fields inside a **closed** shadow root are invisible to detection/fill (only open roots are pierced). | Low | Inherent — closed roots are inaccessible by design. |
