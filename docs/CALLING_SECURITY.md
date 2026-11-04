# Calling security model

## What D1 provides

| Property | Status |
| --- | --- |
| Authenticated signaling (session bearer) | Yes |
| Friendship + block checks before ring | Yes |
| Participant-only access to call resources | Yes |
| Idempotent initiate/accept/ICE client ids | Yes |
| Reject conflicting SDP replay | Yes |
| Bounded SDP/ICE sizes + rate limits | Yes (60/min/user in-process) |
| Clear SDP/ICE on call end | Yes |
| End calls on logout/session revoke | Yes |
| WebRTC DTLS-SRTP media encryption | **Client/D2+** (transport mandatory when media exists) |
| Cryptographic call-peer binding to MLS device identity | **D4** (not claimed in D1) |
| TURN short-lived credentials | **D3** |

## Honest media-security statement

Chat uses OpenMLS for E2EE messaging. **Calling does not inherit MLS authentication automatically.**

Until D4 lands:

- Signaling is server-mediated and server-visible (SDP/ICE while the call is live).
- Media encryption (DTLS-SRTP) is provided by WebRTC once peers connect — that protects media in transit between peers / relays, **not** an MLS-style identity proof by itself.
- The server can observe call metadata: who called whom, when, duration, media type, and (while live) signaling payloads.
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
- Blocked / non-friend callers → rejected.
- Busy / simultaneous active calls → rejected.
- Oversized SDP/ICE → 413.
- Rate limit is **single-instance** (same limitation as crypto limiter).

## Background ringing

Reliable OS-level incoming-call UX when the app is killed is **not** claimed until demonstrated on Android/iOS (D5). D1 only delivers WS hints to connected clients plus HTTP state.
