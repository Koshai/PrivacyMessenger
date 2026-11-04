# PrivacyMessenger MVP Status

**Updated:** 2026-11-03  
**Repository:** https://github.com/Koshai/PrivacyMessenger  
**Committed HEAD (origin/master):** `92197b6` — *feat: harden auth lifecycle and add private friends MVP*  
**Local uncommitted work:** post-B hardening + opaque envelopes + **Milestone C1 OpenMLS PoC**.

## Committed vs local

| Area | In `92197b6` (committed) | Local (uncommitted) |
| --- | --- | --- |
| Milestone A auth hardening | Yes | Additional concurrency fixes + delayed-store tests |
| Milestone B friends | Yes | Enumeration hardening + adversarial HTTP tests |
| Messaging envelopes | No | Migration `000005`, opaque ciphertext routes/tests |
| Encryption / C1 | Stub only in earlier local work | `openmls` **3.3.0** PoC behind `EncryptionService` / `MlsGroupEncryptionService` |
| E2EE docs | Evaluation matrix | `E2EE_DEPENDENCY_REVIEW.md`, `E2EE_C1_REPORT.md`, third-party notices |

## Suite results (C1 session)

| Suite | Result | Command |
| --- | --- | --- |
| Flutter analyze | **No issues** | `cd mobile && flutter analyze` |
| Flutter tests | **76 passed** | `cd mobile && flutter test` |
| OpenMLS PoC tests | **13 passed** (native) | `flutter test test/core/crypto/openmls_poc_test.dart` |
| Android debug APK | **Built** | `flutter build apk --debug` → `app-debug.apk` |
| Android emulator runtime | **Passed** | `integration_test/openmls_android_smoke_test.dart` on Pixel_8_API_36 |
| iOS | **Not run** (Windows host) | Needs macOS |
| Go tests | Pre-existing envelope suites unchanged by C1 client | `go test ./...` |

## Milestone progress

| Milestone | Status |
| --- | --- |
| A — Auth | Complete (committed + local race hardening) |
| B — Friends | Complete (committed + local enumeration fixes) |
| C — E2EE | **C1 PoC complete for review** — OpenMLS MIT candidate; **Milestone C not complete** |
| D — Calls | Not started |
| E — Release | Not started |

## C1 summary

- Proprietary-compatible gate passed for pinned `openmls` 3.3.0 (no AGPL/GPL blocker).  
- Isolated Alice/Bob MLS round-trip, persistence restart, tamper/unauthorized/duplicate/epoch tests.  
- Server remains opaque-envelope only.  
- Full report: `docs/E2EE_C1_REPORT.md`.  
- **Next:** review C1 → decide C2; do not ship messaging UI crypto yet.

## Recommended path

1. Review `docs/E2EE_C1_REPORT.md` and approve/reject OpenMLS for C2.  
2. Commit C1 + post-B hardening when ready.  
3. Arrange iOS macOS verification before production crypto.  
4. Keep Milestone C incomplete until C2 production integration criteria are met.
