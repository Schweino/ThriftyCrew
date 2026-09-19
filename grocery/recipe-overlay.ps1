<#
  recipe-overlay.ps1 - Overlay this week's weekly-ad SALES onto the everyday recipe-ingredient baseline.

  WHY: the 60 recipe ingredients carry EVERYDAY (non-sale) floor prices in recipe-board-everyday.json
  (refreshed monthly). But many (meat, dairy, produce, some pantry) DO go on sale. This reads today's
  already-pulled store ad feed, finds any recipe ingredient ON SALE at any store (via the recipe rule-set
  recipe-commodities.json), overlays those store prices (marks type=sale so the page shows a "Sale thru"
  badge), RE-RANKS each commodity cheapest-first, and writes the LIVE recipe-board.json the page reads.

  Auto-reverts: when a sale ends, the next run finds no sale for it and uses the everyday floor -> back to
  the baseline ranking. Run it in the daily job after compare-deals; it is headless + non-fatal.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$out  = Join-Path $root 'out'
$today = (Get-Date).ToString('yyyy-MM-dd')

$baseFile = Join-Path $out 'recipe-board-everyday.json'
$rulesFile = Join-Path $root 'recipe-commodities.json'
if (-not (Test-Path $baseFile))  { Write-Output 'recipe-overlay: no everyday baseline (recipe-board-everyday.json) - nothing to do'; exit 0 }
if (-not (Test-Path $rulesFile)) { Write-Output 'recipe-overlay: no recipe-commodities.json rules yet - leaving board as-is'; exit 0 }

# 1. run the comparison engine against the RECIPE rule-set + today's ad feed (own output name; no collision)
$bakers = Get-ChildItem (Join-Path $out 'bakers\bakers-deals-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
$sams   = Get-ChildItem (Join-Path $out 'sams\sams-deals-*.json')     -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
# -IdentityNamespace recipe: the RECIPE half of the product identity table. graph\schema.md keeps the two
# commodity namespaces separate on purpose - staple `ground-turkey` and recipe `93-7-ground-turkey` are
# different purchases - so one SKU legitimately carries one assignment per namespace and they differ. This
# run writes graph\identity\recipe\; the staple run (check-ad-cycles) writes graph\identity\staple\. A table
# keyed on the product alone would have had these two runs overwrite each other every morning (section 10.1).
$args = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'compare-deals.ps1'),'-CommoditiesFile',$rulesFile,'-OutName','recipe-sales','-MinStores','1','-IdentityNamespace','recipe')
if ($bakers) { $args += @('-BakersFile', $bakers.FullName) }
if ($sams)   { $args += @('-SamsFile',   $sams.FullName) }
& powershell @args | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output ("recipe-overlay: compare-deals(recipe) failed rc=$LASTEXITCODE - leaving board as-is"); exit 0 }

# 2. sale lookup: id -> store -> {per_unit, item, size} for recipe items found ON SALE this week
$salesFile = Get-ChildItem (Join-Path $out 'recipe-sales-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^recipe-sales-\d{4}-\d{2}-\d{2}\.json$' } | Sort-Object Name -Descending | Select-Object -First 1
$sales = @{}
if ($salesFile) {
  $sc = (Read-JsonFile $salesFile.FullName).comparison
  foreach ($it in $sc) {
    $id = [string]$it.id
    foreach ($s in $it.stores) {
      # only treat as a sale if the engine tagged it 'sale' (ad-sourced), not an everyday match
      if ([string]$s.type -eq 'sale') {
        if (-not $sales.ContainsKey($id)) { $sales[$id] = @{} }
        $sales[$id][[string]$s.store] = [pscustomobject]@{ per_unit=[double]$s.per_unit; item=[string]$s.item; size=[string]$s.size }
      }
    }
  }
}

# 3. overlay sales onto the everyday baseline, re-rank, write the live board
$base = Read-JsonFile $baseFile

