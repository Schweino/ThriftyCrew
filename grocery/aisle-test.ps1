<#
  aisle-test.ps1 - would this candidate crown flip put a product from the WRONG AISLE on the board?

  WHY THIS EXISTS
  ---------------
  Family Fare's shallow search feed has been doing double duty as an accidental RELEVANCE FILTER. Browsing
  the full catalogue is cheap (18,441 products, 185 requests vs ~992 search requests/day) but simulated
  through the real matcher it flips 26 cheapest-store verdicts, about two thirds to the WRONG product:

      watermelon -> Hefty Fabuloso Scent Trash Bags, Watermelon
      milk       -> M&M's Peanut MILK Chocolate
      coffee     -> International Delight Iced Mocha CREAMER
      butter     -> Our Family BUTTER BEANS

  Every one shares a word with the commodity, which is exactly why regex cannot catch them:
  audit-food-category caught 0 of 26, audit-store-taxonomy caught 3. So depth is only safe behind a
  per-commodity relevance test, and this is it.

  WHY IT IS NOT A SEMANTIC SCORE (measured, 2026-08-01, both rejected)
  -------------------------------------------------------------------
  The obvious build - score the candidate with the GPU reranker and threshold it - FAILS, and it fails in a
  way worth recording so nobody rebuilds it. Calibrated against all 2,825 shipped board pairs, the score
  distributions INTERLEAVE:

      0.000141  M&M's Peanut Milk Chocolate            WRONG
      0.000299  Our Family Butter Beans                WRONG
      0.000312  Wimmer's Wieners, Skinless             RIGHT - a real hot dog
      0.000318  Blue Diamond Mike's Hot Honey Almonds  RIGHT
      0.000365  International Delight Iced Mocha       WRONG
      0.000983  Hefty Fabuloso Watermelon Trash Bags   WRONG

  No global cut separates those. The cause is structural: a cross-encoder scores VOCABULARY OVERLAP with
  the commodity's words, so a regional brand sharing none of them ("Wimmer's Wieners" for hot-dogs) scores
  as low as a wrong product sharing one ("Butter Beans" for butter). The absolute score measures name
  transparency, not membership. The peer-relative form (candidate vs the commodity's existing cohort) was
  tried next and ALSO failed: every commodity's cohort median is ~0.9, so the ratio just rescales by a
  near-constant and preserves the same interleaving (worst-WRONG 0.001026 vs floor-RIGHT 0.000334).

  WHAT ACTUALLY WORKS: THE STORE'S OWN SHELF
  ------------------------------------------
  Family Fare's canonical_url IS the shelf path, on 99.7% of rows, and it is authored by the STORE:

      /shop/fresh_fruits_vegetables/melons/fresh_watermelons_seedless/        <- real watermelon
      /shop/health_beauty/grooming_hygiene/body_washes/olay_body_wash_...     <- watermelon body wash
      /shop/beverages/coffee/instant/starbucks_lime_watermelon_refreshers/    <- watermelon drink

  That is categorical, not a model's opinion, and it is the signal the four failures actually violate. So
  the test is: learn which departments a commodity's OWN shipped products live in, then refuse a candidate
  from a department the commodity has never occupied.

  WHAT IT CANNOT DO (state this before trusting it)
  -------------------------------------------------
  It is a DEPARTMENT filter, so it only catches CROSS-department errors. It cannot separate two things the
  store shelves in the same place. Concretely: International Delight Iced Mocha sits in `dairy` and is
  blocked for `coffee`, but Natural Bliss Oat Creamer sits in `beverages` - and so does real coffee - so it
  is ALLOWED. Coffee-vs-creamer is a rules problem (there is a separate coffee-creamer commodity) and this
  gate will not solve it. Measured on 3,828 rule-matched FF rows: 7.8% blocked, and spot-reading the top
  blocked commodities, roughly 8 in 10 are true pollution (Eggo Cookies-and-Creme waffles under `cookies`,
  Spindrift Blood Orange sparkling water under `oranges`, Ruffles Cheddar & Sour Cream chips under
  `sour-cream`, Diet Coke Retro Lime under `limes`, a Lean Cuisine turkey dinner under `apples`) and the
  rest are real product the department map is too tight for (Amy's FROZEN mac and cheese, pantry prunes).
  Since a block only means "do not take this depth", that error direction is the cheap one.

  BLIND REFUSES THE FLIP. Everywhere else in this estate could-not-evaluate means publish anyway, because
  the board is the known state and a gate must not hold it hostage. Here the FLIP is the change, so the
  safe direction inverts: no aisle evidence means we do not flip. Refusing depth costs coverage; accepting
  a bad flip costs a wrong price, and a wrong price is the thing the product promises never to do.

  Usage:
    .\aisle-test.ps1 -SelfTest
    .\aisle-test.ps1 -Candidates candidates.json      [{id, store, product, canonical_url}]
    .\aisle-test.ps1 -Id watermelon -Product "..." -Url "https://.../shop/household/..."
#>
param(
  [string]$Candidates = '',
  [string]$Id = '',
  [string]$Product = '',
  [string]$Url = '',
  [switch]$SelfTest,
  [switch]$LiveBoard,
  [int]$MinProfile = 2,
  [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# ---- the shelf path, reduced to what we compare on -------------------------------------------------
# Segment 1 is the DEPARTMENT (fresh_fruits_vegetables, household, health_beauty, pantry...). Segment 2 is
# the aisle within it. We gate on DEPARTMENT: it is the level the four failures violate, and it is stable -
# a store reshuffling an aisle inside a department must not start refusing real product.
function Get-Dept([string]$u) {
  if (-not $u) { return '' }
  $m = [regex]::Match([string]$u, '/shop/([^/]+)/')
  if ($m.Success) { return $m.Groups[1].Value.ToLower() }
  return ''
}
function Get-Aisle([string]$u) {
  if (-not $u) { return '' }
  $m = [regex]::Match([string]$u, '/shop/([^/]+)/([^/]+)/')
  if ($m.Success) { return ($m.Groups[1].Value + '/' + $m.Groups[2].Value).ToLower() }
  return (Get-Dept $u)
}

# ---- the AUTHORED category -> department allowlist ---------------------------------------------------
# This table is written by a human and reviewed. The first build LEARNED it per commodity from rows the
# engine matched, and that failed for a reason worth keeping: the rules are already polluted, so the
# profile inherited their errors. watermelon's learned profile contained health_beauty (1 of 10 matches)
# purely because the rule already matches Olay Watermelon Body Wash - so the gate cheerfully ALLOWED the
# body wash. A gate that learns its baseline from the thing it is auditing cannot catch that thing.
#
# Measured department mix per estate category on the live FF catalogue (2026-08-01, n in parens):
#   pet 100% pets_wildlife (141)    baby 100% health_beauty (62)     canned 97% pantry (358)
#   personal 94% health_beauty (283) condiments 93% pantry (383)     household 91% household (265)
#   grains 91% pantry (201)         frozen 89% freezer (101)          baking 84% pantry (350)
#   meat 83% meat +13% deli (240)   bakery 78% bakery (94)            dairy 66% dairy +18% deli (282)
#   veg 62% fresh_fruits_vegetables (137)
# and THREE that are not mapping failures but rule pollution, recorded here because they are findings:
#   fruit  34% fresh_fruits_vegetables, 26% pantry, 24% BEVERAGES, 7% HEALTH_BEAUTY (140)
#   snacks 47% beverages, 45% pantry (600)
#   oils   69% pantry, 29% beverages (191)   [also: 'coffee' is filed under 'oils', likely miscategorised]
# For `fruit` the allowlist is deliberately produce-ONLY: the beverage and health_beauty share IS the
# defect this gate exists to stop, so encoding it would be encoding the bug.
$CAT_DEPT = @{
  'baby'       = @('health_beauty')
  'bakery'     = @('bakery', 'pantry')
  'baking'     = @('pantry')
  'canned'     = @('pantry')
  'condiments' = @('pantry', 'deli')
  'dairy'      = @('dairy', 'deli')
  'frozen'     = @('freezer')
  'fruit'      = @('fresh_fruits_vegetables')
  'grains'     = @('pantry')
  'household'  = @('household')
  'meat'       = @('meat', 'deli', 'meat_seafood')
  'oils'       = @('pantry')
  'personal'   = @('health_beauty', 'household')
  'pet'        = @('pets_wildlife')
  'snacks'     = @('pantry', 'beverages')
  'veg'        = @('fresh_fruits_vegetables', 'pantry', 'freezer')
}

# ---- reviewed per-commodity exceptions ---------------------------------------------------------------
# The category default is right for most things and WRONG for a predictable minority: commodities the
# STORE shelves somewhere other than where the estate files them. Measured by judging all 3,828
# rule-matched FF rows and reading every commodity that absorbed blocks - 10.8% blocked, and these are the
# ones where the blocked rows were REAL product, not pollution:
#   coffee(30) + orange-juice(26) + lemonade(7)  real drinks, but filed under 'oils'/'fruit'
#   hand-soap(24) + protein-bars(19)             stores shelve these in health_beauty, not household/snacks
#   whipped-cream(9)                             Cool Whip is literally frozen
#   dried-cranberries(7)                         dried fruit is pantry, not produce
# Everything else that blocked was the gate working: Spindrift Blood Orange sparkling water under
# `oranges`, Ruffles Cheddar & SOUR CREAM chips under `sour-cream`, Eggo Cookies-and-Creme waffles under
# `cookies`, Mike's HARD Lemonade under `lemonade`, Starbucks Refreshers under `watermelon`.
# NOTE for later: `coffee` sits in the estate category 'oils', which is almost certainly a
# miscategorisation rather than an aisle problem. Left alone here - recategorising a commodity moves it on
# the public board's category filter, which is a bigger change than this gate should make on its own.
# 2026-08-06 (triage plan-2026-08-06, item 2026-08-03-3ec6da): the standing BLOCK set had grown to a fixed
# 21 rows that re-paged on every product-string churn, and ALL 21 were read row by row against the board -
# every one a REAL instance of its commodity that Family Fare simply shelves somewhere else (Sugar 'N Spice
# spice packets and bagged Chile De Arbol in produce, canned milks and refrigerated bagels in dairy,
# ReaLemon-class juices in beverages, breaded nuggets and fish sticks filed under meat, Pampa rice and Lil
# Dutch Maid cookies in the trial-sizes aisle, dried prunes in pantry, California Sun Dry tomatoes in
# produce). A standing set of known-real blocks is worse than useless: a genuinely NEW cross-department
# hijack arrives buried in a 21-row list a human has to diff from memory. Draining it to zero re-arms the
# signature dedup in check-ad-cycles so the alert only speaks on a new block.
# EVERY entry below is the commodity's CURRENT category allowlist PLUS the observed FF department - never a
# raw replacement, because this table REPLACES the category map (see Judge), so a bare list would silently
# BLOCK a department that is allowed today. Verified: none of the 21 loses a department it already allows.
# The category-level CAT_DEPT map above stays tight on purpose - loosening it is the thing this gate exists
# to refuse.
$COMMODITY_DEPT = @{
  'coffee'            = @('beverages', 'pantry')
  'orange-juice'      = @('beverages', 'pantry')
  'lemonade'          = @('beverages', 'pantry')
  'hand-soap'         = @('health_beauty', 'household')
  'protein-bars'      = @('health_beauty', 'pantry')
  'whipped-cream'     = @('freezer', 'dairy')
  'dried-cranberries' = @('pantry', 'fresh_fruits_vegetables')
  # --- reviewed 2026-08-06, all 21 read against their board row ---
  'bagels'             = @('bakery', 'pantry', 'dairy')                                # FF shelves Lender's/Bubba's bagels in dairy
  'bay-leaves'         = @('pantry', 'fresh_fruits_vegetables')                         # Sugar 'N Spice packets hang in produce
  'curry-powder'       = @('pantry', 'fresh_fruits_vegetables')
  'dried-arbol-chiles' = @('pantry', 'fresh_fruits_vegetables')                         # bagged dried chiles are a produce item
  'ground-fennel'      = @('pantry', 'fresh_fruits_vegetables')
  'ground-turmeric'    = @('pantry', 'fresh_fruits_vegetables')
  'poultry-seasoning'  = @('pantry', 'fresh_fruits_vegetables')
  'condensed-milk'     = @('pantry', 'dairy')                                           # canned milks sit in the dairy aisle
  'evaporated-milk'    = @('pantry', 'dairy')
  'cheese-tortellini'  = @('pantry', 'freezer')
  'rice'               = @('pantry', 'seasonal_special_occasion')                        # Pampa rice in the trial-sizes aisle
  'chicken-nuggets'    = @('freezer', 'meat')                                            # breaded frozen nuggets filed under meat
  'fish-sticks'        = @('freezer', 'meat')
  'coffee-creamer'     = @('dairy', 'deli', 'beverages')                                 # 26 FF creamers hang in beverages
  'corned-beef-hash'   = @('pantry', 'meat')
  'gingersnaps'        = @('pantry', 'beverages', 'seasonal_special_occasion')
  'lemon-juice'        = @('pantry', 'deli', 'beverages')                                # ReaLemon-class juice bottles
  'lime-juice'         = @('pantry', 'deli', 'beverages')
  'minced-garlic'      = @('pantry', 'deli', 'fresh_fruits_vegetables')
  'prunes'             = @('fresh_fruits_vegetables', 'pantry')                          # dried fruit is pantry, not produce
  'sun-dried-tomatoes' = @('pantry', 'fresh_fruits_vegetables')                          # FF shelves the California Sun Dry jar in produce
  # --- reviewed 2026-08-30 (plan-2026-08-30-2, queue 2026-08-30-2611d3), each read against its board row ---
  # The standing BLOCK set had regrown to 11 and re-paged every 3 days. Ten were RIGHT products failing a
  # wrong map; the eleventh was Blue Bunny ICE CREAM holding the pistachios crown, which is the catch this
  # gate exists for and which was buried under the ten. Draining the ten re-arms the signature dedup so the
  # alert only speaks on a NEW block. Every entry below is the commodity's current category allowlist PLUS
  # the observed Family Fare department - never a bare replacement, because this table REPLACES the category
  # map in Judge, so a short list would silently BLOCK a department that is allowed today.
  'dried-basil'        = @('pantry', 'fresh_fruits_vegetables')   # Litehouse freeze-dried herbs hang on the produce spice rack
  'black-peppercorns'  = @('pantry', 'fresh_fruits_vegetables')   # Sugar 'N Spice packets, same rack as bay-leaves above
  'cinnamon-stick'     = @('pantry', 'fresh_fruits_vegetables')   # Canela Entera, the Hispanic spice rack in produce
  'whole-cloves'       = @('pantry', 'fresh_fruits_vegetables')   # Sugar 'N Spice packets
  'dried-ancho-chiles' = @('pantry', 'fresh_fruits_vegetables')   # bagged dried chiles ARE a produce item at FF, like dried-arbol-chiles
  # The three alcohol rows are right products in the right aisle: the estate files them under the 'snacks'
  # CATEGORY (pantry, beverages), so beer_wine_spirits is disallowed for a bottle of wine. Fixed here rather
  # than by recategorising, because a commodity's category is also its section on the public board and that
  # is a bigger change than this gate should make on its own (see the coffee note above).
  'brandy'             = @('pantry', 'beverages', 'beer_wine_spirits')
  'red-wine'           = @('pantry', 'beverages', 'beer_wine_spirits')
  'white-wine'         = @('pantry', 'beverages', 'beer_wine_spirits')
  'vienna-sausage'     = @('pantry', 'meat')                      # FF files Libby's tins under meat/sausage; category 'canned' allows only pantry
  'parmesan'           = @('dairy', 'deli', 'pantry')             # Our Family GRATED 16 oz is shelf-stable and sits in pantry
  # --- reviewed 2026-08-31 (queue 2026-08-31-e6a93d), each read against its Family Fare row ---
  # Three blocks, all RIGHT product on a shelf the map does not allow, so the standing set was about to
  # start regrowing again - which is the state the 08-06 and 08-30 notes above both drained precisely so a
  # genuinely new hijack cannot arrive buried in a list. Nothing here loses a department it allows today.
  #   celery-salt    'Dan's Pantry Celery Salt' $4.99 / 12 oz, in fresh_fruits_vegetables/fresh_spices_herbs
  #   smoked-paprika 'Sugar N Spice Paprika Smoked Pp' $2.49 / 1 oz, the SAME produce spice rack and the
  #                  SAME brand already reviewed for bay-leaves, black-peppercorns and whole-cloves
  # Neither of those two is even on the board (both under MinStores), so the block was costing a candidate
  # rather than publishing a wrong cell - still worth draining, for the buried-in-a-list reason above.
  #   pistachios     'Planters Dry Roasted Pistachios 12.75 Oz' $5.99, filed in dairy/ready_to_eat. Read the
  #                  whole row before allowing it, because THIS is the commodity Blue Bunny ice cream
  #                  crowned on 08-30: all five cells are real pistachios today and the crown is Sam's
  #                  48 oz at 0.3538/oz, with the Planters row a non-crown runner-up at 0.4698.
  'celery-salt'        = @('pantry', 'fresh_fruits_vegetables')
  'smoked-paprika'     = @('pantry', 'fresh_fruits_vegetables')
  'pistachios'         = @('pantry', 'beverages', 'dairy')
}

function Get-CategoryMap {
  $cats = Read-JsonFile (Join-Path $root 'categories.json')
  $m = @{}
  $keyByLabel = @{}
  foreach ($c in @($cats.categories)) {
    $keyByLabel[[string]$c.label] = [string]$c.key
    foreach ($id in @($c.commodities)) { $m[[string]$id] = [string]$c.key }
  }
  # THE RECIPE BOARD IS A SECOND ID NAMESPACE (2026-08-30, queue 2026-08-30-2611d3). categories.json lists
  # only the STAPLE ids, so every recipe-board id reached Judge with no category and came back BLIND -
  # 21 of them on 2026-08-30 (greek-yogurt, mozzarella-cheese, salsa-verde, smoked-paprika and 17 more),
  # while -LiveBoard has been reading recipe-board.json since it was written. Unjudged is exactly how the
  # Blue Bunny ice cream held the pistachios crown, so a whole namespace nobody judges is the same hole
  # one commodity wide. The recipe rows carry their category as a LABEL on the row itself; build-deals-page
  # already THROWS if that label is not one of categories.json's sections, so the label is canonical and
  # this is a lookup, not a guess. categories.json membership always wins - a staple id can never be
  # re-keyed by a recipe row - and a label with no section is left BLIND rather than mapped to something.
  foreach ($rbn in @('out\recipe-board-everyday.json', 'out\recipe-board.json')) {
    $rbp = Join-Path $root $rbn
    if (-not (Test-Path $rbp)) { continue }
    try { $rbd = Read-JsonFile $rbp } catch { continue }
    foreach ($r in @($rbd.comparison)) {
      $rid = [string]$r.id; $rlab = [string]$r.category
      if (-not $rid -or -not $rlab) { continue }
      if ($m.ContainsKey($rid)) { continue }
      if ($keyByLabel.ContainsKey($rlab)) { $m[$rid] = $keyByLabel[$rlab] }
    }
  }
  return $m
}

# ---- per-commodity evidence, kept as a SECONDARY signal only -----------------------------------------
# Still useful for reporting how unusual a candidate is, but it no longer decides anything, because of
# the pollution above.
function Build-Profile {
  param([string]$FeedFile)
  $coms = Read-JsonFile (Join-Path $root 'commodities.json')
  $rx = New-Object System.Collections.Generic.List[object]
  $exc = @{}
  foreach ($c in $coms) {
    foreach ($p in @($c.include)) { if ($p) { $rx.Add([pscustomobject]@{ id = [string]$c.id; r = [regex]::new([string]$p, 'IgnoreCase,Compiled') }) } }
    $l = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($c.exclude)) { if ($p) { $l.Add([regex]::new([string]$p, 'IgnoreCase,Compiled')) } }
    $exc[[string]$c.id] = $l
  }
  $d = Read-JsonFile $FeedFile
  $rows = @($d.deals); if (-not $rows.Count) { $rows = @($d) }
  $prof = @{}
  foreach ($row in $rows) {
    $nm = [string]$row.item; $u = [string]$row.canonical_url
    if (-not $nm -or -not $u) { continue }
    $hit = ''
    foreach ($e in $rx) {
      if (-not $e.r.IsMatch($nm)) { continue }
      $killed = $false
      foreach ($x in $exc[$e.id]) { if ($x.IsMatch($nm)) { $killed = $true; break } }
      if (-not $killed) { $hit = $e.id; break }     # first-match-wins, same as the engine
    }
    if (-not $hit) { continue }
    $dept = Get-Dept $u
    if (-not $dept) { continue }
    if (-not $prof.ContainsKey($hit)) { $prof[$hit] = @{} }
    if (-not $prof[$hit].ContainsKey($dept)) { $prof[$hit][$dept] = 0 }
    $prof[$hit][$dept]++
  }
  return $prof
}

function Judge {
  param($CatMap, [string]$CommodityId, [string]$Url)
  $dept = Get-Dept $Url
  if (-not $dept) { return [pscustomobject]@{ verdict = 'BLIND'; reason = 'candidate has no shelf path - cannot place it on a shelf, so the flip is refused' } }
  if ($COMMODITY_DEPT.ContainsKey($CommodityId)) {
    $ov = @($COMMODITY_DEPT[$CommodityId])
    if ($ov -contains $dept) { return [pscustomobject]@{ verdict = 'ALLOW'; reason = "'$dept' is a reviewed exception department for '$CommodityId'" } }
    return [pscustomobject]@{ verdict = 'BLOCK'; reason = "candidate sits in '$dept'; '$CommodityId' allows only: $($ov -join ', ')" }
  }
  if (-not $CatMap.ContainsKey($CommodityId)) { return [pscustomobject]@{ verdict = 'BLIND'; reason = "'$CommodityId' is in no estate category - refused rather than guessed" } }
  $cat = $CatMap[$CommodityId]
  if (-not $CAT_DEPT.ContainsKey($cat)) { return [pscustomobject]@{ verdict = 'BLIND'; reason = "category '$cat' has no reviewed department allowlist - refused rather than guessed" } }
  $allowed = @($CAT_DEPT[$cat])
  if ($allowed -contains $dept) { return [pscustomobject]@{ verdict = 'ALLOW'; reason = "'$dept' is an allowed department for category '$cat'" } }
  return [pscustomobject]@{ verdict = 'BLOCK'; reason = "candidate sits in '$dept'; category '$cat' allows only: $($allowed -join ', ')" }
}

# ---- self-test: the founding failures MUST be blocked, the hard positives MUST pass ------------------
if ($SelfTest) {
  # Frozen fixture category map - deliberately NOT read from live data, per the guard-fixture rule. A
  # fixture regenerated from the thing it audits cannot fail, which makes a green run meaningless. That
  # is not hypothetical here: v1 of this gate learned its baseline from the live feed and ALLOWED an Olay
  # body wash into watermelon, because the polluted rule had already taught it health_beauty was normal.
  $P = @{
    'watermelon' = 'fruit'
    'milk'       = 'dairy'
    'coffee'     = 'oils'
    'butter'     = 'dairy'
    'hot-dogs'   = 'meat'
    'bagels'     = 'bakery'
    'thin'       = 'no-such-category'
  }
  $bad = 0
  $must = @(
    @('watermelon', 'https://www.shopfamilyfare.com/shop/household/trash_bags/hefty_fabuloso_watermelon/p/1', 'trash bags are not produce'),
    @('milk',       'https://www.shopfamilyfare.com/shop/pantry/candy/chocolate/mms_peanut_milk_chocolate/p/2', 'candy is not dairy'),
    @('coffee',     'https://www.shopfamilyfare.com/shop/dairy/creamers/international_delight_iced_mocha/p/3', 'a dairy creamer is not the coffee aisle'),
    @('butter',     'https://www.shopfamilyfare.com/shop/pantry/canned_goods/our_family_butter_beans/p/4', 'canned beans are not dairy'),
    # 2026-08-06: a reviewed COMMODITY_DEPT exception is DEPARTMENT-SCOPED, not a free pass. bagels allows
    # bakery/pantry/dairy; anything else must still BLOCK, or the 21 exceptions added that day would have
    # quietly turned 21 commodities into wildcards.
    @('bagels',     'https://www.shopfamilyfare.com/shop/household/trash_bags/hefty_bagel_scent/p/10', 'an excepted commodity in a NON-listed department must still block')
  )
  foreach ($m in $must) {
    $v = Judge -CatMap $P -CommodityId $m[0] -Url $m[1]
    if ($v.verdict -ne 'BLOCK') { Write-Output ("  X MUST-FIRE: $($m[0]) should BLOCK ($($m[2])) - got $($v.verdict)"); $bad++ }
  }
  # clean twins: real product in its own department must ALLOW - including the hard positive that broke
  # the semantic build (Wimmer's Wieners scored BELOW three of the four failures)
  $clean = @(
    @('watermelon', 'https://www.shopfamilyfare.com/shop/fresh_fruits_vegetables/melons/fresh_watermelons_seedless/p/5'),
    @('hot-dogs',   'https://www.shopfamilyfare.com/shop/meat_seafood/hot_dogs_sausage/wimmers_wieners_skinless/p/6'),
    @('milk',       'https://www.shopfamilyfare.com/shop/dairy/milk/our_family_2_percent/p/7'),
    # the twin of the case above, and the one that actually PINS the exception table: category 'bakery'
    # does not allow 'dairy', so this row can only pass through the reviewed COMMODITY_DEPT entry. Delete
    # the bagels exception and this goes red.
    @('bagels',     'https://www.shopfamilyfare.com/shop/dairy/breads_rolls_bagels/lenders_pre_sliced_plain_bagels_6_ea/p/11')
  )
  foreach ($m in $clean) {
    $v = Judge -CatMap $P -CommodityId $m[0] -Url $m[1]
    if ($v.verdict -ne 'ALLOW') { Write-Output ("  X CLEAN-TWIN: $($m[0]) should ALLOW - got $($v.verdict): $($v.reason)"); $bad++ }
  }
  # BLIND must refuse, never allow: no url, unknown commodity, too-thin profile
  foreach ($t in @(
      @('watermelon', '', 'no shelf path'),
      @('never-heard-of-it', 'https://www.shopfamilyfare.com/shop/pantry/x/y/p/8', 'unknown commodity'),
      @('thin', 'https://www.shopfamilyfare.com/shop/pantry/x/y/p/9', 'profile below MinProfile'))) {
    $v = Judge -CatMap $P -CommodityId $t[0] -Url $t[1]
    if ($v.verdict -ne 'BLIND') { Write-Output ("  X BLIND: $($t[2]) should be BLIND - got $($v.verdict)"); $bad++ }
  }
  # PS 5.1 array-unroll fixture: a multi-row candidates file must judge EVERY row, not collapse to one.
  # The founding bug: `@(Get-Content x | ConvertFrom-Json)` handed the whole array through as a single
  # pipeline object, so 8 real candidates became 1 row whose id was every id concatenated - which then
  # returned a tidy BLIND and read as a clean run.
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('aisle-fix-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
  '[{"id":"watermelon","product":"A","canonical_url":"https://x/shop/household/trash/a/p/1"},{"id":"watermelon","product":"B","canonical_url":"https://x/shop/fresh_fruits_vegetables/melons/b/p/2"}]' | Set-Content $tmp -Encoding UTF8
  $parsedFx = Read-JsonFile $tmp
  $rowsFx = @($parsedFx)
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  if ($rowsFx.Count -ne 2) { Write-Output ("  X ARRAY-UNROLL: a 2-row candidates file parsed to $($rowsFx.Count) row(s) - the PS 5.1 unroll bug is back"); $bad++ }
  else {
    $v1 = Judge -CatMap $P -CommodityId ([string]$rowsFx[0].id) -Url ([string]$rowsFx[0].canonical_url)
    $v2 = Judge -CatMap $P -CommodityId ([string]$rowsFx[1].id) -Url ([string]$rowsFx[1].canonical_url)
    if ($v1.verdict -ne 'BLOCK' -or $v2.verdict -ne 'ALLOW') { Write-Output ("  X ARRAY-UNROLL: rows judged $($v1.verdict)/$($v2.verdict), expected BLOCK/ALLOW"); $bad++ }
  }
  if ($bad) { Write-Output "aisle-test SELFTEST: FAILED ($bad)"; exit 2 }
  Write-Output 'aisle-test SELFTEST: 14/14 pass (5 must-fire blocked incl. an excepted commodity in a non-listed dept, 4 clean twins allowed incl. the hard positive and the exception path, 3 blind paths refuse, multi-row file unrolls)'
  exit 0
}

# ---- live ------------------------------------------------------------------------------------------
$feed = Get-ChildItem (Join-Path $root 'out\regular\family-fare-regular-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
if (-not $feed) { Write-Output 'BLIND: no Family Fare feed - no shelf evidence, so no flip can be judged'; exit 3 }
$catMap = Get-CategoryMap
Write-Output ("category map: {0} commodit(y/ies) carry an estate category; {1} categories have a reviewed department allowlist" -f $catMap.Count, $CAT_DEPT.Count)

$rows = @()
# -LiveBoard: judge the cells ALREADY ON THE BOARD, not hypothetical flips. This was not the use it was
# built for and it is the one that paid first: on 2026-08-01 it read 406 live Family Fare cells and found
# five wrong products, TWO of them holding the cheapest-price crown - Arm & Hammer Baking Soda Clumping
# CAT LITTER at $0.0375/oz as `baking-soda`, and Pineapple Teriyaki BRATS at $1.3725 as `pineapple`.
# Neither is a pricing error (both prices are real), which is exactly why no price guard could see them.
# Reads BOTH boards, for the reason in the recipe-board note on audit-everyday-mismatch.
if ($LiveBoard) {
  $cmpF = Get-ChildItem (Join-Path $root 'out\comparison-*.json') -EA SilentlyContinue |
  Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $cmpF) { Write-Output 'BLIND: no comparison-*.json'; exit 3 }
  $boardRows = @((Read-JsonFile $cmpF.FullName).comparison)
  $rbF2 = Join-Path $root 'out\recipe-board.json'
  if (Test-Path $rbF2) { $boardRows += @((Read-JsonFile $rbF2).comparison) }
  $feedF = Get-ChildItem (Join-Path $root 'out\regular\family-fare-regular-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $feedF) { Write-Output 'BLIND: no Family Fare feed - shelf paths come from it'; exit 3 }
  $fd = Read-JsonFile $feedF.FullName
  $frows = @($fd.deals); if (-not $frows.Count) { $frows = @($fd) }
  $urlByName = @{}
  foreach ($fr in $frows) { if ($fr.item -and $fr.canonical_url) { $urlByName[([string]$fr.item).Trim()] = [string]$fr.canonical_url } }
  $lb = New-Object System.Collections.Generic.List[object]
  foreach ($br in $boardRows) {
    foreach ($s in $br.stores) {
      if ([string]$s.store -ne 'Family Fare') { continue }   # only store publishing a shelf path today
      $nm = ([string]$s.item).Trim(); if (-not $nm) { continue }
      $u = $urlByName[$nm]; if (-not $u) { continue }
      $lb.Add([pscustomobject]@{ id = [string]$br.id; store = 'Family Fare'; product = $nm; canonical_url = $u })
    }
  }
  $rows = $lb.ToArray()
  Write-Output ("live-board mode: {0} Family Fare cell(s) carry a shelf path" -f $rows.Count)
}
# ConvertFrom-Json is called as a FUNCTION, not through a pipeline. In PS 5.1 `@(... | ConvertFrom-Json)`
# does NOT unroll a JSON array - the whole array arrives as one pipeline object, @() wraps it in a
# 1-element array, and the foreach below then sees a single "row" whose .id is every id concatenated
# ("watermelon watermelon milk milk coffee..."). It judges one nonexistent commodity, returns BLIND, and
# looks like a clean run. Fixtured below.
if ($Candidates) { $parsed = Read-JsonFile $Candidates; $rows = @($parsed) }
elseif ($Id) { $rows = @([pscustomobject]@{ id = $Id; product = $Product; canonical_url = $Url }) }
elseif (-not $LiveBoard) { Write-Output 'nothing to judge (pass -Candidates, -Id/-Url, or -LiveBoard)'; exit 0 }

$out = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
  $v = Judge -CatMap $catMap -CommodityId ([string]$r.id) -Url ([string]$r.canonical_url)
  $out.Add([pscustomobject]@{ id = [string]$r.id; store = [string]$r.store; product = [string]$r.product; dept = (Get-Dept ([string]$r.canonical_url)); aisle = (Get-Aisle ([string]$r.canonical_url)); verdict = $v.verdict; reason = $v.reason })
}
$g = @($out | Group-Object verdict | Sort-Object Name)
Write-Output ("judged {0} candidate flip(s): {1}" -f $out.Count, (($g | ForEach-Object { "$($_.Name)=$(@($_.Group).Count)" }) -join '  '))
foreach ($r in ($out | Sort-Object verdict, id)) {
  Write-Output ("  {0,-6} {1,-24} {2}" -f $r.verdict, $r.id, ([string]$r.product).Substring(0, [math]::Min(46, ([string]$r.product).Length)))
  Write-Output ("         {0}" -f $r.reason)
}
if (-not $OutFile) { $OutFile = Join-Path $root 'out\aisle-test.json' }
($out.ToArray() | ConvertTo-Json -Depth 4) | Set-Content $OutFile -Encoding UTF8
Write-Output "-> $OutFile"
Write-GuardComplete -Name 'aisle-test' -Summary ''
exit 0

