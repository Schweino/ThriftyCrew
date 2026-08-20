<#
  pull-regular-familyfare.ps1 - Pulls Family Fare EVERYDAY (non-ad) shelf prices for the tracked
  commodities, straight from Family Fare's OWN Freshop catalog (base_price). NOT Instacart.
  Output: out\regular\family-fare-regular-<date>.json  (price_type = "everyday"), which compare-deals
  ingests alongside the weekly-ad data so the true cheapest (sale OR everyday) wins.
#>
param([string]$OutDir = "", [int]$MaxMinutes = 9, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $root 'omaha-time.ps1')
# Alerts go out through Send-Alert (alert-lib.ps1), never as `powershell -File send-alert.ps1 -Body $long`:
# Windows refuses to start a process whose command line passes 32767 chars, so an oversized body did not
# arrive truncated - it did not arrive at all, and the launch error read like the CHECK had crashed. Three
# consecutive guard-blind days went unpaged that way on 2026-08-03/04/05. See alert-lib.ps1.
. (Join-Path $root 'alert-lib.ps1')
# The Freshop price rule (current-not-regular, and drop multi-buy offer text) is shared with
# probe-ingredient.ps1 so both callers cannot drift. Has its own -SelfTest carrying the founding bug.
. (Join-Path $root 'ff-price-lib.ps1')

# ---------------------------------------------------------------------------------------------------------
# THE PURE RULES, LIFTED OUT SO THEY CAN BE TESTED (2026-07-31, extended 2026-08-02).
# All of these were inline expressions buried in the middle of a network-driven script, which meant the only
# way to exercise them was to run the real pull against the real store. That is why nobody ever noticed the
# alert condition below had become structurally impossible to satisfy: there was no way to ask it a question.
# A decision that only exists inside a network-driven loop is a decision no fixture can reach.
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

# WRITE THE CATALOG WITHOUT BEING ABLE TO LOSE IT (2026-08-02, plan item 2026-08-02-91d877).
# Measured, not theorised, in this pipeline's own ff-sweep-log.txt: the 2026-08-02T07:00 window bought terms
# #458..#34 (686 rows), wrote its throttled diagnostic, ADVANCED THE CURSOR #458 -> #35 at 07:06:40, and then
# threw "Set-Content : The process cannot access the file" at 07:06:41 on the merged write. Under
# $ErrorActionPreference='Stop' that bare Set-Content took the whole run down AFTER the cursor had already
# moved, so 686 rows of fresh prices and as_of re-verifications across ~104 terms were discarded while the
# cursor skipped past those exact terms - which then waited a full ~1.2-day rotation for their next chance.
# The merged file's mtime stayed 06:18:38 while the cursor file's said 07:06:40, which is the fingerprint.
# Every merged-write failure repeats it, and unlike name-churn expiry this one genuinely pushes rows toward
# the 14-day edge. Two properties fix it, and -SelfTest can reach both:
#   1. ATOMIC AND RETRIED - write a temp file, then rename over the target, up to 5 attempts with a 2s
#      backoff. A reader can never see half a catalog, and a transient lock costs 8 seconds instead of a
#      whole window. The temp suffix is ".tmp" ON PURPOSE: out\regular is scanned with '*.json' in several
#      places, so a partial file named *.json could be read as a store - the same reasoning that moved the
#      throttled diagnostic out of out\regular entirely.
#   2. IT NEVER THROWS - it returns $true/$false and the caller decides. A failed write must not be able to
#      kill the run at whatever line it happens to be on; it has to be a VALUE the cursor decision can read.
function Write-FfJsonAtomic([string]$path, [string]$text, [int]$Attempts = 5, [int]$BackoffSec = 2) {
  $tmp = $path + '.tmp'
  for ($a = 1; $a -le $Attempts; $a++) {
    try {
      $text | Set-Content -LiteralPath $tmp -Encoding UTF8 -ErrorAction Stop
      Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
      return $true
    } catch {
      if ($a -lt $Attempts) { Start-Sleep -Seconds $BackoffSec }
    }
  }
  # Leave no half-written orphan behind, and leave the PRIOR file byte-identical: losing a window is
  # recoverable (the cursor did not move, so the next window re-buys it); corrupting the catalog is not.
  try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch {}
  return $false
}

# MAY THIS WINDOW MOVE THE CURSOR? Get-FfNextCursor says WHERE the next window would start; this says whether
# this window earned the right to say so. It did not if its purchases never landed on disk. Re-buying the same
# slice next window is the correct no-loss behaviour and is exactly what already happens on a cold shutout.
# Lifted out as its own pure function for one reason: so a fixture can ask it the question without a network,
# a file lock or a real sweep (the 2026-07-29 lesson - a fix whose self-test cannot reach the new code is not
# a fix). This is the ONLY thing allowed to authorise a cursor write.
function Get-FfCursorCommit($nextIdx, [bool]$mergedOk) {
  if ($null -eq $nextIdx) { return $null }   # cold shutout: nothing was bought, so there is nothing to commit
  if (-not $mergedOk) { return $null }       # bought, but the catalog never landed - do NOT skip those terms
  return [int]$nextIdx
}