# THE STAPLES ROW OWNS ITS ID (2026-07-30). Any recipe row whose id also exists on the weekly staples board is
# DROPPED here, dynamically, before the overlay. The recipe baseline is a frozen monthly snapshot (2026-07-12
# vintage), and 78 of its 158 ids also lived on the fresh weekly board - so one page showed TWO prices for the
# same product: Family Fare ground coriander $3.21/oz in the recipe section against $1.05/oz in the staples
# section, 124 same-store same-unit cells disagreeing by >=10%, and the recipe half had NO Fareway anywhere,
# so its "cheapest" verdicts were decided over six stores instead of seven. The page already keys recipe rows
# separately ('<id>::r'), so removal is purely a data change: the fresh staple row simply becomes the only
# place that id appears. Recipe-ONLY ids (80 today) stay - stale-but-disclosed beats absent, and their history
# banking is unaffected (update-history already skips ids the weekly board covered).
# Dynamic on purpose: a commodity promoted onto the staples board in a future batch auto-resolves instead of
# waiting for someone to remember this file.
$stapleIds = @{}
$newestCmp = Get-ChildItem (Join-Path $out 'comparison-*.json') -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^comparison-\d{4}-\d{2}-\d{2}\.json$' } | Sort-Object Name -Descending | Select-Object -First 1
if ($newestCmp) {
  try { foreach ($sr in @((Read-JsonFile $newestCmp.FullName).comparison)) { $stapleIds[[string]$sr.id] = $true } } catch {}
}
# THE STAPLE COMMODITY OWNS ITS ID, NOT ONLY THE STAPLE ROW (2026-09-19). The filter above read the ids the
# weekly board PUBLISHED today, so a staple with no publishable cell - every cell withheld by the provenance
# contract as stale, ship-only or self-sourced - left the set, and this file then served that commodity from
# the frozen 2026-07-06 recipe snapshot instead: the exact prices the contract had just refused, back on the
# page one step later, with no date on any of the 894 cells to say so. Measured on the gated rebuild that day:
# audit-known-wrong hard-failed on 6 staples resurrected this way. The weekly rule-set names every staple
# commodity whether or not it priced today, so its ids join the set: a staple with no honest price shows no
# price, which is what the weekly board already decided.
$stapleRules = Join-Path $root 'commodities.json'
if (Test-Path $stapleRules) {
  # commodities.json is a BARE top-level array. `.commodities` on it member-enumerates to one $null per row -
  # 592 of them, a count that looks loaded and matches nothing - so read the array itself, assigned first.
  try {
    $stapleRuleRows = Read-JsonFile $stapleRules
    $stapleRuleN = 0
    foreach ($sc in @($stapleRuleRows)) { if ($sc.id) { $stapleIds[[string]$sc.id] = $true; $stapleRuleN++ } }
    if ($stapleRuleN -eq 0) { Write-Output 'recipe-overlay: WARNING - commodities.json yielded no staple ids; a staple with no cell today can be served from the recipe snapshot' }
  }
  catch { Write-Output ('recipe-overlay: WARNING - commodities.json unreadable (' + $_.Exception.Message + '); a staple with no cell today can be served from the recipe snapshot') }
}
# THE SAME COMMODITY UNDER TWO ID SPELLINGS IS STILL THE SAME COMMODITY (2026-08-08). The filter above
# compares RAW ids, and it works: exactly 0 recipe rows collide with the weekly board by literal id. But
# the recipe and weekly namespaces spell 33 shared commodities differently - 93-7-ground-beef against
# ground-beef-93-7, beef-chuck-roast against chuck-roast - and recipe-floor-id-map.json exists precisely
# because those pairs ARE the same thing (each one passed an evidence gate: label match, unit
# reconciliation, multi-store price agreement). Comparing raw ids can never match them, so 33 of the 80
# recipe rows survived as stale duplicates of a fresher weekly row and the page published BOTH numbers.
# Measured on the 2026-08-08 board: 9 cells where an identical product string carried two live prices
# (beef chuck roast at Family Fare, $8.49 on the weekly board and $10.99 here; diced green chiles at
# Hy-Vee, 39% apart) plus 6 more that were the same price in a different unit. That is the exact symptom
# the 2026-07-30 filter was written to kill - it just could not see through the id spelling.
$idMap = @{}
$mapFile = Join-Path $root 'recipe-floor-id-map.json'
if (Test-Path $mapFile) {
  try {
    foreach ($p in ((Read-JsonFile $mapFile).map.PSObject.Properties)) { $idMap[[string]$p.Name] = [string]$p.Value }
  } catch { Write-Output 'recipe-overlay: WARNING - recipe-floor-id-map.json unreadable; falling back to raw-id matching only' }
} else {
  Write-Output 'recipe-overlay: WARNING - no recipe-floor-id-map.json, so shared commodities spelled differently on the two boards will NOT be de-duplicated'
}
if ($stapleIds.Count -gt 0) {
  $beforeN = @($base.comparison).Count
  # Counted BEFORE the filter, deliberately. A `$byMap++` inside the Where-Object block would depend on
  # whether that block shares the caller's scope, and this estate has lost enough hours to PowerShell
  # scoping surprises that a count worth printing should not rest on one.
  $byMap = @($base.comparison | Where-Object {
    $rid = [string]$_.id
    (-not $stapleIds.ContainsKey($rid)) -and $idMap.ContainsKey($rid) -and $stapleIds.ContainsKey($idMap[$rid])
  }).Count
  $base.comparison = @($base.comparison | Where-Object {
    $rid = [string]$_.id
    if ($stapleIds.ContainsKey($rid)) { return $false }              # same id on the weekly board
    if ($idMap.ContainsKey($rid) -and $stapleIds.ContainsKey($idMap[$rid])) { return $false }  # same COMMODITY, other spelling
    $true
  })
  $droppedN = $beforeN - @($base.comparison).Count
  Write-Output ("recipe-overlay: dropped $droppedN row(s) whose commodity lives on the weekly staples board ($byMap of them via recipe-floor-id-map, the rest by literal id; the fresh row owns the commodity); $(@($base.comparison).Count) recipe-only row(s) remain")
} else {
  Write-Output 'recipe-overlay: WARNING - no staples comparison found, so the overlap filter examined NOTHING and every recipe row is kept; duplicate-price rows are possible this run'
}
# 2c. PRICES COME FROM THE PRICING DATABASE, NOT THE SNAPSHOT (Brad, 2026-09-19). recipe-board-everyday.json is a
# week_of 2026-07-06 table whose 894 store cells carry no date; nothing refreshes it (derive-recipe-floors -Apply has
# no caller), and until today this file overlaid only SALES onto it, so every everyday recipe price on the page and
# in the recipe costs was the snapshot's. Step 1 above already priced every recipe-rule commodity from TODAY'S
# captures, through the same provenance contract as the weekly board. So, per row:
#   - the gated recipe build prices it   -> its row replaces the snapshot's, cells, dates and all ('recipe-build');
#   - it HAS a recipe rule but no gated cell today -> it is WITHHELD, no fallback: the contract refused every cell
#     or nothing was captured, and publishing the July number instead is the defect this block exists to end;
#   - it has NO rule in either rule-set  -> the snapshot is still its only source. Each such cell is tagged
#     'snapshot-undated', counted into recipe_price_source, and check-ad-cycles pages on a count above zero. This is
#     a transition, not a tier: the set empties as each id gets a rule, and then the snapshot has no reader here.
$recipeRuleIds = @{}
try {
  $rcDoc = Read-JsonFile $rulesFile
  foreach ($rr in @($rcDoc.commodities)) { if ($rr.id) { $recipeRuleIds[[string]$rr.id] = $true } }
} catch { Write-Output ('recipe-overlay: WARNING - recipe-commodities.json unreadable (' + $_.Exception.Message + ')') }
$builtRows = @{}
if ($salesFile) {
  try { foreach ($br in @((Read-JsonFile $salesFile.FullName).comparison)) { if ($br.id) { $builtRows[[string]$br.id] = $br } } } catch {}
}
$srcBuild = New-Object System.Collections.Generic.List[string]
$srcWithheld = New-Object System.Collections.Generic.List[string]
$srcSnapshot = New-Object System.Collections.Generic.List[string]
$srcUnplaced = New-Object System.Collections.Generic.List[string]

