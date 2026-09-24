# Lane: pd-plancite, W7.2 of design/PLAN-push-derived-conflicts-2026-09-23.md, 2026-09-23

Found while building W7.2 (`ops/plan_citation.py`, called from `ops/hooks/commit-msg`). Both findings are outside that
item's files, so they are filed here rather than fixed.

## one stale status line would make 83 of 86 plan-citation warnings, and from 2026-09-30 refusals

`DONE` `queue-7`

**What was measured.** `ops/plan_citation.py --replay 2026-09-16` (harness blob `3e3fc44542991632a8ba87a0ff2101bc16c0dca3`,
run from a linked worktree against origin/main at `23778c0760d5` on 2026-09-23) judges every first-parent, non-merge
commit on origin/main since 2026-09-16 through the same `judge()` the commit-msg hook uses, against the plans each
commit's first parent held. A `Co-Authored-By: Claude` trailer stands in for a session id, which history does not keep.
598 commits: 572 session, 26 not. 96 of the 572 changed a file named by a plan whose Status line says ruled or under
way; 10 of the 96 cited it and 86 did not.

**83 of those 86 come from one plan.** `design/PLAN-zero-alert-days-2026-09-10.md` opens with
`**Status: RULED 2026-09-10, building in the order of section 7.**`, and it names `grocery/alert-registry.json` (45
commits), `grocery/check-ad-cycles.ps1` (43), `ops/run-gates.ps1` (13) and three more files the daily triage and ops
lanes change almost every day. The only other plan in the window is this push-derived-conflicts plan (4 commits, one of
them the founding `5841e96b1`). So the week of warnings before D18's cutoff (REFUSE_FROM `2026-09-30` in
`ops/plan_citation.py`) will be mostly about one plan, and from the cutoff about 15% of session commits (86 of 572 at
last week's rate) would be refused until they cite it or say `Plan-not-applicable: <reason>`.

**The decision this needs.** Either that plan is still being built, and those commits should cite it (the rule is
working), or it is finished and its Status line should say so first (`DONE` or `SUPERSEDED`), which takes it out of the
check at once. The rule reads the FIRST status word, so `DONE 2026-09-xx (ruled 2026-09-10)` works. Nothing in W7.2
decides which, and it must not: an automatic staleness cut-off would be a hard-coded band on a plan's age. The cheapest
first rung is Brad reading section 7 of that plan and saying which it is before 2026-09-30.

**Not done here.** The plan file was not edited (it is not this lane's file), and REFUSE_FROM was not moved: D18 fixed
it at 7 days after landing.

**ANSWERED 2026-09-24, ruled by Brad: "Close 1-7, new plan for 8-11 (Recommended)".** The source plan's Status line
now opens with DONE (steps 1 to 7), and steps 8 to 11, R18, R11 and the step 3b build moved to
`design/PLAN-zero-alert-days-remainder-2026-09-24.md`, which names to the check only the files no other lane writes
and names a shared file only while its step is being built. `plan_state()` now reads the source plan as `finished`
and the new one as `under-way`. Measured with the same harness (blob `3e3fc44542991632a8ba87a0ff2101bc16c0dca3`) over
the same window, 2026-09-16 to `23778c0760d5`, as a counterfactual through the same `judge()` (the replay judges each
commit against its parent's plans, so a plain re-run cannot see a later Status change): of 572 session commits, 86
warnings before and 4 after, and all 4 name `PLAN-push-derived-conflicts-2026-09-23`. Over 2026-09-16 to origin/main
at `da90eea25`: 681 session commits, 93 warnings before and 9 after (push-derived-conflicts 7, bot-checkout-self-heal
2). The new plan's section 4 has the table and the variant that was tried first.

## a store_citation crash refuses the commit, because the hook reads its exit 1 as a refusal

`OPEN` `queue-7` `2-WAY` `RUNG1 BUILD`

**What the code does.** `ops/hooks/commit-msg` treats ANY non-zero exit from `ops/store_citation.py --commit-msg` as a
refusal (`|| refuse=1`, and `|| exit 1` before W7.2). `store_citation.main()` calls `run_commit_check` with no top-level
`try`, so an uncaught exception (a malformed recall-log line, an encoding error writing stderr under cp1252, a git
timeout's `SubprocessError`) exits 1 through Python's traceback path and the commit is refused. That is fail-closed on a
could-not-look, the opposite of the rule the same file states for a missing script or interpreter, and it holds TODAY,
before its REFUSE_FROM of 2026-09-25, because a crash does not go through `commit_mode` at all. Read from the code,
not observed: no crash has been seen.

**The shape that fixes it, already on main beside it.** W7.2 gave `ops/plan_citation.py` one refusal code,
`REFUSE_EXIT = 10`, and the hook refuses on 10 and prints every other non-zero code as BLIND (fixtured: a stub that
raises lands its commit, and a mutant that maps any non-zero to a refusal turns that case red). store_citation could take
the same contract: return a dedicated code for a refusal, wrap `run_commit_check` so an exception prints a BLIND line
and a traceback and returns 0, and the hook's store block maps codes the same way. Its own self-test would need a crash
stub case and a refusal case through the real hook. Not built here: `ops/store_citation.py` is not this lane's file, and
changing what its exit code means is a change to a rule Brad ruled on (2026-09-18).

**RULED 2026-09-24, ruled by Brad: "Match plan-citation (Recommended)".** `ops/store_citation.py`'s crash prints BLIND
and lets the commit land, and it refuses only on a dedicated refusal code, the same contract `ops/plan_citation.py`
has (`REFUSE_EXIT = 10`). The build is owed, and a sibling agent builds it; this record is text only.
