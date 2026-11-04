# Milestone C2 report — OpenMLS production path (partial)

**Date:** 2026-11-03  
**Base commit before C2 work:** `e594b14` (C1 committed on `master`)  
**Status:** C2 implementation landed for review — **Milestone C still not complete**

## Implemented modules

| Area | Status |
| --- | --- |
| `DeviceCryptoStore` + `MlsSessionManager` | Done — secure storage for signer + SQLCipher key; fail-closed restore |
| Key-package Go service + HTTP API | Done — register, upload, atomic claim, peer identities, revoke |
| Conversation ↔ MLS group mapping | Done — `PUT .../mls-group`; application msgs require mapping |
| Opaque envelope MLS content types | Done |
| Flutter 1:1 encrypted chat UI | Done — friends → conversation screen; send/receive/retry/offline banner |
| Authenticated WebSocket hints | Done — `/realtime/ws`; Postgres remains SoT |
| Automated unit tests (Go + Flutter) | Done for core modules |
| Full multi-account E2E via live API | **Outstanding** (harness not fully automated this session) |
| iOS runtime | **Outstanding** (needs macOS) |
| Crypto rate limits | Partial — package size/TTL guards; dedicated rate limiter TBD |
| SCA / license CI scan | **Outstanding** |

## Migrations

- `backend/migrations/000006_mls_crypto.up.sql` / `.down.sql`
  - `device_mls_identities`, `mls_key_packages`
  - conversation MLS columns
  - envelope `seq` trigger

## Key files

### Backend
- `internal/crypto/*` — domain, service, memory + Postgres store, tests
- `internal/httpapi/crypto_*.go`, `realtime_handler.go`
- `internal/messaging` — MLS establish, content-type gates, notifying wrapper
- `internal/realtime/hub.go`
- `cmd/api/main.go` — wiring

### Mobile
- `lib/core/crypto/device_crypto_store.dart`, `mls_session_manager.dart`
- `lib/features/messaging/*` — service, controller, screen, realtime client
- `lib/features/chats/chats_screen.dart` — open chats with friends
- Tests: `device_crypto_store_test.dart`, messaging model tests, existing OpenMLS PoC

### Contracts / docs
- `contracts/mls-key-packages-api.md`
- `contracts/messaging-envelopes-api.md` (updated)
- This report + `MVP_STATUS.md` / `MVP_PLAN.md`

## Exact test results (executed)

| Suite | Result |
| --- | --- |
| `flutter analyze` | No issues |
| `flutter test` | **81 passed** |
| `go test ./...` | **pass** (auth, config, crypto, friends, httpapi, messaging) |
| `go vet ./...` | **pass** (with test run) |
| Android debug APK | **Built** (`app-debug.apk`) |
| PostgreSQL integration for 000006 | Requires `DATABASE_URL` migration apply — run before deploy |
| iOS | Not executed |

## Security limitations

1. Server-mediated fingerprints are not end-to-end identity proof.
2. WebSocket events can be dropped (bounded queue); clients must sync pending.
3. MLS Welcome/Commit ordering relies on client sorting by timestamp; DS does not validate MLS epoch cryptographically.
4. Private keys never leave device secure storage by design — key loss requires explicit re-enrollment (no silent regen).
5. Concurrent initiator races: second `EstablishMlsGroup` conflicts; joiner must ingest Welcome.
6. Full offline queue durability for unsent plaintext drafts is minimal (failed send retry in UI).

## Remaining blockers for Milestone C

1. Automated two-account E2E (friendship → claim KP → encrypt → disconnect sync → process restart).
2. Apply migration `000006` in all environments + Postgres integration tests for crypto reservation under load.
3. iOS OpenMLS verification on macOS.
4. Hardening: crypto rate limits, LicenseRegistry notices in app, OSV/SCA in CI.
5. Safety-number UI beyond warning banner.
6. Explicit product sign-off that OpenMLS remains production crypto.

**Do not start Milestone D until the above blockers are accepted or closed.**
