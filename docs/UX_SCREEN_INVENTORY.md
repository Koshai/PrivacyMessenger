# UX screen inventory — Step 19.7.28

Source of truth: Flutter tree under `mobile/lib/` (examined 2026-11-07).  
No visual changes were made for this audit.

## Navigation architecture

| Layer | Implementation | File |
| --- | --- | --- |
| Root app | `PrivateMessengerApp` switches `home` on `AuthStatus` | `mobile/lib/main.dart` |
| Signed-out | Nested `Navigator` → `LoginScreen` → push `VerifyOtpScreen` | `features/auth/auth_flow.dart` |
| Signed-in shell | `CallHost` → `MainNavigation` (`IndexedStack` + `NavigationBar`) | `main.dart` |
| Chat thread | `Navigator.push` → `ConversationScreen` | `features/chats/chats_screen.dart` |
| Active call | Root `OverlayEntry` → `ActiveCallScreen` (not a route) | `features/calling/call_screens.dart` |
| Safety number | `Navigator.push` from call UI | `features/messaging/safety_number_screen.dart` |

State management is controller/`ChangeNotifier`-based (`AuthController`, `FriendsController`, `ConversationController`, `CallController`). There is no named route table beyond `AuthFlow.onGenerateRoute`.

Theme: light Material 3 only (`AppTheme.light`). No `darkTheme` / `ThemeMode`.

---

## Complete screen inventory

| # | Screen / surface | Class | Reachable from product UI? | Purpose |
| --- | --- | --- | --- | --- |
| 1 | Session restore spinner | anonymous `Scaffold` + `CircularProgressIndicator` | Yes (`AuthStatus.initial` / `checking`) | First paint while session validates |
| 2 | Session unavailable | anonymous `Scaffold` + “Try again” | Yes (`AuthStatus.unavailable`) | Retry session restore |
| 3 | Sign in | `LoginScreen` | Yes | Email → OTP request |
| 4 | Verify email | `VerifyOtpScreen` | Yes | Six-digit OTP |
| 5 | History open failure | anonymous `Scaffold` text | Yes when `LocalMessageStore.open` fails | Blocks shell if encrypted history cannot open |
| 6 | Messaging bootstrap spinner | anonymous `Scaffold` + spinner | Yes while history opens | Brief gate before tabs |
| 7 | Chats (home tab) | `ChatsScreen` | Yes | Friend-based conversation list |
| 8 | Friends tab | `FriendsScreen` | Yes | Add / accept / reject / remove / block |
| 9 | Settings tab | `SettingsScreen` | Yes | Easy Mode toggle, privacy row, logout |
| 10 | One-to-one chat | `ConversationScreen` | Yes from Chats | Messages, send, call buttons |
| 11 | Active call overlay | `ActiveCallScreen` | Yes when `CallPhase != idle` | Incoming/outgoing/in-call UI |
| 12 | Safety number | `SafetyNumberScreen` | Yes from call “Compare safety number” | Fingerprint compare / trust |
| 13 | API connectivity (dev) | `ApiConnectivityScreen` | **No** — not linked from `MainNavigation` or Settings | Health-check diagnostic |

**Total product screens/surfaces discovered: 12** (plus 1 orphan diagnostic).  
There is no branded splash, profile page, notification center, missed-call log, media gallery, or group chat UI.

---

## Primary user journeys

### J1 — First launch / session restore
1. App starts → spinner (`checking`).
2a. Valid session → open encrypted history → tabs.  
2b. No session → Sign in.  
2c. Validation unavailable → “Try again” only (no explanation copy).  
2d. History open fails → hard stop text, no retry control.

### J2 — Email OTP authentication
1. Enter email → “Send verification code”.
2. OTP screen → enter 6 digits → “Verify code”.
3. Success → `AuthController.signIn` → authenticated shell (AuthFlow navigator discarded via `MaterialApp` key).
4. Expired code → SnackBar; “Use a different email” pops back.
5. Gaps: no resend OTP on same screen; `deviceName: 'Android'` hard-coded in `VerifyOtpScreen`.

### J3 — Home and conversation list
1. Chats tab lists **friends** (not a separate conversation store).
2. Empty → “Add a friend…” but no CTA to Friends tab.
3. Error → Retry.
4. Tap row → `ConversationScreen`.
5. Gaps: no last-message preview, unread badges, timestamps, or search.

### J4 — Friends and contact lifecycle
1. Add by email (privacy-preserving success copy).
2. Incoming Accept / Reject.
3. Remove friend / Block (icon-only, **no confirmation dialog**).
4. Unblock.
5. Gaps: no outgoing-pending list UI section; remove/block are irreversible without confirm.

### J5 — One-to-one messaging
1. Open chat → enroll/open MLS → load history.
2. Send; statuses via `deliveryStatusLabel` (`Sending` / `Sent` / `Failed` / `Unconfirmed` / `Needs attention`).
3. Retry / Resubmit for failed / uncertain only (`ConversationController.retry`).
4. Offline icon in AppBar; key-change `MaterialBanner`.
5. Gaps: “Sent” = server-accepted durable send, **not** peer-device delivery; blocked state has no user action; jargon in uncertain helper (“ciphertext”).

### J6 — Audio / video calling
1. From chat AppBar → start audio/video.
2. Overlay: ringing / connecting / connected / failed / ended.
3. Accept / Decline / Cancel / Mute / Speaker / Camera / Flip / Hang up.
4. Auth phases gate remote video (`remoteMediaAuthenticated`).
5. Safety number compare optional after auth.
6. Gaps: after video auth, local preview disappears; call is Overlay (Android back does not hang up); no missed-call inbox; no claim of terminated-app ringing (PushKit/FCM not productized).

### J7 — Settings / logout
1. Easy Mode switch (local state only — **does not change theme/text**).
2. Privacy row subtitle: “End-to-end encryption planned” (**stale vs shipped E2EE**).
3. Log out → clears MLS/session (destructive) with **no confirmation** explaining history/key consequences.

### J8 — Connectivity / background
1. Chat offline icon; Friends/Chats load errors with Retry.
2. `CallHost` observes app lifecycle → hang up on detach.
3. Gaps: no global connectivity banner; no push notifications for messages; incoming call depends on foreground/realtime.

---

## Missing screens (documented gaps)

| Expected area | Status |
| --- | --- |
| Branded splash / onboarding | Missing (spinner only) |
| Profile / edit display name | Missing |
| Conversation search / archive | Missing |
| Message delivery to peer / read receipts | Not modeled in UI (`Sent` ≠ peer delivery) |
| Missed / canceled call history | Missing |
| System notification settings UI | Missing |
| Account recovery / device transfer | Missing (logout/re-enroll is destructive by design) |
| Dark mode | Missing |
| Linked `ApiConnectivityScreen` | Exists but unreachable |
| iOS-specific first-run copy | Not separated (OTP `deviceName` Android-fixed) |

---

## Widget / test coverage map (existing)

| Area | Representative tests |
| --- | --- |
| Tabs / empty chats | `test/widget_test.dart` |
| Login / OTP | `login_screen_test.dart`, `verify_otp_screen_test.dart` |
| Auth navigation / logout | `auth_navigation_test.dart`, `settings_logout_test.dart` |
| Friends | `friends_screen_test.dart` |
| Delivery labels | `delivery_status_test.dart` |
| Safety number | `safety_number_screen_test.dart` |
| Call overlay / controls | `call_ux_test.dart` |

No golden/screenshot suite. ConversationScreen empty/error, logout confirmation, and Easy Mode behavior lack dedicated widget coverage.
