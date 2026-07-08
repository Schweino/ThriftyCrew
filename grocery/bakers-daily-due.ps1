<#
  bakers-daily-due.ps1 - idempotency guard for the DAILY Baker's flash-sale check agent.
  Baker's is the only BROWSER store with a weekly ad cycle, so a flash/weekend sale that starts or ends
  mid-cycle can't be seen by the headless daily job. This lets a tiny daily Chrome agent catch it, WITHOUT
  redundant work: it prints FRESH (skip, already refreshed today) or DUE (run the scan). Also prints ADFLIP
  when Baker's weekly ad has rolled (today >= next_pull) so the agent knows to pull the flyer too, not just
  the everyday scan. Prints one line; the agent reads the first token.
#>
$ErrorActionPreference = 'Stop'
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
  $b = @((Get-Content $sf -Raw | ConvertFrom-Json).stores) | Where-Object { $_.store -eq "Baker's" } | Select-Object -First 1
  if ($b -and $b.next_pull) { try { if ($today -ge ([datetime]$b.next_pull).Date) { $adflip = $true } } catch {} }
  # a missing or >6-day-old flyer also needs a fresh ad pull (safety net if a weekly run was missed)
  if (-not $deals -or $deals.LastWriteTime.Date -lt $today.AddDays(-6)) { $adflip = $true }
}

# the flyer freshness is judged on the DEALS file, not the everyday file: an agent that finished the
# everyday scan but died before the flyer pull must still get sent back for the flyer.
$flyerFresh = ($deals -and $deals.LastWriteTime.Date -eq $today)
if ($fresh -and $adflip -and (-not $flyerFresh)) {
  Write-Output "FRESH ADFLIP  everyday scan done today, but the weekly FLYER still needs pulling (step B only)"
} elseif ($fresh) {
  Write-Output ("FRESH  Baker's already refreshed today (" + $reg.LastWriteTime.ToString('MM-dd HH:mm') + ") - nothing to do")
} else {
  Write-Output ("DUE" + $(if ($adflip) { " ADFLIP  Baker's weekly ad has rolled - pull the flyer + everyday" } else { "  everyday flash scan (ad still current)" }))
}
