# Milestone D4 report — cryptographic call authentication

**Date:** 2026-11-05  
**Scope:** Bind one-to-one WebRTC calls to device identity without replacing DTLS-SRTP.  
**Milestone D remains open.** D5 was not started.

## Design

OpenMLS 3.3.0 cannot safely sign arbitrary call transcripts (no domain-separated sign API). D4 uses a dedicated Ed25519 call key, registered once per device and pinned locally beside the MLS fingerprint. See `docs/CALL_AUTH_PROTOCOL.md`.

A malicious signaling server can substitute SDP, but it cannot forge the pinned key's signature over the DTLS fingerprint both peers observed. Authentication failure ends the call. ICE connectivity alone is not shown as verified. Remote video stays hidden until verification. Early DTLS packets can exist before that point and are not treated as authenticated media.

Manual safety-number trust stays separate from "authenticated device".

## Checks (this machine, 2026-11-05)

| Check | Result |
| --- | --- |
| `go test ./...` with `DATABASE_URL` set and `TURN_RELAY_TEST` unset | pass, including `internal/callauth` PostgreSQL hello/purge and the security cases (forgery, replay, role swap, call id, DTLS mismatch, device replacement, revocation, duplicates, concurrent confirms) |
| `TestRealWebRTCFingerprintBinding` | pass. Two pion peers, real SDP fingerprints, tampered callee fingerprint fails closed |
| `TestRelayOnlyDataChannel` | skipped in the green local `go test ./...` because `TURN_RELAY_TEST` was unset. The GitHub `turn-relay` job must listen and relay on `127.0.0.1` and allow loopback peers; coturn otherwise allocates on a private runner address and refuses the hairpin. The test still requires a nominated relay/relay pair and a data-channel payload |
| `flutter analyze` | no issues |
| `flutter test` with `LIVE_E2E=1` | 122 passed, 0 failed, 0 skipped, including live OpenMLS Alice/Bob and `call_auth_test.dart` |
| Android WebRTC smoke | not re-run on this pass (no new media-stack change). Previous D3 run on emulator-5554 passed after `RECORD_AUDIO` was granted |
| macOS/iOS compile and native tests | not run on this Windows host. GitHub Actions `ios-compile` is the check after push |

## Not claimed

MLS-authenticated media, custom SRTP, background ringing, or a closed Milestone D.
