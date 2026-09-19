# I143 sweep: the 76 claim words, in five batches for Brad

**Brad's ruling (2026-09-19):** fix all 76 FDA nutrient-claim-word uses on the live catalogue that do not pass
their bar (21 fail it, 55 cannot be computed) across 53 live recipes, in batches he approves. The list they came
from is `design\ready-for-brad\I143-claim-words.md`.

**State: prepared, nothing published, no spec on main.** Every replacement is written into the recipe specs on
the pushed branch `claude/i143-sweep` and proven offline below. The specs stay OFF main on purpose: a spec change
on main reaches the live page without a batch approval, through the daily republish of cards whose price moved
(`meal-prep\lib\gated-republish-lib.ps1`, called from `grocery\check-ad-cycles.ps1`) and through
`propagate-recipes.ps1`. So each batch comes to main only when Brad says so, by the commands under it.

## What each rewrite does

- It removes the claim word and keeps the sentence saying the same true thing in plain words ("about as lean as
  a grocery list gets" becomes "about as short as a grocery list gets"). Where the word was the only thing a
  clause said ("at a lean 562 calories"), the word goes and the number stays.
- Nothing else in any spec moves. Each rewrite is a byte-level replace of one phrase, 71 of them over 53 specs
  (the fajita sentence sits in two fields), 72 spec lines in all.
- **One is a post title.** "Lean BBQ Chicken and Rice Bowls" becomes "BBQ Chicken and Rice Bowls" (the slug does
  not change). `meal-prep\recipes-db.json` carries the same rename on the branch, because every derived copy of
  the name (planner, dinner, cheapnow and stretcher feeds, `public\planner-data.json`, `public\smp-feed.json`, the
  site tools pages) is rebuilt from that file by the daily chain. The BBQ burrito's intro links to the bowls by
  name and changes with it.
- **Seven new phrases keep a claim word because it names a product the recipe buys**, which the ruling's own
  carve-out allows and the same function exempts: "Fat free cheddar" (bbq-chicken-rice-bowls buys Fat Free
  Cheddar), "Sugar-free BBQ sauce(s)" three times in two recipes that buy BBQ Sauce (Sugar Free), "a sugar-free BBQ
  sauce" as an optional swap in pulled-pork-stuffed-peppers, and "low fat cottage cheese" / "the low fat tub" in the
  alfredo lasagna. The old wording said "barbecue", which the product carve-out does not read as BBQ, so the
  spelling now matches the product the recipe buys.
- Three uses were never claims about the dish ("this is not a lean dish" once, "a light lunch" twice) and are
  rewritten anyway, because the ruling is all 76.

## Proof, measured 2026-09-19

Base: the branch was cut from origin/main at `7695b84c1`; no spec, `recipes-db.json`, claim list or claim library
changed on main between that and `b3e012b0e`. Claim library blob `73a790fb84cd599d7efdc2cb293a8e11e7d03f2a`
(`meal-prep\pipeline\nutrient-claim-lib.ps1`), renderer blob `261d7908a1332a505d15a7e923ce1132ef7273f3`
(`meal-prep\pipeline\build-card2.ps1`).

- **The claim audit clears.** `meal-prep\pipeline\audit-nutrient-claims.ps1` over all 584 specs on the branch:
  exit 0, **670 uses, 670 pass, 0 fail, 0 not computable** (before: 746 uses, 670 pass, 21 fail, 55 not
  computable). The 76 are gone and the 670 passing uses are untouched.
- `audit-forbidden-prose.ps1`: 0 findings over 584. `audit-ghost-field-limits.ps1`: 0 findings over 584 (the
  three changed meta descriptions still fit Ghost's 300-character excerpt).
- **Each rebuilt card differs only by the replaced phrases.** Every one of the 53 specs was rendered twice through
  the real `build-card2.ps1` into a temp directory, never `db\built`: once from its spec and `recipes-db.json` at
  the base, once from the branch, same `db\costed.json`, same day. With only the sweep's phrase pairs substituted
  into the base render (in each encoding a card uses: raw, HTML-escaped, JSON-escaped, and with `{{cal}}` already
  expanded), **53 of 53 bodies and heads equal the branch render byte for byte**. 48 bodies and 12 heads changed;
  the 5 unchanged bodies are the burritos whose only change is a meta keyword. So no paywall split, section or
  structure moved. The check was broken once to prove it can fail: a pairs file missing the drunken-noodles keyword
  pair left exactly that slug red with the old keyword shown. The harness was a one-off scratch script
  (render twice, substitute the pairs, compare ordinally); the repeatable check before each batch is the committed
  probe below.
- **No layout change**, so no 375px check was run: every change is words inside an existing paragraph or a
  meta field.

## Also shipping when a batch publishes: the drift already pending on those cards

Publishing a card sends the card as it renders today, and these cards already carry changes the live pages do
not have. Measured before the edits by `meal-prep\pipeline\probe-allergen-backfill.ps1` (blob
`25d9cd57a95f06a8268d735c0eb160b48c3cc153`) over the 53 slugs, against the main checkout's publish journal:
53 of 53 render, 53 of 53 carry the allergen line `audit-allergen-line` derives, and publish would PUT all 53.
Beyond the allergen line (I172, all 53), per card: the rotating "Three more for this week" footer 43, I44's
paywall claim on the Recipe node 34, the cost-composition bar 10, and 4 carrying I138's "healthy" removals, two of
them live titles ("Healthy Chicken, Rice and Broccoli Skillet" and "Healthy Hamburger Helper" become "Chicken,
Rice and Broccoli Skillet" and "Homemade Hamburger Helper"). That drift is NOT fixed or changed here; it is named
per batch so nothing ships unannounced. It is all already on main and already ruled.

**One card outside the 53 names the renamed title.** The live footer of `chicken-pot-pie-biscuit-casserole`
links to "Lean BBQ Chicken and Rice Bowls"; a fresh render of it already reads the new name. It is an optional
extra in batch 1.

## Why not `propagate-recipes.ps1`

`propagate-recipes.ps1 -DryRun` on the branch lists **461 dirty specs of 584**, not 53: propagate carries every
dirty spec and has no `-Slugs`, so it would republish most of the catalogue. Each batch below goes through the
same three steps the daily republish uses (build the named cards, check the allergen line, publish the named
slugs), which `build-cards.ps1`, `audit-allergen-line.ps1` and `publish.ps1` each take as `-Slugs`.

## How to run one batch

In a fresh worktree cut from origin/main (seeded), bring the batch's specs over as a patch, never by
`git checkout <branch> -- <file>`: that would put back a whole file as it stood on the branch's base and undo any
change main has made to it since. Write the patch with `--output`, never a PowerShell `>` (under PS 5.1 that
writes UTF-16 and git refuses it).

```
git fetch origin
git diff --output=$env:TEMP\i143-batch-K.patch origin/main...origin/claude/i143-sweep -- <the batch's files>
git apply --3way $env:TEMP\i143-batch-K.patch
powershell -NoProfile -File meal-prep\pipeline\audit-nutrient-claims.ps1
powershell -NoProfile -File meal-prep\pipeline\probe-allergen-backfill.ps1 -Slugs <the batch's slugs> -PublishedHashes C:\Codex\ThriftyCrew\meal-prep\db\published-hashes.json
```
The audit's non-passing count must fall by the batch's use count. The probe is the DRY RUN: it renders the batch
offline and prints what `publish.ps1` would do with each card; expect every slug rendered, every allergen line
"agrees", every decision `put`, exit 0. Then commit those files (message in a file, `-F`) and land with
`powershell -NoProfile -File ops\push-main.ps1`. Then, in the main checkout once it holds the landed commit:
```
powershell -NoProfile -File grocery\audit-ghost-drift.ps1 -Recipes
powershell -NoProfile -File meal-prep\engine\build-cards.ps1 -Slugs <the batch's slugs>
powershell -NoProfile -File meal-prep\pipeline\audit-allergen-line.ps1 -Slugs <the batch's slugs>
powershell -NoProfile -File meal-prep\engine\publish.ps1 -Slugs <the batch's slugs>
```
Read each exit code before the next. The first three write nothing live. `build-cards` must say
`built N/N errors 0`; `audit-allergen-line` must exit 0; `publish.ps1` is the only Ghost write, hash-gated and
live-verified per slug. If publish refuses a slug as "the LIVE card no longer matches", that is its drift guard
and the drift report says why; do not reach for `-Force`.

The exact files and slugs for each batch are written out under its table. Batches 1 and 2 hold every use that
FAILS its bar (21 of 21); batches 3 to 5 are the uses that could not be computed.

## Batch 1: 10 recipes, 24 uses (14 fail their bar, 10 cannot be computed)

| Recipe | Field | Old phrase | New phrase |
|---|---|---|---|
| bbq-chicken-rice-bowls | head.keywords | `bbq chicken bowl, low fat meal prep, budget dinner` | `bbq chicken bowl, chicken and rice meal prep, budget dinner` |
| bbq-chicken-rice-bowls | name (the post title; recipes-db.json carries the same rename) | `Lean BBQ Chicken and Rice Bowls` | `BBQ Chicken and Rice Bowls` |
| bbq-chicken-rice-bowls | shop_smart[2] | `<strong>Fat free cheese stretches the protein.</strong> A quarter cup adds 9 grams of protein for 45 calories and zero fat.` | `<strong>Fat free cheddar stretches the protein.</strong> A quarter cup adds 9 grams of protein for 45 calories.` |
| bbq-chicken-burrito | head.description | `built on a lean blended crema.` | `built on a blended cottage cheese crema.` |
| bbq-chicken-burrito | head.keywords | `high protein meal prep, low calorie burrito, cheap meal prep` | `high protein meal prep, meal prep burrito, cheap meal prep` |
| bbq-chicken-burrito | intro_html | `If you like our Lean BBQ Chicken and Rice Bowls,` | `If you like our BBQ Chicken and Rice Bowls,` |
| bbq-chicken-burrito | shop_smart[0] | `If you want to shave carbs, the no-sugar-added versions taste nearly identical once they hit the hot chicken.` | `If you want to shave carbs, compare the sugar grams on the labels and grab the bottle with the fewest. It tastes nearly identical once it hits the hot chicken.` |
| bbq-chicken-burrito | shop_smart[2] | `it turns a normally fatty sauce into a lean one.` | `it carries a creamy sauce that is usually all mayo.` |
| chicken-enchilada-rice-bowls | cost_closing_html | `for a lean, cheesy enchilada bowl` | `for a cheesy, filling enchilada bowl` |
| chicken-enchilada-rice-bowls | shop_smart[2] | `for 45 calories and no fat, which is why it earns its spot in the lean bowls.` | `for 45 calories, which is why it earns its spot in these bowls.` |
| chicken-enchilada-rice-bowls | upsell_html | `Lean, cheesy dinners for about` | `Cheesy, filling dinners for about` |
| fajita-chicken-rice-bowl | head.description + intro_html | `A high-protein, low-fat Tex-Mex chicken,` | `A high-protein Tex-Mex chicken,` |
| hot-honey-chicken-bowls | cost_closing_html | `for a lean, crave-worthy dinner` | `for a crave-worthy dinner` |
| hot-honey-chicken-bowls | head.keywords | `hot honey chicken, low fat meal prep, budget dinner` | `hot honey chicken, chicken bowl meal prep, budget dinner` |
| hot-honey-chicken-bowls | upsell_html | `Lean, crave-worthy dinners for about` | `Crave-worthy dinners for about` |
| high-protein-chicken-alfredo-lasagna | shop_smart[0] | `Full fat or low fat both work; low fat trims the fat number` | `Full fat or low fat cottage cheese both work; the low fat tub trims the fat number` |
| chimichurri-steak-sheet-pan | shop_smart[1] | `keeps this from eating like a light lunch.` | `keeps this from eating like a snack plate.` |
| greek-turkey-fasolakia-rice-bowls | intro_html | `which turns a light lunch into a container` | `which turns a summer side into a container` |
| ground-beef-teriyaki-bowls | portion_html | `keeping this one light, sweet, and filling.` | `keeping this one sweet, saucy, and filling.` |
| honey-bbq-chicken-mac-and-cheese | make_it[4] | `which is the whole trick to keeping this light.` | `which is the whole trick to getting it smooth.` |

Pending drift that ships with this batch (already on main, named above): allergen line 10, footer 7, Recipe paywall claim 6, cost bar 1, and honey-bbq-chicken-mac-and-cheese's I138 keyword change ("healthy mac and cheese" becomes "one pot mac and cheese").

```
# files for the patch
meal-prep/db/recipes/bbq-chicken-rice-bowls.json meal-prep/db/recipes/bbq-chicken-burrito.json meal-prep/db/recipes/chicken-enchilada-rice-bowls.json meal-prep/db/recipes/fajita-chicken-rice-bowl.json meal-prep/db/recipes/hot-honey-chicken-bowls.json meal-prep/db/recipes/high-protein-chicken-alfredo-lasagna.json meal-prep/db/recipes/chimichurri-steak-sheet-pan.json meal-prep/db/recipes/greek-turkey-fasolakia-rice-bowls.json meal-prep/db/recipes/ground-beef-teriyaki-bowls.json meal-prep/db/recipes/honey-bbq-chicken-mac-and-cheese.json meal-prep/recipes-db.json
# slugs for the probe, build-cards, audit-allergen-line and publish
bbq-chicken-rice-bowls,bbq-chicken-burrito,chicken-enchilada-rice-bowls,fajita-chicken-rice-bowl,hot-honey-chicken-bowls,high-protein-chicken-alfredo-lasagna,chimichurri-steak-sheet-pan,greek-turkey-fasolakia-rice-bowls,ground-beef-teriyaki-bowls,honey-bbq-chicken-mac-and-cheese
```

Optional, after batch 1 is live: `build-cards.ps1 -Slugs chicken-pot-pie-biscuit-casserole`, then `audit-allergen-line.ps1` and `publish.ps1` with the same slug, so its footer stops naming the old title. That card carries its own pending drift too; run the probe on it first.


## Batch 2: 11 recipes, 13 uses (7 fail their bar, 6 cannot be computed)

| Recipe | Field | Old phrase | New phrase |
|---|---|---|---|
| chicken-bacon-ranch-burrito | head.keywords | `high protein meal prep, low calorie burrito, cheap meal prep` | `high protein meal prep, meal prep burrito, cheap meal prep` |
| chicken-refried-bean-burrito | head.keywords | `budget burrito meal prep, low calorie chicken burrito` | `budget burrito meal prep, chicken bean burrito` |
| chicken-refried-bean-burrito | shop_smart[2] | `the sour cream stand-in that keeps this whole batch lean.` | `the sour cream stand-in that carries the whole batch.` |
| green-chile-turkey-burrito | head.keywords | `high protein burrito, low calorie meal prep, budget dinner` | `high protein burrito, green chile meal prep, budget dinner` |
| honey-chipotle-chicken-burrito | head.keywords | `high protein meal prep, low calorie burrito, cheap meal prep` | `high protein meal prep, meal prep burrito, cheap meal prep` |
| ranch-chicken-burrito | head.keywords | `high protein meal prep, low calorie burrito, cheap meal prep` | `high protein meal prep, meal prep burrito, cheap meal prep` |
| salsa-verde-chicken-burrito | head.keywords | `cottage cheese crema, low calorie burrito, budget chicken burrito` | `cottage cheese crema, shredded chicken burrito, budget chicken burrito` |
| thai-peanut-chicken-burrito | head.keywords | `avocado chicken burrito, low calorie burrito, budget meal prep` | `avocado chicken burrito, meal prep burrito, budget meal prep` |
| thai-peanut-chicken-burrito | shop_smart[0] | `Buy the natural kind with no added sugar so the honey does the sweetening on your terms.` | `Buy the natural kind and check the ingredient list for sugar, so the honey does the sweetening on your terms.` |
| buffalo-chicken-burrito | cost_closing_html | `The cottage sauce is the trick that keeps it both creamy and lean.` | `The cottage sauce is the trick that keeps it both creamy and filling.` |
| creamy-chicken-fajita-burrito | shop_smart[3] | `Reduced fat mozzarella melts creamy for fewer calories than full fat, and the bag` | `Reduced fat mozzarella still melts creamy, and the bag` |
| green-chile-chicken-burrito | intro_html | `keeps it fast and lean.` | `keeps it fast and simple.` |
| korean-bulgogi-beef-burrito | shop_smart[2] | `sweetens the marinade with no added sugar, and you eat` | `sweetens the marinade, and you eat` |

Pending drift that ships with this batch (already on main, named above): allergen line 11, footer 11, Recipe paywall claim 9, cost bar 2.

```
# files for the patch
meal-prep/db/recipes/chicken-bacon-ranch-burrito.json meal-prep/db/recipes/chicken-refried-bean-burrito.json meal-prep/db/recipes/green-chile-turkey-burrito.json meal-prep/db/recipes/honey-chipotle-chicken-burrito.json meal-prep/db/recipes/ranch-chicken-burrito.json meal-prep/db/recipes/salsa-verde-chicken-burrito.json meal-prep/db/recipes/thai-peanut-chicken-burrito.json meal-prep/db/recipes/buffalo-chicken-burrito.json meal-prep/db/recipes/creamy-chicken-fajita-burrito.json meal-prep/db/recipes/green-chile-chicken-burrito.json meal-prep/db/recipes/korean-bulgogi-beef-burrito.json
# slugs for the probe, build-cards, audit-allergen-line and publish
chicken-bacon-ranch-burrito,chicken-refried-bean-burrito,green-chile-turkey-burrito,honey-chipotle-chicken-burrito,ranch-chicken-burrito,salsa-verde-chicken-burrito,thai-peanut-chicken-burrito,buffalo-chicken-burrito,creamy-chicken-fajita-burrito,green-chile-chicken-burrito,korean-bulgogi-beef-burrito
```


## Batch 3: 11 recipes, 13 uses (0 fail their bar, 13 cannot be computed)

| Recipe | Field | Old phrase | New phrase |
|---|---|---|---|
| cheesy-ground-beef-tortellini | shop_smart[1] | `makes the sauce creamy for less money and fewer calories than heavy cream,` | `makes the sauce creamy for less money than heavy cream,` |
| chicken-florentine | intro_html | `while eating like it has no business being that lean.` | `while eating like a much heavier plate.` |
| chicken-rice-and-broccoli | cost_closing_html | `is about as lean as a grocery list gets,` | `is about as short as a grocery list gets,` |
| chicken-rice-and-broccoli | intro_html | `That is a lean, honest number.` | `That is a solid, honest number.` |
| chicken-souvlaki-rice-bowls | intro_html | `at a lean {{cal}} calories` | `at {{cal}} calories` |
| creamy-tomato-ground-turkey-gnocchi | shop_smart[0] | `gives you 3.75 pounds of lean protein for the batch.` | `gives you 3.75 pounds of meat for the batch.` |
| filipino-chicken-inasal-bowls | intro_html | `at a lean {{cal}} calories` | `at {{cal}} calories` |
| grilled-pork-tenderloin-burrito-bowl | cost_closing_html | `The tenderloin is the whole trick: lean, tender, and cheaper than people assume.` | `The tenderloin is the whole trick: tender, quick to cook, and cheaper than people assume.` |
| ground-beef-stroganoff-pasta | portion_html | `still earns its spot on a lean plan.` | `still earns its spot in the rotation.` |
| ground-beef-stroganoff-pasta | shop_smart[1] | `gives you the classic creamy tang with less fat, and one tub` | `gives you the classic creamy tang, and one tub` |
| healthy-hamburger-helper | make_it[1] | `but 93/7 stays pretty lean.` | `but 93/7 does not give up much.` |
| italian-ground-turkey-white-bean-skillet | shop_smart[0] | `The 93/7 blend keeps it lean without cooking up dry and chalky` | `The 93/7 blend keeps enough fat to stay juicy instead of cooking up dry and chalky` |
| machaca-beef-burrito | intro_html | `This build keeps it lean and honest at about` | `This build keeps it simple and honest at about` |

Pending drift that ships with this batch (already on main, named above): allergen line 11, footer 7, Recipe paywall claim 6, cost bar 3, and the two I138 title changes (chicken-rice-and-broccoli, healthy-hamburger-helper).

```
# files for the patch
meal-prep/db/recipes/cheesy-ground-beef-tortellini.json meal-prep/db/recipes/chicken-florentine.json meal-prep/db/recipes/chicken-rice-and-broccoli.json meal-prep/db/recipes/chicken-souvlaki-rice-bowls.json meal-prep/db/recipes/creamy-tomato-ground-turkey-gnocchi.json meal-prep/db/recipes/filipino-chicken-inasal-bowls.json meal-prep/db/recipes/grilled-pork-tenderloin-burrito-bowl.json meal-prep/db/recipes/ground-beef-stroganoff-pasta.json meal-prep/db/recipes/healthy-hamburger-helper.json meal-prep/db/recipes/italian-ground-turkey-white-bean-skillet.json meal-prep/db/recipes/machaca-beef-burrito.json
# slugs for the probe, build-cards, audit-allergen-line and publish
cheesy-ground-beef-tortellini,chicken-florentine,chicken-rice-and-broccoli,chicken-souvlaki-rice-bowls,creamy-tomato-ground-turkey-gnocchi,filipino-chicken-inasal-bowls,grilled-pork-tenderloin-burrito-bowl,ground-beef-stroganoff-pasta,healthy-hamburger-helper,italian-ground-turkey-white-bean-skillet,machaca-beef-burrito
```


## Batch 4: 11 recipes, 12 uses (0 fail their bar, 12 cannot be computed)

| Recipe | Field | Old phrase | New phrase |
|---|---|---|---|
| pizza-pasta-bowls | shop_smart[0] | `It brings the same pizza flavor with less fat, which is why` | `It brings the same pizza flavor, which is why` |
| pork-fried-rice-bowls | shop_smart[0] | `It is lean, it slices thin without a fight,` | `It cooks fast, it slices thin without a fight,` |
| pulled-pork-stuffed-peppers | shop_smart[3] | `a sugar-free barbecue sauce swaps in` | `a sugar-free BBQ sauce swaps in` |
| salisbury-steak-potato-bowls | intro_html | `comfort food done lean and cheap.` | `comfort food done simple and cheap.` |
| senfbraten-german-mustard-pork-roast | intro_html | `It is a lean, high protein plate at 53 grams` | `It is a high protein plate at 53 grams` |
| senfbraten-german-mustard-pork-roast | shop_smart[0] | `and loin is lean enough that you are paying for meat, not trim.` | `and a loin has so little waste that you are paying for meat, not trim.` |
| sheet-pan-pork-tenderloin-potatoes-green-beans | cost_closing_html | `for a lean protein, a starch and a vegetable` | `for a protein, a starch and a vegetable` |
| slow-cooker-chicken-gyro-bowls | portion_html | `lean and filling in equal measure.` | `fresh and filling in equal measure.` |
| slow-cooker-filipino-pork-adobo-bowls | shop_smart[1] | `Pork loin keeps this lean and affordable.` | `Pork loin keeps this simple and affordable.` |
| slow-cooker-mongolian-chicken-bowls | portion_html | `a genuinely lean, high-protein plate.` | `a genuinely high-protein plate.` |
| slow-cooker-pork-tinga-bowls | shop_smart[2] | `Pork loin keeps this cheap and lean.` | `Pork loin keeps this cheap and easy.` |
| slow-cooker-pulled-pork-bowl | shop_smart[1] | `Sugar-free sauces vary a lot in price.` | `Sugar-free BBQ sauces vary a lot in price.` |

Pending drift that ships with this batch (already on main, named above): allergen line 11, footer 10, Recipe paywall claim 7, cost bar 1.

```
# files for the patch
meal-prep/db/recipes/pizza-pasta-bowls.json meal-prep/db/recipes/pork-fried-rice-bowls.json meal-prep/db/recipes/pulled-pork-stuffed-peppers.json meal-prep/db/recipes/salisbury-steak-potato-bowls.json meal-prep/db/recipes/senfbraten-german-mustard-pork-roast.json meal-prep/db/recipes/sheet-pan-pork-tenderloin-potatoes-green-beans.json meal-prep/db/recipes/slow-cooker-chicken-gyro-bowls.json meal-prep/db/recipes/slow-cooker-filipino-pork-adobo-bowls.json meal-prep/db/recipes/slow-cooker-mongolian-chicken-bowls.json meal-prep/db/recipes/slow-cooker-pork-tinga-bowls.json meal-prep/db/recipes/slow-cooker-pulled-pork-bowl.json
# slugs for the probe, build-cards, audit-allergen-line and publish
pizza-pasta-bowls,pork-fried-rice-bowls,pulled-pork-stuffed-peppers,salisbury-steak-potato-bowls,senfbraten-german-mustard-pork-roast,sheet-pan-pork-tenderloin-potatoes-green-beans,slow-cooker-chicken-gyro-bowls,slow-cooker-filipino-pork-adobo-bowls,slow-cooker-mongolian-chicken-bowls,slow-cooker-pork-tinga-bowls,slow-cooker-pulled-pork-bowl
```


## Batch 5: 10 recipes, 14 uses (0 fail their bar, 14 cannot be computed)

| Recipe | Field | Old phrase | New phrase |
|---|---|---|---|
| slow-cooker-root-beer-pulled-pork-bowls | intro_html | `sugar-free barbecue sauce keep this pulled pork lean while the slow cooker` | `sugar-free BBQ sauce do the sweetening while the slow cooker` |
| slow-cooker-root-beer-pulled-pork-bowls | shop_smart[0] | `Sugar-free barbecue sauce cuts the sugar` | `Sugar-free BBQ sauce cuts the sugar` |
| slow-cooker-salsa-verde-chicken-bowl | intro_html | `It is loaded with lean protein and a squeeze of lime` | `It is loaded with tender chicken and a squeeze of lime` |
| slow-cooker-salsa-verde-pork-bowls | shop_smart[0] | `Pork tenderloin runs lean and clean, but watch the tag.` | `Pork tenderloin is easy to work with, but watch the tag.` |
| south-indian-chettinad-pepper-chicken-bowls | intro_html | `Big flavor, lean numbers.` | `Big flavor, honest numbers.` |
| southwest-ground-turkey-cauliflower-rice-skillet | shop_smart[0] | `The 93/7 blend stays lean without cooking up dry and chalky` | `The 93/7 blend keeps enough fat to stay juicy instead of cooking up dry and chalky` |
| thai-red-curry-chicken-rice-bowls | intro_html | `Lean has never tasted less like a punishment.` | `Chicken breast has never tasted less like a punishment.` |
| turkey-bolognese-penne | intro_html | `made lean with ground turkey.` | `made with ground turkey.` |
| turkey-chile-relleno-casserole-skillet | cost_closing_html | `This is not a lean dish and it was never trying to be.` | `This one was never trying to go easy on the cheese.` |
| turkey-drunken-noodles | cost_closing_html | `for lean drunken noodles.` | `for turkey drunken noodles.` |
| turkey-drunken-noodles | head.description | `Lean pad kee mao with basil and jalapeno heat.` | `Turkey pad kee mao with basil and jalapeno heat.` |
| turkey-drunken-noodles | head.keywords | `lean noodle meal prep,` | `noodle meal prep,` |
| turkey-fajita-rice-bowls | portion_html | `at just {{cal}} calories, which keeps this one lean and filling.` | `at just {{cal}} calories, and it still eats like a full dinner.` |

Pending drift that ships with this batch (already on main, named above): allergen line 10, footer 8, Recipe paywall claim 6, cost bar 3, and turkey-bolognese-penne's I138 keyword change ("healthy pasta" becomes "turkey pasta").

```
# files for the patch
meal-prep/db/recipes/slow-cooker-root-beer-pulled-pork-bowls.json meal-prep/db/recipes/slow-cooker-salsa-verde-chicken-bowl.json meal-prep/db/recipes/slow-cooker-salsa-verde-pork-bowls.json meal-prep/db/recipes/south-indian-chettinad-pepper-chicken-bowls.json meal-prep/db/recipes/southwest-ground-turkey-cauliflower-rice-skillet.json meal-prep/db/recipes/thai-red-curry-chicken-rice-bowls.json meal-prep/db/recipes/turkey-bolognese-penne.json meal-prep/db/recipes/turkey-chile-relleno-casserole-skillet.json meal-prep/db/recipes/turkey-drunken-noodles.json meal-prep/db/recipes/turkey-fajita-rice-bowls.json
# slugs for the probe, build-cards, audit-allergen-line and publish
slow-cooker-root-beer-pulled-pork-bowls,slow-cooker-salsa-verde-chicken-bowl,slow-cooker-salsa-verde-pork-bowls,south-indian-chettinad-pepper-chicken-bowls,southwest-ground-turkey-cauliflower-rice-skillet,thai-red-curry-chicken-rice-bowls,turkey-bolognese-penne,turkey-chile-relleno-casserole-skillet,turkey-drunken-noodles,turkey-fajita-rice-bowls
```


