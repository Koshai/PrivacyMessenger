# PrivacyMessenger MVP Plan

## Principles

- Preserve working auth architecture; incremental milestones only.
- No homemade cryptography; stop Milestone C if a trustworthy E2EE library cannot be integrated.
- Do not add groups, stories, feeds, public profiles, or AI features.
- A milestone is done only when compile, tests, analysis, migrations, and docs criteria in the charter are met.

## Milestone A — Authentication hardening

**Goal:** Reliable OTP login, secure session restore, server logout, typed errors, concurrency-safe controller, navigation regressions.

**Acceptance**

- [x] Duplicate annotation fixed; Flutter analyze clean of errors
- [x] Typed API errors (no string equality for session revocation)
- [x] AuthController: generation on logout, duplicate logout prevention, stale op discard, serialized store access
- [x] Login → authenticated shell; no back-navigation into OTP
- [x] Flutter tests: restore, sign-in, logout success/failure, duplicate logout, stale validation, invalid session cleanup, navigation
- [x] Go auth unit + handler tests green; PostgreSQL integration tests executed when `DATABASE_URL` available
- [x] `docs/MVP_STATUS.md` updated

**Then:** proceed to B without rewriting auth. **(Reached — starting B.)**

## Milestone B — Friends and privacy

**Goal:** Email friend requests, accept/reject/remove/block, private lists and counts, enumeration-resistant lookups, rate limits.

**Acceptance:** charter backend + Flutter mandatory tests; no public directory or third-party friend-list exposure.

**Status:** complete (2026-11-03) — see `MVP_STATUS.md`.

## Milestone C — End-to-end encrypted messaging

**Goal:** Proprietary-compatible E2EE using pinned MIT `openmls` 3.3.0 behind `EncryptionService`. Opaque envelopes on server; secure device crypto store; key packages; MLS delivery; 1:1 encrypted chat; WebSocket sync hints.

**Acceptance:** charter crypto/message tests; never claim properties the library does not provide and test. No AGPL/GPL deps without approval.

**Status:**
- **C1** (committed `e594b14`): dependency review + isolated OpenMLS PoC + native tests.
- **C2** (local/uncommitted for review): DeviceCryptoStore, key-package API, MLS group mapping, chat UI, WebSocket — see `docs/E2EE_C2_REPORT.md`.
- **Milestone C not complete** until E2E, iOS, migration/integration gates, and blockers in the C2 report are closed.

## Milestone D — One-to-one audio/video calls

**Goal:** WebRTC calling with authenticated signaling, mute/camera, timeouts, STUN/TURN docs, no media recording.

## Milestone E — Release candidate

**Goal:** Accessibility / Easy Mode, secure config, migration verification, Android release build, iOS readiness, security review, developer docs. Distinguish MVP-ready vs production-ready maturity.

## Suggested sequence after A

1. B friends domain + HTTP + Flutter UI/tests  
2. C crypto evaluation memo → key registration → envelopes → sync → WebSocket  
3. D signaling → WebRTC client → TURN docs  
4. E polish and release checklist  

## Test commands

```bash
# Backend (unit/handler)
cd backend && go vet ./... && go test ./...

# Backend (with Postgres)
# DATABASE_URL=postgres://messenger:…@127.0.0.1:55433/private_messenger?sslmode=disable
cd backend && go test ./...

# Mobile
cd mobile && flutter analyze && flutter test
```
