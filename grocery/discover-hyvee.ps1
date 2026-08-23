<#
  discover-hyvee.ps1 - give Hy-Vee a DISCOVERY path, because today it has none.

  THE PROBLEM
  -----------
  `pull-regular-hyvee.ps1` is a REFRESH, not a pull - grep it for "search" and there are zero hits. Its
  work list comes from exactly two closed sets: yesterday's own `hyvee-regular-*.json`, and the Hy-Vee
  entries in `product-urls.json`. **A product that is not already in the file and has no stored link can
  never enter.** 1,538 rows is not a bound, it is a FIXED POINT. Measured over 34 commodities: the store
  offers 885 qualifying products and we hold 95 - **89.3% absent** - and 59% of the Hy-Vee column is
  decided from two candidates or fewer. That is the dominant defect class on the board.

  WHY THIS WRITES A DOCKET AND NOT THE FEED
  -----------------------------------------
  The whole point of discovery is to surface products that BEAT what we hold, and those are exactly the
  ones that can take a crown - so an unreviewed discovery path is a machine for installing wrong cheapest
  prices. The Family Fare browse test flipped 26 crowns, two thirds to the wrong product, and
  `audit-food-category` caught 0 of them.

  For Family Fare that risk is contained by `aisle-test.ps1`, which reads the store's own shelf path out
  of `canonical_url`. **Hy-Vee gives us no such signal, and this was measured, not assumed** (2026-08-01):
    * the search result carries NO category/department field (`analytics` comes back empty)
    * the response DOES expose a CATEGORY facet - for "baking soda" it lists BAKING_SODA (3),
      CAT_LITTER (1), FACE_WASHES_AND_SCRUBS - so the store clearly knows
    * but passing that facet back as a `searchFilters` constraint is SILENTLY IGNORED. Three request
      shapes were tried; all returned the identical unfiltered 10 results with the cat litter still in
      them. A filter that looks applied and is not is worse than no filter, so nothing here may depend
      on it. If a future Hy-Vee API exposes a real per-product category, THAT is when discovery earns
      the right to write straight into the feed.

  So this script stops one step short: it finds the net-new candidates and writes them to a docket for
  adjudication. Nothing it produces reaches a board on its own.

  WHERE THE DOCKET GOES (2026-08-01). build-arrivals-docket.ps1 lists it as a PROSPECTS section - the same
  desk, the same reader, the same cohort-divergence score as a product that already arrived - and
  adjudicate-discovery.ps1 records the ruling. A settled candidate is dropped here rather than surfaced
  again: a review queue that re-asks a question a human already answered teaches its reader to skim it.

  WHAT IT KEEPS
  -------------
  A candidate must (1) match the searched commodity's own include and survive its excludes - the same
  rule filter that keeps prime-batch-headless surgical, (2) not already be in the Hy-Vee feed, and
  (3) BEAT the per-unit we currently hold for that commodity at Hy-Vee, because a candidate that loses on
  price changes no verdict and is not worth a human's attention.

  BOUNDED AND ROTATING. Runtime is the real constraint on the Hy-Vee side (~598 ms/product), so this takes
  a slice of the term list per run and advances a cursor, the same shape the Family Fare puller uses. It
  never walks all 526 terms in one pass.

  Usage:
    .\discover-hyvee.ps1 -SelfTest
    .\discover-hyvee.ps1 -Slice 40            discover across the next 40 terms, advance the cursor
    .\discover-hyvee.ps1 -Ids apples,coffee   discover for named commodities, cursor untouched
