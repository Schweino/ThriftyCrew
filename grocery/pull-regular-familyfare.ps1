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

# ROOT-CAUSE FIX (2026-07-13, ground-pork + 56 other FF staples were silently missing): the Freshop /sessions
# token endpoint now 404s, and during the rapid 301-term run the shared IP gets rate-limited so Freshop returns
# 200 with ZERO items, which was silently skipped -> the term vanished from the board as "No price yet".
# BOUNDED design (an earlier "3 retries+backoff per term" version ran ~45 min under a hard throttle): the main
# loop does ONE query per term (retry only on a hard ERROR, never on empty), detects a throttle STREAK and cools
# down ONCE, then does at most 2 recovery passes for the empties - all under a hard wall-clock cap so it can never
# run away. NO-TOKEN queries work fine.
$startTime = Get-Date
$MAXMIN = 9    # hard wall-clock cap for the whole pull
function Over-Cap { return (((Get-Date) - $startTime).TotalMinutes -gt $MAXMIN) }
function Get-FreshopItems($term) {
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
      $r = Invoke-RestMethod -Uri ("$b/products?app_key=$ak&store_id=$sid&q=" + [uri]::EscapeDataString($term) + "&limit=25&fields=name,size,price,base_price,unit_price") -Headers $UA -TimeoutSec 20
      return @($r.items)   # may be empty (throttled or not-carried); caller queues empties for recovery
    } catch { Start-Sleep -Milliseconds 400 }   # retry ONCE on a hard error only
  }
  return @()
}

# Some FF searches surface the wrong product (notably "orange juice" -> canned mandarin oranges); add
# supplemental queries for those so the everyday matrix stays complete without a manual patch.
$supplemental = @{ 'orange juice' = @('simply orange juice','kemps orange juice') }

$deals = @()
$seen = @{}
function Ingest-Items($items) {
  foreach ($it in $items) {
    if (-not $it.name) { continue }
    $val = $it.base_price; if (-not $val) { $val = $it.price }
    if (-not $val) { continue }
    $key = ([string]$it.name + '|' + [string]$it.size)
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $script:deals += ,([ordered]@{ store='Family Fare'; item=[string]$it.name; ad_price=('$' + $val); size=[string]$it.size; regular=$it.base_price; source_ad='everyday shelf price' })
  }
}
# flatten terms to an ordered array so a wall-clock break can queue the REMAINING terms for recovery
$termList = @($terms.PSObject.Properties | ForEach-Object { [string]$_.Value })
$empty = New-Object System.Collections.Generic.List[string]
$streak = 0
for ($i = 0; $i -lt $termList.Count; $i++) {
  if (Over-Cap) { for ($j = $i; $j -lt $termList.Count; $j++) { $empty.Add($termList[$j]) }; Write-Output 'Family Fare: wall-clock cap hit in main pass; remaining terms deferred to recovery'; break }
  $term = $termList[$i]
  $queries = @($term); if ($supplemental.ContainsKey($term)) { $queries += $supplemental[$term] }
  $items = @(); foreach ($q in $queries) { $items += (Get-FreshopItems $q) }
  Start-Sleep -Milliseconds 200
  if (@($items).Count -eq 0) {
    $empty.Add($term); $streak++
    if ($streak -ge 15) { Write-Output ("Family Fare: throttle streak ($streak empties) - cooling down 45s..."); Start-Sleep -Seconds 45; $streak = 0 }
  } else { $streak = 0; Ingest-Items $items }
}
# RECOVERY PASSES: empties are rate-limit victims; wait out the throttle and retry ONCE each, up to 2 passes,
# still under the wall-clock cap. Single query per term (no inner backoff) so a hard throttle can't blow up.
$pass = 0
while ($empty.Count -gt 0 -and $pass -lt 2 -and -not (Over-Cap)) {
  $pass++
  Write-Output ("Family Fare: recovery pass $pass for " + $empty.Count + " empty term(s)...")
  Start-Sleep -Seconds 20
  $still = New-Object System.Collections.Generic.List[string]
  foreach ($term in $empty) {
    if (Over-Cap) { $still.Add($term); continue }
    $items = Get-FreshopItems $term; Start-Sleep -Milliseconds 250
    if (@($items).Count -eq 0) { $still.Add($term) } else { Ingest-Items $items }
  }
  $empty = $still
}
if ($empty.Count) { Write-Warning ("Family Fare: " + $empty.Count + " term(s) STILL empty after recovery (not carried, or persistent throttle): " + (($empty | Select-Object -First 40) -join ', ')) }

# THROTTLE-WIPEOUT GUARD: if this run collected FAR fewer items than the best of the last few files, it was
# rate-limited into near-emptiness - do NOT clobber good data with it (that would blank out FF on the board).
# Write a .partial diagnostic file instead and keep the last good file live. The next un-throttled run refreshes.
$prevMax = 0
foreach ($pf in (Get-ChildItem (Join-Path $regDir 'family-fare-regular-*.json') -EA SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 4)) {
  try { $pc = [int](ConvertFrom-Json ([IO.File]::ReadAllText($pf.FullName))).deal_count; if ($pc -gt $prevMax) { $prevMax = $pc } } catch {}
}
$file = Join-Path $regDir ("family-fare-regular-$todayS.json")
if ($prevMax -gt 100 -and @($deals).Count -lt ($prevMax * 0.5)) {
  $pfile = Join-Path $regDir ("family-fare-regular-$todayS.PARTIAL.json")
  ([ordered]@{ store='Family Fare'; week_of=$todayS; price_type='everyday'; throttled=$true; deal_count=@($deals).Count; empty_terms=@($empty); deals=$deals } | ConvertTo-Json -Depth 6) | Set-Content $pfile -Encoding UTF8
  Write-Warning ("Family Fare: THROTTLE-WIPEOUT guard tripped - got only " + @($deals).Count + " items vs " + $prevMax + " in the last good file. NOT overwriting; wrote " + $pfile + ". Last good FF prices stay live.")
  return
}
$out = [ordered]@{ store='Family Fare'; week_of=$todayS; price_type='everyday'; source='Freshop catalog base_price (store_id 6401, Omaha), NOT Instacart'; deal_count=@($deals).Count; empty_terms=@($empty); deals=$deals }
($out | ConvertTo-Json -Depth 6) | Set-Content $file -Encoding UTF8
Write-Output ("Family Fare everyday prices: " + @($deals).Count + " catalog items (" + $empty.Count + " terms still empty) -> " + $file)
