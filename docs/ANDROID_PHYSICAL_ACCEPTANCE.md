# Android Physical Acceptance — Rollup (through 19.7.30E)

Single index of physical-device evidence. Detail matrices: 30B messaging, 30C calling, 30D lifecycle, 30E gate.

**Devices (30E audit):**

| Role | Identity | App | Signing SHA-256 | Status |
| --- | --- | --- | --- | --- |
| A | SM-S938U `R5CXC2SA8HJ`, Android 17 | `1.0.0` / versionCode `1`, lastUpdate 2026-11-07 23:17:41 | `b694351d88992798ea347584901d77247591010cbcec4e77a2d115be4a803e85` (Android Debug) | Attached; **unlocked** for 30E retest |
| B | Second handset | — | Unknown (do not assume match) | **Not attached** (ADB: only A + offline `emulator-5554`) |

**Git tip at 30E docs commit:** `e3bff3ef8c44d1fd9f2d6c89b4bf11ee63629eac`. Retest below after owner unlock.

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
| L-03 | Lock → unlock UI resume | **Pass** (retest) — after owner unlock, app resumed signed-in; history/chats intact |
| L-04 | Network loss backgrounded | Partial — transient “Can’t reach Private Messenger…” banner observed in conversation; local history still visible; Refresh restored list |

## Accessibility smoke (physical) — Device A retest

TalkBack briefly enabled (`com.google.android.marvin.talkback`); system tutorial appeared (service active). TalkBack then disabled via secure settings; **font_scale restored to 1.0**. No private message bodies or emails recorded in evidence (handles redacted).

| ID | Check | Status | Notes |
| --- | --- | --- | --- |
| X-01 | TalkBack service engages | **Pass** | Service on; tutorial overlay confirmed; app nodes expose content-desc |
| X-01b | TalkBack full gesture navigation of all screens | **Partial** | Tutorial blocked scripted swipe-nav; structural labels verified after TB off |
| X-02 | Large font (1.5×) | **Pass** | Chats/Friends/Settings/Log out/tabs and chat Send/Audio/Video/Back remained present with tappable bounds; font restored |
| X-03 | OTP / login | **Skipped** | Session preserved — no logout |
| X-04 | Chats / Friends / Settings | **Pass** | Tab labels `Chats/Friends/Settings Tab N of 3`; Refresh chats/friends; privacy copy on Settings |
| X-05 | Message statuses / retry guidance | **Pass** | Conversation content-desc includes Received / Sent to server + honest server-vs-device wording |
| X-06 | Safety-number screen | **Pending** | Entry is call-flow “Compare safety number”; no live call without Device B |
| X-07 | Call controls | **Partial** | Audio/Video call buttons labeled and present; live Accept/Decline/Hang up not exercised |
| X-08 | Error / permission recovery | **Partial** | Offline/reachability banner readable; permission-deny flows not re-run |

No inaccessible critical action found on exercised paths. Live call a11y and safety-number remain Device-B gated.

## Security / data preservation (30E retest)

| Check | Result |
| --- | --- |
| Unexpected sign-out | **No** — remained signed in after unlock/TalkBack/font tests |
| Encrypted history loss | **No** — chat rows and message statuses still present |
| Destructive logout / account switch tested | **Not performed** |
| MLS/history cross-store crash window | Remains **open** (RB-30B-002) |
| Premature call auth UI / stuck cam | Not exercised (no live calls) |

## Gate summary

| Gate | Result |
| --- | --- |
| One-device data preservation | Met |
| One-device a11y smoke (A) | **Mostly met** (X-06/X-07 live call pending) |
| Two-device messaging | **Not met** |
| Two-device audio/video | **Not met** |
| Narrow code fix required | **No** |
| RC readiness | **NOT READY** |