#>
param(
  [int]$Slice = 40,
  [string[]]$Ids = @(),
  [int]$PageSize = 90,
  [double]$MinBeatPct = 2,
  # HOW MANY SEARCHES AT ONCE (2026-08-23). This script was 165 s of the inspect fan-out's 171 s
  # wall - 96% of it - so every other advisory audit finished and sat waiting on this one lane.
  # It is not compute: it is $Slice sequential HTTP POSTs to Hy-Vee, each followed by a deliberate
  # 400 ms pace.
  # FOUR, NOT SIXTEEN, AND THE REASON IS NOT PERFORMANCE. The pacing is politeness to somebody
  # else's store API, and this estate has already been walled by one (Walmart) and rate-shaped by
  # another. Each worker keeps the SAME 400 ms gap between its own requests, so the effective rate
  # goes from ~0.24 req/s to ~1 req/s - a fourfold increase against a third party, deliberately
  # chosen to be small. Raising this is a decision about a vendor relationship, not a tuning knob.
  [int]$MaxParallel = 4,
  [switch]$SelfTest,
  [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }

# ---- the decision, isolated so it is testable without the network ------------------------------------
# Split out deliberately: the founding risk of this script is what it CHOOSES to surface, and a choice
# that can only be exercised by hitting a live store API cannot be fixtured.
function Test-Candidate {
  param([string]$Name, [double]$PerUnit, [double]$HeldPerUnit, [hashtable]$HaveNames, $Rx, $Ex, [double]$MinBeatPct = 2)
  if (-not $Name) { return @{ keep = $false; why = 'no name' } }
  if ($PerUnit -le 0) { return @{ keep = $false; why = 'no usable per-unit' } }
  if ($HaveNames.ContainsKey($Name.Trim().ToLower())) { return @{ keep = $false; why = 'already in the Hy-Vee feed' } }
  $hit = $false
  foreach ($r in @($Rx)) { if ($r.IsMatch($Name)) { $hit = $true; break } }
  if (-not $hit) { return @{ keep = $false; why = 'no include matches - off-target search result' } }
  foreach ($x in @($Ex)) { if ($x.IsMatch($Name)) { return @{ keep = $false; why = "excluded by the commodity's own rule" } } }
  # BEAT-WHAT-WE-HOLD, BY A MARGIN. A candidate that does not beat the held price changes no verdict, so
  # surfacing it is noise. HeldPerUnit <= 0 means we hold NOTHING at this store, and then any real match
  # is news. The margin exists because the first live run surfaced a 0.0%-better row - the same Hy-Vee
  # olive oil in a different size, equal to four decimal places - which is a rounding artefact, not a
  # find. Anything under the margin cannot justify a human reading it.
  if ($HeldPerUnit -gt 0 -and $PerUnit -ge ($HeldPerUnit * (1 - ($MinBeatPct / 100)))) { return @{ keep = $false; why = "does not beat what we hold by at least $MinBeatPct%" } }
  return @{ keep = $true; why = if ($HeldPerUnit -gt 0) { 'beats the held price' } else { 'we hold nothing here' } }
}

if ($SelfTest) {
  $rx = @([regex]::new('baking\s+soda', 'IgnoreCase'))
  $ex = @([regex]::new('\blitter\b', 'IgnoreCase'), [regex]::new('toothpaste', 'IgnoreCase'))
  $have = @{ 'hy-vee pure baking soda' = $true }
  $bad = 0
  # MUST-FIRE: the founding defect class. Hy-Vee's own "baking soda" search returns cat litter, and on
  # 2026-08-01 a litter product WAS holding the live baking-soda crown at another store. It is cheaper
  # than what we hold, so only the exclude stands between it and a docket entry.
  $r = Test-Candidate -Name 'Hy-Vee Unscented Clumping Cat Litter with Baking Soda' -PerUnit 0.03 -HeldPerUnit 0.08 -HaveNames $have -Rx $rx -Ex $ex
  if ($r.keep) { Write-Output '  X MUST-FIRE: cat litter must never reach the docket as baking soda'; $bad++ }
  $r = Test-Candidate -Name 'Crest Whitening Baking Soda & Peroxide Toothpaste, 2 Count' -PerUnit 0.01 -HeldPerUnit 0.08 -HaveNames $have -Rx $rx -Ex $ex
  if ($r.keep) { Write-Output '  X MUST-FIRE: toothpaste must never reach the docket as baking soda'; $bad++ }
  # CLEAN TWINS
  $r = Test-Candidate -Name 'ARM & HAMMER Baking Soda, 2 lb Box' -PerUnit 0.05 -HeldPerUnit 0.08 -HaveNames $have -Rx $rx -Ex $ex
  if (-not $r.keep) { Write-Output "  X CLEAN-TWIN: a real cheaper baking soda must reach the docket - got: $($r.why)"; $bad++ }
  $r = Test-Candidate -Name 'ARM & HAMMER Baking Soda, 1 lb Box' -PerUnit 0.05 -HeldPerUnit 0 -HaveNames $have -Rx $rx -Ex $ex
  if (-not $r.keep) { Write-Output "  X CLEAN-TWIN: with nothing held, any real match is news - got: $($r.why)"; $bad++ }
  # noise suppression
  $r = Test-Candidate -Name 'Hy-Vee Pure Baking Soda 17 oz' -PerUnit 0.0799 -HeldPerUnit 0.08 -HaveNames @{} -Rx $rx -Ex $ex
  if ($r.keep) { Write-Output '  X a 0.1%-better row is a rounding artefact, not a find'; $bad++ }
  $r = Test-Candidate -Name 'ARM & HAMMER Baking Soda, 4 lb Box' -PerUnit 0.09 -HeldPerUnit 0.08 -HaveNames $have -Rx $rx -Ex $ex
  if ($r.keep) { Write-Output '  X a candidate that does not beat the held price must not be surfaced'; $bad++ }
  $r = Test-Candidate -Name 'Hy-Vee Pure Baking Soda' -PerUnit 0.01 -HeldPerUnit 0.08 -HaveNames $have -Rx $rx -Ex $ex
  if ($r.keep) { Write-Output '  X a product already in the feed is not a discovery'; $bad++ }
  if ($bad) { Write-Output "discover-hyvee SELFTEST: FAILED ($bad)"; exit 2 }
  Write-Output 'discover-hyvee SELFTEST: 7/7 pass (cat litter + toothpaste refused, real cheaper kept, nothing-held kept, non-beating/marginal/already-held suppressed)'
  exit 0
}

# ---- live -------------------------------------------------------------------------------------------
. (Join-Path $root 'pu-lib.ps1')
. (Join-Path $root 'discovery-lib.ps1')
. (Join-Path $root 'search-terms-lib.ps1')
$verdicts = Get-DiscoveryVerdicts (Join-Path $root 'discovery-verdicts.json')
$coms = ConvertFrom-Json (Get-Content (Join-Path $root 'commodities.json') -Raw)
$terms = (ConvertFrom-Json (Get-Content (Join-Path $root 'commodity-search.json') -Raw)).terms
$comById = @{}; foreach ($c in $coms) { $comById[[string]$c.id] = $c }

$feedF = Get-ChildItem (Join-Path $OutDir 'regular\hyvee-regular-*.json') -EA SilentlyContinue |
Where-Object { $_.BaseName -match '^hyvee-regular-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
if (-not $feedF) { Write-Output 'BLIND: no hyvee-regular file - cannot tell new from held'; exit 3 }
$feed = ConvertFrom-Json (Get-Content $feedF.FullName -Raw)
$feedRows = @($feed.deals); if (-not $feedRows.Count) { $feedRows = @($feed) }
$haveNames = @{}
foreach ($fr in $feedRows) { if ($fr.item) { $haveNames[([string]$fr.item).Trim().ToLower()] = $true } }

# what we currently hold per commodity at Hy-Vee, from the board (both boards - see the recipe-board note)
$held = @{}
$cmpF = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -EA SilentlyContinue |
Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
$boardRows = @()
if ($cmpF) { $boardRows += @((ConvertFrom-Json (Get-Content $cmpF.FullName -Raw)).comparison) }
$rbF = Join-Path $OutDir 'recipe-board.json'
if (Test-Path $rbF) { $boardRows += @((ConvertFrom-Json (Get-Content $rbF -Raw)).comparison) }
foreach ($b in $boardRows) {
  foreach ($s in $b.stores) { if ([string]$s.store -eq 'Hy-Vee') { $held[[string]$b.id] = [double]$s.per_unit } }
}

# which commodities to walk: named ids, or the next bounded slice from a persisted rotating cursor
$allIds = @($terms.PSObject.Properties.Name)
$curF = Join-Path $OutDir 'hyvee-discover-cursor.txt'
if ($Ids.Count) {
  $work = @($Ids)
} else {
  $cur = 0
  if (Test-Path $curF) { [void][int]::TryParse(((Get-Content $curF -Raw) + '').Trim(), [ref]$cur) }
  $work = @()
  for ($i = 0; $i -lt [math]::Min($Slice, $allIds.Count); $i++) { $work += $allIds[(($cur + $i) % $allIds.Count)] }
  Set-Content $curF ([string](($cur + $work.Count) % $allIds.Count)) -Encoding UTF8
  Write-Output ("cursor {0} -> {1} of {2} term(s); this run walks {3}" -f $cur, ((($cur + $work.Count) % $allIds.Count)), $allIds.Count, $work.Count)
}

$EP = 'https://www.hy-vee.com/aisles-online/api/search/products'
$HUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148 Safari/537.36'
# THE STORE IDENTITY HAS ONE HOME (2026-08-21). It was hard-coded in six files, so switching stores
# meant editing six and hoping. See hyvee-store-lib.ps1 for why storeId and locationId must move together.
. (Join-Path $PSScriptRoot 'hyvee-store-lib.ps1')
$HStore = [int](Get-HyVeeStore).store_id
function HV-Search([string]$term, [int]$size) {
  $h = @{ 'content-type' = 'application/json'; 'User-Agent' = $HUA; 'x-hy-vee-correlation-id' = [guid]::NewGuid().ToString() }
  $body = @{ pageNumber = 1; pageSize = $size; searchFilters = @(); searchTerm = $term; sortDirection = 'RELEVANCE'; storeId = $HStore; pageViewId = [guid]::NewGuid().ToString() } | ConvertTo-Json -Compress
  for ($a = 1; $a -le 3; $a++) {
    try { return @((Invoke-RestMethod -Uri $EP -Method Post -Headers $h -Body $body -TimeoutSec 25).results) }
    catch { Start-Sleep -Seconds (2 * $a) }
  }
  return $null    # NULL, not @() - the caller must be able to tell "store said nothing" from "we never asked"
}

$docket = New-Object System.Collections.Generic.List[object]
$searched = 0; $failed = 0; $scanned = 0; $settled = 0
# COUNT EVERY SKIP. The first live run of this script asked for six commodities, matched none of them by
# id, and printed "searched 0 term(s)" with no reason - which reads exactly like a store that returned
# nothing. Every path out of a requested id is now counted and named.
$noCommodity = @(); $noTerm = @()
# ---- PHASE 1: WHAT ARE WE ASKING, AND OF WHOM? (serial, no network) ------------------------------------
# Split out from the search on 2026-08-23. These are pure lookups over data already in memory, and they
# decide which ids are skipped and why. They stay serial and stay FIRST because $noCommodity / $noTerm are
# the reasons a requested id produced nothing, and every one of them is printed - the first live run of
# this script matched none of six ids and reported "searched 0 term(s)", which reads exactly like a store
# that answered nothing. That accounting does not move into a thread.
$plan = New-Object System.Collections.Generic.List[object]
foreach ($id in $work) {
  $c = $comById[[string]$id]
  if (-not $c) { $noCommodity += [string]$id; continue }
  $term = (Get-PrimarySearchTerm $terms $id)
  if (-not $term) { $noTerm += [string]$id; continue }
  $plan.Add([pscustomobject]@{ Id = [string]$id; Term = [string]$term; Commodity = $c })
}

# ---- PHASE 2: ASK THEM ALL, A FEW AT A TIME (concurrent, network only) ---------------------------------
# A RUNSPACE IS THE RIGHT SHAPE **HERE** AND THE WRONG ONE NEXT DOOR. fanout-lib.ps1's rule 6 says
# runspaces hold child PROCESSES and must not do the work, because PowerShell's -match/-replace go through
# one process-wide static Regex cache behind one lock and scale NEGATIVELY across threads (measured
# 8.9 s -> 215.5 s from 1 to 16 runspaces). That rule is about REGEX ON THE THREAD. What happens here is
# Invoke-RestMethod: .NET socket I/O, no shared lock, genuinely concurrent, and spawning a whole
# powershell.exe per HTTP request would cost more than the request. So: threads for the fetch, and every
# line of judgement stays on the main thread in phase 3, where the regexes live.
#
# The results are keyed by id and read back IN PLAN ORDER, so the docket, the counters and the printed
# lines are identical to the serial version regardless of which store response arrives first.
$fetched = @{}
if ($plan.Count) {
  $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $MaxParallel))
  $pool.ApartmentState = 'MTA'
  $pool.Open()
  $jobs = New-Object System.Collections.ArrayList
  try {
    foreach ($pl in $plan) {
      $ps = [powershell]::Create()
      $ps.RunspacePool = $pool
      # Self-contained: a runspace inherits none of this file's functions or variables, so HV-Search's
      # body is passed in whole rather than called. Same retry ladder, same 25 s timeout, same
      # $null-means-we-never-got-an-answer contract as the original - $null and @() must stay different,
      # because "the store said nothing" and "we never asked" are different findings.
      [void]$ps.AddScript({
        param([string]$Term, [int]$Size, [string]$Endpoint, [string]$Ua, [int]$StoreId, [int]$PaceMs)
        $ErrorActionPreference = 'Continue'
        $h = @{ 'content-type' = 'application/json'; 'User-Agent' = $Ua; 'x-hy-vee-correlation-id' = [guid]::NewGuid().ToString() }
        $body = @{ pageNumber = 1; pageSize = $Size; searchFilters = @(); searchTerm = $Term; sortDirection = 'RELEVANCE'; storeId = $StoreId; pageViewId = [guid]::NewGuid().ToString() } | ConvertTo-Json -Compress
        $out = $null
        for ($a = 1; $a -le 3; $a++) {
          try { $out = @((Invoke-RestMethod -Uri $Endpoint -Method Post -Headers $h -Body $body -TimeoutSec 25).results); break }
          catch { Start-Sleep -Seconds (2 * $a) }
        }
        # THE PACE IS PER WORKER AND IT IS AFTER THE CALL, exactly as the serial version paced. Keeping it
        # inside the runspace is what bounds the request rate to (workers / 400 ms) instead of removing
        # the bound altogether - deleting this line is how a polite client becomes a scraper.
        Start-Sleep -Milliseconds $PaceMs
        return @{ ok = ($null -ne $out); results = $out }
      })
      [void]$ps.AddArgument([string]$pl.Term)
      [void]$ps.AddArgument([int]$PageSize)
      [void]$ps.AddArgument([string]$EP)
      [void]$ps.AddArgument([string]$HUA)
      [void]$ps.AddArgument([int]$HStore)
      [void]$ps.AddArgument(400)
      [void]$jobs.Add(@{ Id = [string]$pl.Id; PS = $ps; Async = $ps.BeginInvoke() })
    }
    foreach ($j in $jobs) {
      $r = $null
      try { $r = @($j.PS.EndInvoke($j.Async)) | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1 } catch { $r = $null }
      # A DEAD RUNSPACE IS A FAILED SEARCH, NOT AN EMPTY ONE. If the thread itself broke we know nothing
      # about that term, which is exactly what $null means to phase 3 - it becomes a counted SEARCH FAILED
      # line rather than a commodity that silently produced no candidates.
      $fetched[[string]$j.Id] = if ($r -and $r.ok) { @($r.results) } else { $null }
      try { $j.PS.Dispose() } catch { }
    }
  } finally {
    try { $pool.Close() } catch { }
    try { $pool.Dispose() } catch { }
  }
}

