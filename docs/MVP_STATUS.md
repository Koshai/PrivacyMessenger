# PrivacyMessenger MVP Status

**Updated:** 2026-11-03  
**Repository:** https://github.com/Koshai/PrivacyMessenger  
**Remote `origin/master` HEAD:** `cff4c95` — *Milestone C2ready*  
**Local:** uncommitted **Milestone C3** verification work (WebSocket handshake, durable seq, DeviceCryptoStore enrollment marker, E2E harness, CI)

## Milestone progress

| Milestone | Status |
| --- | --- |
| A — Auth | Complete |
| B — Friends | Complete |
| C — E2EE | **C1+C2 on remote; C3 local for review — Milestone C not complete** (iOS unwaived) |
| D — Calls | Not started |
| E — Release | Not started |

## C3 gates (executed locally)

| Gate | Result |
| --- | --- |
| `flutter analyze` / `flutter test` | Pass |
| `go test` incl. `internal/e2e` + Postgres | Pass |
| Migrations 000006 + 000007 on Docker Postgres | Applied |
| WS query-token rejected; auth handshake | Pass |
| No silent identity regeneration | Pass |
| iOS | **Outstanding / unwaived** |
| GitHub Actions | Workflow added; not yet run remotely |

## Logout / history policy (C3)

Logout wipes MLS keys from secure storage. Local encrypted DB ciphertext may remain but cannot be decrypted. Re-enrollment creates a new identity — **prior history is not recoverable**. See `docs/E2EE_C3_REPORT.md`.

## Next

Review C3 → decide iOS waiver vs macOS run → commit/push C3 → only then Milestone D.
