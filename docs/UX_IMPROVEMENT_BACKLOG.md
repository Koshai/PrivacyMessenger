# UX improvement backlog — Step 19.7.28 → 19.7.29

Implementation is **not** authorized until Step 19.7.29 is approved.  
This backlog batches findings from `UX_AUDIT_FINDINGS.md` for incremental work without a redesign.

## Top 10 highest-impact improvements

1. **Accurate privacy copy** (F-001) — Settings must reflect live E2EE.
2. **Logout confirmation with consequences** (F-002).
3. **Auth unavailable explanation** (F-003).
4. **Honest message delivery labels** (F-004, F-005, F-006).
5. **Confirm friend remove/block** (F-007).
6. **Empty chats → Add friends CTA** (F-008).
7. **History-unavailable recovery actions** (F-009).
8. **Android back during call → hang-up path** (F-010).
9. **Restore local video preview after auth** (F-011).
10. **Fix or remove Easy Mode** (F-014) + permission Open-settings reliability (F-013).

---

## Suggested implementation batches (19.7.29+)

### Batch A — Trust & destructive actions (P0 + related P1)
| ID | Work | Est. risk |
| --- | --- | --- |
| F-001 | Rewrite Settings privacy subtitle | Copy |
| F-002 | Logout confirm dialog | Low–med |
| F-007 | Friend remove/block confirms | Low |
| F-003 | Unavailable session explanation UI | Low |
| F-009 | History failure Retry + Log out | Low |

**Exit:** No silent destructive logout; privacy copy accurate; blocked boot paths have recovery.

### Batch B — Messaging status language (P1)
| ID | Work |
| --- | --- |
| F-004 | Relabel Sent → server-bound wording |
| F-005 | Replace ciphertext jargon |
| F-006 | Blocked bubble guidance (no retry) |
| F-018 | Richer empty conversation state |
| F-019 | Composer clear timing polish |

**Exit:** Status labels match outbox safety table; widget tests updated; no auto-retry introduced.

### Batch C — Calling UX solidification (P1)
| ID | Work |
| --- | --- |
| F-010 | `PopScope` / back → hang-up confirm |
| F-011 | Local PiP after video auth |
| F-013 | Structured permission → Open settings |
| F-021 | Video top status (phase + duration) |
| F-012 | In-app missed/canceled affordance **without** claiming killed-app push |
| F-032 | Brief ended hold |

**Exit:** Users always know ringing vs connecting vs connected vs ended; back is safe.

### Batch D — First-run & navigation (P1/P2)
| ID | Work |
| --- | --- |
| F-008 | Empty chats CTA to Friends |
| F-014 | Easy Mode: implement textScale **or** remove |
| F-015 | Platform-correct `deviceName` |
| F-016 | Chat list preview + time (local history) |
| F-017 | Global connectivity banner |
| F-026 | Branded checking splash |

**Exit:** New user can discover friends and understand offline state.

### Batch E — Accessibility & consistency (P2/P3)
| ID | Work |
| --- | --- |
| F-022, F-023 | Safety-number human labels; hide raw hex on call chrome |
| F-024 | Labeled friend actions |
| F-028, F-029 | Semantics + text-scale pass |
| F-030, F-031 | AppBar/avatar consistency |
| F-027, F-037 | Diagnostics/licenses under Settings (validation builds) |
| F-025 | Dark theme (optional later) |

**Exit:** TalkBack smoke pass on auth → chats → send → call controls; 1.5× font no clipped primary actions.

---

## Explicit non-goals for 19.7.29

- TCMA / trust-constrained messaging architecture
- iOS TestFlight / PushKit terminated-app calling claims
- Changing MLS wire format, outbox state machine semantics, or automatic unsafe retries
- New UI component libraries
- Backend deploy or schema changes (unless a later approved copy/API error-message pass)
- Uninstalling apps, clearing data, regenerating identities

## Dependency notes

- Batch B must preserve `ConversationController.retry` rules (failed/uncertain only).
- Batch C must not weaken `remoteMediaAuthenticated` video gating.
- Chat list previews (F-016) must read **local decrypted** history only; never log plaintext.