# ---- PHASE 3: JUDGE THEM, IN PLAN ORDER (serial - this is where the regexes are) -----------------------
foreach ($pl in $plan) {
  $id = $pl.Id
  $c = $pl.Commodity
  $rx = @(); foreach ($p in @($c.include)) { if ($p) { $rx += [regex]::new([string]$p, 'IgnoreCase,Compiled') } }
  $ex = @(); foreach ($p in @($c.exclude)) { if ($p) { $ex += [regex]::new([string]$p, 'IgnoreCase,Compiled') } }
  $res = $fetched[[string]$id]
  if ($null -eq $res) { $failed++; Write-Output ("  {0,-26} SEARCH FAILED (counted, not silently skipped)" -f $id); continue }
  $searched++
  $heldPu = if ($held.ContainsKey([string]$id)) { [double]$held[[string]$id] } else { 0 }
  $kept = 0
  foreach ($x in @($res)) {
    $scanned++
    $nm = [string]$x.description
    $price = 0.0; try { $price = [double]$x.pricing.tagPriceValue } catch {}
    if ($price -le 0) { continue }
    $size = [string]$x.unitOfMeasure
    $pu = Get-LinkPerUnit -size $size -unit ([string]$c.unit) -price $price -name $nm
    if ($null -eq $pu) { continue }
    $v = Test-Candidate -Name $nm -PerUnit ([double]$pu) -HeldPerUnit $heldPu -HaveNames $haveNames -Rx $rx -Ex $ex -MinBeatPct $MinBeatPct
    if (-not $v.keep) { continue }
    # ALREADY RULED ON? Keyed by the store's own productId, so a re-titled product cannot walk back onto the
    # docket as if it had never been judged. Counted, never silently dropped - a docket that shrinks without
    # saying why is indistinguishable from a search that stopped working.
    if ($verdicts.ContainsKey((Get-DiscoveryKey -Store 'Hy-Vee' -Commodity ([string]$id) -ProductId ([string]$x.id) -Product $nm))) { $settled++; continue }
    $docket.Add([pscustomobject]@{
        id = [string]$id; store = 'Hy-Vee'; product = $nm; size = $size; price = $price
        per_unit = [math]::Round([double]$pu, 4); unit = [string]$c.unit
        held_per_unit = [math]::Round($heldPu, 4)
        beats_by_pct = if ($heldPu -gt 0) { [math]::Round((1 - ($pu / $heldPu)) * 100, 1) } else { $null }
        product_id = [string]$x.id; why = [string]$v.why
      })
    $kept++
  }
  if ($kept) { Write-Output ("  {0,-26} {1} candidate(s) worth review" -f $id, $kept) }
}

