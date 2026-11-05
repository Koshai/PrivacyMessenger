# D4.1 report — call-authentication corrections

**Date:** 2026-11-05  
**Milestone D remains open.** D5 follows this correction. D6 was not started.

## Corrections

1. Every hello is verified on the device. The signature must cover the expected call id, peer user, peer device, and role. Malformed nonces, unexpected keys, and replayed nonces are rejected. A hello that verifies for a different call is rejected even when its signature is valid for that other call.
2. The call public key is bound by `PrivacyMessenger/call-key-binding/v1`, signed by the call key and delivered as an MLS application message. A server-reported fingerprint is not the binding. Existing pins are not replaced. A new device id for a pinned user is an identity change. Revocation is fail-closed when the device is no longer enrolled. Safety-number verification stays a separate manual flag.
3. `authenticatePeer == null` no longer marks media authenticated. Production always installs an authenticator. Remote tracks stay disabled and the remote renderer is detached until verification succeeds.
4. Remote SDP updates emit the DTLS fingerprint. A change after verification, or a replaced peer connection, ends the call. An unchanged fingerprint (ICE restart with the same certificate) does not.

## Tests

`flutter test test/features/calling/call_auth_d41_test.dart`: 9 passed.

Covered: substituted hello, forged signature, replay, role mismatch, replacement key, malformed nonce, binding versus a different pinned fingerprint, device replacement, session-level substituted hello, successful binding, revoked enrollment, missing authenticator, DTLS change, same-fingerprint renegotiation, peer-connection replacement.

`flutter analyze` is run with the D5 suite and recorded in `docs/CALLING_D5_REPORT.md`.

## First contact

Without an established MLS conversation the binding channel returns nothing and the call fails closed. The earlier key-package claim is still the one-time trust of that messaging device. The signaling server cannot substitute a new call key afterward.
