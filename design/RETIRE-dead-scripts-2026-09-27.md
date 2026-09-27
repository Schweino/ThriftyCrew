# Retire dead scripts - candidate list for Brad (2026-09-27)

**Nothing has been deleted or moved.** This is a list for approval. One row per script is in
`design/RETIRE-dead-scripts-2026-09-27.tsv` (path, class, evidence, last commit date, date added).

## Knowledge consulted
Searched "dead script unreferenced archive retire" (knowledge-search --estate): nothing applicable.
Used: rules/grocery.md (a script can be used with no basename reference: run `ops\count-source-lifters.ps1`),
memory a-negative-search-result-must-prove-itself (the grep was probed against a known-live name first).

## Method
Harness: a scratch census (not committed; a one-off), run in worktree `agent-a7e796d8031c93f29` at HEAD `f56c713d9`.
1. Population: tracked `*.ps1` and `*.py`, excluding `test-*.ps1` and any path containing `fixture`: **1,001 scripts**.
2. Candidate: its basename appears in no tracked file other than itself (`git grep -o -I -E '[A-Za-z0-9_.-]+\.(ps1|py)\b'`,
   keyed by the file that mentions it), and in no argument of the 201 scheduled-task actions on this box.
   Probe: `compare-deals.ps1` is mentioned by 180 files, so the grep is not silently empty. **93 candidates.**
   The brief's starting point was 109 of 1,002; I did not reproduce that exact count. My test drops a script if ANY
   other tracked file (docs and data included) names it, which is stricter, so 93 is a subset-shaped difference, not
   a contradiction. The 16 gap was not itemised.
3. Per candidate, checked what a basename grep misses:
   - the stem without extension (catches Python `import`, Join-Path pieces, prose): found 1 real use (`plausibility_report`);
   - the folder's `SKILL.md` (lesson, meal-macro): no candidate is a documented command;
   - `ops\count-source-lifters.ps1 -Script <name>` for all 85 `.ps1` candidates: **85 of 85 exit 0, NAMES=0 READS=0 EXECUTES=0**
     (its own scope line: UNSOUND, a zero means no read of a shape it follows);
   - function names defined in the file and named elsewhere: every hit was a sibling's own copy (inline `New-GhostJWT`,
     `BrandMap` across `assemble-batch*`), not a lift;
   - glob discovery: `run-gates` excludes `\archive\` and `\out\` from discovery, and no candidate is an `audit-*` or `test-*` it would pick up;
   - last commit and date added (`git log`). The 2026-09-19 dates on several are the I230 Accept-Version sweep, a mechanical edit, not use.

## Counts (denominator: 93 candidates of 1,001 scripts)

| Class | Count | Meaning |
|---|---|---|
| ONE-OFF | 80 | Historical batch fix, probe or diagnostic. 59 already sit under an `archive/` or `grocery/out/` directory. |
| DEAD | 3 | Superseded, and re-running would break a current rule. |
| UNSURE | 9 | Plausibly run by hand; needs Brad. |
| LIVE-BY-HAND | 1 | `graph/eval/plausibility_report.py`: imported by `graph/eval/smoke_test.py:208`. Not a candidate. |

Clusters: grocery 44, .claude 18, meal-prep 17, site 5, sidecar 3, archive 2, graph 2, media 1, ops 1.

**DEAD**: `.claude/skills/meal-macro/batch-publish.ps1` (a Ghost publish road outside the gated publishers),
`.claude/skills/meal-macro/build-recipe-index.ps1` (bakes cost/serving as a literal, which the live-price rule forbids),
`meal-prep/pipeline/build-run-final.ps1` (Recipe Hunter v1 run shape).

**UNSURE, questions for Brad**:
- Are the budget tracker, compound calculator and savings tracker workbooks still regenerated? If yes, keep
  `site/build/build-budget-tracker.ps1`, `build-compound-calculator.ps1`, `build-savings-tracker.ps1` (the only generators
  of formula-driven workbooks) and the Sheets steps `update-tracker-sheet.ps1`, `update-sheet-from-xlsx.ps1`,
  `thriftycrew-oauth-authorize.ps1` (the last one's header still names itself `google-oauth-authorize.ps1`).
- Is the protein leaderboard tool still rebuilt? (`meal-prep/build-protein-data.ps1`)
- Is `/suggest-an-item/` still edited through `build-item-request-page.ps1`?
- Is the bulk reel builder `media/reels/build-all-recipe-videos.ps1` wanted?

**ONE-OFF, a note before deleting**: `meal-prep/pipeline/dedup_prompt_drill_ask.py` and `sidecar/audit_rejections.py` are
measurement harnesses. The measurement rules say a measurement that may be repeated commits its harness, so keep them if
their questions can recur.

## What the existing audits already say (same worktree, same HEAD)
- `grocery/audit-script-census.ps1` (exit 0): 729 scripts plus 38 under `out\`, read against 801 executable files;
  **108 uncalled, 73 recorded as deliberate**; wide tier 75 uncalled outside `grocery\`; "35 recorded entries are no longer
  uncalled here - drop their KNOWN lines"; wide ratchet below its mark (70 < 71). Its test is "called by an executable
  file", so it counts more than this list, which also accepts a doc mention as a use.
- `grocery/audit-guard-contract.ps1` (exit 0): `covered=68 backlog=0 regressed=0 half=0 dead=0 hold=0`. It covers chain
  detectors only; none of the 93 candidates is one.
- Both live in `grocery/`, not `ops/` as the brief named them.

## Proposed action, on approval
Delete the 80 ONE-OFF and 3 DEAD in one commit (git history keeps them), after re-running step 2 on the day, since a
sibling may add a reference. Leave UNSURE until each is answered. Script-census's KNOWN list and wide baseline then need
their `-WideBaseline` re-mark in the same change.
