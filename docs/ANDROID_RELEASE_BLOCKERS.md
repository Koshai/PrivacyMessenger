# Android Release Blockers

Living register updated through **Step 19.7.30D**. Severity: **Blocker** > **High** > **Medium** > **Low**.

## Classification key (30D)

| Class | Meaning |
| --- | --- |
| External-beta blocker | Must close (or explicitly waive with evidence) before controlled external beta |
| Public-release blocker | Must close before public/store review |
| Known beta limitation | Acceptable for a tightly controlled beta if disclosed |
| Deferred improvement | Later milestone; not a silent “pass” |

## Open — security / data-loss

| ID | Severity | Class | Reproducible? | Physical? | Status | Close evidence |
| --- | --- | --- | --- | --- | --- | --- |
| RB-30A-001 | **High** | Known beta limitation (disclose) | Yes (by design) | Yes | Open | Product decision + UX copy; disposable-account logout only on validation |
| RB-30A-003 | **Medium** | Deferred improvement | Yes | N/A | Open | Logout clears peer index or scopes wipe |

## Open — messaging reliability

| ID | Severity | Class | Notes | Status | Close evidence |
| --- | --- | --- | --- | --- | --- |
| RB-30B-001 | **High** | **External-beta blocker** | Two-device messaging after UX/update unverified (Device B missing) | Open | M-01 matrix on A+B |
| RB-30B-002 | **Medium** | Known beta limitation | Cross-store MLS↔history crash window | Open | Documented consequence + fail-closed UI; redesign out of scope |
| RB-30A-004 | **Medium** | Deferred improvement | Preview “Encrypted chat” until first open | Open | Preview decrypt policy |

## Open — calling / physical acceptance

| ID | Severity | Class | Notes | Status | Close evidence |
| --- | --- | --- | --- | --- | --- |
| RB-30A-002 | **High** | **External-beta blocker** | Updated two-device A/V after UX batches | Open | See calling matrix 30C |
| RB-30C-001 | **High** | **External-beta blocker** | Bidirectional **audible** audio not verified on current APKs | Open | A-01/A-02 with media evidence |
| RB-30C-002 | **High** | **External-beta blocker** | Bidirectional **visible** video + PiP/cam switch not verified | Open | V-01/V-02 |
| RB-30C-003 | **Medium** | External-beta preferred | Physical Back during live call | Open | C30-B\* on device |
| RB-30C-004 | **Medium** | Public-release / network claim | TURN relay selected-pair unproven | Open | Privacy-safe candidate type |
| RB-30C-005 | **Low** | Known beta limitation | Wi-Fi↔cellular mid-call unsupported | Open | Clean failure copy |

## Open — lifecycle / accessibility / RC (30D)

| ID | Severity | Class | Notes | Status | Close evidence |
| --- | --- | --- | --- | --- | --- |
| RB-30D-001 | **High** | **External-beta blocker** | Aggregate: Device B still absent → two-device gate unmet | Open | Attach B; run `ANDROID_PHYSICAL_ACCEPTANCE.md` |
| RB-30D-002 | **Medium** | External-beta blocker until smoke done | Physical TalkBack/large-font smoke incomplete (secure keyguard after lock test) | Open | X-01–X-08 on unlocked device |
| RB-30D-003 | **Low** | Deferred / ops | No custom uncaught-error handler / local diagnostic export | Open | Approved privacy-preserving design |
| RB-30D-004 | **Low** | Public-release | versionCode still `1`; debug signing for validation | Open | Store keystore + version bump plan (do not swap cert on established devices casually) |

## Not blockers (disclosed)

| ID | Severity | Notes |
| --- | --- | --- |
| RB-30A-010 | Low | Debug signing for validation APKs (intentional) |
| RB-30A-011 | Low | versionCode still 1 |
| RB-30A-012–014 | Low | Dark theme / global banner / killed-app incoming (unsupported) |

## Closed / verified (code or one-device)

| ID | Milestone | Notes |
| --- | --- | --- |
| RB-30A-V01–V04 | 30A | Update-in-place, session, fail-closed history, peer index tests |
| RB-30B-V01–V03 | 30B | History open/reopen; outbox UI matrix |
| RB-30C-V01 | 30C | Call entry affordances on SM-S938U; no stuck overlay |
| RB-30C-V02 | 30C | Automated auth gate, duplicate hangUp cleanup, jargon-free copy, camera-off preview |
| RB-30D-V01 | 30D | Force-stop cold start + bg/fg reopen conversation on SM-S938U; session retained |
| RB-30D-V02 | 30D | Local disposable Postgres envelope idempotency concurrency e2e **PASS** |
| RB-30D-V03 | 30D | Inspect-only release APK built; **not** installed on established Samsung |

## Deferral rules

- Do **not** close RB-30B-001 / RB-30C-001 / RB-30C-002 because unit tests pass.
- Do **not** close RB-30B-002 because lifecycle smoke passed.
- Known limitations may ship only inside a **controlled** beta with written disclosure — still requires Device B messaging + A/V media evidence first.

## Manual checklist snapshot

### Device A — SM-S938U

- [x] Updated APK; session; chats/friends/settings (30A)
- [x] Conversation history open (30B)
- [x] Force-stop / bg-fg lifecycle reopen (30D)
- [x] Audio/Video call buttons; no stuck Hang up (30C one-device)
- [ ] TalkBack / large-font smoke (30D incomplete — keyguard)
- [ ] Live A/V with peer
- [ ] Back during live call
- [ ] Permission recovery on device/emulator

### Device B

- [ ] Not attached — all two-device rows **Pending**

## RC pointer

See `ANDROID_RC_READINESS.md`: **NOT READY**.
