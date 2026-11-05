# PrivacyMessenger MVP Status

**Updated:** 2026-11-04  
**Repository:** https://github.com/Koshai/PrivacyMessenger  
**Remote `origin/master`:** C complete; D1.1 + D2 local for review (see `docs/CALLING_D2_REPORT.md`)

## Milestone progress

| Milestone | Status |
| --- | --- |
| A — Auth | Complete |
| B — Friends | Complete |
| C — E2EE | **Complete (C4)** |
| D — Calls | **D1.1 + D2 complete for review** — D3–D7 not started; Milestone D **not** complete |
| E — Release | Not started |

## D1.1 / D2 gates (local)

| Gate | Result |
| --- | --- |
| `go test ./...` | Pass |
| Calling Postgres integration (simultaneous initiate, lifecycle, privacy) | Pass |
| Calling HTTP handler tests | Pass |
| `flutter analyze` | Pass (no issues) |
| `flutter test test/features/calling` | Pass |
| `flutter test` (excl. live API fixture drift) | Unit/widget pass; live OpenMLS e2e may fail if seeded identities revoked |
| `flutter build apk --debug` | Pass |
| Android emulator native WebRTC smoke | **Pass** (`webrtc_android_smoke_test` on `emulator-5554`) |
| iOS full build | **Skipped** (no Xcode on Windows host); Info.plist mic/camera keys added |
| Production TURN / background ringing | Not claimed |

## Next

Review D1.1 + D2 → then **D3 TURN**. Do not mark Milestone D complete until D6/D7 gates pass.
