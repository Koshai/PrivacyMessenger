# Data Preservation Audit — Step 19.7.30A

## What survives an ordinary in-place APK update

| Asset | Location / mechanism | Survives `adb install -r`? |
| --- | --- | --- |
| Auth session token | FlutterSecureStorage (`SecureSessionStore`) | Yes, if package + signing unchanged |
| MLS identity + SQLCipher DB key | FlutterSecureStorage (`DeviceCryptoStore`) | Yes |
| MLS group state DB | App support `mls_{user}_{device}.db` (SQLCipher) | Yes |
| Encrypted message history | App support `messages_{user}_{device}.db` (AES-GCM fields) | Yes |
| History AES key | FlutterSecureStorage keyed by user+device | Yes |
| Peer conversation index | Sidecar `messages_….peers.json` | Yes (ids only) |
| App preferences / files under dataDir | `/data/user/0/com.privatemessenger.private_messenger` | Yes |

**Observed after 30A update on SM-S938U:** signed-in Chats shell remained; friend/chat rows still listed; Settings About/licenses reachable. No decryptability probe of individual message bodies was automated (manual open of a thread still recommended before RC).

## Actions that permanently lose decryptability (do not run on established accounts)

| Action | Effect |
| --- | --- |
| Confirmed **Log out** | Revokes/clears session; `MlsSessionManager.clearOnLogout` / `DeviceCryptoStore.clearOnLogout` remove MLS keys; new login mints a **new** encryption identity; prior history files may remain but are not readable with new keys |
| **Clear saved sign-in** (auth unavailable path) | Clears local session; does not by itself wipe MLS, but leaves user without a session |
| Uninstall / clear app data | Deletes secure storage + on-disk DBs |
| Install with **different signing certificate** | Android refuses update; forcing uninstall destroys data |
| Change `applicationId` | Treated as a different app |
| Missing/corrupt history key while DB file present | `MessageHistoryKeyLossException` — open fails **without** minting a replacement key |
| Schema **downgrade** | Throws `MessageHistorySchemaException` (non-destructive fail-closed) |

## Risk matrix

| Risk | Severity | Notes |
| --- | --- | --- |
| User logs out expecting history to remain readable | High (UX/security expectation) | Current design intentionally destroys key access; copy documents this |
| Peer index leftover after logout | Low–Med | Sidecar is path-scoped by user/device; new device id → new file. Not wiped on logout |
| Cross-account history read | Low (mitigated) | Paths and secure-storage key names are length-prefixed user+device scoped; covered by solidification tests |
| Destructive recovery on DB open failure | Low (mitigated) | Failures surface history-unavailable UI with Retry / Log out — no auto wipe |
| Signing identity replacement | Critical if done casually | Would block `-r` updates; requires coordinated reinstall + data loss |

## Account isolation summary

- History DB path: `messages_{userId}_{deviceId}.db`
- MLS DB path: `mls_{userId}_{deviceId}.db`
- Peer index: beside history DB
- Secure storage keys include explicit length-prefixed user and device segments

## Update prerequisites (validated this milestone)

1. Same `applicationId`
2. Matching signing certificate SHA-256
3. Compatible ABI (`arm64-v8a` on SM-S938U)
4. Non-destructive installer: `adb install -r` only
