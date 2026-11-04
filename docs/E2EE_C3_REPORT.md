# Milestone C3 report — Secure messaging verification

**Date:** 2026-11-03  
**Base remote commit before C3 work:** `cff4c95` (*Milestone C2ready*) on `origin/master`  
**Working tree:** local uncommitted C3 changes (do not treat as committed until pushed)

## Objective

Close C2 security/integration gaps. Calls (Milestone D) not started.

## Priority 0 — Correctness and security

| Item | Result |
| --- | --- |
| Remove `access_token` query WS auth | **Done** — query rejected with 400; first-frame `{"type":"auth","token"}` handshake; 30s re-auth; logout disconnects active sockets |
| DeviceCryptoStore silent regen | **Done** — enrollment marker; corrupt/missing material after enrollment → `CryptoKeyLossException`; explicit `forceReenroll` only |
| Durable MLS ordering | **Done** — migration `000007` per-conversation `conversation_seq` allocated in same TX as insert; client sorts by seq + protocol rank |
| Welcome/Commit recoverability | **Done** — deferred reprocess after Welcome; seq-ordered pending sync |
| Sender/membership before display | **Done** — `_isAuthorizedSender` binds peer per conversation |
| Logout / history policy | **Documented** — logout wipes secure-storage keys + enrollment marker; SQLCipher DB file may remain but is undecryptable; re-enrollment creates a **new** identity so prior ciphertext cannot be read. Chosen policy: **destroy decryptability on logout** (not preserve under reauth). |
| Stale device after replacement | **Done** — login revokes prior MLS identities + consumes leftover packages; WS disconnect on logout/revoke |

## Priority 1 — Two-account E2E

| Check | Result |
| --- | --- |
| Go+Postgres harness `internal/e2e` | **Passed** with `DATABASE_URL` against local Docker Postgres |
| Friendship, identity, KP claim, MLS map, Welcome/Commit/app, pending sync, idempotent retry, revoke | Covered (opaque ciphertext fixtures) |
| Native OpenMLS client crypto | Covered by Flutter `openmls_poc_test` + prior Android smoke (restart, epoch, tamper) |
| Combined Flutter↔API live process-pair | **Partial** — server path + native MLS tested separately; full dual-process Flutter harness still recommended for release |

## Priority 2 — Lifecycle tests (executed)

- Corrupted enrolled secure-storage (`device_crypto_store_test`)
- Missing keys after enrollment marker
- Concurrent KP claims (`crypto` unit)
- Key substitution / continuity mismatch
- Duplicate / delayed protocol ordering (`envelope_ordering_test`)
- Epoch transition / restart (`openmls_poc_test`)
- WS query reject + revoke disconnect (`realtime_handler_test`)
- Session revoke during WS (re-auth ticker + DisconnectToken)

## Priority 3 — Product / hardening

| Item | Status |
| --- | --- |
| Safety-number screen | **Added** `safety_number_screen.dart` (trust states + key-change copy) |
| Crypto API rate limits | **Added** in-process 60/min per user |
| LicenseRegistry notices | **Added** `license_notices.dart` registered in `main` |
| CI + govulncheck + iOS compile job | **Added** `.github/workflows/ci.yml` (not yet run on GitHub Actions) |
| Migration `000006`/`000007` | **Applied** on local Docker DB (upgrade path verified) |
| Android native re-run | See session results below |
| macOS iOS | CI job prepared; **not executed on this Windows host** — **unwaived release blocker** |

## Exact tests executed

| Suite | Result |
| --- | --- |
| `go test ./internal/crypto ./messaging ./httpapi ./auth ./e2e` | **pass** (e2e with Postgres) |
| `flutter analyze` | No issues |
| `flutter test` | **84 passed** |
| `flutter build apk --debug` | **Success** |
| Migrations 000006+000007 on live Docker | **Applied successfully** |
| Android emulator OpenMLS smoke | **Not re-run** — emulator failed to start; APK build is compile gate only |
| GitHub Actions CI | **Not executed** (workflow added only) |
| iOS simulator | **Not executed** (unwaived blocker) |

## Security findings

1. Query-string bearer tokens removed (prevents access-log leakage).
2. Postgres unique-violation abort previously broke idempotent envelope retries when combined with seq allocation — fixed with pre-insert idempotent lookup.
3. Server still cannot prove human identity; safety numbers are advisory.
4. In-process rate limiter is not cluster-safe (single API instance assumption).

## Remaining limitations / blockers for calling Milestone C “complete”

1. **iOS verification** still unwaived (macOS runner required).
2. Dual Flutter-process live E2E against API not automated in one binary.
3. CI workflow not yet green on GitHub.
4. Cluster-wide crypto rate limiting / Redis not introduced (by design).
5. Safety-number UI not yet wired into every conversation chrome.

## Milestone C verdict

**C3 security/integration gaps substantially closed for review.**  
**Do not mark Milestone C complete** until iOS gate is accepted or executed, CI runs green, and product accepts residual limitations above.

**Stop before Milestone D.**
