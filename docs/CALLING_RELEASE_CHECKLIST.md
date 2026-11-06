# Calling release checklist

A row is passed only when that check ran and succeeded. Skipped and not-run rows stay open.

| Gate | State | Evidence |
| --- | --- | --- |
| Authentication, friendship, OpenMLS, WebRTC, and calling regressions | Passed locally: Flutter 153 with live OpenMLS, Go packages `ok` | This D7 pass |
| One MLS decrypt path for chat and call bindings | Passed | `call_d7_pipeline_test.dart`, live two-client ingest |
| Binding inbox encrypted, bounded, expired, cleared on logout | Passed | inbox test and logout wiring |
| No binding plaintext in the chat transcript | Passed | pipeline tests and live ingest |
| Restart recovers a stored binding without a second decrypt | Passed | crash/restart test |
| Playback cannot turn on after hang-up or a stale generation | Passed | `call_d7_lifecycle_test.dart` |
| Enrollment timeout and API errors are not revocation | Passed | lifecycle tests |
| Revocation ends the call and releases media | Passed | lifecycle test |
| Loopback TURN relay | CI job `turn-relay` must be green. Local run **skipped** without `TURN_RELAY_TEST` | GitHub Actions |
| CI `go`, `flutter`, `live-e2e`, `turn-relay`, `ios-compile`, `android-compile` | Required on the final commit | Actions run for that SHA |
| Android emulator WebRTC smoke | Passed: 1 test on `sdk_gphone16k_x86_64` / Android 16 | `webrtc_android_smoke_test.dart` |
| Android notification, foreground service, permission denial, system hang-up, background, lock, audio focus, speaker/Bluetooth, process cleanup | Not run | Open blocker |
| Physical Android | Not attached | Open blocker |
| iPhone CallKit, audio session, hang-up, permissions, background, lock, routing, media cleanup | Not run | Open blocker |
| Production TURN on an external host | Not run | Open blocker |
| Hosted API, PostgreSQL, HTTPS, and SMTP on OVHcloud | Files prepared. Not provisioned and not exercised | `docs/HOSTED_VALIDATION_RESULTS.md` |
| VPS-1 capacity under the validation workload | Not measured | `docs/HOSTED_RESOURCE_BUDGET.md` |
| Terminated-app incoming calls | Unsupported, accepted as an MVP constraint | `docs/CALLING_KNOWN_LIMITATIONS.md` |

Milestone D stays open while any open blocker remains. CI success does not close it.
