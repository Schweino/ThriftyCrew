# Batch 2 (items 26-50) - hijack + relax_global findings

Agent B slice: bok-choy, butternut-squash, acorn-squash, spaghetti-squash, sugar-snap-peas,
spring-mix, arugula, garden-salad, caesar-salad-kit, coleslaw-mix, fresh-stir-fry-blend,
bean-sprouts, broccolini, fennel, chayote, yuca-root, jicama, okra, artichokes, rhubarb,
pie-pumpkins, fresh-parsley, fresh-dill, fresh-rosemary, fresh-thyme.

Verified against the real `$GLOBAL_EXCLUDE` in `compare-deals.ps1` (lines 564-577) and the
real include/exclude arrays in `commodities.json` (453 commodities). All rules are in
`rules-b2-b.json`; nothing in `commodities.json` was edited.

Note on slice boundaries: `turnip-greens` is item 24 of batch2.json, i.e. the OTHER agent's
slice (items 1-25), so the turnip-greens-vs-turnips root/greens boundary is theirs to draft;
none of my 25 items touch turnip tokens.

---

## sugar-snap-peas  (BLOCKING hijack - existing `snow-peas`)

`snow-peas` include is literally:
`snow\s+peas | sugar\s+snap\s+peas | \bsnap\s+peas | pea\s+pods`

Two of those four patterns match every sugar snap product, and snow-peas sits earlier in the
file, so first-match-wins routes 100% of sugar snap peas to snow-peas. The new commodity
receives NOTHING until this is fixed.

**Add to `snow-peas` exclude:** `sugar\s+snap`

That single exclude neutralizes both the `sugar\s+snap\s+peas` and `\bsnap\s+peas` include
hits on sugar-snap titles (exclude wins after include). Cleaner long-term: also DELETE
`sugar\s+snap\s+peas` and `\bsnap\s+peas` from snow-peas' include list when the new
commodity registers - `\bsnap\s+peas` alone still matches "Sugar Snap Peas" text and only
the exclude is holding the line.

My side: sugar-snap-peas excludes `snow\s+peas?` so it can never steal a snow pea.

## spaghetti-squash  (hijack - existing `pasta`)

`pasta` include contains bare `spaghetti` (unanchored), which substring/phrase-matches
"Spaghetti Squash". pasta's excludes (sauce, cheese, canned, ravioli, ... manicotti) have no
squash token, so pasta steals every spaghetti squash today.

**Add to `pasta` exclude:** `\bsquash\b`

Safe for pasta: no dry pasta product carries the word "squash" (butternut-squash ravioli is
already excluded by pasta's `ravioli`).

## broccolini  (hijack - existing `broccoli`)

`broccoli` include is bare unanchored `broccoli`, which substring-matches "Broccolini" and
phrase-matches "Baby Broccoli" / "Broccolette". broccoli's excludes (frozen, cheese, soup,
slaw, tots, steam, cuts) catch none of them.

**Add to `broccoli` exclude:** `broccolini` , `baby\s+broccoli` , `broccolette`

My side: broccolini's includes cannot match plain broccoli crowns/bunches/florets.

## garden-salad  (hijack - existing `lettuce`)

`lettuce` include: `\blettuce\b | \biceberg\b | \bromaine\b`. A garden-blend bag titled
"Classic Iceberg Salad" (Dole/Marketside style) hits `\biceberg\b` and none of lettuce's
excludes (`\bkit\b`, `\bblend\b`, `shredded`, `chopped`, `salad\s+mix`) - lettuce steals it.

**Add to `lettuce` exclude:** `garden\s+salad` , `classic\s+iceberg\s+salad`

Safe for lettuce: head/hearts iceberg and romaine titles never carry those phrases.
(Titles like "Garden Salad Mix" / "Iceberg Salad Blend" were already lettuce-excluded via
`salad\s+mix` / `\bblend\b`; these two patterns close the remaining bare-"salad" gap.)

## spring-mix  (hijack - existing `spinach`)

`spinach` include is bare `spinach`. The 50/50 product ("Spinach & Spring Mix 50/50 Blend")
contains the word spinach, so existing spinach first-match-steals it from the new spring-mix
commodity (candidate notes say 50/50 belongs to spring-mix; spinach is for spinach-only packs).

**Add to `spinach` exclude:** `spring\s+mix` , `50\s*/\s*50`

Safe for spinach: pure spinach packs (fresh, canned, boxed) never carry either phrase.

## fresh-parsley  (hijack - existing `dried-parsley`)

`dried-parsley` include is bare `parsley`; excludes only `\bfresh\b`, `\bplant\b`,
`\bbunch\b`, `\bliving\b`, `\bcurly\b\s+\bbunch\b` (+ dressing/salad/butter/potato/cheese).
Produce titles WITHOUT the words fresh/bunch - "Italian Parsley", "Flat Leaf Parsley",
"Curly Parsley", "Organic Parsley Clamshell" - are stolen by the spice item today.

