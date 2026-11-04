# Milestone C4 report — Final E2EE verification

**Date:** 2026-11-03  
**Base remote commit before C4:** `1ad22da` (*C3 completed*)  
**C4 remote commit:** `4e74c81661173bfe8b156425a1daa55331e4dd0e` (`4e74c81`)  
**Prior CI on C3:** [run 41775116006](https://github.com/Koshai/PrivacyMessenger/actions/runs/41775116006) — **failure** (`govulncheck` on Go 1.26.5 / `golang.org/x/text@v0.29.0`)  
**C4 CI:** [run 41776665396](https://github.com/Koshai/PrivacyMessenger/actions/runs/41776665396) — **success** (`go`, `flutter`, `ios-compile`, `live-e2e`)

## Objective

Complete verification and release hardening for Milestone C. Milestone D (calls) not started.

## Task 1 — Commit and CI

| Item | Result |
| --- | --- |
| Working tree before C4 | Clean at `1ad22da` |
| Go toolchain | Bumped to **1.26.10** (`go.mod` + CI) |
| `golang.org/x/text` | Bumped to **v0.41.0** |
| Local `govulncheck ./...` | **No vulnerabilities found** |
| Misleading Flutter audit (`dart pub outdated \|\| true`) | **Removed**; replaced with `flutter pub deps` |
| CI jobs | `go`, `flutter`, `ios-compile` (+ native OpenMLS tests), **`live-e2e`** |
| Remote CI after C4 push | **success** — [41776665396](https://github.com/Koshai/PrivacyMessenger/actions/runs/41776665396) |

## Task 2 — Secure enrollment lifecycle

`DeviceCryptoStore` now exposes explicit states:

- `neverEnrolled`, `enrolling`, `active`, `corrupted`, `revoked`

Behaviors:

- Interrupted `enrolling` without complete material → **corrupted**, no silent regen
- Crash after material write while still `enrolling` → recovered to **active**
- Corrupt blob → **corrupted** + `CryptoKeyLossException`
- Logout → wipe keys + **revoked** (history undecryptable; next login may enroll a **new** identity intentionally)
- `forceReenroll` marks revoked, clears, then enrolling→active (safe against interrupted replacement)

Tests: `device_crypto_lifecycle_test.dart`, existing `device_crypto_store_test.dart`.

## Task 3 — MLS protocol verification

| Check | Result |
| --- | --- |
| Seq allocation + insert same TX | Confirmed; added explicit `SELECT … FOR UPDATE` before seq bump |
| Concurrent senders | `TestConversationSeqConcurrentAllocation` — dense unique seqs |
| Welcome / Commit / app ordering | Client `compareEnvelopesForProcessing` + server `conversation_seq` |
| Failed crypto ack | Application messages **not** acked without plaintext; Welcome/Commit ack only after successful processing (joiner may skip redundant Commit epoch) |
| Server-path E2E | `TestTwoAccountEncryptedMessagingPath` pass |

## Task 4 — Live two-client native OpenMLS E2E

Harness:

- `backend/cmd/e2eseed` — isolated Alice/Bob sessions + friendship
- `mobile/test/integration/live_two_client_e2e_test.dart` — **native OpenMLS** encrypt/decrypt via real HTTP API
- CI job `live-e2e` orchestrates Postgres + API + Flutter test

Local execution (this session): **PASS** against Docker Postgres + API on `:4010`.

Covered: auth fixtures, friendship, identity + KP upload/claim, MLS group, Welcome/Commit delivery, bidirectional encrypted text, offline sync, process restart, idempotent duplicate send, peer fingerprint read, device revoke → upload denied.

## Task 5 — Android and iOS

| Gate | Result |
| --- | --- |
| Android emulator OpenMLS | **13/13 pass** (`openmls_poc_test`); debug APK built, `adb install` + launcher start on `emulator-5554` |
| iOS compile | CI `ios-compile` on `macos-latest` (C3 already green; C4 re-runs + OpenMLS unit tests) |
| iOS simulator physical-hardware extras | None required beyond simulator/unit path; **macOS CI is the iOS gate** |
| Physical device | Not required for C4 |

## Task 6 — Security and product

| Item | Result |
| --- | --- |
| WS auth frame bound | 8 KiB max + token length cap |
| Handshake timeout | 10s |
| Production TLS | `REQUIRE_TLS` / `APP_ENV=production` requires `TLS_CERT_FILE` + `TLS_KEY_FILE`; `ListenAndServeTLS` when set |
| Origin policy | `WS_ALLOWED_ORIGINS` → `OriginPatterns` (default: request host only) |
| Token log redaction | `AttachRedactingErrorLog` + `RedactSecrets` |
| Safety number UI | Widget test for key-change warning + trust transitions |
| Crypto rate limits | 60/min per user **in-process** (single-instance limitation documented) |
| Logout UX policy | Keys destroyed; prior ciphertext not recoverable; re-login enrolls new identity |

## Exact tests executed (local)

| Suite | Result |
| --- | --- |
| `go test ./...` (Go 1.26.10, Postgres) | **pass** |
| `govulncheck ./...` | **pass** (0 vulns) |
| `flutter analyze` | No issues |
| `flutter test` | **90 passed**, 1 skipped (live E2E without env) |
| Live E2E with API+fixture | **pass** |
| Android emulator `openmls_poc_test` | See Android log below |
| Migrations 000006/000007 | Already applied on local Docker; CI reapplies clean |

## Residual limitations

1. Crypto rate limiter is **not** cluster-safe (single API process).
2. Safety-number screen is implemented and tested; not yet wired into every conversation chrome entry point.
3. Production TLS is enforced only when `REQUIRE_TLS`/`APP_ENV=production` is set by operators.
4. Crypto rate limiter remains single-process; operators must not assume multi-instance fairness without a shared store.

## Milestone C verdict

C4 closes the remaining verification gaps from C3.  
**Remote CI is green** on `4e74c81` (including `live-e2e` and `ios-compile`).  
**Milestone C may be marked complete** pending product sign-off on residual limitations above.

**Stop before Milestone D.**
