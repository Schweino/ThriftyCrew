<#
  build-regression-baseline.ps1 - Rebuilds the golden baseline by RUNNING the engine on the hermetic frozen
  input set in regression-inputs\ and snapshotting the result. Re-run ONLY after a deliberate, verified
  engine change to intentionally re-baseline.

  This deliberately does NOT trust any pre-existing comparison file: the previous version snapshotted
  whatever -CompareFile was handed to it (once a Jul-6 live file) while labeling it frozen_week=2026-07-05 -
  a baseline built from different inputs than the test replays, which made the regression test meaningless.
  Building FROM the frozen inputs guarantees baseline and test always share the same input set.

  It reads the PINNED rules (regression-inputs\commodities.json + price-bands.json), exactly as
  regression-test.ps1 does, so baseline and test cannot disagree about the rules either.

  *** BEFORE YOU RE-BASELINE, EXPLAIN EVERY DIFF ***
  Re-baselining is how a real bug becomes the reference. On 2026-07-29 the guard was red with 66 diffs and
  the temptation was to just rebuild; the diffs turned out to be the price_mode in-store contract correctly
  refusing a pre-contract Aldi capture (36), plus rule growth and its knock-on winner moves. Only because
  every line had an explanation was blessing them safe. If you cannot say WHY a line moved, do not run this.
  And never regenerate the fixture from the LIVE board - re-derive from the frozen inputs, which is what
  this script does.
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$fz = Join-Path $root 'regression-inputs'
if (-not (Test-Path (Join-Path $fz 'ads-2026-07-05.json'))) { Write-Output "regression-inputs\ missing - freeze the inputs first"; exit 2 }

$scratch = Join-Path $fz 'scratch-out'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'compare-deals.ps1') `
    -AdsFile (Join-Path $fz 'ads-2026-07-05.json') `
    -BakersFile (Join-Path $fz 'bakers-deals-2026-07-05.json') `
    -SamsFile (Join-Path $fz 'sams-deals-2026-07-05.json') `
    -RegularDir (Join-Path $fz 'regular') `
    -ExtraDir $fz `
    -CommoditiesFile (Join-Path $fz 'commodities.json') `
    -BandsFile (Join-Path $fz 'price-bands.json') `
    -OutDir $scratch -MinStores 2 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output "engine FAILED on the frozen inputs - no baseline written"; exit 1 }

$cmpF = Get-ChildItem (Join-Path $scratch 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$doc = Read-JsonFile $cmpF.FullName

$rows = New-Object System.Collections.Generic.List[object]
foreach ($r in $doc.comparison) {
  $stores = [ordered]@{}
  foreach ($s in $r.stores) { $stores[[string]$s.store] = [double]$s.per_unit }
  $rows.Add([ordered]@{
    id=$r.id; unit=$r.unit
    cheapest_store=$r.cheapest_store; cheapest_price=[double]$r.cheapest_price
    nomem_store=$r.nomem_store; nomem_price=$(if($r.nomem_price -ne $null){[double]$r.nomem_price}else{$null})
    stores=$stores
  })
}
$out = [ordered]@{ frozen_week=[string]$doc.week_of; built_at=(Get-Date).ToString('s'); source='regression-inputs (hermetic; engine-rebuilt)'; commodities=$rows.ToArray() }
$file = Join-Path $root 'regression-baseline.json'
($out | ConvertTo-Json -Depth 8) | Set-Content $file -Encoding UTF8
Write-Output ("golden baseline frozen: " + $rows.Count + " commodities (week " + $doc.week_of + ") -> " + $file)
