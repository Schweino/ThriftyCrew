NO-GO
scope: whole-wave

# Wave 3 audit, run hunt-2026-08-27-ten
Auditor: recipe-batch-auditor (final gate), 2026-08-27
Battery: wave-3.preaudit.json, generated 2026-08-27T07:08:59, 16 checks, 0 failed.
Band of record (from the run dir, not the prose): cal 450-700, carbs <= 40, protein >= 40.
Slug under audit: baked-stuffed-pork-chops (sole slug of the wave).

## Battery disposition
All 16 checks green with work shown; chains verified rather than re-derived, EXCEPT the
macro chain, which I re-derived fully by hand because 533 cal sits within 5% of the 550
dinner gate: recomputed from food-macros-db rows against the spec grams, all 13 lines,
batch 7456.6 cal / 708.9 P / 188.6 C / 407.9 F -> per serving 532.61 / 50.64 / 13.47 /
29.14. Matches the battery (532.6/50.6/13.5/29.1) and the published stat (533/51/14/29)
exactly. Band: 533 in 450-700, 13.5 <= 40, 50.6 >= 40, all with margin, no knife edges.
The macro basis for the pork is the correct boneless-loin row (fdc:167839, raw
lean-and-fat, purchase basis) - macros are NOT affected by the cost defect below.

## Verdict per category
- MACROS: clean (full hand recompute above; cranberries-stay-fresh ruling sound and
  evidenced; ranch/oil/salt double-use sums verified against grams).
- COSTS: BLOCKED (main-protein price basis is the wrong FORM - Blocker 1).
- MAPPING: BLOCKED (registrar ruling ratified but never executed; stale vocab alias
  contradicts it - same finding, Blocker 1).
- PROTEIN/ROTATION: clean (pork by 3174 g, dryrun green; known quirk: the deriver counts
  560 g chicken BROTH as chicken - harmless here, standing owner note on update-recipes-db).
- CARDS: clean (battery rebuild structurally identical to live reference; JSON-LD parses).
- VOICE/COPY: clean (0 dash bytes; "lasts several batches" in cost_lines is engine
  boilerplate shared by 495 live specs, not writer prose - the forbidden list governs prose).
- GATES: clean (nothing weakened; all shared audits exit 0 with COMPLETE lines).

## BLOCKER 1 - baked-stuffed-pork-chops: main protein priced on the bone-in id the
## registrar ruled against, because the ruling was never executed
The chain, each link verified in the files:
1. This run's mapper mapped the protein to a NEW id `boneless-pork-chops` and the
   commodity registrar APPROVED it (mapped\baked-stuffed-pork-chops.json,
   registrar_rulings): it verified the only priced chop id `pork-chops` is literally
   "Member's Mark Bone-In Pork Chops" - a bone-in purchase, not a boneless-inclusive
   generic - and prescribed three REQUIRED follow-up edits via add-commodity-rule.ps1
   (mint the id in recipe-board-everyday + recipe-commodities; dupe-allowlist pair;
   add \bboneless\b to pork-chops excludes). Its own words: bridging the two "would
   publish both a wrong price and a wrong portion for the main protein of the dish."
2. NONE of those edits happened. `boneless-pork-chops` has 0 occurrences in
   grocery\commodities.json, grocery\recipe-commodities.json,
   grocery\out\recipe-board-everyday.json, grocery\commodity-dupe-allowlist.json and
   grocery\out\smp-feed.json. pork-chops' excludes still lack \bboneless\b.
3. A STALE vocabulary row from the 2026-08-26 run (meal-prep\db\ingredients.json:
   "Boneless Pork Chops" -> bid pork-chops, note "a NAME, not a new commodity") says the
   OPPOSITE of the ruling. The intake carries item+grams only, so the engine resolved
   the name through this row.
