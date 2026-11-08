# UX audit findings — Step 19.7.28

Each finding includes screen/journey, code refs, problem, impact, severity, correction, regression risk, acceptance criteria, and suggested tests.  
Priorities: **P0** critical / privacy confusion; **P1** common-flow failure; **P2** meaningful usability; **P3** polish.

Severity counts (this document): **P0: 3 · P1: 12 · P2: 14 · P3: 8** (37 findings).

---

## P0

### F-001 — Settings claims encryption is “planned” while E2EE is live
- **Journey:** Settings → Privacy
- **Refs:** `features/settings/settings_screen.dart` (`Privacy and Security` / `End-to-end encryption planned`); contrast with OpenMLS messaging in `EncryptedConversationService`
- **Problem:** User-facing copy contradicts shipped end-to-end encryption.
- **Reproduction:** Open Settings tab; read Privacy subtitle.
- **Impact:** Undermines trust; users may treat chats as server-readable.
- **Severity:** P0
- **Correction:** Replace with accurate, non-jargon statement (e.g. messages are end-to-end encrypted on this device; the server cannot read message contents). Link to safety-number concept without MLS jargon.
- **Regression risk:** Low (copy-only).
- **Acceptance:** Privacy row never says encryption is only “planned”; reviewed by product.
- **Tests:** Widget assert on Settings privacy subtitle string.

### F-002 — Logout destroys crypto/session with no confirmation or consequence copy
- **Journey:** Settings → Log out
- **Refs:** `settings_screen.dart` `_handleLogout`; `main.dart` `onLogout` → `mls.clearOnLogout` + `signOut`
- **Problem:** Single tap logs out and clears MLS identity material; no dialog explaining that prior encrypted history becomes unreadable on re-login with a new identity.
- **Reproduction:** Settings → Log out.
- **Impact:** Accidental logout → apparent “lost messages” / new identity; privacy/data-loss confusion.
- **Severity:** P0
- **Correction:** Destructive confirmation dialog with plain-language consequences; require explicit confirm; keep snackbar on network failure.
- **Regression risk:** Medium (must not change wipe semantics, only gate them).
- **Acceptance:** Logout requires confirm; cancel leaves session intact; confirm still runs existing clear path.
- **Tests:** Widget test: first tap opens dialog; cancel does not call `onLogout`; confirm calls once.

### F-003 — Auth unavailable screen has no explanation
- **Journey:** J1 session restore failure
- **Refs:** `main.dart` `AuthStatus.unavailable` branch — only `FilledButton` “Try again”
- **Problem:** Blank/minimal screen; no title, cause, or offline guidance.
- **Reproduction:** Force validation failure during `restore`.
- **Impact:** First-time/offline users stuck without understanding.
- **Severity:** P0 (critical flow unusable without guidance)
- **Correction:** Title + short body (“Couldn’t reach Private Messenger. Check your connection.”) + Try again + optional “Sign in with a different account” if session should be discarded safely.
- **Regression risk:** Low.
- **Acceptance:** Unavailable state always shows explanation + retry.
- **Tests:** Auth navigation widget covering `unavailable` home content.

---

## P1

### F-004 — “Sent” implies peer delivery; means server accepted
- **Journey:** Messaging send
- **Refs:** `models/envelope.dart` `deliveryStatusLabel`; `LocalMessageDelivery.sent` mapping in `encrypted_conversation_service.dart`
- **Problem:** Label “Sent” is easy to read as “delivered to their phone.” Durable outbox only confirms server acceptance of ciphertext.
- **Impact:** False confidence about delivery when peer offline.
- **Severity:** P1
- **Correction:** Prefer “Sent to server” / “On its way” wording; keep distinct from future peer-ack if added. Do **not** auto-retry outbox states.
- **Regression risk:** Medium (copy + tests in `delivery_status_test.dart`).
- **Acceptance:** Outgoing success label does not claim device delivery; docs match UI.
- **Tests:** Update `delivery_status_test.dart` expectations.

