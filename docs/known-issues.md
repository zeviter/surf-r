# Known issues

Parked edge cases — documented for transparency, not scheduled for a fix yet.

## Omnibox parser (`Surfr/Surfr/Omnibox.swift`)

| Input example | Current behaviour | Severity | Notes / workaround |
|---|---|---|---|
| Schemeless single-label host, e.g. `devbox:3000`, `intranet`, `wiki/page` | Treated as a **DuckDuckGo search**, not navigation — the host heuristic needs a dotted name or the literal `localhost`. (`localhost`, `localhost:8080`, and IP literals like `192.168.1.1` already navigate correctly.) | Low — local/intranet dev only | Prefix with `https://` to force navigation. |
| Single-word input, e.g. `news` | Treated as a **DuckDuckGo search** rather than an attempt to visit a host. | None — intended default | Working as designed; listed for transparency. Prefix `https://` or add a TLD to navigate. |
