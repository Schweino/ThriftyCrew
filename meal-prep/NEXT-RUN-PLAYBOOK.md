# Recipe expansion run playbook (model-routed, zero /model flips)

Brad's requirement (2026-07-25): he should never have to remember to flip models mid-run. The routing
lives in the AGENT definitions (C:\Codex\.claude\agents\), each pinned to its model. Whatever model the
main session is on, the orchestrator dispatches stages to these agents and each runs on its own brain.

No seafood recipes: seafood is expensive per serving and nobody has asked (Brad, 2026-07-25).

## Stage routing

| Stage | Who runs it | Model | Why |
|---|---|---|---|
| 1. Source candidates from the internet (fan out N slices by cuisine/protein/method) | **recipe-sourcer** (parallel) | **opus** | breadth research; returns structured candidates + source URLs; selector culls |
| 2. DEDUP + select final batch to protein targets | **recipe-dedup-selector** | **opus 4.8** | judges the DISH not the name, vs catalog AND pool; Brad's rule: no duplicates or darn-near |
| 2.5 Normalize ingredients -> canonical worklist | scripts + main session | any | splitter + canon rules; start from meal-prep\canon-rules-standing.json (promoted r300 base) |
| 3. NEW ingredient mapping + food-DB entries | **recipe-ingredient-mapper** | **fable** | accuracy-critical; evidence-gate judgment; label transcription |
| 4. Scale to 14 servings, macros, 550 gate, pricing | scripts (r100 pipeline) | any | the gates do the checking |
| 5. Prose + card assembly (fan out slices) | **recipe-writer** (N in parallel) | **opus** | volume; numbers are transcribed, never computed |
| 6. Pre-publish batch audit | **recipe-batch-auditor** | **fable** | adversarial full-batch review; GO / NO-GO |
| 7. Publish + verify live + push + memory | main session | any | scripted, verified |
| 8. POST-publish independent review | **post-publish-reviewer** | **fable** | trusts artifacts not summaries; fixes via gates or files needs-brad; CLEAN / FIXED / NEEDS-BRAD verdict |

### Stage 2 speed note (learned on r300, 2026-07-25)
One selector adjudicating a 450-candidate pool serially takes ~45-60 min (reads ~650KB of candidates +
the full catalog, rules on every dish with a written reason). For pools this size, split stage 2 by
PROTEIN into parallel selectors (each gets its protein's slices + the full live catalog + that protein's
target), then run a short final merge pass in the main session for the only cross-protein risk:
same-dish-different-protein twins (e.g. a turkey chili vs a beef chili candidate). Cross-protein twins
vs the LIVE catalog are already each selector's job; only candidate-vs-candidate twins need the merge pass.

### Stage 2.5 speed note (learned on r300, 2026-07-25)
Status of the candidate optimizations:
1. APPLIED 2026-07-25: meal-prep\canon-rules-standing.json is the promoted base (= r300's built rules:
   authored 208 + rebased r100 223, all patches, audit-passed). Next run loads THIS file plus its own
   run-specific additions; keep promoting after each run's audit passes (never promote unaudited rules).
2. Start normalize DURING harvest: run the splitter + normalizer per harvest chunk as each lands
   (incremental unmapped inventory) instead of waiting for all chunks. The rule agent can start on the
   first ~80% of the inventory while the last chunks finish.
3. Parallelize rule DRAFTING by ingredient family (spices/condiments vs produce vs proteins vs
   packaged) across 2-3 agents - BUT rules are order-sensitive and first-match-wins, so drafts must
   merge through ONE serial integrator that owns ordering, then the full hijack audit runs exactly as
   today. The audit is the non-negotiable part; never split or skip it.
4. Cheap mechanical win: extend the splitter's prep-word stripping (CleanItem) with the highest-volume
   noise seen in r300 ("minced", "tsp." units, trailing "to taste") so fewer distinct unmapped strings
   reach the agent at all.

### Pre-launch efficiency checklist (r300 retrospective, 2026-07-25)
What we'd do differently BEFORE dispatching the next big run:
1. CAPTURE-AT-VERIFY - APPLIED 2026-07-25: now baked into recipe-sourcer.md (sourcers transcribe
   ingredients/servings/nutrition at verification). The separate harvest stage is only needed for
   candidates whose capture came back incomplete. (~8 agents / ~45 min / ~730k tokens saved per run.)
2. WEB-SEARCH BUDGET - PARTIALLY APPLIED: the fallback method + 403 domain list are baked into
   recipe-sourcer.md, and CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION is raised in .claude\settings.json
   (verify it took effect at the next wave: sourcers should report searches available deep into their
   slices). Discovery bias from index-crawling (one slice went 13/40 Chinese) is called out in the def.
3. SHARED PRE-DIGESTS: write ONE catalog digest (slugs+names by protein) and ONE merged candidate pool
   file before dispatch, instead of 10 sourcers each re-reading recipes-db.json and the selector
   re-reading 10 files. Same for any common brief: put it in a file agents Read, not 10x in prompts.
