# patch-scaler-gpu.ps1 - Retrofits UNIT-RECONCILED scaler gpu into the r100 spec files (specs\<slug>.json).
# Backport of r300\build-specs.ps1 port delta #3 (Resolve-ScalerGpu): r100's build-specs wrote the RAW map
# gpu into the scaler payload, but the widget computes cost = feed.cheapest * (grams / gpu), so gpu must be
# grams per the unit the LIVE price source quotes (smp-feed unit, board unit fallback). A map calibrated in
# oz against a per-lb feed row misprices the widget 16x (the 2026-07-19 brown-sugar lesson; the cost engine
# was fixed then, the live scaler payloads were not).
# Specs are patched IN PLACE (JSON round-trip proven byte-identical) because they carry merged prose that a
# build-specs re-run would destroy. Dry-run by default; -Apply writes.
# Outputs: scaler-fix-report.txt (every entry checked) + scaler-fix-slugs.txt (specs changed -> rebuild+republish).
param([switch]$Apply)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- merged item -> {bid,gpu,unit} with r100 build-specs precedence (r100-board-map wins, ingredient-map fills)
$bidMap=@{}
$mapNew = (Get-Content (Join-Path $here 'r100-board-map.json') -Raw | ConvertFrom-Json).map
foreach($p in $mapNew.PSObject.Properties){ $bidMap[$p.Name] = @{ bid=[string]$p.Value.bid; gpu=[double]$p.Value.gpu; unit=[string]$p.Value.unit } }
$mapOldM = (Get-Content (Join-Path $here '..\ingredient-map.json') -Raw | ConvertFrom-Json).mappings
foreach($m in $mapOldM){ if(-not $bidMap.ContainsKey($m.item)){ $bidMap[$m.item] = @{ bid=[string]$m.board_id; gpu=[double]$m.grams_per_unit; unit=[string]$m.unit } } }

# ---- units of the live price sources the widget reads (feed primary, board fallback)
$feedUnit=@{}
$feed = (Get-Content (Join-Path $here '..\..\grocery\out\smp-feed.json') -Raw | ConvertFrom-Json).ingredients
if($feed){ foreach($p in $feed.PSObject.Properties){ if($p.Value.unit){ $feedUnit[$p.Name]=[string]$p.Value.unit } } }
$boardUnit=@{}
$cmpFile = Get-ChildItem (Join-Path $here '..\..\grocery\out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
foreach($row in ((Get-Content $cmpFile.FullName -Raw | ConvertFrom-Json).comparison)){ $boardUnit[$row.id]=[string]$row.unit }
$rbFile = Join-Path $here '..\..\grocery\out\recipe-board.json'
if(Test-Path $rbFile){
  foreach($row in ((Get-Content $rbFile -Raw | ConvertFrom-Json).comparison)){ if(-not $boardUnit.ContainsKey($row.id)){ $boardUnit[$row.id]=[string]$row.unit } }
}
$UNIT_G=@{ lb=453.592; oz=28.3495; floz=29.57; kg=1000.0; g=1.0 }
function GpuStr([double]$v){ $v.ToString('0.000') }

$slugs = Get-Content (Join-Path $here 'specs-ready.txt') | Where-Object { $_ }
$report=@(); $flags=@(); $changedSlugs=@(); $itemFixCount=@{}
foreach($slug in $slugs){
  $sf = Join-Path $here ("specs\$slug.json")
  $spec = Get-Content $sf -Raw | ConvertFrom-Json
  $changed=$false
  foreach($ing in $spec.scaler.ing){
    if(-not ($ing.PSObject.Properties.Name -contains 'bid') -or -not $ing.bid){ continue }
    if(-not $bidMap.ContainsKey($ing.item)){ $flags += ("$slug :: $($ing.item) [$($ing.bid)] NOT IN MERGED MAP - left as is"); continue }
    $b = $bidMap[$ing.item]
    if($b.bid -ne [string]$ing.bid){ $flags += ("$slug :: $($ing.item) BID DRIFT spec=$($ing.bid) map=$($b.bid) - left as is, review"); continue }
    if([Math]::Abs([double]$ing.gpu - $b.gpu) -gt 0.001){
      # spec gpu no longer equals the raw map gpu -> its calibration unit is unknown; never guess
      $flags += ("$slug :: $($ing.item) [$($ing.bid)] GPU DRIFT spec=$($ing.gpu) map=$($b.gpu) - left as is, review"); continue
    }
    $rowUnit = $null
    if($feedUnit.ContainsKey($b.bid)){ $rowUnit=$feedUnit[$b.bid] } elseif($boardUnit.ContainsKey($b.bid)){ $rowUnit=$boardUnit[$b.bid] }
    if(-not $rowUnit -or -not $b.unit -or $rowUnit -eq $b.unit){ continue }
    if($UNIT_G.ContainsKey($b.unit) -and $UNIT_G.ContainsKey($rowUnit)){
      $newGpu = GpuStr ($b.gpu * ($UNIT_G[$rowUnit]/$UNIT_G[$b.unit]))
      if($newGpu -ne [string]$ing.gpu){
        $report += ("$slug :: $($ing.item) [$($ing.bid)] $($b.unit) -> $rowUnit : gpu $($ing.gpu) -> $newGpu")
        $itemFixCount[$ing.item + ' [' + $ing.bid + '] ' + $b.unit + '->' + $rowUnit]++
        $ing.gpu = $newGpu
        $changed=$true
      }
    } else {
      $flags += ("$slug :: $($ing.item) [$($ing.bid)] NON-STANDARD UNIT MISMATCH map=$($b.unit) live=$rowUnit - left as is, review")
    }
  }
  if($changed){
    $changedSlugs += $slug
    if($Apply){ $spec | ConvertTo-Json -Depth 8 | Out-File $sf -Encoding utf8 }
  }
}

$mode = if($Apply){'APPLIED'}else{'DRY RUN'}
Write-Output ("== scaler gpu unit reconciliation ($mode) ==")
Write-Output ("specs checked: $($slugs.Count); specs needing gpu fixes: $($changedSlugs.Count); entries fixed: $($report.Count)")
Write-Output ""
Write-Output "-- distinct item fixes --"
$itemFixCount.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Output ("  {0}  x{1}" -f $_.Key, $_.Value) }
if($flags.Count -gt 0){
  Write-Output ""
  Write-Output "-- FLAGS (not auto-fixed, review) --"
  $flags | ForEach-Object { Write-Output ("  " + $_) }
}
$report | Out-File (Join-Path $here 'scaler-fix-report.txt') -Encoding utf8
$changedSlugs | Out-File (Join-Path $here 'scaler-fix-slugs.txt') -Encoding utf8
Write-Output ""
Write-Output "detail -> scaler-fix-report.txt; changed slugs -> scaler-fix-slugs.txt"
