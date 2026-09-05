<#
  regression-test.ps1 - Re-runs the engine on the fully-FROZEN input set in regression-inputs\ and asserts
  every number/winner still matches regression-baseline.json (within 1%). Run after ANY engine change.
  A FAIL means the code changed a known-good price - investigate before shipping. Exit 1 on failure.

  HERMETIC: ads + Baker's + Sam's + the entire regular\ (everyday) channel + extra-deals are ALL pinned to
  regression-inputs\ via -RegularDir/-ExtraDir. (The original harness pinned only ads/bakers/sams while the
  engine auto-loaded the LIVE newest regular files - so the "frozen" test drifted with the data and once
  failed with 47 phantom diffs. Never point this at live out\ inputs again.)

  ...AND SO ARE THE RULES (pinned 2026-07-29). Freezing the data but not commodities.json/price-bands.json
  left the same hole one level up: every ordinary rule edit - a widened include, a new exclude, and there is
  one most weeks - registered as "regression drift". The guard went red, stayed red, and stopped being read.
  On 2026-07-29 it reported 66 differences and NOT ONE was a code bug: 36 were the price_mode in-store
  contract correctly refusing a frozen Aldi capture that predates it, the rest were rule growth (29 -> 503
  commodities) and the knock-on winner moves. A guard that can fail for legitimate reasons will, and then it
  is worse than no guard because it looks like coverage.

  So this test now answers exactly one question: DID THE CODE CHANGE A KNOWN-GOOD NUMBER? Rule drift is
  audit-match-soundness's job (it has a reviewed baseline and an -Accept workflow). Two guards, one job each.
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$fz = Join-Path $root 'regression-inputs'
$baseFile = Join-Path $root 'regression-baseline.json'
if (-not (Test-Path $baseFile)) { Write-Output "no baseline - run build-regression-baseline.ps1 first"; exit 2 }
if (-not (Test-Path (Join-Path $fz 'ads-2026-07-05.json'))) { Write-Output "no frozen inputs - regression-inputs\ is missing"; exit 2 }

# multibuy / BOGO math unit test (deterministic) - gate before the frozen-input comparison
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'compare-deals.ps1') -SelfTest | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output 'REGRESSION FAIL  -  multibuy self-test failed (run: compare-deals.ps1 -SelfTest to see which case)'; exit 1 }

# re-run the engine on the frozen inputs into a SCRATCH out dir (never touches live out\ files)
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
if ($LASTEXITCODE -ne 0) { Write-Output 'REGRESSION FAIL  -  engine crashed on the frozen inputs'; exit 1 }

$base = (Read-JsonFile $baseFile).commodities
$nowF = Get-ChildItem (Join-Path $scratch 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$now  = (Read-JsonFile $nowF.FullName).comparison
$nowById = @{}; foreach ($r in $now) { $nowById[[string]$r.id] = $r }

function Near($a, $b) { if ($a -eq $null -or $b -eq $null) { return ($a -eq $b) }; $a=[double]$a; $b=[double]$b; if ($b -eq 0) { return ($a -eq 0) }; return ([math]::Abs($a-$b)/[math]::Max([math]::Abs($b),0.01) -le 0.01) }

$fails = New-Object System.Collections.Generic.List[object]
foreach ($b in $base) {
  $r = $nowById[[string]$b.id]
  if (-not $r) { $fails.Add("MISSING commodity '$($b.id)' - dropped from output"); continue }
  if (-not (Near $r.cheapest_price $b.cheapest_price)) { $fails.Add("$($b.id): cheapest_price $($b.cheapest_price) -> $($r.cheapest_price)") }
  if ([string]$r.cheapest_store -ne [string]$b.cheapest_store) { $fails.Add("$($b.id): cheapest_store $($b.cheapest_store) -> $($r.cheapest_store)") }
  if ([string]$r.nomem_store -ne [string]$b.nomem_store) { $fails.Add("$($b.id): nomem_store $($b.nomem_store) -> $($r.nomem_store)") }
  if (-not (Near $r.nomem_price $b.nomem_price)) { $fails.Add("$($b.id): nomem_price $($b.nomem_price) -> $($r.nomem_price)") }
  $nowStores = @{}; foreach ($s in $r.stores) { $nowStores[[string]$s.store] = [double]$s.per_unit }
  foreach ($p in $b.stores.PSObject.Properties) {
    if (-not $nowStores.ContainsKey($p.Name)) { $fails.Add("$($b.id): store '$($p.Name)' dropped"); continue }
    if (-not (Near $nowStores[$p.Name] $p.Value)) { $fails.Add("$($b.id)/$($p.Name): $($p.Value) -> $($nowStores[$p.Name])") }
  }
}

if ($fails.Count -eq 0) {
  Write-Output ("REGRESSION PASS  -  all " + @($base).Count + " commodities match the hermetic frozen baseline within 1%.")
  exit 0
} else {
  Write-Output ("REGRESSION FAIL  -  " + $fails.Count + " difference(s) from the golden baseline:")
  foreach ($f in $fails.ToArray()) { Write-Output ("  " + $f) }
  exit 1
}
