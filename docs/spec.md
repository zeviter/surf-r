# spec.md — surf-r build specification

> Authoritative build spec, referenced by `CLAUDE.md`. Privacy-first browser for macOS + iOS,
> Swift + WebKit. Verify Apple framework APIs against current docs before relying on snippets.

---

## 1. Goal & principles

A browser where privacy is the default behaviour. Guiding principles:
- **Ephemeral by default** — nothing persisted unless the user opts in per-site.
- **WebKit engine** on both platforms (`WKWebView`). No Chromium/Gecko (Apple requires WebKit for
  third-party browsers outside the EU; acceptable for every feature here).
- **No telemetry, ever.** The product earns trust by collecting nothing.
- **User owns the stack** — self-hosted IP routing, self-owned password vault, device-bound keys.

---

## 2. Feature requirements → mechanism

| ID | Feature | Mechanism |
|----|---------|-----------|
| F1 | IP obfuscation | Per-app proxy via `WKWebsiteDataStore.proxyConfigurations` (iOS 17+/macOS 14+) → SOCKS5 to Tor or self-hosted WireGuard; WebRTC + DNS leak hardening |
| F2 | No cookies | `WKWebsiteDataStore.nonPersistent()` per tab/session; optional per-domain persistent allowlist |
| F3 | Block all ads | Fetch filter lists (EasyList/EasyPrivacy) and convert them to WebKit content-blocker JSON at runtime via a maintained converter (AdGuard `SafariConverterLib`) or a reputable pre-converted source — **never** a hand-rolled converter. Compile with `WKContentRuleListStore`; retain the last-good compiled list and fall back to it on any fetch/convert/compile failure; a small bundled seed list ships as the initial last-good fallback. Per-list rule cap is hard-coded (50,000 rules on older OS versions, 150,000 on current); exceed it by splitting into multiple lists each under the cap and applying them all — separate lists are independent (a rule in one cannot undo a block from another). Cosmetic element-hiding via `WKUserScript`. |
| F4 | Block ad popups, allow trusted | `WKUIDelegate.webView(_:createWebViewWith:…)` gate: allow only user-initiated or allowlisted origins |
| F5 | Own password manager, cross-device + cross-app | Encrypted vault (CryptoKit + Keychain + Secure Enclave) · CloudKit E2E sync · `ASCredentialProviderExtension` for system-wide autofill + passkeys |
| F6 | Clean bookmarks on new tab | Local-first `BookmarkStore` (CloudKit-synced) rendered as the New Tab page |
| F7 | Organised history | Indexed, searchable, date-grouped store; **local-only by default**; auto-expiry |
| F8 | Omnibox shortcut | Global `UIKeyCommand` (iOS) / `NSMenu` (macOS) → input parser (URL vs search) → opens in new tab |

---

## 3. Architecture (target state)

```
            ┌──────────── SurfrCore (Swift package) ────────────┐
            │ TabEngine · ProxyManager · ContentBlockerCompiler │
            │ VaultCrypto · SyncEngine · History/BookmarkStore  │
            │ OmniboxParser · TrustPolicy                        │
            └───▲───────────────▲────────────────────▲──────────┘
        ┌───────┴──┐      ┌──────┴───────┐     ┌──────┴───────────┐
        │ macOS app│      │  iOS app     │     │ Extensions:      │
        │ (SwiftUI)│      │ (SwiftUI)    │     │ AutoFill ×2 ·    │
        │ WKWebView│      │ WKWebView    │     │ Content Blocker ·│
        └──────────┘      └──────────────┘     │ Proxy/Network    │
                                               └──────────────────┘
```
Targets are added incrementally (see Build order), not all at once.

---

## 4. Build order (phased)

Each phase must build and run before the next. Commit per slice.

### Phase 0 — macOS MVP  ← current
- New macOS SwiftUI app `Surfr`, deployment target macOS 14.
- A `WKWebView` wrapped for SwiftUI (`NSViewRepresentable`) using `.nonPersistent()` data store.
- Loads a hardcoded URL in a window.
- **Done:** a cookie-less window renders a live page.

