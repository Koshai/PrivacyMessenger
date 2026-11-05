# Milestone D1.1 + D2 report — Signaling hardening & WebRTC clients

**Date:** 2026-11-04  
**Base:** D1 signaling + Milestone C (`4e74c81` verified)  
**Scope:** D1.1 mandatory signaling corrections + D2 Flutter audio/video WebRTC clients.  
**Milestone D:** **not complete.** Stop before D3 (TURN / production NAT).

## Objective

Finish D1 signaling correctness and implement real one-to-one WebRTC audio/video connectivity while preserving A–C and existing calling contracts.

## D1.1 — Signaling corrections (Go)

| Correction | Implementation |
| --- | --- |
| Answer ≠ connected | SDP answer leaves session in `accepted`; `connected` only after client `POST /calls/{id}/connected` (client-reported, not server-verified media) |
| One active call / user | PostgreSQL advisory locks + transactional busy checks; simultaneous-initiate integration test |
| Atomic end + SDP/ICE clear | `EndSessionAtomic` clears signaling in the same DB transaction; failures propagate |
| Accept device binding | Callee device recorded on accept; conflicting device retries rejected |
| ICE limits concurrency-safe | Idempotent `client_ice_id` under transactional constraints |
| Initiate idempotency validation | Retry must match original callee, caller device, and media type |
| Privacy errors | Blocked / non-friend targets return unified not-available / 404-style responses |
| Versioned transitions | Optimistic `version` checks reject stale concurrent updates |

Migrations: `000008_calling`, `000009` (D1.1 hardening as applied in repo).

## D2 — Flutter WebRTC

| Item | Result |
| --- | --- |
| Package | `flutter_webrtc` **1.6.3** (pinned, MIT) |
| License notice | `mobile/docs/licenses/flutter_webrtc-1.6.3-NOTICE.md` |
| Permissions | `permission_handler`; mic/camera only after user start/accept |
| Architecture | `CallService` → `WebRtcCallService` / `FakeCallService`; `CallController`; `CallingApiClient`; WS hints via `RealtimeClient` |
| ICE config | Injectable `IceServerConfig` (default public STUN; TURN fields ready for D3) |
| UI | `CallHost` / call screens; conversation audio+video entry points; no WebRTC ops in widgets |

### Client behaviors delivered

- Outgoing / incoming foreground audio and video calls
- Accept, decline, cancel, hang up
- Offer/answer + trickle ICE (+ poll)
- Mute, speaker (where supported), camera enable/switch
- ICE connection monitoring; failure cleanup; logout ends call
- Reconcile via `GET /calls/active` after reconnect
- Duplicate offer/answer dedupe; late ICE; ring timeout
- Camera failure → audio-only fallback when `getUserMedia` video fails
- Dispose tracks/renderers/peer connection on termination

### Explicit non-claims

- No reliable background ringing (D5)
- No production TURN / relay verification (D3)
- No MLS-authenticated call peer binding (D4)
- Milestone D incomplete until broader D6/D7 gates

## Tests executed

### Go

| Suite | Result |
| --- | --- |
| `go test ./...` | **pass** |
| `go test ./internal/calling` with `DATABASE_URL` (incl. `TestPostgresCallLifecycleD11`, `TestPostgresSimultaneousInitiate`, `TestPostgresBlockedPrivacy`) | **pass** |
| `go test ./internal/httpapi` | **pass** |

### Flutter

| Suite | Result |
| --- | --- |
| `flutter analyze` | **No issues found** |
| `flutter test test/features/calling` | **pass** (13 tests: controller, API, two-client signaling mock) |
| `flutter test` (full) | **103 pass / 1 fail** — `live_two_client_e2e_test` failed with `identity revoked` against long-running local API fixture (unrelated to calling; re-seed API to clear) |
| `flutter build apk --debug` | **pass** (`build/app/outputs/flutter-apk/app-debug.apk`) |
| Android emulator `integration_test/webrtc_android_smoke_test.dart` (`emulator-5554`) | **pass** — native `createPeerConnection` + audio `getUserMedia` + local offer |
| macOS / iOS compile | **skipped** — no Xcode/`xcodebuild` on this Windows host; `Info.plist` mic/camera usage strings added for when iOS builds run |

## Architecture notes

- Authoritative call state remains PostgreSQL; WebSocket events are hints only.
- Media connectedness is **client-reported** (`MarkConnected`); the server does not verify DTLS-SRTP delivery.
- Direct host connectivity on a controlled test network is sufficient for D2; TURN remains D3.

## Docs updated

- `docs/CALLING_ARCHITECTURE.md`
- `docs/CALLING_SECURITY.md`
- `docs/MVP_PLAN.md`
- `docs/MVP_STATUS.md`
- this report

## Next

Review D1.1 + D2 → then **D3 TURN** (injectable short-lived credentials, relay verification). Do **not** mark Milestone D complete.
