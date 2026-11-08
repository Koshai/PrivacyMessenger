# Android Release-Candidate Readiness — Step 19.7.30E (retest)

## Decision

**NOT READY**

Bidirectional encrypted messaging between Device A (`syed.r.akbar@gmail.com` / SM-S938U) and Device B (`neloythedev@gmail.com` / emulator) **passed** with matching plaintext tokens and honest Sent/Received labels.

Audio **signaling** for A→B (ring → accept → hangup cleanup) passed. **Actual two-way audible audio**, reverse-direction calls, video, consecutive stability, and TURN/network matrices are still incomplete. Do not publish an APK from this milestone.

## Decision rubric (applied)

| Criterion | Met? |
| --- | --- |
| Bidirectional encrypted messaging on two devices after UX batches | **Yes** (30E retest) |
| Bidirectional **audible** audio with media evidence | **No** (signaling only) |
| Bidirectional video with visible+audible media | **No** |
| TURN selected-pair / hard network transitions | **No** |
| Device A a11y smoke (TalkBack / large font) | Mostly yes (prior retest) |
| Logout/MLS wipe + cross-store crash window reviewed | Yes — remain disclosed (RB-30A-001, RB-30B-002) |
| Store-grade signing + R8 | **No** |

## What changed this retest

- Emulator cold-booted; both devices on matching debug-signed validation APKs via `adb install -r`
- Named accounts friended and exercised
- Narrow fix: do not clear composer when `send()` is ignored; snackbar + scroll-after-queue

## Still required before controlled external beta review

1. Prove **audible** two-way audio both directions (multiple consecutive successes)
2. Prove **visible+audible** video both directions with cam controls / Back confirm
3. Optional but preferred: Wi-Fi diversity / privacy-safe ICE selected type
4. Keep RB-30A-001 / RB-30B-002 disclosed

## Related docs

- `ANDROID_PHYSICAL_ACCEPTANCE.md`
- `ANDROID_RELEASE_BLOCKERS.md`
- `ANDROID_EXTERNAL_TESTER_30E.md`
