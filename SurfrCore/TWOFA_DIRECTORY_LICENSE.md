# 2FA Directory dataset — attribution & license

`Sources/SurfrCore/Resources/twofa_totp_domains.json` is a **reduced snapshot** of the
[2FA Directory](https://2fa.directory) dataset, used by the vault Security Check (vault-spec §10 WF-9)
to flag sites that support TOTP two-factor authentication where the stored login has no one-time code.

- Source: **2FA Directory** by **2factorauth** — https://2fa.directory
- API: https://api.2fa.directory/v4/totp.json (TOTP-supporting entries)
- Snapshot date: **2026-06-24** (also recorded inside the JSON as `generated`)
- License: **MIT** — see the upstream repository https://github.com/2factorauth/twofactorauth

## Attribution (required — the signal is user-visible)

> **Data sourced from 2FA Directory by 2factorauth**

This string is shown verbatim in the Security Check surface and is reproduced here to satisfy the
MIT attribution requirement.

## What was reduced

The upstream payload is a domain-keyed object carrying `methods`, `documentation`, `recovery`, icons,
etc. surf-r needs only **which registrable domains support TOTP**, so the snapshot keeps only entries
whose `methods` include `"totp"`, reduced to a sorted list of registrable-domain strings (everything
else dropped). No domain data was altered beyond lower-casing. Refreshing the signal is a **new app
build that ships a new file** — there is **no runtime network lookup, ever**.
