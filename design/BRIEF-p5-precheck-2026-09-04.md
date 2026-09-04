# BRIEF: the P5 precheck - do not pay the auditor for a wave wave-publish will refuse

queue_id: p5-precheck-2026-09-04
shipped_commit: 561f40628ec9a5a187d2c8370a9f3701ad2eaf55 (2026-09-04, "Don't pay the auditor for a wave wave-publish is
going to refuse"). This field names a commit, so the work is DONE: verify it and report, do
not rebuild.
author of the brief: Fable, 2026-09-04, from the measurement in
design\EVAL-hunter-repeat-work-2026-09-04.md, section "The wave-repeat cost, measured".
ruled by: Brad, 2026-09-04 ("attack the wave-repeat cost", then asked for this brief).

## 0. Read these before touching anything

1. `design\EVAL-hunter-repeat-work-2026-09-04.md` - the whole file, and especially the corrected
   section. The first draft of that eval hypothesised a spec-hash skip; the measurement refuted it.
   Do NOT build a spec-hash skip. This brief is what the measurement actually supports.
2. `meal-prep\pipeline\hunt-daemon.py`, method `run_wave` (search `async def run_wave`). The change
   lives between `await self.preaudit(wk)` and the first `self.dispatch("recipe-batch-auditor"`.
3. `meal-prep\pipeline\wave-publish.ps1`, the `$gates = @(` array under `# ---- P5.` - the six gate
   labels this brief keys on. Read them off the file; do not trust this brief's copy if they differ.
4. `meal-prep\pipeline\wave-preaudit.ps1` around `$sharedChecks.Add(` - the shared checks the battery
   writes, and the report shape (`shared_checks` is a flat list of `{check, verdict, numbers, detail}`,
   `verdict` is the string `pass` or `fail`).
5. `meal-prep\pipeline\hunt_daemon_selftest.py`: `_wave_scratch`, `_preaudited`, `_wave_daemon`,
   `_mtimes_with`, `_shared_data_takes_the_unchanged_road`, and the section headed
   `2026-09-04 - the repeat-work fixes`. Your fixtures go in a new section modelled on those.
6. The estate memory rules that bite here (they are in the auto-memory index; the ones that matter):
   - a self-test that greps its own source cannot fail; build needles by concatenation;
   - neuter numbers get predicted, not measured: run each neuter separately, restore by md5, and
     DROP `__pycache__\hunt-daemon*.pyc` before every run (a patched source sharing size and mtime
     second with the previous neuter revalidates the previous neuter's .pyc - measured 2026-09-04);
   - exit code first, tally second: diff case NAMES against a pinned baseline run, never counts;
   - compose commit messages in a file and commit with `-F`; never `git add -A`; stage explicit paths;
   - the interpreter is `C:\Codex\Python312\python.exe`; bare `python` is the Store shim;
   - check for a sibling session (compare `main` vs `origin/main` in the MAIN checkout) before you
     commit, and do not run while a hunt is running.

## 1. The measured defect (why this exists)

hunt-2026-08-27-highprotein, 154M input tokens, 15 auditor calls at 3.8M each.
`wave-preaudit.ps1` runs the shared gates and writes their verdicts into
`waves\wave-<k>.preaudit.json` BEFORE the auditor is dispatched. `wave-publish.ps1` P5 then
hard-refuses the publish when ANY of these six is not clean:

    audit-spec-contradictions
    audit-store-integrity
    audit-vocab-integrity
    audit-unbid-ingredients
    audit-cost-plausibility
    audit-cost-line-coverage

`audit-spec-contradictions` was already `fail` in the preaudit report for waves 1, 2, 9, 10 and 11.
Each of those waves then bought a full auditor session, which returned NO-GO citing that gate. Their
audits and re-audits cost 21.8M tokens, 38% of audit spend, ~14% of the run, to reach verdicts
wave-publish would have refused regardless.

Two facts that bound the design:
- `recipes-db-dryrun` failed in 12 of 15 preaudits and waves 3, 4 and 8 PUBLISHED anyway. It is not
  a P5 gate. Neither are `p8-endpoint-provenance` and `p8-feed-liveness` (those are P8, checked
  separately by wave-publish and NOT part of this brief). The precheck keys on P5's six and nothing
  else. "Any red in the battery" is the wrong rule and would have blocked three good publishes.
- The auditor did nothing wrong. It refused correctly, and its recipe-local findings in those waves
  were real. What is wasted is the ORDER: the wave is audited before the thing that will veto it is
  fixed, so the audit is bought again after the repair. The precheck moves the shared-data repair
  BEFORE the audit instead of after a NO-GO that only re-discovers it.

## 2. The change, exactly

### 2.1 One authority for the gate list

In `hunt_lib.py`, near `MAP_BATCH` / `PRICE_BATCH`:

    P5_GATES = ("audit-spec-contradictions", "audit-store-integrity", "audit-vocab-integrity",
                "audit-unbid-ingredients", "audit-cost-plausibility", "audit-cost-line-coverage")

and a pure function:

    def p5_red_gates(preaudit_doc) -> list of gate labels whose shared_checks verdict is not "pass"
        (case-insensitive on the verdict, exact match on the label, order = P5_GATES order).
        A gate ABSENT from shared_checks is NOT red (the battery did not run it; could-not-look is
        announced elsewhere and is not a refusal here). A doc that is not a dict returns [].

### 2.2 The precheck in `run_wave`

After `await self.preaudit(wk)` and BEFORE the auditor dispatch, read
`waves\wave-<k>.preaudit.json` (utf-8-sig, as `render_audit_dossier` does) and compute `red`.

If the report cannot be read: append a finding saying so, and proceed to the auditor exactly as
today. An unreadable report is announced, never treated as a red gate and never as a clean one.

If `red` is empty: proceed to the auditor exactly as today. Byte-identical behaviour.

If `red` is non-empty:

1. Stamp a FREE lane pair so the lane log explains why no auditor ran (section 4.5's completeness
   rule; `audit-lane-shape.ps1` reads this log):
   `await self.lane("audit", "p5-precheck w%d" % wk, slugs, "mechanical", "start")` then
   `await self.lane_free_end("audit", "p5-precheck w%d" % wk, slugs, "mechanical",
   "P5 red: <comma-joined gates> - auditor not dispatched")`.
2. `self.log("WAVE %d: P5 gate(s) red in the battery (%s) - the auditor is not paid for a wave
   wave-publish will refuse" % (wk, ", ".join(red)))` and append the same as a finding.
3. ONE shared repair, IF this run has not already spent one on the FIRST red gate. Keep a run-level
   dict `self.p5_repairs_spent = {}` (gate -> True), initialised in `__init__` next to
   `self.map_inflight`. If `red[0]` is already in it, skip to step 6 (hold). Otherwise:
   - `owner = self.p5_owner(red[0])` from this map, defined ONCE as a class attribute
     `P5_OWNERS`:

         audit-spec-contradictions -> recipe-writer
         audit-cost-line-coverage  -> recipe-writer
         audit-vocab-integrity     -> recipe-ingredient-mapper
         audit-unbid-ingredients   -> recipe-ingredient-mapper
         audit-store-integrity     -> recipe-hunter-pricer
         audit-cost-plausibility   -> recipe-hunter-pricer

     (These mirror wave-publish.ps1's own comments: vocab-integrity means the NAME is wrong, unbid
     means the wiring is missing. They are the brief's ruling; Brad may change them, you may not.)
   - `before = self.mtimes(slugs, audit_path)` exactly as the existing agent road does.
   - dispatch `owner` with `self.p5_repair_prompt(wk, slugs, red, doc)` on lane `"audit"`, label
     `"wave-%d:p5-repair" % wk`, items `slugs`, `stage=owner`, no schema (the existing shared road
     passes none either; read `repair_prompt` and mirror its rails: sanctioned path only, never
     weaken a gate, report exactly what changed, "nothing needed changing" is legal).
     The prompt MUST carry, per red gate, the battery's own `detail` string and `numbers` for that
     shared check, verbatim, and the sentence that the gate is one wave-publish P5 refuses on, so the
     agent is fixing the estate, not the wave. It MUST also say: if the defect is not yours to fix
     (a vocabulary row, a board cell), say so and change nothing - the daemon will hold the wave.
   - `self.p5_repairs_spent[red[0]] = True`
   - `await self.rebuild_repaired_specs(wk, slugs, before)` exactly as the existing agent road does
     after its repair (read that call in `run_wave` and reuse it; do not reimplement).
   - `await self.preaudit(wk)` again, re-read the report, recompute `red`.
4. If `red` is now empty: proceed to the auditor exactly as today (first audit, scope whole-wave).
   The audit prompt already carries the battery's refreshed numbers.
5. (There is no step 5. One repair, then either audit or hold. Never a second shared repair for the
   same gate in the same run.)
6. HOLD the wave without paying the auditor:
   - write `waves\wave-<k>.p5-held.json`: `{wave, run, gates: red, at, repair_spent: bool,
     owner_tried: owner or ""}`;
   - for every slug in the wave: `await self.advance(s, "qa-passed", "daemon",
     "returned to the pool: wave %d held on P5 gate(s) %s" % (wk, ", ".join(red)))` and append to
     `self.qa_passed` if absent - the same road `trim_wave`'s `clean` branch takes. Do NOT call
     `trim_wave` and do NOT reject anything: no recipe in the wave is at fault for a shared gate.
   - `await self.sync_wave_manifest(wk)` as `trim_wave` does, so the manifest lets go of the slugs;
   - append a finding: `"wave %d HELD: P5 gate(s) %s red after %s - no auditor paid; clear the gate
     and the next wave close re-runs the battery for free"`;
   - return from `run_wave` without publishing.
   A subsequent wave close in the same run over the same red gate goes: battery (free) -> precheck
   red -> no repair (spent) -> hold. That is the loop the run had, minus the 3.8M audit per turn.
   The run's final `--status` must list held waves; add a `HELD WAVES` line to `status_report`
   reading the `wave-*.p5-held.json` files (gates and slug count), so the report can never say
   "nothing published" without saying why.

### 2.3 What must NOT change
- The auditor's prompt, schema, scope rules, the NO-GO repair roads, `trim_wave`, publish, the
  post-publish review. If a wave's P5 gates are clean, every byte of today's path runs unchanged.
- No new gate is added to P5 and none removed. `P5_GATES` is a MIRROR of wave-publish's list.
- Nothing writes board cells, the vocabulary, or the food DB from this code path. The repair agent
  keeps the rails it already has.

## 3. Fixtures - all required, in `hunt_daemon_selftest.py`, a new section
`H("2026-09-04 - the P5 precheck")`, registered in `run()` after the repeat-work section.
Every dispatch and every shell call injected, as everywhere in that file. Use `_wave_scratch`,
`_preaudited` (extend it with a `shared_fail=(...)` parameter that flips those checks to
`verdict: "fail"` with a `detail`), `_wave_daemon`, `_mtimes_with`. Name each case
`MUST FIRE` or `CLEAN TWIN` as the file does.

1. MUST FIRE: `audit-spec-contradictions` fail in the report -> the auditor is NOT dispatched
   before the repair; ONE `recipe-writer` dispatch with label `wave-1:p5-repair` whose prompt
   carries the gate label and the battery's `detail` verbatim; then (FakePS's `wave-preaudit`
   reply REWRITES the report clean on its second call - make the handler count calls) the auditor
   IS dispatched once, returns GO, and the wave publishes. Assert the ORDER in `fd.calls`:
   writer before auditor.
2. MUST FIRE: the repair does not clear the gate (the handler leaves it red) -> the auditor is
   NEVER dispatched, `wave-1.p5-held.json` exists naming the gate, every wave slug was advanced
   `qa-passed` with the held detail (read the FakePS `-Advance` calls), the manifest sync ran, a
   finding says HELD, and `wave-publish.ps1` was NOT called.
3. MUST FIRE: a SECOND `run_wave` on the same daemon with the same gate still red dispatches NO
   repair (spent) and NO auditor - the loop costs a battery run and nothing else.
4. CLEAN TWIN: `recipes-db-dryrun` fail ALONE (every P5 gate pass) -> the auditor is dispatched
   exactly as today, no repair, no hold file.
5. CLEAN TWIN: all shared checks pass -> `fd.calls` for the whole wave is identical to what the
   existing `_recipe_local_takes_the_patch_road` fixture produces for its GO path (no
   `p5-repair`, no `p5-precheck` stamp is REQUIRED - but if you stamp a free "clean" pair, pin it).
6. CLEAN TWIN: the preaudit report is unreadable (delete it before `run_wave`) -> a finding says
   so, the auditor IS dispatched, nothing is held.
7. MUST FIRE: `hunt_lib.P5_GATES` equals the six labels read out of `wave-publish.ps1`'s `$gates`
   array by regex over THAT file (`label = '<name>'`). Grepping a different file is not the
   self-grep trap; it is the cross-file pin this brief needs.
8. MUST FIRE: the lane log carries a `p5-precheck w1` start/end pair with the red gates in its
   detail when the precheck refuses (read FakePS's `hunt-run.ps1 -Lane` calls; see the existing
   `_lane_lines` helper and the "every end line outside the judgment dispatch goes through
   lane_free_end" case for the pattern).
9. MUST FIRE: `status_report` output contains a `HELD WAVES` line naming wave 1 and its gate when
   `wave-1.p5-held.json` exists, and no such line when it does not.

Neuter proofs, one per mechanism, run SEPARATELY with the .pyc dropped, restored by md5, counts
MEASURED and written into the commit message: (a) precheck removed (always dispatch the auditor);
(b) `P5_GATES` widened to include `recipes-db-dryrun`; (c) the spent-cap removed; (d) the hold's
`advance` to `qa-passed` removed; (e) the `P5_OWNERS` map replaced with a constant owner. Every
neuter must turn at least one of the cases above red, and the case it turns red must be the one
whose name claims that mechanism. If a neuter turns nothing red, the fixture does not bite: fix
the fixture, do not ship.

## 4. Gates you run, and the numbers you compare against

Baseline on `main` at cab6f72f plus the fixture fix in the commit after it (see git log for
"The band-gate fixture was stale"):

    C:\Codex\Python312\python.exe meal-prep\pipeline\hunt-daemon.py --selftest
      -> PASS, exit 0, 451 "ok" lines, 0 red, ends HUNT-DAEMON-COMPLETE
    C:\Codex\Python312\python.exe meal-prep\pipeline\hunt_dispatch.py --selftest
      -> PASS, 64 ok
    powershell -NoProfile -ExecutionPolicy Bypass -File meal-prep\pipeline\wave-preaudit.ps1 -SelfTest
    powershell -NoProfile -ExecutionPolicy Bypass -File meal-prep\pipeline\wave-publish.ps1 -SelfTest
      (both must stay exactly as green as they are on main; you change neither file)

Before you build: run the daemon suite once on clean `main`, save its output, and diff case NAMES
against your final run. A vanished case is a failure even at a higher count. Delete
`meal-prep\pipeline\__pycache__\hunt-daemon*.pyc` before every run. The daemon suite takes ~5
minutes; run it in the background and read the file, do not poll with sleeps.

## 5. Delivery

- Commit message in a file, `git commit -F`, explicit `git add` of exactly:
  `meal-prep/pipeline/hunt-daemon.py`, `meal-prep/pipeline/hunt_lib.py`,
  `meal-prep/pipeline/hunt_daemon_selftest.py`, and this brief with `shipped_commit:` filled in.
- The message states: the measured cost (21.8M / 38% / 5 waves), the six gates, the one-repair
  cap, the hold road, the neuter counts as measured, and the baseline-vs-final case-name diff.
- Push to `main`. Then report: what shipped, the suite numbers, and the ONE thing this cannot
  prove without a real run - that the held-wave road drains correctly across a daemon restart
  (`seed()` already returns unpublished waves' recipes to the pool; a held wave's recipes are at
  `qa-passed` with a reconciled manifest, so they should re-form; say that you did not run it).

## 6. Things you will be tempted to do, and must not

- Do not make the precheck read the gates' scripts directly. The battery already ran them; read
  the report. Running them twice is the waste this brief exists to remove.
- Do not add `recipes-db-dryrun`, `p8-*` or any other check to `P5_GATES`. Three waves published
  with `recipes-db-dryrun` red.
- Do not route a P5 red through `trim_wave`. It rejects recipes after a spent repair, and no recipe
  is at fault for a shared gate.
- Do not dispatch the auditor "anyway, to get its findings". Its findings on a wave that cannot
  publish are bought again after the repair; that is the measured 21.8M.
- Do not touch `wave-publish.ps1` or `wave-preaudit.ps1`.
- Do not "fix" the pre-existing content of the shared gates (the PHANTOM class, the zest cost
  basis). Those are separate defects with their own owners; this brief is the ORDER of the chain.
