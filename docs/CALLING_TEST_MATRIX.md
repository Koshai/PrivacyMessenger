# Calling test matrix (D6)

Passed means the check ran and succeeded. Skipped means the check was not executed. A skip is not a pass.

## Lifecycle

| Step | Audio | Video | Where |
| --- | --- | --- | --- |
| Alice initiates | Passed | Passed | `call_d6_reliability_test.dart` with `FakeCallService` |
| Bob sees incoming | Passed | Passed | same |
| Bob accepts | Passed | Passed | same |
| Both reach a connected media event | Passed | Passed | fake connection event, not a device radio |
| Cryptographic authentication completes | Passed | Passed | injected authenticator in that test; real hello/binding in `call_auth_d41_test.dart` and the live OpenMLS test |
| Remote media stays off until verification | Passed | Passed | playback flag |
| Mute, speaker, camera | Passed | Passed | controller toggles the fake service |
| Either side ends | Passed | Passed | Bob hang-up; Alice follows the ended hint |
| Signaling payload cleared on end | Passed | Passed | offer and answer cleared when the mock hang-up runs. Server deletion is the existing calling purge test |
| Both sides release media | Passed | Passed | `disposeMedia` |

A second outgoing attempt while one call is up is refused. A repeated answer is applied once.

## Network and TURN

| Case | Result |
| --- | --- |
| Direct connection | Covered by the client ICE path and the earlier pion direct tests. This pass did not place two handsets on a LAN. |
| TURN-only relay | `TestRelayOnlyDataChannel` skips locally unless `TURN_RELAY_TEST=1` and coturn is up. CI job `turn-relay` runs it and must be read as its own result. |
| Failed TURN allocation | ICE config `503` is mapped to an API error (`ice_config_test.dart`). |
| Expired TURN credentials | `IceServerConfig.isExpired` is unit-tested. |
| Wi-Fi to mobile transition | Not simulated on this host. |
| Temporary connectivity loss and reconnect before timeout | Passed in `call_controller_test.dart` (short disconnect keeps the call; a longer one hangs up). |
| Duplicate or delayed signaling | Passed: duplicate answer ignored; answer applied when the later hint arrives. |
| Simultaneous calls | Passed: the second `startOutgoing` returns without replacing the first. |
| Authentication timeout | Passed: remote playback stays off and media is disposed. |
| DTLS fingerprint change | Passed in `call_auth_d41_test.dart`. The same fingerprint does not end the call. |
| Failed call leaves no active session or media | Passed for the client hang-up path and the Go end/purge tests. |

## Android

| Check | Result |
| --- | --- |
| Debug APK compile | Local `flutter build apk --debug` and CI job `android-compile`. |
| Emulator `emulator-5554` attached | Yes, during this pass. |
| WebRTC `getUserMedia` smoke on that emulator | Passed in an earlier D2/D3 run after `RECORD_AUDIO` was granted. Not re-run for D6. |
| Foreground incoming call, notification show/dismiss, foreground-service lifecycle | Unit-tested kinds and fixed notification strings. Not exercised on the emulator in this pass. |
| Notification, microphone, or camera permission denied | Microphone/camera denial is a controller test. Notification denial was not exercised on a device. |
| System hang-up, background, lock/unlock, audio focus, Bluetooth, speaker routing, process death | Not exercised on a device in this pass. |
| Terminated-process incoming calls | Unsupported. Documented, not claimed. |
| Physical Android | No physical device attached. |

## iOS

| Check | Result |
| --- | --- |
| macOS simulator compile and native OpenMLS tests | CI job `ios-compile`. This Windows host cannot run Xcode. |
| Physical iPhone: CallKit, system hang-up, AVAudioSession, speaker/Bluetooth, permissions, background, lock screen, media cleanup | Not run. Release dependency for D7. |
| PushKit, terminated-app wake-up, reliable background incoming delivery | Not implemented and not claimed. |
