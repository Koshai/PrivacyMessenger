# Android Release-Candidate Readiness — Step 19.7.30D

## Decision

**NOT READY**

Required physical two-device acceptance evidence is missing. Accessibility smoke after lock is incomplete. Do not publish or distribute a new APK from this milestone.

## Decision rubric (applied)

| Criterion | Met? |
| --- | --- |
| One-device session/history survives update & process death | Yes (30A–30D) |
| Messaging outbox fail-closed + server idempotency | Yes (tests + local DB e2e) |
| Bidirectional encrypted messaging on two physical devices after UX batches | **No** — Device B absent |
| Bidirectional audio + video with real media evidence | **No** — Device B absent |
| TURN selected-pair / hard network transitions | **No** |
| Physical TalkBack / large-font critical-path smoke (30D) | **Incomplete** (secure keyguard) |
| Store-grade release signing + R8 validation | **No** (debug signing by design for validation) |
| Crash-reporting / support diagnostics policy | Deferred (no third-party SDK) |

## Readiness classes (reference)

| Status | When to use |
| --- | --- |
| **NOT READY** | Missing required physical acceptance or security/data-loss blockers for any external exposure |
| READY FOR CONTROLLED EXTERNAL BETA | Two-device messaging + A/V matrices pass; known limitations documented; signed validation channel agreed |
| READY FOR PUBLIC RELEASE REVIEW | Store signing, R8, a11y, crash policy, and production ops review complete |

This milestone selects **NOT READY** only.

## What is solid enough for *internal* engineering use

- Debug-signed validation APKs on known devices with preserved MLS/history
- Automated Flutter (319) + Go internal short + DB-backed envelope idempotency
- Lifecycle smoke on SM-S938U (force-stop, bg/fg, reopen chat)
- Calling lifecycle code/tests (30C); one-device affordance checks

Internal engineering ≠ controlled external beta.

## Blocking evidence still required

1. Attach Device B; run `ANDROID_PHYSICAL_ACCEPTANCE.md` messaging + audio + video rows with **real media** evidence.
2. Complete TalkBack / large-font smoke on unlocked SM-S938U (and preferably Device B).
3. Close or explicitly defer RB-30B-001 / RB-30C-001 / RB-30C-002 with evidence.
4. Agree signing/versionCode policy before any wider distribution.

## Inspect-only release artifact (not distributed)

| Item | Value |
| --- | --- |
| Built | `mobile/build/app/outputs/flutter-apk/app-release.apk` (~117.2 MB) |
| SHA-256 | `7866DE3EA147B02DB540F35A3C4B1649A3962BF2B5ADF0E2279E1F941638EF1D` |
| Signing | Android Debug (same SHA-256 as installed validation identity) |
| Installed on SM-S938U? | **No** |

## Related docs

- `ANDROID_LIFECYCLE_30D.md`
- `ANDROID_RELEASE_BLOCKERS.md`
- `ANDROID_PHYSICAL_ACCEPTANCE.md`
- `MESSAGING_RELIABILITY_MATRIX_30B.md`
- `ANDROID_CALLING_ACCEPTANCE_30C.md`
