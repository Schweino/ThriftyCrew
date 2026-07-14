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
    # PUBLISH THE CURRENT PRICE, NEVER THE REGULAR ONE.
    # This used to read `base_price` FIRST and only fall back to `price`. base_price is the REGULAR price;
    # `price` is what the store charges today. That is exactly the bug that had the board publishing Hy-Vee
    # sirloin at $13.99/lb while Omaha #01 was charging $11.99, and Baker's chicken breast at $2.89/lb while
    # the store was charging $2.29. Freshop happens to return the two fields identical for every one of the
    # 375 Family Fare products sampled on 2026-07-14, so it was harmless - but it was a loaded gun. The day
    # Freshop starts populating a markdown into `price`, the old order would have quietly published the
    # regular price instead, and nothing downstream would have caught it.
    # `price` comes back as a string with a $ ("$3.59"); base_price as a number (3.59).
    $cur  = 0.0; [void][double]::TryParse((([string]$it.price)      -replace '[^0-9.]',''), [ref]$cur)
    $base = 0.0; [void][double]::TryParse((([string]$it.base_price) -replace '[^0-9.]',''), [ref]$base)
    $val = $cur
    if ($val -le 0) { $val = $base }
    if ($val -le 0) { continue }
    $key = ([string]$it.name + '|' + [string]$it.size)
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    # THE CONTRACT (guards invariant 10): current_price is what the STORE CHARGES, recorded independently of
    # what we choose to publish in ad_price. A puller that reaches for the regular-price field then produces
    # two different numbers on the row, and the guard sees it. Without this field the guard cannot check us.
    $row = [ordered]@{ store='Family Fare'; item=[string]$it.name; ad_price=('$' + $val); size=[string]$it.size; regular=$val; current_price=$cur; source_ad='everyday shelf price'; as_of=$todayS }
    if ($base -gt 0) { $row['base_price'] = $base }
    if ($base -gt 0 -and $val -lt ($base - 0.005)) { $row['marked_down'] = $true }
    $script:deals += ,$row
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
  # WRITE THIS OUTSIDE out\regular ENTIRELY.
  # It used to be written as "out\regular\family-fare-regular-<date>.PARTIAL.json", which still MATCHES the
  # 'family-fare-regular-*.json' glob - and because "PARTIAL.json" sorts AFTER "json", every consumer that
  # takes the newest file by name (compare-deals and ~20 audits) picked the throttled 0-row file instead of
  # the last good one. The guard defeated itself: Family Fare collapsed to ZERO everyday board rows while
  # this file claimed to be "keeping the last good FF prices live".
  # Renaming it inside out\regular was not enough - out\regular is scanned with '*.json' in several places,
  # so ANY file living there can be read as a store. The only safe home for a diagnostic is a directory that
  # is not the data directory. A diagnostic must never be able to become the source of truth.
  $qDir = Join-Path $OutDir 'throttled'
  if (-not (Test-Path $qDir)) { New-Item -ItemType Directory -Path $qDir -Force | Out-Null }
  $pfile = Join-Path $qDir ("family-fare-$todayS.throttled.json")
  ([ordered]@{ store='Family Fare'; week_of=$todayS; price_type='everyday'; throttled=$true; deal_count=@($deals).Count; empty_terms=@($empty); deals=$deals } | ConvertTo-Json -Depth 6) | Set-Content $pfile -Encoding UTF8
  Write-Warning ("Family Fare: THROTTLE-WIPEOUT guard tripped - got only " + @($deals).Count + " items vs " + $prevMax + " in the last good file. NOT overwriting; wrote " + $pfile + ". Last good FF prices stay live.")
  return
}
# CARRY-FORWARD: a pull that returns FEWER products than last time has NOT proved those products are gone.
# Freshop rate-limits us into partial catalogues routinely, and a partial pull is a plain overwrite: on
# 2026-07-14 a 380-item run replaced a 590-item file, silently dropping 210 products - including every
# commodity registered that morning - and it sailed past the 50%-wipeout guard above (380 > 295) with nothing
# logged. Family Fare lost 24 board cells and the run reported success.
# So: today's price ALWAYS wins for a product this run returned; a product it did NOT return is carried
# forward at its last verified price, stamped with the date that price was captured, and dropped once that
# capture goes stale. Absence from one throttled response is not evidence of absence from the store.
$MaxCarryDays = 14
$carried = 0; $expired = 0
$prevF = Get-ChildItem (Join-Path $regDir 'family-fare-regular-*.json') -EA SilentlyContinue |
  Where-Object { $_.BaseName -match '^family-fare-regular-\d{4}-\d{2}-\d{2}$' } |
  Sort-Object Name -Descending | Select-Object -First 1

# One uniform row shape. Fresh rows are [ordered] hashtables; rows re-read from JSON are PSCustomObjects, and
# mixing the two breaks both '.prop = x' assignment and Add-Member. Normalise every row through this.
function Norm-Row($r, $asOf, $isCarried) {
  $h = [ordered]@{ store='Family Fare'; item=[string]$r.item; ad_price=[string]$r.ad_price; size=[string]$r.size; regular=$r.regular; source_ad=[string]$r.source_ad; as_of=[string]$asOf }
  # PRESERVE THE CONTRACT FIELDS. This normalizer rebuilds every row with a fixed key set, and it used to drop
  # current_price / base_price / marked_down - so the contract the ingest step carefully wrote got stripped one
  # line later, and guard 10 saw ZERO Family Fare rows to police. A normalizer that silently discards the field
  # a guard depends on is how a store slips back out from under the guard without anyone noticing.
  foreach ($k in @('current_price','base_price','marked_down')) { if ($null -ne $r.$k) { $h[$k] = $r.$k } }
  if ($isCarried) { $h['carried_forward'] = $true }
  return $h
}

$rows = New-Object System.Collections.ArrayList
$have = @{}
foreach ($d in $deals) { $k = ([string]$d.item).ToLower(); if ($have.ContainsKey($k)) { continue }; $have[$k] = $true; [void]$rows.Add((Norm-Row $d $todayS $false)) }

if ($prevF) {
  $pdoc = Get-Content $prevF.FullName -Raw | ConvertFrom-Json
  foreach ($d in @($pdoc.deals)) {
    $k = ([string]$d.item).ToLower()
    if (-not $k -or $have.ContainsKey($k)) { continue }
    $asOf = if ($d.as_of) { [string]$d.as_of } else { [string]$pdoc.week_of }
    $age = 9999
    try { $age = [int](([datetime]$todayS) - ([datetime]$asOf)).TotalDays } catch {}
    if ($age -gt $MaxCarryDays) { $expired++; continue }
    $have[$k] = $true
    [void]$rows.Add((Norm-Row $d $asOf $true))
    $carried++
  }
}
$deals = $rows.ToArray()

$out = [ordered]@{ store='Family Fare'; week_of=$todayS; price_type='everyday'; source='Freshop catalog base_price (store_id 6401, Omaha), NOT Instacart'; deal_count=@($deals).Count; fresh_count=(@($deals).Count - $carried); carried_count=$carried; expired_count=$expired; max_carry_days=$MaxCarryDays; empty_terms=@($empty); deals=$deals }
($out | ConvertTo-Json -Depth 6) | Set-Content $file -Encoding UTF8
Write-Output ("Family Fare everyday prices: " + @($deals).Count + " catalog items (" + (@($deals).Count - $carried) + " fresh, " + $carried + " carried forward, " + $expired + " expired past $MaxCarryDays d; " + $empty.Count + " terms still empty) -> " + $file)
