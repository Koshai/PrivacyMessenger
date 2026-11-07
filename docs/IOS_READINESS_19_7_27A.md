# Step 19.7.27A — iOS readiness and hosted macOS build

Status: compile-validation milestone. An unsigned CI success does **not** mean the app installs on a tester iPhone.

Validation API for hosted client builds:

```text
https://privacymessenger-test.duckdns.org
```

Example:

```sh
flutter build ios --release --no-codesign \
  --dart-define=APP_ENV=validation \
  --dart-define=API_BASE_URL=https://privacymessenger-test.duckdns.org
```

## Compatibility matrix

| Component | Current implementation | iOS compatibility | Missing work | Risk | Verification |
| --- | --- | --- | --- | --- | --- |
| Flutter `ios/` project | Present (`Runner`, SPM plugin package, no Podfile) | Complete for Flutter SPM apps | Keep SPM path; do not add Podfile without workflow update | Low | `flutter build ios --no-codesign` on macOS |
| Flutter / Dart | Flutter 3.47.8 / SDK `^3.13.7` | Compatible | Pin CI to 3.47.8 | Low | `flutter --version`, analyze |
| Bundle ID / deploy target | `com.privatemessenger.privateMessenger`, iOS 15.0 | OK for modern plugins | Register ID in Apple Developer portal for TestFlight | Low (tech) / High (membership) | Xcode project settings |
| Display name | `Private Messenger` | OK | App Store metadata later | Low | Info.plist |
| OpenMLS (`openmls` 3.3.0) | FRB hook downloads `ios-device-arm64`, `ios-simulator-arm64`, `ios-simulator-x86_64` | Declared `platforms: ios`; prebuilts | Confirm SHA-verified download in CI logs; no local Rust cross-compile required for release binaries | Medium if release assets missing | Hosted build + OpenMLS unit tests |
| MLS protocol / serialization | Shared Dart+Rust path with Android | Same wire format | Do not regenerate Android identities | High if changed | Existing crypto tests |
| Message history | `sqflite` + AES-GCM; key in secure storage | Works on iOS (not SQLCipher) | Device Keychain persistence test | Medium | Unit tests + later device test |
| MLS encrypted DB | Rust SQLCipher-backed store inside OpenMLS | Linked via native lib | Real-device recovery after relaunch | Medium | OpenMLS lifecycle tests + device |
| Secure storage | `createAppSecureStorage()` with `IOSOptions(first_unlock_this_device)` | Explicit Keychain accessibility | Physical Keychain after reboot/unlock | Medium | Code review + device |
| `flutter_webrtc` 1.6.3 | Plugin via Flutter SPM | Supported by package | Mic/camera on device; audio session with CallKit | Medium–High | Device call test |
| CallKit / audio | `AppDelegate` CXProvider + AVAudioSession | Present for foreground/active call UX | PushKit / VoIP push **not** implemented | High for terminated-app incoming | Code inspection |
| Background modes | `audio`, `voip` in Info.plist | Declared | `voip` without PushKit may be rejected at App Review; does **not** enable killed-app ringing | High (product claim) | Document only until PushKit |
| Camera / mic strings | Present in Info.plist | Required | None for compile | Low | Info.plist |
| Local network (WebRTC) | `NSLocalNetworkUsageDescription` + Bonjour STUN/TURN | Needed on iOS 14+ | Confirm prompts on device | Low | Device |
| TLS / validation API | `ApiConfig` requires https for `validation` | ATS default; no arbitrary loads | Use dart-defines only | Low | `api_config_test.dart` |
| Android-specific logic | Loopback `10.0.2.2` only when `APP_ENV=local` and Android | iOS local uses `127.0.0.1` | None for validation builds | Low | `api_config_test.dart` |
| CocoaPods | Not used (SwiftPM) | N/A | Workflow fails if Podfile appears | Low | `ios-validation.yml` |
| Hosted macOS CI | `.github/workflows/ios-validation.yml` + existing `ci.yml` `ios-compile` | Available on `macos-latest` | Runner minutes / quotas | Medium (ops) | workflow_dispatch |

## OpenMLS iOS targets

The `openmls` 3.3.0 build hook selects:

| Target | Artifact name |
| --- | --- |
| Device arm64 | `ios-device-arm64` |
| Simulator arm64 | `ios-simulator-arm64` |
| Simulator x86_64 | `ios-simulator-x86_64` |

Libraries are downloaded from GitHub Releases (`djx-y-z/openmls_dart`) with SHA-256 verification. An XCFramework is not produced by this app; Flutter code assets register the static/dynamic library for the active SDK.

Do **not** replace OpenMLS, regenerate Android MLS identities, or change message formats for iOS.

## Keychain / storage notes

- Session tokens, device crypto material, history DEK, and call-auth seeds use `createAppSecureStorage()`.
- iOS accessibility: `KeychainAccessibility.first_unlock_this_device` (device-bound, available after first unlock).
- History ciphertext remains in the app sandbox SQLite file; only the DEK is in Keychain.
- Logout still wipes keys per existing C3/C4 policy; do not clear production tester Android data when validating iOS.

## Explicit non-claims

- Unsigned `--no-codesign` builds are not installable on external tester iPhones.
- Simulator success does not prove microphone, camera, Keychain persistence, MLS recovery, or WebRTC media.
- `UIBackgroundModes` `voip` does not implement terminated-app incoming calling without PushKit + server push.
- No TestFlight / App Store distribution in this step.

## Hosted workflow

Path: `.github/workflows/ios-validation.yml`

- Trigger: `workflow_dispatch`, and PRs touching mobile/iOS paths
- Runner: `macos-latest`
- Flutter: pinned `3.47.8`
- Builds: `flutter build ios --release --no-codesign` (validation dart-defines) and simulator debug
- Artifacts: log text only under `mobile/build/ios-validation-logs/` (no IPA publish, no signing material)
