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
$args = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'compare-deals.ps1'),'-CommoditiesFile',$rulesFile,'-OutName','recipe-sales','-MinStores','1')
if ($bakers) { $args += @('-BakersFile', $bakers.FullName) }
if ($sams)   { $args += @('-SamsFile',   $sams.FullName) }
& powershell @args | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output ("recipe-overlay: compare-deals(recipe) failed rc=$LASTEXITCODE - leaving board as-is"); exit 0 }

# 2. sale lookup: id -> store -> {per_unit, item, size} for recipe items found ON SALE this week
$salesFile = Get-ChildItem (Join-Path $out 'recipe-sales-*.json') -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^recipe-sales-\d{4}-\d{2}-\d{2}\.json$' } | Sort-Object Name -Descending | Select-Object -First 1
$sales = @{}
if ($salesFile) {
  $sc = (Get-Content $salesFile.FullName -Raw | ConvertFrom-Json).comparison
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
$base = Get-Content $baseFile -Raw | ConvertFrom-Json

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
  try { foreach ($sr in @((Get-Content $newestCmp.FullName -Raw | ConvertFrom-Json).comparison)) { $stapleIds[[string]$sr.id] = $true } } catch {}
}
if ($stapleIds.Count -gt 0) {
  $beforeN = @($base.comparison).Count
  $base.comparison = @($base.comparison | Where-Object { -not $stapleIds.ContainsKey([string]$_.id) })
  $droppedN = $beforeN - @($base.comparison).Count
  Write-Output ("recipe-overlay: dropped $droppedN row(s) whose id lives on the weekly staples board (the fresh row owns the id); $(@($base.comparison).Count) recipe-only row(s) remain")
} else {
  Write-Output 'recipe-overlay: WARNING - no staples comparison found, so the overlap filter examined NOTHING and every recipe row is kept; duplicate-price rows are possible this run'
}
$overlaid = 0
foreach ($row in $base.comparison) {
  $id = [string]$row.id
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
