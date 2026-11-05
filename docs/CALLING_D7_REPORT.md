# D7 report — final calling acceptance

**Date:** 2026-11-05  
**Milestone D remains open.** Milestone E was not started.

## Recommendation

Do not mark Milestone D complete. Automated tests and the loopback TURN job are required evidence, and they are not sufficient. Physical-device calling behavior and a production TURN deployment are still open release blockers.

Terminated-app incoming calls are an accepted MVP constraint. The app does not wake a killed process to show an incoming call, and it does not provide WhatsApp-style or Signal-style terminated-app delivery.

## What changed

Chat synchronization and call setup now share one MLS decryption pipeline. A call-key binding is decrypted once, checked against the envelope sender, and written to an AES-GCM inbox before the server is acknowledged. The inbox holds at most eight records for three minutes. Logout deletes it. Bindings are not rendered as chat. A restart after the inbox write acknowledges the envelope without decrypting it again.

Remote playback is enabled only for the call generation that finished authentication. A second or late authenticator cannot turn playback on after hang-up. Enrollment rechecks time out. A `false` result ends the call and releases media. A timeout or API error leaves the authenticated call up and retries.

`WebRtcCallService.disposeMedia` stops local tracks, closes the peer connection, and detaches and disposes renderers. The controller calls that path for hang-up, authentication failure, connection failure, revocation, logout, leaving the call screen, and controller disposal.

## Local results

| Check | Result |
| --- | --- |
| `flutter analyze` | No issues found |
| `flutter test` with `LIVE_E2E=1` | **153 passed, 0 failed, 0 skipped** |
| `go test ./...` with `DATABASE_URL` | All packages `ok`. `TestRelayOnlyDataChannel` **skipped** locally (`TURN_RELAY_TEST` unset) |
| Android emulator WebRTC smoke | **Passed**, 1 test, `sdk_gphone16k_x86_64` / Android 16. Calling UX checklist not run |
| Real OpenMLS binding race, duplicate, reorder, and restart | Passed in `call_d7_pipeline_test.dart` |
| Stale playback, API interruption, revocation, media release | Passed in `call_d7_lifecycle_test.dart` |
| Live two-client binding through the shared pipeline | Passed inside the 153 |

The CI `flutter` job skips the live test. The `live-e2e` job runs it. The `turn-relay` job is the loopback relay pass. A skip is not a pass.

## Devices

| Device | OS | What ran | Outcome |
| --- | --- | --- | --- |
| Android emulator `emulator-5554`, model `sdk_gphone16k_x86_64` | Android 16 | `integration_test/webrtc_android_smoke_test.dart`: create a peer connection and open the microphone. Notification, foreground service, permission denial, system hang-up, background, lock, audio focus, Bluetooth, and process-death behavior were not exercised. | Smoke **passed** (1 test). The checklist items above were not demonstrated. |
| Physical Android | — | No physical device was attached. | Open blocker |
| Physical iPhone | — | No iPhone and no local Xcode. Simulator compile stays on CI `ios-compile`. | Open blocker |

Locked-screen incoming calls were not demonstrated. PushKit is not implemented.

## Production TURN

No externally reachable coturn host was available. DNS, TLS, firewall relay ports, two clients on different networks, relay candidate selection on that host, packet exchange through it, and bandwidth or failure monitoring were not run. The shared secret was not placed on a public host. The loopback CI relay test remains the relay evidence and must stay green.

## Acceptance

Milestone D is not accepted as complete.
