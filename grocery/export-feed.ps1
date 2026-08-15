<#
  export-feed.ps1 - Builds smp-feed.json, the single public price feed the website fetches at view time.

  This is the "database" the pages read from: instead of baking prices into 113 published posts, every
  page/widget fetches this one file and shows THIS WEEK's numbers, falling back to its own baked-in
  baseline if the fetch ever fails. When a sale moves a price, this file updates and every page is current
  on its next load - no republishing.

  Sources (all already produced by the daily pipeline; no new price logic here):
    - out\recipe-costs.json      (recipe week-costs, from top5-weekly.ps1)
    - out\recipe-board.json      (recipe-ingredient board, sale-overlaid)
    - out\comparison-*.json      (weekly staples board)
    - ..\meal-prep\recipes-db.json (base servings)

  Output: out\smp-feed.json  (committed by the workflow; served publicly via Cloudflare Pages).
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$out  = Join-Path $root 'out'
$mp   = Join-Path (Split-Path $root -Parent) 'meal-prep'

# ---- ingredients: cheapest verified price per board commodity id (both boards) ----
# durable product links: id -> store -> url (so the feed can point at the exact cheapest item)
$purl = @{}
try {
  $pd = (Get-Content (Join-Path $root 'product-urls.json') -Raw | ConvertFrom-Json).items
  foreach ($p in $pd.PSObject.Properties) {
    $m = @{}
    foreach ($sp in $p.Value.PSObject.Properties) { if ($sp.Name -ne 'commodity' -and $sp.Value -and $sp.Value.url) { $m[[string]$sp.Name] = [string]$sp.Value.url } }
    $purl[[string]$p.Name] = $m
  }
} catch {}
# sale windows: id|store -> sale_end, so the feed can carry "sale ends <date>" for the cheapest chip.
# sale-windows.json is gitignored + regenerated daily on both local and cloud (check-ad-cycles runs
# build-sale-windows BEFORE export-feed) - if it is missing we just emit no sale_end fields.
$saleEnd = @{}
try {
  $sw = Get-Content (Join-Path $root 'sale-windows.json') -Raw | ConvertFrom-Json
  $todayS = (Get-Date).ToString('yyyy-MM-dd')
  foreach ($w in $sw.windows) {
    if (-not $w.sale_end) { continue }
    if ([string]$w.sale_end -lt $todayS) { continue }   # expired window: no badge
    $saleEnd[([string]$w.id + '|' + [string]$w.store)] = [string]$w.sale_end
  }
} catch {}

# board-price overrides (same file the page build + audit use): pin an EVERYDAY cell to the verified per-unit
# of the product its link opens, so the PUBLIC feed (CF Worker -> 113 recipe widgets) never serves a stale
# board price either. Sales are never overridden.
$ovr = @{}
$ovrFile = Join-Path $root 'board-price-overrides.json'
if (Test-Path $ovrFile) { try { foreach ($c in (Get-Content $ovrFile -Raw | ConvertFrom-Json).cells) { $k=[string]$c.id; if (-not $ovr.ContainsKey($k)) { $ovr[$k]=@{} }; $ovr[$k][[string]$c.store]=[double]$c.per_unit } } catch {} }

$ing = [ordered]@{}

# ---- pricing_inputs: the WHOLE-PACKAGE basis the recipe cards price against ----
# WHY THIS EXISTS (2026-08-15). The 544 recipe cards used to fetch this from the V3 platform's
# /api/v2/recipe-feed/<slug>. That platform was deleted on 2026-08-14; the endpoint still answers from a
# STORED release, so it returns 200 for anything that existed when the last release was minted and 404 for
# everything newer, and its prices are frozen at whatever that release captured (butter served $3.99 against
# a real $2.555). Nothing in this repo produces it and nobody here can regenerate it. The cards now read the
# feed we DO own, and this block is the one thing that feed was missing.
#
# A per-unit price cannot answer the card's question. The card prices whole packages, because you cannot buy
# 7.5 tbsp of vinegar, so it needs three more facts per commodity: how big the package is, what the package
# costs, and whether the item is sold loose by weight instead of in a package at all. All three are already
# in the board rows this pipeline produces:
#   basis "size 4 lb"     -> packageBasisUnits 4, ALREADY IN THE ROW'S OWN UNIT (measured 2026-08-15: on
#                            every one of the 2,428 weekly cells where ad and basis are both present, the
#                            two reproduce the row's per_unit within 2%. Zero disagreements.)
#   basis "per-lb marker" -> variableWeight: a meat-counter price, so the card charges the exact amount used
#                            instead of rounding up to a package that does not exist
#   ad    "$10.22"        -> purchasePriceMinor 1022
# A cell with none of that carries perUnitMicros only. The card then falls back to the recipe's OWN authored
# package size (pkg_g/gpu, which every spec already has) rather than this script inventing a package size -
# a guessed package size is a wrong PRICE, which is worse than an honest per-unit one.
$pin = [ordered]@{}
$pinDiverged = 0        # cells where the shelf tag did not divide into its own per-unit price
$pinNoBasis  = 0        # cells shipped per-unit-only, for the card's authored-package fallback

