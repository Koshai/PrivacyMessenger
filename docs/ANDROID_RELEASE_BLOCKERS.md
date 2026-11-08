# Android Release Blockers

Living register updated through **Step 19.7.30B**. Severity: **Blocker** > **High** > **Medium** > **Low**.

## Open — security / data-loss

| ID | Severity | Reproduction | Impact | Devices | Data-loss / security | Proposed correction | Status | Acceptance test |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| RB-30A-001 | **High** | Logout on a device with readable encrypted history | Prior chats unreadable after re-login (new MLS identity) | All | Intentional key wipe | Keep confirmation; RC notes; never experiment on established accounts | Open (by design) | Disposable logout → history not decryptable |
| RB-30A-003 | **Medium** | Peer index `.peers.json` survives logout | Stale opaque ids under old user/device path | All | Low if device ids rotate | Optional logout sidecar cleanup (approved change later) | Open | Disposable logout isolation |

## Open — messaging reliability

| ID | Severity | Reproduction | Impact | Status | Acceptance test |
| --- | --- | --- | --- | --- | --- |
| RB-30B-001 | **High** | Second validation handset unavailable | Bidirectional live send/receive after UX+30A update **unverified** | Open | Two-device messaging smoke on updated APKs |
| RB-30B-002 | **Medium** | Cross-store crash between MLS ratchet advance and history/outbox commit | Non-atomic window; mitigated by barriers but not fully eliminated | Open (architectural) | Documented in reliability matrix; disposable crash fixtures only |
| RB-30A-004 | **Medium** | Chat list shows “Encrypted chat” until conversation opened once | Weaker previews | Open | After open + restart, preview/time persist |

## Open — calling / device verification

| ID | Severity | Notes | Status |
| --- | --- | --- | --- |
| RB-30A-002 | **High** | Two-device calling UX regression after Batches B–E still pending | Open → 19.7.30C |

## Not blockers

| ID | Severity | Notes | Status |
| --- | --- | --- | --- |
| RB-30A-010 | Low | Validation APK uses debug signing | Documented |
| RB-30A-011 | Low | `versionCode` still `1` | Bump before store/RC |
| RB-30A-012 | Low | Dark theme deferred | Out of scope |
| RB-30A-013 | Low | No global connectivity banner | Conversation-scoped only |
| RB-30A-014 | Low | No terminated-app incoming call / FCM | Must not claim |

## Closed / verified

| ID | Milestone | Notes |
| --- | --- | --- |
| RB-30A-V01 | 30A | Signing-compatible `adb install -r` on SM-S938U |
| RB-30A-V02 | 30A | Session survived update; tabs reachable |
| RB-30A-V03 | 30A | History open fail-closed without key replacement |
| RB-30A-V04 | 30A | Peer index isolation / corrupt handling tests |
| RB-30B-V01 | 30B | Existing conversation opens post-update; substantial a11y content nodes; not unavailable/empty |
| RB-30B-V02 | 30B | Background → reopen conversation still shows substantial content nodes |
| RB-30B-V03 | 30B | Outbox UI action matrix locked in solidification tests; existing outbox/idempotency suites green |

## Manual acceptance checklist

### Device A — SM-S938U (`R5CXC2SA8HJ`)

- [x] Signature-compatible update installed (30A)
- [x] App launches; session authenticated
- [x] Chats / Friends / Settings reachable
- [x] Open existing conversation (history content present via a11y; no unavailable/empty)
- [x] Background and reopen conversation (content nodes remain)
- [ ] Live send with honest status (deferred — avoid noise without peer device)
- [ ] Safety number from a call
- [ ] Large text Hang up / Send
- [ ] Audio / video call smoke + Back policy

### Device B — second validation handset

- [ ] Attached via ADB
- [ ] Update + session/history preserved
- [ ] Bidirectional messaging
- [ ] Calling smoke (30C)

## Owner

Do not close physical-device blockers with unit tests alone. Do not clear established device data to “fix” failures.
