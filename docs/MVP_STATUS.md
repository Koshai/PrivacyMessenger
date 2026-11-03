# PrivacyMessenger MVP Status

**Updated:** 2026-11-03  
**Repository:** https://github.com/Koshai/PrivacyMessenger  
**Branch:** `master` (local Milestone A + B changes; not yet committed)

## Suite results (verified this session)

| Suite | Result | Command |
| --- | --- | --- |
| Flutter tests | **56 passed** | `cd mobile && flutter test` |
| Flutter analyze | **No issues** | `cd mobile && flutter analyze` |
| Go unit + integration | **pass** (with Postgres) | `cd backend && go test ./...` |
| Go vet | **pass** | `cd backend && go vet ./...` |
| Android debug APK | **Built** (`app-debug.apk`) | `cd mobile && flutter build apk --debug` |

### Environment notes

- Local Postgres via `deploy/compose.yaml` on `127.0.0.1:55433`.
- Integration tests require `DATABASE_URL` (URL-encode special characters in the password).
- A stray `dart.exe` process previously bound `127.0.0.1:55433`, causing `unexpected EOF` on Postgres connects.
- `go test -race` requires CGO on this Windows host (`CGO_ENABLED=1`); not executed as passed.

## Milestone A — Authentication hardening

**Status: complete**

### Implemented

- Removed duplicate `@override` in `mobile/lib/main.dart`.
- Typed `ApiException` with `ApiErrorKind`.
- `AuthController` generation on logout, store serialization, duplicate logout guard, typed unauthorized handling.
- Navigation: `MaterialApp(key: ValueKey(status))` prevents back into OTP after login.
- flutter_secure_storage v11 default Keystore-backed Android options.
- Docs: `docs/MVP_STATUS.md`, `docs/MVP_PLAN.md`.

### Tests

- Flutter: logout success/failure, duplicate logout, stale validation, identity mismatch, login→Chats, OTP back-stack isolation, settings logout UI.
- Go: existing auth unit/handler/integration tests green with Postgres.

## Milestone B — Friends and privacy

**Status: complete (automated tests green)**

### Implemented

- Migration `000004_friends` (`friendships`, `user_blocks`, `friend_request_limits`).
- Go `internal/friends` domain, repository, rate limiter, service (fake-store unit tests + Postgres integration).
- Authenticated HTTP API:
  - `POST /friends/requests`
  - `GET /friends/requests/incoming|outgoing`
  - `POST /friends/requests/{id}/accept|reject`
  - `GET /friends`, `GET /friends/count`
  - `DELETE /friends/{userID}`
  - `POST /friends/blocks`, `GET /friends/blocks`, `DELETE /friends/blocks/{userID}`
- Enumeration-resistant request creation (unknown/blocked targets → generic 202).
- Private friend list/count for the authenticated caller only.
- Flutter models, `ApiClient` friends methods, `FriendsController`, accessible Friends UI (add/accept/reject/remove/block/unblock, loading/empty/error).

### Manual verification outstanding

- Two real accounts exchanging requests on emulator against running API + SMTP
- Confirm rate-limit UX under burst traffic

## Remaining milestones

| Milestone | Status |
| --- | --- |
| A — Authentication hardening | **Complete** |
| B — Friends and privacy | **Complete** |
| C — E2EE messaging | **Blocked pending license decision** — see `docs/E2EE_EVALUATION.md` |
| D — Audio/video calling | Not started |
| E — Release candidate | Not started |

## Security notes

- Auth: hashed tokens/OTP; one active session; typed client unauthorized handling.
- Friends: no public directory or third-party friend-list endpoint; self-only count; normalized unknown-email responses; request rate limits.
- Limits: local compose is not TLS-terminated; production ops maturity deferred to Milestone E.
