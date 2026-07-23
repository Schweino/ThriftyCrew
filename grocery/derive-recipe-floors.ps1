<#
  derive-recipe-floors.ps1 - refresh the recipe EVERYDAY floor prices FROM THE BOARD'S OWN DATA
  (2026-07-23, improvement item 7) instead of the monthly agent hand-browsing 158 items x 6 stores.

  Since R100 put every recipe ingredient on the 7-store staple board (#125), the weekly/daily pulls
  already capture everyday prices for these commodities. The comparison row hides a store's everyday
  floor whenever a SALE is winning that store, but candidates-<date>.json records EVERY matched row -
  and since 2026-07-23 each candidate carries price_type, so the floor per store is simply the
  cheapest EVERYDAY-typed candidate. One source of truth, no re-implemented matching (the two-copies
  trap), no monthly browser grind.

  Conservative by design:
    - DRY RUN by default: writes out\recipe-floors-proposed.json + out\recipe-floors-report.json and
      prints the summary. -Apply consumes the SAME derivation (no re-read drift) into
      recipe-board-everyday.json.
    - A store cell with no everyday candidate keeps its prior value (flagged, never guessed).
    - A row whose id has no board match is left whole (flagged 'no-board-match' - the monthly agent
      hand-checks ONLY these plus the big deltas, which is the entire remaining human workload).
    - Deltas >25% are applied but listed loudly for review - a floor moving that far in a month is
      either a real reprice or a wrong match, and a human should glance either way.
#>
param([switch]$Apply)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$outDir = Join-Path $root 'out'

$floorF = Join-Path $outDir 'recipe-board-everyday.json'
$doc = Get-Content $floorF -Raw | ConvertFrom-Json
$rows = @($doc.comparison)

# optional curated mapping recipe-floor-id -> board-commodity-id, for the ~80 rows whose recipe-era id
# differs from the board id ('93-7-ground-turkey' vs the board's naming). EVERY entry is a one-time
# HUMAN verification (same commodity, same form) that automates that row forever after - the monthly
# agent adds mappings as it hand-checks, shrinking its own future workload. Never guess a mapping:
# a wrong one is the board-collision class (a floor silently priced off a different product).
$idMapF = Join-Path $root 'recipe-floor-id-map.json'
$idMap = @{}
if (Test-Path $idMapF) {
  foreach ($p in ((Get-Content $idMapF -Raw | ConvertFrom-Json).map).PSObject.Properties) { $idMap[$p.Name] = [string]$p.Value }
}

$candF = Get-ChildItem (Join-Path $outDir 'candidates-*.json') | Where-Object { $_.BaseName -match '^candidates-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $candF) { throw 'no candidates-<date>.json found - run compare-deals first' }
$cand = Get-Content $candF.FullName -Raw | ConvertFrom-Json
$candById = @{}
foreach ($c in $cand.commodities) { $candById[$c.id] = $c }
$hasType = $false
foreach ($c in $cand.commodities) { foreach ($cc in @($c.candidates)) { if ($cc.PSObject.Properties['price_type']) { $hasType = $true; break } }; if ($hasType) { break } }
if (-not $hasType) { throw ("candidates file " + $candF.Name + " predates the price_type field - re-run compare-deals.ps1 once, then re-run this") }

# standard-unit conversion for the one legitimate cross-unit case (board tracks oz, recipe floor lb, etc.).
# NON-standard mismatches (each vs oz, ct vs lb) are REFUSED, never guessed - the brown-sugar 16x lesson:
# a unit_price silently reinterpreted in a different unit is a real number attached to a false basis.
$UNIT_G = @{ lb = 453.592; oz = 28.3495; floz = 29.57; kg = 1000.0; g = 1.0 }
$updated = 0; $kept = 0; $bigDeltas = @(); $noMatch = @(); $noEveryday = @(); $unitMismatch = @()
foreach ($row in $rows) {
  $lookupId = if ($idMap.ContainsKey($row.id)) { $idMap[$row.id] } else { $row.id }
  $c = $candById[$lookupId]
  if (-not $c) { $noMatch += $row.id; continue }
  # unit reconciliation BEFORE any price moves: candidates' unit_price is per the BOARD unit ($c.unit)
  $factor = $null
  if ([string]$row.unit -eq [string]$c.unit) { $factor = 1.0 }
  elseif ($UNIT_G.ContainsKey([string]$row.unit) -and $UNIT_G.ContainsKey([string]$c.unit)) {
    # board $/boardUnit -> $/rowUnit: multiply by grams-per-rowUnit / grams-per-boardUnit
    $factor = $UNIT_G[[string]$row.unit] / $UNIT_G[[string]$c.unit]
  }
  if ($null -eq $factor) { $unitMismatch += ($row.id + " (row '" + $row.unit + "' vs board '" + $c.unit + "')"); continue }
  foreach ($s in @($row.stores)) {
    $best = @($c.candidates) |
      Where-Object { $_.store -eq $s.store -and $_.price_type -eq 'everyday' -and $_.unit_price } |
      Sort-Object { [double]$_.unit_price } | Select-Object -First 1
    if (-not $best) { $noEveryday += ($row.id + '/' + $s.store); $kept++; continue }
    $new = [math]::Round(([double]$best.unit_price * $factor), 4)
    $old = [double]$s.per_unit
    if ($old -gt 0 -and [math]::Abs($new - $old) / $old -gt 0.25) {
      $bigDeltas += [pscustomobject]@{ id = $row.id; store = $s.store; old = $old; new = $new; item = [string]$best.name }
    }
    if ($new -ne $old) { $s.per_unit = $new; $updated++ } else { $kept++ }
  }
  # re-rank cheapest-first and refresh the verdict
  $sorted = @($row.stores | Sort-Object { [double]$_.per_unit })
  $row.stores = $sorted
  $row.cheapest_store = $sorted[0].store
}
if ($doc.PSObject.Properties['built_at']) { $doc.built_at = (Get-Date).ToString('s') } else { $doc | Add-Member -NotePropertyName built_at -NotePropertyValue (Get-Date).ToString('s') }

$report = [pscustomobject]@{
  derived_from = $candF.Name
  updated_cells = $updated
  unchanged_cells = $kept
  ids_with_no_board_match = @($noMatch)
  ids_with_unit_mismatch = @($unitMismatch)
  cells_with_no_everyday_candidate = @($noEveryday)
  deltas_over_25pct = @($bigDeltas)
}
$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $outDir 'recipe-floors-report.json') -Encoding UTF8
$doc | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outDir 'recipe-floors-proposed.json') -Encoding UTF8
if ($Apply) {
  Copy-Item (Join-Path $outDir 'recipe-floors-proposed.json') $floorF -Force
  Write-Output ("APPLIED to recipe-board-everyday.json - now run recipe-overlay.ps1 + publish-deals-page.ps1")
}
Write-Output ("derive-recipe-floors ({0}): {1} cells updated, {2} unchanged | no-board-match ids: {3} | unit-mismatch ids: {4} | no-everyday cells: {5} | >25% deltas: {6}  (details: out\recipe-floors-report.json)" -f `
  $candF.Name, $updated, $kept, @($noMatch).Count, @($unitMismatch).Count, @($noEveryday).Count, @($bigDeltas).Count)
if (@($unitMismatch).Count) { Write-Output ("  REFUSED (unit mismatch - map or convert, never guess): " + (@($unitMismatch) -join '; ')) }
if (@($noMatch).Count) { Write-Output ("  hand-check ids (add verified mappings to recipe-floor-id-map.json to automate them): " + (@($noMatch) -join ', ')) }
