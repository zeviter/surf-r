# Known issues

Parked edge cases — documented for transparency, not scheduled for a fix yet.

## Omnibox parser (`Surfr/Surfr/Omnibox.swift`)

| Input example | Current behaviour | Severity | Notes / workaround |
|---|---|---|---|
| Schemeless single-label host, e.g. `devbox:3000`, `intranet`, `wiki/page` | Treated as a **DuckDuckGo search**, not navigation — the host heuristic needs a dotted name or the literal `localhost`. (`localhost`, `localhost:8080`, and IP literals like `192.168.1.1` already navigate correctly.) | Low — local/intranet dev only | Prefix with `https://` to force navigation. |
| Single-word input, e.g. `news` | Treated as a **DuckDuckGo search** rather than an attempt to visit a host. | None — intended default | Working as designed; listed for transparency. Prefix `https://` or add a TLD to navigate. |

## Content blocking (`Surfr/Surfr/ContentBlocker.swift`)

| Issue | Current behaviour | Severity | Notes / workaround |
|---|---|---|---|
| Cold-start first-paint gap | On a fresh launch the first tab may briefly paint before the content-rule list attaches; subsequent loads/tabs are fully covered. | Low | Deferred to Phase 2b where the blocking flow is reworked. |

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
