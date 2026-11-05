# Call authentication protocol (D4)

## Decision

OpenMLS 3.3.0 (`MlsSignatureKeyPair`) can generate and serialize the MLS Ed25519 identity key, but it does not expose a domain-separated `sign` / `verify` for arbitrary bytes. Using that private key as a call-signing oracle would reuse an MLS credential key outside MLS, where MLS signatures are not domain-separated from other protocols. That is not safe.

D4 therefore uses a **dedicated Ed25519 call-authentication key** stored only on the device. The public key is registered once per device (`device_call_auth_keys`) and pinned in local secure storage next to the MLS identity fingerprint. A later change of either value is an identity change. It is not accepted automatically. Manual safety-number verification stays a separate user action: cryptographic authentication of the device is not the same as a human comparing safety numbers.

Matching user IDs, device IDs, or a fingerprint returned by the signaling server during the call is not verification. Verification uses the pinned call public key and the DTLS fingerprint observed on the peer connection.

## Threat model

An active signaling server can:

- See who is calling, media type, SDP, ICE, and the public handshake frames while the call exists.
- Drop, delay, or reorder handshake frames.
- Substitute its own SDP and DTLS certificate and attempt to relay media.

It cannot:

- Obtain either device's call-signing private key or MLS private key.
- Produce a valid confirm signature for the honest peer's pinned call key.
- Make both peers agree on a substituted DTLS fingerprint: each peer signs the fingerprint it observes, and each peer requires the peer's signed fingerprint to equal the remote SDP fingerprint WebRTC checked against the DTLS certificate.
- Replay a confirm from another `call_id`, role assignment, or fingerprint. Those bytes are inside the signed transcript.
- Keep a revoked MLS identity in the handshake. The API rejects revoked devices. Clients still verify signatures themselves. The server is not the sole authority for peer identity.

## Transcript

Version 1. Fixed field order, raw bytes, no JSON canonicalization.

Hello domain: `PrivacyMessenger/call-hello/v1\n`  
Confirm domain: `PrivacyMessenger/call-auth/v1\n`

Hello binds `call_id`, user, device, role (`1` caller, `2` callee), 32-byte nonce, 32-byte call public key, 32-byte MLS fingerprint.

Confirm (signed by both parties over the same bytes) binds protocol version, call id, both account ids, both device ids, media type, both nonces, both DTLS SHA-256 fingerprints, both MLS fingerprints, and both call public keys.

Signatures are Ed25519 over those bytes.

## Exchange

1. Each device registers its call public key once. A different key for the same device is rejected.
2. After accept, each device sends a signed hello.
3. After the peer connection has local and remote descriptions, each device signs the confirm using its local DTLS fingerprint and the remote fingerprint from the SDP WebRTC is using.
4. Each device checks the peer signature under the **pinned** call key (or pins it on first success) and checks the signed self-fingerprint equals the observed remote DTLS fingerprint.
5. ICE `connected` does not mark the call authenticated. Remote video stays hidden until this check passes. DTLS may already have carried early packets; those are not presented as an authenticated call.
6. Failure, identity change, timeout, or a DTLS fingerprint change after verification ends the call and releases media.

## Renegotiation and ICE restart

ICE restart that keeps the same DTLS certificates does not change the signed fingerprints and does not require a new signature. A new DTLS certificate (offer/answer renegotiation that changes `a=fingerprint`) invalidates the transcript. D4 fails closed instead of silently re-authenticating.

## Server

`POST /calls/auth-key`, `POST /calls/{id}/auth`, `GET /calls/{id}/auth`.

The API checks membership, the accepting device binding, revocation, signature shape against the registered key, idempotency, and a 90s window. Frames are deleted when the call ends. Private keys are never sent.
