GO
scope: narrow re-audit of the three head.description shortenings (Ghost custom_excerpt 300-char limit)
run: hunt-2026-08-15-lowcarb-100  wave 3  (9 slugs)  2026-08-16, written by the wave-3 re-auditor
supersedes: the 15:39:32 GO. That GO's full findings stand and are carried; this file re-certifies the
three specs edited after it and re-attests the other six unchanged.

== SCOPE CLAIM INDEPENDENTLY VERIFIED (not taken from the orchestrator's word) =====================

- Five specs (garlic-butter-steak-bites-zucchini, turkey-meatballs-cream-sauce-skillet,
  pulled-pork-stuffed-peppers, low-carb-taco-cabbage-beef-skillet, sheet-pan-tandoori-chicken-
  cauliflower) are byte-identical to git HEAD and untouched since 14:06:01 - exactly the bytes the
  prior GO certified.
- keto-cheeseburger-skillet: mtime still 14:49:15, the exact certified write from the prior round;
  stat re-read as 524/31/6/40, cost_ps 2.66, "6 grams of carbs or less" phrasing intact - all matching
  the prior audit's recorded values.
- The three edited specs were byte-identical to HEAD at the prior GO, so `git diff HEAD` shows the
  entire post-GO delta: for each of mexican-chorizo-egg-casserole (15:57:30),
  spinach-artichoke-chicken-casserole (15:57:30), flank-steak-parmesan-green-beans (15:56:57) the diff
  is EXACTLY ONE line, head.description. No macro, cost, mapping, ingredient, or step byte moved.

== THE THREE SHORTENED DESCRIPTIONS: ACCURATE AND UNDER LIMIT ======================================

Lengths recomputed first-hand with {{cal}}/{{protein}} expanded from each spec's own stat
(the engine expands before custom_excerpt leaves publish.ps1): 289 / 292 / 290, all under 300.
Sweep extended to all nine wave specs: max expanded length 292, none over. No em dashes introduced.

- mexican-chorizo-egg-casserole (289): "fresh chorizo browned with onion and pepper, layered with
  corn tortillas and cheese, then baked under an egg custard with jalapeno". Every named item is in
  the spec (chorizo 624 g, onion, red bell, tortillas 306 g, pepper jack + cheddar, eggs 850 g,
  jalapeno 42 g). "Fresh" chorizo is retained, which matters given the documented dry-Spanish macro
  divergence. Dish identity, layering, 14 servings, and the macro sentence with the literal 17 g carb
  figure intact. Nit, carried not new: the jalapeno is tossed with the cheese mix (make_it 3), not
  whisked into the custard; the certified intro_html already places it "shot through" the custard, the
  old certified description said the same, and at dish level the claim is true. Non-blocking.
- spinach-artichoke-chicken-casserole (292): "baked under three cheeses" verified against the spec:
  the topping is exactly mozzarella + parmesan + feta (make_it 6, shop_smart "Three cheeses go on
  top"). Cream cheese, the dish's fourth cheese, is named separately as the sauce base in the same
  sentence, so no count is misstated. Dropping "heavy cream" and "quartered" removes detail, claims
  nothing false (both remain in the recipe). "No bread and no flour" retained and true; "under 12
  grams of carbs" true at stat.carbs 10.
- flank-steak-parmesan-green-beans (290): dropped only "lean" and "served". Remaining claims all
  verified: soy sauce, honey, and garlic are in the marinade; dijon mustard dresses the green beans;
  parmesan present; "under 35 grams of carbs" true at stat.carbs 23. Nothing important lost.

== THE STALE-BUILT-HEAD TRAP, CHECKED AND CLOSED ===================================================

db\built\<slug>.head.html for the three slugs was generated 15:52:42-43, BEFORE the spec edits, and
still carries the old over-limit description in its JSON-LD. This does not ship: custom_excerpt /
meta / og / twitter all come from the SPEC (engine\publish.ps1 line 63/134), and the built head is
regenerated before publish because propagate-recipes runs build-cards over every dirty slug - all
nine wave-3 slugs verified UNSTAMPED in pipeline\propagate-stamps.json, so all nine rebuild from
current spec bytes at E4 before the engine reads them. Do not publish through any path that skips
the build-cards step, or the old 369-char JSON-LD description ships disagreeing with the excerpt.

== CARRIED FROM THE 15:39 GO (still standing, not re-litigated) ====================================

- Store-integrity guard alias fix: hard=0, independently A/B verified last round.
- Keto-cheeseburger record chain, all 9 QA certs, wave mechanics, ledger w3 row: certified last round;
  the six untouched specs and keto's unchanged bytes carry those certifications forward.
- Cheddar package-vs-rate rendering ticket and Tandoori Masala buyability: open, non-blocking,
  for the post-publish reviewer.
- CONDITION: this GO certifies the publish chain as self-tested at the prior round and re-confirmed
  green by the orchestrator on current bytes. If wave-publish.ps1, propagate-recipes.ps1 or
  engine\publish.ps1 change before the publish is invoked, re-run their self-tests to green first.

VERDICT: GO. wave-publish -RunDir meal-prep\runs\hunt-2026-08-15-lowcarb-100 -Wave 3, then dispatch
the post-publish reviewer with the two carried tickets. Suggested post-publish check: the live pages'
JSON-LD description should match the new short text, proving the card rebuild ran.