4. SIZE SLICES BY DUPE PRESSURE: chicken had the thinnest candidate margin (92 for 59) exactly where
   the live catalog was densest (69 live = highest dedup kill-rate). Oversupply should scale with
   existing-catalog density, not be uniform.
5. KNOWN-BLOCKED DOMAINS: route candidates whose source is on the 403 list straight to the browser
   capture lane instead of letting fetch agents retry them.
6. AGENT REGISTRY: verify the custom agent list loaded (one cheap dispatch) BEFORE composing the wave;
   if missing, fix the registry rather than inlining instructions, so agent defs and prompts cannot drift.

### Stage 3-8 lessons (r300, 2026-07-25) - the second half of the pipeline

QUALITY / PROCESS
1. WRITER WAVES ARE FREE DATA QA - budget a repair pass for their flags. The 8 prose writers, reading
   each recipe closely to write about it, surfaced ~60 real data bugs the engines had passed clean:
   fresh-vs-can scaling blowups (6 plum tomatoes -> 6 cans -> 8.6kg), choose-one source lines taken
   twice (japchea 2 of 3 alt beef cuts -> $6.48/serv), missing title starches (a la king with no
   noodle line), herb mis-folds (mint->basil in kibbeh), 5th instance of the sausage canon trap.
   Plan the sequence: waves land -> compile ALL flags -> ONE tuner data-repair pass -> ONE build/display
   pass -> THEN the auditor. Do not send the auditor a batch the writers already flagged.
2. THE AUDITOR EARNS ITS KEEP ON THINGS GUARDS CANNOT SEE. r300's NO-GO caught a board salsa cell
   hijacked by a guacamole product (2.2x real salsa, 8 recipes overpriced) via cost-PLAUSIBILITY, not
   any invariant; and 12 protein-field mislabels (turkey-sausage dishes tagged pork). Gates check
   internal consistency; the auditor checks external reality. Keep it adversarial, keep it FABLE.
3. guard-accepts.json: a VERIFY-class guard failure can carry a one-line human-reviewed accept
   (suya true==batch is arithmetic truth at exactly 7.0 lb of thigh). Only the VERIFY guard consults
   it; every hard guard stays hard. This is how you clear a false-positive without weakening a gate.
4. specs-ready.txt is armed ONLY by spec-guards -WriteReady, AFTER the auditor GO. Validation runs
   write specs-full-ok.txt instead, so no passing run can jump the gate. Keep this two-file split.
5. TIMESTAMP + HASH the ready-list: build-all stamps head.image back into specs, so specs-full-ok.txt
   must be the newest file AND the aggregate spec hash must match before/after the final guard pass
   (proves cards were rendered from the bytes that passed). Re-run guards once after build-all.

ENGINE / PRICING BUGS FIXED (all live in r300\ scripts now)
6. DRAINED-vs-NET can basis (real money bug): parse-compute weighs canned beans DRAINED (255g) but the
   board prices the NET can (425g) and $PKG carried net - so utils under-priced every can 1.67x AND the
   "Buy N cans" line under-counted ("uses 5.6, Buy 4"). Fix derives a drained table and prices/rounds
   on the same basis both sides. Any future canned item needs this or it double-wrongs.
7. Buy-line basis guard: spec-guards now re-derives Buy-N from the printed amount when amount and
   package share a unit (cans/heads/bunches) - a shopper following the card must not come up short.
8. Auto-numeric-sync must cover ALL FOUR prose fields (intro/portion/cost_closing/upsell), not r100's
   two: writers put macros in the closing line ("a sub with 51g protein"), and a spec regenerated after
   a re-cost must not ship a stale macro. Then RE-VERIFY nothing stale survived.
9. Display units: render meat + leafy/bulk produce weight-first (lb/oz), never "Turkey Breast 14.25
   cups" / "Kale 75.5 cups". Watch the inherited r100 bug where the meat regex also matched "Chicken
   Broth" and printed broth as "4.25 lb".
10. Pantry-line guard: a folded "Pantry seasonings" line > $5, or one that names a broth/stock/milk,
    hard-fails - it means a real ingredient got mis-bucketed (gumbo's $22 line was a sausage->Italian
    Seasoning canon victim hiding in the pantry fold).

ITEM-ID / DB (correction to the old bottom-of-file note)
11. DO NOT run normalize-recipe-ids.ps1 over r300-era rows. It reads ingredient-map.json ONLY and would
    NULL every r100/r300-only item_id. The r300 update-recipes-db.ps1 writes protein + item_id directly,
    stamping the ingredient-map.json id where it exists (live-213 convention) and the scaler bid only as
    fallback. normalize-recipe-ids is safe ONLY for the pre-r100 rows it was written for.
