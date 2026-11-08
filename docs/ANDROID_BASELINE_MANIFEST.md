# Android Baseline Manifest — Step 19.7.30A

Recorded: 2026-11-07 (America/New_York). No secrets, tokens, or message bodies included.

## Source / tooling

| Item | Value |
| --- | --- |
| Git commit (pre-30A docs/tests) | `eb73f75119d613dbb2ab30419b96b7574e0b6a99` |
| Flutter | 3.47.8 (stable) |
| Dart | 3.13.7 |
| Android SDK | 36.0.0 |
| Build-tools | 36.0.0 |
| Host OS | Windows 10.0.26200 |

## Application identity

| Item | Value |
| --- | --- |
| `applicationId` / namespace | `com.privatemessenger.private_messenger` |
| `versionName` / `versionCode` | `1.0.0` / `1` (from `pubspec.yaml` / Flutter) |
| `minSdk` / `targetSdk` (installed) | 24 / 36 |
| Build type used for update | `release` with **debug signing** (intentional for validation sideloads; see `android/app/build.gradle.kts`) |
| Minify / shrink | Disabled for share/validation APKs |
| Debuggable (installed) | Yes (`DEBUGGABLE`) |

## Signing (public fingerprints only)

| Item | Value |
| --- | --- |
| Certificate DN | `C=US, O=Android, CN=Android Debug` |
| SHA-256 | `b694351d88992798ea347584901d77247591010cbcec4e77a2d115be4a803e85` |
| SHA-1 | `6a1edc80010d129bdf26c7ac3db7ec2cc3540302` |
| Pre-update installed APK | Same SHA-256 (match confirmed before `adb install -r`) |
| Post-update APK | Same SHA-256 |

**Policy:** Do not replace this signing identity without an explicit migration plan for existing devices.

## Native / ABI

| Item | Notes |
| --- | --- |
| Connected device ABI | `android-arm64` (SM-S938U) |
| Packaged natives | OpenMLS (SQLCipher-backed MLS DB), `flutter_webrtc`, SQLite via `sqflite` for history |
| History DB | AES-GCM ciphertext in ordinary SQLite (`messages_{user}_{device}.db`) — **not** the MLS SQLCipher file |
| MLS DB | `mls_{user}_{device}.db` under application support, keyed via secure storage |

## Validation endpoint

| Item | Value |
| --- | --- |
| Hosted API | `https://privacymessenger-test.duckdns.org` |
| Client defines used for 30A APK | `APP_ENV=validation`, `API_BASE_URL=https://privacymessenger-test.duckdns.org` |
| WebSocket | `wss://…/realtime/ws` (scheme swap from https) |

## Schema / storage versions

| Store | Version / key |
| --- | --- |
| Local message history schema | `LocalMessageStore.schemaVersion = 4` (additive migrations only; downgrade throws) |
| History key slot | `message_history_key_v1.{len}.{userId}.{len}.{deviceId}` in FlutterSecureStorage |
| Peer index sidecar | `{historyDb}.peers.json` (opaque ids only; no message plaintext) |

## Connected devices (ADB at audit time)

| Serial | Model | Role |
| --- | --- | --- |
| `R5CXC2SA8HJ` | SM-S938U (Galaxy S25 Ultra family) | Updated in place (`adb install -r`) |
| Second validation handset | **Not attached** | Two-device smoke incomplete |

## Automated test baseline (post-30A)

| Check | Result |
| --- | --- |
| `flutter analyze` | Expected clean (re-run in 30A completion) |
| `flutter test` | Expected ≥305 + new solidification cases |

## Update action performed

| Step | Result |
| --- | --- |
| Signature compare installed vs new | Match |
| `adb install -r` | Success |
| `lastUpdateTime` | Advanced to 2026-11-07 23:17:41 |
| Cold start after update | Process alive; MainActivity shown |
| Session after update | Still authenticated (Chats shell; contacts visible) — **no logout / clear data** |

## Explicit non-actions

- No uninstall, clear data, Clear saved sign-in, or logout on the physical device
- No MLS identity regeneration
- No backend deploy
- No package id or signing certificate change
