NO-GO
scope: whole-wave
run: hunt-2026-08-27-highprotein, wave 1
battery: wave-1.preaudit.json (generated 2026-08-27T12:19:50, 37 checks, 3 reported fails) - read, chains verified, arithmetic spot-checked, not taken on faith
auditor: recipe-batch-auditor, 2026-08-27

## VERDICT: NO-GO. Two blockers, both recipe-local.

### BLOCKER 1 - chicken-rice-and-broccoli: spec-contradictions gate is RED (STAT-PROSE 1 vs baseline 0)
- File: meal-prep\db\recipes\chicken-rice-and-broccoli.json, head.description (line ~202):
  "47.3g protein and 472 calories per serving" vs stat.protein 47.
- I re-ran meal-prep\pipeline\audit-spec-contradictions.ps1 myself: exit 1, the single STAT-PROSE
  regression is this wave's slug. The gate's parser bites the decimal in "47.3g" and reads "3g";
  the QA file already diagnosed this. Substantively it is display-rounding drift (stat shows 47,
  meta description shows 47.3), not a wrong macro - the recompute chain (471.9 cal / 47.3 P from
  food-macros-db) is sound.
- But the gate is red at baseline and I do not weaken a gate to pass a wave. The correct fix is
  through the owning stage and it is one string: change head.description to the stat's own display
  numbers - "47g protein and 472 calories per serving". That makes prose and stat literally agree
  (the writer_notes themselves say the description carries "the stat's own numbers"; 47.3 is not
  the stat's number, 47 is) and turns the gate green without touching the gate.
- Kind: recipe-local. Owner: recipe-writer. After the edit, re-run audit-spec-contradictions
  (expect STAT-PROSE 0) and a scoped preaudit: wave-preaudit.ps1 -Slugs chicken-rice-and-broccoli.

### BLOCKER 2 - teriyaki-grilled-chicken-and-veggie-rice-bowls: dish identity never ruled against the live teriyaki-chicken-bowl
- The live catalog carries teriyaki-chicken-bowl ("Teriyaki Chicken and Rice Bowl"): chicken breast
  2495 g + teriyaki sauce + rice + broccoli + carrots, 519 cal.
- The accepted recipe is: chicken breast 2381 g + homemade teriyaki (soy/brown sugar/honey/ginger/
  garlic/rice vinegar) + rice + broccoli + carrots + zucchini, 764 cal. Same protein, same sauce
  family, same starch, and the SAME two vegetables plus one.
- The decider's own precedent, same run, two minutes earlier (considered-dishes.json 11:40:27):
  crock-pot-teriyaki-chicken REJECTED as dupe of teriyaki-chicken-bowl because it matched "on
  protein, teriyaki/soy sauce and rice starch; added stir-fry veg does not make it a distinct
  dinner." The 11:42:38 acceptance reason for this slug compares only "orange/sweet-sour/adobo
  chicken bowls" and never names teriyaki-chicken-bowl - the nearest neighbour was not tested.
  The claimed distinction lives only in the key (chicken|skillet|soy vs chicken|braised|soy),
  i.e. grilled vs braised, plus homemade vs bottled sauce.
- Compounding: the acceptance reason says "verified 40g protein 465 cal band" but the built recipe
  is 49 g / 764 cal - the dossier the decider ruled on is not the dish that got built (the QA-noted
  uncooked-rice reading roughly accounts for the calorie jump; still in band, but the ruling's
  stated basis is stale).
- This may be publishable - grilled + from-scratch sauce is an arguable distinction - but that
  argument has never been made against the right neighbour, and the same decider's same-day
  precedent cuts the other way. Material uncertainty = NO-GO with a question, not a shrug.
- Kind: recipe-local. Owner: recipe-dedup-selector (re-rule this slug explicitly against
  teriyaki-chicken-bowl, with the built 764-cal spec as the basis; escalate to Brad if it is a
  judgment call). If re-ruled dupe, pull the slug from the wave; the other three are separable.

## RULED NOT BLOCKING (with reasons)

1. voice-sweep "fail" on ground-beef-cottage-cheese-bowl and chicken-rice-and-broccoli: FALSE
   POSITIVE. The only dash bytes in either spec are the em/en dash entries inside the specs' own
   forbidden_prose_terms ban list (lines 24-25 / 23-24). I character-grepped both whole specs and
   both rebuilt preaudit cards: zero dashes anywhere in reader-facing prose or HTML (card-rebuild
   also asserts "no dash bytes"). Not a writer defect; no repair to the recipes needed.
   TOOLING NOTE for the battery owner: wave-preaudit's dash sweep should exempt the
   forbidden_prose_terms field, or every spec that correctly bans dashes will fail forever.
2. Macro band (this run's enforced band: cal 450-800, protein >= 40, carbs any) - all four pass
   on the recomputed (not just stated) numbers: teriyaki 764/48.9, hamburger-helper 550.5/44.5,
   cottage-cheese-bowl 550.4/41.7, chicken-rice 471.9/47.3. The cottage bowl's 1.7 g protein
   headroom I verified by hand from the label rows: 93/7 beef 2117 g x 24g/113g = 449.6 g +
   Darigold cottage cheese 791 g x 13g/113g = 91.0 g = 540.6 g from the two big rows alone
   (38.6/serving) with sweet potato, tomato paste, avocado and spices carrying the rest; both DB
   rows are USDA-corroborated 2026-08-26. The floor holds.
3. Costs: engine rows internally coherent on all four, zero unpriced lines, cost-plausibility and
   line-coverage audits clean. Spot checks against shelf reality: chicken breast $11.71 / 5.25 lb
   = $2.23/lb (Member's Mark, plausible), per-serving $1.66-$3.08 all sane for the dishes. No
   price-class survivors of the grits kind.
4. Protein derivation: all four claimed = derived by grams, single-protein tallies, run condition
   (breast/ground beef/pork loin/ground turkey) satisfied; no seafood anywhere; 14 servings all.
5. Mapping residue, all ruled by QA with evidence I checked: stock->broth on chicken-rice is the
   source's own synonymy (its step 4 says "broth"); NOTE that the source specified low/no-salt
   stock so sodium reads slightly high on the salted Swanson mapping - mapper may consider a
   low-sodium row someday, not blocking. Rice mapped to the board "rice" id per the 2026-08-26
   long-grain ruling; existing food-DB Rice row correctly left standing. Dropped "water" lines
   (teriyaki, hamburger-helper) are the house tap-water convention with quantities carried in the
   method at exact 3.5x - verified sums in the QA files.
6. Chicken-rice dried-seasoning lines at 3.0x vs the batch 3.5x: uniform whole-tbsp rounding,
   ~1 tsp short per spice across 14 servings, immaterial; mapper may tighten to 2 1/4 tbsp at
   leisure.
7. spec-contradictions UNMEASURABLE-QTY (21) and UNUSED (4): at/below baseline, none in this
   wave's slugs; owned by earlier batches, not this gate decision.
8. Shared infrastructure: store-integrity (hard=0), vocab-integrity, unbid-ingredients,
   recipes-db -DryRun (every row with item_id), P8 endpoint provenance and feed liveness (562
   recipes, generated this morning) all clean. Dish identity for the OTHER three slugs checked
   against the live feed: no plain chicken-rice-broccoli skillet, no hamburger-helper, no
   cottage-cheese bowl live today - distinct.

## REPAIR PATH
1. recipe-writer: one-string fix to chicken-rice-and-broccoli head.description ("47g").
2. recipe-dedup-selector: explicit re-rule of the teriyaki bowl vs teriyaki-chicken-bowl on the
   built spec; drop or keep with a written reason naming that neighbour.
3. Then scoped re-audit: wave-preaudit.ps1 -RunDir <run> -Wave 1 -Slugs <repaired slugs> and a
   scoped pass here. The other two slugs (healthy-hamburger-helper,
   ground-beef-cottage-cheese-bowl) are clean and carry no findings of their own.
