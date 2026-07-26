# r10 proof run (dry, board-tracked, instrumented) - started 02:05:45

Proves: agent registry, capture-at-verify (0 harvest), fresh folder referencing pipeline/, engines, guards, promotion policy.
Does NOT prove: parallel-dedup TIME savings (10 too small; merge mechanic only).

## Stage timings


- SETUP: r10 stood up from PROVEN r300 engines + promoted pipeline/ (per policy). All cross-refs
  resolve from the fresh folder (pipeline/build-card, pipeline/guard-lib, lib/json-db-io, standing
  canon 431 rules, food-macros-db, grocery board). Scripts syntax-clean. => promotion plumbing PROVEN.
- SOURCER: dispatched by agent NAME (recipe-sourcer) with no error => agent registry PROVEN working
  (r300 could not, ran on inline fallbacks). capture-at-verify + board-tracked-only brief. Awaiting.
- SOURCER done: 10 candidates, 10/10 with full inline capture, 0 unmapped => capture-at-verify PROVEN at source. (~17 min, 182k tok)
- DEDUP (parallel by protein): turkey selector 5/5 kept, 0 cut (~4 min, 74k tok); beef selector 2 kept, 3 cut.
  merge-protein-selections => 7 selected, 0 cross-protein twins. Parallel dedup mechanic PROVEN (time savings NOT, N too small).

## Back-half dry run (2026-07-26) - the mechanical pipeline + gates

Per-stage wall time (7 recipes), all engines copied from proven r300:
  build-final 0.1s | normalize 0.1s | parse-compute 0.3s | cost-engine 0.4s | build-specs 0.5s |
  spec-guards 0.1s | update-recipes-db -DryRun 0.1s   => ~1.6s total mechanical for 7 recipes.

PROVEN:
- capture-at-verify: build-final sourced 7/7 from inline captures, 0 harvest fallback. Harvest stage
  genuinely eliminated.
- Gates fire correctly: 550-cal gate (parse-compute 7/7 pass at pf=1); prose-file gate (spec-guards
  HARD-BLOCKED all 7 "missing prose file" - the writer wave is a required gate, build-specs only skeletons);
  DB-merge safety (update-recipes-db -DryRun refused parse-unvalidated specs, "nothing to add", no crash).

FOUND + FIXED:
- BUG (shared lib): Save-JsonArray crashed when a run has ZERO new items - an empty PS pipeline assigns
  $null (not @()), and the param lacked [AllowNull()]. Every all-board-tracked run would have hit this.
  Fixed in lib/json-db-io.ps1 (AllowNull + null->empty coercion). This is the headline proof win: only a
  board-tracked-only run surfaces it, which r300 (always had new items) never was.
- CANON GAPS (compounding): 4 ingredients unmapped by the standing canon - patis->Fish Sauce,
  oil for the pan->Vegetable Oil, lemon with rind->Lemon Juice, turkey stock->Chicken Broth. Added as
  r10-canon-rules.json (all map to existing board commodities). Promote to standing after settle.

FOUND (data-quality, would be auditor-caught):
- turkey-mole-rice-bowls came through with a THIN 5-line capture (others 12-21). Result: implausible
  $0.18/serving - the turkey line dropped and rice ballooned to 1761g. spec-guards does NOT check cost
  plausibility (that is the recipe-batch-auditor's job), so it would be caught at the audit gate, not here.
  Lesson: capture-at-verify quality VARIES; the batch-auditor cost-sanity pass is not optional.

NOT exercised: the writer wave (prose). spec-guards correctly requires it; it is the most-proven stage
from r300 (8 waves), so re-running it here adds cost without novel proof value. STOPPED at the prose gate
by design (dry run, no publish).
