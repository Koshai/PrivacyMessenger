# Calling security model

## What D1 / D1.1 provide

| Property | Status |
| --- | --- |
| Authenticated signaling (session bearer) | Yes |
| Friendship + block checks before ring | Yes |
| Privacy-preserving errors for blocked / non-friend | Yes (D1.1) |
| Participant-only access to call resources | Yes |
| Idempotent initiate/accept/ICE client ids | Yes |
| Initiate retry validates callee / device / media | Yes (D1.1) |
| Accept binds callee device | Yes (D1.1) |
| Reject conflicting SDP replay | Yes |
| Bounded SDP/ICE sizes + rate limits | Yes (60/min/user in-process) |
| Concurrency-safe one-active-call + ICE limits | Yes (D1.1) |
| Atomic clear SDP/ICE on call end | Yes (D1.1) |
| Versioned / optimistic call transitions | Yes (D1.1) |
| End calls on logout/session revoke | Yes |
| `connected` only after client-reported WebRTC indication | Yes (D1.1) — **not** server-verified media |
| WebRTC DTLS-SRTP media encryption | **D2+** (transport when peers connect) |
| Dedicated Ed25519 call key, MLS-encrypted binding statement | **D4.1** — not an MLS signature over media |
| Remote media hidden until local verification | **D4.1** |
| In-process call notification without signaling contents | **D5** — not terminated-app ringing |
| TURN short-lived REST credentials | **D3** — secret server-side only |

## What D2 adds

| Property | Status |
| --- | --- |
| Client media stack (`flutter_webrtc` 1.6.3 MIT) | Yes |
| Mic/camera only after explicit user action | Yes |
| Dispose tracks / renderers / PC on end | Yes |
| Injectable ICE servers (STUN + short-lived TURN) | Yes (D3) |
| Relay-only ICE policy | Yes (D3) |
| Reliable background ringing while the process is alive | **Partial (D5)** — notification and CallKit while the app process is running |
| Terminated-app or locked-screen incoming calls | **Not claimed** |
| TURN relay path exercised (local coturn + pion) | Yes (D3). Production NAT still depends on a correctly deployed coturn |

## Honest media-security statement

Chat uses OpenMLS for E2EE messaging. Calling uses a separate Ed25519 call key. That key is bound to the device by a statement encrypted in the existing MLS conversation. WebRTC DTLS-SRTP still encrypts the media. The server is not the authority for the peer's call key.

- Clients verify hello signatures, call id, user, device, role, and the MLS binding locally.
- A missing authenticator fails closed. ICE connectivity is not shown as authenticated.
- Remote playback stays off until verification. Early DTLS packets can still exist.
- A DTLS fingerprint change or a new peer connection ends the call.
- First contact still depends on the earlier messaging key-package trust. The signaling server cannot refresh that trust during the call.
- `connected` remains a client assertion. It does not prove identity.

## Server metadata exposure

Retained after call end (operational / UX):

- Caller/callee user ids, device ids (callee device once accepted)
- Media type, state/end reason, timestamps

Not retained after end:

- SDP offer/answer
- ICE candidates (may embed reflexive/relay addresses)

## Threat notes

- Forged signaling from non-participants → rejected (`ErrNotAuthorized`).
- Blocked / non-friend callers → privacy-preserving not-available.
- Busy / simultaneous active calls → rejected under transactional control.
- Oversized SDP/ICE → 413.
- Stale concurrent updates → rejected via version checks.
- Rate limit is **single-instance** (same limitation as crypto limiter), including TURN credential issuance (30/minute/user).
- Coturn shared secret must not be committed, logged, or returned by `/calls/ice-config`.
- TURN operators can observe relayed packet metadata. Relay-only mode hides peer reflexive addresses from the other client at bandwidth cost.

## Background ringing

Reliable incoming-call UX when the process is already running uses a content-free notification on Android and CallKit on iOS. PushKit is not implemented. Apple requires a VoIP push entitlement and immediate CallKit reporting, and that path was not tested on a device. A killed process does not receive calls. Notifications are hints: the app loads authoritative call state after activation and drops expired, revoked, or duplicate calls. Notification bodies are `Incoming call` or `Call in progress` and do not contain tokens, SDP, ICE, or keys.
