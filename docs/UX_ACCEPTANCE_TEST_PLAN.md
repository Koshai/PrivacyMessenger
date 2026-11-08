# UX acceptance test plan — Step 19.7.28 / prep for 19.7.29

Manual and automated checks for ordinary nontechnical users.  
Do **not** uninstall apps, clear data, or regenerate MLS identities while validating on devices that hold real conversations.

## A. Automated (CI / Windows)

Run from `mobile/`:

```sh
flutter analyze
flutter test
```

Existing coverage to keep green:

| Area | Tests |
| --- | --- |
| Tabs / empty chats | `test/widget_test.dart` |
| Login / OTP | `features/auth/*_test.dart` |
| Auth navigation / logout invoke | `core/auth/auth_navigation_test.dart`, `features/settings/settings_logout_test.dart` |
| Friends accept/reject/error | `features/friends/friends_screen_test.dart` |
| Delivery labels | `features/messaging/delivery_status_test.dart` |
| Safety number | `features/messaging/safety_number_screen_test.dart` |
| Call overlay | `features/calling/call_ux_test.dart` |
| Outbox safety (non-UI) | `outgoing_outbox_test.dart`, `outbox_safety_verification_test.dart` |

### Coverage gaps (add in 19.7.29 with implementations)

| Gap | Suggested test type | Avoid |
| --- | --- | --- |
| Logout confirmation copy/flow | `testWidgets` | Flaky timing |
| Unavailable auth explanation | `testWidgets` | Network flake — inject AuthController state |
| History-unavailable recovery | `testWidgets` with fake shell flag | Real DB corruption |
| Blocked bubble guidance | `testWidgets` on `ChatMessageBubble` | — |
| Relabeled Sent / Unconfirmed | Update `delivery_status_test.dart` | — |
| Empty chats CTA | `testWidgets` callback | — |
| Call back → hang-up | `testWidgets` + `CallHost` | Full WebRTC |
| Video local PiP after auth | `testWidgets` with fake controller phases | Pixel goldens first |
| Easy Mode behavior or absence | `testWidgets` | — |
| Text scale 1.5 overflow on Login/Chats/Call controls | `testWidgets` with `MediaQuery` textScaler | Full-screen goldens until layout stable |

**Golden / screenshot guidance:** Prefer targeted goldens for `ChatMessageBubble` status row and `CallStatusHeader` only after copy stabilizes. Avoid full-app goldens (theme/CI font variance).

---

## B. Manual device matrix (Android physical preferred)

Use two already-installed validation devices; `adb install -r` only if a new build is approved later. For this audit milestone, **observation of current APK** is enough.

| ID | Journey | Steps | Pass criteria |
| --- | --- | --- | --- |
| M1 | Cold start | Force-stop → launch | Spinner then chats or sign-in; never blank forever |
| M2 | OTP happy path | New email or existing | Code entry clear; lands on tabs |
| M3 | OTP expired | Wait/expire → verify | Understandable error; can go back and request again |
| M4 | Empty chats | Account with no friends | Message understandable; user can find Friends (note F-008 fail today) |
| M5 | Friend request | Send / accept on peer | Lists update; privacy snackbar OK |
| M6 | Remove/block | Tap icons | Today: immediate — record accidental-tap risk (F-007) |
| M7 | Send message | Online peer | Shows Sending → Sent; peer receives |
| M8 | Offline send | Airplane → send → online | Status honest; retry/resubmit safe; no duplicate plaintext confusion |
| M9 | Unconfirmed | Induce uncertain if possible | “Unconfirmed” + Resubmit; no jargon preference (F-005 fail today) |
| M10 | Audio call | A→B | Ringing/connecting/connected/hangup clear |
| M11 | Video call | A↔B | Both see remote; note missing local PiP after auth (F-011) |
| M12 | Permission deny | Deny mic | Failed state + path to settings |
| M13 | Back during call | System back | Record actual behavior (F-010) |
| M14 | Background | Home during call | Call ends or continues per lifecycle — document; no killed-app claim |
| M15 | Logout | Settings logout | Today: no confirm (F-002); after fix: confirm explains history risk |
| M16 | Font scale | System largest font | Primary buttons still tappable; no clipped OTP field |
| M17 | TalkBack smoke | Enable TalkBack | Tabs, Send, Accept/Decline announced |

---

## C. Acceptance criteria for “UX ready for RC messaging”

Must all be true before calling messaging UX release-candidate ready:

1. Privacy Settings copy matches shipped E2EE.
2. Logout requires informed confirmation.
3. Message statuses never claim peer-device delivery unless a real ack exists.
4. Failed / unconfirmed / blocked each have correct, safe actions only.
5. Empty chats leads to adding friends in one tap.
6. Call phases are verbally and visually distinct; back cannot leave silent live media.
7. Easy Mode is truthful or removed.
8. `flutter analyze` + `flutter test` green.
9. Two-device manual M7–M11 pass on current validation backend.
10. No user-visible MLS/ciphertext/DTLS jargon in primary flows.

Calling RC additionally requires M10–M14 and explicit documentation that terminated-app incoming calls are **not** supported.

---

## D. Safety confirmation for testers

When executing manual tests:

- Do not clear app storage.
- Do not delete conversations to “reset” UX.
- Do not regenerate MLS identities.
- Do not paste OTP codes or session tokens into tickets with plaintext message contents.
- Prefer screenshots of chrome/status, not private message bodies, in shared notes.
