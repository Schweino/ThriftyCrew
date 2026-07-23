<#
  audit-walmart-fullpull.ps1 - early warning for the 2026-07-23 partial-pull class, BEFORE it becomes a
  coverage hold.

  Walmart's board coverage rests on compare-deals' UNION of its out\regular captures inside a 14-day window
  (WalmartMaxAgeDays). A PerimeterX-throttled day produces a ~50-term partial; the union absorbs it by
  backfilling from the last COMPREHENSIVE capture. But if only partials arrive for 14 straight days, the last
  full capture ages OUT of the window and coverage collapses - the coverage guard then HOLDS the board (safe,
  but a lost refresh day) with no earlier warning, because guard 9 only watches file AGE and daily partials
  keep the newest file perpetually fresh. The Wednesday watchdog is blind too: it watches file mtimes, and a
  partial refresh updates the mtime.

  So this audit watches the one thing nothing else does: the AGE OF THE NEWEST COMPREHENSIVE CAPTURE.
  "Comprehensive" = pull_terms >= 200 (a full worklist pull runs ~400+ terms of commodity-search.json's 447;
  a throttled partial runs ~50 - deal COUNT cannot tell them apart, the 07-23 partial had MORE deals than the
  full pull). Files without pull_terms are LEGACY-UNKNOWN: if one is newer than every stamped-full file we
  cannot judge, so we stay silent rather than cry wolf (the watch arms itself as stamped pulls accumulate).

  Exit codes: 0 = healthy or indeterminate. 1 = ADVISORY - the newest comprehensive capture is >= WarnAgeDays
  old (or the window holds only stamped partials). NEVER 2: this must never block a publish; the coverage
  guard already fails closed at the cliff. One copy of this logic on purpose - guards.ps1 (warn) and
  check-ad-cycles.ps1 (deduped email) both CALL this script instead of re-implementing it.
#>
param([int]$WindowDays = 14, [int]$WarnAgeDays = 10, [string]$RegularDir = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$regDir = if ($RegularDir) { $RegularDir } else { Join-Path $root 'out\regular' }
$today = [datetime]::Today

$inWindow = @()
foreach ($f in (Get-ChildItem (Join-Path $regDir 'walmart-regular-*.json') -ErrorAction SilentlyContinue)) {
  $m = [regex]::Match($f.BaseName, '(\d{4}-\d{2}-\d{2})$')
  if (-not $m.Success) { continue }
  $d = [datetime]$m.Groups[1].Value
  if (($today - $d).TotalDays -gt $WindowDays) { continue }
  $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
  $terms = $null
  if ($j.PSObject.Properties['pull_terms']) { $terms = [int]$j.pull_terms }
  $inWindow += [pscustomobject]@{ date = $d; terms = $terms; name = $f.Name }
}

if (-not $inWindow.Count) { Write-Output "walmart-fullpull: no Walmart captures in the $WindowDays-day window at all (the coverage guard owns that failure)"; exit 0 }

$newestFull    = $inWindow | Where-Object { $_.terms -ne $null -and $_.terms -ge 200 } | Sort-Object date -Descending | Select-Object -First 1
$newestUnknown = $inWindow | Where-Object { $_.terms -eq $null } | Sort-Object date -Descending | Select-Object -First 1

if ($newestUnknown -and (-not $newestFull -or $newestUnknown.date -gt $newestFull.date)) {
  Write-Output ("walmart-fullpull: indeterminate - newest unstamped (pre-pull_terms) capture {0} outranks any stamped-full file; cannot judge comprehensiveness, staying silent" -f $newestUnknown.name)
  exit 0
}
if (-not $newestFull) {
  Write-Output ("walmart-fullpull: WARNING - the {0}-day window holds ONLY partial captures (max pull_terms {1}). The union has no comprehensive base; Walmart coverage is running on borrowed time. Run a full-worklist browser pull." -f $WindowDays, (($inWindow | Measure-Object -Property terms -Maximum).Maximum))
  exit 1
}
$age = [int]($today - $newestFull.date).TotalDays
if ($age -ge $WarnAgeDays) {
  Write-Output ("walmart-fullpull: WARNING - newest comprehensive Walmart capture ({0}, {1} terms) is {2} days old; at day {3} it leaves the union window and coverage collapses (the guard will hold the board). Run a full-worklist browser pull soon." -f $newestFull.name, $newestFull.terms, $age, $WindowDays)
  exit 1
}
Write-Output ("walmart-fullpull: ok - newest comprehensive capture {0} ({1} terms) is {2} day(s) old (warn at {3}, cliff at {4})" -f $newestFull.name, $newestFull.terms, $age, $WarnAgeDays, $WindowDays)
exit 0
