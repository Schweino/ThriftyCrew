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

  THE RULE ITSELF LIVES IN aisle-lib.ps1 SINCE 2026-09-11 (queue 2026-09-11-62b248). compare-deals.ps1 now
  refuses a Family Fare row at ADMISSION through the same functions, so the department tables, the reviewed
  exceptions and the verdict moved there verbatim. This file keeps the outcome watch (-LiveBoard), the
  candidate judge (-Candidates / -Id) and the hermetic self-test, which drives the lib's code path.

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
. (Join-Path $PSScriptRoot 'aisle-lib.ps1')   # THE rule: Get-AisleDept, the two department tables, Test-AisleAllowed, the admission index
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# ---- thin names over the lib, so this file reads the way it always has ------------------------------
function Get-Dept([string]$u) { return (Get-AisleDept $u) }
function Get-Aisle([string]$u) { return (Get-AisleShelf $u) }
$CAT_DEPT = $AISLE_CAT_DEPT
$COMMODITY_DEPT = $AISLE_COMMODITY_DEPT
function Get-CategoryMap { return (Get-AisleCategoryMap -Root $root) }

# ---- per-commodity evidence, kept as a SECONDARY signal only -----------------------------------------
# Still useful for reporting how unusual a candidate is, but it no longer decides anything, because of
# the pollution recorded in aisle-lib.ps1.
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
  return (Test-AisleAllowed -CatMap $CatMap -CommodityId $CommodityId -Url $Url)
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
  # ---- ADMISSION (2026-09-11, queue 2026-09-11-62b248) --------------------------------------------------
  # compare-deals refuses a Family Fare row through Get-AisleAdmissionRefusal over the index Add-AisleShelfRow
  # builds, so these cases drive exactly that path. Rows frozen verbatim from family-fare-regular-2026-09-11.json;
  # the Planters row carried no canonical_url that day, so its department is the one the 2026-08-31 review
  # recorded ('dairy/ready_to_eat'), passed as the dept field the builder now stamps.
  $PA = @{ 'frozen-pizza' = 'frozen'; 'pistachios' = 'snacks' }
  $ix = New-AisleShelfIndex
  Add-AisleShelfRow $ix ([pscustomobject]@{ item = 'Contadina Tmto Bsl Pizza Squz Btl'; product_id = '1764405684716243059'; canonical_url = 'https://www.shopfamilyfare.com/shop/pantry/canned_goods/tomato_sauce_paste/contadina_tmto_bsl_pizza_squz_btl/p/1764405684716243059' })
  Add-AisleShelfRow $ix ([pscustomobject]@{ item = 'Di Giorno Frozen Pizza, Rising Crust Sausage & Pepperoni Pizza, 27.3oz (Frozen)'; product_id = '1564405684715603663'; canonical_url = 'https://www.shopfamilyfare.com/shop/freezer/frozen_meals_more/pizza/di_giorno_frozen_pizza_rising_crust_sausage_pepperoni_pizza_27_3oz_frozen/p/1564405684715603663' })
  Add-AisleShelfRow $ix ([pscustomobject]@{ item = 'Planters Dry Roasted Pistachios 12.75 Oz'; dept = 'dairy' })
  # MUST-FIRE: the founding row is refused at admission, by id, and the refusal names the department it saw
  $ref = Get-AisleAdmissionRefusal -CatMap $PA -Store 'Family Fare' -CommodityId 'frozen-pizza' -Dept (Get-AisleShelfDept $ix '1764405684716243059' 'Contadina Tmto Bsl Pizza Squz Btl')
  if (-not $ref -or [string]$ref.dept -ne 'pantry' -or [string]$ref.verdict -ne 'BLOCK') { Write-Output '  X MUST-FIRE: the Contadina squeeze bottle on frozen-pizza was NOT refused at admission naming dept pantry'; $bad++ }
  # MUST-FIRE: and by NAME when the row carries no product id (an ad row naming the same product)
  $ref2 = Get-AisleAdmissionRefusal -CatMap $PA -Store 'Family Fare' -CommodityId 'frozen-pizza' -Dept (Get-AisleShelfDept $ix '' '  Contadina Tmto Bsl Pizza Squz Btl ')
  if (-not $ref2) { Write-Output '  X MUST-FIRE: the Contadina row was NOT refused when looked up by name alone'; $bad++ }
  # CLEAN TWIN: the real frozen pizza's shelf resolves to freezer and is ALLOWED for frozen-pizza
  $dg = Test-AisleAllowed -CatMap $PA -CommodityId 'frozen-pizza' -Dept (Get-AisleShelfDept $ix '1564405684715603663' '')
  if ($dg.verdict -ne 'ALLOW' -or $dg.dept -ne 'freezer') { Write-Output ("  X CLEAN-TWIN: Di Giorno should ALLOW from freezer - got $($dg.verdict) from '$($dg.dept)'"); $bad++ }
  # CLEAN TWIN: a reviewed COMMODITY_DEPT exception is honoured by the same path (category 'snacks' does not allow dairy)
  $pl = Test-AisleAllowed -CatMap $PA -CommodityId 'pistachios' -Dept (Get-AisleShelfDept $ix '' 'Planters Dry Roasted Pistachios 12.75 Oz')
  if ($pl.verdict -ne 'ALLOW' -or $pl.reason -notmatch 'reviewed exception') { Write-Output ("  X CLEAN-TWIN: Planters pistachios in dairy should ALLOW through the reviewed exception - got $($pl.verdict): $($pl.reason)"); $bad++ }
  # MUST NOT FIRE: a Family Fare row with no shelf path is ADMITTED (BLIND admits at admission), and another
  # store's row is never judged even when its name matches a refused product
  $blindAdmit = Get-AisleAdmissionRefusal -CatMap $PA -Store 'Family Fare' -CommodityId 'frozen-pizza' -Dept (Get-AisleShelfDept $ix '999' 'Bellatoria Ultra Thin Crust Ultimate Supreme Pizza 19.41 Oz')
  $otherStore = Get-AisleAdmissionRefusal -CatMap $PA -Store 'Walmart' -CommodityId 'frozen-pizza' -Dept 'pantry'
  if ($null -ne $blindAdmit -or $null -ne $otherStore) { Write-Output '  X MUST-NOT-FIRE: a row with no shelf path, or a non-Family-Fare row, was refused at admission'; $bad++ }
  # MUST NOT FIRE: a shelf-less canonical_url is not a department. Frozen verbatim from the row the 2026-09-11 dry
  # run refused before Get-AisleDept learned this: the product SLUG was read as department
  # 'kraft_grated_cheese_parmesan_cheese_8_oz' and a real grated parmesan was blocked from parmesan.
  $krUrl = 'https://www.shopfamilyfare.com/shop/kraft_grated_cheese_parmesan_cheese_8_oz/p/1564405684716409165'
  $ixK = New-AisleShelfIndex
  Add-AisleShelfRow $ixK ([pscustomobject]@{ item = 'Kraft Grated Cheese, Parmesan Cheese, 8 Oz'; product_id = '1564405684716409165'; canonical_url = $krUrl })
  $krRef = Get-AisleAdmissionRefusal -CatMap @{ 'parmesan' = 'dairy' } -Store 'Family Fare' -CommodityId 'parmesan' -Dept (Get-AisleShelfDept $ixK '1564405684716409165' 'Kraft Grated Cheese, Parmesan Cheese, 8 Oz')
  if ((Get-Dept $krUrl) -ne '' -or $null -ne $krRef) { Write-Output ("  X MUST-NOT-FIRE: the shelf-less Kraft URL was read as department '" + (Get-Dept $krUrl) + "' and refused a real parmesan"); $bad++ }
  if ($bad) { Write-Output "aisle-test SELFTEST: FAILED ($bad)"; exit 2 }
  Write-Output 'aisle-test SELFTEST: 20/20 pass (5 must-fire blocked incl. an excepted commodity in a non-listed dept, 4 clean twins allowed incl. the hard positive and the exception path, 3 blind paths refuse, multi-row file unrolls; ADMISSION: the Contadina squeeze bottle refused by id and by name naming pantry, Di Giorno allowed from freezer, the Planters exception honoured, a shelf-less row and a non-FF row admitted, a /shop/<product_slug>/p/ URL is not a department)'
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
Exit-Guard -Name 'aisle-test' -Summary '' -Code 0

