# .planning

Historical build record for phases 1 to 4 (2026-03 to 2026-06). **Reference only, and partly out of date.**

Everything here has been superseded by the post-audit work of 2026-08-01. The archive is kept because it records *why* decisions were made, which the code cannot. It is not a description of how the app works now.

## Where to look instead

| For | Read |
|---|---|
| How the system fits together | [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) |
| The carving score design of record | [docs/CARVING-SCORE.md](../docs/CARVING-SCORE.md) |
| Evidence behind the score | [docs/RESEARCH.md](../docs/RESEARCH.md) |
| The audit that drove the current state | [docs/AUDIT.md](../docs/AUDIT.md) |
| What still needs proving on snow | [docs/FIELD-VALIDATION.md](../docs/FIELD-VALIDATION.md) |
| Working rules for this repo | [CLAUDE.md](../CLAUDE.md) |

## Known inaccuracies in the archive

Recorded so nobody trusts these files as current:

- `archive/REQUIREMENTS.md` marks all 22 v1 requirements Complete. Three of them were complete on paper and dead in the shipped app: HIST-02 resort geocoding had no caller and no stored coordinate, SESS-05 orphan recovery only cleared a sentinel, and the Today stats row was hardcoded dashes. All three work now; the amendments are noted inline in that file.
- `archive/PROJECT.md` says iOS 18+ and Swift 7. The real target is iOS 26.2 and Swift 6.
- `archive/STATE.md` contradicted itself for months, claiming both 100 percent complete and Phase 1 in progress. Corrected before archiving.
- Phase summaries describe metrics that have since been removed for honesty reasons, notably "carve pressure" (a raw device axis, now a gravity-projected vertical load) and pitch-derived vertical drop (now barometric or nil).

`config.json` stays at the top level because the tooling reads it.
