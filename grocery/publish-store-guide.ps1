<#
  publish-store-guide.ps1 - The single, gated PUBLISH action for the "Shop Smart at Your Store" page.
  HEADLESS (no browser). Rebuilds out\store-guide-embed.html from the newest board (same file-selection
  logic as the price board), runs a COVERAGE GATE so a degraded/half-empty matrix is never pushed live,
  then upserts the Ghost Resources post (slug shop-smart-at-your-store) via publish-resource.ps1.

  Visibility is PUBLIC: this page is a free proof asset, same as the price board.

  Exit codes:  0 = published   2 = HELD (coverage gate failed)   1 = error
  Params: -CompareFile <path> (default newest)  -MinCommodities 25  -MinPerStore 15  -Force (skip gate)  -Draft
#>
param([string]$CompareFile = "", [int]$MinCommodities = 25, [int]$MinPerStore = 15, [switch]$Force, [switch]$Draft)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
$slug   = 'shop-smart-at-your-store'

if (-not $CompareFile) {
  $cmpF = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1)
  $CompareFile = $cmpF.FullName
  # prefer the semantically-verified board when it is at least as fresh as the raw comparison (see build-deals-page)
  try { $wk = (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).week_of; $verF = Join-Path $OutDir ("verified-" + $wk + ".json"); if ((Test-Path $verF) -and ((Get-Item $verF).LastWriteTime -ge $cmpF.LastWriteTime)) { $CompareFile = $verF } } catch {}
}
$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json

# ---- COVERAGE GATE: never publish a degraded matrix (a store that dropped out, or a thin board) ----
$stores = @('Hy-Vee','Aldi','Family Fare',"Baker's","Sam's Club",'Walmart')
$perStore = @{}; foreach ($s in $stores) { $perStore[$s] = 0 }
foreach ($r in $doc.comparison) { foreach ($st in $r.stores) { $k = [string]$st.store; if ($perStore.ContainsKey($k)) { $perStore[$k]++ } } }
$commCount = @($doc.comparison).Count
$thin = @(); foreach ($s in $stores) { if ($perStore[$s] -lt $MinPerStore) { $thin += ("{0}={1}" -f $s, $perStore[$s]) } }
$reasons = @()
if ($commCount -lt $MinCommodities) { $reasons += "only $commCount commodities (need >= $MinCommodities)" }
if ($thin.Count -gt 0)             { $reasons += ("thin/missing stores: " + ($thin -join ', ')) }
if ($reasons.Count -gt 0 -and -not $Force) {
  Write-Output ("HELD: coverage gate failed - " + ($reasons -join '; ') + ". NOT publishing (a store's pull likely failed; run -Force to override).")
  exit 2
}

# ---- rebuild the embed page (no <h1>; Ghost's post title is the H1) ----
# Delete the previous embed FIRST and check the builder's result: otherwise a build crash leaves
# yesterday's embed in place, which would then publish as if fresh.
$embed = Join-Path $OutDir 'store-guide-embed.html'
Remove-Item $embed -ErrorAction SilentlyContinue
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'build-store-guide.ps1') -CompareFile $CompareFile -Out $embed -Embed | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output ("ERROR: store-guide build FAILED (rc=$LASTEXITCODE) - not publishing"); exit 1 }
if (-not (Test-Path $embed) -or ((Get-Item $embed).Length -lt 2000)) { Write-Output 'ERROR: store-guide build produced no/short file'; exit 1 }

# ---- upsert (publish-resource.ps1 upserts by slug; public = no paywall schema) ----
$pubArgs = @('-ExecutionPolicy','Bypass','-File',(Join-Path $root 'publish-resource.ps1'),
  '-Title','Shop Smart at Your Store',
  '-Slug',$slug,
  '-HtmlFile',$embed,
  '-Excerpt','Pick your store and see what to buy there, what is fair, and what to skip this week. Seven Omaha stores, verified prices.',
  '-MetaTitle','Shop Smart at Your Store | Thrifty Crew',
  '-MetaDesc','Most of us shop at one store. Pick yours and see what it prices well this week, what is close enough, and what costs way more than it should. Seven Omaha stores, checked against their own ads.',
  '-Visibility','public')
if ($Draft) { $pubArgs += '-Draft' }
& powershell @pubArgs
$prc = $LASTEXITCODE
if ($prc -ne 0) {
  Write-Output ("ERROR: Ghost upsert FAILED (rc=$prc) - live page NOT updated (change not published)")
  exit 1
}
Write-Output ("PUBLISHED shop-smart-at-your-store  (public, $commCount weekly commodities, week " + [string]$doc.week_of + ")")
exit 0
