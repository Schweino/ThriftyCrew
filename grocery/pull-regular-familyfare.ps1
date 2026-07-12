<#
  pull-regular-familyfare.ps1 - Pulls Family Fare EVERYDAY (non-ad) shelf prices for the tracked
  commodities, straight from Family Fare's OWN Freshop catalog (base_price). NOT Instacart.
  Output: out\regular\family-fare-regular-<date>.json  (price_type = "everyday"), which compare-deals
  ingests alongside the weekly-ad data so the true cheapest (sale OR everyday) wins.
#>
param([string]$OutDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$regDir = Join-Path $OutDir 'regular'
if (-not (Test-Path $regDir)) { New-Item -ItemType Directory -Force $regDir | Out-Null }
$UA = @{ 'User-Agent' = 'Mozilla/5.0' }
$todayS = (Get-Date).ToString('yyyy-MM-dd')
$terms = (Get-Content (Join-Path $root 'commodity-search.json') -Raw | ConvertFrom-Json).terms

$ak = 'family_fare'; $sid = '6401'; $b = 'https://api.freshop.ncrcloud.com/1'
function Get-FreshToken {
  foreach ($tu in @("https://api.freshop.ncrcloud.com/2/sessions?app_key=$ak", "$b/sessions?app_key=$ak")) {
    try { $ts = Invoke-RestMethod -Uri $tu -Method Post -Headers $UA -TimeoutSec 20; if ($ts.token) { return [string]$ts.token } } catch {}
  }
  return $null
}
$tok = Get-FreshToken

# OMAHA GUARD (Brad's rule: every store source must be a verified Omaha location). Store 6401 is
# "Family Fare - 50th & Grover St, 5019 Grover St, Omaha NE 68106" (verified 2026-07-12). Assert it on
# every run: if Freshop ever remaps the id to a different city, FAIL LOUD rather than pull wrong prices.
# An API error on the metadata call is NOT fatal (throttle) - only a NON-Omaha answer is.
try {
  $meta = Invoke-RestMethod -Uri "$b/stores/$sid`?app_key=$ak" -Headers $UA -TimeoutSec 20
  if ($meta -and $meta.city -and ([string]$meta.city) -notmatch '^Omaha$') {
    Write-Output ("FATAL: Freshop store $sid resolves to '" + $meta.city + "', NOT Omaha - refusing to pull wrong-city prices. Fix `$sid.")
    exit 2
  }
} catch { }

# ROOT-CAUSE FIX: Freshop rate-limits a reused token and then returns 200 with ZERO items (not an error),
# which silently dropped the last terms. Retry on EMPTY as well as on error, with a FRESH token each retry.
function Get-FreshopItems($term) {
  for ($attempt = 1; $attempt -le 4; $attempt++) {
    $tq = if ($tok) { "&token=$tok" } else { "" }
    try {
      $r = Invoke-RestMethod -Uri ("$b/products?app_key=$ak&store_id=$sid$tq&q=" + [uri]::EscapeDataString($term) + "&limit=15&fields=name,size,price,base_price,unit_price") -Headers $UA -TimeoutSec 25
      if ($r.items -and @($r.items).Count -gt 0) { return @($r.items) }
    } catch {}
    Start-Sleep -Milliseconds 500
    $script:tok = Get-FreshToken      # empty or error -> mint a new token before the next try
  }
  return @()
}

# Some FF searches surface the wrong product (notably "orange juice" -> canned mandarin oranges); add
# supplemental queries for those so the everyday matrix stays complete without a manual patch.
$supplemental = @{ 'orange juice' = @('simply orange juice','kemps orange juice') }

$deals = @()
$seen = @{}
foreach ($p in $terms.PSObject.Properties) {
  $term = [string]$p.Value
  $queries = @($term); if ($supplemental.ContainsKey($term)) { $queries += $supplemental[$term] }
  $items = @()
  foreach ($q in $queries) { $items += (Get-FreshopItems $q); Start-Sleep -Milliseconds 120 }
  if (@($items).Count -eq 0) { Write-Warning ("Family Fare term returned nothing after retries: $term"); continue }
  foreach ($it in $items) {
    if (-not $it.name) { continue }
    $val = $it.base_price; if (-not $val) { $val = $it.price }
    if (-not $val) { continue }
    $key = ([string]$it.name + '|' + [string]$it.size)
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $deals += ,([ordered]@{ store='Family Fare'; item=[string]$it.name; ad_price=('$' + $val); size=[string]$it.size; regular=$it.base_price; source_ad='everyday shelf price' })
  }
}

$out = [ordered]@{ store='Family Fare'; week_of=$todayS; price_type='everyday'; source='Freshop catalog base_price (store_id 6401, Omaha), NOT Instacart'; deal_count=@($deals).Count; deals=$deals }
$file = Join-Path $regDir ("family-fare-regular-$todayS.json")
($out | ConvertTo-Json -Depth 6) | Set-Content $file -Encoding UTF8
Write-Output ("Family Fare everyday prices: " + @($deals).Count + " catalog items -> " + $file)
