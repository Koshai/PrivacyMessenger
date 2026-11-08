# UX component guidelines — Step 19.7.28

Prefer Flutter Material 3 and patterns already in the app (`SnackBar`, `MaterialBanner`, `FilledButton`, `NavigationBar`, `InputDecorationTheme` from `AppTheme.light`).  
**Do not** add a third-party UI kit unless a later milestone proves a gap Material cannot fill.

## When to use which surface

| Surface | Use for | Do not use for |
| --- | --- | --- |
| **SnackBar** | Brief noncritical confirmation (friend request submitted, blocked, copy copied) | Destructive confirms; multi-step errors; ongoing outage |
| **MaterialBanner / top banner** | Ongoing connectivity, key-change warning, reconnecting | One-shot success |
| **Dialog (`AlertDialog`)** | Destructive or irreversible decisions (logout, remove friend, hang-up confirm on back) | Routine send failures (prefer inline) |
| **Bottom sheet** | Optional explanations (“Why can’t I resend?”), action sheets for friend overflow | Hard blockers that need a decision (use dialog) |
| **Inline text** | Field validation, per-bubble delivery errors | App-wide outages |
| **Full-screen status** | Auth checking, history unavailable, call overlay | Minor errors |
| **Overlay (calls)** | Active call only (`CallHost`) | Ordinary navigation |

## Recommended reusable wrappers (implement in 19.7.29+)

Keep thin wrappers in e.g. `mobile/lib/core/ui/` — no new packages.

| Component | Responsibility | Notes |
| --- | --- | --- |
| `AppConfirmDialog` | Title, body, Cancel, destructive Confirm | Used by logout, remove, block, hang-up-on-back |
| `AppErrorPanel` | Icon + message + primary Retry + optional secondary | Chats load error, conversation error, auth unavailable |
| `AppEmptyState` | Icon + title + body + optional CTA button | Chats empty, friends empty, conversation empty |
| `ConnectivityBanner` | Listens to API/WS health; non-modal | Dismissible only when back online |
| `MessageStatusText` | Maps `ChatDeliveryState` → user strings + optional action | Single source; update `deliveryStatusLabel` |
| `CallStatusHeader` | Phase + duration + auth subtitle | Shared audio/video |
| `PermissionRationaleSheet` | Why mic/camera needed + Open settings | Before or after denial |
| `LoadingButton` | Disables + progress on async submit | Login, OTP, logout already partially pattern this |
| `DestructiveMenuButton` | Labeled overflow for friend actions | Replaces icon-only remove/block |

## Message status presentation

- Show status with **text**, not color alone (colorblind-safe).
- Pair Failed / Unconfirmed with a single safe action button.
- For Blocked: never show Retry; show “Type a new message” guidance.
- Never show tokens, MLS epoch, wire bytes, or raw stack traces in UI.

## Call status presentation

| User-visible state | Required cues |
| --- | --- |
| Ringing out | “Calling…” + Cancel |
| Ringing in | “Incoming call” + Accept/Decline (large targets ≥48dp) |
| Connecting | “Connecting…” + Hang up |
| Verifying | “Verifying identity…”; remote video hidden until authenticated |
| Connected | Duration + mute/speaker/(camera) + Hang up |
| Failed / ended | Clear title + short reason + auto-dismiss after brief hold |

Labels on call buttons already use `semanticLabel` / tooltip (`_RoundButton`) — preserve and extend.

## Copy tone

- Short sentences; action verbs (“Try again”, “Send again”, “Open settings”).
- Avoid: MLS, epoch, ciphertext, DTLS, ratchet, SDP, ICE (diagnostics only).
- Prefer: encrypted, verification code, safety number, delivery unconfirmed, connection lost.

## Theming

- Continue `ColorScheme.fromSeed` teal (`0xFF176B60`).
- Use theme text styles instead of one-off `fontSize: 26` where practical (Batch E).
- Minimum touch target 48×48; existing elevated button `minimumSize` height 56 is good — align IconButtons.
- Easy Mode: if kept, apply a documented `textScaler` / larger `VisualDensity`; do not ship an inert switch.

## Accessibility checklist for new components

- `Semantics` labels on icon-only controls
- Focus order: title → primary field → primary button
- Errors announced via `SnackBar` or `Semantics.liveRegion` for status changes
- Contrast: body text on white / on primaryContainer meets WCAG AA where feasible
- Verify at system font scale 1.0, 1.3, 1.5, 2.0 on a small phone width
