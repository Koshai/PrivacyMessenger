# D6 report — calling reliability, security, and platform verification

**Date:** 2026-11-05  
**Milestone D remains open.** D7 was not started.

## Security corrections

`persistMessagingDevicePin` no longer overwrites a different fingerprint and no longer hides storage errors. A conflict raises `IdentityPinConflict`. A non-64-character stored value is treated as corrupt and left untouched. The messaging service waits for that write and keeps the previous in-memory fingerprint when the pin conflicts.

`CallAuthSession` fails closed when `deviceStillEnrolled` is missing, when the peer device is absent, or when the stored messaging pin is corrupt. `CallController` rechecks enrollment on resume and on the one-second poll while the call is authenticated, and hangs up if the check fails. Logout deletes the local call-signing seed through `clearLocalCallSecret` and leaves contact pins in place. Device replacement does not delete or replace those pins.

The binding content type `application/call-key-binding` is now an allowed envelope type. The server still does not read the plaintext. The live two-client test sends Alice's signed binding through the real API and OpenMLS conversation; Bob decrypts it and verifies account, device, and call public key. A wrong device and a substituted ciphertext fail.

## Local checks

| Check | Result |
| --- | --- |
| `flutter analyze` | No issues found |
| `flutter test` with `LIVE_E2E=1`, API at `http://127.0.0.1:4010`, and `DATABASE_URL` | **144 passed, 0 failed, 0 skipped** |
| `go test ./...` with `DATABASE_URL` | All packages `ok`. `TestRelayOnlyDataChannel` **skipped** (`TURN_RELAY_TEST` unset). |
| `flutter build apk --debug` | Built `mobile/build/app/outputs/flutter-apk/app-debug.apk` |
| Emulator `emulator-5554` | Attached. D6 notification, lock-screen, audio-focus, Bluetooth, and process-death checks were not run on it. |
| Physical Android / iPhone | Not attached. |

CI distinguishes the skipped relay test: job `turn-relay` sets `TURN_RELAY_TEST=1` with loopback coturn. Job `flutter` does not set `LIVE_E2E`, so the live OpenMLS test is skipped there and job `live-e2e` runs it. Job `android-compile` builds the debug APK. Job `ios-compile` builds the iOS simulator binary and native tests. A green job is a pass only for the tests that job executed.

## Known limitations

- Terminated-process incoming calls are unsupported.
- Locked-screen incoming-call behavior was not demonstrated.
- Wi-Fi to cellular handoff was not simulated.
- PushKit is not implemented.
- Contact pins are global per device id. Logout on a shared device does not erase another account's pins.
- Physical iPhone verification is a D7 release dependency.

## D7 release blockers

- Physical Android coverage for notification, permission denial, foreground service, system hang-up, background, lock, audio focus, Bluetooth/speaker, and process cleanup.
- Physical iPhone coverage for CallKit, system hang-up, `AVAudioSession`, routing, permissions, background, lock screen, and media cleanup.
- A decision on whether terminated-app wake-up is in scope. It is unsupported today.
- Production TURN deployment beyond the CI loopback relay.
