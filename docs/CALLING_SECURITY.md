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
| Cryptographic call-peer binding to MLS device identity | **D4** (not claimed) |
| TURN short-lived credentials | **D3** |

## What D2 adds

| Property | Status |
| --- | --- |
| Client media stack (`flutter_webrtc` 1.6.3 MIT) | Yes |
| Mic/camera only after explicit user action | Yes |
| Dispose tracks / renderers / PC on end | Yes |
| Injectable ICE servers (STUN now; TURN later) | Yes |
| Reliable background ringing | **No** (D5) |
| Production NAT traversal / TURN relay proof | **No** (D3) |

## Honest media-security statement

Chat uses OpenMLS for E2EE messaging. **Calling does not inherit MLS authentication automatically.**

Until D4 lands:

- Signaling is server-mediated and server-visible (SDP/ICE while the call is live).
- Media encryption (DTLS-SRTP) is provided by WebRTC once peers connect — that protects media in transit between peers / relays, **not** an MLS-style identity proof by itself.
- The server can observe call metadata: who called whom, when, duration, media type, and (while live) signaling payloads.
- `connected` is a **client assertion**. The API records it; it does not prove bidirectional media delivery.
- Relay (TURN) operators can see relayed packet metadata; relay-only mode (D3) reduces peer IP exposure at bandwidth cost.

Do **not** claim “MLS-authenticated calls” until an explicit reviewed binding between the WebRTC peer and the trusted device identity is implemented and tested (D4).

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
- Rate limit is **single-instance** (same limitation as crypto limiter).

## Background ringing

Reliable OS-level incoming-call UX when the app is killed is **not** claimed until demonstrated on Android/iOS (D5). D1/D2 deliver WS hints to connected/foreground clients plus HTTP reconcile.
