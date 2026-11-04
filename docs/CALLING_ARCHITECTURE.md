# Calling architecture (Milestone D)

## Scope

One-to-one audio/video calls. No groups, recording, livestreaming, or paid comms.

## Selected client stack (verified for D2+)

| Item | Choice |
| --- | --- |
| Package | [`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc) **1.6.3** |
| License | **MIT** (compatible with proprietary PrivacyMessenger) |
| Maintenance | Active (1.6.3 published 2026-10-26; Android/iOS/desktop/web) |
| Native deps | Google WebRTC SDK via flutter-webrtc; platform permission plugins required in D2 |

D1 does **not** add the Flutter dependency yet — only documents the selection. D2 wires `CallService` + `flutter_webrtc`.

## Signaling model (D1)

```
Flutter clients                Go API                     Peer
     |                           |                         |
     |-- POST /calls ----------->|                         |
     |                           |-- WS call.ringing ----->|
     |<----- WS call.ringing ----|                         |
     |-- POST .../accept ------->|                         |
     |                           |-- WS call.accepted ---->|
     |-- PUT  .../offer -------->|                         |
     |                           |-- WS call.offer ------->|
     |                           |<---- PUT .../answer ----|
     |<----- WS call.answer -----|                         |
     |-- POST .../ice ---------->|<------- POST .../ice ---|
     |        WebRTC media (DTLS-SRTP) peer-to-peer / TURN |
```

- **Authoritative state:** PostgreSQL `call_sessions` (+ ephemeral `call_ice_candidates`).
- **Hints:** existing authenticated WebSocket hub (`realtime.Event.CallID`).
- **Clients always re-fetch** `GET /calls/{id}` after a hint (same pattern as envelopes).

## Call state machine

```
ringing → accepted → connected → ended
   │          │           │
   ├─ decline / cancel / timeout / revoke ──→ ended
   └─ hangup (caller) ──────────────────────→ ended
```

| State | Meaning |
| --- | --- |
| `ringing` | Callee notified; awaiting accept/decline/cancel/timeout |
| `accepted` | Callee accepted; SDP/ICE negotiation |
| `connected` | Answer SDP stored; media expected on clients |
| `ended` | Terminal; SDP/ICE cleared immediately |

End reasons: `declined`, `cancelled`, `hangup`, `timeout`, `revoked`, `busy`, `failed`.

## HTTP API (authenticated)

| Method | Path | Role |
| --- | --- | --- |
| POST | `/calls` | Initiate (`media_type`, `callee_user_id`, `client_call_id`) |
| GET | `/calls/active` | Current non-ended call |
| GET | `/calls/{id}` | Fetch session |
| POST | `/calls/{id}/accept` | Callee accept |
| POST | `/calls/{id}/decline` | Callee decline |
| POST | `/calls/{id}/cancel` | Caller cancel while ringing |
| POST | `/calls/{id}/hangup` | Either party end |
| PUT | `/calls/{id}/offer` | Caller SDP offer |
| PUT | `/calls/{id}/answer` | Callee SDP answer |
| POST | `/calls/{id}/ice` | Trickle ICE |
| GET | `/calls/{id}/ice?after=` | Poll ICE |

## Authorization

- Accepted friendship required.
- Either-direction `user_blocks` rejects initiate.
- Only participants may read/mutate a call.
- Single active call per user (busy otherwise).
- Logout / session revoke ends active calls (`EndRevoked`).

## Retention

SDP and ICE exist only while the call is non-terminal. On end they are deleted. Metadata (ids, media type, end reason, timestamps) may remain for missed-call UX.

## NAT / TURN (D3 — not implemented in D1)

Short-lived TURN credentials via coturn; no permanent secrets in the app. Documented later in D3.

## Module layout

- `backend/internal/calling` — domain, service, stores
- `backend/internal/httpapi/calling_*.go` — HTTP + WS notify adapter
- Migration `000008_calling`