### F-005 — Uncertain helper uses “ciphertext” jargon
- **Journey:** Unconfirmed send
- **Refs:** `_recoveryError` / send path strings in `encrypted_conversation_service.dart`
- **Problem:** “Resubmit only with the same ciphertext” is opaque to nontechnical users.
- **Impact:** Users fear pressing Resubmit or spam-retry incorrectly.
- **Severity:** P1
- **Correction:** “Delivery wasn’t confirmed. You can safely resubmit the same message. This won’t create a different encrypted copy.” Keep internal outbox safety unchanged.
- **Regression risk:** Low.
- **Acceptance:** No “ciphertext/MLS/DTLS” in user-visible strings for this path.
- **Tests:** String assert on bubble error text.

### F-006 — Blocked / “Needs attention” has no safe action
- **Journey:** Messaging exceptional outbox
- **Refs:** `ChatDeliveryState.blocked`; UI shows label but Retry only for failed/uncertain (`conversation_screen.dart`)
- **Problem:** User sees “Needs attention” / “Cannot safely retry” with nowhere to go.
- **Impact:** Dead-end; may retype and create a *new* message (safe) without knowing that is the path.
- **Severity:** P1
- **Correction:** Inline guidance: “This copy can’t be resent safely. Type a new message instead.” Optional “Learn more” bottom sheet.
- **Regression risk:** Low if retry remains disabled for blocked.
- **Acceptance:** Blocked bubbles explain next step; Retry not shown.
- **Tests:** Widget for blocked bubble copy; controller retry no-op remains.

### F-007 — Friend remove / block without confirmation
- **Journey:** Friends destructive actions
- **Refs:** `friends_screen.dart` remove / block `IconButton`s
- **Problem:** Immediate API call; icon-only; easy mis-tap.
- **Impact:** Accidental unfriend/block.
- **Severity:** P1
- **Correction:** Confirm dialogs; consider text labels or menu; success snackbar already partial for block.
- **Regression risk:** Low.
- **Acceptance:** Remove/block require confirm; cancel no-ops.
- **Tests:** Friends screen widget with dialogs.

### F-008 — Empty chats has no path to Friends
- **Journey:** First-time user
- **Refs:** `chats_screen.dart` empty state
- **Problem:** Instructs “Add a friend” but does not navigate or highlight Friends tab.
- **Impact:** New users don’t discover Friends tab.
- **Severity:** P1
- **Correction:** Primary button “Add friends” calling into tab switch (callback from `MainNavigation`) or push Friends.
- **Regression risk:** Low.
- **Acceptance:** Empty chats exposes one-tap path to add friends.
- **Tests:** Widget tap invokes callback.

### F-009 — Encrypted history failure is a dead end
- **Journey:** Authenticated bootstrap
- **Refs:** `main.dart` `_historyUnavailable`
- **Problem:** Static text; no Retry, Logout, or support path.
- **Impact:** App unusable after storage failure.
- **Severity:** P1
- **Correction:** Retry open + Log out + plain explanation (without instructing data wipe).
- **Regression risk:** Low.
- **Acceptance:** User can retry or return to sign-in without adb.
- **Tests:** Shell widget with forced unavailable flag.

### F-010 — Call UI is Overlay; Android back ignores hang-up
- **Journey:** Active call + system back
- **Refs:** `CallHost` / `ActiveCallScreen` overlay insertion; no `PopScope`
- **Problem:** Back pops underlying routes (e.g. conversation) while call overlay may remain; does not map to Decline/Hang up.
- **Impact:** Confusion about whether call is still live; mic may stay active.
- **Severity:** P1
- **Correction:** While `phase != idle`, intercept back → confirm hang-up or map to hang-up; keep overlay above content.
- **Regression risk:** Medium (navigation).
- **Acceptance:** Back during call never silently leaves media active without user intent.
- **Tests:** Widget/integration with mocked `CallController` + back.

### F-011 — Video call loses local preview after authentication
- **Journey:** Video connected
- **Refs:** `call_screens.dart` branch `video && remoteMediaAuthenticated` shows only remote fill
- **Problem:** Local PiP exists only in pre-auth verifying branch.
- **Impact:** Users can’t tell if their camera is on/framed.
- **Severity:** P1
- **Correction:** Keep local PiP after auth; mirror preview.
- **Regression risk:** Low–medium (layout).
- **Acceptance:** Local preview visible whenever camera enabled in video call.
- **Tests:** Call UX widget checks for dual panes when authenticated video.

