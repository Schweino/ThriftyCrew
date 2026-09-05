<#
  measure-cheapest-selection.ps1 - READ-ONLY blast radius for the "cheapest store" fix.

  THE DEFECT IT MEASURES. The recipe card's cost section picks, per ingredient, the store with the lowest
  PER-UNIT price (pricing_inputs[bid].current, chosen server-side by export-feed.ps1) and then charges the
  reader for WHOLE PACKAGES at that store. Those two rules fight: a warehouse store wins on per-unit with a
  huge package and the reader is billed for the huge package. Butter needs 0.194 lb and the receipt bills a
  Sam's Club 4 lb box at $10.22 while Aldi's 1 lb box is $2.89.

  This script computes, over the LIVE feed and all built cards, what every ingredient line and every recipe
  total costs under:
    OLD rule = the single pre-selected cell (today's card)
    NEW rule = the minimum COST across every store cell (what "Shop this recipe" already does)
  at base servings and at 7 and 28, because the winning store DEPENDS ON QUANTITY: over about 3.5 lb the
  Sam's 4 lb pack really is cheapest, which is exactly why the selection cannot be pinned server-side.

  It writes nothing but its own report. Keep it as a rerunnable audit: after the fix ships, its old-vs-new
  delta doubles as a regression probe - a change that reintroduces per-unit selection makes the deltas
  reappear.

  -SelfTest runs two frozen fixtures with no feed and no cards: the MUST-FIRE butter shape (per-unit winner
  Sam's 4 lb, cost winner Aldi 1 lb) and its CLEAN TWIN (per-unit winner is also the cost winner, so nothing
  moves). Per the standing guard-fixture rule, every guard ships the bug that founded it plus a clean twin.

  Usage:
    powershell -File grocery\measure-cheapest-selection.ps1
    powershell -File grocery\measure-cheapest-selection.ps1 -SelfTest
#>
param(
  [string]$FeedPath = '',
  [string]$BuiltDir = '',
  [string]$OutFile  = '',
  [string]$SummaryFile = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $root -Parent

# ---------------------------------------------------------------------------------------------------
# THE CARD'S MATH comes from meal-prep\lib\package-cost-lib.ps1, the ONE server-side mirror of
# costAt()/cheapestAcross() in tpl2-scaler-prefix.html. compute-v2-perserving.ps1 uses the same lib. Do not
# re-transcribe the JS here: a second PowerShell copy is how the counts below would quietly become fiction.
# The fixtures below pin the exact cell shapes the template produces.
# ---------------------------------------------------------------------------------------------------
. (Join-Path $repo 'meal-prep\lib\package-cost-lib.ps1')
function Get-CellField($cell, [string]$name) { return (Get-PkgCellField $cell $name) }
function Get-CellCost($cell, [double]$required, [double]$fallbackBasis) { return (Get-PkgCellCost $cell $required $fallbackBasis) }
function Get-CheapestAcross($inputs, [double]$required, [double]$fallbackBasis, [bool]$NonSaleOnly) {
  if ($NonSaleOnly) { return (Get-PkgCheapestAcross $inputs $required $fallbackBasis -NonSaleOnly) }
  return (Get-PkgCheapestAcross $inputs $required $fallbackBasis)
}

# ---------------------------------------------------------------------------------------------------
# FIXTURES. Frozen shapes, no feed, no cards, no network.
# ---------------------------------------------------------------------------------------------------
if ($SelfTest) {
  $fail = New-Object System.Collections.Generic.List[string]
  # MUST FIRE: the founding bug, measured live 2026-08-15 on bangers-and-mash-onion-gravy / butter.
  # 88 g of butter at gpu 453.592 = 0.194 lb. Sam's wins per-unit at $2.555/lb with a 4 lb box ($10.22);
  # Aldi is dearer per pound and cheaper to BUY, because you only have to buy one pound of it.
  $butterJson = '{"current":{"store":"Sam''s Club","unit":"lb","perUnitMicros":2555000,"variableWeight":false,"packageBasisUnits":4,"purchasePriceMinor":1022},"stores":{"Sam''s Club":{"perUnitMicros":2555000,"variableWeight":false,"packageBasisUnits":4,"purchasePriceMinor":1022},"Aldi":{"perUnitMicros":2890000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":289},"Walmart":{"perUnitMicros":2976000,"variableWeight":false,"packageBasisUnits":2.003,"purchasePriceMinor":596},"Fareway":{"perUnitMicros":3480000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":348}}}'
  $butter = $butterJson | ConvertFrom-Json
  $req = 88.0 / 453.592
  $old = Get-CellCost $butter.current $req 0
  $new = Get-CheapestAcross $butter $req 0 $false
  if ($null -eq $old -or [math]::Round($old.cost,2) -ne 10.22) { $fail.Add("must-fire: OLD rule should bill 10.22, got " + $(if($null -eq $old){'null'}else{[math]::Round($old.cost,2)})) }
  if ($null -eq $new) { $fail.Add('must-fire: NEW rule returned nothing') }
  else {
    if ([math]::Round($new.cost,2) -ne 2.89) { $fail.Add("must-fire: NEW rule should bill 2.89, got " + [math]::Round($new.cost,2)) }
    if ($new.store -ne 'Aldi') { $fail.Add("must-fire: NEW rule should pick Aldi, got '" + $new.store + "'") }
  }
  # QUANTITY DEPENDENCE, the reason this cannot be pinned server-side: at 4 lb the warehouse pack wins
  # honestly and the NEW rule must say so. A fix that always picks the small package is also wrong.
  $bulk = Get-CheapestAcross $butter 4.0 0 $false
  if ($null -eq $bulk -or $bulk.store -ne "Sam's Club") { $fail.Add("must-fire: at 4 lb the NEW rule should pick Sam's Club, got '" + $(if($null -eq $bulk){'null'}else{$bulk.store}) + "'") }
  # CLEAN TWIN: per-unit winner IS the cost winner (every store sells the same 1 lb package), so the fix
  # must change nothing at all. A guard that only ever fires has not been shown to discriminate.
  $twinJson = '{"current":{"store":"Aldi","unit":"lb","perUnitMicros":1000000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":100},"stores":{"Aldi":{"perUnitMicros":1000000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":100},"Hy-Vee":{"perUnitMicros":1500000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":150}}}'
  $twin = $twinJson | ConvertFrom-Json
  $tOld = Get-CellCost $twin.current 0.5 0
  $tNew = Get-CheapestAcross $twin 0.5 0 $false
  if ($null -eq $tOld -or $null -eq $tNew) { $fail.Add('clean twin: one of the rules returned nothing') }
  elseif ([math]::Round($tOld.cost,4) -ne [math]::Round($tNew.cost,4) -or $tNew.store -ne 'Aldi') { $fail.Add("clean twin: the fix moved a line it must not (old " + $tOld.cost + " new " + $tNew.cost + " at " + $tNew.store + ")") }
  # VARIABLE WEIGHT: a meat-counter cell is priced by the exact amount used, no package rounding.
  $varJson = '{"stores":{"Fareway":{"perUnitMicros":3000000,"variableWeight":true},"Hy-Vee":{"perUnitMicros":2000000,"variableWeight":true}}}'
  $vr = Get-CheapestAcross ($varJson | ConvertFrom-Json) 2.0 0 $false
  if ($null -eq $vr -or [math]::Round($vr.cost,2) -ne 4.00 -or $vr.store -ne 'Hy-Vee') { $fail.Add('variable-weight: expected $4.00 at Hy-Vee for 2 units') }
  # PER-UNIT-ONLY cell: no packageBasisUnits, so the recipe's own authored pkg_g/gpu is the basis and the
  # shelf tag must NOT be used (it belongs to a package we do not know the size of).
  $puoJson = '{"stores":{"Aldi":{"perUnitMicros":2000000,"variableWeight":false}}}'
  $puo = Get-CheapestAcross ($puoJson | ConvertFrom-Json) 0.3 1.0 $false
  if ($null -eq $puo -or [math]::Round($puo.cost,2) -ne 2.00) { $fail.Add('per-unit-only: expected $2.00 from the authored 1-unit package fallback') }
  # SALE FILTER: the everyday lane must skip a sale cell even when it is the cheapest to buy.
  $saleJson = '{"stores":{"Hy-Vee":{"perUnitMicros":1000000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":100,"sale":true},"Aldi":{"perUnitMicros":2000000,"variableWeight":false,"packageBasisUnits":1,"purchasePriceMinor":200}}}'
  $sd = $saleJson | ConvertFrom-Json
  $anyC = Get-CheapestAcross $sd 0.5 0 $false
  $evC  = Get-CheapestAcross $sd 0.5 0 $true
  if ($null -eq $anyC -or $anyC.store -ne 'Hy-Vee') { $fail.Add('sale filter: the cheapest lane must still see the sale cell') }
  if ($null -eq $evC -or $evC.store -ne 'Aldi') { $fail.Add('sale filter: the everyday lane must skip the sale cell') }
  if ($fail.Count) { Write-Output 'SELFTEST FAIL:'; foreach ($f in $fail) { Write-Output ('  ' + $f) }; exit 2 }
  Write-Output 'SELFTEST PASS: must-fire butter shape (Sam''s $10.22 -> Aldi $2.89), quantity flip at 4 lb, clean twin unchanged, variable-weight, per-unit-only fallback, sale filter'
  exit 0
}

# ---------------------------------------------------------------------------------------------------
# LIVE MEASUREMENT
# ---------------------------------------------------------------------------------------------------
if (-not $FeedPath)    { $FeedPath    = Join-Path $repo 'public\smp-feed.json' }
if (-not $BuiltDir)    { $BuiltDir    = Join-Path $repo 'meal-prep\db\built' }
if (-not $OutFile)     { $OutFile     = Join-Path $root 'out\cheapest-selection-report.json' }
if (-not $SummaryFile) { $SummaryFile = Join-Path $repo 'design\MEASURE-cheapest-selection.md' }

$feed = Get-Content $FeedPath -Raw -Encoding utf8 | ConvertFrom-Json
$schema = 0
if ($feed.PSObject.Properties['schema']) { $schema = [int]$feed.schema }
$pi = $feed.pricing_inputs
$piMap = @{}
foreach ($p in $pi.PSObject.Properties) { $piMap[[string]$p.Name] = $p.Value }
$ingMap = @{}
foreach ($p in $feed.ingredients.PSObject.Properties) { $ingMap[[string]$p.Name] = $p.Value }
$saleFlagged = 0
foreach ($k in $piMap.Keys) {
  $st = Get-CellField $piMap[$k] 'stores'
  if ($null -eq $st) { continue }
  foreach ($sp in $st.PSObject.Properties) { if ((Get-CellField $sp.Value 'sale') -eq $true) { $saleFlagged++ } }
}
$canEveryday = ($schema -ge 2)

Write-Output ("feed: {0}  week_of {1}  schema {2}  pricing_inputs {3}  sale-flagged cells {4}" -f $FeedPath, $feed.week_of, $schema, $piMap.Count, $saleFlagged)
if (-not $canEveryday) {
  Write-Output 'NOTE: feed carries no schema marker, so sale cells cannot be identified on the lean per-store entries.'
  Write-Output '      The EVERYDAY lane is reported as not-measurable rather than guessed. Re-run after the feed change.'
}

# THE TYPED SCRIPT TAG IS THE ANCHOR. Do not string-search for 'smp-sc-data': the template's own JS
# contains that literal (box.querySelector('.smp-sc-data')), so a naive search matches the wrong block.
$reData = [regex]'(?s)<script type="application/json" class="smp-sc-data">(.*?)</script>'
$cards = @(Get-ChildItem (Join-Path $BuiltDir '*.body.html') | Sort-Object Name)
Write-Output ("cards: {0} built" -f $cards.Count)

$SERVING_LANES = @(7, 28)
$recipeRows = New-Object System.Collections.Generic.List[object]
$switchRows = New-Object System.Collections.Generic.List[object]
$parseFail  = New-Object System.Collections.Generic.List[string]
$namedExample = $null

foreach ($cf in $cards) {
  $slug = $cf.Name -replace '\.body\.html$',''
  $html = Get-Content $cf.FullName -Raw -Encoding utf8
  $m = $reData.Match($html)
  if (-not $m.Success) { $parseFail.Add("$slug (no smp-sc-data block)"); continue }
  $data = $null
  try { $data = $m.Groups[1].Value | ConvertFrom-Json } catch { $parseFail.Add("$slug (unparseable data block)"); continue }
  if ($null -eq $data -or $null -eq $data.ing) { $parseFail.Add("$slug (data block carries no ing[])"); continue }
  $base = if ($data.base) { [int]$data.base } else { 14 }
  $ings = @($data.ing)

  $lanes = New-Object System.Collections.Generic.List[object]
  foreach ($nn in (@($base) + $SERVING_LANES)) {
    $oldTot = 0.0; $newTot = 0.0; $oldComplete = $true; $newComplete = $true
    $switched = 0; $priced = 0
    $evOldTot = 0.0; $evNewTot = 0.0; $evOldComplete = $true; $evNewComplete = $true; $evSwitched = 0
    foreach ($it in $ings) {
      $bid = [string](Get-CellField $it 'bid')
      $gpu = [double](Get-CellField $it 'gpu')
      $grams = [double](Get-CellField $it 'grams')
      $pkgG = [double](Get-CellField $it 'pkg_g')
      $required = if ($gpu -gt 0) { $grams * ($nn / [double]$base) / $gpu } else { 0.0 }
      $inputs = if ($bid -and $piMap.ContainsKey($bid)) { $piMap[$bid] } else { $null }
      if ($null -eq $inputs -or -not ($required -gt 0)) { $oldComplete = $false; $newComplete = $false; $evOldComplete = $false; $evNewComplete = $false; continue }
      $fallback = if ($pkgG -gt 0 -and $gpu -gt 0) { $pkgG / $gpu } else { 0.0 }

      # ---- cheapest lane
      $oldR = Get-CellCost (Get-CellField $inputs 'current') $required $fallback
      $newR = Get-CheapestAcross $inputs $required $fallback $false
      if ($null -eq $oldR) { $oldComplete = $false } else { $oldTot += $oldR.cost }
      if ($null -eq $newR) { $newComplete = $false } else { $newTot += $newR.cost }
      if ($null -ne $oldR -and $null -ne $newR) {
        $priced++
        $oldStore = [string](Get-CellField (Get-CellField $inputs 'current') 'store')
        if ($newR.store -ne $oldStore -or [math]::Round($newR.cost,2) -ne [math]::Round($oldR.cost,2)) {
          $switched++
          if ($nn -eq $base) {
            $switchRows.Add([pscustomobject]@{
              slug=$slug; item=[string](Get-CellField $it 'item'); bid=$bid
              servings=$nn; required=[math]::Round($required,4)
              old_store=$oldStore; old_cost=[math]::Round($oldR.cost,2); old_k=$oldR.k
              new_store=$newR.store; new_cost=[math]::Round($newR.cost,2); new_k=$newR.k
              new_own_basis=[bool]$newR.own_basis; old_own_basis=[bool]$oldR.own_basis
              delta=[math]::Round($newR.cost - $oldR.cost,2)
            })
          }
        }
      }

      # ---- everyday lane (only meaningful once the feed marks sale cells)
      if ($canEveryday) {
        $evSrc = Get-CellField $inputs 'everyday'
        if ($null -eq $evSrc) { $evSrc = Get-CellField $inputs 'current' }
        $evOldR = Get-CellCost $evSrc $required $fallback
        $evNewR = Get-CheapestAcross $inputs $required $fallback $true
        if ($null -eq $evOldR) { $evOldComplete = $false } else { $evOldTot += $evOldR.cost }
        if ($null -eq $evNewR) { $evNewComplete = $false } else { $evNewTot += $evNewR.cost }
        if ($null -ne $evOldR -and $null -ne $evNewR -and [math]::Round($evNewR.cost,2) -ne [math]::Round($evOldR.cost,2)) { $evSwitched++ }
      }
    }
    $lanes.Add([pscustomobject]@{
      servings=$nn
      old_total=$(if($oldComplete){[math]::Round($oldTot,2)}else{$null})
      new_total=$(if($newComplete){[math]::Round($newTot,2)}else{$null})
      delta=$(if($oldComplete -and $newComplete){[math]::Round($newTot-$oldTot,2)}else{$null})
      lines_priced=$priced; lines_switched=$switched
      everyday_old_total=$(if($canEveryday -and $evOldComplete){[math]::Round($evOldTot,2)}else{$null})
      everyday_new_total=$(if($canEveryday -and $evNewComplete){[math]::Round($evNewTot,2)}else{$null})
      everyday_lines_switched=$(if($canEveryday){$evSwitched}else{$null})
    })
  }
  $baseLane = $lanes[0]
  $recipeRows.Add([pscustomobject]@{ slug=$slug; base=$base; ingredients=$ings.Count; lanes=$lanes.ToArray() })
  if ($slug -eq 'bangers-and-mash-onion-gravy') { $namedExample = $baseLane }
}

# ---------------------------------------------------------------------------------------------------
# ROLLUP
# ---------------------------------------------------------------------------------------------------
$baseLaneOf = { param($r) $r.lanes[0] }
$withBoth = @($recipeRows | Where-Object { $null -ne $_.lanes[0].old_total -and $null -ne $_.lanes[0].new_total })
$deltas = @($withBoth | ForEach-Object { [double]$_.lanes[0].delta })
$rose = @($withBoth | Where-Object { [double]$_.lanes[0].delta -gt 0.005 })
$fell = @($withBoth | Where-Object { [double]$_.lanes[0].delta -lt -0.005 })
$medianDelta = 0.0
if ($deltas.Count) { $sorted = @($deltas | Sort-Object); $medianDelta = if ($sorted.Count % 2) { $sorted[[int](($sorted.Count-1)/2)] } else { ($sorted[$sorted.Count/2 - 1] + $sorted[$sorted.Count/2]) / 2 } }
$maxDrop = if ($deltas.Count) { ($deltas | Measure-Object -Minimum).Minimum } else { 0 }
$switchedLines = $switchRows.Count
$switchedRecipes = @($recipeRows | Where-Object { $_.lanes[0].lines_switched -gt 0 }).Count
# switches that land on a cell with NO package size of its own, so the line is priced against the recipe's
# authored package. Pre-existing fallback, but the min-cost scan reaches those cells more often than
# per-unit selection did, so the number is recorded rather than discovered later.
$fallbackWins = @($switchRows.ToArray() | Where-Object { -not $_.new_own_basis }).Count

# serving-count dependence: lines whose winning store at 28 servings differs from the winner at 7
$laneSwitch = @{}
foreach ($r in $recipeRows) {
  foreach ($l in $r.lanes) { if (-not $laneSwitch.ContainsKey([string]$l.servings)) { $laneSwitch[[string]$l.servings] = 0 }; $laneSwitch[[string]$l.servings] += [int]$l.lines_switched }
}

Write-Output ''
Write-Output ("=== CHEAPEST LANE, at each recipe's base servings ===")
Write-Output ("  recipes measured with both totals : {0} of {1}" -f $withBoth.Count, $recipeRows.Count)
Write-Output ("  ingredient lines that switch store: {0} across {1} recipe(s)" -f $switchedLines, $switchedRecipes)
Write-Output ("  recipe totals that FALL           : {0}" -f $fell.Count)
Write-Output ("  recipe totals that RISE           : {0}   <- must be 0; any rise is a bug or a real find" -f $rose.Count)
Write-Output ("  median delta                      : {0}" -f ('$' + [math]::Round($medianDelta,2)))
Write-Output ("  largest single-recipe drop        : {0}" -f ('$' + [math]::Round($maxDrop,2)))
Write-Output ("  lines switching at 7 / 28 servings: {0} / {1}" -f $laneSwitch['7'], $laneSwitch['28'])
Write-Output ("  switches won by a per-unit-only cell (priced on the recipe's authored package): {0}" -f $fallbackWins)
if ($rose.Count) {
  Write-Output '  RISING RECIPES (stop and look):'
  foreach ($r in ($rose | Select-Object -First 15)) { Write-Output ("    {0}  {1} -> {2}" -f $r.slug, $r.lanes[0].old_total, $r.lanes[0].new_total) }
}
if ($namedExample) {
  Write-Output ''
  Write-Output ("  NAMED EXAMPLE bangers-and-mash-onion-gravy: old {0} -> new {1} ({2} line(s) switched)" -f ('$'+$namedExample.old_total), ('$'+$namedExample.new_total), $namedExample.lines_switched)
  $but = @($switchRows | Where-Object { $_.slug -eq 'bangers-and-mash-onion-gravy' -and $_.bid -eq 'butter' })
  if ($but.Count) { Write-Output ("    butter: {0} `${1} -> {2} `${3}" -f $but[0].old_store, $but[0].old_cost, $but[0].new_store, $but[0].new_cost) }
  else { Write-Output '    butter: DID NOT SWITCH - the founding example is not reproducing, stop and look' }
}
if ($canEveryday) {
  $evBoth = @($recipeRows | Where-Object { $null -ne $_.lanes[0].everyday_old_total -and $null -ne $_.lanes[0].everyday_new_total })
  $evFell = @($evBoth | Where-Object { ([double]$_.lanes[0].everyday_new_total - [double]$_.lanes[0].everyday_old_total) -lt -0.005 })
  $evRose = @($evBoth | Where-Object { ([double]$_.lanes[0].everyday_new_total - [double]$_.lanes[0].everyday_old_total) -gt 0.005 })
  $evLines = 0; foreach ($r in $recipeRows) { $evLines += [int]$r.lanes[0].everyday_lines_switched }
  Write-Output ''
  Write-Output '=== EVERYDAY LANE (min cost over NON-SALE cells) ==='
  Write-Output ("  ingredient lines that move: {0}" -f $evLines)
  Write-Output ("  recipe totals fall / rise : {0} / {1}" -f $evFell.Count, $evRose.Count)
  # The invariant the card depends on: the cheapest scan's candidate set is a SUPERSET of the everyday
  # scan's, so cheapest <= everyday must hold on every recipe, per line, by construction.
  $inv = @($recipeRows | Where-Object { $null -ne $_.lanes[0].new_total -and $null -ne $_.lanes[0].everyday_new_total -and ([double]$_.lanes[0].new_total - [double]$_.lanes[0].everyday_new_total) -gt 0.005 })
  Write-Output ("  recipes where NEW cheapest > NEW everyday: {0}   <- must be 0 by construction" -f $inv.Count)
  foreach ($r in ($inv | Select-Object -First 10)) { Write-Output ("    {0}  cheapest {1} vs everyday {2}" -f $r.slug, $r.lanes[0].new_total, $r.lanes[0].everyday_new_total) }
}
if ($parseFail.Count) {
  Write-Output ''
  Write-Output ("PARSE FAILURES: {0} card(s)" -f $parseFail.Count)
  foreach ($p in ($parseFail | Select-Object -First 10)) { Write-Output ('  ' + $p) }
}

# ---------------------------------------------------------------------------------------------------
# PHASE 2 PROBE: would aligning cheapest_ps change WHICH RECIPES ARE FREE?
#
# Two variants, and the difference between them is the whole decision:
#   A) keep compute-v2's RECIPE package basis (k * pkg_g/gpu * per_unit) and merely pick the store that
#      minimises cost. k and pkg_g/gpu do not vary by store, so minimising cost over a fixed basis is
#      ALGEBRAICALLY IDENTICAL to minimising per-unit. Variant A is a no-op by construction.
#   B) move to the STORE's package basis, i.e. exactly what the card will compute. This is the only
#      version of "align cheapest_ps to the card" that changes anything.
# So phase 2 is a basis change, not a selection change, and B is what is diffed below.
# ---------------------------------------------------------------------------------------------------
$freeDiff = $null
try {
  $v2Path = Join-Path $repo 'meal-prep\pipeline\v2-perserving.json'
  $costsPath = Join-Path $root 'out\recipe-costs.json'
  $dbPath = Join-Path $repo 'meal-prep\recipes-db.json'
  if ((Test-Path $v2Path) -and (Test-Path $costsPath) -and (Test-Path $dbPath)) {
    $v2 = Read-JsonFile $v2Path
    $v2Map = @{}; foreach ($r in $v2) { $v2Map[[string]$r.slug] = $r }
    $costsDoc = Read-JsonFile $costsPath
    $costMap = @{}; foreach ($c in $costsDoc.recipes) { $costMap[[string]$c.slug] = $c }
    $dbDoc = Read-JsonFile $dbPath
    $protMap = @{}; $servMap = @{}
    foreach ($r in $dbDoc.recipes) { $protMap[[string]$r.slug] = [string]$r.protein; $servMap[[string]$r.slug] = [int]$r.servings }

    # variant-B per-serving, from the card's own math at base servings
    $newPs = @{}
    foreach ($rr in $recipeRows) {
      $l = $rr.lanes[0]
      if ($null -eq $l.new_total) { continue }
      $sv = if ($servMap.ContainsKey($rr.slug) -and $servMap[$rr.slug] -gt 0) { $servMap[$rr.slug] } else { $rr.base }
      $ps = [math]::Round([double]$l.new_total / $sv, 2)
      # keep compute-v2's standing clamp: cheapest can never exceed everyday
      $ev = if ($v2Map.ContainsKey($rr.slug)) { [double]$v2Map[$rr.slug].everyday_ps } else { 0 }
      if ($ev -gt 0 -and $ps -gt $ev) { $ps = $ev }
      $newPs[$rr.slug] = $ps
    }
    function Get-FreeSet($psLookup) {
      $out = [ordered]@{}
      foreach ($prot in @('chicken','turkey','beef','pork')) {
        $cands = New-Object System.Collections.Generic.List[object]
        foreach ($slug in $protMap.Keys) {
          if ($protMap[$slug] -ne $prot) { continue }
          if (-not $costMap.ContainsKey($slug)) { continue }
          if ([double]$costMap[$slug].calories -le 500) { continue }
          $ps = & $psLookup $slug
          if ($null -eq $ps) { continue }
          $sv = if ($servMap.ContainsKey($slug) -and $servMap[$slug] -gt 0) { $servMap[$slug] } else { 14 }
          $cands.Add([pscustomobject]@{ slug=$slug; per_serving=[double]$ps; week_cost=[math]::Round([double]$ps * $sv, 2) })
        }
        # the exact 3-key tie-break top5-weekly and rotate-free-dinners both use
        $ranked = @($cands.ToArray() | Sort-Object @{e={[double]$_.per_serving}}, @{e={[double]$_.week_cost}}, @{e={$_.slug}} | Select-Object -First 5)
        $out[$prot] = @($ranked | ForEach-Object { $_.slug })
      }
      return $out
    }
    $todaySet = Get-FreeSet { param($s) if ($costMap.ContainsKey($s)) { [double]$costMap[$s].per_serving } else { $null } }
    $newSet   = Get-FreeSet { param($s) if ($newPs.ContainsKey($s)) { $newPs[$s] } else { $null } }
    $changed = New-Object System.Collections.Generic.List[object]
    foreach ($prot in @('chicken','turkey','beef','pork')) {
      $a = @($todaySet[$prot]); $b = @($newSet[$prot])
      $lost = @($a | Where-Object { $b -notcontains $_ })
      $gained = @($b | Where-Object { $a -notcontains $_ })
      if ($lost.Count -or $gained.Count) { $changed.Add([pscustomobject]@{ protein=$prot; loses_free=$lost; gains_free=$gained }) }
    }
    $freeDiff = [pscustomobject]@{ today=$todaySet; phase2_variant_b=$newSet; changed=$changed.ToArray(); variant_a_is_noop=$true }
    Write-Output ''
    Write-Output '=== PHASE 2 PROBE: free-dinner rotation ==='
    Write-Output '  variant A (keep the recipe package basis) is algebraically a NO-OP: min cost over a fixed basis == min per-unit.'
    if ($changed.Count -eq 0) { Write-Output '  variant B (store package basis): the free set does NOT change.' }
    else {
      Write-Output ("  variant B (store package basis): the free set CHANGES in {0} protein class(es). Brad decides before any phase 2 work." -f $changed.Count)
      foreach ($c in $changed) {
        Write-Output ("    {0}: loses free [{1}]  gains free [{2}]" -f $c.protein, ($c.loses_free -join ', '), ($c.gains_free -join ', '))
      }
    }
  } else { Write-Output ''; Write-Output 'PHASE 2 PROBE skipped: one of v2-perserving.json / recipe-costs.json / recipes-db.json is missing.' }
} catch {
  Write-Output ('PHASE 2 PROBE failed: ' + $_.Exception.Message)
}

# ---------------------------------------------------------------------------------------------------
# WRITE THE REPORT
# ---------------------------------------------------------------------------------------------------
$report = [ordered]@{
  generated = (Get-Date).ToString('s')
  feed_path = $FeedPath
  feed_week_of = [string]$feed.week_of
  feed_schema = $schema
  everyday_lane_measured = $canEveryday
  sale_flagged_cells = $saleFlagged
  cards = $cards.Count
  parse_failures = $parseFail.ToArray()
  summary = [ordered]@{
    recipes_with_both_totals = $withBoth.Count
    lines_switching_store = $switchedLines
    recipes_with_a_switch = $switchedRecipes
    recipe_totals_fell = $fell.Count
    recipe_totals_rose = $rose.Count
    median_delta = [math]::Round($medianDelta,2)
    max_drop = [math]::Round($maxDrop,2)
    switches_won_by_per_unit_only_cell = $fallbackWins
    lines_switching_by_servings = $laneSwitch
  }
  switches = $switchRows.ToArray()
  recipes = $recipeRows.ToArray()
  free_dinner_probe = $freeDiff
}
$outDir = Split-Path $OutFile -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
($report | ConvertTo-Json -Depth 8 -Compress) | Set-Content $OutFile -Encoding utf8

$md = New-Object System.Collections.Generic.List[string]
$md.Add('# Measured: cheapest-store selection, old rule vs min-cost rule')
$md.Add('')
$md.Add(('Generated ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + ' by `grocery\measure-cheapest-selection.ps1`. Read-only.'))
$md.Add(('Feed: `' + $FeedPath + '`, week of ' + $feed.week_of + ', schema ' + $schema + '. Cards: ' + $cards.Count + '.'))
$md.Add('')
$md.Add('## Cheapest lane, at each recipe base servings')
$md.Add('')
$md.Add('| measure | value |')
$md.Add('|---|---|')
$md.Add(('| recipes with both totals | ' + $withBoth.Count + ' of ' + $recipeRows.Count + ' |'))
$md.Add(('| ingredient lines that switch store | ' + $switchedLines + ' |'))
$md.Add(('| recipes with at least one switch | ' + $switchedRecipes + ' |'))
$md.Add(('| recipe totals that fall | ' + $fell.Count + ' |'))
$md.Add(('| recipe totals that rise | ' + $rose.Count + ' (must be 0) |'))
$md.Add(('| median delta | $' + [math]::Round($medianDelta,2) + ' |'))
$md.Add(('| largest single-recipe drop | $' + [math]::Round($maxDrop,2) + ' |'))
$md.Add(('| lines switching at 7 / 28 servings | ' + $laneSwitch['7'] + ' / ' + $laneSwitch['28'] + ' |'))
$md.Add(('| switches won by a per-unit-only cell | ' + $fallbackWins + ' |'))
$md.Add('')
if ($namedExample) {
  $md.Add(('Named example `bangers-and-mash-onion-gravy`: $' + $namedExample.old_total + ' -> $' + $namedExample.new_total + ', ' + $namedExample.lines_switched + ' line(s) switched.'))
  $md.Add('')
}
$md.Add('## Biggest movers')
$md.Add('')
$md.Add('| recipe | ingredient | old | new | delta |')
$md.Add('|---|---|---|---|---|')
foreach ($s in (@($switchRows.ToArray() | Sort-Object delta | Select-Object -First 25))) {
  $md.Add(('| ' + $s.slug + ' | ' + $s.item + ' | ' + $s.old_store + ' $' + $s.old_cost + ' | ' + $s.new_store + ' $' + $s.new_cost + ' | $' + $s.delta + ' |'))
}
$md.Add('')
if ($freeDiff) {
  $md.Add('## Phase 2 probe: the free-dinner rotation')
  $md.Add('')
  $md.Add('Variant A (keep compute-v2 recipe package basis, pick the min-cost store) is algebraically a no-op:')
  $md.Add('with k and pkg_g/gpu fixed across stores, minimising cost is minimising per-unit. Only variant B')
  $md.Add('(move to the store package basis, matching the card) changes anything.')
  $md.Add('')
  if ($freeDiff.changed.Count -eq 0) { $md.Add('Variant B does NOT change the free set.') }
  else {
    $md.Add('Variant B CHANGES which recipes are free:')
    $md.Add('')
    $md.Add('| protein | loses free | gains free |')
    $md.Add('|---|---|---|')
    foreach ($c in $freeDiff.changed) { $md.Add(('| ' + $c.protein + ' | ' + (@($c.loses_free) -join ', ') + ' | ' + (@($c.gains_free) -join ', ') + ' |')) }
  }
  $md.Add('')
}
$sumDir = Split-Path $SummaryFile -Parent
if (-not (Test-Path $sumDir)) { New-Item -ItemType Directory -Force -Path $sumDir | Out-Null }
Set-Content $SummaryFile -Value ($md.ToArray() -join "`r`n") -Encoding utf8

Write-Output ''
Write-Output ("report -> {0}" -f $OutFile)
Write-Output ("summary -> {0}" -f $SummaryFile)
if ($rose.Count -gt 0) { exit 1 }
exit 0
