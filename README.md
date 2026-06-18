# surf-r

A privacy-first web browser for **macOS and iOS**, built on WebKit (`WKWebView`) in Swift.
Open source — fork it, change it, make it yours.

## What it's for
A browser that treats privacy as the default, not a setting:

- **No cookie storage** — ephemeral sessions, nothing persisted to disk by default
- **Ad & tracker blocking** — native WebKit content rules
- **Popup control** — block ad/redirect popups, allow trusted ones
- **IP obfuscation** — route traffic through a proxy/VPN/Tor you control
- **Built-in password manager** — encrypted vault that syncs across your devices and
  autofills across all apps (system credential provider)
- **Clean bookmarks** on every new tab, **organised history**, and a fast **omnibox**
  (one shortcut: type a URL or a search, opens in a new tab)

## Status
Early. Building macOS-first as a single vertical slice, then growing into the full
multi-target architecture. See [`docs/spec.md`](docs/spec.md) for scope, architecture,
and build order, and [`CLAUDE.md`](CLAUDE.md) for how the project is developed.

## Platforms
macOS 14+ and iOS 17+. Engine is WebKit on both (Apple requires WebKit for third-party
browsers outside the EU; this is fine for everything surf-r does).

## Build
Requires a recent Xcode (26.5+) on Apple Silicon. Open the project in Xcode and run the
`Surfr` scheme. (The module/product name is `Surfr`; the display name is "surf-r".)

## License
MIT — see [`LICENSE`](LICENSE).
