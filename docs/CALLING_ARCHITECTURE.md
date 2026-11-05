# Calling architecture (Milestone D)

## Scope

One-to-one audio/video calls. No groups, recording, livestreaming, or paid comms.

## Selected client stack (D2)

| Item | Choice |
| --- | --- |
| Package | [`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc) **1.6.3** (pinned) |
| License | **MIT** — see `mobile/docs/licenses/flutter_webrtc-1.6.3-NOTICE.md` |
| Maintenance | Active; Android/iOS/desktop/web |
| Client layers | `CallingApiClient` → `CallController` → `CallService` (`WebRtcCallService` / `FakeCallService`) |

Widgets never call WebRTC APIs directly.

## Signaling model

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
     |-- (ICE connected) ------->| POST .../connected      |
     |        WebRTC media (DTLS-SRTP) peer-to-peer / TURN |
```

- **Authoritative state:** PostgreSQL `call_sessions` (+ ephemeral `call_ice_candidates`).
- **Hints:** authenticated WebSocket hub (`realtime.Event.CallID`).
- **Clients always re-fetch** `GET /calls/{id}` or `GET /calls/active` after a hint / reconnect.

## Call state machine (D1.1)

```
ringing → accepted → connected → ended
   │          │           │
   ├─ decline / cancel / timeout / revoke ──→ ended
   └─ hangup (caller) ──────────────────────→ ended
```

| State | Meaning |
| --- | --- |
| `ringing` | Callee notified; awaiting accept/decline/cancel/timeout |
| `accepted` | Callee accepted; SDP/ICE negotiation in progress (answer may already be stored) |
| `connected` | **Client-reported** WebRTC connection indication (`POST .../connected`). Not server-verified media delivery |
| `ended` | Terminal; SDP/ICE cleared atomically with the end transition |

End reasons: `declined`, `cancelled`, `hangup`, `timeout`, `revoked`, `busy`, `failed`.

## HTTP API (authenticated)

| Method | Path | Role |
| --- | --- | --- |
| POST | `/calls` | Initiate (`media_type`, `callee_user_id`, `client_call_id`) |
| GET | `/calls/active` | Current non-ended call |
| GET | `/calls/{id}` | Fetch session |
| POST | `/calls/{id}/accept` | Callee accept (binds accepting device) |
| POST | `/calls/{id}/decline` | Callee decline |
| POST | `/calls/{id}/cancel` | Caller cancel while ringing |
| POST | `/calls/{id}/hangup` | Either party end |
| POST | `/calls/{id}/connected` | Client-reported media connected |
| PUT | `/calls/{id}/offer` | Caller SDP offer |
| PUT | `/calls/{id}/answer` | Callee SDP answer (does **not** alone imply `connected`) |
| POST | `/calls/{id}/ice` | Trickle ICE |
| GET | `/calls/{id}/ice?after=` | Poll ICE |

## Authorization & concurrency (D1.1)

- Accepted friendship required; blocks / non-friends → privacy-preserving not-available errors.
- Only participants may read/mutate a call.
- Single active call per user (transactional / advisory-lock busy).
- Accept binds callee device; conflicting device retries rejected.
- Initiate idempotent retries validated against callee, caller device, media type.
- Optimistic version checks on transitions.
- Logout / session revoke ends active calls (`EndRevoked`).

## Client media lifecycle (D2)

1. User action → permission request → `prepareOutgoing` / `prepareIncoming` (getUserMedia).
2. Create offer/answer; trickle ICE; poll peer ICE.
3. On ICE connected/completed → local UI `connected` + `POST .../connected`.
4. On hangup / fail / logout / reconcile-empty → dispose tracks, PC, renderers.

Camera is never activated before initiation or acceptance. Video `getUserMedia` failure falls back to audio-only when possible.

## Retention

SDP and ICE exist only while the call is non-terminal. On end they are deleted atomically with the session transition. Metadata (ids, media type, end reason, timestamps) may remain for missed-call UX.

## Call authentication (D4)

Dedicated Ed25519 call keys. Signed hello + confirm transcript binds call id, both users, both devices, media type, nonces, MLS fingerprints, and both DTLS fingerprints. Clients verify against pinned keys and the DTLS fingerprint on the peer connection. Protocol: `docs/CALL_AUTH_PROTOCOL.md`.

ICE connected is not authentication. Remote video is hidden until verification succeeds. Authentication failure ends the call.

## NAT / TURN (D3)

- `GET /calls/ice-config` (authenticated, rate-limited) returns STUN/TURN URLs and short-lived coturn REST credentials.
- Shared secret stays on the API (`TURN_SHARED_SECRET`). Clients never receive it.
- Username form is `<expiry-unix>:<user-id>`; credential is base64(HMAC-SHA1(secret, username)).
- Flutter `WebRtcCallService` loads a fresh config for every new peer connection.
- Direct mode uses the returned servers. Relay-only mode sets `iceTransportPolicy: relay` (`CALL_RELAY_ONLY` dart-define or `IceServerConfig.relayOnly`).
- Missing or invalid TURN configuration makes the endpoint return `503 TURN unavailable` with no secret material.
- Deployment: `docs/TURN_DEPLOYMENT.md`, example config `deploy/coturn/`.
- Relay connectivity is verified by a data-channel exchange over a nominated relay pair, not by SDP alone.
- Background ringing (D5) and MLS call binding (D4) are still out of scope.

## Module layout

- `backend/internal/calling` — domain, service, stores, Postgres integration tests
- `backend/internal/httpapi/calling_*.go` — HTTP + WS notify adapter
- Migrations `000008_calling`, `000009` (D1.1)
- `mobile/lib/features/calling/` — API, controller, WebRTC/fake services, screens
