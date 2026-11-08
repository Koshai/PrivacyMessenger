# Android Lifecycle, Crash Resilience — Step 19.7.30D

Recorded: 2026-11-07/08 (America/New_York). No message plaintext, tokens, or private keys.

Baseline tip before this milestone: `5cd97865d3a89dfa60ae29ec86ccb1a3ba415664` (30C).

## Devices

| Device | Role | Notes |
| --- | --- | --- |
| SM-S938U (`R5CXC2SA8HJ`) | Established validation install | Session/MLS/history preserved; **no** uninstall/clear/logout |
| Second physical handset | Required for two-device acceptance | **Not attached** |
| Pixel_8_API_36 emulator | Isolated aggressive fault injection | Available; not used against production-like validation accounts |

## Phase 1 — Lifecycle matrix (SM-S938U)

Safe operations only on the established package.

| # | Scenario | Result | Evidence |
| --- | --- | --- | --- |
| 1 | Foreground → Home → foreground | **Pass** | After resume, conversation still showed Send; no unavailable/history wipe |
| 2 | Screen lock → unlock | **Partial** | Power lock reached secure PIN keyguard; automation stopped (no PIN entry). No stuck Hang up while locked. Further UI after unlock blocked until operator unlocks |
| 3 | Recent-apps / task bring-to-front | **Pass** | `am start` brought existing task forward (`Activity not started, its current task has been brought to the front`) |
| 4 | Process termination (`am force-stop`) + cold start | **Pass** | `LaunchState: COLD`, `TotalTime: 196` ms; post-start chat opened with Send; pid restarted; no Sign-in screen |
| 5 | Network loss while backgrounded | **Not run** | Deferred while keyguard held; covered by code (WS backoff) + prior unit paths — mark pending for manual when unlocked |
| 6 | Reopen existing encrypted conversation | **Pass** | After force-stop + bg/fg: Send present; no “Unable to open” / unavailable |
| 7 | Pending outgoing restore | **Code/tests** | Outbox fail-closed matrix (30B); not fault-injected on established account |
| 8 | WebSocket reconnection | **Code** | `RealtimeClient` reconnect + backoff; physical network flap pending |
| 9 | Authentication restoration | **Pass** | Cold start after force-stop remained signed in (Chats path, not OTP) |
| 10 | Repeated ordinary launches | **Pass** | Multiple `am start` cycles; warm bring-to-front WaitTime ~21 ms while locked |

### Startup timings (privacy-safe)

| Metric | Value |
| --- | --- |
| Cold start `TotalTime` (after force-stop) | 196 ms |
| Wall clock around cold start | ~251 ms |
| Warm bring-to-front while keyguard | TotalTime 0 / WaitTime 21 ms |

These are activity launch timings, not first-frame Flutter paint.

## Phase 2 — Messaging persistence under lifecycle

| Risk | Assessment | Notes |
| --- | --- | --- |
| Duplicate local messages | Mitigated | Client message id + history store; server idempotency (see Go e2e) |
| Delete pending outbox | Mitigated | Durable outbox columns; force-stop did not clear app data |
| Re-encrypt uncertain submission | Fail-closed | Missing outbox → blocked; no silent re-encrypt |
| Unsafe MLS advance | Architectural window remains | Separate MLS SQLCipher vs AES history DB (RB-30B-002) |
| Lose committed encrypted history | Not observed | Conversation reopen after process death |
| Replace missing encryption keys | Fail-closed | History key loss throws; no mint |
| Cross-account conversation association | Mitigated | user+device scoped paths (30A tests) |

### Cross-store crash window (unchanged)

If the process dies after MLS ratchet advance and before history/outbox commit:

| Item | Detail |
| --- | --- |
| Consequence | Local send may surface as blocked / non-resendable copy; peer may or may not have ciphertext depending on submit order |
| Detection | Outbox missing bytes + advanced delivery state → blocked UI |
| Safe user behavior | Compose a **new** message (new client id); do not invent ciphertext |
| Future mitigation | Single transactional boundary or write-ahead linkage — **out of scope for 30D** |

## Phase 3 — Calling lifecycle

