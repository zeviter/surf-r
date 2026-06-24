# CLAUDE.md

## Project
**surf-r** — a privacy-first web browser for macOS and iOS, written in Swift on WebKit
(`WKWebView`). Open source (MIT). Privacy is the default behaviour, not an option.

## Source of truth
**`docs/spec.md` is authoritative** for scope, architecture, and build order. Read it before
acting. Apple framework docs override any code snippet here if APIs have changed — verify
against current docs (WebKit, AuthenticationServices, CloudKit, Network) before relying on them.
**`docs/ui-wireframes.md`** is the authoritative UI reference — read it before any rail/tab/omnibox/
bookmarks/history UI work.
**`docs/vault-spec.md`** is authoritative for the password vault + AutoFill (F5) — read it before any
vault/credential/autofill work.

## Environment
- macOS Tahoe 26.5.1, Apple Silicon (MacBook Pro M1 Pro, 16 GB RAM).
- Xcode 26.5+ (Swift 6.x). SDKs: iOS 26.5 / macOS 26.5. **Deployment targets: iOS 17.0 / macOS 14.0.**
- Module/product name: **`Surfr`** (no hyphen — Swift module rule). Display name: "surf-r".
  Bundle id base: `com.zeviter.surfr`.

## Architecture (target state)
Shared Swift package core (`SurfrCore`) + thin per-platform UI, growing into these targets:
macOS app · iOS app · AutoFill credential-provider extension (per platform) · content-blocker
extension · optional network/proxy extension · CloudKit-backed sync. Engine is **WebKit** on both
platforms (no Chromium/Gecko — Apple requires WebKit for third-party browsers outside the EU).

## Current state
The macOS app is well past MVP: rail with host-grouped tabs + flyout, summon-only spotlight omnibox,
bookmarks-on-new-tab, full-page History/Trusted-Sites/Shortcuts/Downloads surfaces, ad/tracker/
cookie-consent blocking, pop-up gate, HTTPS-only, tracking-param stripping, persistent download
history, and the hybrid trust model. **The F5 password vault is largely built** (`docs/vault-spec.md`
§11 Slices 1–8e): Argon2id/CryptoKit vault, master + Secure-Enclave biometric unlock, Recovery Kit,
list/detail/add-edit, CSV import, generator, TOTP (+ Google Authenticator migration), and **in-browser
fill + save** (isolated-world detection, exact-host anti-leak, ⌘\ / rail badge / per-field overlay,
own save prompt). Built in `SurfrCore` (crypto/store/TOTP/generator) + the macOS app target. See
`docs/spec.md` (reality-first; §6 maps phases to DONE/REMAINING) and `docs/backlog.md`.
**Remaining major work:** vault Slice 9 (security check) + Slice 10 (system AutoFill extension,
Apple-gated) → then the **last two v1 surfaces**, both *design-pass-then-slice* and interlocking at the
trust boundary: **Incognito mode** (F9 — a no-local-trace, trust-suspended session, distinct from the
existing ephemeral-by-default) and **two-mode anti-fingerprinting** (F10 — Standard/blend-as-Safari by
default, Randomized/farbled opt-in; promoted from v2 to v1) → then v1 is essentially complete.
**Post-v1:** IP routing (F1); CloudKit→**AirDrop-first** sync; `SurfrCore` extraction completion + iOS
target; anti-adblock.
Still single-target macOS; data layers are written import-clean for the future `SurfrCore` move.

## Core architecture — the hybrid trust model
Any navigation- or data-touching change **must respect the hybrid trust model** (`docs/spec.md` §4,
`Trust.swift`): tabs are ephemeral and isolated (`WKWebsiteDataStore.nonPersistent()`) by default;
**trusted registrable domains** share the single persistent `WKWebsiteDataStore.default()` so logins
persist. The store is bound at web-view creation and rebound on trust-boundary crossings in the
navigation delegate (with a redirect-chain guard). **HTTP can never be trusted/persisted** — insecure
pages stay ephemeral. Don't bypass this (e.g. don't load trusted content in an ephemeral view or vice
versa) without updating the model.

## Engineering guardrails
- **Build in vertical slices.** Each slice should run and be testable in the Simulator / on the Mac
  before moving on. Prefer small, reviewable commits.
- **Work directly on `main`.** Commit straight to `main`; do **not** create feature/work branches
  unless the user explicitly asks. (This overrides any generic "branch first" default.)
- **Privacy is the product.** Never add telemetry, analytics, crash-phone-home, or any code that
  exfiltrates user data or browsing activity. Default to the most private option.
- **Crypto: do not roll your own.** The password vault uses CryptoKit (AES-GCM/ChaChaPoly), the
  Keychain, and the Secure Enclave for key material. Never weaken these, never log secrets/keys/
  plaintext credentials, never hardcode keys.
- **Secrets never get committed.** No API tokens, signing certs, provisioning profiles, or
  CloudKit keys in the repo. Respect `.gitignore`; stop and warn if a secret is staged.

## Human-only steps (pause and hand to the user)
- Apple ID / Apple Developer Program enrolment and any signing-identity or certificate creation.
- Enabling capabilities that require an Apple ID prompt (CloudKit container, AutoFill, Network
  Extension entitlements) the first time.
- Anything requiring payment or acceptance of Apple's terms.

## Definition of done (Phase 0)
A macOS window renders a live web page through `WKWebView` with an ephemeral data store, builds and
runs clean on Xcode 26.5, and the repo is pushed to `github.com/zeviter/surf-r`. Next phases
(omnibox, tabs, bookmarks new-tab, blocking, IP routing, iOS target, vault, autofill, sync) are
defined in `docs/spec.md`.
