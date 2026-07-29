<#
  browser-refresh-due.ps1 - Idempotency guard for the weekly Wednesday browser refresh. Prints FRESH if
  this week's browser-store data is already current (every browser feed dated on/after the most recent
  Wednesday), else DUE. Lets the scheduled agent SKIP a redundant pull when it fires (or catches up on
  next app launch) but the week's refresh already ran - and RETRY the next morning if a prior run failed
  (a failed run leaves the data stale, so this still reports DUE).
  Exit 0 = FRESH (already done this week; skip)   Exit 1 = DUE (run the full refresh)
#>
param([string]$Today = "")
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
$asof = if ($Today) { ([datetime]$Today).Date } else { (Get-Date).Date }
$dow = [int]$asof.DayOfWeek                      # Sun=0 .. Wed=3 .. Sat=6
$daysSinceWed = (($dow - 3) + 7) % 7             # 0 if today IS Wednesday
$lastWed = $asof.AddDays(-$daysSinceWed).Date    # most recent Wednesday (or today if Wed)

# The feed list and the capture-date rule live in browser-feeds-lib.ps1, shared with check-ad-cycles.ps1's
# missed-refresh alert. They used to be two copies and both were missing Fareway; see that file's header.
. (Join-Path $PSScriptRoot 'browser-feeds-lib.ps1')
$feeds = Get-BrowserFeedDates -OutDir $OutDir
$stale = @()
foreach ($k in $feeds.Keys) { $m = $feeds[$k]; if (($null -eq $m) -or ($m.Date -lt $lastWed)) { $stale += $k } }
if ($stale.Count -eq 0) {
  Write-Output ("FRESH - browser refresh already done for the week of " + $lastWed.ToString('yyyy-MM-dd') + "; nothing to do.")
  exit 0
} else {
  Write-Output ("DUE - these feeds are stale/missing since Wed " + $lastWed.ToString('yyyy-MM-dd') + ": " + ($stale -join ', '))
  exit 1
}
