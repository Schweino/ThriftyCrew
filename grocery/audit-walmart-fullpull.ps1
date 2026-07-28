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
  partials. NEVER 2 - this must never block a publish; the coverage guard already fails closed at the
  cliff. ONE copy of this logic on purpose: guards.ps1 (warn) and check-ad-cycles.ps1 (deduped email)
  both call this script instead of re-implementing it.
#>
param([int]$WindowDays = 14, [int]$WarnAgeDays = 10, [string]$GroceryRoot = "")
$ErrorActionPreference = 'Stop'
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

$advisory = $false
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
    Write-Output ("fullpull [{0}]: no captures in the {1}-day window at all (the coverage guard owns that failure)" -f $st.label, $WindowDays)
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

if ($advisory) { exit 1 } else { exit 0 }
