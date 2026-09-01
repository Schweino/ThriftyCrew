<#
  test-commodity-rules.ps1 - FROZEN REGRESSION FIXTURES for individual commodity include/exclude rules.

  WHY THIS FILE EXISTS, AND WHY IT IS NOT test-match-lib.ps1. That suite proves the two MATCHER
  implementations agree with each other on the real corpus - which product a rule claims, decided the
  same way twice. It says nothing about whether the RULE IS RIGHT. A row can be matched identically by
  both implementations and still be wrong about the food, and nothing in this estate noticed when one
  was: `chicken-thighs` carried `exclude: \bdrumsticks?\b` while its own label read
  "Chicken Thighs / Drumsticks", so every real chicken drumstick was removed from the id that claimed
  to carry them, and the board answered `chicken drumsticks` with seven stores of THIGHS.

  It was found on 2026-08-24 by the Recipe Hunter's 6b run - a recipe wanting drumsticks - and not by
  any guard here, because no guard here asks "does this row's rule do what its label says".

  THE SHAPE. Each case is (commodity id, a REAL product name seen in a capture, expected verdict, why).
  Real names only: an invented product name proves the regex compiles, not that it matches the shelf.
  A case whose product no longer appears in any capture is still worth keeping - the rule outlives the
  week's assortment - but the name must have been real when the case was written.

  ADD A CASE whenever a commodity rule is fixed, on the same day, with the product that exposed it.
  That is the estate's standing rule: a fix whose founding case is not frozen next to it drifts back
  into the dead-guard pile.

  Exit 0 = every case holds. Exit 1 = at least one rule no longer does what its case says.