4. Result in db\costed.json: the 3174 g line's basis is `board:pork-chops:walmart`,
   whose crowned product is "Pork Assorted Loin Chops, Bone-In, 8 count ... Tray" at
   $3.27/lb. The published card charges 7 lb of BONELESS, 1 1/4-inch, pocket-cut loin
   chops ($22.88 of a $32.39 batch, 71% of batch cost) at a bone-in assorted-tray price,
   and its buy line tells the reader "Buy 7 lbs: $22.89" for a product that at that price
   is bone-in - followed literally, the reader comes home ~30% short of boneless meat.
5. Real boneless prices exist and were already gathered (hunt-2026-08-26-ten
   price-evidence batch-5): Sam's Member's Mark Boneless Center Cut Loin Chops $2.98/lb,
   Family Fare NY Boneless Value Pack $2.995/lb (it is even the Family Fare row inside
   the pork-chops cell today, a boneless product crowned on a bone-in id - the exact
   leak the ruling's exclude edit closes), Hy-Vee $3.96, Fareway $3.99. The $3.27
   happens to sit inside that spread, which is why it survived every plausibility gate
   and the wave-2 desk's shelf-sense check ("an agreeing number escapes scrutiny") - but
   the basis is wrong by the estate's own ratified ruling, and wave-publish E2's
   re-anchor would chain this recipe to bone-in sale prices forever.
Classification per the 2026-08-16 rule: NOT "unpriced" - the name resolves, to the WRONG
row. This is mapping/registration wiring, not capture.
- Repair owner: recipe-ingredient-mapper executing the registrar's already-written
  prescription: (a) run add-commodity-rule.ps1 for the three edits exactly as ruled;
  (b) fix the ingredients.json row "Boneless Pork Chops" -> bid boneless-pork-chops
  (and correct its contradicting note); (c) wire the new id's board rows from the
  batch-5 evidence (pricer adjudication already effectively done - four stores, named
  products, per-lb prices); (d) re-cost, sync-recipesdb-cost before propagate, rebuild
  the spec cost lines; (e) scoped re-audit: wave-preaudit.ps1 -RunDir <run> -Wave 3
  -Slugs baked-stuffed-pork-chops, then this desk re-reviews the cost chain only.
- Blocker kind: shared-data (vocabulary + commodity registry), consequence currently
  recipe-local (this recipe is the row's only consumer).

## SHARED FINDING 2 (does not block this verdict, must be fixed before the next wave) -
## price-evidence batch filenames are reused and clobber earlier evidence
This run priced "boneless pork chops" + "white pepper" as price batch 1 at 04:23
(lane-log.jsonl), verdict CARRIED at 04:54. At 06:00 a later dispatch WROTE NEW batch-1
files for "italian turkey sausage", overwriting them. The run dir now holds NO evidence
record for the pricing verdict on this wave's main protein - the audit trail for a
CARRIED ruling is gone. Owner: the daemon's pre-pass/pricer evidence writer (batch
numbering must be unique per dispatch, or filenames must carry the term set). Nothing
can restore the overwritten files; the 08-26 batch-5 evidence covers the same term and
is why this wave could still be audited at all.

## Non-blocking notes
- Salt grams: spec says 21 g (QA repair, correct at 3 1/2 tsp x 6 g), engine row still
  20 g from pre-repair. Cost impact $0.0015; fold into the Blocker 1 re-cost.
- Sandwich bread $6.97/20oz loaf remains high-side vs generic shelf (~$1.50-2.50);
  conservative direction, carried note from wave-2, bid class still deserves a look.
- Broth-counted-as-chicken in the protein tally: standing deriver note, harmless here.

## GO / NO-GO
NO-GO. Blocked by Blocker 1 only: baked-stuffed-pork-chops' main-protein cost basis is
the bone-in pork-chops id, against the registrar's executed-in-writing-only ruling.
Everything else on the recipe is clean - macros, band, protein, card, voice, gates -
so the repair is narrow: execute the ruling, rewire the vocab row, re-cost, scoped
re-audit. Shared Finding 2 (evidence clobbering) must be fixed before the next pricing
dispatch or the next wave publishes with an unauditable price trail.