# WHAT DOES ONE EXPIRY ACTUALLY MEAN? Three different things, and only one of them is news.
#   starved - the row's own search term has not returned a single product inside the whole carry window. The
#             sweep genuinely cannot replace this product. THIS is degradation, and it is directly actionable:
#             a starved term gets a second term in commodity-search.json (the F3 multi-term path).
#   churn   - the term is being bought fine; this particular NAME simply stopped appearing in its top-25.
#             Renames, ranking drift, delistings and the multi-buy skip all do this while Family Fare goes on
#             selling the product. Architectural, permanent, and not a fault.
#   unknown - the row predates found_by_term (or the ledger lost its entry), so starvation is UNMEASURABLE
#             for it. Never pages. Paging on the absence of a measurement is precisely the false page this
#             change exists to kill, and the class empties itself within MaxCarryDays as every carried row
#             either refreshes (gaining the field) or expires.
function Get-FfExpiryClass([string]$foundByTerm, [string]$lastSuccess, [string]$today, [int]$maxCarryDays) {
  if ([string]::IsNullOrWhiteSpace($foundByTerm)) { return 'unknown' }
  if ([string]::IsNullOrWhiteSpace($lastSuccess)) { return 'unknown' }
  $age = 9999
  try { $age = [int](([datetime]$today) - ([datetime]$lastSuccess)).TotalDays } catch { return 'unknown' }
  if ($age -gt $maxCarryDays) { return 'starved' }
  return 'churn'
}