#>
param([string]$File = '', [switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $File) { $File = Join-Path $root 'commodities.json' }

if (-not (Test-Path $File)) {
  Write-Output ("test-commodity-rules: CANNOT RUN - no commodities file at {0}" -f $File)
  exit 2
}
$rows = Get-Content $File -Raw -Encoding utf8 | ConvertFrom-Json
$byId = @{}
foreach ($r in $rows) { if ($r.id) { $byId[[string]$r.id] = $r } }

function Get-RuleVerdict {
  <#
    The rule as the board applies it: an include must match, and then no exclude may. Returns
    'included', 'excluded:<pattern>', or 'no-include-match'. The three are DIFFERENT answers and a
    fixture that collapses them would pass while a row silently stopped matching anything at all.
  #>
  param($Row, [string]$Name)
  $inc = @($Row.include)
  $exc = @($Row.exclude)
  $hit = $false
  foreach ($p in $inc) { if ($p -and $Name -match $p) { $hit = $true; break } }
  if (-not $hit) { return 'no-include-match' }
  foreach ($p in $exc) { if ($p -and $Name -match $p) { return ('excluded:' + $p) } }
  return 'included'
}

# =====================================================================================================
# THE CASES. Product names are verbatim from grocery\out\captures\*.csv on the date noted.
# =====================================================================================================
$cases = @(
  # ---- chicken-thighs, label "Chicken Thighs / Drumsticks" (fixed 2026-08-24) --------------------
  # The founding case. All three drumstick names below were in the captures and priced BELOW the
  # cheapest thigh ($0.98/lb against $1.28), so the exclusion cost accuracy and money at once.
  @{ id='chicken-thighs'; name="Member's Mark Chicken Drumsticks, priced per pound"; expect='included'
     why='FOUNDING CASE: the id whose label says "Chicken Thighs / Drumsticks" must carry a drumstick' }
  @{ id='chicken-thighs'; name='fresh fresh chicken drumsticks family pack per lb'; expect='included'
     why='and an Aldi drumstick pack, which is the cheapest bone-in chicken on the board' }
  @{ id='chicken-thighs'; name='kirkwood fresh chicken drumsticks per lb'; expect='included'
     why='three real drumstick names, because a collection fixture takes at least three' }
  @{ id='chicken-thighs'; name="Member's Mark Chicken Thighs, Case, priced per pound"; expect='included'
     why='CLEAN TWIN the thighs the id has always carried are untouched by the fix' }
  @{ id='chicken-thighs'; name='Nestle Drumstick Cone Variety Pack, Frozen 16 ct.'; expect='no-include-match'
     why='the ice cream the old exclusion was aimed at. It never matched an include in the first place - it has no "chicken" in it - which is why removing that exclusion was free' }
  @{ id='chicken-thighs'; name='Tyson Chicken Nuggets'; expect='no-include-match'
     why='CLEAN TWIN a chicken product that is not a thigh or a drumstick still does not match' }

  # ---- rice (fixed 2026-08-24) ------------------------------------------------------------------
  # `rice` includes a bare \brice\b, so "cauliflower rice" mapped to it and priced as white rice at
  # 7 of 7 stores. Found while checking whether the Recipe Hunter could safely price the cheapest of
  # a set of ALTERNATIVES: it could not, while the matcher would substitute a different food.
  @{ id='rice'; name='Birds Eye Cauliflower Rice 12 oz'; expect='excluded'
     why='FOUNDING CASE: cauliflower rice is not rice and must not price as it' }
  @{ id='rice'; name='Green Giant Riced Cauliflower 10 oz'; expect='no-include-match'
     why='the other phrasing of the same food' }
  @{ id='rice'; name="Member's Mark Long Grain White Rice, 50 lbs."; expect='included'
     why='CLEAN TWIN actual rice is untouched by the exclusion' }
  @{ id='rice'; name='Great Value Long Grain Enriched Rice, 20 lb'; expect='included'
     why='CLEAN TWIN and so is the Walmart row' }

  # =================================================================================================
  # 2026-09-01 triage (plan-2026-09-01.json, routing frozen in plan-2026-09-01.routing.json).
  # Every name below is verbatim from a real capture under grocery\out; the capture file is named in
  # the `why` when it is not walmart-regular-2026-08-31.json. NEVER regenerate these from the live
  # board: the rows they encode are the ones the rules were wrong about, and a regenerated fixture
  # would find nothing and pass.
  # =================================================================================================

  # ---- jalapenos: the fence excluded the ADJECTIVE but not the CONTAINER NOUN (queue b7da16) ------
  # A canned 3-pack held the FRESH jalapeno cell at $0.877/lb against a real $1.76/lb fresh row, and
  # last week's winner was the same class, so this cell had been canned-on-fresh for over a week.
  @{ id='jalapenos'; name='(3 pack) El Mexicano Whole Jalapeno Peppers, 27 oz Can'; expect='excluded'
     why='FOUNDING CASE: canned peppers held the fresh-jalapeno cell. jalapenos already excluded "canned", "pickled" and "jar"; this name carries none of them, only the container noun "Can"' }
  @{ id='jalapenos'; name='EMBASA Whole Jalapenos in Escabeche, Shelf Stable, Kosher, 26 oz Steel Can'; expect='excluded'
     why='the SAME class one week earlier (walmart-regular-2026-08-11) - it was the previous cell holder, and "escabeche" is the preparation noun the adjective fence could not see' }
  @{ id='jalapenos'; name='Armour Jalapeno Vienna Sausage, 6g Protein Per Serving, 4.6 oz Can'; expect='excluded'
     why='a latent mis-route the same fix corrects: a jalapeno-FLAVOURED canned sausage was routing to fresh peppers' }
  @{ id='vienna-sausage'; name='Armour Jalapeno Vienna Sausage, 6g Protein Per Serving, 4.6 oz Can'; expect='included'
     why='and the other half of that correction - released from jalapenos, it must land on the commodity it actually is' }
  @{ id='jalapenos'; name='Fresh Jalapenos, Each'; expect='included'
     why='CLEAN TWIN the real fresh pepper (walmart-regular-2026-07-30) is untouched, and it is the row that takes the cell back' }

  # ---- broccoli / frozen-broccoli: a store name that omits its own type word (queue b7da16) -------
  # "Great Value Broccoli Florets, 14 oz" carries no frozen or steam token, so the fresh-broccoli
  # fence could not see it and it held the Walmart broccoli cell at $1.3257/lb. Walmart's own
  # breadcrumb for item 13925175, read 2026-09-01: Food > Frozen Foods > Frozen Fruits & Vegetables
  # > Frozen Vegetables. Its found_by_term in the capture is "frozen broccoli florets".
  @{ id='broccoli'; name='Great Value Broccoli Florets, 14 oz'; expect='excluded'
     why='FOUNDING CASE: a FROZEN product held the FRESH broccoli cell and the crown. Store-verified frozen by breadcrumb, not inferred' }
  @{ id='frozen-broccoli'; name='Great Value Broccoli Florets, 14 oz'; expect='included'
     why='the other half: excluding it from fresh is only right if it lands where it belongs. A drop with no re-home would lose the row entirely' }
  @{ id='broccoli'; name='Great Value: Broccoli Stir-Fry, 16 oz'; expect='excluded'
     why='same fix, second instance: a stir-fry BLEND is not a broccoli crown' }
  @{ id='broccoli'; name='Marketside Broccoli Florets, 12 oz'; expect='included'
     why='CLEAN TWIN Marketside is Walmart fresh line, and florets are still fresh broccoli - proof the new token is brand-specific and not a florets ban' }
  @{ id='broccoli'; name='Fresh Whole Green Broccoli Crowns, 1 Each'; expect='included'
     why='CLEAN TWIN the real fresh crown (walmart-regular-2026-07-23) still matches' }
  @{ id='frozen-broccoli'; name='Great Value Frozen Cut Broccoli, 16 oz'; expect='included'
     why='CLEAN TWIN the existing frozen-broccoli cell holder is unmoved by the new include' }
  @{ id='frozen-broccoli'; name='Marketside Broccoli Florets, 12 oz'; expect='no-include-match'
     why='CLEAN TWIN and the fresh florets do NOT leak the other way into frozen' }

  # ---- coleslaw-mix: the two-word spelling matched nothing estate-wide (queue 4a481e) -------------
  @{ id='coleslaw-mix'; name='Marketside Tri-Color Cole Slaw, 16 oz Bag (Fresh)'; expect='included'
     why='FOUNDING CASE: the include library knew "coleslaw" and "slaw mix" but not two-word "Cole Slaw", so Walmart had NO cell on a commodity it stocks. The tri-colour token does not help either: it wants "tri-color coleslaw", and this reads "Tri-Color Cole Slaw"' }
  @{ id='coleslaw-mix'; name='Marketside Angel Hair Cole Slaw, 10 oz Bag (Fresh)'; expect='included'
     why='second real instance of the same two-word spelling (walmart-regular-2026-08-11)' }
  @{ id='coleslaw-mix'; name='Freshness Guaranteed Homestyle Cole Slaw, 30 oz Tub (Refrigerated)'; expect='excluded'
     why='MUST-FIRE FENCE: the first-draft bare token admitted this - a DRESSED deli salad in a tub, not a bag of shredded cabbage. Caught by measurement before shipping, which is why homestyle and tub are on the exclude list' }
  @{ id='coleslaw-mix'; name='Freshness Guaranteed Homestyle Cole Slaw, 15 oz Small Tub (Refrigerated)'; expect='excluded'
     why='and its small-tub sibling, so a size change cannot walk one of them back in' }
  @{ id='coleslaw-mix'; name="Mann's Broccoli Cole Slaw The Original"; expect='excluded'
     why='CLEAN TWIN broccoli slaw is a different vegetable and the pre-existing broccoli exclude still holds it out' }

  # ---- cooked-jasmine-rice / rice: adjacency and the release exclude (queue 4a481e) ---------------
  # The include demanded "ready-to-eat" immediately followed by "jasmine rice", so every flavoured or
  # differently-ordered variant was invisible. Two of them were CLAIMED by `rice` at index 63, which
  # excluded "ready rice" and "ready to heat" but never "ready to eat" - so widening the include alone
  # would not have reached them (first-match-wins).
  @{ id='cooked-jasmine-rice'; name='Mahatma Ready-to-Eat Cilantro Limon Jasmine Rice, Microwaveable Rice, Gluten Free, 8.8 oz Pouch'; expect='included'
     why='FOUNDING CASE: a flavour word between "ready-to-eat" and "jasmine rice" made the row invisible to every include' }
  @{ id='cooked-jasmine-rice'; name='Mahatma Ready-to-Eat White Jasmine Rice, Microwavable Rice, 8.8 oz Pouch'; expect='included'
     why='same shape with a colour word (walmart-regular-2026-08-11)' }
  @{ id='cooked-jasmine-rice'; name="Ben's Original Ready Rice Jasmine Rice, Easy Dinner Side, 8.5 Ounce Pouch"; expect='included'
     why='the other word order - "Ready Rice Jasmine" - which needed its own token' }
  @{ id='cooked-jasmine-rice'; name='Minute Ready-to-Eat Jasmine Rice, Microwaveable Rice Cups, 4.4 oz, 2 Count'; expect='included'
     why='the row `rice` used to claim; it must be reachable here once released' }
  @{ id='rice'; name='Minute Ready-to-Eat Jasmine Rice, Microwaveable Rice Cups, 4.4 oz, 2 Count'; expect='excluded'
     why='THE RELEASE EXCLUDE. rice sits at index 63 and cooked-jasmine-rice at 587, so without this the widened include can never be reached. Dry rice is never ready-to-eat' }
  @{ id='rice'; name='Minute Ready-to-Eat Restaurant-Style Sticky Rice, Microwaveable Rice Cups, 4.4 oz, 2 Count'; expect='excluded'
     why='the release is about the FORM, not the grain: a cooked cup must not price dry rice (walmart-regular-2026-08-06)' }
  @{ id='cooked-jasmine-rice'; name='Minute Ready-to-Eat Restaurant-Style Sticky Rice, Microwaveable Rice Cups, 4.4 oz, 2 Count'; expect='no-include-match'
     why='CLEAN TWIN and it must not land here either - cooked, but not jasmine. It is correct for this row to route nowhere' }
  @{ id='rice'; name='Golden Star Thai Hom Mali Jasmine Rice, 5 lbs'; expect='included'
     why='CLEAN TWIN dry bagged jasmine rice is untouched by the ready-to-eat release (walmart-regular-2026-07-23)' }

  # ---- cherry-tomatoes: a plural stem the singular name could never satisfy (queue ff9801) --------
  # Every include spelled the fruit "tomatoes?" - which is "tomatoe" plus an optional "s", so it
  # matches "tomatoes" and never "tomato". The singular "Grape Tomato" had therefore never matched
  # anything estate-wide, and Walmart's cheapest grape tomato was invisible.
  @{ id='cherry-tomatoes'; name='Fresh Grape Tomato, 10 oz Package'; expect='included'
     why='FOUNDING CASE: the singular name the plural stem could not see. $2.27 against the organic $3.27 that held the cell' }
  @{ id='cherry-tomatoes'; name='(2 pack) Bonnie Plants Husky Cherry Red Cherry Tomato 19.3 oz.'; expect='no-include-match'
     why='THE LIVE GARDEN PLANT, and it is stopped one layer EARLIER than the plan expected. The plan proposed pluralising the plant fence because a FIRST-DRAFT singular token would have admitted this row; the token actually shipped is grape-only, so no include fires and the fence is never reached. Measured over all 45,666 corpus names: ZERO match a cherry-tomatoes include and \bplants?\b, and zero match one and the old singular \bplant\b, so a pluralised fence would have shipped with no reachable test. It was left out and this case is what proves the include is narrow enough to make it unnecessary. If anyone ever widens the token to (?:cherry|grape)\s+tomato, this case goes red and the fence becomes required - four Bonnie tomato PLANT listings are live in the corpus, two of them ending "Live Plants" (walmart-regular-2026-08-06)' }
  @{ id='cherry-tomatoes'; name='Fresh Organic Grape Tomatoes, 10 oz Package'; expect='included'
     why='CLEAN TWIN the plural row that already held the cell still matches' }

  # ---- coconut-oil: a STANDING RULING upheld, not a widening (queue ff9801) -----------------------
  # The 2026-09-01 plan proposed widening the include to admit "Coconut Cooking Oil". Three dated
  # reviewed rulings say otherwise (coverage-gap-allowlist coconut-oil|Sam's Club 2026-07-29 and two
  # coconut-oil|Walmart entries of 2026-08-31): the Carrington line is a FRACTIONATED oil that stays
  # liquid at room temperature, sold by fluid ounce, and "widening the include to catch it would put
  # two different fats in one row". Re-verified at the store 2026-09-01 (walmart.com/ip/37025807:
  # "Organic Coconut Cooking Oil, 32 Floz, Unflavored"). Ruled known-wrong instead. This case exists
  # so a future widening has to argue with a red test rather than with nobody.
  @{ id='coconut-oil'; name='Carrington Farms Organic Coconut Cooking Oil, 32 Floz'; expect='no-include-match'
     why='UPHELD RULING: a fractionated liquid oil must NOT enter the solid-coconut-oil row. If this case goes red, someone widened the include past three dated reviews' }
  @{ id='coconut-oil'; name='Great Value Organic Naturally Refined Coconut Oil, 56 fl oz'; expect='included'
     why='CLEAN TWIN the real Walmart coconut-oil cell holder is untouched' }

  # ---- blackberries / raspberries: the spread fence two of four berries never had -----------------
  # DEVIATION, found by rebuilding: today's Aldi capture put a JAM on the fresh-blackberries cell
  # (0.3983/oz of fresh fruit replaced by 0.2603/oz of spread). strawberries and blueberries have
  # carried a bare `spread` exclude for months; raspberries and blackberries never got it, and their
  # only spread-shaped fence is \bfruit\s+spreads?\b, which demands the two words be adjacent. Aldi
  # writes "Blackberry Spread With 75 Fruit", so the words are in the wrong order and the fence misses.
  # Same class as this plan's own mechanism (1): the fence knows the adjective, not the noun.
  # Measured over all 45,666 corpus names: exactly ONE routing change, the row below leaving
  # blackberries for nothing. No raspberry name moves - that half is parity with the two siblings,
  # closing an OPEN hole (raspberries includes the bare stem "raspberr", so the same Aldi product
  # line would be admitted the moment it appears) rather than speculation about a hole that is shut.
  @{ id='blackberries'; name='Specially Selected Blackberry Spread With 75 Fruit 9.95 OZ'; expect='excluded'
     why='FOUNDING CASE: a fruit SPREAD held the Aldi fresh-blackberries cell on the 2026-09-01 rebuild (aldi-regular-2026-09-01)' }
  @{ id='blackberries'; name='Blackberries 6 OZ'; expect='included'
     why='CLEAN TWIN the real fresh berry, which is the row that takes the cell back' }
  @{ id='raspberries'; name='Raspberries Package 6 OZ'; expect='included'
     why='CLEAN TWIN the sibling fence must not touch fresh raspberries (aldi-regular-2026-09-01)' }
  @{ id='strawberries'; name='Strawberries Package 1 LB'; expect='included'
     why='CLEAN TWIN the berry that already had the fence is unchanged, which is what makes this a parity fix' }

  # ---- the seven LATENT wrong routings from the 2026-09-01 contested review (queue e17a88) --------
  # audit-match-soundness listed ten new-contested names; seven were genuinely wrong-commodity
  # routings, none of them holding a cell that day. Latent is not harmless: garlic is unit=each with
  # band 0.25-2.5, so a bouillon jar lands IN band on any ordinary day and takes the cell.
  # Blast radius measured as ROUTING over all 45,934 distinct capture names, before and after, using
  # the estate's own matcher with GLOBAL_EXCLUDE lifted from compare-deals: exactly 25 names move and
  # every one of them is listed here or is another instance of the same class. Nothing else moves.
  #
  # THE FALL-THROUGH IS PART OF THE FIX, and measuring it is what found the other half. Refusing a
  # name at index 55 only hands it to index 64. The stewed-tomato row walked garlic -> jalapenos ->
  # ground-cumin, one spice word at a time, and the prepared pasta bowl walked mushrooms -> pasta.
  # Each of those second and third landings is a wrong cell this change would have CREATED, so each
  # gets its own fence and its own case below.
  @{ id='garlic'; name='Better Than Bouillon Premium Roasted Garlic Base, Shelf-Stable, 8 oz Jar'; expect='excluded'
     why='FOUNDING CASE a bouillon base won the GARLIC cell over the bouillon commodity (garlic is unit=each, band 0.25-2.5, so an 8 oz jar lands in band)' }
  @{ id='garlic'; name='Del Monte Diced Tomatoes with the Flavors of Basil, Garlic & Oregano, 14.5 oz Can'; expect='excluded'
     why='FOUNDING CASE canned diced tomatoes won GARLIC on the word Garlic in the flavour list. 18 tomato rows were routing this way, not the 2 the review named' }
  @{ id='garlic'; name='Del Monte Stewed Mexican Recipe w/Jalapenos Garlic & Cumin Tomatoes, 14.5 oz'; expect='excluded'
     why='FOUNDING CASE, and the row that proved the fall-through matters it walked garlic to jalapenos to ground-cumin as each fence went in' }
  @{ id='jalapenos'; name='Del Monte Stewed Mexican Recipe w/Jalapenos Garlic & Cumin Tomatoes, 14.5 oz'; expect='excluded'
     why='THE SECOND LANDING. With garlic fenced this row fell onto jalapenos (unit lb, band 0.8-4.5). A cell this change created is a cell this change owns' }
  @{ id='ground-cumin'; name='Del Monte Stewed Mexican Recipe w/Jalapenos Garlic & Cumin Tomatoes, 14.5 oz'; expect='excluded'
     why='THE THIRD LANDING. With jalapenos fenced it fell onto ground-cumin. It now routes NOWHERE, which is right the estate has no stewed-tomatoes commodity' }
  @{ id='garlic'; name='Fresh Garlic, Each'; expect='included'
     why='CLEAN TWIN real fresh garlic is untouched by either fence' }
  @{ id='diced-tomatoes'; name='Del Monte Diced Tomatoes with the Flavors of Basil, Garlic & Oregano, 14.5 oz Can'; expect='included'
     why='CLEAN TWIN and the PROOF THE FIX LANDS SOMEWHERE RIGHT the row garlic gave up is claimed by the commodity that should have had it' }
  @{ id='jalapenos'; name='Fresh Jalapeno Peppers'; expect='included'
     why='CLEAN TWIN the tomato fence must not touch a real jalapeno' }
  @{ id='ground-cumin'; name='Great Value Ground Cumin, 2.5 oz'; expect='included'
     why='CLEAN TWIN the tomato fence must not touch a real cumin jar' }

  @{ id='milk'; name='Dove Macadamia+Rice Milk and Brown Sugar+Coco Body Scrub Mixed Pack, 15 oz., 2 pk.'; expect='excluded'
     why='FOUNDING CASE a body scrub won the MILK cell (unit gallon, band 1.80-7.00) on the words Rice Milk' }
  @{ id='brown-sugar'; name='Dove Macadamia+Rice Milk and Brown Sugar+Coco Body Scrub Mixed Pack, 15 oz., 2 pk.'; expect='excluded'
     why='THE SECOND LANDING with milk fenced the same scrub fell onto brown-sugar on the words Brown Sugar. Both fences sit in the personal-care block both commodities already carry \blotion\b for' }
  @{ id='milk'; name='Great Value Whole Vitamin D Milk, Gallon, 128 fl oz'; expect='included'
     why='CLEAN TWIN the real gallon of milk is untouched' }
  @{ id='brown-sugar'; name='Great Value Light Brown Sugar, 32 oz'; expect='included'
     why='CLEAN TWIN real brown sugar is untouched' }

  @{ id='instant-mashed-potatoes'; name='Idahoan Shredded Hashbrowns, 2.125 lbs.'; expect='excluded'
     why='FOUNDING CASE \bidahoan\b is a BRAND include, so every Idahoan product landed on instant mashed potatoes. Hash browns have their own commodity' }
  @{ id='instant-mashed-potatoes'; name='Idahoan Fresh Cut Hash Browns, 8 servings, 4.8 oz'; expect='excluded'
     why='SECOND INSTANCE found by measuring the review named one Idahoan hash-brown row, the corpus holds two' }
  @{ id='hash-browns'; name='Idahoan Shredded Hashbrowns, 2.125 lbs.'; expect='included'
     why='CLEAN TWIN and the proof the fix lands somewhere right hash-browns claims the row instant-mashed-potatoes gave up' }
  @{ id='instant-mashed-potatoes'; name='Idahoan Buttery Homestyle Mashed Potatoes, 4 oz'; expect='included'
     why='CLEAN TWIN the real Idahoan mashed-potato pouch still routes here, so the brand include is fenced and not gutted' }

  @{ id='bottled-marinade'; name='Soeos Whole Bay Leaves 2oz, Dried Laurel, Non-GMO Verified, Herb for Marinades, Stews and Soups'; expect='excluded'
     why='FOUNDING CASE, and the trap it teaches bottled-marinade claimed this off the word Marinades in the DESCRIPTION, so a fence keyed on the type word alone cannot see it. The fence is the USE claim "for marinades"' }
  @{ id='bay-leaves'; name='Soeos Whole Bay Leaves 2oz, Dried Laurel, Non-GMO Verified, Herb for Marinades, Stews and Soups'; expect='included'
     why='CLEAN TWIN and the proof the fix lands somewhere right bay-leaves takes the row bottled-marinade gave up' }
  @{ id='bottled-marinade'; name='Allegro Original Marinade, 12.7 fl oz'; expect='included'
     why='CLEAN TWIN a real marinade product is untouched the fence needs the words "for marinades", not the word "marinade"' }

  @{ id='mushrooms'; name='Tangle Creamy Mushroom Pasta Bowl, 6 pk.'; expect='excluded'
     why='FOUNDING CASE a prepared single-serve bowl won the MUSHROOMS cell (unit oz, band 0.10-0.90)' }
  @{ id='pasta'; name='Tangle Creamy Mushroom Pasta Bowl, 6 pk.'; expect='excluded'
     why='THE SECOND LANDING mushrooms is index 57 and pasta is 64, so fencing mushrooms alone just moved the wrong cell one commodity along. With both fences the row routes NOWHERE, which is correct - the estate prices no prepared bowls' }
  @{ id='mushrooms'; name='Fresh Sliced White Mushrooms, 8 oz'; expect='included'
     why='CLEAN TWIN real mushrooms are untouched' }
  @{ id='pasta'; name='Great Value Spaghetti, 16 oz'; expect='included'
     why='CLEAN TWIN real dry pasta is untouched' }
)

$bad = 0
$n = 0
foreach ($c in $cases) {
  $n++
  $row = $byId[$c.id]
  if (-not $row) {
    Write-Output ("  X     {0}: no such commodity id in {1}" -f $c.id, (Split-Path $File -Leaf))
    $bad++; continue
  }
  $got = Get-RuleVerdict $row $c.name
  # 'excluded' in a case means "excluded by SOME pattern"; which pattern is not the contract.
  $ok = if ($c.expect -eq 'excluded') { $got -like 'excluded:*' } else { $got -eq $c.expect }
  if ($ok) {
    if (-not $Quiet) { Write-Output ("  ok    {0,-16} {1,-52} {2}" -f $c.id, $c.name.Substring(0, [Math]::Min(52, $c.name.Length)), $c.expect) }
  } else {
    Write-Output ("  X     {0,-16} {1}" -f $c.id, $c.name)
    Write-Output ("          expected {0}, got {1}" -f $c.expect, $got)
    Write-Output ("          why this case exists: {0}" -f $c.why)
    $bad++
  }
}

Write-Output ''
if ($bad -gt 0) {
  Write-Output ("test-commodity-rules: FAIL - {0} of {1} case(s) no longer hold" -f $bad, $n)
  exit 1
}
Write-Output ("test-commodity-rules: PASS - {0} case(s) over {1} commodity row(s)" -f $n, (@($cases | ForEach-Object { $_.id } | Select-Object -Unique)).Count)
exit 0
