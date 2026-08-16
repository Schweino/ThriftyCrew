GO
scope: narrow re-audit - one field changed since the 15:39:01 GO: spinach-provolone-stuffed-flank-steak-rolls
head.description, trimmed to clear Ghost's 300-char custom_excerpt limit (the 422 class found on wave 1)
run: hunt-2026-08-15-lowcarb-100  wave 4  (2 slugs)  re-audited 2026-08-16 by recipe-batch-auditor

== CHANGE ISOLATION =================================================================================
Exactly one reader-facing field moved, verified three ways:
  - mtimes: sheet-pan-smoked-sausage-broccoli-cheddar.json is 13:44:05 to the second, the same
    certification mtime the 15:39 audit recorded, same size 19827; byte-identity corroborated.
    The flank spec is 15:57:30, the only wave-4 file touched after the 15:39 GO.
  - git diff vs HEAD on the flank spec: every hunk except head.description is the already-certified
    Neufchatel rebase (writer_notes RESOLVED entries, stat 518/42/6/36, cream-cheese rename, fresh
    spinach bid, re-rendered cost block matching the certified $3.22/$3.68 and 42.74/49.68 figures
    quoted in the 15:39 audit). The single uncertified hunk is the description trim.
  - the run's intake snapshot (intake\spinach-provolone-stuffed-flank-steak-rolls.json, 10:58)
    preserves the pre-trim text, confirming old raw 349 / expanded 336 - genuinely over the limit;
    the recipe could never have published untrimmed.

== LENGTH: MEASURED, NOT TAKEN ON FAITH =============================================================
New description: raw 307, expanded 294 (cal=518, protein=42). Raw is OVER 300, so the GO hinges on
the publisher expanding tokens before the POST. Verified in code, not assumed:
meal-prep\engine\publish.ps1 runs Expand-SpecProse BEFORE $desc = $spec.head.description, and $desc
feeds custom_excerpt, meta_description, og_description, twitter_description. render-tokens.ps1
expands {{cal}}/{{protein}} in head.description specifically (its self-test covers that surface).
The Remove-GhostStaticCurrencyClaims rewrite only fires on price clauses; this description carries
no dollar figure, so nothing re-lengthens it. Ghost receives 294 characters.
Sheet-pan checked for the same defect class (the 15:39 audit predates knowledge of the limit):
raw 293, expanded 280 (cal=447, protein=23). Both slugs clear.

== ACCURACY OF THE TRIMMED DESCRIPTION ==============================================================
Ruled accurate. Walked against the spec's make_it and ingredient basis:
  - "flank steak spread with a cream cheese filling": the filling is cream cheese melted into
    sauteed onion and garlic (make_it 3). The basis is the 1/3 Fat Cream Cheese (Great Value
    Neufchatel) row per Brad's ruling; Neufchatel is sold as a cream cheese product, the buy string
    itself reads "14 oz cream cheese", and the card's own intro, shop_smart, and steps call it
    cream cheese throughout. The meta matches the card; not misleading.
  - dropping "butterflied" and "seared and": omissions, not contradictions. Butterflying (make_it 2)
    and the sear (make_it 5) survive in intro_html and the steps; the rolls genuinely finish in the
    oven, so "and baked" stands alone truthfully. Safe trims for a meta description.
  - "rolled into pinwheels" (old: "rolled and sliced into pinwheels"): pinwheels imply the slice;
    accurate compression.
  - "built for 14 servings": servings 14. "About 518 calories and 42 grams of protein per serving,
    with under 10 grams of carbs": QA recompute 518.2 / 42.5 / 5.9 against stat 518 / 42 / 6.
    All true after expansion.
Voice: no em dashes, plain punctuation, matches the card's register.

== EVERYTHING ELSE STANDS ===========================================================================
Carried forward unchanged from the 15:39 audit, re-anchored by the isolation proof above: categories
1-6 on both recipes, the well-formed w4 ledger row (two separate slug strings, no comma residue),
the alias-aware store-integrity guard (differential 8/13 -> 0/13, not weakening), the annotated
writer_notes, and the ruling that the stale w2 ledger row need not reconcile before publish (it
drives off manifests, not ledger slug lists; still on the follow-up list). No gate weakened; publish
must still run wave-publish's full preflight.

== NON-BLOCKING OBSERVATIONS ========================================================================
1. Nothing in the estate validates head.description's expanded length against Ghost's 300-char
   custom_excerpt limit pre-POST; wave 1 found it by 422. A build-time or preflight check (expand,
   measure, fail closed over 300) belongs on the follow-up list so this class dies estate-wide -
   every unpublished spec in this run and the next should be swept once, cheaply, at build time.
2. The description trim also silently dropped "and sliced" (beyond the three trims named in the
   change note). Ruled accurate above; noted only so the change record is complete.