### F-012 — Incoming call depends on app/realtime; no missed-call UX
- **Journey:** Incoming call while backgrounded
- **Refs:** realtime hints + `CallController`; Android notifications not implemented for calls/messages
- **Problem:** No product UI for missed/canceled calls; no FCM incoming UX.
- **Impact:** Missed calls invisible.
- **Severity:** P1 (for reliability expectations)
- **Correction:** In-app missed-call row/snackbar when hint arrives late; do **not** claim terminated-app calling until push implemented.
- **Regression risk:** Medium.
- **Acceptance:** Document limitation in Settings; show in-app missed event when detectable.
- **Tests:** Controller unit for canceled/missed transition → UI hook.

### F-013 — Permission denial messaging inconsistent
- **Journey:** Start/accept call
- **Refs:** `call_controller.dart` permission failures; `ActiveCallScreen` shows “Open settings” only if error contains `'permission'`
- **Problem:** Some strings “Permission denied” vs “Microphone/camera permission denied”; recovery affordance string-matched.
- **Impact:** Users may not find Settings.
- **Severity:** P1
- **Correction:** Structured error code → always show Open settings for permission failures.
- **Regression risk:** Low.
- **Acceptance:** Any permission failure shows actionable Open settings.
- **Tests:** Call screen with permission error fixture.

### F-014 — Easy Mode toggle is non-functional
- **Journey:** Settings
- **Refs:** `settings_screen.dart` `easyMode` local bool unused elsewhere
- **Problem:** Switch appears to enable larger text/simpler controls but changes nothing.
- **Impact:** Accessibility false promise.
- **Severity:** P1
- **Correction:** Either wire to `MediaQuery`/textScale/theme or hide until implemented.
- **Regression risk:** Low if removed; medium if implemented.
- **Acceptance:** Control matches behavior; no inert toggle.
- **Tests:** Settings test asserting scale or absence.

### F-015 — OTP verify hard-codes `deviceName: 'Android'`
- **Journey:** Auth on non-Android
- **Refs:** `verify_otp_screen.dart` `verifyOtp(... deviceName: 'Android')`
- **Problem:** Misleading device labeling in multi-device accounts.
- **Impact:** Support/confusion; iOS devices appear as Android.
- **Severity:** P1
- **Correction:** Use `defaultTargetPlatform` / user-visible device label.
- **Regression risk:** Low.
- **Acceptance:** Device name reflects platform.
- **Tests:** Unit/widget with platform override if available.

---

## P2

### F-016 — Chats list lacks preview, time, unread
- **Refs:** `chats_screen.dart` — subtitle always `Encrypted chat`
- **Impact:** Hard to find recent threads.
- **Correction:** Show last plaintext preview from local store + relative time; unread count when available.
- **Risk:** Medium (privacy: previews are local-only — OK).

### F-017 — No global connectivity banner
- **Refs:** Per-screen offline icon / load errors only
- **Correction:** App-level Material banner for API/WS down.
- **Risk:** Low.

### F-018 — Conversation empty state is minimal
- **Refs:** `conversation_screen.dart` “No messages yet”
- **Correction:** Reassure encryption + suggest first message; optional call shortcuts.
- **Risk:** Low.

### F-019 — Send clears input before success
- **Refs:** `_submit` clears then `send`
- **Impact:** Failure requires retyping from bubble (retry exists for failed).
- **Correction:** Clear on accept into outbox; restore to composer on immediate local failure before bubble exists.
- **Risk:** Low.

### F-020 — Keyboard / composer occlusion not specially handled
- **Refs:** `ConversationScreen` `SafeArea` + `TextField`
- **Correction:** Ensure `resizeToAvoidBottomInset`; scroll to last message on focus.
- **Risk:** Low.

### F-021 — Call duration/status weak on video layout
- **Refs:** Title/status concentrated in audio-centered column
- **Correction:** Top status chip on video (phase, duration, auth).
- **Risk:** Low.

### F-022 — Safety number trust state shows enum name
- **Refs:** `safety_number_screen.dart` `Trust state: ${_trust.name}`
- **Correction:** Human labels (“Verified”, “Not verified”, “Changed”).
- **Risk:** Low.

