<#
  pull-regular-familyfare.ps1 - Pulls Family Fare EVERYDAY (non-ad) shelf prices for the tracked
  commodities, straight from Family Fare's OWN Freshop catalog (base_price). NOT Instacart.
  Output: out\regular\family-fare-regular-<date>.json  (price_type = "everyday"), which compare-deals
  ingests alongside the weekly-ad data so the true cheapest (sale OR everyday) wins.
#>
param([string]$OutDir = "", [int]$MaxMinutes = 9, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# ---------------------------------------------------------------------------------------------------------
# TWO PURE RULES, LIFTED OUT SO THEY CAN BE TESTED (2026-07-31).
# Both of these were inline expressions buried in the middle of a network-driven script, which meant the only
# way to exercise them was to run the real pull against the real store. That is why nobody ever noticed the
# alert condition below had become structurally impossible to satisfy: there was no way to ask it a question.
# ---------------------------------------------------------------------------------------------------------

# WHERE THE NEXT RUN STARTS. $lastSuccessRot is the ROTATED index of the last term that returned products, so
# the absolute term after it is where this budget stopped buying - which, when the run aborted on a wall of
# consecutive empties, is exactly the FIRST TERM OF THAT WALL. The walled tail is therefore re-attempted at
# the top of the next window rather than skipped, and a term that is answered but genuinely product-less does
# not pin the cursor (it never becomes $lastSuccessRot, so the next success advances straight past it).
# Returns $null when nothing was bought at all: a cold shutout must leave the cursor exactly where it was,
# because those terms were REFUSED, not answered.
function Get-FfNextCursor([int]$startIdx, [int]$lastSuccessRot, [int]$termCount) {
  if ($termCount -le 0) { return $null }
  if ($lastSuccessRot -lt 0) { return $null }
  return (($startIdx + $lastSuccessRot + 1) % $termCount)
}

# IS THE CATALOG ACTUALLY DEGRADING? (re-keyed 2026-07-31, plan item 30a1a8)
# The old alert asked "did ONE run capture the whole store", comparing this run's raw collection against the
# best deal_count of recent MERGED files. That was the right question at one pull per day. Under the 3-hourly
# sharded sweep it is a question that can NEVER be answered yes - a run buys ~85 of 526 terms BY DESIGN - so
# it paged every single day about an architecture that was working: catalog 1909 -> 3974 items across 8
# sweeps, 0 expired, 358 board cells against a 256-cell pre-freeze baseline.
# So ask about OUTCOMES instead, on the MERGED catalog, where "Family Fare stopped refreshing" is actually
# visible. Any one of these is real news:
#   - rows are aging out of the 14-day carry (expired > 0): the catalog is losing products it cannot replace
#   - almost nothing has been re-verified against the store in the last 24-48h: the sweep is not buying
#   - the merged catalog itself shrank materially against the best of recent files
# The recently-verified window is TWO DAYS on purpose: as_of is a date, not a timestamp, and the day's FIRST
# sweep would otherwise be judged on its own slice alone and page every morning - the same shape of bug being
# fixed here. A genuinely frozen store falls to ~0 across two days regardless.
function Test-FfCatalogDegraded([int]$mergedCount, [int]$prevMax, [int]$expired, [int]$recentVerified) {
  $reasons = @()
  if ($expired -gt 0) { $reasons += ("$expired row(s) aged out past the 14-day carry - the catalog is losing products the sweep is not replacing") }
  if ($recentVerified -lt 500) { $reasons += ("only $recentVerified row(s) re-verified against the store in the last 48h - the sweep is not buying terms") }
  if ($prevMax -gt 100 -and $mergedCount -lt ($prevMax * 0.80)) { $reasons += ("merged catalog is $mergedCount items against a best-of-recent $prevMax - it shrank by more than 20%") }
  return @{ degraded = ($reasons.Count -gt 0); reasons = $reasons }
}

if ($SelfTest) {
  # Reachable BY CONSTRUCTION: declared on param() (an undeclared [switch] silently lands in $args and the
  # script runs its normal live path looking like a passing self-test - the 2026-07-29 class, re-proven in
  # commit 3014ab5c), and placed above every network call and every piece of pull state, so no data condition
  # can skip it. Pure computation, no writes, no requests.
  $fail = 0
  function _T([string]$label, [bool]$cond) { if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label"; $script:fail++ } }

  # ---- CURSOR. Frozen from the real 2026-07-31T04:00 sweep: started #154, bought through #243, then hit a
  # 60-term wall of HTTP 400s. termCount 526, so lastSuccessRot = 243 - 154 = 89.
  # THE INVARIANT: the next run must resume at #244, the FIRST term of the wall - not past it. This is a
  # REGRESSION PIN, not a fix: today's code already satisfies it (verified against ff-sweep-log.txt, where
  # the 07:00 run started at #244 and came back with 773 rows). It is pinned because the triage plan believed
  # the opposite, and an invariant nobody can test is one anybody can quietly break.
  _T 'cursor resumes at the FIRST term of the wall after an abort (#154 + 89 successes -> #244)' ((Get-FfNextCursor 154 89 526) -eq 244)
  # clean twin: a run with NO wall still advances to last-attempted+1
  _T 'cursor with no wall advances to last-attempted + 1 (#100 + 89 -> #190)' ((Get-FfNextCursor 100 89 526) -eq 190)
  # a term answered-but-empty cannot pin the cursor: it never becomes lastSuccessRot, so the next success passes it
  _T 'an answered-but-product-less term does not pin the cursor (success at rot 5 past an empty at rot 3)' ((Get-FfNextCursor 100 5 526) -eq 106)
  # a cold shutout must NOT move the cursor: re-attempting the refused slice is correct
  _T 'a cold shutout (no successes) leaves the cursor untouched' ($null -eq (Get-FfNextCursor 154 -1 526))
  # the wrap is real - the 2026-07-30T22:00 run started at #508 and wrapped to #70
  _T 'cursor wraps around the end of the term list (#508 + 87 of 526 -> #70)' ((Get-FfNextCursor 508 87 526) -eq 70)

  # ---- ALERT CONDITION. MUST-FIRE and its clean twin are both frozen from real runs.
  # CLEAN TWIN, and the whole point of the change: the 2026-07-31T04:00 sweep. One shard of a healthy catalog
  # (4269 merged items, 0 expired, 1259 re-verified in the window). The OLD trigger paged on this every day
  # because the run's own 566-row collection is under half the merged 4269 - by design. It must be silent.
  $ok = Test-FfCatalogDegraded 4269 4269 0 1259
  _T 'a healthy sharded sweep does NOT page (4269 items, 0 expired, 1259 re-verified) - the false daily alert' (-not $ok.degraded)
  # MUST-FIRE 1: rows aging out of the carry. This is what a genuinely frozen store looks like first.
  $d1 = Test-FfCatalogDegraded 4269 4269 24 1259
  _T 'FIRES when rows age out past the 14-day carry (24 expired)' ($d1.degraded -and ($d1.reasons -join ' ') -match 'aged out')
  # MUST-FIRE 2: the sweep has stopped buying terms at all
  $d2 = Test-FfCatalogDegraded 4269 4269 0 12
  _T 'FIRES when almost nothing was re-verified against the store (12 rows)' ($d2.degraded -and ($d2.reasons -join ' ') -match 're-verified')
  # MUST-FIRE 3: the merged catalog itself collapsed - the original freeze, which bottomed at 207 board cells
  $d3 = Test-FfCatalogDegraded 1909 3974 0 1259
  _T 'FIRES when the merged catalog shrinks >20% against best-of-recent (1909 vs 3974)' ($d3.degraded -and ($d3.reasons -join ' ') -match 'shrank')
  # and it must not fire on a catalog that merely grew slower than its best day
  _T 'does NOT fire on a catalog within 20% of its best (3800 vs 3974)' (-not (Test-FfCatalogDegraded 3800 3974 0 1259).degraded)

  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

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
# HARD WALL-CLOCK CAP for the whole pull. Now a PARAMETER (-MaxMinutes) rather than a constant.
# WHY (2026-07-30): this cap, not Freshop's rate limit, turned out to be the binding constraint on Family Fare
# coverage. Two full passes ran 9.1 and 9.7 minutes - both hit the 9-minute cap and deferred the rest - and each
# reported ~460 "empty" terms. Those terms were largely never REQUESTED, not refused: the run simply ran out of
# budget partway through ~500 terms. A second pass 90 minutes later added only 106 fresh rows and moved board
# coverage by zero cells, which is the tell - re-running the same truncated prefix cannot reach the tail.
# The cap itself is correct for the DAILY job (an earlier retry-happy version ran ~45 min under a throttle, and
# an unbounded pull in a scheduled task is how a job silently eats a morning). So the default stays 9. A manual
# catch-up run passes a bigger number deliberately.
$MAXMIN = $MaxMinutes
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
      # RECORD THE STATUS CODE. This catch used to swallow the response entirely and return @(), which made an
      # API REFUSAL indistinguishable from "this store genuinely does not carry that term". That single
      # conflation is why 13 days of Family Fare degradation was diagnosed as "throttled" without anyone ever
      # seeing a status code - and the truth, measured 2026-07-30, is that the search endpoint answers HTTP
      # 400, not 429 and not an empty 200. Browse (no q=) and /stores both return 200 the whole time, so we
      # are NOT ip-blocked; it is the q= search specifically. A tally of what the API actually said is the
      # difference between diagnosing this in one run and guessing at it for a fortnight.
      $sc = 0
      try { if ($_.Exception.Response) { $sc = [int]$_.Exception.Response.StatusCode } } catch {}
      $key = if ($sc) { "HTTP $sc" } else { 'no response/timeout' }
      if (-not $script:apiStatus) { $script:apiStatus = @{} }
      $script:apiStatus[$key] = 1 + [int]$script:apiStatus[$key]
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
    # ...AND SOMETIMES IT IS NOT A PRICE AT ALL. Freshop returns multi-buy offers as text: "4 for $5.00".
    # Stripping non-digits from that yields "45.00", so the row gets published at $45. Measured 2026-07-31:
    # 28 of 3,856 Family Fare rows carried a price built exactly that way (all "4 for $5.00" -> 45,
    # "3 for $5.00" -> 35, "2 for $3.00" -> 23), and one of them was LIVE ON THE PUBLISHED BOARD:
    # ground-cloves @ Family Fare read "Spice Supreme Spice Ground Cloves", size 1.25 oz, ad $45, which the
    # engine correctly divided into $36.00/oz against a real cheapest of $1.09/oz at Walmart. No price band,
    # no guard and no audit blinked, because $45 for a spice jar is absurd but not arithmetically impossible.
    # DROP, DO NOT FLIP. Freshop's own row says base_price=5.0 and unit_price=1.25 for that product, so the
    # OFFER costs $5.00 and a jar inside the offer works out at $1.25. Neither number says what ONE jar costs
    # a shopper who does not buy four, and "4 for $5.00" is very often must-buy-four. Two readings, no way to
    # choose between them: the honest output is no row. Skipping costs one board cell today (ground-cloves
    # keeps Walmart, Hy-Vee, Baker's and Fareway, and Walmart stays cheapest) and removes a 36x error.
    # If a later pass proves Family Fare honours the single price, read unit_price here and require
    # n * unit_price to reconcile with base_price before trusting it - do not simply divide.
    $priceText = [string]$it.price
    if ($priceText -and $priceText.Contains(' for ')) { continue }
    $cur  = 0.0; [void][double]::TryParse(($priceText -replace '[^0-9.]',''), [ref]$cur)
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
# flatten terms to an ordered array so a wall-clock break can queue the REMAINING terms for recovery.
# THROUGH THE LIB, NOT `[string]$_.Value` (F3, 2026-08-01). commodity-search.json now allows an ARRAY of
# terms per commodity, because 210 of 429 commodities have an FF product name that does not contain our
# single term at all - `popsicles` reaches "Popsicle Ice Pops" and never "Our Family Jr. Pops". The old
# cast did not FAIL on an array, it JOINED it: ["popsicles","ice pops"] became the one search
# "popsicles ice pops", which matches nothing while looking like an ordinary term that found nothing.
# Get-SearchTermPairs expands arrays into real separate searches; a plain string behaves exactly as before.
. (Join-Path $root 'search-terms-lib.ps1')
$termPairs = @(Get-SearchTermPairs $terms)
$termList = @($termPairs | ForEach-Object { $_.term })
$extraTerms = @($termPairs | Where-Object { -not $_.primary }).Count
if ($extraTerms -gt 0) {
  # The budget is the binding constraint (~85 of 526 terms bought per rotation), so say what the extra
  # terms cost rather than letting a longer rotation be discovered later as an unexplained slowdown.
  Write-Output ("Family Fare: {0} search term(s) across {1} commodit(y/ies) - {2} are ADDITIONAL terms on multi-term commodities and each one spends a budget slot every rotation" -f $termList.Count, @($terms.PSObject.Properties).Count, $extraTerms)
}

# ROTATE THE START (2026-07-30) - the term-budget cursor.
# The 3b-ii retest settled what Freshop's limit actually is: a per-window REQUEST BUDGET of roughly 60-70
# search terms, after which q= answers HTTP 400 outright (measured: 775 fresh rows then "API said: HTTP 400
# x169"; the 45s cooldowns demonstrably do NOT reset it). Every run used to start at term 0, so the SAME
# first ~60 terms were refreshed daily and the ~466-term tail was NEVER reached - 13 straight days of "466
# terms still empty" was not the API refusing those terms, it was us never getting to them before the budget
# died. Starting each run where the previous run's successes ENDED makes the budget sweep the whole catalogue
# across runs instead of re-buying the same prefix: full coverage in ~8 daily runs, faster if the pull is
# scheduled more than once a day (each extra run advances the cursor another budget's worth - that cadence is
# a scheduling decision, not a code one). Absent terms stay covered by carry-forward exactly as before.
# The cursor file failing to parse starts the run at 0 - fail toward the old behaviour, never toward skipping.
$cursorFile = Join-Path $OutDir 'ff-term-cursor.json'
$startIdx = 0
if (Test-Path $cursorFile) {
  try {
    $cj = Get-Content $cursorFile -Raw | ConvertFrom-Json
    $ci = [int]$cj.next_index
    if ($ci -ge 0 -and $ci -lt $termList.Count) { $startIdx = $ci }
  } catch {}
}
if ($startIdx -gt 0) {
  $termList = @($termList[$startIdx..($termList.Count-1)]) + @($termList[0..($startIdx-1)])
  Write-Output ("Family Fare: term cursor at #$startIdx of $($termList.Count) - this run's budget starts there and wraps")
}
$empty = New-Object System.Collections.Generic.List[string]
# GIVE UP WHEN THE API IS CLEARLY REFUSING US, instead of spending the whole budget proving it.
# The cooldown below (15 empties -> sleep 45s -> reset) is a THROTTLE-RIDE, not an exit: under a hard shutout
# it just loops - 15 empties, sleep, 15 more, sleep - until the wall-clock cap fires. On 2026-07-30 a run with
# a 30-minute budget did exactly that and returned ZERO items across all 526 terms: half an hour of requests,
# nothing to show, and the API pushed further away for the next caller.
# $emptyRun counts CONSECUTIVE empties and is deliberately NOT reset by a cooldown - that is the whole point,
# because a cooldown that does not help is itself the evidence. Any successful term resets it.
$ABORT_EMPTY_RUN = 60      # sustained refusal after we had been getting data
$ABORT_COLD_START = 30     # refused from the very first term - nothing has EVER come back this run
$streak = 0; $emptyRun = 0; $aborted = $false; $lastSuccessRot = -1
for ($i = 0; $i -lt $termList.Count; $i++) {
  if (Over-Cap) { for ($j = $i; $j -lt $termList.Count; $j++) { $empty.Add($termList[$j]) }; Write-Output 'Family Fare: wall-clock cap hit in main pass; remaining terms deferred to recovery'; break }
  $term = $termList[$i]
  $queries = @($term); if ($supplemental.ContainsKey($term)) { $queries += $supplemental[$term] }
  $items = @(); foreach ($q in $queries) { $items += (Get-FreshopItems $q) }
  Start-Sleep -Milliseconds 200
  if (@($items).Count -eq 0) {
    $empty.Add($term); $streak++; $emptyRun++
    $limit = if (@($script:deals).Count -eq 0) { $ABORT_COLD_START } else { $ABORT_EMPTY_RUN }
    if ($emptyRun -ge $limit) {
      for ($j = $i + 1; $j -lt $termList.Count; $j++) { $empty.Add($termList[$j]) }
      $apiSay = if ($script:apiStatus -and $script:apiStatus.Count) { ' API said: ' + (($script:apiStatus.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ', ') + '.' } else { ' API returned 200 with zero items (terms genuinely not carried, NOT a refusal).' }
      Write-Output ("Family Fare: ABORTING - " + $emptyRun + " consecutive empty terms" + $(if (@($script:deals).Count -eq 0) { ' from the first request (hard shutout)' } else { ' after ' + @($script:deals).Count + ' rows' }) + "." + $apiSay + " Continuing would burn time for nothing and push the limit out further. Carrying forward and writing what we have.")
      $aborted = $true
      break
    }
    if ($streak -ge 15) { Write-Output ("Family Fare: throttle streak ($streak empties) - cooling down 45s..."); Start-Sleep -Seconds 45; $streak = 0 }
  } else { $streak = 0; $emptyRun = 0; $lastSuccessRot = $i; Ingest-Items $items }
}
# Advance the cursor past the contiguous stretch the budget actually bought. Only main-pass successes move it:
# recovery-pass hits are re-tries of earlier empties and would drag the cursor backwards. No successes at all
# (a cold shutout) leaves the cursor where it was - re-attempting the same slice next run is correct, because
# those terms were REFUSED, not absent.
# The arithmetic itself lives in Get-FfNextCursor at the top of this file so -SelfTest can exercise it; this
# is the only caller. When the run ABORTED, the term after the last success IS the first term of the wall, so
# next_index lands on the wall's start and the walled tail gets first claim on the next window's budget.
$nextIdx = Get-FfNextCursor $startIdx $lastSuccessRot $termList.Count
if ($null -ne $nextIdx) {
  try {
    ([ordered]@{ next_index = $nextIdx; updated = (Get-Date).ToString('s'); note = 'index into the commodity-search term order where the NEXT Family Fare run starts; see the term-budget cursor comment in pull-regular-familyfare.ps1' } | ConvertTo-Json) | Set-Content $cursorFile -Encoding UTF8
    Write-Output ("Family Fare: term cursor advanced to #$nextIdx (this run bought terms #$startIdx..#$(($startIdx + $lastSuccessRot) % $termList.Count))")
  } catch { Write-Warning ('Family Fare: could not write term cursor (next run restarts at #' + $startIdx + '): ' + $_.Exception.Message) }
}
# RECOVERY PASSES: empties are rate-limit victims; wait out the throttle and retry ONCE each, up to 2 passes,
# still under the wall-clock cap. Single query per term (no inner backoff) so a hard throttle can't blow up.
# If the main pass ABORTED on a shutout, skip recovery entirely. Recovery exists to re-ask terms that were
# rate-limit victims; when the window budget is already spent, re-asking 500 of them is the same mistake again.
$pass = 0
while (-not $aborted -and $empty.Count -gt 0 -and $pass -lt 2 -and -not (Over-Cap)) {
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
  # THE ALERT USED TO LIVE HERE AND IT HAS MOVED (2026-07-31, plan item 30a1a8).
  # Writing the diagnostic is the GUARD and it stays exactly as it is. What was wrong was ALERTING off it:
  # this branch tests ONE RUN's raw collection against the best of recent MERGED files, and under the 3-hourly
  # sharded sweep a run buys ~85 of 526 terms BY DESIGN, so the branch is now permanently true and paged every
  # day about a pipeline that had taken the catalog from 1909 to 3974 items with 0 expired rows.
  # A trigger that can never be false is not a signal. The alert is re-keyed on the MERGED catalog's outcomes
  # and now sits after the carry-forward merge below, which is the first point those numbers exist.
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

# ---- IS FAMILY FARE ACTUALLY FREEZING? (re-keyed 2026-07-31, plan item 30a1a8) ----
# This is the alert that used to live inside the throttle-wipeout branch above, asking a question the sharded
# sweep made permanently unanswerable ("did ONE run capture the whole store?"). It now runs on every pull,
# reads the MERGED catalog it just wrote, and asks whether the catalog is actually degrading - see
# Test-FfCatalogDegraded at the top of this file for the three outcome tests and why each one is real news.
# The once-per-day stamp is KEPT verbatim: 9 sweeps a day must not become 9 emails, and it was seven identical
# items in the triage queue on 2026-07-30 that proved it.
try {
  $recentVerified = 0
  $cutoff = ([datetime]$todayS).AddDays(-1)
  foreach ($d in @($deals)) {
    try { if (([datetime][string]$d.as_of) -ge $cutoff) { $recentVerified++ } } catch {}
  }
  $ffState = Test-FfCatalogDegraded @($deals).Count $prevMax $expired $recentVerified
  if ($ffState.degraded) {
    $alertStamp = Join-Path $OutDir 'ff-throttle-alert.stamp'
    $sentToday = $false
    if (Test-Path $alertStamp) { $sentToday = (((Get-Content $alertStamp -Raw) + '').Trim() -eq $todayS) }
    if ($sentToday) {
      Write-Warning ("Family Fare: catalog-degradation alert already sent today ($todayS) - not re-sending (one email per day).")
    } else {
      $qDirA = Join-Path $OutDir 'throttled'
      $recent = @(Get-ChildItem (Join-Path $qDirA 'family-fare-*.throttled.json') -ErrorAction SilentlyContinue |
                  Where-Object { $_.BaseName -match '(\d{4}-\d{2}-\d{2})' -and [datetime]$Matches[1] -ge (Get-Date).AddDays(-4) })
      $body = "Family Fare's MERGED everyday catalog is degrading, not just throttled.`n`n" +
              "What tripped it:`n  - " + (($ffState.reasons) -join "`n  - ") + "`n`n" +
              "Merged catalog: $(@($deals).Count) items ($(@($deals).Count - $carried) fresh this run, $carried carried forward, $expired expired past $MaxCarryDays days, $recentVerified re-verified in the last 48h) against a best-of-recent of $prevMax. File: $file`n`n" +
              "Throttled diagnostics written on $($recent.Count) of the last 4 days - that alone is NORMAL under the 3-hourly sharded sweep (a run buys ~85 of 526 terms by design) and is no longer what this alert keys on. It fires only when the merged catalog is actually losing ground.`n`n" +
              "Freshop rate-limits several hundred sequential terms from one IP. The fix is fewer requests per window (shard the term list across the day), NOT slower pacing - a 2026-07-28 probe showed 20 terms at 200ms all succeed while a second burst all came back empty, so the budget is per-window request COUNT."
      & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'send-alert.ps1') -Subject ("Grocery: Family Fare catalog is degrading - " + $ffState.reasons.Count + " signal(s)") -Body $body | Out-Null
      # stamp only on a SENT alert: a failed send must be free to try again on the next run, or a transient
      # mail error would buy the whole day's silence.
      if ($LASTEXITCODE -eq 0) { Set-Content -Path $alertStamp -Value $todayS -Encoding ASCII }
    }
  } else {
    Write-Output ("Family Fare: catalog healthy - " + @($deals).Count + " items, $expired expired, $recentVerified re-verified in 48h (no alert)")
  }
} catch { Write-Warning ('family-fare catalog-degradation check failed: ' + $_.Exception.Message) }
