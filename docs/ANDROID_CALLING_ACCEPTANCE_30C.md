# Android Calling Acceptance — Step 19.7.30C

Git tip at matrix authoring: `8e52663690691512e34a6b3b20a122e327407245` (plus 30C docs/tests commit).  
Physical acceptance requires **two** updated handsets. At audit time only **SM-S938U** (`R5CXC2SA8HJ`) was attached.

## Call lifecycle (code)

| `CallPhase` | Meaning | Auth / media notes |
| --- | --- | --- |
| idle | No call UI | — |
| outgoingRinging | Local initiated, waiting | No remote media |
| incomingRinging | Incoming offer | Accept/Decline |
| connecting | SDP/ICE in progress | Not authenticated media |
| connected | WebRTC path up | UI “Securing…” until `CallAuthPhase.authenticated`; `remoteMediaAuthenticated` gates remote video |
| ended | Terminal success hangup | ~1.6s hold then idle |
| failed | Terminal failure | Permission / auth / ICE / etc. |

`CallAuthPhase` (selected): idle → verifying / awaitingPeer → authenticated | failed | identityChanged.

**Do not treat ICE Connected alone as “users can hear/see each other.”**

## One-device checks performed (SM-S938U)

| Test ID | Result | Evidence |
| --- | --- | --- |
| C30-1D-01 Conversation exposes Audio/Video call actions | Pass | UIAutomator: Audio call, Video call present; Hang up / Incoming call absent |
| C30-1D-02 No stuck call overlay at rest | Pass | No Hang up / Incoming call on conversation |
| C30-1D-03 Return to Chats | Pass | Refresh chats after Back |

No live place-call was started (would require peer; avoid orphan ringing on established accounts).

## Two-device matrix (executable when Device B attaches)

Both devices: same package, debug-signing validation APK at current commit, `APP_ENV=validation`, no uninstall/clear/logout.

| Test ID | Initiator | Receiver | Network | Expected | Actual | Auth evidence | Media evidence | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C30-A01 | A audio → B | B accept | Wi-Fi | Two-way audio; mute both; speaker; A hangup cleans both | — | Authenticated chrome / securing→duration | Audible both ways | **Pending** |
| C30-A02 | B audio → A | A accept | Wi-Fi | Same reverse | — | Same | Same | **Pending** |
| C30-V01 | A video → B | B accept | Wi-Fi | Two-way video+audio; local PiP after auth; cam off/on; flip; A hangup | — | Auth before remote video | Visible+audible | **Pending** |
| C30-V02 | B video → A | A accept | Wi-Fi | Same reverse | — | Same | Same | **Pending** |
| C30-B01 | Outgoing ringing | — | — | Back cancels once | — | — | — | **Pending** |
| C30-B02 | Incoming ringing | — | — | Back declines once | — | — | — | **Pending** |
| C30-B03 | Active audio | — | — | Back confirm hangup once; cancel keeps call | — | — | — | **Pending** |
| C30-B04 | Active video | — | — | Same + PiP not covering Hang up | — | — | — | **Pending** |
| C30-B05 | Ended | — | — | Back/dismiss returns to chat | — | — | — | **Pending** |
| C30-P01 | Mic denied (emulator preferred) | — | — | Clear copy; Open settings; no auto-redial | — | — | — | **Pending** |
| C30-P02 | Camera denied | — | — | Same for video | — | — | — | **Pending** |
| C30-N01 | Brief Wi-Fi loss mid-call | — | — | Clean end or documented unsupported migration | — | — | — | **Pending** |
| C30-N02 | Caller cancel before accept | — | — | Callee overlay clears | — | — | — | **Pending** |
| C30-N03 | Remote hangup connecting | — | — | No phantom connected | — | — | — | **Pending** |
| C30-R01 | Local then remote hangup cycles ×3 | — | — | Subsequent call starts; no stuck cam/mic | — | — | — | **Pending** |
| C30-T01 | Relay path (isolated TURN test) | — | — | Selected pair relay if forced | — | — | Privacy-safe stats only | **Pending** |

Legend: Device A = SM-S938U; Device B = second validation phone (not attached).

## Automated coverage (30C)

| Area | Status |
| --- | --- |
| Back / hangup confirm / cancel | Existing `call_ux_test` |
| Auth gate / no Connected before auth | Existing + `calling_lifecycle_30c_test` |
| Duplicate hangUp / auth clear | `calling_lifecycle_30c_test` |
| Camera-off preview / pre-auth video chrome | `calling_lifecycle_30c_test` |
| Permission Open settings / refresh | Existing `call_ux_test` |
| Jargon-free copy | Existing + 30C solidification |

CI must not depend on shared TURN or physical cameras.

## Explicit non-claims

- Physical bidirectional audio/video after UX batches: **not accepted** (Device B missing).
- TURN relay path: **not proven** by allocation alone.
- Terminated-app incoming calls / FCM: **out of scope**.
