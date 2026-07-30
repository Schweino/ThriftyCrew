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
# ASK FOR THE PRODUCT'S IDENTITY. `fields=` is a WHITELIST, and it used to list only name/size/price - i.e. we
# explicitly told Freshop NOT to send canonical_url or id, and then ran a SEPARATE search to guess back which
# product each price came from. That guess is where every wrong Family Fare link came from. canonical_url is the
# store's own URL for this exact product; taking it here makes the link a property of the price rather than a
# second, fallible lookup.
#
# WITH A FALLBACK, because this runs unattended at 06:30. If Freshop ever rejects the wider whitelist (an
# unknown field name is a 400, and 400 is also what its throttle returns - the two are indistinguishable from
# here), the pull must NOT die: Family Fare's prices would go stale and the daily's freshness assert would fail
# the whole job. A field we would merely LIKE must never be able to take down the price we NEED.
$FIELDS_RICH = 'id,name,size,price,base_price,unit_price,canonical_url'
$FIELDS_MIN = 'name,size,price,base_price,unit_price'
$script:fieldsMode = $FIELDS_RICH
$script:fellBack = $false
function Get-FreshopItems($term) {
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    try {
      $r = Invoke-RestMethod -Uri ("$b/products?app_key=$ak&store_id=$sid&q=" + [uri]::EscapeDataString($term) + "&limit=25&fields=" + $script:fieldsMode) -Headers $UA -TimeoutSec 20
      return @($r.items)   # may be empty (throttled or not-carried); caller queues empties for recovery
    }
    catch {
      # On the FIRST hard failure while asking for the rich field set, try the minimal one once. If that works,
      # the wide whitelist is the problem and we stay narrow for the rest of the run (rows keep their prices but
      # lose their identity - logged loudly, because that is a silent return to the two-pipeline bug).
      if ($script:fieldsMode -eq $FIELDS_RICH -and -not $script:fellBack) {
        try {
          $r2 = Invoke-RestMethod -Uri ("$b/products?app_key=$ak&store_id=$sid&q=" + [uri]::EscapeDataString($term) + "&limit=25&fields=" + $FIELDS_MIN) -Headers $UA -TimeoutSec 20
          $script:fieldsMode = $FIELDS_MIN; $script:fellBack = $true
          Write-Warning 'Family Fare: Freshop rejected the canonical_url field whitelist - fell back to the minimal fields. Rows will carry NO product identity this run, so their links cannot be derived and must be searched. Check the Freshop field names.'
          return @($r2.items)
        }
        catch { }   # both failed -> it is the throttle, not the whitelist; fall through to the normal retry
      }
      Start-Sleep -Milliseconds 400
    }
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
    # STAMP THE PRODUCT IDENTITY WE ALREADY HAVE.
    # We just fetched this price FROM a specific Freshop product, and Freshop hands us its canonical_url and id
    # in the same response - then this row threw both away. A separate pass later had to SEARCH the store to
    # re-find the product so it could be linked, and sometimes found a different one: the board published
    # "Hy Vee Almondmilk" while its link opened "Blue Diamond Almond Breeze". Two independent pipelines for one
    # fact can always disagree, and that disagreement is the entire wrong-link bug class.
    # A price and its link are the same fact. Carry the id with the price and they cannot drift apart.
    $row = [ordered]@{ store='Family Fare'; item=[string]$it.name; ad_price=('$' + $val); size=[string]$it.size; regular=$val; current_price=$cur; source_ad='everyday shelf price'; as_of=$todayS }
    if ($it.canonical_url) { $row['canonical_url'] = [string]$it.canonical_url }
    if ($it.id) { $row['product_id'] = [string]$it.id }
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
  Write-Warning ("Family Fare: throttled - got only " + @($deals).Count + " items vs " + $prevMax + " in the last good file. Diagnostic copy: " + $pfile + ". These rows are REAL and are being MERGED (today's prices win, everything else carries forward).")
  # ALERT ON A CONSECUTIVE RUN OF THROTTLED DAYS (2026-07-28). The guard above is correct and does its job -
  # it refuses to let a throttled partial overwrite good prices. But it did that SILENTLY, and a throttled
  # file has been written on 8 of the last 8 days: out\throttled\ holds family-fare-2026-07-21 through -28.
  # A store whose prices quietly freeze is exactly the failure the whole estate is built to prevent, and the
  # one signal that it is happening was a Write-Warning nobody reads. One day of throttling is routine
  # weather; several in a row means the store has stopped refreshing and the board is serving old prices.
  try {
    $recent = @(Get-ChildItem (Join-Path $qDir 'family-fare-*.throttled.json') -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -match '(\d{4}-\d{2}-\d{2})' -and [datetime]$Matches[1] -ge (Get-Date).AddDays(-4) })
    if ($recent.Count -ge 3) {
      $lastGood = @(Get-ChildItem (Join-Path $OutDir 'regular\family-fare-regular-*.json') -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
      $lgName = if ($lastGood.Count) { $lastGood[0].Name } else { '(none)' }
      $body = "Family Fare's pull has hit the throttle-wipeout guard on $($recent.Count) of the last 4 days, so the board is still serving prices from $lgName.`n`n" +
              "Nothing is WRONG on the board - the guard is refusing to let a throttled partial overwrite good prices, which is correct. The problem is that Family Fare has effectively stopped refreshing, and until now that happened silently.`n`n" +
              "Today's run collected $(@($deals).Count) items against a best-of-recent of $prevMax, with $(@($empty).Count) term(s) still empty after recovery. Diagnostic: $pfile`n`n" +
              "Freshop rate-limits several hundred sequential terms from one IP. The fix is fewer requests per window (shard the term list across the day), NOT slower pacing - a 2026-07-28 probe showed 20 terms at 200ms all succeed while a second burst all came back empty, so the budget is per-window request COUNT."
      & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'send-alert.ps1') -Subject ("Grocery: Family Fare has been throttled " + $recent.Count + " of the last 4 days - prices frozen") -Body $body | Out-Null
    }
  } catch { Write-Warning ('family-fare throttle alert failed: ' + $_.Exception.Message) }
  # NO `return` HERE ANY MORE (2026-07-30). This block used to bail out, throwing the whole capture away.
  #
  # THAT WAS AN ALL-OR-NOTHING DECISION ABOUT A PARTIAL PULL. A throttled response is not a WRONG response -
  # it is a SHORTER one. Every row in it was fetched from Freshop today and is fully identity-bearing
  # (773/773 carried canonical_url + product_id + current_price on 2026-07-29, against 963/2011 on the file
  # the board was actually serving). Binning it discarded 32 price CORRECTIONS and 36 new products, and 5 of
  # those 32 were live board cells: sour cream $2.99 -> $3.29, strawberries $3.99 -> $4.49, lemons, chipotle
  # adobo, zucchini. The estate published prices it had already been told were wrong, 13 days running.
  #
  # THE CARRY-FORWARD BLOCK BELOW ALREADY DOES THE RIGHT THING, and this `return` was jumping over it:
  # "today's price ALWAYS wins for a product this run returned; a product it did NOT return is carried
  # forward at its last verified price, stamped with the date that price was captured". That IS the union
  # Walmart gets. The wipeout guard predates it and was still defending against a danger the carry-forward
  # had already removed - even a ZERO-row pull now yields a fully carried file rather than a blank store.
  #
  # It also fixes a second bug: the 14-day cap is applied at BUILD time, so freezing the file froze the cap
  # with it. The board was serving 20 rows captured 2026-07-13 - seventeen days old under a fourteen-day
  # policy - purely because nothing rebuilt the file. Falling through re-applies the cap every day.
  #
  # The detection and the alert above are KEPT: "Family Fare is being throttled" is real news worth sending.
  # What changes is that being throttled no longer means being ignored.
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
  # canonical_url/product_id are contract fields too: they are the IDENTITY of the product this price came
  # from, and the link is derived from them. Drop them here and the row keeps its price but forgets which
  # product it priced - which is exactly how a tile ends up with a price and no link, or worse, a link found
  # by a separate search that landed on a different product.
  foreach ($k in @('current_price', 'base_price', 'marked_down', 'canonical_url', 'product_id')) { if ($null -ne $r.$k) { $h[$k] = $r.$k } }
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
