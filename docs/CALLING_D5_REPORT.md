# D5 report — mobile calling lifecycle

**Date:** 2026-11-05  
**Milestone D remains open.** D6–D7 were not started.

## What shipped

In-app incoming, outgoing, audio, and video screens show duration, connection quality, identity warnings, and mute, speaker, camera, and hang-up controls. Permission denial offers an open-settings action. Remote video stays hidden until D4.1 verification.

Android, while the process is running:

- A call notification whose body is only `Incoming call` or `Call in progress`.
- A non-sticky microphone/camera foreground service for an ongoing call.
- Audio routing still uses the WebRTC audio session. Speaker toggle uses `Helper.setSpeakerphoneOn`. Bluetooth is allowed through the platform audio route (`BLUETOOTH_CONNECT` and the iOS `allowBluetooth` option). There is no separate Bluetooth stack.

iOS, while the process is running:

- CallKit reports a generic handle `call` with the same fixed labels. No phone number and no contact name.
- `AVAudioSession` uses play-and-record / voice chat and is deactivated when the call ends.
- Ending the call from the system UI tells Flutter to hang up.

PushKit is not implemented. Apple’s current VoIP policy requires the `voip` background mode, a VoIP push entitlement, and an immediate CallKit report for every push. That path needs a push credential and a device test, so it was not added. No paid calling provider is used.

## What was not demonstrated

| Situation | Result |
| --- | --- |
| App process terminated | Not supported. No push wake-up. |
| Screen locked, process suspended | Not tested on a device. No full-screen intent and no PushKit. |
| Physical Android or iPhone | Not run in this pass. |
| Emulator incoming-call notification | Not run in this pass. The notification text and lifecycle kinds are unit-tested. |
| macOS/iOS compile | Not run on this Windows host. GitHub Actions `ios-compile` is the compile check after the next push. |

Automated checks that did run are listed below. A push notification is only a hint: the app reconciles `GET /calls/active` and drops an ended, expired, or revoked call. One active call per user is unchanged.

## Checks on this Windows host

| Check | Result |
| --- | --- |
| `flutter analyze` | no issues |
| `flutter test` with `LIVE_E2E=1` | 134 passed, 0 failed, 0 skipped, including live OpenMLS, `call_auth_d41_test.dart`, and `call_ux_test.dart` |
| `go test ./...` with `DATABASE_URL` | passed. `TestRelayOnlyDataChannel` skipped because `TURN_RELAY_TEST` was unset |
| Android debug APK | compiled (`flutter build apk --debug`). The emulator was attached; notification, lock-screen, and process-death behavior were not exercised |
| Physical Android / iPhone | not run |
| iOS compile | not run here. It remains the GitHub Actions `ios-compile` job and has not been pushed for this change |
