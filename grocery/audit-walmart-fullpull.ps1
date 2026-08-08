<#
  audit-walmart-fullpull.ps1 - early warning for the partial-pull aging class, BEFORE it becomes a
  coverage hold. Covers BOTH union-based stores since 2026-07-23: Walmart AND Sam's Club.

  Both stores' board coverage rests on compare-deals UNIONING their recent captures inside a 14-day
  window. A throttled/sliced day produces a partial capture; the union absorbs it by backfilling from
  older captures. But daily/weekly partials keep every OTHER freshness signal green (guard 9 watches
  file AGE, the Wednesday watchdog watches mtimes) while the last COMPREHENSIVE capture silently ages
  toward the window's cliff - at which point the coverage guard HOLDS the board (safe, but a lost
  refresh day) with no earlier warning. Deal COUNT cannot detect partiality (the 2026-07-23 Walmart
  partial had MORE deals than the full pull), so the builders stamp `pull_terms` (distinct search
  terms in the raw capture) and THIS audit watches the age of the newest capture with pull_terms >=
  200 (a full worklist runs ~400+ of commodity-search.json's 447 terms; a throttled slice ~50).

  Files predating the stamp are LEGACY-UNKNOWN: if one is newer than every stamped-comprehensive
  capture we cannot judge, so that store stays silent rather than cry wolf (each store's watch arms
  itself at its first stamped comprehensive pull). Exit codes: 0 = all stores healthy/indeterminate;
  1 = ADVISORY, at least one store is aging (>= WarnAgeDays) or its window holds only stamped
  partials; 3 = BLIND, at least one store had ZERO captures in its window - the watch examined nothing and can prove nothing (blind outranks advisory). NEVER 2 - this must never block a publish; the coverage guard already fails closed at the
  cliff. ONE copy of this logic on purpose: guards.ps1 (warn) and check-ad-cycles.ps1 (deduped email)
  both call this script instead of re-implementing it.

  CROSS-REFERENCE (2026-07-31): build-rescue-worklist.ps1 carries its OWN copy of the item|price capture
  tracer in watch 2 below, and that duplication is deliberate. This file WATCHES (is a comprehensive
  capture aging?); that one BUILDS A WORKLIST (which terms should the next browser session search?).
  Sharing a tracer lib would mean one edit could blind both at once, and the two separate fixture sets
  exist precisely so that cannot happen. Duplicated tracing is an accepted drift risk here; a broken
  freshness watcher is not.
#>
param([int]$WindowDays = 14, [int]$WarnAgeDays = 10, [string]$GroceryRoot = "", [int]$CellWarnDays = 5, [int]$CellWarnPct = 5)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root = if ($GroceryRoot) { $GroceryRoot } elseif ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$today = [datetime]::Today

# Per-store "comprehensive" thresholds, calibrated to each store's real full-pull size (NOT one number for
# both): a full Walmart pass runs the whole 447-term worklist (throttled partials ~50), while Sam's carries
# only ~330 of our commodities and its normal weekly pass searches ~200 terms (2026-07-23: 198) - opportunistic
# gap-fill slices run ~20-50. A shared 200 cutoff would flap on Sam's forever.
$STORES = @(
  @{ label = 'Walmart';    fullTerms = 200; glob = (Join-Path $root 'out\regular\walmart-regular-*.json') },
  @{ label = "Sam's Club"; fullTerms = 150; glob = (Join-Path $root 'out\sams\sams-deals-*.json') }
)

$advisory = $false; $blind = $false
foreach ($st in $STORES) {
  $inWindow = @()
  foreach ($f in (Get-ChildItem $st.glob -ErrorAction SilentlyContinue)) {
    $m = [regex]::Match($f.BaseName, '(\d{4}-\d{2}-\d{2})$')
    if (-not $m.Success) { continue }
    $d = [datetime]$m.Groups[1].Value
    if (($today - $d).TotalDays -gt $WindowDays) { continue }
    $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
    $terms = $null
    if ($j.PSObject.Properties['pull_terms']) { $terms = [int]$j.pull_terms }
    $inWindow += [pscustomobject]@{ date = $d; terms = $terms; name = $f.Name }
  }
  if (-not $inWindow.Count) {
    Write-Output ("fullpull [{0}]: BLIND - no captures in the {1}-day window at all; this watch examined ZERO files for {0} and can prove nothing about its coverage (the coverage guard still fails closed at the cliff). Run a full-worklist pull now." -f $st.label, $WindowDays)
    $blind = $true
    continue
  }
  $newestFull    = $inWindow | Where-Object { $_.terms -ne $null -and $_.terms -ge $st.fullTerms } | Sort-Object date -Descending | Select-Object -First 1
  $newestUnknown = $inWindow | Where-Object { $_.terms -eq $null } | Sort-Object date -Descending | Select-Object -First 1

  if ($newestUnknown -and (-not $newestFull -or $newestUnknown.date -gt $newestFull.date)) {
    # TIME-BOUND THE SILENCE (2026-07-28). "Indeterminate" means we cannot PROVE the newest unstamped
    # capture is comprehensive - it does not mean everything is fine, and it must not be a permanent gag.
    # On 2026-07-28 this branch was silent while 334 of 426 live Walmart cells (78% of that store's board)
    # were priced from an unstamped capture that was already 10 days old, with a hard coverage collapse
    # dated 2026-08-02 and no advance warning: the alarm would have fired the same day as the damage.
    # An unknown that is YOUNG is genuinely worth staying quiet about. An unknown that is older than the
    # warn threshold is worth saying out loud, precisely BECAUSE we cannot verify it. Stays advisory - it
    # can never block a publish.
    $unkAge = [int]($today - $newestUnknown.date).TotalDays
    if ($unkAge -ge $WarnAgeDays) {
      Write-Output ("fullpull [{0}]: WARNING - the newest capture we can lean on ({1}) is UNSTAMPED, so we cannot prove it is comprehensive, AND it is already {2} days old; at day {3} it leaves the union window and coverage collapses. Every stamped capture in the window is a partial (max pull_terms {4}). Run a full-worklist browser pull." -f $st.label, $newestUnknown.name, $unkAge, $WindowDays, (($inWindow | Where-Object { $_.terms -ne $null } | Measure-Object -Property terms -Maximum).Maximum))
      $advisory = $true
      continue
    }
    Write-Output ("fullpull [{0}]: indeterminate - newest unstamped (pre-pull_terms) capture {1} is only {2}d old and outranks any stamped-comprehensive file; staying silent until it ages past {3}d or the watch arms" -f $st.label, $newestUnknown.name, $unkAge, $WarnAgeDays)
    continue
  }
  if (-not $newestFull) {
    Write-Output ("fullpull [{0}]: WARNING - the {1}-day window holds ONLY partial captures (max pull_terms {2}). The union has no comprehensive base; coverage is running on borrowed time. Run a full-worklist browser pull." -f $st.label, $WindowDays, (($inWindow | Measure-Object -Property terms -Maximum).Maximum))
    $advisory = $true
    continue
  }
  $age = [int]($today - $newestFull.date).TotalDays
  if ($age -ge $WarnAgeDays) {
    Write-Output ("fullpull [{0}]: WARNING - newest comprehensive capture ({1}, {2} terms) is {3} days old; at day {4} it leaves the union window and coverage collapses (the guard will hold the board). Run a full-worklist browser pull soon." -f $st.label, $newestFull.name, $newestFull.terms, $age, $WindowDays)
    $advisory = $true
    continue
  }
  Write-Output ("fullpull [{0}]: ok - newest comprehensive capture {1} ({2} terms) is {3} day(s) old (warn at {4}, cliff at {5})" -f $st.label, $newestFull.name, $newestFull.terms, $age, $WarnAgeDays, $WindowDays)
}

# ---------------------------------------------------------------------------------------------------
# WATCH 2 (2026-07-30) - THE CELLS, NOT THE TERM COUNT.
#
# The watch above asks "is there a comprehensive capture in the window". On 2026-07-30 it answered
# "ok - newest comprehensive capture walmart-regular-2026-07-30.json (217 terms) is 0 day(s) old" while
# 207 of 432 live Walmart board cells (47.9%, 58 of them CROWNS) had walmart-regular-2026-07-18.json as
# their ONLY remaining source - a file that leaves the 14-day union on 2026-08-02. The term threshold is
# a proxy and the proxy had drifted: 200 was calibrated against a 447-term worklist, commodity-search.json
# now holds 526, and a 217-term pull clears the bar while re-covering only 41% of it. So this watch stops
# proxying and measures the thing itself: for every cell the board publishes for a union store, find the
# NEWEST capture in the window that still contains that exact winning row, and count the cells whose only
# source is about to age out. A cell nobody re-pulls dies on a known date; this names the date in advance.
#
# CRY-WOLF, MEASURED before this was written (18 historical comparison-*.json boards, each evaluated as of
# its own date): Walmart cells with <= 3 days left were ZERO on 15 boards and 207 on 2026-07-29 - the one
# real cliff. At the shipped <= 5 day / >= 5% setting the only firings are 07-27 (331), 07-28 (331),
# 07-29 (207) for Walmart and 07-22 (29), 07-26 (182), 07-27 (198), 07-28 (191) for Sam's - two genuine
# expiries, each one silenced by the next full pull (Sam's dropped to 11 cells / 3.2% the day after its
# 07-29 pull, below threshold, silent). It does not fire on a healthy day.
#
# THE PERCENT FLOOR IS LOAD-BEARING: a handful of cells always trails (a product that went out of stock,
# a term that returned nothing that morning). Sam's carried 11 such cells on 07-29 with nothing wrong.
# "Any cell at all" would have made this a permanent alarm.
#
# ADVISORY ONLY (exit 1), same contract as the watch above - never blocks a publish. Attribution that
# examines nothing (no board, or not one cell traceable to a capture) is stated out loud, never silence.
$cellFile = Get-ChildItem (Join-Path $root 'out\comparison-*.json') -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match 'comparison-\d{4}-\d{2}-\d{2}$' } |
            Sort-Object Name -Descending | Select-Object -First 1
