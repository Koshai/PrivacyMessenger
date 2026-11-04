# PrivacyMessenger MVP Status

**Updated:** 2026-11-03  
**Repository:** https://github.com/Koshai/PrivacyMessenger  
**Remote `origin/master`:** see `docs/E2EE_C4_REPORT.md` for exact C4 SHA after push  
**Prior HEAD:** `1ad22da` — *C3 completed*

## Milestone progress

| Milestone | Status |
| --- | --- |
| A — Auth | Complete |
| B — Friends | Complete |
| C — E2EE | **C4 verification complete locally; Milestone C complete only after remote CI green** |
| D — Calls | Not started — stop for review |
| E — Release | Not started |

## C4 gates

| Gate | Result |
| --- | --- |
| `flutter analyze` / `flutter test` | Pass (90 + 1 skipped without live env) |
| Live two-client native OpenMLS ↔ API ↔ Postgres | **Pass** locally; CI job `live-e2e` |
| `go test ./...` + Postgres e2e + concurrent seq | Pass |
| `govulncheck` on Go 1.26.10 | Pass (0 vulns) |
| WS auth bounds / TLS / origin / token redaction | Implemented + tested |
| Enrollment lifecycle states | Implemented + tested |
| Android emulator OpenMLS suite | Pass |
| iOS | macOS CI `ios-compile` + OpenMLS unit tests (gate via Actions) |
| GitHub Actions | Must be green on C4 commit before calling C complete |

## Logout / history policy

Logout destroys MLS keys and marks enrollment **revoked**. Local encrypted DB ciphertext may remain but cannot be decrypted. Re-login enrolls a **new** identity — prior history is not recoverable. See `docs/E2EE_C4_REPORT.md`.

## Next

Review C4 + confirm remote CI green → product sign-off on Milestone C → only then Milestone D.