# categories.json maps a display section to the commodity ids that belong in it. It is the same file
# build-deals-page renders from, so a category resolved here is one that file can place by construction.
$script:CategoryById = @{}
try {
  $catDoc = Read-JsonFile (Join-Path $root 'categories.json')
  foreach ($sec in @($catDoc.categories)) {
    foreach ($cid in @($sec.commodities)) { $script:CategoryById[[string]$cid] = [string]$sec.label }
  }
} catch { Write-Output ('recipe-overlay: WARNING - categories.json unreadable (' + $_.Exception.Message + '); build-only rows cannot be placed and will be reported unplaced') }

function Get-CategoryForId([string]$id) {
  if ($script:CategoryById.ContainsKey($id)) { return $script:CategoryById[$id] }
  # a recipe id often mirrors a staple one (idMap); borrow that twin's section rather than inventing one
  if ($idMap.ContainsKey($id) -and $script:CategoryById.ContainsKey([string]$idMap[$id])) { return $script:CategoryById[[string]$idMap[$id]] }
  return $null
}
$kept = New-Object System.Collections.Generic.List[object]
$seenIds = @{}
foreach ($row in @($base.comparison)) {
  $id = [string]$row.id
  $seenIds[$id] = $true
  if ($builtRows.ContainsKey($id)) {
    $nr = $builtRows[$id]
    if ($row.PSObject.Properties['category'] -and -not $nr.PSObject.Properties['category']) { $nr | Add-Member -NotePropertyName category -NotePropertyValue $row.category -Force }
    $nr | Add-Member -NotePropertyName price_source -NotePropertyValue 'recipe-build' -Force
    $kept.Add($nr); $srcBuild.Add($id)
  } elseif ($recipeRuleIds.ContainsKey($id)) {
    $srcWithheld.Add($id)
  } else {
    foreach ($s in @($row.stores)) { $s | Add-Member -NotePropertyName source -NotePropertyValue 'snapshot-undated' -Force }
    $row | Add-Member -NotePropertyName price_source -NotePropertyValue 'snapshot-undated' -Force
    $kept.Add($row); $srcSnapshot.Add($id)
  }
}
# A recipe-rule commodity the build priced but the snapshot never listed is still a recipe price; the weekly board
# owns any id it also rules, exactly as the filter above decides for snapshot rows.
foreach ($bid in @($builtRows.Keys)) {
  if ($seenIds.ContainsKey($bid) -or $stapleIds.ContainsKey($bid)) { continue }
  if ($idMap.ContainsKey($bid) -and $stapleIds.ContainsKey($idMap[$bid])) { continue }
  $nr = $builtRows[$bid]
  # EVERY ROW NEEDS A HOME, AND A ROW WITH NONE MUST NOT COST THE WHOLE BOARD (2026-09-19).
  # A row the snapshot never listed arrives here with no `category`: the merge above copies one from the OLD
  # row, and there is no old row. build-deals-page renders recipe rows INTO categories.json's sections and
  # THROWS on any row it cannot place, so one unplaceable row refused every publish - boneless-pork-chops did
  # exactly that on the 2026-09-19 rebuild, after guards had already passed. So resolve the category here,
  # from categories.json by id, and when that cannot answer, SKIP the row and NAME it rather than either
  # publishing it homeless (the throw) or dropping it silently (a real price disappearing with no line in the
  # log). The skipped ids ride in recipe_price_source so a caller can page on a count above zero.
  if (-not $nr.PSObject.Properties['category'] -or -not ([string]$nr.category).Trim()) {
    $cat = Get-CategoryForId $bid
    if ($cat) { $nr | Add-Member -NotePropertyName category -NotePropertyValue $cat -Force }
    else { $srcUnplaced.Add($bid); continue }
  }
  $nr | Add-Member -NotePropertyName price_source -NotePropertyValue 'recipe-build' -Force
  $kept.Add($nr); $srcBuild.Add($bid)
}
$base.comparison = $kept.ToArray()
$base | Add-Member -NotePropertyName recipe_price_source -NotePropertyValue ([ordered]@{
  recipe_build = $srcBuild.Count; withheld = $srcWithheld.ToArray(); snapshot_undated = $srcSnapshot.ToArray()
  unplaced = $srcUnplaced.ToArray()
  build_file = $(if ($salesFile) { $salesFile.Name } else { $null })
}) -Force
if ($srcUnplaced.Count) {
  Write-Output ("recipe-overlay: UNPLACED " + $srcUnplaced.Count + " build-only row(s) have no section in categories.json and were left OFF the board: " + (($srcUnplaced.ToArray()) -join ', ') + " - register each id under a category in categories.json to publish it")
}
Write-Output ("recipe-overlay: RECIPE-PRICE-SOURCE recipe_build=$($srcBuild.Count) withheld=$($srcWithheld.Count) snapshot_undated=$($srcSnapshot.Count)" + $(if ($srcSnapshot.Count) { ' - still priced from the undated snapshot: ' + (($srcSnapshot | Select-Object -First 12) -join ', ') } else { '' }))

