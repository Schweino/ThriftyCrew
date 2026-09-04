# BRIEF: remove every hard-coded macro band - the band is Brad's, per run

queue_id: no-hardcoded-bands-2026-09-04
shipped_commit: (none yet - if this field names a commit, the work is DONE: verify it and report,
do not rebuild)
author: Opus 5, 2026-09-04, from a survey run the same day.
ruled by: Brad, 2026-09-04: "We need to remove ALL hardcoded bands. The bands are specified by me
per-run. They could fluctuate or have different conditions, so should never be hard coded."

## 0. Read these first

1. `resolve_band` in `meal-prep\pipeline\hunt-daemon.py` (~line 8136). It ALREADY implements the
   doctrine: "NOTHING supplies a default - a band nobody typed is a band nobody agreed to, and two
   gates would enforce it silently for the whole run." Every edge is separately optional, and an
   unstated edge is UNBOUNDED rather than a refusal (Brad, 2026-08-24 evening).
2. `resolve_conditions` immediately above it. Its docstring records the exact defect this brief
   finishes: a run minted at 450-700 cal / <= 40 carbs told its machine gate one band and every agent
   a DIFFERENT one, in prose, silently - and on hunt-2026-08-27-ten the mapper reported a "CONDITION
   BREACH ... fails this run's 35 g ceiling" against a run whose ceiling was 40.
3. `design\OPEN-ITEMS-recipe-hunter-2026-08-24.md` section 5.1. It says harvest.py hard-codes the
   band at ingest. **That entry is STALE** - see section 2 below. Do not build from it.

## 1. What is actually still hard-coded, surveyed 2026-09-04

| where | state | verdict |
|---|---|---|
| `resolve_band` | supplies no default; unstated edge is unbounded | ALREADY CORRECT, leave it |
| `resolve_conditions` -> `DEFAULT_COND` | **falls back to a built-in band, in PROSE** | the real target |
| `DEFAULT_BAND` (hunt-daemon:113) | `self.band = dict(band or DEFAULT_BAND)` in `__init__` | the second target |
| `harvest.py` `BAND_CAL_MIN/MAX/CARB_MAX` | **inert** - `band_at_ingest` defaults False and no production caller sets it | dead constants, remove |

**The prose side is the live defect.** `self.conditions` is rendered verbatim into three agent prompts
(hunt-daemon lines ~4078, ~5964, ~7366 - the mapper, the writer and the auditor). A run dir that
states no conditions falls back to `DEFAULT_COND`, whose text names "between 350 and 650 calories per
serving AND 35 g carbohydrate or less". The machine gate obeys the run's real band; the agents are
told this one. The estate fixed this on the machine side and left its twin standing.

**And the fallback's own warning misreports itself.** `resolve_conditions` returns the message
"falling back to the built-in default, whose prose names a 400-650 cal / 35 g carb band" while
`DEFAULT_COND` says **350**-650 (the floor moved 400 -> 350 on Brad's ruling, 2026-08-29, and the
warning text was not moved with it). The safety message names a band that is not the one it installs.

## 2. Why 5.1 is stale, and how to prove it before you touch harvest.py

`qualify()` takes `band_at_ingest=False` and applies `in_band` ONLY when it is true. All three
production callers (harvest.py ~1700, ~2013, ~2537) call `qualify(entry, node, families, methods)`
with no band arguments, so the band is never applied at ingest; only the self-test passes it. The
comment above that call already records the fix ("qualify() ruled candidates out at CRAWL time ... was
the last place a second, hidden band survived").

So `BAND_CAL_MIN`, `BAND_CAL_MAX` and `BAND_CARB_MAX` are unused defaults on two signatures. They are
worth REMOVING - dead wiring that a future caller could re-arm by passing nothing - but removing them
is a tidy-up, not the fix 5.1 describes. Prove it yourself before you act: grep every call of
`qualify(` and `in_band(` and confirm no production path passes a band.

## 3. The change

1. `resolve_conditions` stops falling back. A run dir that states no conditions and no `--conditions`
   flag is a run that CANNOT START - the same shape `hunt-run.ps1 -Init` already takes for the band
   (it refuses to mint a run dir without one). The daemon should refuse with a message naming the run
   dir and what to state, not invent a band for three agent prompts.
2. `DEFAULT_BAND` goes the same way: `self.band = dict(band or DEFAULT_BAND)` becomes a refusal when
   no band is passed AND the run dir states none. Fixtures construct daemons constantly, so give the
   suite an explicit band rather than letting the default paper over it - that is the point.
3. Delete `DEFAULT_COND` and `DEFAULT_BAND` once nothing reads them, and the harvest.py trio with
   them. A constant that exists is a constant something will use.
4. The self-test currently asserts DEFAULT_COND and DEFAULT_BAND agree with each other
   (`hunt_daemon_selftest.py` ~10540 derives its expectation from `HD.DEFAULT_BAND` deliberately).
   Those cases change shape rather than disappear: the new invariant is that a run's band and its
   conditions prose agree, read from the RUN, for whatever band the run states.

## 4. Fixtures
1. MUST FIRE: a run dir stating no conditions and no flag REFUSES, naming the run dir.
2. MUST FIRE: same for the band.
3. CLEAN TWIN: a run dir stating a band and conditions starts, and both reach the prompts.
4. MUST FIRE: the conditions prose and the band NUMBERS agree for a non-default band - build a run at
   450-700 / 40 and assert the mapper, writer and auditor prompts all carry 450, 700 and 40 and carry
   no 350, 650 or 35.
5. MUST FIRE: no module-level band constant remains (grep the source for a numeric band literal, by
   concatenation so the assertion cannot match its own text).

Neuters: (a) the conditions refusal removed; (b) the band refusal removed; (c) the prose/number
agreement assertion pointed at a stale constant. Counts MEASURED.

## 5. Gates
`hunt-daemon.py --selftest` (451+ ok on main today; diff the case NAMES, nothing removed),
`hunt_dispatch.py --selftest`, `harvest.py` self-test if it has one. Background the daemon suite.

## 6. The thing to be careful about
Every fixture that builds a Daemon today gets its band from `DEFAULT_BAND` without saying so. When the
default goes, those fixtures must state a band EXPLICITLY - and if a case's meaning depends on which
band it had, stating it is the fix, not a chore. A suite that silently depended on a hard-coded band
is itself an instance of the defect this brief removes.
