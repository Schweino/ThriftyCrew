<#
  fareway-daily-due.ps1 - idempotency + WINDOW-AWARE guard for the DAILY Fareway browser check.

  Fareway is a BROWSER store (shop.fareway.com storefront, Instacart platform - no headless API) with a weekly
  ad cycle (Sun-Sat) + a monthly ad. So when its ad drops off, the new everyday pricing can only be fetched with
  a browser - the headless daily job can't see it, and the weekly Wednesday agent alone would leave a Fareway
  sale ending on (say) Sunday stale until Wednesday. This guard decides whether the tiny daily Fareway browser
  agent needs to run. It prints ONE line; the agent reads the FIRST token:
    FRESH   - Fareway already refreshed today (weekly Wed agent, a prior run, or manual) -> STOP.
    IDLE    - nothing due: no ad flip today and no Fareway sale reverts/starts today -> STOP (skip the pull).
    DUE     - a Fareway sale boundary is due today (a sale reverts or a new sale starts) -> pull the storefront.
    DUE ... ADFLIP - the weekly (or monthly) ad has rolled today -> pull the storefront AND the ad images.

  Same window-aware design as bakers-daily-due.ps1: re-check exactly on the days a Fareway price is scheduled to
  move (sale_end + 1 = refresh day), not blindly every day. Undated flash sales (rare at Fareway) are the one
  accepted gap - caught by the weekly Wednesday pull. Fails SAFE (DUE) if the logs are missing/unreadable.
#>
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$out  = Join-Path $root 'out'
$today = (Get-Date).Date

# Fareway already refreshed today? (its everyday/storefront file dated today counts)
$reg = Get-ChildItem (Join-Path $out 'regular\fareway-regular-*.json') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$fresh = ($reg -and $reg.LastWriteTime.Date -eq $today)

# Fareway weekly OR monthly ad rolled today? (needs the fresh storefront pull + the ad images)
$adflip = $false
$sf = Join-Path $root 'ad-schedule.json'
if (Test-Path $sf) {
  $fw = @((Get-Content $sf -Raw | ConvertFrom-Json).stores) | Where-Object { $_.store -eq 'Fareway' } | Select-Object -First 1
  if ($fw) {
    if ($fw.next_pull) { try { if ($today -ge ([datetime]$fw.next_pull).Date) { $adflip = $true } } catch {} }
    if ($fw.monthly -and $fw.monthly.to) { try { if ($today -gt ([datetime]$fw.monthly.to).Date) { $adflip = $true } } catch {} }
  }
}
# a missing or >7-day-old storefront file also needs a fresh pull (safety net if a weekly run was missed)
if (-not $reg -or $reg.LastWriteTime.Date -lt $today.AddDays(-7)) { $adflip = $true }

# Is a Fareway DATED sale boundary due today? (a sale reverts today = refresh_on == today; or starts today)
$boundary = $false; $bReason = ''
$logFile = Join-Path $root 'sale-windows.json'
if (Test-Path $logFile) {
  try {
    $log = Get-Content $logFile -Raw | ConvertFrom-Json
    foreach ($w in $log.windows) {
      if ([string]$w.store -ne 'Fareway') { continue }
      $ro = $null; $ss = $null
      try { $ro = [datetime]$w.refresh_on } catch {}
      try { $ss = [datetime]$w.sale_start } catch {}
      if ($ro -ne $null -and $ro.Date -eq $today) { $boundary = $true; $bReason = ($w.commodity + ' sale reverts today'); break }
      if ($ss -ne $null -and $ss.Date -eq $today) { $boundary = $true; $bReason = ($w.commodity + ' sale starts today'); break }
    }
  } catch { $boundary = $true; $bReason = 'sale-window log unreadable - failing safe' }
} else {
  $boundary = $true; $bReason = 'no sale-window log yet - failing safe'
}

if ($fresh) {
  Write-Output ("FRESH  Fareway already refreshed today (" + $reg.LastWriteTime.ToString('MM-dd HH:mm') + ") - nothing to do")
} elseif ($adflip) {
  Write-Output "DUE ADFLIP  Fareway ad has rolled - pull the storefront + the ad images"
} elseif ($boundary) {
  Write-Output ("DUE  Fareway sale boundary today (" + $bReason + ") - re-pull the storefront prices")
} else {
  Write-Output "IDLE  no Fareway ad flip and no Fareway sale starts/reverts today - skip the pull (event-driven)"
}
