<#
  audit-cell-drops.ps1 - "we had this price and quietly lost it" per-CELL detector (2026-07-23, built the
  day Brad caught Fareway's boneless chicken breast missing by eye).

  The coverage-regression guard compares per-store TOTALS with a ~5% tolerance, so a store can shed a
  handful of real items (today: 7 Fareway cells incl. chicken breast, from a partial storefront pull)
  without tripping anything. This audit diffs the newest board against a ~5-7 day old one at CELL level
  (commodity x store) and reports every EVERYDAY cell that vanished. Ended SALES are excluded (rolling
  off the ad cycle is correct; the sale-fallback machinery owns those) and Sam's Club is excluded (its
  slices age out by the capture policy on purpose; the fullpull watch owns that). What remains should be
  ZERO now that carry-forward walks the whole window - so anything listed is a real, new leak.
  ADVISORY (exit 1, never 2; exit 3 = BLIND, examined nothing): the board holding a true price matters more than perfect coverage.
#>
param([int]$CompareAgeDays = 5)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$outDir = Join-Path $root 'out'
$boards = @(Get-ChildItem (Join-Path $outDir 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending)
if ($boards.Count -lt 2) { Write-Output ('cell-drops: BLIND - only ' + $boards.Count + ' dated board(s) in out\, zero cells diffed; this detector proved NOTHING (comparison-*.json is gitignored, so a fresh clone / the cloud backup runner always lands here)'); exit 3 }
$newF = $boards[0]
$newDate = [datetime]([regex]::Match($newF.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)
$oldF = $boards | Where-Object { ([datetime]([regex]::Match($_.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)) -le $newDate.AddDays(-$CompareAgeDays) } | Select-Object -First 1
if (-not $oldF) { $oldF = $boards[$boards.Count - 1] }
if ($oldF.FullName -eq $newF.FullName) { Write-Output 'cell-drops: no older board to diff against'; exit 0 }

$new = (Get-Content $newF.FullName -Raw | ConvertFrom-Json).comparison
$old = (Get-Content $oldF.FullName -Raw | ConvertFrom-Json).comparison
$nmap = @{}
foreach ($r in $new) { $nmap[[string]$r.id] = @($r.stores | ForEach-Object { [string]$_.store }) }
$drops = @(); $cells = 0
foreach ($r in $old) {
  foreach ($s in @($r.stores)) {
    $st = [string]$s.store
    # SAM'S IS EXCLUDED HERE AND INCLUDED IN build-rescue-worklist.ps1, ON PURPOSE (noted 2026-07-31).
    # This audit answers "did something break?", and a Sam's slice aging out of the 14-day window is policy,
    # not breakage, so listing it here would be a permanent false alarm. The rescue worklist answers a
    # different question - "what should the next browser session search?" - and by that measure the shopper
    # lost the price either way and a capture is what fixes it. Two questions, two answers, one comment in
    # each file so neither reads as a bug in the other.
    # SAM'S IS SKIPPED BECAUSE ITS CAPTURES ARE SLICES, not because of any particular window. The comment
    # here said "14-day slice policy" until 2026-08-22; the carry is 90 days now, so a genuine Sam's drop
    # would have gone unreported for 76 days longer than the note implied. The reason still holds - a
    # partial club capture legitimately omits categories, and audit-walmart-fullpull owns that clock - but
    # the reason is the SLICE, and it must not be re-derived from a stale number.
    if ($st -eq "Sam's Club") { continue }
    if ([string]$s.type -eq 'sale') { continue }        # ended sales roll off correctly
    $cells++
    $now = $nmap[[string]$r.id]
    if (-not $now -or ($now -notcontains $st)) {
      $drops += [pscustomobject]@{ id = [string]$r.id; store = $st; was = ('{0:N2}' -f [double]$s.per_unit) }
    }
  }
}
if ($cells -eq 0) { Write-Output ("cell-drops: BLIND - compared ZERO everyday cells against " + $oldF.BaseName + " (that board parsed to no comparison rows, or stores[].store/.type renamed); 'no cell lost' would be an empty claim"); exit 3 }
if ($drops.Count -eq 0) { Write-Output ("cell-drops: ok - no everyday cell lost vs " + $oldF.BaseName + " (" + $cells + " cells compared)"); exit 0 }
# Wording fixed 2026-07-28. It used to assert "carry-forward should have prevented it", which sent every
# reader hunting for a carry-forward bug in Baker's and Walmart - stores that run COMPREHENSIVE pulls and
# deliberately have no carry-forward at all. For those the usual cause is a search term that failed during
# the capture, so every product reachable only through it is simply absent from that day's file.
Write-Output ("cell-drops: WARNING - {0} everyday cell(s) priced on {1} are missing from today's board. Baker's/Walmart run comprehensive pulls with NO carry-forward by design, so a dead search term is an instant hole - check that store's pull for failed terms first; for the browser stores check as_of expiry + carry-forward:" -f $drops.Count, $oldF.BaseName)
$drops | ForEach-Object { Write-Output ("  " + $_.id + " @ " + $_.store + " (was $" + $_.was + ")") }
exit 1
