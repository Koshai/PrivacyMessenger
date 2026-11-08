# Android Release Blockers

Living register updated through **Step 19.7.30E**. Severity: **Blocker** > **High** > **Medium** > **Low**.

## Classification key

| Class | Meaning |
| --- | --- |
| Must fix before controlled external beta | External-beta blocker — evidence required |
| Must fix before public release | Public-release blocker |
| Documented acceptable beta limitation | May ship in tightly controlled beta only if disclosed **and** other beta gates pass |
| Deferred improvement | Later milestone; not a silent pass |

## Open — security / data-loss

| ID | Severity | Class | Reproducible? | Physical? | 30E review | Status | Close evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| RB-30A-001 | **High** | Documented acceptable beta limitation (disclose) | Yes (by design) | Yes | Consequence reviewed: logout wipes MLS keys → history unreadible | Open | Product decision + UX copy; never test logout on established RC accounts |
| RB-30A-003 | **Medium** | Deferred improvement | Yes | N/A | Unchanged | Open | Logout clears peer index or scopes wipe |
| RB-30B-002 | **Medium** | Documented acceptable beta limitation | Architectural | N/A | Consequence + fail-closed UX reviewed; **no redesign in 30E** | Open | Documented window; user composes new message; future transactional boundary |

## Open — messaging reliability

| ID | Severity | Class | Notes | Status | Close evidence |
| --- | --- | --- | --- | --- | --- |
| RB-30B-001 | **High** | **Must fix before controlled external beta** | Two-device messaging after UX/update unverified | Open (30E: Device B absent) | M-01–M-07 on A+B |
| RB-30A-004 | **Medium** | Deferred improvement | Preview “Encrypted chat” until first open | Open | Preview decrypt policy |

## Open — calling / physical acceptance

| ID | Severity | Class | Notes | Status | Close evidence |
| --- | --- | --- | --- | --- | --- |
| RB-30A-002 | **High** | **Must fix before controlled external beta** | Updated two-device A/V after UX batches | Open | Calling matrix with media evidence |
| RB-30C-001 | **High** | **Must fix before controlled external beta** | Bidirectional **audible** audio not verified on current APKs | Open | A-01/A-02 (+ consecutive) |
| RB-30C-002 | **High** | **Must fix before controlled external beta** | Bidirectional **visible** video + controls not verified | Open | V-01/V-02 |
| RB-30C-003 | **Medium** | Must fix before controlled external beta (preferred) | Physical Back during live call | Open | C30-B\* / V-04 |
| RB-30C-004 | **Medium** | Must fix before public release (for relay claims) | TURN selected-pair unproven | Open | Privacy-safe candidate type when selected |
| RB-30C-005 | **Low** | Documented acceptable beta limitation | Wi-Fi↔cellular mid-call unsupported | Open | Clean failure copy |

## Open — lifecycle / accessibility / RC

| ID | Severity | Class | Notes | Status | Close evidence |
| --- | --- | --- | --- | --- | --- |
| RB-30D-001 | **High** | **Must fix before controlled external beta** | Device B absent → two-device gate unmet | **Reconfirmed 30E** | Attach B or remote sheet results |
| RB-30D-002 | **Medium** | **Must fix before controlled external beta** | Physical TalkBack/large-font incomplete | **Reconfirmed 30E** (keyguard) | X-01–X-08 unlocked |
| RB-30D-003 | **Low** | Deferred improvement | No custom crash handler / local diagnostic export | Open | Approved privacy-preserving design |
| RB-30D-004 | **Low** | Must fix before public release | versionCode `1`; debug signing for validation | Open | Store keystore + version plan without casual cert swap |

## Not blockers (disclosed)

| ID | Severity | Notes |
| --- | --- | --- |
| RB-30A-010 | Low | Debug signing for validation APKs (intentional) |
| RB-30A-011 | Low | versionCode still 1 |
| RB-30A-012–014 | Low | Dark theme / global banner / killed-app incoming (unsupported) |

## Closed / verified (code or one-device) — unchanged unless noted

| ID | Milestone | Notes |
| --- | --- | --- |
| RB-30A-V01–V04 | 30A | Update-in-place, session, fail-closed history, peer index |
| RB-30B-V01–V03 | 30B | History open/reopen; outbox UI matrix |
| RB-30C-V01–V02 | 30C | One-device call affordances + automated lifecycle |
| RB-30D-V01–V03 | 30D | Force-stop lifecycle; local DB idempotency; inspect APK not installed |
| RB-30E-V01 | 30E | Installed A cert fingerprint confirmed; no destructive install; remote tester sheet published |
| RB-30E-V02 | 30E | Explicit non-closure of two-device / a11y / MLS-window blockers without evidence |

## 30E manual checklist

### Device A — SM-S938U

- [x] Package/signing/ABI recorded (debug cert match known validation identity)
- [ ] Unlocked for TalkBack / large-font smoke
- [ ] Live messaging with peer
- [ ] Live A/V with peer

### Device B

- [ ] Not attached — all two-device rows **Pending** (use `ANDROID_EXTERNAL_TESTER_30E.md` if remote)

## RC pointer

`ANDROID_RC_READINESS.md`: **NOT READY**.