# Size-string units, normalised. Only what the boards actually emit; an unrecognised token is refused, not guessed.
$UNIT_ALIAS = @{
  'oz'='oz'; 'ounce'='oz'; 'ounces'='oz'
  'lb'='lb'; 'lbs'='lb'; 'pound'='lb'; 'pounds'='lb'
  'floz'='floz'; 'fl oz'='floz'; 'fluid ounce'='floz'; 'fluid ounces'='floz'
  'ct'='each'; 'count'='each'; 'ea'='each'; 'each'='each'; 'pk'='each'; 'pack'='each'
  'g'='g'; 'gram'='g'; 'grams'='g'; 'kg'='kg'
  'gal'='gal'; 'gallon'='gal'; 'qt'='qt'; 'quart'='qt'; 'pt'='pt'; 'pint'='pt'
  'l'='l'; 'liter'='l'; 'litre'='l'; 'ml'='ml'
}
function ConvertTo-RowUnit([double]$mag, [string]$from, [string]$to) {
  if ($from -eq $to) { return $mag }
  switch ("$from>$to") {
    'oz>lb'    { return $mag / 16 }
    'lb>oz'    { return $mag * 16 }
    'g>lb'     { return $mag / 453.59237 }
    'g>oz'     { return $mag / 28.349523 }
    'kg>lb'    { return $mag * 2.2046226 }
    'kg>oz'    { return $mag * 35.273962 }
    'gal>floz' { return $mag * 128 }
    'qt>floz'  { return $mag * 32 }
    'pt>floz'  { return $mag * 16 }
    'l>floz'   { return $mag * 33.814023 }
    'ml>floz'  { return $mag / 29.573530 }
    # THE BOARD'S OWN CONVENTION, MIRRORED - not a new one. On a row already established as a liquid (unit
    # floz), a package labelled "32 oz" is 32 fluid ounces, which is exactly what the board's own `basis`
    # field emits for those cells ("size 32 floz" from size "32 oz"). Allowed in this one direction only:
    # any other weight/volume crossing is refused below, because guessing one is a wrong price.
    'oz>floz'  { return $mag }
    default    { return 0 }
  }
}
function Get-PkgBasis($s, [string]$rowUnit) {
  $b = [string]$s.basis
  if ($b -match 'per-lb marker') { return @{ variable = $true;  basis = 0.0 } }
  if ($b -match 'size\s+([\d.]+)') { return @{ variable = $false; basis = [double]$Matches[1] } }   # already in the row's unit
  $sz = [string]$s.size
  if ($sz -match '^\s*([\d.]+)\s*([a-zA-Z][a-zA-Z.\s]*?)\s*$') {
    $mag = [double]$Matches[1]
    $u = ($Matches[2] -replace '\.','' -replace '\s+',' ').Trim().ToLower()
    if ($UNIT_ALIAS.ContainsKey($u)) {
      $v = ConvertTo-RowUnit $mag $UNIT_ALIAS[$u] $rowUnit
      if ($v -gt 0) { return @{ variable = $false; basis = [double]$v } }
    }
  }
  return @{ variable = $false; basis = 0.0 }
}
# $Full=$false emits the lean per-store shape. THE CARD READS FOUR FIELDS off a `stores` entry
# (perUnitMicros, packageBasisUnits, purchasePriceMinor, variableWeight) and takes the store NAME from the
# key and the unit from the ingredients row, so store/unit/url on those entries are pure duplication - and
# there are ~3,200 of them. Carrying them cost 428 KB on a file every recipe page fetches. `current` and
# `everyday` keep the full shape because the card does read store, unit and url off those two.
function New-PricingEntry($s, [double]$perUnit, [string]$rowUnit, [string]$id, [bool]$Full) {
  $pk = Get-PkgBasis $s $rowUnit
  $e = [ordered]@{}
  if ($Full) { $e['store'] = [string]$s.store; $e['unit'] = $rowUnit }
  $e['perUnitMicros']  = [int][math]::Round($perUnit * 1000000)
  $e['variableWeight'] = [bool]$pk.variable
  if ([double]$pk.basis -gt 0) {
    $e['packageBasisUnits'] = [math]::Round([double]$pk.basis, 6)
    $adMinor = 0
    if (([string]$s.ad) -match '^\s*\$\s*([\d,]+(?:\.\d+)?)\s*$') { $adMinor = [int][math]::Round(([double](($Matches[1]) -replace ',','')) * 100) }
    $derived = [int][math]::Round($perUnit * [double]$pk.basis * 100)
    # SHIP THE SHELF TAG WHEN IT DIVIDES INTO ITS OWN PER-UNIT PRICE, the derived figure when it does not.
    # The card prints both on one receipt line ("$10.22" and "$2.56/lb"), so a pair that does not divide is
    # the arithmetic-fingerprint defect printed straight at the reader.
    if ($adMinor -gt 0 -and $derived -gt 0 -and ([math]::Abs($adMinor - $derived) / [double]$derived) -le 0.02) { $e['purchasePriceMinor'] = $adMinor }
    else { $e['purchasePriceMinor'] = $derived; if ($adMinor -gt 0) { $script:pinDiverged++ } }
  } else { $script:pinNoBasis++ }
  if ($Full -and $purl.ContainsKey($id) -and $purl[$id].ContainsKey([string]$s.store)) { $e['url'] = $purl[$id][[string]$s.store] }
  return $e
}