12. PROXY item_ids are a known debt: ~12 items price off a near-neighbor commodity (ricotta->cottage-
    cheese, red onion->onions, smoked turkey sausage->kielbasa, cherry tomatoes->tomatoes...). Correct
    for pricing, but a grocery-merge fuses them. Durable fix = register each as its own commodity. The
    live 213 carry null for those items, so nothing fuses TODAY - but check on the first planner rebuild.

TOOLING GOTCHAS (cost real time on r300)
13. PS 5.1 ConvertTo-Json wraps a bare array as {value,Count} unpredictably, even with -InputObject -
    it corrupted commodities.json TWICE. For big engine JSON, use targeted text edits + [IO.File]::
    WriteAllText, or the registration scripts - never round-trip through ConvertTo-Json.
14. Browser tool JS strings: use regex LITERALS (/\bancho\b/i), not string patterns ("\\bancho\\b") -
    the string escapes turn \b into a backspace and the reducer silently matches nothing.
15. Walmart search prices live at priceInfo.priceDetails.priceLines[].values[] (key PRICE / UNIT_PRICE),
    NOT priceInfo.linePrice (empty on marketplace items). Same finding as the grocery refresh skill.
16. Publishing is a ~1 post/sec continuous run; 4x75 batches with a live-verify each is fine, but the
    post-publish reviewer for an early batch may still be running when later batches land - tell it which
    slugs are its scope and that later publishes landing mid-review are the pipeline, not corruption.

## Shared pipeline (promoted 2026-07-26) - reference, do not re-port

The stable, run-agnostic toolchain now lives OUTSIDE the run folder so it compounds instead of being
re-copied (and drifting) each run. The next run REFERENCES these; it does not copy them:
- meal-prep\lib\json-db-io.ps1 - Save-JsonArray (top-level array always, defeats the PS5.1 wrap +
  1-element-collapse traps), Read-JsonArrayFile, Remove-RecipeRow (db-row surgery). Dot-source it.
- meal-prep\pipeline\build-card.ps1 + tpl-scaler-prefix/suffix.html - the byte-exact card generator
  (proven byte-identical after the move). build-all references ..\pipeline\build-card.ps1.
- meal-prep\pipeline\guard-lib.ps1 - reusable guard predicates: Get-ProseIngredientDrift (recipeIngredient
  must name only real meats - catches swap-drift) + Get-StaleSuperlativeClaims (only protein rank-#1 may
  claim batch primacy). spec-guards dot-sources it.
- meal-prep\pipeline\test-guards.ps1 - regression tests for the two guard predicates (13 assertions).
- meal-prep\pipeline\merge-protein-selections.ps1 - the parallel-dedup merge pass (below).

STAYS RUN-LOCAL (copy the PROVEN r300 versions, NOT r100's - r300 carries every fix): parse-compute.ps1,
cost-engine.ps1, build-specs.ps1, spec-guards.ps1, update-recipes-db.ps1, publish-r300.ps1, and the run
data (canon rules, manual-overrides, densities, pantry-packages, labels, board map). These have
run-specific tuning and are not cleanly parameterized yet - promoting them needs a real second run to
test against, so it was deliberately deferred (do NOT move them blind).
ENGINES support -Slugs (targeted recompute-and-splice) so a one-off fix does not rewrite all 300.
update-recipes-db supports -Replace <slugs> (Remove-RecipeRow then re-add) for single-recipe replacement.

## Parallel-by-protein dedup runbook (the ~40-min serial selector -> ~1/4)
1. Dispatch FOUR recipe-dedup-selector agents in one message, each given ONE protein's slices + the full
   live catalog + that protein's target. Each writes <RunDir>\selected-<protein>.json.
2. Run pipeline\merge-protein-selections.ps1 -RunDir <RunDir>: concatenates the four into selected.json
   and prints the candidate-vs-candidate CROSS-PROTEIN TWINS (a turkey chili vs a beef chili candidate).
3. Main session resolves those twins by the run's "max 2 protein-variants per dish" rule, editing
   selected.json. (Cross-protein twins vs the LIVE catalog are already each selector's job.)

## How to start a run

Tell the session: "start a recipe run for N recipes" (optionally: theme/constraints). The session follows
this playbook, reuses the r100 pipeline in meal-prep\r100\ (see recipe-r100-expansion memory for the
engine gotchas: $Matches clobber, rule order), and dispatches stages 3/5/6 to the pinned agents by name.
Stage 6's NO-GO blocks publish, full stop. Stage 8 runs UNCONDITIONALLY after every publish of the run
(and is reusable after any other site publish, not just recipes).

After a batch lands in recipes-db: the r300+ update-recipes-db.ps1 ALREADY writes item_id + protein
directly (ingredient-map id where it exists, scaler bid as fallback). DO NOT then run
normalize-recipe-ids.ps1 over those rows - it reads ingredient-map.json only and nulls every
r100/r300-only id (see stage 3-8 lesson #11). normalize-recipe-ids remains correct only for the
original pre-r100 rows. The free-dinner rotation and hub Top 5 read the protein field and must stay
set-identical - verify that at post-publish, do not re-stamp to "fix" it.
