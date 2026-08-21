<#
  browser-refresh-due.ps1 - does a Chrome session owe the board any capture work right now?

  Exit 0 = FRESH (nothing owed; skip)     Exit 1 = DUE (work the worklists)

  *** REWRITTEN 2026-08-21: IT USED TO ASK THE CALENDAR, NOT THE DATA. ***
  The old gate asked one question - "is every browser feed dated on or after the most recent
  Wednesday?" - and answered DUE whenever the answer was no. That made sense while the estate
  refreshed everyday prices fortnightly in one big weekly sweep. It stopped making sense on
  2026-08-20, when capture-policy.ps1 moved everyday prices onto a 90-day quarter with a daily
  drip of total-terms/90 per store.

  What that mismatch cost, measured on 2026-08-21: the gate fired DUE because four feeds
  predated Wednesday, while every rescue worklist reported EXPIRING 0 and STALE-UNREFRESHABLE 0
  and the oldest capture on the board was ten days old against a ninety-day carry. It was
  asking for a full 592-term sweep per store to fix a problem that did not exist, and a
  592-term burst is exactly the shape that trips a bot wall. The gate was arguing for the
  risk it was supposed to be avoiding.

  WHAT IT ASKS NOW. Two questions, both about data:

    1. ROTATION DEBT. Has this store landed a capture TODAY? Under the quarterly policy each
       store is owed a small slice every day (7 terms of 596), so a store that has not landed
       one is behind by however many days it has been. This is the normal, expected DUE.

    2. EXPIRY PRESSURE. Is anything actually about to fall off the board? build-rescue-worklist
       already traces every everyday cell back to the capture backing it and counts EXPIRING and
       STALE-UNREFRESHABLE. A non-zero count is the URGENT case and is reported separately,
       because it means cells go blank rather than merely stale.

  Both are printed either way. A gate that says DUE without saying what is owed teaches the
  reader to skip the reason and just run everything, which is how the full sweep survived a
  policy change that had already retired it.
#>
param(
  [string]$Today = "",
  [string]$OutDir = "",
  # How many days a walled store may go without landing a capture before it is called out
  # loudly rather than reported as ordinary daily debt. Not a freshness window: rows live for
  # the policy's 90-day carry regardless. This is about the ROTATION falling behind.
  [int]$StallDays = 3
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$asof = if ($Today) { ([datetime]$Today).Date } else { (Get-Date).Date }
$todayS = $asof.ToString('yyyy-MM-dd')

. (Join-Path $root 'browser-feeds-lib.ps1')
. (Join-Path $root 'capture-policy-lib.ps1')

$stores = Get-BrowserCaptureStores -OutDir $OutDir

# ---- 1. rotation debt -------------------------------------------------------
$owed = @()
$stalled = @()
$lines = @()
foreach ($name in $stores.Keys) {
  $newest = Get-NewestCaptureDate $stores[$name]
  $age = if ($newest) { ($asof - $newest).Days } else { $null }
  $landedToday = ($null -ne $newest -and $newest -eq $asof)
  $cur = if (Test-TermRotationStore $name) { Get-CaptureCursor -Store $name -OutDir $OutDir } else { $null }
  $rot = (Get-CapturePlan -Store $name -Today $todayS).RotationTerms

  if (-not $landedToday) {
    $owed += $name
    if (($null -eq $age) -or ($age -ge $StallDays)) { $stalled += ("{0} ({1})" -f $name, $(if ($null -eq $age) { 'never' } else { "$age d" })) }
  }
  $lines += ("  {0,-11} newest={1,-11} age={2,-6} cursor=#{3,-4} owed_today={4}" -f `
      $name,
      $(if ($newest) { $newest.ToString('yyyy-MM-dd') } else { 'never' }),
      $(if ($null -eq $age) { 'n/a' } else { "${age}d" }),
      $(if ($null -eq $cur) { 'n/a' } else { $cur }),
      $(if ($landedToday) { "no (landed)" } else { "$rot term(s)" }))
}

# ---- 2. expiry pressure -----------------------------------------------------
# Read the counts build-rescue-worklist already measured rather than re-deriving them here.
# A second implementation of "is this cell about to expire" is exactly the private-copy
# disease that let the 14-day window survive in five places after the policy moved to 90.
$expiring = 0; $stale = 0; $rescueSeen = $false
foreach ($f in (Get-ChildItem (Join-Path $OutDir 'rescue-terms-*.txt') -ErrorAction SilentlyContinue)) {
  foreach ($l in (Get-Content -LiteralPath $f.FullName)) {
    if ($l -notmatch '^#\s*DROPPED') { continue }
    $rescueSeen = $true
    if ($l -match 'EXPIRING\s+(\d+)') { $expiring += [int]$Matches[1] }
    if ($l -match 'STALE-UNREFRESHABLE\s+(\d+)') { $stale += [int]$Matches[1] }
  }
}

# ---- report -----------------------------------------------------------------
Write-Output ("browser capture debt - $todayS  (quarter $(Get-PolicyQuarterDays)d, carry $(Get-PolicyMaxCarryDays)d)")
$lines | ForEach-Object { Write-Output $_ }
if ($rescueSeen) { Write-Output ("  expiry pressure: EXPIRING $expiring, STALE-UNREFRESHABLE $stale") }
else { Write-Output '  expiry pressure: no rescue worklist found - run build-rescue-worklist.ps1' }
Write-Output ''

if ($expiring -gt 0 -or $stale -gt 0) {
  Write-Output ("DUE - URGENT: $expiring cell(s) expiring and $stale stale-unrefreshable. These leave the board if not re-captured; work out\rescue-terms-*.txt FIRST.")
  exit 1
}
if ($stalled.Count) {
  Write-Output ("DUE - rotation STALLED for: " + ($stalled -join ', ') + ". Work each store's out\worklists\capture-<store>-$todayS.json.")
  exit 1
}
if ($owed.Count) {
  Write-Output ("DUE - today's rotation slice not yet landed for: " + ($owed -join ', ') + ". That is a small daily pass, not a sweep: work out\worklists\capture-<store>-$todayS.json and nothing else.")
  exit 1
}
Write-Output "FRESH - every walled store landed its rotation slice today and nothing is expiring; nothing to do."
exit 0

