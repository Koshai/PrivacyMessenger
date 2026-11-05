# PrivacyMessenger MVP Status

**Updated:** 2026-11-05  
**Repository:** https://github.com/Koshai/PrivacyMessenger  
**D6:** calling reliability, security corrections, and platform verification are ready for review. Milestone D stays open. D7 is not started.

## Milestone progress

| Milestone | Status |
| --- | --- |
| A — Auth | Complete |
| B — Friends | Complete |
| C — E2EE | **Complete (C4)** |
| D — Calls | **D1.1–D6 ready for review** — D7 not started; Milestone D **not** complete |
| E — Release | Not started |

## D6 limits

Identity pins are not overwritten. Production calls require an enrollment check and hang up if that check later fails. The MLS call-key binding is exercised by two live OpenMLS clients. Terminated-process incoming calls remain unsupported. Physical iPhone testing and several Android device behaviors are release dependencies. Reports: `docs/CALLING_D6_REPORT.md`, `docs/CALLING_TEST_MATRIX.md`, `docs/CALLING_SECURITY_REGRESSION.md`.

## Next

Review D6 before **D7**. Do not mark Milestone D complete.