$overlaid = 0
foreach ($row in $base.comparison) {
  $id = [string]$row.id
  # A row from the gated build already chose each store's cheapest cell, sale or everyday, with its own dates.
  if ([string]$row.price_source -eq 'recipe-build') { continue }
  foreach ($s in $row.stores) {
    $store = [string]$s.store
    if ($sales.ContainsKey($id) -and $sales[$id].ContainsKey($store)) {
      $sale = $sales[$id][$store]
      # only overlay when the sale is genuinely CHEAPER than the everyday floor (a sale should be lower;
      # a higher "sale" match is a bad parse -> ignore, keep everyday). Small tolerance for rounding.
      if ($sale.per_unit -gt 0 -and $sale.per_unit -le ([double]$s.per_unit * 1.02)) {
        $s.per_unit = [math]::Round($sale.per_unit, 4)
        if ($s.PSObject.Properties['type']) { $s.type = 'sale' } else { $s | Add-Member -NotePropertyName type -NotePropertyValue 'sale' -Force }
        if ($s.PSObject.Properties['item']) { $s.item = $sale.item } else { $s | Add-Member -NotePropertyName item -NotePropertyValue $sale.item -Force }
        if ($s.PSObject.Properties['size']) { $s.size = $sale.size } else { $s | Add-Member -NotePropertyName size -NotePropertyValue $sale.size -Force }
        $overlaid++
      }
    }
  }
  # re-rank cheapest-first + refresh ALL cheapest_* fields (not just the store - leaving cheapest_price at
  # the pre-sale floor made the written board internally inconsistent for any future consumer)
  $ranked = @($row.stores | Sort-Object per_unit)
  $row.stores = $ranked
  foreach ($pair in @(@('cheapest_store',[string]$ranked[0].store), @('cheapest_price',[double]$ranked[0].per_unit), @('cheapest_type',[string]$ranked[0].type))) {
    if ($row.PSObject.Properties[$pair[0]]) { $row.($pair[0]) = $pair[1] } else { $row | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force }
  }
}
if ($base.PSObject.Properties['built_at']) { $base.built_at = (Get-Date).ToString('s') } else { $base | Add-Member -NotePropertyName built_at -NotePropertyValue (Get-Date).ToString('s') -Force }
($base | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $out 'recipe-board.json') -Encoding UTF8
Write-Output ("recipe-overlay: overlaid " + $overlaid + " sale price(s) onto the recipe board (from " + $(if($salesFile){$salesFile.Name}else{'no sales file'}) + ")")
