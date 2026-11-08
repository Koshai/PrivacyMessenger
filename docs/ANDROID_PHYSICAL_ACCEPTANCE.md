# Android Physical Acceptance — Rollup (through 19.7.30D)

Single index of physical-device evidence. Detail matrices live in 30B/30C docs; this file tracks pass/fail/pending for RC gating.

**Devices:** A = SM-S938U (`R5CXC2SA8HJ`). B = second handset (**not attached** as of 30D).

**Policy:** Do not mark media rows Pass from SDP/ICE/UI alone. Do not clear/logout/uninstall established installs.

## Messaging

| ID | Check | A | B | Status |
| --- | --- | --- | --- | --- |
| M-01 | Bidirectional encrypted send/receive | — | — | **Pending** (Device B) |
| M-02 | Existing history after update | Pass (30A/30B) | Pending | Open until B |
| M-03 | Order + dedup under reconnect | Code/tests | Pending | Partial |
| M-04 | Offline/reconnect recovery | Partial (lifecycle) | Pending | Open |
| M-05 | Safe failure-state presentation | Pass (UI/tests) | Pending | Partial |
| M-06 | History after force-stop / bg-fg | Pass (30D) | — | One-device Pass |

Detail: `MESSAGING_RELIABILITY_MATRIX_30B.md`.

## Audio calling

| ID | Check | Status |
| --- | --- | --- |
| A-01 / A-02 | Bidirectional audible audio both directions | **Pending** (Device B) — RB-30C-001 |
| A-03 | Mute / speaker | Pending |
| A-04 | Hangup either side + cleanup | Pending |
| A-05 | Repeat calls after cleanup | Pending (auto cleanup exists) |

Prior two-device video success (pre-UX) is **historical** and does not close post-UX acceptance.

## Video calling

| ID | Check | Status |
| --- | --- | --- |
| V-01 / V-02 | Bidirectional visible video + audible audio | **Pending** — RB-30C-002 |
| V-03 | Local preview / cam off / switch | Pending (widget coverage) |
| V-04 | Back confirm / remote hangup cleanup | Pending |

Detail: `ANDROID_CALLING_ACCEPTANCE_30C.md` (C30-A\*, C30-V\*, C30-B\*).

## Network

| ID | Check | Status |
| --- | --- | --- |
| N-01 | Different Wi-Fi SSIDs | Pending |
| N-02 | Wi-Fi ↔ cellular mid-call | Pending / unsupported clean-end expectation — RB-30C-005 |
| N-03 | TURN relay selected pair (privacy-safe type only) | Pending — RB-30C-004 |

## Lifecycle (one-device, 30D)

| ID | Check | Status |
| --- | --- | --- |
| L-01 | Bg/fg reopen chat | Pass |
| L-02 | Force-stop cold start + session | Pass |
| L-03 | Lock → unlock UI resume | Incomplete (PIN keyguard) |
| L-04 | Network loss backgrounded | Not run |

Detail: `ANDROID_LIFECYCLE_30D.md`.

## Accessibility smoke (physical)

| ID | Check | Status |
| --- | --- | --- |
| X-01 | TalkBack critical path | **Incomplete** (device locked after lock test) |
| X-02 | Large font primary actions | Incomplete |
| X-03 | OTP / login | Not re-run (session preserved; do not logout) |
| X-04 | Chats / Friends / Settings | Prior 29E/30A; 30D re-smoke blocked by keyguard |
| X-05 | Message status / retry copy | Code + prior UX |
| X-06 | Safety-number screen | Prior 29E |
| X-07 | Call controls / dialogs | One-device affordances 30C; TalkBack pending |
| X-08 | Error / permission recovery | Emulator preferred for deny flows — pending |

Inaccessible critical action → treat as release **blocker**. None newly filed from 30D because smoke did not complete.

## Gate summary

| Gate | Result |
| --- | --- |
| One-device data preservation | Met |
| Two-device messaging | **Not met** |
| Two-device audio/video | **Not met** |
| Accessibility physical smoke | **Not met** |
| RC readiness | **NOT READY** (`ANDROID_RC_READINESS.md`) |
