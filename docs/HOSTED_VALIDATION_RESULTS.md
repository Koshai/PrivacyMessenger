# Hosted validation results

**Milestone D:** open
**Milestone E:** not started
**Hosted environment exercised:** no
**External TURN exercised:** no
**Capacity decision:** not made

Rows stay "not run" until the command or the device check actually happens. This page is updated in the same change as the local preparation commands. It is not a VPS report.

## Not run, because no VPS or DNS change was approved

- OTP email delivery through a real SMTP account
- HTTPS certificate issuance
- WebSocket upgrade through the public name
- Two-device messaging and calling
- Relay-only media on an external network
- Wi-Fi to mobile data
- Physical Android and iPhone lifecycle rows
- Backup restore on the VPS
- RAM, disk, CPU, and relay measurements on the VPS

## Local preparation commands

These ran on the developer workstation. They do not exercise OVHcloud, DNS, SMTP delivery, or an external relay.

| Command | Result | Notes |
| --- | --- | --- |
| `go test ./...` with the local database URL | Pass | Every package `ok` |
| `flutter analyze` | Pass | No issues |
| `flutter test` | Pass | 155 passed, 0 failed. The summary did not report a skip |
| Live OpenMLS harness | Pass | `flutter test test/integration/live_two_client_e2e_test.dart` with `LIVE_E2E=1` against `http://127.0.0.1:4010`: 1 passed |
| TURN relay integration | Skipped | `TestRelayOnlyDataChannel` skipped because `TURN_RELAY_TEST` is unset. The other `internal/turn` tests passed |
| `docker compose config` | Pass | API and PostgreSQL publish no ports. Caddy publishes 80 and 443. coturn publishes 3478 and UDP 49160-49260 |
| API image build | Pass | `golang:1.26.10-bookworm` multi-stage image, 91.8 MiB. `useradd --system` warned that uid 65532 is above `SYS_UID_MAX`; the user was still created and the container ran as that user |
| Validation Postgres, migrate, health | Pass | Local only. First start healthy in 16.6 seconds. Migrations 2.2 seconds. Second migrate skipped all 10 files. `GET /health` returned `{"status":"ok"}`. A 15-character TURN secret made the API exit; a 16-character secret started |
| Isolated restore | Pass | Local throwaway volume. Custom-format dump restored into `private_messenger_restore` with 10 recorded migrations. The volume was then deleted. This is not a VPS restore |
| Caddy | Syntax pass, not started | `caddy validate` on `caddy:2.8.4` reported `Valid configuration` for the placeholder domain. It did not obtain a certificate |
| coturn process | Not started | Template and compose ports were reviewed. No relay allocation was made |
| Android debug build | Pass | `flutter build apk --debug` with `APP_ENV=validation` and `API_BASE_URL=https://api.example.com`. Gradle warned that `flutter_webrtc` still applies the Kotlin Gradle Plugin. The APK was produced |
| iOS compile | Not run here | This workstation has no Xcode. GitHub Actions `ios-compile` is the check |

## Follow-up checks

Re-run on the developer workstation after the migration and backup changes. Still not a VPS result.

| Command | Result | Notes |
| --- | --- | --- |
| `go test ./... -count=1` | Pass | Every package `ok` |
| `go test ./internal/turn -count=1 -v` | Pass, one skip | `TestRelayOnlyDataChannel` skipped because `TURN_RELAY_TEST` is unset |
| `flutter analyze` | Pass | No issues |
| `flutter test` with `LIVE_E2E=1` | Pass | 155 passed, 0 failed |
| `deploy/scripts/migrate_regression.sh` | Pass | A failing file rolled back its table and wrote no ledger row. Terminating `psql` during `pg_sleep` did the same. The following run applied that filename |
| `deploy/scripts/backup_regression.sh` | Pass | AES-256-CBC ciphertext restored marker id 7 into `backup_dst`. Retention kept the 14-day file and the newer weekly file, and deleted the older weekly file and the 90-day file. A local target without `BACKUP_ALLOW_LOCAL_DRILL=1` was refused |
| `docker compose config` | Pass | Validation compose still parses |

UDP-only TURN relay is an intentional validation choice. External UDP relay, TCP relay, and TURN TLS were not run.

## Security notes for this preparation

- No production password, SMTP password, OTP secret, or TURN secret is in the commit.
- Validation clients must use HTTPS. The API process behind Caddy stays on private HTTP with `APP_ENV=validation`.
- Call-binding lookup scope and the MLS inbox crash window are unchanged. Both fail closed. Severity is medium. See `docs/HOSTED_INFRASTRUCTURE_AUDIT.md`.

## Resource notes for this preparation

Container ceilings and PostgreSQL settings are planning controls. They are not a capacity pass. See `docs/HOSTED_RESOURCE_BUDGET.md`.
