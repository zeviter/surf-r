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

## Current phase
**Phase 0 — macOS-first MVP.** One vertical slice: a `WKWebView` window using
`WKWebsiteDataStore.nonPersistent()` (no cookies on disk) that loads a URL. Do not scaffold all
targets yet; grow the core out of working code. See `docs/spec.md` §Build order.

## Engineering guardrails
- **Build in vertical slices.** Each slice should run and be testable in the Simulator / on the Mac
  before moving on. Prefer small, reviewable commits.
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
