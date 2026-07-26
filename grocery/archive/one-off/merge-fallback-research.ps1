<#
  merge-fallback-research.ps1 - folds fresh browser-researched EVERYDAY prices (out\fallback-research.json,
  written by the browser fallback-refresh) into each store's everyday file, so on-sale browser-store cells have
  a CURRENT everyday item to revert to when the sale ends. Preserves the store's other everyday commodities
  (loads the newest existing <store>-regular, appends the fresh items, dedupes by product name, writes a fresh
  dated file). compare-deals then ranks the cheapest everyday item, so the fresh price wins the moment a sale ends.
#>
param([string]$In = "", [string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
if (-not $In) { $In = Join-Path $OutDir 'fallback-research.json' }
$asofS = (Get-Date).ToString('yyyy-MM-dd')
$storeFile = @{ "Baker's" = 'bakers'; 'Hy-Vee' = 'hyvee'; 'Aldi' = 'aldi'; 'Walmart' = 'walmart' }

$fresh = Get-Content $In -Raw | ConvertFrom-Json
$byStore = @{}
foreach ($r in $fresh) {
  if (-not $r.item -or $r.item -match 'NOT FOUND' -or -not $r.ad_price) { continue }
  $st = [string]$r.store; if (-not $byStore.ContainsKey($st)) { $byStore[$st] = @() }
  $byStore[$st] += ,([pscustomobject]@{ store=$st; item=[string]$r.item; ad_price=[string]$r.ad_price; size=[string]$r.size; regular=''; source_ad='everyday fallback refresh (browser)' })
}
$regDir = Join-Path $OutDir 'regular'
foreach ($st in $byStore.Keys) {
  $key = $storeFile[$st]; if (-not $key) { Write-Output "  skip unknown store '$st'"; continue }
  $existing = @()
  $prev = Get-ChildItem (Join-Path $regDir ($key + '-regular-*.json')) -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  $ptype = 'everyday'
  if ($prev) { try { $pd = Get-Content $prev.FullName -Raw | ConvertFrom-Json; if ($pd.price_type) { $ptype = [string]$pd.price_type }; $existing = @($pd.deals) } catch {} }
  # fresh items REPLACE any existing entry with the same product name; everything else is preserved
  $freshNames = @{}; foreach ($f in $byStore[$st]) { $freshNames[($f.item.ToLower().Trim())] = $true }
  $merged = @(); foreach ($d in $existing) { $nm = (("" + $d.item + $d.name).ToLower().Trim()); if (-not $freshNames.ContainsKey($nm)) { $merged += ,$d } }
  $merged += $byStore[$st]
  $doc = [ordered]@{ store=$st; price_type=$ptype; source='everyday (weekly pull + fallback refresh)'; generated=$asofS; deals=$merged }
  $doc | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $regDir ($key + "-regular-$asofS.json")) -Encoding UTF8
  Write-Output ("$key-regular-$asofS.json: +$($byStore[$st].Count) fresh everyday, $($merged.Count) total")
}