function AddBoard($rows) {
  foreach ($r in $rows) {
    $id = [string]$r.id
    # weekly board wins ties for a shared id (it carries this week's ad price); don't overwrite it with recipe floor
    if ($ing.Contains($id)) { continue }
    $rowUnit = [string]$r.unit
    $lo = $null; $los = ''; $lot = ''; $nStores = 0; $loCell = $null
    $evLo = $null; $evStore = ''; $evCell = $null
    $st = [ordered]@{}         # per-store per-unit prices (same unit as the row) - the Meal Plan Builder's store split needs these
    $pinSt = [ordered]@{}      # per-store WHOLE-PACKAGE inputs, same cells, same override, same loop
    foreach ($s in $r.stores) {
      $p = [double]$s.per_unit
      if (([string]$s.type) -eq 'everyday' -and $ovr.ContainsKey($id) -and $ovr[$id].ContainsKey([string]$s.store)) { $ov=[double]$ovr[$id][[string]$s.store]; if ($ov -gt 0) { $p = $ov } }
      if ($p -le 0) { continue }
      $nStores++; $st[[string]$s.store] = [math]::Round($p,4)
      # ONE LOOP, ONE WINNER. The cheapest chip and the card's `current` pricing basis are picked here
      # together on purpose: computed twice they can disagree, and a receipt whose store chip names a
      # different store from the price beside it is the board-match-collision class, on a recipe page.
      $pinSt[[string]$s.store] = (New-PricingEntry $s $p $rowUnit $id $false)
      if ($null -eq $lo -or $p -lt $lo) { $lo = $p; $los = [string]$s.store; $lot = [string]$s.type; $loCell = $s }
      if ((([string]$s.type) -eq 'everyday') -and ($null -eq $evLo -or $p -lt $evLo)) { $evLo = $p; $evStore = [string]$s.store; $evCell = $s }
    }
    if ($null -eq $lo) { continue }
    $u = if ($purl.ContainsKey($id) -and $purl[$id].ContainsKey($los)) { $purl[$id][$los] } else { '' }
    # n = how many of the 6 stores actually have a price for this ingredient - so the UI never overclaims
    # "checked at 6 stores" for an item only 1-2 stores have been priced at yet (new adds, or an item some
    # stores simply don't carry).
    $row = [ordered]@{ unit=$rowUnit; cheapest=[math]::Round($lo,4); store=$los; type=$lot; url=$u; n=$nStores; stores=$st }
    # attach the sale's end date when the winning chip IS the sale and its window is known
    if ($lot -eq 'sale') { $sk = $id + '|' + $los; if ($saleEnd.ContainsKey($sk)) { $row['sale_end'] = $saleEnd[$sk] } }
    $ing[$id] = $row
    # `everyday` is the cheapest NON-SALE cell, which is what the card's "everyday" tab means and what its
    # savings delta subtracts from. With no everyday cell at all the two tabs collapse to the same number,
    # which the card already detects and refuses to print twice under two labels.
    # The per-unit-only counter is charged once per CELL, on the lean pass above; the two full entries below
    # re-describe cells already counted, so they must not be counted again.
    $seenNoBasis = $pinNoBasis; $seenDiv = $pinDiverged
    $pinEntry = [ordered]@{ current = (New-PricingEntry $loCell $lo $rowUnit $id $true) }
    # OMIT `everyday` WHEN IT IS THE SAME CELL AS `current`, which it is for most commodities most weeks
    # (nothing is on sale, so the cheapest price IS the everyday price). The card reads
    # `inputs.everyday||inputs.current`, so the absent case is the identical case, said once instead of
    # twice. Worth 180 KB on a file every recipe page fetches.
    if ($evCell -and $evStore -ne $los) { $pinEntry['everyday'] = (New-PricingEntry $evCell $evLo $rowUnit $id $true) }
    $pinEntry['stores'] = $pinSt
    $pin[$id] = $pinEntry
    $pinNoBasis = $seenNoBasis; $pinDiverged = $seenDiv
  }
}
$cmpF = Get-ChildItem (Join-Path $out 'comparison-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$weekOf = ''
if ($cmpF) { $cdoc = Get-Content $cmpF.FullName -Raw | ConvertFrom-Json; $weekOf = [string]$cdoc.week_of; AddBoard $cdoc.comparison }   # weekly first (wins ties)
$rbF = Join-Path $out 'recipe-board.json'
if (Test-Path $rbF) { AddBoard (Get-Content $rbF -Raw | ConvertFrom-Json).comparison }

# ---- recipe-namespace aliases: a de-duped commodity must still RESOLVE, even though its row is gone ----
# THE PAGE DE-DUPS, THE FEED MUST NOT (2026-08-09). recipe-overlay drops a recipe row whose commodity also
# lives on the weekly board (f8c997f4, via recipe-floor-id-map.json) - correct for the page, which was
# publishing two prices for one product. But this file is not a page, it is the priceable NAMESPACE, and
# db\ingredients.json bids, the spec scaler bids and the widget keys are all written in the RECIPE spelling
# ('93-7-ground-beef', not 'ground-beef-93-7'). When the rows went, the keys went with them: the first
# pipeline run after the de-dup could not price 297 ingredient lines across 239 recipes, took the bid FK
# down with them and left the db rebuild refused by its own constraint. The commodity did not go anywhere -
# it is on the weekly board under its other spelling at a FRESHER price, which is exactly why the recipe row
# lost the tie. So re-point the key instead of dropping it.
# UNIT IDENTITY IS THE GATE, NOT A CONVERSION. grams_per_unit downstream is expressed in the served row's
# unit; a row served per lb under a key whose consumers convert grams with an 'each' factor is a wrong
# PRICE, which is worse than the missing one. Pairs that do not share a unit are reported and stay
# unresolved until their db\ingredients.json row is re-anchored (unit AND gpu together).
$aliased = 0
$aliasSkipped = New-Object System.Collections.Generic.List[string]
$idMapFile = Join-Path $root 'recipe-floor-id-map.json'
if (Test-Path $idMapFile) {
  # the recipe row's OWN unit, read from the everyday baseline - it predates the drop, so it survives it
  $baseUnit = @{}
  $rbeF = Join-Path $out 'recipe-board-everyday.json'
  if (Test-Path $rbeF) { try { foreach ($r in (Get-Content $rbeF -Raw | ConvertFrom-Json).comparison) { $baseUnit[[string]$r.id] = [string]$r.unit } } catch {} }
  try {
    foreach ($p in ((Get-Content $idMapFile -Raw | ConvertFrom-Json).map.PSObject.Properties)) {
      $rid = [string]$p.Name; $wid = [string]$p.Value
      if ($ing.Contains($rid)) { continue }                                                    # recipe row survived
      if (-not $ing.Contains($wid)) { $aliasSkipped.Add("$rid -> $wid (twin not priced either)"); continue }
      $ru = if ($baseUnit.ContainsKey($rid)) { $baseUnit[$rid] } else { '' }
      $wu = [string]$ing[$wid].unit
      if ($ru -and $ru -ne $wu) { $aliasSkipped.Add("$rid -> $wid (unit $ru vs $wu)"); continue }
      $clone = [ordered]@{}
      foreach ($f in @($ing[$wid].Keys)) { $clone[$f] = $ing[$wid][$f] }
      $clone['alias_of'] = $wid
      $ing[$rid] = $clone
      # THE ALIAS HAS TO CARRY THE PACKAGE BASIS TOO. Aliasing only the per-unit row would leave the recipe
      # spelling priceable by every surface except the recipe cards, which is the one surface this map was
      # written for. Same unit gate above already applies: it is what makes this clone safe.
      if ($pin.Contains($wid)) { $pin[$rid] = $pin[$wid] }
      $aliased++
    }
  } catch { Write-Output 'export-feed: WARNING - recipe-floor-id-map.json unreadable; recipe-spelling bids will NOT resolve' }
} else {
  Write-Output 'export-feed: WARNING - no recipe-floor-id-map.json, so a de-duped commodity leaves its recipe-spelling bid unpriceable'
}
Write-Output ("export-feed: {0} recipe-spelling key(s) re-pointed at their weekly twin{1}" -f $aliased, $(if ($aliasSkipped.Count) { "; " + $aliasSkipped.Count + " NOT aliased: " + ($aliasSkipped -join '; ') } else { '' }))

# ---- recipes: this week's cost per slug (+ base servings for the scaler) ----
$servings = @{}
try { foreach ($r in (Get-Content (Join-Path $mp 'recipes-db.json') -Raw | ConvertFrom-Json).recipes) { $servings[[string]$r.slug] = [int]$r.servings } } catch {}
$rec = [ordered]@{}
$rcF = Join-Path $out 'recipe-costs.json'
if (Test-Path $rcF) {
  foreach ($c in (Get-Content $rcF -Raw | ConvertFrom-Json).recipes) {
    $slug = [string]$c.slug
    $rec[$slug] = [ordered]@{
      name        = [string]$c.name
      servings    = if ($servings.ContainsKey($slug)) { $servings[$slug] } else { 14 }
      week_cost   = [double]$c.week_cost
      per_serving = [double]$c.per_serving
      calories    = [int]$c.calories
      sale_items  = @($c.sale_items)
    }
  }
}

# board_item_count: distinct commodities on the WEEKLY board (the "N items at seven stores" claim on
# the homepage). Served in the feed so the tc-ic site markers stay current without any page edits.
$boardItemCount = 0
try {
  $cmpF = Get-ChildItem (Join-Path $PSScriptRoot 'out\comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if($cmpF){ $boardItemCount = @(((Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison)).Count }
} catch {}
$feed = [ordered]@{
  generated   = (Get-Date).ToString('s')
  week_of     = $weekOf
  ingredient_count = $ing.Count
  recipe_count     = $rec.Count
  board_item_count = $boardItemCount
  ingredients = $ing
  pricing_inputs = $pin
  recipes     = $rec
}
Write-Output ("export-feed: pricing_inputs for {0} commodities ({1} cell(s) per-unit-only -> card uses its authored package size; {2} cell(s) where the shelf tag did not divide into its per-unit price -> derived)" -f $pin.Count, $pinNoBasis, $pinDiverged)
# Write to the repo-root public\ dir - this is the ONLY folder Cloudflare Pages serves, so nothing else
# in the repo is exposed. _headers there sets CORS + cache. Keep a copy in out\ for local inspection.
# -Compress (2026-07-26 scale hardening): the feed is fetched client-side by EVERY recipe card widget.
# Pretty-printing bloated it ~4x (973 KB raw for ~236 KB of data); at 1500 recipes that is a ~2.3 MB
# raw file JSON.parse'd on every mobile page view. Compact keeps the wire small (worker still gzips) and
# the on-device parse cheap. No consumer depends on whitespace.
$json = $feed | ConvertTo-Json -Depth 8 -Compress
$json | Set-Content (Join-Path $out 'smp-feed.json') -Encoding UTF8
$pub = Join-Path (Split-Path $root -Parent) 'public'
if (-not (Test-Path $pub)) { New-Item -ItemType Directory -Force -Path $pub | Out-Null }
# BOM-LESS (L7, 2026-08-01). Set-Content -Encoding UTF8 emits a UTF-8 BOM in PS 5.1. Browsers strip it
# per spec so the live page was never broken - but PS 5.1's OWN ConvertFrom-Json chokes on it, which is
# how a verification pass reported this feed "malformed" when it was fine. Our own tooling has to be able
# to read what we publish.
[IO.File]::WriteAllText((Join-Path $pub 'smp-feed.json'), $json, (New-Object Text.UTF8Encoding($false)))
Write-Output ("smp-feed.json: " + $ing.Count + " ingredients, " + $rec.Count + " recipes, week " + $weekOf + " -> out\ + public\")
