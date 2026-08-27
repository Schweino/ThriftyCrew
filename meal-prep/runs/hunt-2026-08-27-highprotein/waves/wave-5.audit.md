NO-GO
scope: whole-wave

# Wave 5 audit - hunt-2026-08-27-highprotein (batch hunt-2026-08-27-highprotein-w5)
Auditor: recipe-batch-auditor (final gate), 2026-08-27
Battery: wave-5.preaudit.json (generated 2026-08-27T16:28:11, 51 checks, 1 failed) - read in full,
chains verified, macros independently re-derived end to end for all 6 slugs.

Wave context, verified: wave 5 is the sanctioned re-cut of wave 4 (same 6 slugs). Wave 4 got a GO at
16:22:08 and its publish crashed at E4 (propagate could not see wave-4.allow-create.txt - the file
landed 16:23:00, refusal 16:23:09) AFTER E1 tokenized the specs, E2 re-anchored cost_ps and E3 wrote
recipes-db. That one fact explains every oddity the battery hit: spec mtimes 16:22:57, the six rows
already present in recipes-db, the w4 label inside the specs' notes, and the dry-run race below.

## VERDICT BY CATEGORY

1. MACROS - ISSUES FOUND (one blocker). I recomputed all four macros for ALL SIX recipes by hand from
   food-macros-db grams-by-grams (not just the battery's numbers): every recompute reproduces the
   battery and the stat block to rounding. Both 550-adjacent recipes (healthy-hamburger-helper 550.5,
   ground-beef-cottage-cheese-bowl 550.4) were recomputed 100% per the standing rule. Spot-checked DB
   rows are label-accurate (93/7 beef and chicken breast USDA-corroborated; 80/20 kept as a distinct
   row). BUT healthy-hamburger-helper's arithmetic is built on the wrong FORM of one ingredient - see
   blocker 1.

2. COSTS - clean. Engine rows internally coherent, spec cost fields match to the cent, three tiers sum
   sensibly on all six, no unpriced lines, no price-class absurdities among the priced forms. I
   verified stat.cost_ps = cost_first_run/servings (everyday basis) to the cent on all six - E2
   already ran during the wave-4 partial publish, which is why new slugs carry the correct basis.
   (2b: no unpriced findings, so no repair-owner classification needed.)

3. MAPPING - ISSUES FOUND. (a) The rotini form conflict, recorded by the mapper itself in
   mapped\healthy-hamburger-helper.json db_row_findings and never adjudicated - blocker 1 below.
   (b) pioneer-woman-chili: the mapper WROTE a 'Limes' food-DB row while 'Lime' already exists (its own
   finding says one will silently shadow the other). The spec line is 'Lime' and resolves to the
   pre-existing row, so this wave's numbers are unaffected (impact <1 cal/serving either way). Routes
   to the standing ~15-pair food-DB duplicate backfill lane (Fable proposes, Brad confirms). Not a
   wave blocker.

4. PROTEIN + ROTATION - clean. All six recipes-db rows verified directly (I re-ran
   update-recipes-db -DryRun myself AND read the six rows): protein fields match the heaviest protein
   ingredient, 0 null item_ids across all six. Proteins are within the run's allowed set: boneless
   skinless chicken breast x3, ground beef x3 (93/7, 93/7, 80/20 - all ground beef). CAVEAT for the
   battery's owner: the protein-derivation tally counts BROTH grams toward the meat category
   (chicken-rice: 2381 g breast + 2520 g chicken broth = the reported 4901; hamburger-helper:
   1588 + 1680 beef broth = 3268). Harmless in this single-protein wave, but a heavy off-category
   broth could flip a future label. Fix the tally in wave-preaudit.ps1; not a wave-5 blocker.

5. CARDS - clean. Battery rebuilt all six and structurally compared against the live reference; I
   byte-spot-checked three (butter-chicken-pasta, pioneer-woman-chili, chicken-rice-and-broccoli):
   serving scaler, print sheet, dynamic three-tier cost section (fed by the verified live feed),
   source credit block all present; zero em/en dash bytes (an apparent dash in my first probe was a
   codepage artifact of the multiplication sign - read UTF-8, it is clean).

6. VOICE - clean. No dashes anywhere, no swearing, prose reads in Brad's register in the specs I read
   in full. No new visual elements beyond the standard template, so no new 375px surface.

7. GATES - clean. Nothing weakened; the wave-4 refusal was the publish gates firing correctly, and
   wave-5 rides the same gated path. Note for the ledger reader: E4 propagate reported ~13 dirty specs
   OUTSIDE this wave that will be carried and republished with it (propagate's design) - the wave's
   ledger entry should not be read as shipping only 6.

## RESOLVED BATTERY FAILURE (do not treat as open)
shared check recipes-db-dryrun FAIL (rc=1, no item_id line) was a transient race: the battery ran
16:28, seconds after the daemon's 16:22:57 recipes-db write. My re-run of the exact invocation exits
0 and prints "item_id source: ... no id (null) 0 rows" (all six skipped already-present). Because a
skipped row is not a verified row, I additionally verified the six rows in recipes-db directly:
0 null item_ids. This check is settled.

## BLOCKERS

### Blocker 1 - healthy-hamburger-helper: macros computed on Protein+ pasta, recipe sold as regular
Recipe-local. Owner: recipe-ingredient-mapper.
The food-DB row 'Rotini Pasta' is a Barilla PROTEIN PLUS label (190 cal / 10 g protein / 38 g carbs
per 56 g; its own notes say "Protein Plus"). Everything reader-facing describes REGULAR rotini: the
source recipe ("3 cups dry rotini pasta (sub penne or medium shells)"), the buy string, the cost line
($2.74 for three 16-oz boxes - regular-pasta price class, roughly 1/3 the Protein+ shelf price), and
shop_smart ("Penne or medium shells sub in fine... Any short pasta with ridges"). The mapper's own
cross-check validated at regular-pasta figures (its macro_cross_check: 579 cal / 41.8 g protein) and
its db_row_findings recorded the row conflict, but the existing Protein+ row stood and the spec's
published stat (550 cal / 44 g protein) was computed from it. Cooked as the card sells it, the honest
numbers are about 573 cal / 41 g protein / 59 g carbs - still inside this run's enforced band
(450-800 cal, protein >= 40), so the recipe survives; the published macros are what is wrong.
Files: meal-prep\db\recipes\healthy-hamburger-helper.json (stat + prose),
meal-prep\food-macros-db.json ('Rotini Pasta' row),
meal-prep\runs\hunt-2026-08-27-highprotein\mapped\healthy-hamburger-helper.json (the recorded conflict).
Fix (mapper rules the form, two coherent options):
  (a) RECOMMENDED - book the macros to a regular-rotini row (regular enriched pasta class, e.g.
      200 cal / 7 g / 42 g per 56 g, the same class as the existing 'Ziti Pasta' row), rebuild the
      spec (expect ~573 cal / ~41 g protein), re-run the scoped battery
      (wave-preaudit -Slugs healthy-hamburger-helper) and a scoped re-audit. Matches source, price
      class and prose with no cost change.
  (b) Keep Protein+ macros - then the card must SAY Protein Plus (live cheeseburger-pasta is the
      precedent), the "any short pasta subs fine" line must go, and the cost line must move to the
      Protein+ price class (board bid check included).
Follow-up either way (shared-data, NOT blocking this wave): the food-DB row 'Rotini Pasta' carries a
Protein Plus label without the qualifier in its name, against the 2026-08-26 naming ruling ("leading
qualifiers IN the name"). Mapper proposes the rename, Brad confirms. Four LIVE recipes ride on that
row (turkey-pesto-pasta-kale, turkey-alfredo-rotini-bake, pizza-pasta-bowls,
ground-beef-stroganoff-pasta) - they need the same form question answered post-ruling.

### Blocker 2 - pioneer-woman-chili: trademark title, unruled - a question, not a shrug
Recipe-local. Owner: Brad (ruling), then recipe-writer for the edit.
"The Pioneer Woman Chili" would be the FIRST celebrity-trademark title in the 568-recipe catalog
(verified: no other person/brand-named recipe exists), and it credits thecozycook.com, a middleman
blog, not the trademark holder. No pipeline stage rules on trademark exposure (the dedup-selector
rules dish identity; this is exactly the "condition questions the run has not ruled on" residue class).
Every mechanical check on this recipe is clean - macros, cost, mapping, card - so this is purely a
title/branding ruling. Uncertain-and-material is a NO-GO question by charter.
Fix: Brad rules keep-or-rename. If rename (my recommendation: something like "Cowboy Beef and Bean
Chili" with the credit line unchanged), the slug also carries "pioneer-woman" and the row is already
in recipes-db from the wave-4 partial publish - rename BEFORE this wave publishes while a slug change
is still cheap, then rebuild the card and re-run the scoped battery.
Files: meal-prep\db\recipes\pioneer-woman-chili.json, meal-prep\recipes-db.json (row already written),
meal-prep\runs\hunt-2026-08-27-highprotein\waves\wave-5.json.

## CLEAN SLUGS (no findings)
butter-chicken-pasta (protein 40.2 clears the 40 g gate - verified by hand), 
ground-beef-cottage-cheese-bowl, chicken-rice-and-broccoli, teriyaki-grilled-chicken-and-veggie-rice-bowls.
Band check, all six, against the enforced band (cal 450-800, protein >= 40): 630/40.2, 550/44.5*,
550/41.7, 472/47.3, 764/48.9, 680/41.8 - all inside. (*hamburger-helper stays inside on the corrected
regular-rotini basis too: ~573/41.1.)

## AFTER REPAIR
Repair both blockers, then: wave-preaudit -Slugs healthy-hamburger-helper,pioneer-woman-chili for the
mechanical re-check, and a scoped re-audit for the fresh GO. The GO must postdate every spec mtime
(P1b) - remember E1 rewrites specs at publish, and the ~07:00 bot can bump mtimes.
