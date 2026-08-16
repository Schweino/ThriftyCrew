NO-GO
scope: whole-wave

# Wave 2 audit - hunt-2026-08-15-lowcarb-100 (audited 2026-08-16, third audit of this wave)

Auditor: batch audit gate. The dispatch called this the "first audit of this wave"; the on-disk
history says otherwise (first audit 11:41, second audit 12:09, both NO-GO). This pass therefore
re-verified everything against CURRENT bytes rather than trusting either label: full 10/10 macro
recompute from food-macros-db, full 10/10 cost reconciliation against db\costed.json (12:05:12
working copy), all 10 cards rebuilt to a scratch dir, protein derivation by construction plus
update-recipes-db -DryRun, voice sweep, mapping and adjudication re-read, publish-path gates walked.

## What moved since the second audit (12:09)

- The orchestrator ran a wave-2:trim (12:09:46-12:11:13): rolls was set to `rejected-audit`
  (12:00:27), philly and fajita were returned to `written` for re-QA, and the seven certified slugs
  were set back to `qa-passed`. A wave-2:close ran 12:15:53-12:16:22 but changed nothing: the wave
  manifest waves\wave-2.json still has its 11:40:51 bytes and still lists all 10 slugs.
- db\costed.json was rewritten at 12:05:12 by wave-3 write traffic. Re-verified: every wave-2 row is
  numerically identical to the numbers the second audit certified (details below).
- No QA verdict for philly or fajita was written after their 11:58 re-renders. No spinach repair
  artifact of any kind landed (ingredient-map.json untouched since 06:19:47, db\ingredients.json
  since 10:37:13 with Spinach still routed to frozen-chopped-spinach, no fresh-spinach commodity,
  no spinach ruling in db\ingredient-resolutions.json).

## Verdict summary

| Category | Verdict |
|---|---|
| 1. Macros | CLEAN - 10/10 recomputed end to end from spec grams x food-macros-db (not just the five inside the 5%-of-550 band). Max drift 1.4 cal (turkey casserole 429.6 vs stat 431); everything else within 0.6 cal and 0.6 g on every macro. All 10 sit inside the run window: 401-546 cal, carbs 5-23 g (gate is 400-650 and 35 g), 14 servings on every spec. |
| 2. Costs | CLEAN on numbers - every spec cost field (batch / true / pantry / first-run / ps) reconciles with its engine row to the cent, every engine row's line utils sum to its batch total to the cent, lines_unpriced = 0 on all 10, no zero-cost non-optional line, no sub-$0.25/lb class survivor. audit-cost-plausibility clean n=10. Prose cost literals match the spec's own fields on all 10. The rolls' numbers are internally consistent but sit on a wrong price class (blocker 2). |
| 3. Mapping | ISSUES FOUND - BLOCKING on rolls only. update-recipes-db derivation: 98 item_id rows, 0 nulls (82 map + 16 scaler-bid fallbacks). Every fallback is covered by a Brad adjudication of 2026-08-16 08:21 (tandoori-masala->garam-masala, broccoli->frozen-broccoli-florets, crimini->mushrooms, cream-cheese->1-3-fat-cream-cheese, sour-cream, etc.) except nothing covers SPINACH: the rolls' 7 cups fresh baby spinach still ids and prices as frozen-chopped-spinach. audit-vocab-integrity and audit-unbid-ingredients both clean n=10. |
| 4. Protein + rotation | CLEAN - by construction, each spec's protein field matches its heaviest protein ingredient (verified per ingredient grams: 6 beef, 1 pork via andouille, 1 turkey, 1 chicken, 1 beef rolls). -DryRun builds all 10 rows, 0 nulls. normalize-recipe-ids NOT run (new-era rows, 2026-07-25 correction). Rotation/Top-5 exposure only via publish, which is blocked below. |
| 5. Cards | CLEAN - all 10 rebuild through build-card2.ps1 at 100% bid coverage to a scratch dir (nothing under db\built touched). Byte-level structural check of 4 cards against the live al-pastor card: full id skeleton (smp-ing/smp-cost/smp-make/smp-portion/stepN), print, scaler, 3-tab cost section, source credit, feed URL feed.thriftycrew.com/smp-feed.json, zero 0x2014 bytes. |
| 6. Voice + copy | CLEAN - zero em/en dashes (raw and escaped) in all 10 specs; the one swear-sweep hit was the substring of "scraping". Cards are the standard template (verified at 375px when adopted); this wave adds no new visual surface. One open condition question below (Worcestershire). |
| 7. Gates | ISSUES FOUND - BLOCKING. wave-publish P3 requires every manifest slug to be state `waved`; right now ZERO of the 10 are (7 qa-passed, 2 written, 1 rejected-audit), so the manifest no longer describes a publishable wave. Ledger row hunt-2026-08-15-lowcarb-100-w2 correctly carries no audit stamp and still lists all 10 slugs including the rejected one. No gate was weakened; audit-spec-contradictions, vocab, unbid, cost-plausibility all run clean. |

## Verified numbers (current bytes, so the next audit does not redo them)

- All 10 macro recomputes: flank 543.3/31.7/22.6/37.7 vs 543/32/23/38; philly 520.9/30.7/17.2/38.2
  vs 521/31/17/38; keto 538.2/31.1/5.3/42.3 vs 538/31/5/42; fajita 541.0/56.5/7.1/29.7 vs
  541/56/7/30; taco 532.2/33.4/8.5/39.2 vs 532/33/8/39; sausage 447.1/23.0/14.0/34.1 vs
  447/23/14/34; rolls 546.6/42.2/5.5/40.1 vs 546/42/5/40; turkey 429.6/34.9/12.4/27.3 vs
  431/35/13/27; tandoori 401.4/37.4/11.1/21.6 vs 401/37/11/22; balsamic 504.0/40.8/18.9/29.1 vs
  504/41/19/29.
