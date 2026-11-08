# Android Release-Candidate Readiness — Step 19.7.30E

## Decision

**NOT READY**

Device A accessibility smoke completed after unlock. Emulator Device B is now online with matching debug signing and a preserved session after `install -r`, but the two signed-in accounts are **not friends with each other**, so mandatory bidirectional messaging and real-media A/V still did not run. Outstanding security/data-preservation items stay open without two-device evidence.

Do not publish or distribute a new APK from this milestone.

## Decision rubric (applied)

| Criterion | Met? |
| --- | --- |
| One-device session/history survives update & process death | Yes (30A–30D) |
| Messaging outbox fail-closed + server idempotency | Yes (tests + local DB e2e) |
| Bidirectional encrypted messaging on two physical devices after UX batches | **No** — Device B absent (30E) |
| Bidirectional audio + video with real media evidence | **No** — Device B absent |
| TURN selected-pair / hard network transitions | **No** |
| Physical TalkBack / large-font critical-path smoke (Device A) | **Mostly yes** — retest after unlock; live call/safety-number still pending |
| Explicit review of logout/MLS wipe + cross-store crash window | Yes — remain open/disclosed (RB-30A-001, RB-30B-002) |
| Store-grade release signing + R8 validation | **No** (debug signing by design for validation) |
| Crash-reporting / support diagnostics policy | Deferred |

## Readiness classes (reference)

| Status | When to use |
| --- | --- |
| **NOT READY** | Missing required physical acceptance or unresolved external-beta blockers |
| READY FOR CONTROLLED EXTERNAL BETA REVIEW | Two-device messaging + A/V matrices pass with media evidence; limitations disclosed; distribution channel agreed |
| READY FOR PUBLIC RELEASE REVIEW | Store signing, R8, a11y, crash policy, and production ops review complete |

This milestone selects **NOT READY**.

## 30E environment snapshot

| Item | Value |
| --- | --- |
| Git | `ae4d2fb7f1d2db04cd4507cbc03d4bfd57b5aa1c` (= `origin/master`) |
| Device A | SM-S938U; app `1.0.0` (1); Android Debug cert `b694351d…803e85` |
| Device B | Not attached |
| Installs performed | None |
| Backend / coturn | Unchanged |
| Remote tester sheet | `ANDROID_EXTERNAL_TESTER_30E.md` |

## What remains before any “controlled beta review” status

1. Attach or remotely execute Device B checklist (`ANDROID_EXTERNAL_TESTER_30E.md`); fill messaging M-01+ and calling A/V rows with **real** content/media evidence.
2. On a live call, verify safety-number compare + TalkBack on Accept/Decline/Hang up (X-06/X-07 residual).
3. Keep RB-30A-001 / RB-30B-002 disclosed; do not pretend they are fixed.
4. Agree how external testers receive APKs without swapping signing identities on established devices.

## Related docs

- `ANDROID_PHYSICAL_ACCEPTANCE.md`
- `ANDROID_RELEASE_BLOCKERS.md`
- `ANDROID_EXTERNAL_TESTER_30E.md`
- `ANDROID_LIFECYCLE_30D.md`
- `ANDROID_CALLING_ACCEPTANCE_30C.md`
- `MESSAGING_RELIABILITY_MATRIX_30B.md`