# IS THE CATALOG ACTUALLY DEGRADING? (re-keyed 2026-07-31, plan item 30a1a8; expiry arm re-keyed 2026-08-02,
# plan item 2026-08-02-91d877)
# The old alert asked "did ONE run capture the whole store", comparing this run's raw collection against the
# best deal_count of recent MERGED files. That was the right question at one pull per day. Under the 3-hourly
# sharded sweep it is a question that can NEVER be answered yes - a run buys ~85 of 526 terms BY DESIGN - so
# it paged every single day about an architecture that was working: catalog 1909 -> 3974 items across 8
# sweeps, 0 expired, 358 board cells against a 256-cell pre-freeze baseline.
# So ask about OUTCOMES instead, on the MERGED catalog, where "Family Fare stopped refreshing" is actually
# visible. Any one of these is real news:
#   - rows are aging out of the 14-day carry ON A STARVED TERM: the catalog is losing products it cannot replace
#   - a MASS of rows aged out in one run (>2% of the catalog), whatever class they are
#   - almost nothing has been re-verified against the store in the last 24-48h: the sweep is not buying
#   - the merged catalog itself shrank materially against the best of recent files
# The recently-verified window is TWO DAYS on purpose: as_of is a date, not a timestamp, and the day's FIRST
# sweep would otherwise be judged on its own slice alone and page every morning - the same shape of bug being
# fixed here. A genuinely frozen store falls to ~0 across two days regardless.
#
# THE EXPIRY ARM, RE-KEYED 2026-08-02. It used to be a bare `expired > 0`, on the belief that any 14-day
# expiry means the sweep cannot replace products. That premise is false FOR THIS ARCHITECTURE. The merged
# catalog is a NAME-KEYED UNION of every top-25 search response since 07-19 (4,706 rows) while one full
# rotation currently yields ~3,300-3,900 unique names, so 800-1,400 rows are always living on carry-forward.
# Renames ("Chicken Breasts, Boneless & Skinless Fresh" $3.99/lb became "Our Family Boneless Skinless Chicken
# Breast Family Pack" $3.99 - same shelf, same price, new name, successor already in the catalog), top-25
# ranking drift, delistings and the multi-buy skip all retire NAMES without Family Fare losing the PRODUCT.
# A nonzero trickle of name-expiries is therefore the HEALTHY steady state of this design, which made the old
# arm the exact mirror of the bug it replaced: a trigger that at steady state can never stay false. It fired
# on 2026-08-02 for the last tranche of the 07-17..07-29 frozen-era backlog draining on schedule - 55 rows
# that backed ZERO crowns and ZERO commodities on either board (2 non-winner store entries; ground-coriander
# stayed Fareway 0.96, turkey-bacon stayed Aldi 0.325, 492 commodities before and after).
# So ask the question that IS news: has a search term stopped buying? That is measured per term in
# out\ff-term-ledger.json and attached to each row as found_by_term, so starvation stops being an inference
# from row ages and becomes a fact with a name on it. Unknown-class rows never page; see Get-FfExpiryClass.
function Test-FfCatalogDegraded([int]$mergedCount, [int]$prevMax, [int]$starvedExpired, [int]$churnExpired, [int]$recentVerified) {
  $reasons = @()
  $totalExpired = $starvedExpired + $churnExpired
  if ($starvedExpired -gt 0) { $reasons += ("$starvedExpired row(s) aged out past the 14-day carry on a STARVED search term - that term has not returned a single product inside the carry window, so the sweep genuinely cannot replace those products") }
  if ($mergedCount -gt 0 -and $totalExpired -gt ($mergedCount * 0.02)) { $reasons += ("$totalExpired row(s) aged out in ONE run against a $mergedCount-item catalog - that is a mass loss (over 2%) whatever class the rows are") }
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

  # ---- ALERT CONDITION. MUST-FIRE and its clean twin are both frozen from real runs and NEVER regenerated
  # from live data: today's numbers are copied in as literals precisely so that tomorrow's healthy catalog
  # cannot quietly make them pass by finding nothing.
  # CLEAN TWIN (c5), kept verbatim through the re-key: the 2026-07-31T04:00 sweep. One shard of a healthy
  # catalog (4269 merged items, no expiries, 1259 re-verified in the window). The trigger before it paged on
  # this every day because the run's own 566-row collection is under half the merged 4269 - by design.
  $ok = Test-FfCatalogDegraded 4269 4269 0 0 1259
  _T 'CLEAN-TWIN c5: a healthy sharded sweep does NOT page (4269 items, 0 expired, 1259 re-verified)' (-not $ok.degraded)
  # CLEAN TWIN (c1) - TODAY'S REAL FALSE PAGE, frozen. 2026-08-02T06:18: 4655 merged against a best-of-recent
  # 4706, 55 rows aged out, 3357 re-verified. Every one of those 55 was the 2026-07-18 cohort (57 rows in the
  # 08-01 file, 2 of which re-verified fresh) whose terms the sweep had bought 3+ times inside the window, and
  # they backed zero crowns and zero commodities. THIS EXACT ALERT MUST NEVER PAGE AGAIN.
  $c1 = Test-FfCatalogDegraded 4655 4706 0 55 3357
  _T "CLEAN-TWIN c1: today's real false page stays SILENT (4655/4706, 0 starved + 55 churn, 3357 re-verified)" (-not $c1.degraded)
  # MUST-FIRE m1: the same run, but three of those expiries sit on terms that have bought NOTHING for the whole
  # carry window. That is a sweep that has genuinely stopped reaching products, and it pages.
  $m1 = Test-FfCatalogDegraded 4655 4706 3 52 3357
  _T 'MUST-FIRE m1: FIRES on starvation (3 starved + 52 churn) and names the starved count' ($m1.degraded -and ($m1.reasons -join ' ') -match 'STARVED' -and ($m1.reasons -join ' ') -match '^3 row')
  # MUST-FIRE m2: the mass-expiry safety net. Even with every row classed as harmless churn, losing more than
  # 2% of the catalog in ONE run is not something a classifier gets to wave through (120 > 2% of 4655 = 93.1).
  $m2 = Test-FfCatalogDegraded 4655 4706 0 120 3357
  _T 'MUST-FIRE m2: FIRES on mass expiry even when every row is churn-class (120 of 4655 = 2.6%)' ($m2.degraded -and ($m2.reasons -join ' ') -match 'mass loss')
  # MUST-FIRE m3: the OLD founding case re-expressed. The 24 expiries of 2026-07-31T01:05 as they would look
  # if they had been starvation. The re-key must not have cost us the ability to see the original bug.
  $m3 = Test-FfCatalogDegraded 4269 4269 24 0 1259
  _T 'MUST-FIRE m3: the founding 24-expiry case still fires when those rows are starved' ($m3.degraded -and ($m3.reasons -join ' ') -match 'STARVED')
  # MUST-FIRE (kept verbatim): the sweep has stopped buying terms at all. A REAL freeze detector - do not soften.
  $d2 = Test-FfCatalogDegraded 4269 4269 0 0 12
  _T 'MUST-FIRE c5: FIRES when almost nothing was re-verified against the store (12 rows)' ($d2.degraded -and ($d2.reasons -join ' ') -match 're-verified')
  # MUST-FIRE (kept verbatim): the merged catalog itself collapsed - the original freeze, which bottomed at 207
  # board cells. Also a REAL freeze detector - do not soften.
  $d3 = Test-FfCatalogDegraded 1909 3974 0 0 1259
  _T 'MUST-FIRE c5: FIRES when the merged catalog shrinks >20% against best-of-recent (1909 vs 3974)' ($d3.degraded -and ($d3.reasons -join ' ') -match 'shrank')
  # and it must not fire on a catalog that merely grew slower than its best day
  _T 'CLEAN-TWIN c5: does NOT fire on a catalog within 20% of its best (3800 vs 3974)' (-not (Test-FfCatalogDegraded 3800 3974 0 0 1259).degraded)

  # ---- EXPIRY CLASSIFIER. What separates the two above.
  # MUST-FIRE m6, frozen from a real pair: ground-coriander's Family Fare row was found by the term
  # "ground coriander", which is one of the 467 terms the 06:18 run reported still empty. If that term's last
  # successful buy really were 2026-07-18, the row's expiry would be starvation and must be called that.
  _T 'MUST-FIRE m6: a row whose term last succeeded 15 days ago is STARVED' ((Get-FfExpiryClass 'ground coriander' '2026-07-18' '2026-08-02' 14) -eq 'starved')
  # CLEAN TWIN c4: the actual state of those 55 rows - their terms are being bought constantly, the NAMES just
  # left the top-25. Churn never pages. And a row that predates found_by_term is unknown, which never pages
  # either: during the 14-day warm-up, paging on unknown would simply recreate today's false page daily.
  _T 'CLEAN-TWIN c4: a row whose term succeeded yesterday is CHURN' ((Get-FfExpiryClass 'ground coriander' '2026-08-01' '2026-08-02' 14) -eq 'churn')
  _T 'CLEAN-TWIN c4: a row with no found_by_term is UNKNOWN (never pages)' ((Get-FfExpiryClass '' '2026-08-01' '2026-08-02' 14) -eq 'unknown')
  _T 'CLEAN-TWIN c4: a term with no ledger entry is UNKNOWN, not starved (absence of a measurement is not a measurement)' ((Get-FfExpiryClass 'ground coriander' '' '2026-08-02' 14) -eq 'unknown')
  _T 'CLEAN-TWIN c4: exactly at the carry boundary (14 days) is still CHURN, not starved' ((Get-FfExpiryClass 'ground coriander' '2026-07-19' '2026-08-02' 14) -eq 'churn')

  # ---- CURSOR COMMIT. Frozen from the 2026-08-02T07:06:41 loss: 686 rows bought across terms #458..#34, the
  # cursor written to #35, the merged write then refused by a file lock. The cursor must NOT move on that.
  _T 'MUST-FIRE m5: a failed merged write must NOT advance the cursor (Get-FfCursorCommit 35 $false -> null)' ($null -eq (Get-FfCursorCommit 35 $false))
  _T 'CLEAN-TWIN c3: a successful merged write commits the cursor (Get-FfCursorCommit 35 $true -> 35)' ((Get-FfCursorCommit 35 $true) -eq 35)
  _T 'MUST-FIRE m5: a cold shutout commits nothing even when the write succeeded (null, $true -> null)' ($null -eq (Get-FfCursorCommit $null $true))

  # ---- ATOMIC WRITE. The only fixture here that touches a disk, and it stays inside a fresh TEMP directory.
  # MUST-FIRE m4 reproduces the real incident: the target is held open with FileShare.None, exactly as a
  # concurrent reader held out\regular\family-fare-regular-2026-08-02.json at 07:06:41. Windows denies the
  # replacement, which must return FALSE and preserve the path byte-for-byte. POSIX intentionally permits
  # an atomic rename over an open inode; there the open reader must keep seeing the old complete catalog
  # while the path changes to the new complete catalog. Both platforms must leave no .tmp orphan.
  # The backoff argument is passed as 0 so a daily fixture run does not spend 8 seconds asleep; every OTHER
  # property (all 5 attempts, the non-throwing return, the byte-identity, the tmp cleanup) runs exactly as it
  # does live, and test-auditors pins the PRODUCTION defaults (5 attempts / 2s) as a source check so they
  # cannot be quietly dropped here.
  $tdir = Join-Path ([IO.Path]::GetTempPath()) ('ff-selftest-' + [guid]::NewGuid().ToString('N').Substring(0,12))
  $null = New-Item -ItemType Directory -Path $tdir -Force
  try {
    $tf = Join-Path $tdir 'family-fare-regular-2026-08-02.json'
    [IO.File]::WriteAllText($tf, '{"store":"Family Fare","deal_count":4655}')
    $before = [IO.File]::ReadAllBytes($tf)
    $lock = [IO.File]::Open($tf, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    $r4 = $true
    $lockedReaderText = $null
    try {
      $r4 = Write-FfJsonAtomic $tf '{"clobbered":true}' 5 0
      if ($r4) {
        $lock.Position = 0
        $reader = [IO.StreamReader]::new($lock, [Text.Encoding]::UTF8, $true, 1024, $true)
        try { $lockedReaderText = $reader.ReadToEnd() } finally { $reader.Dispose() }
      }
    } finally { $lock.Close(); $lock.Dispose() }
    $after = [IO.File]::ReadAllBytes($tf)
    $same = ($after.Length -eq $before.Length)
    if ($same) { for ($bi = 0; $bi -lt $before.Length; $bi++) { if ($after[$bi] -ne $before[$bi]) { $same = $false; break } } }
    if ($env:OS -eq 'Windows_NT') {
      _T 'MUST-FIRE m4/windows: a locked target returns FALSE, leaves the prior catalog byte-identical, and leaves no .tmp orphan' ((-not $r4) -and $same -and (-not (Test-Path ($tf + '.tmp'))))
    } else {
      $afterText = [Text.Encoding]::UTF8.GetString($after)
      _T 'MUST-FIRE m4/posix: atomic rename gives the open reader the old complete catalog and the path the new complete catalog, with no .tmp orphan' ($r4 -and ($lockedReaderText -match 'deal_count') -and ($afterText -match 'clobbered') -and (-not (Test-Path ($tf + '.tmp'))))
    }
    # CLEAN TWIN c2: the ordinary case still works, replaces the content, and cleans up after itself.
    $r2 = Write-FfJsonAtomic $tf '{"clobbered":true}' 5 0
    $txt = [IO.File]::ReadAllText($tf)
    _T 'CLEAN-TWIN c2: an unlocked target returns TRUE, content is replaced, tmp file is gone' ($r2 -and ($txt -match 'clobbered') -and (-not (Test-Path ($tf + '.tmp'))))
    # and it must create a file that did not exist yet (the first run of a new day)
    $tf2 = Join-Path $tdir 'family-fare-regular-2026-08-03.json'
    $r3 = Write-FfJsonAtomic $tf2 '{"fresh":true}' 5 0
    _T 'CLEAN-TWIN c2: a brand-new target is created (first write of a new day)' ($r3 -and (Test-Path $tf2))
  } finally { Remove-Item -LiteralPath $tdir -Recurse -Force -ErrorAction SilentlyContinue }

  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$regDir = Join-Path $OutDir 'regular'
if (-not (Test-Path $regDir)) { New-Item -ItemType Directory -Force $regDir | Out-Null }
$UA = @{ 'User-Agent' = 'Mozilla/5.0' }
$todayS = Get-OmahaDateKey
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
      # READ THE BODY, NOT JUST THE STATUS - this is the missing half of the note above.
      # That note concluded "HTTP 400, not 429" and therefore "not ip-blocked", because it
      # only ever saw the status line. Measured 2026-08-20: the 400's BODY is
      # {"error_code":429}. It IS a rate limit; Freshop just dresses it as a 400, which is
      # precisely why three weeks of looking at status codes pointed away from the answer.
      # Windows PowerShell 5.1 has already consumed the error stream by the time this catch
      # runs, so GetResponseStream() reads empty - the body is in ErrorDetails.Message.
      $ec = ''
      try {
        $eb = [string]$_.ErrorDetails.Message
        if ($eb -match '"error_code"\s*:\s*(\d+)') { $ec = $Matches[1] }
      } catch {}
      $key = if ($sc -and $ec) { "HTTP $sc (error_code $ec" + $(if ($ec -eq '429') { ' = RATE LIMITED)' } else { ')' }) }
             elseif ($sc) { "HTTP $sc" }
             else { 'no response/timeout' }
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
# $term is the SEARCH TERM this response came back from, and it is stamped onto every row (see found_by_term
# below). Supplemental queries pass the PRIMARY term on purpose: "simply orange juice" exists only as an extra
# query on the "orange juice" term, and the ledger tracks terms, not queries.
function Ingest-Items($items, $term) {
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
    # The rule above now lives in ff-price-lib.ps1, because probe-ingredient.ps1 (the Recipe Hunter's
    # targeted single-term probe) reads the same Freshop rows and has to make the same call. A second inline
    # copy is how a corrected rule ships to one caller and not the other. $null means "no honest price".
    $val = Get-FfPrice $it
    if ($null -eq $val) { continue }
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
    # WHICH TERM FOUND THIS ROW (2026-08-02). Additive metadata; compare-deals and every board consumer ignore
    # it. It exists so that when this row eventually ages out of the 14-day carry, the expiry can be
    # CLASSIFIED instead of guessed at: rows carry their own provenance, and out\ff-term-ledger.json carries
    # each term's last successful buy, so "the sweep can no longer reach this product" becomes a measurement
    # rather than an inference from a date. Without it, starvation and ordinary name-churn are the same event.
    if ($term) { $row['found_by_term'] = [string]$term }
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
# THE PER-TERM LEDGER (2026-08-02): term -> the last date that term's query came back with products.
# This is the structural half of the alert re-key. Rows record which term found them; this records when each
# term last worked. Between them, "a product aged out because the sweep can no longer reach it" is a MEASURED
# statement about a named term instead of an inference from a row's age.
# MEASURED, NEVER STAMPED. Entries are written from the receipt inside the buy loop - the moment a query is
# observed to return items - and nowhere else. The temptation is to bulk-stamp every term in the rotation at
# the end of a run, which would be the dates-written-not-measured trap in its purest form: the builder writing
# the number the freshness check will later read back and believe. A term that was never asked, or that
# answered empty, gets no entry today and keeps whatever it last honestly earned.
# It is a durable map: keys are never dropped, so a term that starves keeps its old date and stays visible.
$ledgerFile = Join-Path $OutDir 'ff-term-ledger.json'
$ledger = @{}
if (Test-Path $ledgerFile) {
  try {
    $lj = Get-Content $ledgerFile -Raw | ConvertFrom-Json
    if ($lj -and $lj.terms) { foreach ($p in $lj.terms.PSObject.Properties) { if ($p.Value) { $ledger[[string]$p.Name] = [string]$p.Value } } }
  } catch { Write-Warning ('Family Fare: term ledger unreadable, starting a fresh one (expiries classify as unknown until it warms up): ' + $_.Exception.Message) }
}
$termSuccess = @{}
$termAttempted = @{}
$termDeferred = @{}

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
# TERM BUDGET (capture policy, 2026-08-20). The wall-clock cap alone let one run buy
# 60-90 terms and the estate ran TWO passes a day, which is what put us over Freshop's
# window and got the search endpoint answering 400/error_code 429. The budget is now
# derived, not guessed: total terms / 90 days, plus one extra for each sale reverting
# today. See capture-policy.ps1 - the single place that decides this for every store.
$script:TermBudget = [int]::MaxValue
try {
  . (Join-Path $root 'capture-policy.ps1')
  $plan = Get-CapturePlan -Store 'Family Fare' -Today $todayS
  $script:TermBudget = [int]$plan.TermBudget
  # Emit the worklist too, so this store's slice is recorded the same way the walled
  # stores' is. One shape for all seven means an audit can ask "what was this store
  # asked for on that day?" and get an answer regardless of how it was fetched.
  try { $null = Write-CaptureWorklist -Store 'Family Fare' -Today $todayS -OutDir $OutDir } catch { }
  Write-Output ("Family Fare: capture-policy budget = " + $script:TermBudget + " term(s) today (" + $plan.RotationTerms + " rotation + " + $plan.SaleExpiries.Count + " sale expiry; quarter " + $plan.QuarterDays + "d)")
} catch {
  # A policy that cannot load must NOT silently become "unlimited" - that is the state
  # we are fixing. Fall back to the quarter rate rather than the old free-for-all.
  $script:TermBudget = 7
  Write-Warning ("Family Fare: capture-policy.ps1 did not load (" + $_.Exception.Message + ") - falling back to a conservative 7-term budget")
}
$bought = 0
for ($i = 0; $i -lt $termList.Count; $i++) {
  if ($bought -ge $script:TermBudget) {
    for ($j = $i; $j -lt $termList.Count; $j++) { $empty.Add($termList[$j]); $termDeferred[$termList[$j]] = 'term budget reached before request' }
    Write-Output ("Family Fare: term budget reached (" + $bought + " bought) - stopping the main pass. This is the policy working, not a failure.")
    break
  }
  if (Over-Cap) { for ($j = $i; $j -lt $termList.Count; $j++) { $empty.Add($termList[$j]); $termDeferred[$termList[$j]] = 'wall-clock cap before request' }; Write-Output 'Family Fare: wall-clock cap hit in main pass; remaining terms deferred to recovery'; break }
  $term = $termList[$i]
  $termAttempted[$term] = $true
  $queries = @($term); if ($supplemental.ContainsKey($term)) { $queries += $supplemental[$term] }
  $items = @(); foreach ($q in $queries) { $items += (Get-FreshopItems $q) }
  Start-Sleep -Milliseconds 200
  if (@($items).Count -eq 0) {
    $empty.Add($term); $streak++; $emptyRun++
    $limit = if (@($script:deals).Count -eq 0) { $ABORT_COLD_START } else { $ABORT_EMPTY_RUN }
    if ($emptyRun -ge $limit) {
      for ($j = $i + 1; $j -lt $termList.Count; $j++) { $empty.Add($termList[$j]); $termDeferred[$termList[$j]] = 'API refusal abort before request' }
      $apiSay = if ($script:apiStatus -and $script:apiStatus.Count) { ' API said: ' + (($script:apiStatus.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ', ') + '.' } else { ' API returned 200 with zero items (terms genuinely not carried, NOT a refusal).' }
      Write-Output ("Family Fare: ABORTING - " + $emptyRun + " consecutive empty terms" + $(if (@($script:deals).Count -eq 0) { ' from the first request (hard shutout)' } else { ' after ' + @($script:deals).Count + ' rows' }) + "." + $apiSay + " Continuing would burn time for nothing and push the limit out further. Carrying forward and writing what we have.")
      $aborted = $true
      break
    }
    if ($streak -ge 15) { Write-Output ("Family Fare: throttle streak ($streak empties) - cooling down 45s..."); Start-Sleep -Seconds 45; $streak = 0 }
  } else { $streak = 0; $emptyRun = 0; $lastSuccessRot = $i; $termSuccess[$term] = $todayS; $bought++; Ingest-Items $items $term }
}
# Advance the cursor past the contiguous stretch the budget actually bought. Only main-pass successes move it:
# recovery-pass hits are re-tries of earlier empties and would drag the cursor backwards. No successes at all
# (a cold shutout) leaves the cursor where it was - re-attempting the same slice next run is correct, because
# those terms were REFUSED, not absent.
# The arithmetic itself lives in Get-FfNextCursor at the top of this file so -SelfTest can exercise it; this
# is the only caller. When the run ABORTED, the term after the last success IS the first term of the wall, so
# next_index lands on the wall's start and the walled tail gets first claim on the next window's budget.
#
# WHERE THIS USED TO BE WRITTEN, AND WHY IT MOVED (2026-08-02). The cursor file was written HERE, before the
# recovery passes and before the merged catalog was written at all. On 2026-08-02T07:06:40 it duly recorded
# #35 - and one second later the merged write was refused by a file lock and the run died with 686 rows of
# purchases in memory and nothing on disk. The cursor had certified a window that produced nothing.
# The arithmetic stays exactly where it was and stays pure; only the COMMIT moves, down past the merged write,
# behind Get-FfCursorCommit. Compute here, commit there.
$nextIdx = Get-FfNextCursor $startIdx $lastSuccessRot $termList.Count
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
    if (Over-Cap) { $still.Add($term); $termDeferred[$term] = 'wall-clock cap before recovery request'; continue }
    $termAttempted[$term] = $true
    $items = Get-FreshopItems $term; Start-Sleep -Milliseconds 250
    if (@($items).Count -eq 0) { $still.Add($term) } else { $termSuccess[$term] = $todayS; Ingest-Items $items $term }
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
  # ATOMIC AND NON-FATAL (2026-08-02). This was a bare Set-Content under $ErrorActionPreference='Stop', which
  # is the same class as the merged-write failure below and sits BEFORE it: a lock on the diagnostic would
  # take down a run that had already bought a full window of real prices. A diagnostic must never be able to
  # kill the thing it is diagnosing, so its failure is a warning and the run carries on to the merge.
  if (-not (Write-FfJsonAtomic $pfile (([ordered]@{ store='Family Fare'; week_of=$todayS; price_type='everyday'; throttled=$true; deal_count=@($deals).Count; empty_terms=@($empty); deals=$deals } | ConvertTo-Json -Depth 6)))) {
    Write-Warning ("Family Fare: could not write the throttled diagnostic to $pfile (locked?) - continuing to the merge, which is the part that matters.")
  }
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
# MUST track capture-policy's quarter. At a 90-day rotation a term is only revisited
# every ~85 days, so a 14-day carry would expire ~85% of the catalog before its turn
# came round again - the rotation and the expiry are two halves of one decision and
# cannot be set independently. Read from the policy so they can never drift apart.
$MaxCarryDays = 90
try { . (Join-Path $root 'capture-policy.ps1'); $MaxCarryDays = Get-PolicyMaxCarryDays } catch { }
$carried = 0; $expired = 0
# EXPIRY CLASSIFICATION (2026-08-02). Counted here, not inferred later. See Get-FfExpiryClass for what the
# three classes mean and why only one of them is allowed to page. The ledger has already been merged with
# this run's measured successes by the time the carry loop runs, so a term bought minutes ago reads as fresh.
$expStarved = 0; $expChurn = 0; $expUnknown = 0
$starvedTerms = @{}
foreach ($k in $termSuccess.Keys) { $ledger[$k] = $termSuccess[$k] }
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
  # found_by_term joined this list on 2026-08-02 for the same reason: a carried row that forgets which term
  # found it can never have its expiry classified, and the classifier is the whole basis of the re-keyed alert.
  # Dropping it here would silently return every carried row to the "unknown" class forever.
  foreach ($k in @('current_price', 'base_price', 'marked_down', 'canonical_url', 'product_id', 'found_by_term')) { if ($null -ne $r.$k) { $h[$k] = $r.$k } }
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
    if ($age -gt $MaxCarryDays) {
      $expired++
      $ft = [string]$d.found_by_term
      $cls = Get-FfExpiryClass $ft ([string]$ledger[$ft]) $todayS $MaxCarryDays
      if ($cls -eq 'starved') { $expStarved++; $starvedTerms[$ft] = $true }
      elseif ($cls -eq 'churn') { $expChurn++ }
      else { $expUnknown++ }
      continue
    }
    $have[$k] = $true
    [void]$rows.Add((Norm-Row $d $asOf $true))
    $carried++
  }
}
$deals = $rows.ToArray()

# AUTHORITATIVE WORKLIST LEDGER. This is the actual rotated search worklist, not buckets inferred from
# whatever rows happened to survive normalization. A zero-result Freshop response is deliberately
# "rejected", not "empty": the endpoint uses the same shape for a genuine miss and a throttled refusal.
# Only a returned product proves success; a term never requested is explicitly not_attempted.
$captureTerms = New-Object System.Collections.ArrayList
for ($termOrdinal = 0; $termOrdinal -lt $termList.Count; $termOrdinal++) {
  $ct = [string]$termList[$termOrdinal]
  $rowCount = @($deals | Where-Object { [string]$_.found_by_term -eq $ct -and -not $_.carried_forward }).Count
  if ($termSuccess.ContainsKey($ct)) {
    [void]$captureTerms.Add([ordered]@{ term=$ct; ordinal=$termOrdinal; outcome='success'; row_count=$rowCount })
  } elseif ($termAttempted.ContainsKey($ct)) {
    [void]$captureTerms.Add([ordered]@{ term=$ct; ordinal=$termOrdinal; outcome='rejected'; row_count=0; reason='request returned no product rows; Freshop does not distinguish a true empty from throttle refusal' })
  } else {
    $reason = if ($termDeferred.ContainsKey($ct)) { [string]$termDeferred[$ct] } else { 'not reached in this bounded rotation window' }
    [void]$captureTerms.Add([ordered]@{ term=$ct; ordinal=$termOrdinal; outcome='not_attempted'; row_count=0; reason=$reason })
  }
}

$out = [ordered]@{ store='Family Fare'; week_of=$todayS; price_type='everyday'; price_mode='pickup'; mode_verified=$todayS; coverage_mode='partial'; source='Freshop catalog base_price (store_id 6401, Omaha), NOT Instacart'; deal_count=@($deals).Count; fresh_count=(@($deals).Count - $carried); carried_count=$carried; expired_count=$expired; expired_starved=$expStarved; expired_churn=$expChurn; expired_unknown=$expUnknown; max_carry_days=$MaxCarryDays; empty_terms=@($empty); capture_terms=$captureTerms.ToArray(); deals=$deals }

# THE ONE WRITE THIS RUN EXISTS TO PRODUCE. Atomic, retried, and NON-FATAL - see Write-FfJsonAtomic. Under the
# old bare Set-Content this line threw at 2026-08-02T07:06:41 and took 686 rows of purchases down with it,
# AFTER the cursor had already been advanced past the terms that bought them.
$mergedOk = Write-FfJsonAtomic $file ($out | ConvertTo-Json -Depth 6)
Write-Output ("Family Fare everyday prices: " + @($deals).Count + " catalog items (" + (@($deals).Count - $carried) + " fresh, " + $carried + " carried forward, " + $expired + " expired past $MaxCarryDays d [" + $expStarved + " starved, " + $expChurn + " churn, " + $expUnknown + " unknown]; " + $empty.Count + " terms still empty) -> " + $file)
if ($starvedTerms.Count) { Write-Warning ("Family Fare: STARVED term(s) behind those expiries (no successful buy inside the " + $MaxCarryDays + "-day carry): " + ((($starvedTerms.Keys | Sort-Object) | Select-Object -First 40) -join ', ')) }

# CURSOR AND LEDGER COMMIT TOGETHER, AND ONLY BEHIND A LANDED CATALOG.
# The catalog, the cursor and the ledger are one fact about one window: these terms were bought, these rows
# are the result, the next window starts after them. Committing the cursor without the catalog is what threw
# away 686 rows; committing the ledger without the catalog would record buys whose rows never landed, which
# would then read as healthy churn on a later expiry. So all three move together or none of them do.
if (-not $mergedOk) {
  Write-Warning ("Family Fare: MERGED WRITE FAILED after 5 attempts - " + $file + " is still the previous run's file and this window's " + (@($deals).Count - $carried) + " fresh row(s) did NOT land. The term cursor is deliberately LEFT AT #" + $startIdx + " so the next window re-buys terms #" + $startIdx + "..#" + (($startIdx + [math]::Max($lastSuccessRot,0)) % [math]::Max($termList.Count,1)) + " instead of skipping them. Nothing is lost; the window is simply repeated.")
  exit 1
}
$commitIdx = Get-FfCursorCommit $nextIdx $mergedOk
if ($null -ne $commitIdx) {
  if (Write-FfJsonAtomic $cursorFile (([ordered]@{ next_index = $commitIdx; updated = (Get-Date).ToString('s'); note = 'index into the commodity-search term order where the NEXT Family Fare run starts; only written after the merged catalog has landed - see the cursor-commit comment in pull-regular-familyfare.ps1' } | ConvertTo-Json))) {
    Write-Output ("Family Fare: term cursor advanced to #$commitIdx (this run bought terms #$startIdx..#$(($startIdx + $lastSuccessRot) % $termList.Count), merged catalog landed)")
  } else { Write-Warning ('Family Fare: merged catalog landed but the term cursor could not be written (next run restarts at #' + $startIdx + ' and re-buys this slice - no rows are lost).') }
}
# The ledger is a full rewrite of a merged map, so a failed write costs the run's new dates and nothing else:
# every term simply keeps its last honestly-earned date and re-earns today's on the next window.
if ($ledger.Count) {
  $ledgerDoc = [ordered]@{ store='Family Fare'; updated=(Get-Date).ToString('s'); note='term -> the last date that search term returned products. Written ONLY from measured receipt inside the buy loop, never bulk-stamped. Used to classify a 14-day carry expiry as starved / churn / unknown; see Get-FfExpiryClass in pull-regular-familyfare.ps1.'; term_count=$ledger.Count; terms=[ordered]@{} }
  foreach ($k in ($ledger.Keys | Sort-Object)) { $ledgerDoc.terms[[string]$k] = [string]$ledger[$k] }
  if (-not (Write-FfJsonAtomic $ledgerFile ($ledgerDoc | ConvertTo-Json -Depth 4))) {
    Write-Warning ('Family Fare: could not write the term ledger to ' + $ledgerFile + ' - expiry classification falls back to unknown (which never pages) until it writes.')
  }
}

# ---- IS FAMILY FARE ACTUALLY FREEZING? (re-keyed 2026-07-31, plan item 30a1a8) ----
# This is the alert that used to live inside the throttle-wipeout branch above, asking a question the sharded
# sweep made permanently unanswerable ("did ONE run capture the whole store?"). It now runs on every pull,
# reads the MERGED catalog it just wrote, and asks whether the catalog is actually degrading - see
# Test-FfCatalogDegraded at the top of this file for the four outcome tests and why each one is real news.
# It runs only on a run whose merged catalog actually LANDED (2026-08-02): a failed write exits above this
# point, because paging about the outcomes of a catalog that never reached disk is noise about a file that
# does not exist, and the write failure itself is already loud in the sweep log at rc=1.
# The once-per-day stamp is KEPT verbatim: 9 sweeps a day must not become 9 emails, and it was seven identical
# items in the triage queue on 2026-07-30 that proved it.
try {
  $recentVerified = 0
  $cutoff = ([datetime]$todayS).AddDays(-1)
  foreach ($d in @($deals)) {
    try { if (([datetime][string]$d.as_of) -ge $cutoff) { $recentVerified++ } } catch {}
  }
  $ffState = Test-FfCatalogDegraded @($deals).Count $prevMax $expStarved $expChurn $recentVerified
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
      # NAME THE STARVED TERMS. A starved term is the one degradation signal that is directly actionable: it
      # gets a second search term in commodity-search.json (the F3 multi-term path), which is a five-minute
      # fix. An email that says "55 rows expired" sends the reader back into the data to find out which; an
      # email that says "these 3 terms have bought nothing in 14 days" hands them the change.
      $starvedLine = if ($starvedTerms.Count) { "STARVED TERMS (no successful buy in $MaxCarryDays days - each one is a candidate for a second search term in commodity-search.json):`n  - " + ((($starvedTerms.Keys | Sort-Object) | Select-Object -First 40) -join "`n  - ") + "`n`n" } else { '' }
      $body = "Family Fare's MERGED everyday catalog is degrading, not just throttled.`n`n" +
              "What tripped it:`n  - " + (($ffState.reasons) -join "`n  - ") + "`n`n" + $starvedLine +
              "Merged catalog: $(@($deals).Count) items ($(@($deals).Count - $carried) fresh this run, $carried carried forward, $expired expired past $MaxCarryDays days [$expStarved starved, $expChurn churn, $expUnknown unknown], $recentVerified re-verified in the last 48h) against a best-of-recent of $prevMax. File: $file`n`n" +
              "Expiry classes: STARVED means the row's own search term has returned nothing for the whole carry window and the sweep genuinely cannot replace that product. CHURN means the term is being bought fine and only the NAME left the store's top-25 (a rename, a ranking shift, a delisting, or the multi-buy skip) - the catalog is a name-keyed union, so a trickle of those is the healthy steady state and does NOT page on its own. UNKNOWN means the row predates the found_by_term field, so it cannot be classified yet; it never pages and the class empties itself within $MaxCarryDays days.`n`n" +
              "Throttled diagnostics written on $($recent.Count) of the last 4 days - that alone is NORMAL under the 3-hourly sharded sweep (a run buys ~85 of 526 terms by design) and is no longer what this alert keys on. It fires only when the merged catalog is actually losing ground.`n`n" +
              "Freshop rate-limits several hundred sequential terms from one IP. The fix is fewer requests per window (shard the term list across the day), NOT slower pacing - a 2026-07-28 probe showed 20 terms at 200ms all succeed while a second burst all came back empty, so the budget is per-window request COUNT."
      Send-Alert -Subject ("Grocery: Family Fare catalog is degrading - " + $ffState.reasons.Count + " signal(s)") -Body $body | Out-Null
      # stamp only on a SENT alert: a failed send must be free to try again on the next run, or a transient
      # mail error would buy the whole day's silence.
      if ($LASTEXITCODE -eq 0) { Set-Content -Path $alertStamp -Value $todayS -Encoding ASCII }
    }
  } else {
    Write-Output ("Family Fare: catalog healthy - " + @($deals).Count + " items, $expired expired, $recentVerified re-verified in 48h (no alert)")
  }
} catch { Write-Warning ('family-fare catalog-degradation check failed: ' + $_.Exception.Message) }
