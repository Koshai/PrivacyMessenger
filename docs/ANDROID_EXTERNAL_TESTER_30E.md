# External Tester Instructions — Step 19.7.30E

Short checklist for a second Android phone. **No ADB or developer tools required.**

Use only non-sensitive test messages (for example: `test-A1`, `test-B1`).  
**Do not** send OTP codes, passwords, private keys, or real personal conversation contents in reports.

## Before you start

1. Install or open **Private Messenger** on your phone (validation build provided by the project owner).
2. Stay signed in if you already have an account. **Do not** log out, clear app data, or uninstall unless the owner asks.
3. Confirm you can open **Chats**, **Friends**, and **Settings**.
4. Confirm you can open a conversation with the other tester and still read older messages (if any existed).

## What to report (fill in)

| Field | Your answer |
| --- | --- |
| Android model | |
| Android version | |
| App version (Settings → About if shown; else “unknown”) | |
| Network during tests (Wi-Fi name type / cellular) | Wi-Fi / cellular / both |
| Already signed in when opened? | Yes / No |
| Existing conversations still openable? | Yes / No / N/A |
| Approximate install time / who gave you the APK | |

## Messaging tests

Coordinate with Device A (Samsung validation phone). Use short throwaway text only.

| Step | Action | Pass? | Notes (no message bodies) |
| --- | --- | --- | --- |
| M1 | A sends one test message → you receive it | | Content match? Yes/No |
| M2 | You send one test message → A receives it | | Content match? Yes/No |
| M3 | Exchange 5 messages in a row (mixed directions) | | Missing or duplicate bubbles? |
| M4 | Press Home, wait 10s, reopen app | | Older messages still readable? |
| M5 | Turn on Airplane Mode, try send, then restore network | | Status honest? Retry works? |

Do **not** treat “Sent to server” as proof the other phone received the message.

## Audio call tests

| Step | Action | Pass? | Notes |
| --- | --- | --- | --- |
| A1 | A calls you (audio); you accept | | Both hear each other? |
| A2 | Mute / unmute on both phones | | |
| A3 | Speaker on/off (as available) | | |
| A4 | You hang up; confirm call UI clears | | Mic stops? |
| A5 | You call A (audio); A accepts; A hangs up | | Both hear? Cleanup? |
| A6 | Repeat successful audio calls (goal: several in a row) | | Count success / fail |

## Video call tests

| Step | Action | Pass? | Notes |
| --- | --- | --- | --- |
| V1 | A calls you (video); accept | | See remote video + hear audio? |
| V2 | Local preview appears when expected | | |
| V3 | Camera off / on | | |
| V4 | Flip camera (if available) | | |
| V5 | System Back → cancel keeps call; confirm ends call | | |
| V6 | Reverse direction (you start video) | | |
| V7 | Another call after hangup works | | Count success / fail |

## Network (optional)

| Step | Action | Pass? | Notes |
| --- | --- | --- | --- |
| N1 | Call while each phone is on a different Wi-Fi | | |
| N2 | One phone on cellular | | |
| N3 | Brief Airplane Mode during a call | | Clean end or clear failure? |

## What not to include in reports

- OTP codes, passwords, recovery codes  
- Private keys or screenshots of safety-number QR that identify real users beyond “verified/unverified”  
- Message plaintext from real conversations  
- Session tokens or API URLs with secrets  

## How to send results

Return this filled table (or a photo of a printed checklist) to the project owner. Mark any step **Fail** with a short reproduction note.
