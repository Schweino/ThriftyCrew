NO-GO
scope: high-protein-chicken-alfredo-lasagna,no-boil-chicken-pasta-casserole-with-artichokes-and-peas,street-corn-chicken-rice-bowls,chicken-and-potato-curry
run: hunt-2026-08-27-highprotein  wave: 9  re-audited: 2026-08-28 (scoped re-audit after claimed recipe-local repairs)
battery: wave-9.preaudit.json (generated 2026-08-28T07:47:50, 51 checks, 4 failed) - chains verified, not rebuilt

## Verdict

NO-GO. The re-audit's premise ("the blocker was recipe-local, so nothing outside the
repaired slugs moved") is false in the other direction: THE REPAIRS THEMSELVES mostly did
not happen. The file evidence: the prior battery ran at 07:31:20; the casserole spec
(07:22:11), street-corn spec (07:27:24) and curry spec (07:28:44) all PREDATE it - those
are the original build stamps, not repairs. Only the lasagna spec (07:45:32) was edited,
and that repair is incomplete because the recost was never run. Four of the prior audit's
five blockers stand verbatim; the fifth (B2 phantom black pepper) was half-fixed and now
blocks in a new way.

## Blockers

### R1. high-protein-chicken-alfredo-lasagna - B2 repair INCOMPLETE: spec recut, recost never run (recipe-local, pipeline)
The writer's fix landed: Salt (9 g) and Black Pepper (2 g) are now separate ingredient and
scaler lines, and the PHANTOM for this slug is gone from audit-spec-contradictions. But
costed.json (mtime 07:20:33) predates the spec edit (07:45:32) and still carries the old
8-line engine row with no Black Pepper line. Result: build-card2.ps1 CANNOT RENDER the card
("no costed line for scaler item 'Black Pepper'") - the battery's card-rebuild fail. The
cost-engine-consistency "pass" on this slug certifies the STALE row. This is the recost
aftercare failure: recost the slug, run sync-recipesdb-cost, rebuild the card, then scoped
re-audit. Owner: pipeline.
File: meal-prep\db\recipes\high-protein-chicken-alfredo-lasagna.json + db\costed.json.

### R2. high-protein-chicken-alfredo-lasagna - B1 protein-form condition STILL UNRULED (recipe-local, orchestrator/Brad)
The writer's FLAG is still in writer_notes (line 21): main protein is Frozen Lightly
Breaded Chicken Breast Bites (Just Bare), 1058 g, breaded and processed, against a run
condition that names "boneless skinless chicken breast" - a cut, not a species. No stage
has ruled since the prior NO-GO asked. The question stands and blocks:
**Does a breaded frozen chicken-breast product satisfy "boneless skinless chicken breast"?**
My reading remains that it does not. Owner: orchestrator/Brad to rule; if it fails, the
recipe leaves the wave (drop or rebuild on plain breast).

### R3. B3 NOT REPAIRED - citrus zest priced per-POUND as per-EACH (recipe-local symptom, pipeline engine defect)
Byte-identical to the prior audit:
- no-boil-chicken-pasta-casserole line 69: "Lemon Zest ... ~$0.42. Buy 1 each: $4.83."
  ($4.83 is the per-pound rate stamped as a per-each buy; the prose says the zest comes
  from "the same lemons" the juice line already buys). cost_batch_true still 54.00 -
  unchanged from the number the prior audit showed to be ~$4.2 overstated.
- street-corn-chicken-rice-bowls line 74: "Lime Zest ... ~$0.44. Buy 1 each: $4.19." Same
  artifact. Line 70 still tells the reader "Buy 1 (covers this batch)" for 213 g of lime
  juice (~3.5 limes) - the bulk-class phrasing defect, also untouched.
Owner: pipeline (cost engine zest/second-occurrence unit basis + citrus bulk classing),
then recost, sync-recipesdb-cost, rebuild both cards.