- philly engine row still batch $42.39 / ps $3.03 / true $50.46 / pantry $7.52 / first run $57.98;
  fajita still $70.72 / $5.05 / $76.06 / $0 / $76.06 - byte-identical to what the second audit
  certified, so the 12:05:12 costed.json rewrite moved no wave-2 number.
- stat.cost_ps basis: flank is already re-anchored to the everyday basis (4.09, present in
  v2-perserving.json); the other nine still carry the batch/14 engine ps and are NOT in the
  manifest yet. That is the expected pre-publish state - wave-publish E2 computes, re-anchors, and
  then hard-verifies the basis per slug, so it is not a defect today.

## What blocks, exactly

### 1. philly-cheesesteak-stuffed-peppers + low-carb-steak-fajita-skillet - re-QA still owed (recipe-local)
Third audit in a row this stands. Both cost repairs are numerically sound (re-verified above), but
qa\philly (06:01:53) and qa\fajita (06:14:23) still certify pre-repair bytes; specs are 11:58:52
and 11:58:58; no qa lane event has touched either slug since. Their states are `written`, which is
also what the trim demanded. This is a fast mechanical stamp against current bytes, not rework.
FIX: run the source-QA lane on the two slugs. Owner: QA lane (repair owner for the wave's return:
orchestrator dispatches it).

### 2. spinach-provolone-stuffed-flank-steak-rolls - fresh-spinach price class, still unrepaired (shared-data)
State is `rejected-audit` (12:00:27) and every artifact confirms the defect is untouched: spec
(11:24:44 bytes) still prints "Spinach, 7 cups baby spinach (about 7 oz): ~$0.85. Buy 1 10oz bag:
$1.15." on basis board:frozen-chopped-spinach:recipeboard-walmart, scaler bid frozen-chopped-spinach,
db\ingredients.json routes Spinach -> frozen-chopped-spinach, no fresh-spinach commodity exists,
and ingredient-resolutions.json carries no spinach ruling. Publishing would ship a self-declared
wrong price class roughly 2.2-2.6x under fresh shelf reality. FIX (unchanged): pricer captures
fresh baby spinach OR Brad adjudicates a disclosed form-flip alias; registrar/map-owner lands the
row; recost + recost-spec-cost-block + re-QA. Owner: pricer + registrar/map-owner first, then
writer lane. ALTERNATIVE: the trim already rejected it - if that is the intended resolution, the
wave manifest and ledger must stop claiming it (blocker 3), and the slug re-hunts later.

### 3. The wave manifest no longer describes the wave (process/orchestration)
waves\wave-2.json (11:40:51 bytes) and the ledger row both still list 10 slugs, but the trim moved
every slug out of `waved`: 7 sit at qa-passed, 2 at written, 1 at rejected-audit. wave-publish P3
would refuse this manifest even on a GO, and a GO from me on the 10-slug scope would certify a slug
the run itself has rejected. The 12:15:53 wave-2:close attempt ended without touching the manifest.
FIX: after blockers 1 (and 2, or its formal removal) resolve, re-close the wave so manifest, ledger,
and states agree - 9 slugs if the rolls rejection stands - then request a fresh audit of exactly
that manifest. Owner: orchestrator.

## Question requiring adjudication (named, not shrugged)

- Worcestershire sauce is a real ingredient in philly-cheesesteak-stuffed-peppers and
  balsamic-sirloin-steak-sheet-pan. Standard Worcestershire contains anchovy; the run condition is
  "no seafood". If that condition is a recipe-class preference (no seafood dishes), these pass and
  this note is closed; if it is an allergy/strict-exclusion rule, both recipes need a
  Worcestershire-free variant or removal. I read the run.json wording ("Budget meal-prep,
  14-serving scalable, no seafood") as recipe-class and do NOT block on it, but it deserves one
  explicit ruling from Brad before this wave ships, recorded where the next auditor can see it.

## Non-blocking observations

- Fajita stat.protein 56 vs recompute 56.52 and writer_notes saying 57: half-gram rounding seam,
  understates the benefit, carried from the second audit. Reconcile at the next touch.
- Turkey casserole recompute is 1.4 cal under stat (429.6 vs 431), the wave's largest drift - a
  food-DB row moved after the spec was built. Far inside any gate; note only.
- The seven certified slugs' QA stamps (06:00-06:31) predate their 11:24 spec mtimes. The 11:24
  deltas were mechanical re-renders certified by the first audit and byte-frozen since (confirmed
  again today); with macros, cost literals, and prose independently re-verified here, I carry them
  as clean rather than demanding a third mechanical re-stamp - but the orchestrator should stop
  re-rendering specs after QA without logging a lane event, because it is what makes every audit
  since have to re-prove freshness by hand.
- The dispatch labeled this "first audit of this wave" and listed all 10 slugs including the
  rejected one. Ledger and lane-log tell the true history; the mislabel cost verification time and
  would have been dangerous with a less suspicious reading.
- wave-2.json recipes[] still carries empty title/source_url/protein; slugs array authoritative.
  Cosmetic, unchanged since wave close.

NO-GO. The wave's numbers are publish-ready on 9 of 10 recipes; nothing here needs rework beyond a
QA stamp on philly and fajita's 11:58 bytes, a real resolution of the rolls (repair or formal
removal), and a wave re-close that makes manifest, ledger, and states tell one story. No ledger
audit stamp issued with this verdict.
