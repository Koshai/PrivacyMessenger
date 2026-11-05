# D2.1 stabilization + D3 TURN

**Date:** 2026-11-05  
**Scope:** Live OpenMLS fixture isolation, call-controller recovery, coturn REST credentials, relay verification.  
**Milestone D:** **not complete.** D4–D7 not started.

## Phase 0 — live E2E identity revoked

**Cause:** `live_two_client_e2e_test` ends by calling `POST /crypto/device/revoke` on Alice’s seeded device. `UpsertIdentity` then returns `ErrIdentityRevoked` (`403 identity revoked`) if the next run reuses that device. Revocation checks were left intact.

**Fix:** Each live run executes `go run ./cmd/e2eseed` against `DATABASE_URL` and uses only that new user/device/session pair. The test no longer reads `LIVE_E2E_FIXTURE`. CI passes `DATABASE_URL` into the Flutter test; the pre-seeded fixture step was removed.

## Phase 1 — D2.1

`CallController` now:

- Retries local ICE submits (bounded).
- Advances the remote ICE cursor only after a successful `addRemoteIce`, or when the seq was already applied (dedup).
- Drops async refresh/ICE/media events whose call generation is stale.
- Treats server `connected` as non-authoritative for local media (`localMediaConnected` only after a WebRTC indication).
- Hangs up the server call if setup fails after `POST /calls`.
- Handles permission denial, `onNavigationAway`, logout, and app lifecycle (`resumed` reconciles, `detached` hangs up).
- Makes hangup idempotent and disposes native media once.
- Cancels a short disconnect grace timer on reconnect; otherwise ends the call.

## Phase 2–3 — TURN

- `internal/turn` issues coturn `use-auth-secret` credentials (HMAC-SHA1, TTL 60s–1h).
- `GET /calls/ice-config` is authenticated and rate-limited. Responses contain URLs, username, credential, and expiry only.
- Empty `TURN_SHARED_SECRET` → `503 TURN unavailable` (API still starts).
- Flutter parses that payload, refreshes it per peer connection, supports UDP/TCP/TLS URLs returned by the server, direct and relay-only modes, and surfaces TURN-unavailable / expired-credential failures.

## Phase 4 — deployment

`docs/TURN_DEPLOYMENT.md` and `deploy/coturn/`. No live credentials committed. The compose default `local-dev-turn-secret` is a loopback example.

## Tests executed locally

| Check | Result |
| --- | --- |
| `go test ./internal/turn` (unit) | pass |
| `go test ./internal/httpapi` (incl. ice-config contract, revoked session, secret non-leak) | pass |
| `TURN_RELAY_TEST=1` `TestRelayOnlyDataChannel` against coturn `4.6.3` | **pass (2.31s)** — nominated relay pair and data-channel payload `relay-ok` |
| `flutter analyze` | no issues |
| `flutter test test/features/calling` | pass (26) |
| Full `flutter test` with `LIVE_E2E=1` against `http://127.0.0.1:4010` | **117 passed, 0 failed, 0 skipped** (fresh `e2eseed` identities; revocation check still runs) |
| `go test ./...` with `DATABASE_URL` | pass, including `internal/turn` |
| Android debug APK | Built by the smoke run: `build/app/outputs/flutter-apk/app-debug.apk` |
| Android emulator WebRTC smoke (`emulator-5554`) | **Pass** after mic permission grant. First attempt hung on the permission dialog and did not complete |
| iOS | not run on this Windows host. Workflow job `ios-compile` was **not executed** (no push) |
| GitHub Actions for this change | **not run** (no push) |

## Remote SHA

`origin/master` and local `HEAD` are `f57cd32fb82951beb6b213c894956be0144251cd`. D2.1/D3 edits are uncommitted, so that SHA does not contain this work.

## Not claimed

- MLS-authenticated calls (D4)
- Reliable background ringing (D5)
- Milestone D complete
- Production coturn capacity or a specific public TURN hostname
