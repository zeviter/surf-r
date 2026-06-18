# ui-wireframes.md — surf-r UI reference (chromeless rail phase)

> Authoritative UI spec for the rail + spotlight + bookmarks + history phase. Referenced by
> `CLAUDE.md` and `docs/spec.md`. This is the textual translation of the agreed wireframes — build
> against the rules here, not against a rendered image. Where this conflicts with `spec.md`'s
> feature table, this file wins for UI/layout/behaviour; `spec.md` wins for architecture.

---

## 0. Design principle

A **near-chromeless** browser: no top bar, no address bar by default, **no back/forward buttons**
(navigation is keyboard-only, e.g. `⌘[` back / `⌘]` forward). The entire persistent UI is a single
**48px left rail**; everything else is summoned (the omnibox) or opened as a page (history).

---

## 1. The left rail (48px, replaces the old top tab bar entirely)

Width **48px**, minimal horizontal padding, compact. Top to bottom:

```
┌────┐
│ 🕐 │  history       ← persistent: opens full-page history in a NEW tab
│ +  │  new tab       ← persistent: opens a new tab (same as ⌘T)
│ ── │  divider
│ S③ │  favicon       ← host group (most-recently-active host on TOP)
│ S② │  favicon
│ G  │  favicon
└────┘
```

- **History icon** (clock) and **new-tab `+`** are fixed controls pinned at the top, above the divider.
- Below the divider: the **favicon stack**, one tile per **host group** (see §2). Newest-active host on top.
- Each favicon tile ≈ 32px, rounded. Shows the site's favicon; fallback in §4.
- **Active host** is highlighted with a **blue 2px border** on its favicon tile.
- **Count badge:** small blue-on-white(ish) number on the favicon's bottom-right corner, shown
  **only when the host has ≥2 tabs**. Caps at **`99+`**.

## 2. Tab grouping (host-based)

- Group tabs by **full host** (subdomain-aware), **not** registrable domain. So
  `admin.shopify.com`, `partners.shopify.com`, and `dev.shopify.com` are **three separate**
  favicons — intentional, this is the desired behaviour.
- One favicon = one host = all that host's tabs collapsed behind it.

## 3. Tabs & the flyout

- **Single-tab host:** clicking the favicon **switches directly** to that tab (no flyout).
- **Multi-tab host:** clicking the favicon opens a **flyout** listing that host's tabs.
- **Flyout is an overlay** — it floats *over* the page content, anchored to the right of the
  favicon. It does **not** push or reflow the page. Dismiss on click-away / `Esc`.
- Flyout contents, top to bottom:
  - Header: `host · N tabs`.
  - **Filter input** ("filter tabs") that live-filters the list by page title/URL as you type
    (the "⌘F for tabs" behaviour).
  - Tab rows: each = favicon/icon + page title + **✕** (close that tab).
  - The **current/active tab is pinned on top and highlighted**.

### Pristine (blank) new tabs — disposable

- A new tab that has **not navigated anywhere** is "pristine."
- A pristine tab is **not shown** in the favicon strip (the rail only lists hosts actually visited).
- A pristine tab is **discarded** when it loses focus without navigating (switching to another tab
  drops it). Re-opening is free via `+` / `⌘T`.
- **Edge case (must handle):** if the user has **typed uncommitted text** into a pristine tab's
  omnibox, switching away must **not** discard the tab or lose the typed text. Only a truly
  untouched pristine tab is disposable.

## 4. Favicons

- Source favicons **first-party only** (the site's own `/favicon.ico` or `<link rel="icon">`).
  **Never** use a third-party favicon service — it would leak browsing activity (off-brand).
- **Fallback:** a generated **letter tile** (first letter of the host) when no favicon exists or
  before it has loaded. Swap in the real favicon once it resolves.
- Cache favicons locally.

## 5. Spotlight omnibox

Hidden by default; summoned with **`⌘L`**. Two contexts:

### On a loaded page (summoned overlay)
- A **centered floating panel** (horizontally + vertically) over a **dimmed** page.
- Input is **pre-filled with the current URL, auto-highlighted** for instant copy.
- **Dismiss:** `Esc` or click-outside → closes with **no navigation**.
- **`Enter`** → navigate in the **current** tab.
- **`⌘Enter`** → **ALWAYS open in a new (foreground) tab** — for a typed URL/search *and* for a
  highlighted suggestion. ⌘Enter universally means "new tab," whatever is selected.
- **Suggestion list** below the input, ranked sensibly by relevance, ordered by source:
  **recent history → bookmarks → search**. Each row tagged with its source. (Don't over-engineer
  ranking; match established browser behaviour.)
- Input parsing reuses existing omnibox logic (URL vs DuckDuckGo search). **Trim and collapse
  whitespace/newlines** before deciding, so a pasted URL with a trailing newline still navigates.

### On the new-tab page (permanent)
- The omnibox is **always visible** as a large stylised box near the top (not dismissable here),
  sitting **above the bookmarks grid**.
- When hidden on a loaded page, the current URL is shown **nowhere** (zero chrome).

## 6. New-tab page

- Layout: the **permanent large omnibox box** (top, centered) + a **bookmarks grid** below
  (favicon + label tiles, responsive grid).
- **Empty state** (no bookmarks yet): just the omnibox box.
- **Adding bookmarks:** `⌘D` or **right-click → "Bookmark page"**.

## 7. History (single surface)

- **No popover.** The history **icon** opens the **full-page history view in a NEW tab**.
- Full-page view:
  - **Search box** (top) that filters all history by title/URL.
  - Entries **grouped by day** (`today`, `yesterday`, then dates).
  - Each row: favicon + title + URL + time + **✕** (delete that entry).
  - Clicking a row **opens that page in a NEW tab** (never replaces the current one).

---

## 8. New data layers required (none exist yet)

- **HistoryStore** — local-only, persistent; records every visit (title, URL, host, timestamp,
  favicon ref); searchable; configurable auto-expiry. **History is not synced** by default.
- **BookmarkStore** — add/remove/persist bookmarks (title, URL, host, favicon ref). (CloudKit E2E
  sync is a later spec phase; build local-first now.)
- **FaviconService** — first-party fetch + local cache + letter-tile fallback (§4).

---

## 9. Build order for this phase (build & verify each slice before the next)

1. **HistoryStore** — record visits + persistence + query/search API. No UI; verify via console/tests.
2. **BookmarkStore** + `⌘D` / right-click "Bookmark page" action. Minimal/no UI.
3. **FaviconService** — first-party fetch, cache, letter-tile fallback.
4. **Left rail + host-grouped favicon tabs** — replaces the top tab bar; badges (`99+` cap);
   active highlight; pristine-tab discard rule (§3). (May sub-split: rail/tabs first, then flyout.)
5. **Flyout** — per-host tab list overlay with filter input, ✕ close, current-tab-on-top.
6. **Spotlight omnibox** — hidden + `⌘L` summon, centered dimmed overlay, current-URL highlight,
   suggestion stack, `Enter` vs `⌘Enter` (always-new-tab), dismissal; + permanent new-tab omnibox.
7. **New-tab bookmarks grid** + **full-page history view**.

> Note: this phase supersedes the simple always-visible omnibox from the earlier Phase 1 — the
> address bar becomes summon-only per §5. Preserve the existing URL-vs-search parsing inside it.
