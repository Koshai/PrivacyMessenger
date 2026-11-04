# E2EE dependency review — OpenMLS Dart (C1)

**Date:** 2026-11-03  
**Decision context:** PrivacyMessenger remains proprietary. AGPL/GPL/copyleft deps require explicit approval.  
**Scope:** Isolated technical proof of concept only — not production messaging UI.

## Package pin

| Item | Value |
| --- | --- |
| Package | `openmls` (pub.dev) |
| Pinned version | **3.3.0** |
| Repository | https://github.com/djx-y-z/openmls_dart |
| Dart SDK requirement | `^3.10.0` (app uses `^3.13.7`) |
| Primary transitive | `flutter_rust_bridge` **2.13.0**, `crypto`, `hooks`, `code_assets` |
| Lockfile | `mobile/pubspec.lock` (committed with C1) |

## License verification (source files)

| Component | License | Source checked |
| --- | --- | --- |
| Dart wrapper `openmls` 3.3.0 | **MIT** | https://raw.githubusercontent.com/djx-y-z/openmls_dart/main/LICENSE and pub.dev `/license` |
| Upstream Rust OpenMLS | **MIT** | https://raw.githubusercontent.com/openmls/openmls/main/LICENSE |
| Bundled native dependency tree | MIT / Apache-2.0 / BSD / ISC / Unlicense (and dual-licensed options) | `THIRD_PARTY_NOTICES.txt` from openmls_dart (shipped with natives) |
| SQLCipher (via `libsqlite3-sys`) | **BSD-3-Clause** (Zetetic) | Notices text T33 / copyright 2008–2020 Zetetic LLC |
| `r-efi` | MIT **OR** Apache-2.0 **OR** LGPL-2.1-or-later | Notices — **MIT/Apache may be elected**; not forced LGPL |

### Copyleft gate

- **No AGPL or GPL-only required dependencies identified** in the Dart package LICENSE or the upstream OpenMLS LICENSE.
- Optional LGPL appears only as an alternate SPDX choice for `r-efi` (MIT/Apache also offered).
- **Action:** Ship `THIRD_PARTY_NOTICES.txt` (or equivalent) with app distributions; register notices via Flutter `LicenseRegistry` as the package README recommends.

## Security advisories

Upstream OpenMLS advisories addressed by **openmls crate 0.9.2**, which Dart package **3.3.0** claims to bundle:

| ID | Summary | Severity (upstream) | Status in 3.3.0 |
| --- | --- | --- | --- |
| GHSA-gc79-23g3-8g52 | Nested extensions DoS / stack exhaustion | High | Fixed (0.9.1+) |
| GHSA-94v4-rg25-x625 | Removed leaf can reappear after external commit tree truncate | Moderate | Fixed (0.9.2) |
| GHSA-p276-g3f3-wwgh | Rejected private messages can advance sender ratchet | — | Fixed (0.9.2) |
| RUSTSEC-2026-0331 | Malformed X-Wing key panic | — | Fixed; **we do not use PQ suites in C1** |
| RUSTSEC-2026-0387 | P-256/P-384 constant-time advisory in `crypto-bigint` | Open (accepted upstream) | **Avoided** by using X25519/Ed25519 suite only |

**C1 ciphersuite (standard, non-experimental):**  
`MlsCiphersuite.mls128DhkemX25519Aes128GcmSha256Ed25519` (RFC 9420 MLS 1.0).

## Platform compatibility

| Platform | Package claim | C1 verification |
| --- | --- | --- |
| Android arm64 / armeabi-v7a / x86_64 | Yes | Debug APK + emulator smoke (`openmls_android_smoke_test`) passed |
| iOS device/simulator | Yes | **Not executed on this Windows host** — arrange macOS check |
| Windows x64 | Yes | Host `flutter test` uses native Rust via FRB (`openmls_poc_test` 13/13) |
| Web dart2wasm | Not supported (FRB limitation) | Out of scope |

## Provenance / trust notes (unresolved, non-blocking for C1)

1. pub.dev publisher marked **unverified**.
2. Prebuilt natives downloaded from GitHub Releases via Dart build hooks (SHA256 verification claimed by package).
3. Wrapper is third-party relative to `openmls/openmls` authors — review FRB binding surface carefully before C2.
4. Storage DB encryption key is **caller-managed**; zero-filled keys forbidden outside fixtures (C1 uses `Random.secure()`).

## Vulnerability tooling

- Manual advisory review against OpenMLS GHSA list and package changelog (2026-11-03).
- `dart pub outdated` / lockfile pin recorded.
- Automated SCA (e.g. OSV) not configured in-repo yet — **recommended for C2**.

## Gate result

**Proceed with C1 PoC.** No AGPL/GPL licensing blocker found for the pinned stack when using the standard X25519 ciphersuite and electing MIT/Apache for dual-licensed crates.