### Phase 1 — Navigation shell (macOS)
- Omnibox (F8): `⌘L` focuses an address field; parser decides URL vs DuckDuckGo search; opens result.
- Multiple tabs (F-core): tab model in `SurfrCore`, tab bar UI, each tab its own ephemeral store.
- Back/forward/reload; loading + TLS indicator.

### Phase 2 — Blocking (macOS)
- **2a — Pipeline proof.** Bundle a seed list (EasyList, pre-converted to WebKit content-blocker
  JSON), compile it with `WKContentRuleListStore`, and apply the resulting `WKContentRuleList` to
  every tab — including newly created tabs. One list, under the cap, no chunking. This is the
  initial last-good fallback.
- **2b — Runtime updates + full blocking.** Add runtime fetch + convert (maintained converter), the
  last-good fallback on any failure, EasyPrivacy, cosmetic element-hiding via `WKUserScript`, and
  multiple-list chunking to respect the per-list cap.
- **2c — Popup gate (F4).** Implement the `WKUIDelegate` popup gate + `TrustPolicy` allowlist.

### Phase 3 — Bookmarks & history (macOS)
- F6: `BookmarkStore`; New Tab page shows the bookmark grid.
- F7: `HistoryStore` with full-text search, date grouping, auto-expiry; local-only.

### Phase 4 — IP routing (macOS)
- F1: `ProxyManager` wiring `proxyConfigurations` (SOCKS5) to the user's self-hosted WireGuard or a
  local Tor SOCKS port. WebRTC shim + DNS-through-tunnel. Guard against the known iOS 18.x
  `proxyConfigurations` crash pattern (set before first load; availability-gate).

### Phase 5 — Promote core + iOS app
- Extract stable logic into `SurfrCore`; add the iOS SwiftUI target reusing it (`UIViewRepresentable`
  WKWebView). Re-verify F1–F8 on iOS.

### Phase 6 — Password vault
- F5 (storage): encrypted store (CryptoKit AES-GCM; key wrapped by Secure Enclave / master password
  via Argon2id). Generator + TOTP. Face/Touch ID gate. App Group shared with the autofill extension.

### Phase 7 — System autofill
- F5 (system): `ASCredentialProviderExtension` targets (iOS + macOS); QuickType + full UI; passkeys
  (`ASPasskeyCredential`, iOS 17+). Note: fills detected login fields/QuickType/Safari, **not** the
  generic context-menu on arbitrary text fields (Apple-private) — same as all third-party managers.

### Phase 8 — Sync
- CloudKit private DB, **end-to-end encrypted** (encrypt before upload) for vault, bookmarks,
  settings. History stays local unless explicitly opted in. Conflict handling: last-write-wins +
  per-record versioning.

---

## 5. Conventions
- Module/product name `Surfr`; display name "surf-r"; bundle base `com.zeviter.surfr`.
- Shared logic lives in `SurfrCore`; UI targets stay thin.
- No secrets in the repo (see `.gitignore`). No telemetry/analytics anywhere.
- Prefer Apple-native frameworks over third-party deps; vet any dependency for privacy.

## 6. Security model (summary)
Protects against: cross-site cookie tracking, ad/tracker requests, IP exposure to sites,
unrequested popups, vault theft (E2E + Secure Enclave). Does **not** provide: anonymity/crowd-
blending (self-hosted exit is a static IP), defence against a malicious relay you don't control,
or protection from on-device malware. State these honestly in any user-facing privacy copy.

## 7. Human-only steps
Apple Developer enrolment, signing identities/certs, first-time capability prompts (CloudKit,
AutoFill, Network Extension), and anything requiring payment or accepting Apple's terms. The build
agent pauses and hands these to the user.

## 8. Decisions
- **F3 fetch-and-convert at runtime (not bundle-only).** EasyList changes constantly; fetching keeps
  it current without shipping an app update for every list change.
- **Maintained converter, never hand-rolled.** Adblock filter syntax evolves; delegating conversion
  to a maintained converter (AdGuard `SafariConverterLib`) or a reputable pre-converted source avoids
  chasing syntax changes ourselves.
- **Bundled seed list.** A small seed list ships in the app so the browser blocks from first launch,
  before any fetch — and survives fetch/convert/compile failures as the initial last-good fallback.
