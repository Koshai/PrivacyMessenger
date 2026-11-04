# Milestone C1 report — OpenMLS proprietary-compatible PoC

**Date:** 2026-11-03  
**Status:** C1 complete for review — **Milestone C not marked complete**  
**Scope:** Isolated technical proof of concept only. No production messaging UI.

## 1. Package versions and licenses

| Component | Version | License |
| --- | --- | --- |
| `openmls` (pub.dev) | **3.3.0** (pinned in `mobile/pubspec.yaml` + `pubspec.lock`) | MIT |
| Upstream Rust OpenMLS (bundled) | 0.9.2 (per package claims / advisory notes) | MIT |
| `flutter_rust_bridge` | 2.13.0 (transitive) | Apache-2.0 / MIT-compatible stack |
| Native tree | See `docs/licenses/openmls-3.3.0-THIRD_PARTY_NOTICES.txt` | MIT / Apache-2.0 / BSD / ISC / Unlicense; dual-license crates elect MIT/Apache |

**Ciphersuite used:** `mls128DhkemX25519Aes128GcmSha256Ed25519` (RFC 9420, non-experimental).

**Copyleft gate:** No AGPL/GPL-only required dependency identified for this pin. Full review: `docs/E2EE_DEPENDENCY_REVIEW.md`.

## 2. Files added or modified (C1 crypto surface)

### Added

| Path | Role |
| --- | --- |
| `docs/E2EE_DEPENDENCY_REVIEW.md` | Phase 1 license/security gate |
| `docs/licenses/openmls-3.3.0-THIRD_PARTY_NOTICES.txt` | Bundled native notices |
| `mobile/docs/licenses/openmls-3.3.0-THIRD_PARTY_NOTICES.txt` | App-tree copy |
| `docs/E2EE_C1_REPORT.md` | This report |
| `mobile/lib/core/crypto/protocol_messages.dart` | Wire kinds + identity/key-package records |
| `mobile/lib/core/crypto/openmls/openmls_encryption_service.dart` | OpenMLS `MlsGroupEncryptionService` |
| `mobile/lib/core/crypto/openmls/mls_device_harness.dart` | Isolated Alice/Bob test devices |
| `mobile/test/core/crypto/openmls_poc_test.dart` | Native OpenMLS integration tests |

### Modified

| Path | Role |
| --- | --- |
| `mobile/pubspec.yaml` / `pubspec.lock` | Pin `openmls: 3.3.0` |
| `mobile/lib/core/crypto/encryption_service.dart` | `EncryptionService` + `MlsGroupEncryptionService` |
| `mobile/test/core/crypto/encryption_service_test.dart` | Stub + backend-id checks |
| `docs/MVP_STATUS.md` | C1 status (not full Milestone C) |

Server continues to store **opaque** envelope bytes + content-type routing metadata only (`backend/internal/messaging`).

## 3. Test classes and results

| Suite | Result |
| --- | --- |
| `flutter analyze` | **No issues** |
| `test/core/crypto/openmls_poc_test.dart` | **13 passed** (native Rust via FRB on Windows host) |
| Full `flutter test` | **76 passed** (includes auth + friends; prior baseline preserved) |
| Go messaging/auth/friends suites | Pre-existing envelope opacity tests remain (not re-broken by C1 client PoC) |

### Coverage mapped to charter

| Requirement | Test |
| --- | --- |
| Identity generation + persistence / restart | identity + restart tests |
| Key package create/validate | identity/key package test |
| Group create + Welcome join | alice↔bob round trip |
| Alice→Bob / Bob→Alice encrypt/decrypt | round trip |
| Tampered ciphertext | rejects |
| Unauthorized member | Eve outsider |
| Duplicate messages | second process rejects |
| Out-of-order (same epoch) | decrypts both (secret-tree window) |
| Stale Welcome | third device rejected |
| Epoch transition | self-update commit |
| Concurrent sends | parallel encrypt + sequential decrypt |
| Key loss | no silent identity regeneration |
| Zero DB keys | constructor rejects |

Mock-only encryption tests were **not** used for the PoC path — `openmls` loads the real native library.

## 4. Android build / runtime

| Check | Status |
| --- | --- |
| Emulator | Pixel_8_API_36 → `emulator-5554` (Android 16 / API 36) |
| Debug APK build | **Success** — `flutter build apk --debug` → `build/app/outputs/flutter-apk/app-debug.apk` |
| Runtime on emulator | **Passed** — `flutter test integration_test/openmls_android_smoke_test.dart -d emulator-5554` (Alice↔Bob native round-trip) |

## 5. iOS verification

| Check | Status |
| --- | --- |
| This host | Windows — **cannot** run Xcode/iOS simulator |
| Package claim | iOS device/simulator supported by openmls 3.3.0 |
| Required follow-up | Arrange macOS `flutter build ios` / simulator run before C2 production decision |

## 6. Cryptographic and operational limitations

1. **PoC only** — not wired into chat UI or production send path.
2. **Signer/identity bytes** are caller-managed; SQLCipher holds MLS group state. After process death, identity must be re-adopted — we **refuse** silent regeneration.
3. **DB encryption key** is caller-provided (`Random.secure()` in harness); secure persistence (Keystore/Keychain) is C2+.
4. **Welcome before merge race** — production DS must accept Commit then deliver Welcome (documented by OpenMLS API); PoC merges add-commit locally then joins via Welcome in-process.
5. **Delivery service semantics** (ordering, fan-out, membership authz beyond friendship) not productionized.
6. **Publisher trust:** pub.dev publisher unverified; natives from GitHub Releases with package SHA256 hooks — supply-chain review still needed for C2.
7. **PQ / experimental suites** intentionally unused.
8. **Atomicity:** engine persists via native SQLCipher on mutation; `persistAndClose` closes cleanly. Outgoing app-message + local DB write atomicity with server ack is **not** implemented in C1 (harness is in-memory wire exchange).

## 7. Suitability for Milestone C2

**Conditional yes** for continuing behind `EncryptionService`, subject to:

- macOS iOS build/runtime verification  
- Secure identity + DB-key storage design  
- Production commit/Welcome DS ordering  
- SCA in CI (OSV) and LicenseRegistry wiring  
- Independent security review of FRB binding surface  
- Explicit product approval that MIT `openmls` remains the production candidate  

**Do not** mark Milestone C complete. Stop after C1 pending review.
