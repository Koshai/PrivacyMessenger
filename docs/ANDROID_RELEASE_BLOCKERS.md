# Android Release Blockers

Living register updated through **Step 19.7.30C**. Severity: **Blocker** > **High** > **Medium** > **Low**.

## Open — security / data-loss

| ID | Severity | Reproduction | Impact | Status | Acceptance test |
| --- | --- | --- | --- | --- | --- |
| RB-30A-001 | **High** | Logout wipes MLS keys; history unreadible after re-login | By-design data loss risk | Open (by design) | Disposable logout only |
| RB-30A-003 | **Medium** | Peer index sidecar survives logout | Stale opaque ids | Open | Disposable isolation |

## Open — messaging reliability

| ID | Severity | Notes | Status |
| --- | --- | --- | --- |
| RB-30B-001 | **High** | Two-device messaging after update **unverified** (Device B missing) | Open |
| RB-30B-002 | **Medium** | Cross-store MLS↔history crash window (architectural) | Open |
| RB-30A-004 | **Medium** | Chat preview “Encrypted chat” until first open | Open |

## Open — calling / physical acceptance

| ID | Severity | Notes | Status |
| --- | --- | --- | --- |
| RB-30A-002 | **High** | Updated two-device A/V calling acceptance after UX batches | **Open** — Device B not attached; see `ANDROID_CALLING_ACCEPTANCE_30C.md` |
| RB-30C-001 | **High** | Bidirectional audio on updated APKs not physically verified | Open |
| RB-30C-002 | **High** | Bidirectional video + local PiP + cam switch not physically verified | Open |
| RB-30C-003 | **Medium** | Physical Android Back during live ringing/active call not revalidated on device | Open (widget coverage exists) |
| RB-30C-004 | **Medium** | TURN relay selected-pair not proven; do not claim relay-only success | Open |
| RB-30C-005 | **Low** | Active call network migration (Wi-Fi↔cellular) unsupported / unproven — must end cleanly | Open |

## Not blockers

| ID | Severity | Notes |
| --- | --- | --- |
| RB-30A-010 | Low | Debug signing for validation APKs |
| RB-30A-011 | Low | versionCode still 1 |
| RB-30A-012–014 | Low | Dark theme / global banner / killed-app incoming |

## Closed / verified (code or one-device)

| ID | Milestone | Notes |
| --- | --- | --- |
| RB-30A-V01–V04 | 30A | Update-in-place, session, fail-closed history, peer index tests |
| RB-30B-V01–V03 | 30B | History open/reopen; outbox UI matrix |
| RB-30C-V01 | 30C | Call entry affordances on SM-S938U (Audio/Video); no stuck overlay |
| RB-30C-V02 | 30C | Automated auth gate, duplicate hangUp cleanup, jargon-free copy, camera-off preview tests |

## Manual checklist snapshot

### Device A — SM-S938U

- [x] Updated APK; session; chats/friends/settings
- [x] Conversation history open (30B)
- [x] Audio/Video call buttons visible; no stuck Hang up overlay (30C one-device)
- [ ] Live A/V with peer
- [ ] Back during live call
- [ ] Permission recovery on device/emulator

### Device B

- [ ] Not attached — all two-device rows **Pending**

Physical acceptance of 30C is **not** complete until C30-A01/A02/V01/V02 pass.