| Scenario | Status |
| --- | --- |
| Active call foreground / lock / background | Code: `CallHost` → `onAppLifecycle`; paused/inactive/hidden keep call; `detached` hangup |
| Reopen after call / remote hangup backgrounded | Automated 30C; physical two-party **pending** (Device B) |
| System Back | Widget coverage; physical live Back **pending** |
| Repeat / failed then retry | Automated cleanup + auth clear tests |
| Cam/mic after termination | `hangUp` → `_cleanupLocal`; no FCM killed-app incoming (known limitation) |
| Unsupported background/terminated incoming | Documented limitation — must not claim support |

Physical live A/V on updated APKs remains open (RB-30C-*).

## Phase 4 — Memory / battery / performance

| Check | Finding |
| --- | --- |
| Cold / warm launch | See timings above; no ANR observed during lifecycle smoke |
| Open existing conversation | Interactive after cold start (~few seconds including Flutter restore) |
| Large history render | Not separately profiled on device this milestone |
| Tab navigation | Smoke via Chats tap after resume; no hang |
| Extended chat / video memory | Not instrumented (would need two-device + profiler) |
| Post-call resource retention | Automated cleanup tests; physical cam LED not verified this run |
| WS reconnect loops | Client uses backoff Timer; no evidence of tight loop in smoke |
| Background polling | No third-party crash/analytics SDK; no evidence of aggressive pollers |

No speculative optimizations applied.

## Phase 5 — Crash / diagnostics

| Item | Finding |
| --- | --- |
| Uncaught Flutter handler | Default Flutter error path; no custom `FlutterError.onError` / zoned handler in `main.dart` |
| Third-party crash SDK | **None** (do not add without approval) |
| Sensitive logs | Prefer stage timings (`DeliveryTiming`) over content; MLS diagnostics avoid plaintext |
| User-facing errors | `AppErrorPanel` / outbox labels / call failure copy from 29–30C |
| Fatal vs connectivity | Outbox uncertain/failed vs blocked; call failed phases distinguishable |
| Local DB failure | Fail-closed history UI; no destructive auto-reset |
| Auth loops | Cold start restored session; no repeated OTP observed |

**Proposal (not implemented):** privacy-preserving local diagnostic export (versions, phases, opaque ids, timings) — requires explicit approval.

## Phase 6 — Release configuration audit

| Item | Value / finding |
| --- | --- |
| applicationId | `com.privatemessenger.private_messenger` |
| versionName / versionCode | `1.0.0` / `1` |
| minSdk / targetSdk (installed) | 24 / 36 |
| Release signing | **Debug** keystore (intentional validation share) |
| Cert SHA-256 | `b694351d88992798ea347584901d77247591010cbcec4e77a2d115be4a803e85` |
| Installed vs built release APK | Same Android Debug identity (safe for `-r` if ever needed) |
| Debuggable (installed package) | Debug-signed validation build; treat as non-store |
| minify / shrink | **Disabled** — no R8 behavior change |
| Permissions | INTERNET, RECORD_AUDIO, CAMERA, MODIFY_AUDIO_SETTINGS, ACCESS_NETWORK_STATE, BLUETOOTH(+CONNECT), POST_NOTIFICATIONS, FGS mic/camera |
| Network security config | None custom; HTTPS validation host |
| Natives | OpenMLS/SQLCipher, flutter_webrtc, sqflite history |
| ABI | Device `arm64-v8a`; universal release APK ~117.2 MB; arm64 split ~39.5 MB |
| Backend env for inspect build | `APP_ENV=validation`, `API_BASE_URL=https://privacymessenger-test.duckdns.org` |
| Secrets in APK | No DATABASE_URL / OTP / TURN secrets in dart-defines |
| Inspect APK | Built **without** installing on SM-S938U |

## Phase 7 — Go concurrency

| Suite | DB | Result |
| --- | --- | --- |
| `internal/messaging` memory concurrent identical + conflict | In-memory | **PASS** |
| `internal/e2e.TestEnvelopeIdempotencyConcurrentIdenticalAndConflict` | Local disposable `127.0.0.1` / `private_messenger` (`private-messenger-postgres`) | **PASS** (identical replay + conflicting ciphertext) |
| Hosted validation DB | Not used | — |

## Accessibility (physical)

TalkBack / large-font / OTP / call-control smoke on SM-S938U after the lock test is **blocked by secure PIN keyguard** (operator unlock required). Code-level a11y from 29E remains; physical 30D a11y = **Incomplete**.

## Explicit non-actions

- No APK install on established Samsung this milestone
- No publish / distribution
- No MLS redesign, schema, or backend deploy
- No Device B matrix execution