$cellCmp = $null
if ($cellFile) {
  # (Get-Content -Raw) is $null on a zero-byte file and [string]$null is $null, not '' - the + '' keeps
  # .Trim()/ConvertFrom-Json off a null. '' | ConvertFrom-Json returns $null WITHOUT throwing, so the
  # emptiness has to be tested after the parse, not trusted to an exception.
  $cellRaw = ((Get-Content $cellFile.FullName -Raw -Encoding UTF8) + '')
  if ($cellRaw.Trim()) { $cellCmp = $cellRaw | ConvertFrom-Json }
}
if ($null -eq $cellCmp -or -not @($cellCmp.comparison).Count) {
  Write-Output ("fullpull [cells]: CANNOT EVALUATE - no readable dated out\comparison-*.json under {0}, so the cell-expiry watch examined ZERO board cells and proves nothing this run (it is NOT reporting that coverage is fine). Run compare-deals." -f $root)
  $advisory = $true
} else {
  foreach ($st in $STORES) {
    # the capture files the engine will union on the NEXT run, oldest first so the last hit is the newest
    $capFiles = New-Object System.Collections.ArrayList
    foreach ($f in (Get-ChildItem $st.glob -ErrorAction SilentlyContinue | Sort-Object Name)) {
      $m2 = [regex]::Match($f.BaseName, '(\d{4}-\d{2}-\d{2})$')
      if (-not $m2.Success) { continue }
      $d2 = [datetime]$m2.Groups[1].Value
      if (($today - $d2).TotalDays -gt $WindowDays) { continue }   # same window test as watch 1 above
      $raw2 = ((Get-Content $f.FullName -Raw -Encoding UTF8) + '')
      if (-not $raw2.Trim()) { continue }
      $j2 = $raw2 | ConvertFrom-Json
      if ($null -eq $j2) { continue }
      $set = New-Object 'System.Collections.Generic.HashSet[string]'
      foreach ($r2 in @($j2.deals)) { if ($null -ne $r2) { [void]$set.Add((([string]$r2.item).ToLower() + '|' + [string]$r2.ad_price)) } }
      [void]$capFiles.Add([pscustomobject]@{ date = $d2; set = $set })
    }
    $cells = 0; $attributed = 0; $atRisk = 0; $crowns = 0
    $soonest = $null
    $names = New-Object System.Collections.ArrayList
    foreach ($row in @($cellCmp.comparison)) {
      $sc = @($row.stores) | Where-Object { $_.store -eq $st.label } | Select-Object -First 1
      if (-not $sc) { continue }
      $cells++
      $key = (([string]$sc.item).ToLower() + '|' + [string]$sc.ad)
      $newest = $null
      foreach ($cf in $capFiles) { if ($cf.set.Contains($key)) { $newest = $cf.date } }
      if ($null -eq $newest) { continue }        # priced from a row no capture in the window still carries
      $attributed++
      $left = $WindowDays - [int]($today - $newest).TotalDays
      if ($left -gt $CellWarnDays) { continue }
      $atRisk++
      if ($row.cheapest_store -eq $st.label) { $crowns++ }
      $gone = $newest.AddDays($WindowDays + 1)
      if ($null -eq $soonest -or $gone -lt $soonest) { $soonest = $gone }
      if ($names.Count -lt 8) { [void]$names.Add([string]$row.id) }
    }
    if ($attributed -eq 0) {
      $why = if ($cells -eq 0) { "the board publishes NO cells at all for this store" } else { ("none of its {0} board cell(s) is traceable to a capture inside the {1}-day window" -f $cells, $WindowDays) }
      Write-Output ("fullpull [{0}] cells: CANNOT EVALUATE - {1}, so this watch examined ZERO attributable cells for {0} and proves nothing (that is not a clean bill of health)." -f $st.label, $why)
      $advisory = $true
      continue
    }
    $pct = [math]::Round(100.0 * $atRisk / $attributed, 1)
    if ($atRisk -gt 0 -and $pct -ge $CellWarnPct) {
      Write-Output ("fullpull [{0}] cells: WARNING - {1} of {2} attributed board cell(s) ({3}%, {4} of them CROWNS) are priced from a capture whose ONLY copy of that row leaves the {5}-day union window; the first of them goes on {6}. Nothing is broken today - on that date those cells lose their price. Run a full-worklist browser pull for {0} (the terms are already in commodity-search.json). e.g. {7}" -f $st.label, $atRisk, $attributed, $pct, $crowns, $WindowDays, $soonest.ToString('yyyy-MM-dd'), (($names.ToArray()) -join ', '))
      $advisory = $true
    } else {
      Write-Output ("fullpull [{0}] cells: ok - {1} of {2} attributed board cell(s) expire within {3} day(s) (warn at {4}%); {5} cell(s) could not be traced to a capture in the window" -f $st.label, $atRisk, $attributed, $CellWarnDays, $CellWarnPct, ($cells - $attributed))
    }
  }
}

if ($blind) { exit 3 } elseif ($advisory) { Write-GuardComplete -Name 'walmart-fullpull'; exit 1 } else { Write-GuardComplete -Name 'walmart-fullpull'; exit 0 }