### F-023 — Fingerprint hex shown inline on call chrome
- **Refs:** `call_screens.dart` authenticated device + hex
- **Correction:** Truncate or move full hex to SafetyNumberScreen only.
- **Risk:** Low.

### F-024 — Friends destructive icons lack text for low-vision/new users
- **Refs:** remove/block `IconButton` tooltips only
- **Correction:** Menu “More” with labeled actions.
- **Risk:** Low.

### F-025 — No dark theme
- **Refs:** `app_theme.dart`
- **Correction:** Optional follow-up; ensure contrast audit on light first.
- **Risk:** Medium.

### F-026 — Splash is anonymous spinner
- **Refs:** `main.dart` checking state
- **Correction:** Lightweight branded splash with “Checking sign-in…”.
- **Risk:** Low.

### F-027 — ApiConnectivityScreen orphan
- **Refs:** `api_connectivity_screen.dart`
- **Correction:** Move under Settings diagnostic (debug/validation builds only) or delete from release UX.
- **Risk:** Low.

### F-028 — No Semantics / screen-reader pass on primary tabs
- **Refs:** Navigation destinations have labels; many icons rely on tooltip only
- **Correction:** Audit `Semantics` on send, call, friend actions; announce delivery status changes.
- **Risk:** Low.

### F-029 — Text scaling not verified
- **Refs:** Hard-coded font sizes (22–26) in AppBars/empty states
- **Correction:** Prefer theme text styles; test at 1.3–2.0 textScaleFactor.
- **Risk:** Medium (overflow).

---

## P3

### F-030 — Inconsistent AppBar title sizing
- Chats/Friends/Settings use custom 26 bold; Login uses default.
- **Correction:** Shared app bar text theme.

### F-031 — CircleAvatar placeholder only
- Chats list always person icon.
- **Correction:** Initials from email local-part.

### F-032 — Call ended/failed auto-dismiss timing not user-explained
- Phase returns to idle after controller cleanup; may feel abrupt.
- **Correction:** Brief “Call ended” hold (1–2s) before overlay removal.

### F-033 — OTP email shown but not masked option
- Full email on verify screen — acceptable; optional mask middle.

### F-034 — Refresh icon without last-updated time
- Chats/Friends refresh.

### F-035 — Speaker control label always “Speaker”
- Doesn’t reflect earpiece vs speaker state in label (icon does).

### F-036 — No haptic on Accept/Decline
- Optional affordance.

### F-037 — License/crypto notices registered but not linked in Settings
- `registerCryptoLicenseNotices()` in `main.dart` — open-source notice screen missing from UI.

---

## Messaging status mapping (preserve safety)

| Durable outbox (`LocalMessageDelivery`) | UI (`ChatDeliveryState`) | Current label | Proposed user label | Allowed actions |
| --- | --- | --- | --- | --- |
| preparing / encrypting / sending | sending (or blocked if unsafe) | Sending | Sending… | None (disable duplicate send same id) |
| ready (with outbox) | failed | Failed | Couldn’t send | Retry (resubmit same ciphertext) |
| submitting | uncertain | Unconfirmed | Delivery unconfirmed | Resubmit (same ciphertext only) |
| failed | failed | Failed | Couldn’t send | Retry |
| uncertain | uncertain | Unconfirmed | Delivery unconfirmed | Resubmit |
| blocked | blocked | Needs attention | Can’t resend this copy | Compose **new** message only |
| sent | sent | Sent | Sent to server / On its way | None |
| received | received | Received | (incoming) | None |

Do **not** introduce silent automatic retries across these states.

---

## Calling phase clarity checklist

| Phase | UI title today | Gap |
| --- | --- | --- |
| outgoingRinging | Calling… | OK |
| incomingRinging | Incoming call | OK + Accept/Decline |
| connecting | Connecting… | OK |
| connected + verifying | Verifying identity… | Good; keep until auth done |
| connected + authenticated | Duration / Verified… | Video needs top chip + local PiP |
| failed / ended | Call failed / ended | Hold overlay briefly; clear error |

Do not claim background/terminated incoming calling in UI copy.
