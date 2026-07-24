<#
  audit-cell-drops.ps1 - "we had this price and quietly lost it" per-CELL detector (2026-07-23, built the
  day Brad caught Fareway's boneless chicken breast missing by eye).

  The coverage-regression guard compares per-store TOTALS with a ~5% tolerance, so a store can shed a
  handful of real items (today: 7 Fareway cells incl. chicken breast, from a partial storefront pull)
  without tripping anything. This audit diffs the newest board against a ~5-7 day old one at CELL level
  (commodity x store) and reports every EVERYDAY cell that vanished. Ended SALES are excluded (rolling
  off the ad cycle is correct; the sale-fallback machinery owns those) and Sam's Club is excluded (its
  slices age out by the 14-day policy on purpose; the fullpull watch owns that). What remains should be
  ZERO now that carry-forward walks the whole window - so anything listed is a real, new leak.
  ADVISORY (exit 1, never 2): the board holding a true price matters more than perfect coverage.
#>
param([int]$CompareAgeDays = 5)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$outDir = Join-Path $root 'out'
$boards = @(Get-ChildItem (Join-Path $outDir 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending)
if ($boards.Count -lt 2) { Write-Output 'cell-drops: fewer than 2 dated boards - nothing to diff'; exit 0 }
$newF = $boards[0]
$newDate = [datetime]([regex]::Match($newF.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)
$oldF = $boards | Where-Object { ([datetime]([regex]::Match($_.BaseName, '(\d{4}-\d{2}-\d{2})$').Groups[1].Value)) -le $newDate.AddDays(-$CompareAgeDays) } | Select-Object -First 1
if (-not $oldF) { $oldF = $boards[$boards.Count - 1] }
if ($oldF.FullName -eq $newF.FullName) { Write-Output 'cell-drops: no older board to diff against'; exit 0 }

$new = (Get-Content $newF.FullName -Raw | ConvertFrom-Json).comparison
$old = (Get-Content $oldF.FullName -Raw | ConvertFrom-Json).comparison
$nmap = @{}
foreach ($r in $new) { $nmap[[string]$r.id] = @($r.stores | ForEach-Object { [string]$_.store }) }
$drops = @()
foreach ($r in $old) {
  foreach ($s in @($r.stores)) {
    $st = [string]$s.store
    if ($st -eq "Sam's Club") { continue }              # 14-day slice policy; fullpull watch owns it
    if ([string]$s.type -eq 'sale') { continue }        # ended sales roll off correctly
    $now = $nmap[[string]$r.id]
    if (-not $now -or ($now -notcontains $st)) {
      $drops += [pscustomobject]@{ id = [string]$r.id; store = $st; was = ('{0:N2}' -f [double]$s.per_unit) }
    }
  }
}
if ($drops.Count -eq 0) { Write-Output ("cell-drops: ok - no everyday cell lost vs " + $oldF.BaseName); exit 0 }
Write-Output ("cell-drops: WARNING - {0} everyday cell(s) priced on {1} are missing from today's board (a real leak; carry-forward should have prevented it - check the store's newest pull + as_of expiry):" -f $drops.Count, $oldF.BaseName)
$drops | ForEach-Object { Write-Output ("  " + $_.id + " @ " + $_.store + " (was $" + $_.was + ")") }
exit 1
