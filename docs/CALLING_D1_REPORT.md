# Milestone D1 report — Calling signaling

**Date:** 2026-11-04  
**Base:** Milestone C complete (`8efdc5f` docs / `4e74c81` verified)  
**Scope:** Signaling only. **D2–D7 not started.** Milestone D **not** complete.

## Objective

Standalone `internal/calling` module with authenticated HTTP signaling, WS hints, friendship/block authorization, timeouts, idempotency, payload bounds, and tests — without Flutter WebRTC UI yet.

## flutter_webrtc selection (for D2)

| Check | Result |
| --- | --- |
| License | MIT |
| Version reviewed | 1.6.3 (2026-10-26) |
| Platforms | Android / iOS / desktop / web |
| Added to `pubspec` in D1? | **No** (signaling-only milestone) |

## Delivered

### Domain / persistence

- Migration `000008_calling` — `call_sessions`, `call_ice_candidates`
- States: `ringing` → `accepted` → `connected` → `ended`
- SDP/ICE cleared on terminal state
- Ring timeout default 45s; background ticker every 5s

### API

Authenticated routes under `/calls` (initiate, accept, decline, cancel, hangup, offer, answer, ice, get, active).

### Realtime

`realtime.Event` extended with `call_id`; types `call.ringing|accepted|offer|answer|ice|connected|ended`.

### AuthZ / safety

- Friends + blocks
- Busy single-active-call
- Logout ends active calls (`revoked`)
- Rate limit 60/min/user (in-process)
- SDP ≤ 64KiB, ICE ≤ 4KiB, ≤ 64 ICE/call
- Replay of conflicting SDP rejected

## Tests executed

| Suite | Result |
| --- | --- |
| `go test ./internal/calling` (unit + Postgres integration) | **pass** |
| `go test ./internal/httpapi` (HTTP calling + existing) | **pass** |
| `go test ./...` | **pass** |
| Flutter / WebRTC media | **N/A (D2+)** |
| Two-client real WebRTC | **N/A (D6)** |

Covered scenarios: authorize create; nonfriend/blocked reject; state transitions; duplicate initiate/accept/ICE; cancel/decline/timeout; revoke-on-end; SDP size limit; hangup clears signaling.

## Docs

- `docs/CALLING_ARCHITECTURE.md`
- `docs/CALLING_SECURITY.md`
- `docs/CALLING_D1_REPORT.md` (this file)
- `docs/MVP_PLAN.md` / `docs/MVP_STATUS.md` updated

## Explicitly out of scope for D1

- `CallService` / `flutter_webrtc` client (D2)
- STUN/TURN credentials (D3)
- Call-peer crypto binding (D4)
- Call UI / Easy Mode (D5)
- Two-client WebRTC integration tests (D6)
- Calling CI matrix extras (D7)

## Verdict

**D1 complete for review.**  
Do **not** mark Milestone D complete. Stop before D2 until review.
