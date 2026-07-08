<#
  build-regression-baseline.ps1 - Rebuilds the golden baseline by RUNNING the engine on the hermetic frozen
  input set in regression-inputs\ and snapshotting the result. Re-run ONLY after a deliberate, verified
  engine change to intentionally re-baseline.

  This deliberately does NOT trust any pre-existing comparison file: the previous version snapshotted
  whatever -CompareFile was handed to it (once a Jul-6 live file) while labeling it frozen_week=2026-07-05 -
  a baseline built from different inputs than the test replays, which made the regression test meaningless.
  Building FROM the frozen inputs guarantees baseline and test always share the same input set.
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
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
    -OutDir $scratch -MinStores 2 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output "engine FAILED on the frozen inputs - no baseline written"; exit 1 }

$cmpF = Get-ChildItem (Join-Path $scratch 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$doc = Get-Content $cmpF.FullName -Raw | ConvertFrom-Json

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
