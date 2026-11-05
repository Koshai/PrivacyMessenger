# PrivacyMessenger MVP Status

**Updated:** 2026-11-05  
**Repository:** https://github.com/Koshai/PrivacyMessenger  
**D7:** acceptance review is ready for review. Milestone D stays **open**. Milestone E has not started.

## Milestone progress

| Milestone | Status |
| --- | --- |
| A — Auth | Complete |
| B — Friends | Complete |
| C — E2EE | **Complete (C4)** |
| D — Calls | **D1.1–D7 ready for review** — Milestone D **not** complete |
| E — Release | Not started |

## Acceptance recommendation

Do not mark Milestone D complete. Automated regressions can be green while physical-device calling and production TURN are still open. Terminated-app incoming calls are an accepted MVP constraint and are not terminated-app delivery.

Reports: `docs/CALLING_D7_REPORT.md`, `docs/CALLING_RELEASE_CHECKLIST.md`, `docs/CALLING_KNOWN_LIMITATIONS.md`.

## Next

Review D7. Do not start Milestone E and do not mark Milestone D complete until the open blockers in the checklist are accepted or closed.
