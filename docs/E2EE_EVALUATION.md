# Milestone C — E2EE decision matrix (pre-integration)

**Updated:** 2026-11-03  
**Status:** Proprietary decision recorded. **C1 OpenMLS PoC complete for review** (`docs/E2EE_C1_REPORT.md`, `docs/E2EE_DEPENDENCY_REVIEW.md`). Production messaging crypto **not** selected until C2 approval. Milestone C **not** complete.  
**Client boundary:** `mobile/lib/core/crypto/encryption_service.dart` (`EncryptionService` / `MlsGroupEncryptionService` / `OpenMlsEncryptionService` PoC).

Licenses below were checked from upstream LICENSE files / pub.dev license pages on 2026-11-03 — not from README marketing text alone.

### Provisional C1 candidate (post-decision)

| Option | Notes |
| --- | --- |
| **G. pub.dev `openmls` 3.3.0** | MIT Dart wrapper + MIT Rust OpenMLS; RFC 9420 ciphersuite used in C1. **PoC only** — see C1 report for Android pass / iOS pending / C2 conditions. |

## Decision matrix

| Option | Protocol pedigree | Flutter path | Verified licenses | Android/iOS | Session/key storage | Commercial / disclosure | Maintenance | Operational risks | Fit for PrivacyMessenger |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **A. pub.dev `libsignal`** | Signal Protocol via upstream [signalapp/libsignal](https://github.com/signalapp/libsignal) | Dart FFI package with prebuilt natives | Wrapper **AGPL-3.0** (pub.dev). Upstream libsignal LICENSE is **AGPL-3.0** (fetched from `signalapp/libsignal` main). App-store exception on the Dart repo **does not** extend to Signal’s precompiled binaries (package docs cite signalapp/libsignal#684). | Android SDK 24+, iOS 13+ claimed | App must implement identity/prekey/session stores; private keys via `flutter_secure_storage` | AGPL source-offer obligations for network/conveyed modified versions; binary NOTICE obligations for Rust deps | Active 2026 releases | Third-party use of libsignal is **unsupported** by Signal; FFI bridge trust; AGPL compliance ops | Strong crypto, heavy legal constraint |
| **B. Matrix `flutter_vodozemac` + Olm/Megolm** | Olm (DR) / Megolm; Matrix-audited [vodozemac](https://github.com/matrix-org/vodozemac) (Least Authority audit public) | Flutter bindings package | **vodozemac Rust: Apache-2.0** (GitHub LICENSE). **flutter_vodozemac: AGPL-3.0** (pub.dev license page). Full Matrix Dart SDK also **AGPL-3.0**. | Supported via Flutter plugin | Same store responsibility; Megolm group features out of MVP scope | Using AGPL Flutter bindings likely pulls AGPL obligations even though Rust core is Apache | Active Matrix ecosystem | Binding license ≠ crypto core license — easy to misread; Megolm is group-oriented | Crypto good; Flutter binding still AGPL |
| **C. Direct FFI / platform channel to Apache vodozemac** | Same Olm/Megolm as B | Custom Flutter Rust Bridge or platform channel **owned by us**, depending only on Apache vodozemac | Target: **Apache-2.0** crypto only (must not copy AGPL binding code) | Feasible Android/iOS; we own packaging | We design secure persistent session storage | Permissive for commercial closed/source-available apps if we keep our bridge non-AGPL | We maintain the bridge | Engineering cost; must re-verify native build reproducibility and audits still apply to our packaging | **Best license/control tradeoff if AGPL is unacceptable** |
| **D. Legacy `olm` / `flutter_olm` Dart packages** | libolm C | Older FFI | pub.dev `olm` lists **Apache-2.0** | Historically Android/iOS via flutter_olm | Same | Permissive | **Weaker maintenance** (vodozemac is Matrix’s modern replacement) | libolm deprecation trajectory | Not preferred vs C |
| **E. Homemade AES/NaCl “E2EE”** | None | N/A | N/A | N/A | N/A | N/A | N/A | Protocol bugs certain | **Rejected by charter** |
| **F. Official Signal Java/Swift only via channels** | Signal | Dual native embeds | AGPL / Signal terms | Possible | Complex | Unsupported third-party use | High dual-stack cost | Diverges from Flutter architecture | Poor fit |

## Popularity is not a selection criterion

Ease of `flutter pub add` is irrelevant if licenses, unsupported upstream policy, or store obligations are incompatible. Exact LICENSE files and bundled binary notices must be re-checked at pin time.

## Secure persistent session storage (all options)

Regardless of library:

1. Private identity and ratchet state only in hardware-backed secure storage where available.  
2. Never upload private keys or plaintext to the Go API.  
3. Server stores opaque envelopes only (already started — see messaging module).  
4. Key change / safety-number UX deferred until a backend is chosen.

## Recommendation

1. **Current proprietary path:** review C1 results for **Option G (`openmls`)** before C2.  
2. AGPL options A/B remain **out** without explicit approval.  
3. Option C (first-party vodozemac) stays a fallback if OpenMLS C2 conditions fail.  
4. Do **not** wire production chat UI crypto until C2 approval.

## Explicit non-claims until proven

No claims of Signal client interoperability, sealed-sender anonymity against our server, or FS/PCS beyond tests of the chosen wiring.
