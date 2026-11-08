# Android Physical Acceptance — Rollup (through 19.7.30E retest)

**Accounts used for A↔B:** Device A = `syed.r.akbar@gmail.com` (SM-S938U); Device B = `neloythedev@gmail.com` (Pixel_8_API_36 emulator).

| Role | Identity | App | Signing SHA-256 | Status |
| --- | --- | --- | --- | --- |
| A | SM-S938U `R5CXC2SA8HJ`, Android 17 | `1.0.0` / `1` | `b694351d…803e85` | Unlocked; `install -r` with send-fix APK; session retained |
| B | `emulator-5554` Pixel_8_API_36, Android 16 | `1.0.0` / `1` | Same debug cert | Cold boot; `install -r`; session retained |

**Policy:** Do not mark media Pass from SDP/ICE/UI alone. No logout/clear on established installs.

## Phase 0 — Install safety

| Check | Result |
| --- | --- |
| Cert match A↔B | Yes |
| Non-destructive `-r` | Yes (both) |
| Friendship | Confirmed: A lists neloy; B lists syed; shared encrypted history |

## Messaging

| ID | Check | Expected | Observed | Status | Evidence | Blocker |
| --- | --- | --- | --- | --- | --- | --- |
| M-01 | Bidirectional encrypted send/receive | Content match both ways | **Pass** | Pass | A→B: `ab004518`, `AtoB005247`, `zztest1` Sent on A / Received on B. B→A: `ba004553`, `visiblecheck`, `BtoA004025` Sent on B / Received on A | RB-30B-001 **closed** |
| M-02 | Existing history after update | Readable | Pass | Pass | Prior + post-`-r` history on both | — |
| M-03 | Order + dedup | No missing/dupes in sampled tokens | Pass (sampled) | Pass | Distinct tokens appear once per side in dumps | — |
| M-04 | Offline/reconnect | Honest status | Partial | Partial | Prior banner paths; not re-faulted this run | — |
| M-05 | Safe failure presentation | Fail-closed labels | Pass | Pass | Sent-to-server wording present | — |
| M-06 | History after force-stop / bg-fg | Readable | Pass | Pass | 30D + this run bg/fg still signed in | — |
| M-07 | Bg/reopen after live exchange | History intact | Pass | Pass | After Home→resume, both remain signed in; history retained | — |

## Audio calling

| ID | Direction | Expected | Observed | Status | Blocker |
| --- | --- | --- | --- | --- | --- |
| A-01 | A→B | Ring; accept; **audible** two-way; hangup cleanup | Signaling **Pass**: A `Calling…`; B `Incoming call` / Accept / Decline; after Accept both `Hang up`; after A hangup both clear, A `Send` restored. **Audible media not instrumented** | **Partial** | RB-30C-001 open for real audio |
| A-02 | B→A | Same reverse | Not run this session | Pending | RB-30C-001 |
| A-03 | Consecutive ×5 | Stable | Not run | Pending | RB-30C-001 |
| A-04 | Hangup cleanup | No stuck UI | Pass (one A→B cycle) | Pass (UI) | — |

## Video calling

| ID | Status | Blocker |
| --- | --- | --- |
| V-01 / V-02 | **Pending** (not executed) | RB-30C-002 |
| V-03 / V-04 | Pending | RB-30C-002 / RB-30C-003 |

## Network / TURN

| ID | Status | Blocker |
| --- | --- | --- |
| N-01–N-03 | Pending | RB-30C-004 / RB-30C-005 |

## Accessibility (carry-forward)

Device A TalkBack + 1.5× font smoke previously passed (retest after unlock). Live-call a11y still partial.

## Narrow code fix applied during retest

Outgoing send no longer clears the composer when `send()` is ignored (missing token/cid/userId/blank). Snackbar shown; scroll-to-end after queue. See conversation_controller/screen.

## Gate summary

| Gate | Result |
| --- | --- |
| Bidirectional messaging (A↔B named accounts) | **Met** |
| Audio signaling A→B | Met; **audible media not proven** |
| Video two-way | **Not met** |
| Network/TURN | **Not met** |
| RC readiness | **NOT READY** (calls/media/TURN incomplete) |