$outF = Join-Path $OutDir 'hyvee-discovery.json'

# ---- MERGE, NEVER OVERWRITE ---------------------------------------------------------------------------
# This used to write only the current slice, and that quietly destroyed the queue. The run is a BOUNDED
# ROTATION - 40 of 526 terms - so a candidate nobody adjudicated before the cursor moved on vanished until
# the rotation came back around, about 13 days later. Measured the moment discovery ran twice: a 12-term
# slice replaced yesterday's 11 open candidates (including That's Smart! peanut butter at -33.4% and
# ketchup at -29%) with 2. The docket is a QUEUE, not a report of the last slice, and the whole point of
# F1's adjudication path is that a human works it down over time.
# So: carry every prior candidate forward EXCEPT the ones that are now settled (they have a ruling) or now
# re-found in this slice (this run's row is fresher). Settled ones are dropped here as well as suppressed
# above, so a ruling actually shrinks the file rather than just hiding a line.
$carried = 0; $dropped = 0
$prior = @()
if (Test-Path $outF) {
  try {
    $praw = ((Get-Content $outF -Raw -Encoding UTF8) + '').Trim()
    if ($praw -ne '') { $pj = $praw | ConvertFrom-Json; $prior = @($pj) }
  } catch {
    # LOUD. An unreadable docket must not read like an empty one - that would silently discard the queue,
    # which is the bug this merge exists to stop, wearing the other hat.
    Write-Output 'WARNING: the existing docket is UNREADABLE - carrying nothing forward. The open queue in it is being lost; restore it from git before trusting this file.'
    $prior = @()
  }
  $thisRun = @{}
  foreach ($d in $docket) { $thisRun[(Get-DiscoveryKey -Store 'Hy-Vee' -Commodity ([string]$d.id) -ProductId ([string]$d.product_id) -Product ([string]$d.product))] = $true }
  foreach ($p in @($prior | Where-Object { $_ })) {
    $k = Get-DiscoveryKey -Store 'Hy-Vee' -Commodity ([string]$p.id) -ProductId ([string]$p.product_id) -Product ([string]$p.product)
    if ($verdicts.ContainsKey($k)) { $dropped++; continue }
    if ($thisRun.ContainsKey($k)) { continue }
    $docket.Add($p); $carried++
  }
}
($docket.ToArray() | ConvertTo-Json -Depth 4) | Set-Content $outF -Encoding UTF8
Write-Output ''
Write-Output ("searched {0} term(s), {1} failed, {2} product(s) scanned" -f $searched, $failed, $scanned)
if ($noCommodity.Count) { Write-Output ("  {0} requested id(s) are in NO commodity: {1}" -f $noCommodity.Count, (($noCommodity | Select-Object -First 12) -join ', ')) }
if ($noTerm.Count) { Write-Output ("  {0} commodit(y/ies) have no search term: {1}" -f $noTerm.Count, (($noTerm | Select-Object -First 12) -join ', ')) }
Write-Output ("DOCKET: {0} open candidate(s) that beat what we hold -> {1}" -f $docket.Count, $outF)
Write-Output ("  ({0} found by this slice, {1} carried forward from earlier runs, {2} removed because they are now ruled)" -f ($docket.Count - $carried), $carried, $dropped)
if ($settled -gt 0) { Write-Output ("  ({0} further candidate(s) suppressed during the search - already ruled)" -f $settled) }
Write-Output 'ADVISORY ONLY: nothing here reaches a board. Adjudicate before any of it is priced -'
Write-Output 'Hy-Vee publishes no per-product department, so aisle-test CANNOT vet these (see the header).'
Write-Output 'Read them ranked in the arrivals desk PROSPECTS section; rule them with adjudicate-discovery.ps1.'
if ($failed -gt 0 -and $searched -eq 0) { Write-Output 'BLIND: every search failed'; exit 3 }
exit 0

