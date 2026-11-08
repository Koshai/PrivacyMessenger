# Android Release Blockers — Step 19.7.30A

Living register. Severity: **Blocker** > **High** > **Medium** > **Low**. Cosmetic issues stay in the Low / deferred section.

## Open blockers / high risks

| ID | Severity | Reproduction | Impact | Devices | Data-loss / security | Proposed correction | Status | Acceptance test |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| RB-30A-001 | **High** | Logout on a device that has readable encrypted history | Prior chats become unreadable after re-login (new MLS identity) | All | Intentional key wipe; easy to misunderstand as “cloud restore” | Keep confirmation copy; document in RC notes; never use established accounts for logout experiments | Open (by design; must be accepted for RC) | Disposable account: logout → re-login → history not decryptable; confirmation shown |
| RB-30A-002 | **High** | Physical regression of Batches B–E calling UX not fully revalidated on **two** devices after UX commits | Unknown regressions in Back, PiP, permissions, statuses | Second device missing at audit | Communication reliability | Complete 19.7.30C calling solidification on two handsets | Open | Two-device A/V call + Back + hang-up + permission recovery checklist |
| RB-30A-003 | **Medium** | Peer index `.peers.json` not deleted on logout | Stale opaque ids may remain under old user/device path | All | Low if device ids rotate; theoretical confusion if same ids reused | Optional logout cleanup of sidecar (separate approved change) | Open | Disposable: logout leaves no readable previews for new identity |
| RB-30A-004 | **Medium** | Chat list may show “Encrypted chat” until a conversation was opened once on this install | Weaker first-run list UX | SM-S938U observed | None (no plaintext leak) | Accept for now or later bind index without inventing unread | Open | After opening a thread, preview/time appear; restart retains |

## Not blockers (tracked)

| ID | Severity | Notes | Status |
| --- | --- | --- | --- |
| RB-30A-010 | Low | Validation APK still uses **debug** signing | Documented; replace only with approved keystore migration |
| RB-30A-011 | Low | `versionCode` remains `1` across UX batches | Bump before store/RC packaging |
| RB-30A-012 | Low | Dark theme deferred (F-025) | Out of 30A scope |
| RB-30A-013 | Low | Global connectivity banner deferred | Conversation-scoped banner only |
| RB-30A-014 | Low | Terminated-app incoming call / FCM not implemented | Must not claim background ringing |

## Closed / verified this milestone

| ID | Notes |
| --- | --- |
| RB-30A-V01 | Signing match allowed non-destructive update (`adb install -r`) on SM-S938U |
| RB-30A-V02 | Post-update session remained signed-in; Chats/Friends/Settings reachable |
| RB-30A-V03 | History open failures fail closed without key replacement (existing unit tests) |
| RB-30A-V04 | Peer index corrupt/missing handling + path isolation solidification tests added |

## Manual acceptance checklist (pending where unchecked)

### Device A — SM-S938U (`R5CXC2SA8HJ`)

- [x] Signature-compatible update installed
- [x] App launches without fatal crash
- [x] Existing session still authenticated
- [x] Chats list shows existing contacts
- [x] Friends tab loads (count visible)
- [x] Settings shows About / licenses / Log out (Log out **not** pressed)
- [ ] Open an existing conversation and confirm historical messages decrypt
- [ ] Send a message; honest status labels
- [ ] Safety number screen opens from a call without enum jargon
- [ ] Large text (system font) still reaches Hang up / Send
- [ ] Audio call smoke
- [ ] Video call smoke + local preview after auth
- [ ] Android Back during ringing / active call

### Device B — second validation handset

- [ ] Device attached via ADB
- [ ] Same update applied with signature match
- [ ] Session / history preserved
- [ ] Two-device messaging + calling smoke

## Owner

Release engineering / app owner: record updates in this file when items close. Do not clear blockers by weakening cryptography or wiping established device data.
