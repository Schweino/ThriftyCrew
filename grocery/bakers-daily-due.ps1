<#
  bakers-daily-due.ps1 - idempotency + WINDOW-AWARE guard for the DAILY Baker's flash-sale check agent.

  Baker's is the only BROWSER store with a weekly ad cycle, so a flash/weekend sale that starts or ends
  mid-cycle can't be seen by the headless daily job. This decides whether the tiny daily Chrome agent needs
  to run at all. It prints ONE line; the agent reads the FIRST token:
    FRESH   - Baker's already refreshed today (weekly Wed agent, a prior run, or manual) -> STOP, nothing to do.
    IDLE    - no ADVERTISED boundary today. Since 2026-07-25 this is INFORMATIONAL ONLY - the 6am agent
              runs the headless API scan every day regardless, because unadvertised promos (the Heritage
              Farm $1.99 morning) are invisible to this window log by definition. Only FRESH skips.
    DUE     - a Baker's sale boundary is due today (a sale ends+reverts, or a new sale starts) -> run the scan.
    DUE ... ADFLIP - the weekly ad has rolled (today >= next_pull) -> also pull the flyer (step B), not just the scan.

  WINDOW-AWARE (2026-07-09): instead of scanning Baker's blindly every single day, we read sale-windows.json
  (built by build-sale-windows.ps1) and only scan when an item's KNOWN sale window actually opens or closes.
  refresh_on = sale_end + 1 = the day a sale's price reverts, so that's the day to re-check. This turns "poll
  daily just in case" into "re-check exactly on the days a Baker's price is scheduled to move."
  HONEST GAP: a brand-new UNADVERTISED flash sale (no date in any feed) can't be predicted, so an undated
  Baker's flash START is only caught on the weekly Wednesday pull. Every DATED sale (the vast majority) is
  caught precisely. If the log is missing/unreadable we fail SAFE (DUE) so we never silently stop scanning.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$out  = Join-Path $root 'out'
$today = (Get-Date).Date

# Baker's already refreshed today? (weekly Wed agent, a prior daily run, or a manual pull all count)
$reg = Get-ChildItem (Join-Path $out 'regular\bakers-regular-*.json') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$deals = Get-ChildItem (Join-Path $out 'bakers\bakers-deals-*.json') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$fresh = ($reg -and $reg.LastWriteTime.Date -eq $today)

# Baker's weekly ad rolled? (needs the flyer vision-read, not just the everyday scan)
$adflip = $false
$sf = Join-Path $root 'ad-schedule.json'
if (Test-Path $sf) {
  $b = @((Read-JsonFile $sf).stores) | Where-Object { $_.store -eq "Baker's" } | Select-Object -First 1
  if ($b -and $b.next_pull) { try { if ($today -ge ([datetime]$b.next_pull).Date) { $adflip = $true } } catch {} }
  # a missing or >6-day-old flyer also needs a fresh ad pull (safety net if a weekly run was missed)
  if (-not $deals -or $deals.LastWriteTime.Date -lt $today.AddDays(-6)) { $adflip = $true }
}

# Is a Baker's DATED sale boundary due today? (a sale reverts today = refresh_on == today; or a new sale
# starts today = sale_start == today). Read from the per-item sale-window log.
$boundary = $false; $bReason = ''
$logFile = Join-Path $root 'sale-windows.json'
if (Test-Path $logFile) {
  try {
    $log = Read-JsonFile $logFile
    foreach ($w in $log.windows) {
      if ([string]$w.store -ne "Baker's") { continue }
      $ro = $null; $ss = $null
      try { $ro = [datetime]$w.refresh_on } catch {}
      try { $ss = [datetime]$w.sale_start } catch {}
      if ($ro -ne $null -and $ro.Date -eq $today) { $boundary = $true; $bReason = ($w.commodity + " sale reverts today"); break }
      if ($ss -ne $null -and $ss.Date -eq $today) { $boundary = $true; $bReason = ($w.commodity + " sale starts today"); break }
    }
  } catch { $boundary = $true; $bReason = 'sale-window log unreadable - failing safe' }
} else {
  # no log yet -> we can't know boundaries, so fail SAFE and scan (also seeds the log via step C).
  $boundary = $true; $bReason = 'no sale-window log yet - failing safe'
}

# the flyer freshness is judged on the DEALS file, not the everyday file: an agent that finished the
# everyday scan but died before the flyer pull must still get sent back for the flyer.
$flyerFresh = ($deals -and $deals.LastWriteTime.Date -eq $today)
if ($fresh -and $adflip -and (-not $flyerFresh)) {
  Write-Output "FRESH ADFLIP  everyday scan done today, but the weekly FLYER still needs pulling (step B only)"
} elseif ($fresh) {
  Write-Output ("FRESH  Baker's already refreshed today (" + $reg.LastWriteTime.ToString('MM-dd HH:mm') + ") - nothing to do")
} elseif ($adflip) {
  Write-Output "DUE ADFLIP  Baker's weekly ad has rolled - pull the flyer + everyday"
} elseif ($boundary) {
  Write-Output ("DUE  Baker's sale boundary today (" + $bReason + ") - re-check the everyday prices")
} else {
  Write-Output "IDLE  no ADVERTISED Baker's boundary today (informational - the API scan runs anyway; unadvertised promos are exactly what it catches)"
}
