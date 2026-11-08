# Android Physical Acceptance — Rollup (through 19.7.30E)

Single index of physical-device evidence. Detail matrices: 30B messaging, 30C calling, 30D lifecycle, 30E gate.

**Devices (30E audit):**

| Role | Identity | App | Signing SHA-256 | Status |
| --- | --- | --- | --- | --- |
| A | SM-S938U `R5CXC2SA8HJ`, Android 17 | `1.0.0` / versionCode `1`, lastUpdate 2026-11-07 23:17:41 | `b694351d88992798ea347584901d77247591010cbcec4e77a2d115be4a803e85` (Android Debug) | Attached; **keyguard locked** during 30E window |
| B | Second handset | — | Unknown (do not assume match) | **Not attached** (ADB: only A + offline `emulator-5554`) |

**Git tip at 30E:** `ae4d2fb7f1d2db04cd4507cbc03d4bfd57b5aa1c` (matches `origin/master`).

**Policy:** Do not mark media Pass from SDP/ICE/UI alone. No uninstall/clear/logout on established installs. Remote tester sheet: `ANDROID_EXTERNAL_TESTER_30E.md`.

## Phase 0 — Installation safety (30E)

| Check | Result |
| --- | --- |
| Package | `com.privatemessenger.private_messenger` |
| ABI | `arm64-v8a` |
| New install attempted | **No** — Device B absent; A already on matching debug-signed build; keyguard blocked further UI |
| Backend / coturn changes | None |

## Messaging

| ID | Check | Env | Expected | Observed | Status | Evidence | Blocker |
| --- | --- | --- | --- | --- | --- | --- | --- |
| M-01 | Bidirectional encrypted send/receive | A+B validation | Content match both ways | Not run | **Pending** | Device B missing | RB-30B-001 |
| M-02 | Existing history after update | A | Readable history | Pass (30A/30B) | Pass (A) | Prior | — |
| M-03 | Order + dedup | A+B | No missing/dupes | Not run two-device | **Pending** | — | RB-30B-001 |
| M-04 | Offline/reconnect | A+B | Honest status + recover | Not run 30E | **Pending** | — | RB-30B-001 |
| M-05 | Safe failure presentation | — | Fail-closed labels | Pass (tests/UI) | Partial | 30B | — |
| M-06 | History after force-stop / bg-fg | A | Readable | Pass (30D) | Pass (A) | 30D | — |
| M-07 | Bg/reopen both apps after live exchange | A+B | History intact | Not run | **Pending** | Device B | RB-30B-001 |

## Audio calling

| ID | Direction | Expected | Observed | Status | Blocker |
| --- | --- | --- | --- | --- | --- |
| A-01 | A→B audible + auth | Two-way hear; mute/speaker; hangup cleanup | Not run | **Pending** | RB-30C-001 |
| A-02 | B→A same | Same | Not run | **Pending** | RB-30C-001 |
| A-03 | Consecutive successes (target 5/dir) | Stable setup | Not run | **Pending** | RB-30C-001 |
| A-04 | Hangup each side + mic cleanup | No stuck mic | Not run | **Pending** | RB-30C-001 |

Prior pre-UX two-device video does **not** close these rows.

## Video calling

| ID | Direction | Expected | Observed | Status | Blocker |
| --- | --- | --- | --- | --- | --- |
| V-01 | A→B video+audio | Live remote + audio; preview rules | Not run | **Pending** | RB-30C-002 |
| V-02 | B→A | Same | Not run | **Pending** | RB-30C-002 |
| V-03 | Cam off/on + flip | Works mid-call | Not run | **Pending** | RB-30C-002 |
| V-04 | Back confirm/cancel + post-hangup recall | Spec behavior | Not run | **Pending** | RB-30C-003 |

## Network / TURN

| ID | Check | Status | Blocker |
| --- | --- | --- | --- |
| N-01 | Independent Wi-Fi | **Pending** | RB-30D-001 |
| N-02 | Cellular / migration clean fail | **Pending** | RB-30C-005 |
| N-03 | Selected ICE pair type (relay only if selected) | **Pending** — no forced TURN change | RB-30C-004 |

## Lifecycle (carry-forward)

| ID | Check | Status |
| --- | --- | --- |
| L-01 | Bg/fg reopen chat (A) | Pass (30D) |
| L-02 | Force-stop cold start + session (A) | Pass (30D) |
| L-03 | Lock → unlock UI resume | **Incomplete** — 30E still on PIN keyguard; PIN not requested |
| L-04 | Network loss backgrounded | Not run |

## Accessibility smoke (physical)

| ID | Check | Status | Notes |
| --- | --- | --- | --- |
| X-01 | TalkBack critical path | **Incomplete** | Device locked entire 30E automation window |
| X-02 | Large font | Incomplete | Same |
| X-03–X-08 | OTP/tabs/status/safety/call/dialogs/errors | Incomplete / prior 29E code only | Do not claim physical pass |

No new inaccessible critical action filed — smoke did not execute.

## Security / data preservation (30E observation window)

| Check | Result |
| --- | --- |
| Unexpected sign-out | Not observed (app pid still present; UI behind keyguard) |
| Destructive logout / account switch tested | **Not performed** (forbidden on established) |
| MLS/history cross-store crash window | Remains **open** (RB-30B-002) |
| Premature call auth UI / stuck cam | Not exercised (no live calls) |

## Gate summary

| Gate | Result |
| --- | --- |
| One-device data preservation | Met (prior) |
| Two-device messaging | **Not met** |
| Two-device audio/video | **Not met** |
| Accessibility physical smoke | **Not met** |
| Narrow code fix required this milestone | **No** (blocked on devices/unlock, not a new defect) |
| RC readiness | **NOT READY** |