**Add to `dried-parsley` exclude:** `italian\s+parsley` , `flat[\s-]?leaf` , `curly\s+parsley` , `clamshell`

Safe for dried-parsley: spice jars are titled "Parsley" / "Parsley Flakes" / "Dried Parsley".
My side: fresh-parsley excludes `\bdried\b` + `flakes?` so it can never steal the jar.

## fresh-dill  (hijack - existing `dried-dill`)

`dried-dill` include: `dill\s+weed | dried\s+dill` - and its excludes have NO `\bfresh\b`.
Fresh dill is routinely titled "Dill Weed" / "Fresh Dill Weed" at Kroger-family stores, so
the spice item steals those bunches today.

**Add to `dried-dill` exclude:** `\bfresh\b` , `\bbunch\b` , `clamshell` , `\bsprigs?\b`

After the fix, "Fresh Dill Weed" falls through to my `fresh\s+dill` include. A produce pack
titled bare "Dill Weed" (no fresh/bunch/clamshell) stays with dried-dill - ambiguous either
way, accepted. My side: excludes pickle/pickled/relish/dip/seed so the pickles boundary is
sealed in both directions (`pickles` includes `dill\s+spears`, which my includes cannot match).

## fresh-thyme  (hijack - existing `dried-thyme`)

`dried-thyme` include is bare `\bthyme\b`; excludes only fresh/plant/living/seeds. Fresh
clamshell packs titled "Thyme 0.75 oz" or "Organic Thyme" are stolen by the spice item today.

**Add to `dried-thyme` exclude:** `clamshell` , `\bbunch\b` , `\bsprigs?\b`

Do NOT add an oz-size exclude (dried thyme jars are themselves ~0.62 oz). Titles that are
just "Thyme"/"Organic Thyme" with no form word remain with dried-thyme - accepted; my
includes stay anchored (fresh/clamshell/bunch/sprig) rather than gambling on bare tokens.

## fresh-rosemary  (no hijack partner - note only)

There is NO dried-rosemary commodity, so nothing steals from fresh-rosemary and no existing
exclude is needed. Anchored includes (fresh/clamshell/bunch/sprig) mean a spice jar titled
bare "Rosemary" is NOT matched - and a fresh pack titled bare "Rosemary" is missed until
real store titles are captured (conservative, flagged in the rule note).

## artichokes  (boundary with existing `artichoke-hearts` - sealed, no change needed)

Candidate notes: hearts are NOT wanted. `artichoke-hearts` sits earlier in the file and owns
hearts/quarters/marinated; my rule additionally excludes hearts?/quarters?/marinated/jarred.
artichoke-hearts already excludes `\bfresh\b` and `\bfrozen\b`, so fresh whole artichokes
fall through to my rule. No edit to artichoke-hearts required.

## fennel  (boundary with existing `ground-fennel` - sealed, no change needed)

`ground-fennel` already excludes `\bbulb\b` and `fresh\s+fennel`; my includes are
bulb/fresh/start-anchored and my excludes block seed/ground/pollen. No edit required.

---

# relax_global tokens needed (verbatim from compare-deals.ps1)

The mix token's exact string, INCLUDING the lookahead, is:  `\bmix\b(?!\s*(?:&|and)\s*match)`
The kit token's exact string is:  `\bkit\b`

| commodity | relax_global (exact token string) | why |
|---|---|---|
| spring-mix | `\bmix\b(?!\s*(?:&|and)\s*match)` | product IS named "Spring Mix" |
| coleslaw-mix | `\bmix\b(?!\s*(?:&|and)\s*match)` | product IS named "Coleslaw Mix" |
| garden-salad | `\bmix\b(?!\s*(?:&|and)\s*match)` | common titles "Garden/Classic Salad Mix" |
| fresh-stir-fry-blend | `\bmix\b(?!\s*(?:&|and)\s*match)` | produce blends titled "Stir Fry Mix" |
| caesar-salad-kit | `\bkit\b` | every product title carries "kit" |

These are already embedded as `relax_global` arrays on the five rule objects in
`rules-b2-b.json`. All other 20 items were checked token-by-token against the full global
list (drink mix, kool-aid, dip, sauce, kit, flavored, soup, frozen, canned, snack, meal,
juice-with-lookbehind, water, cocktail, tart, mix-with-lookahead, etc.) - no other item's
own name or expected product titles inherently contain a blocked token. Deliberate
non-relaxes: fresh-stir-fry-blend does NOT relax `\bwater\b` (titles naming water chestnuts
are dropped - conservative); artichokes does NOT relax `marinated` (marinated = hearts item).