### R4. chicken-and-potato-curry - B4 NOT REPAIRED: spec still contradicts the registrar's ruling (recipe-local, pipeline)
Spec line 135 still ships bid "serrano-peppers"; card prose line 68 still "Fresh Red
Chili ... Buy 1 lb: $6.40". The registrar adjudicated fresh-red-chili -> jalapenos
($1.4277/lb) and the mapped file agrees; the spec ignores it at 4.5x the cost. Today's
dry-run confirms the damage would propagate: "Fresh Red Chili -> serrano-peppers" is in
the scaler-bid fallback list that writes recipes-db item_ids. NOT a rejected mapping - the
jalapenos identity stands; the spec must adopt it. Restamp bid, recost, sync, rebuild.
Owner: pipeline.

### R5. Shared gate red: audit-spec-contradictions PHANTOM 3 vs baseline 0 (shared-data + pipeline)
Re-ran it myself, exit 1. The lasagna phantom is resolved (4 -> 3). Remaining three, all
carried from the prior audit, none in this wave's repair scope:
- blackened-chicken "salsa" - checker FALSE POSITIVE (mango salsa composed in step 1 from
  ingredient-line components); fix the CHECKER, never the baseline. Owner: pipeline.
- beef-rendang-rice-bowls "coconut oil" and mediterranean-chicken-w-marinade "cooking
  spray" - catalog specs outside this run. Owner: shared-data.
Wave-publish must not run against a red gate; this blocks regardless of the four slugs.

## Re-derived / verified this pass

- recipes-db-dryrun: battery fail is its own path bug again (relative forward-slash RunDir,
  "RunDir not found"; exit-2-class could-not-run, wave-8 precedent). Re-ran with absolute
  -RunDir, -SpecsDir meal-prep\db\recipes, -SpecList the wave slug file: clean - 6 rows,
  item_id from ingredient-map 69 / scaler-bid fallback 18 / null 0. The 68->69 delta is the
  lasagna's new Black Pepper line - consistent, not drift. Battery invocation still needs
  the pipeline fix.
- Salt $0 on blackened-chicken (battery fail, out of scope): stands cleared per the prior
  audit's re-derivation - board:salt:walmart carried, 1 g at ~$0.00128/g cent-floors to
  $0.00. Non-blocking; battery should tolerate priced sub-cent lines.
- Macros vs the enforced band (cal 450-800, protein >= 40, carbs any), all six from the
  battery's shown recomputes: cal 496.6-620.2, protein 40.7-54.8. All inside; lasagna
  closest at 40.7 (above the gate on the recompute, so no rounding rescue needed).
- Voice sweeps 0 hits, card rebuilds structurally identical on the 5 slugs that build,
  protein species derivations coherent (chili's 175 g pork is the bacon; chicken 1588 g
  dominates). store-integrity, vocab-integrity, unbid-ingredients, cost-plausibility,
  cost-line-coverage, P8 endpoint + feed liveness (565 recipes, 07:13:42): green.

## Non-blocking notes (carried - their slugs' specs are unchanged)

- blackened-chicken: "seven 10 oz bags" of rice vs cost line "Buy 9 8.5oz pouches" - same
  fact stated twice, disagreeing. Writer, next repair pass.
- Blackened Seasoning priced under cajun-seasoning - same-concept, acceptable, no action.

## Repair routing summary

| finding | slugs | kind | owner | blocking |
|---|---|---|---|---|
| R1 black-pepper recost never run | lasagna | cost-drift (stale engine row, card unbuildable) | pipeline | yes |
| R2 protein-form unruled | lasagna | condition-question | orchestrator/Brad | yes |
| R3 zest per-lb-as-each + lime bulk class (unrepaired) | casserole, street-corn | price-class | pipeline (engine) | yes |
| R4 spec ignores jalapenos ruling (unrepaired) | curry | mapping-drift | pipeline | yes |
| R5 spec-contradictions gate red (3 PHANTOM) | shared (1 checker FP + 2 non-run specs) | gate | pipeline + shared-data | yes |
| salt $0 rounding | blackened | battery-tolerance | pipeline | no |
| dryrun battery path bug | shared | battery-bug | pipeline | no |
| rice bag-count prose | blackened | prose-drift | writer | no |

Process note for the orchestrator: this dispatch was issued as a scoped re-audit "after a
recipe-local repair", but three of the four scoped specs were never edited after the prior
NO-GO. Whatever stage marks repairs done signed off work that does not exist on disk;
verify spec mtimes against the prior battery stamp before dispatching the next re-audit.
