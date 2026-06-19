# Vendored: Argon2id reference C (`CArgon2`)

This directory is a **pinned, vendored** copy of the PHC reference Argon2 implementation. We vendor
rather than depend on a third-party Swift package so the source is fully auditable, pinned, and the
build is reproducible (no external package resolution for the one primitive CryptoKit lacks).

## Provenance

- **Upstream:** https://github.com/P-H-C/phc-winner-argon2
- **Pinned tag:** `20190702` (the last PHC release)
- **Pinned commit:** `62358ba2123abd17fccf2a108a301d4b52c01a7c`
- **License:** dual CC0 1.0 / Apache-2.0 — upstream `LICENSE` copied verbatim alongside the sources.

## What was vendored (and what was deliberately left out)

Only the **portable reference** path needed for raw Argon2id key derivation:

| Included | Purpose |
|---|---|
| `include/argon2.h` | public API (`argon2id_hash_raw`) |
| `argon2.c` | top-level entry points |
| `core.c` / `core.h` | memory fill, secure-wipe of internal scratch |
| `ref.c` | **portable** `fill_segment` (reference, no SIMD) |
| `encoding.c` / `encoding.h` | linked for symbol completeness (string API unused) |
| `thread.c` / `thread.h` | pthreads (non-Windows); inert at `parallelism = 1` |
| `blake2/blake2b.c`, `blake2.h`, `blake2-impl.h`, `blamka-round-ref.h` | BLAKE2b + reference BlaMka round |

**Excluded on purpose:** `opt.c` and `blamka-round-opt.h` (x86 SSE/AVX intrinsics — won't build on
arm64 and unnecessary), and all CLI/bench/test tooling (`run.c`, `bench.c`, `genkat.c`, `test.c`).

## Audit (performed before trusting the code)

- No file, stdout, network, process-exec, or environment access anywhere in the vendored set
  (`grep` for `system`/`popen`/`exec*`/`socket`/`fopen`/`getenv`/`dlopen` → clean; the only `system`
  hit was the word in an `encoding.c` comment).
- Includes are stdlib only (`stdint`/`stdlib`/`string`/`limits`) plus `pthread.h` on Apple platforms;
  `windows.h`/`process.h` are `#ifdef _WIN32`-guarded and never compiled here.
- The library zeroes its own internal scratch memory (`secure_wipe_memory` / `clear_internal_memory`,
  `FLAG_clear_internal_memory = 1` by default).

## Updating

Re-pin by checking out a new upstream tag, re-copying the files above, re-running the audit grep, and
updating the commit hash here. Do not hand-edit the vendored C.
