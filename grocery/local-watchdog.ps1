<#
  local-watchdog.ps1 - Emails Brad if the LOCAL browser-store grocery agents stop refreshing.

  Division of alerting:
    - The CLOUD pipeline (server stores Hy-Vee/Aldi/Family Fare + compute/publish/feed) self-alerts via a
      failed GitHub Actions run -> GitHub emails Brad. Nothing here covers that.
    - THIS watchdog covers the BROWSER-only stores that need Brad's PC: Baker's (daily flash agent) and
      Sam's/Walmart (weekly browser refresh). If those data files stop updating, the local agents are
      failing / not running, and Brad gets one email.

  Runs headless via a WakeToRun Windows task ~45 min after the 6:00am agents. De-dupes on a signature so
  one outage = one email (re-alerts only when the stale set changes or clears). No repo state written.
#>
$ErrorActionPreference = 'Continue'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$out  = Join-Path $root 'out'

# SILENT-DEATH HEARTBEAT (2026-07-26): run the automation/output health check FIRST, unconditionally, so it
# fires on every watchdog invocation regardless of the browser-store outcome below (which exits early when
# fresh). This watchdog has its own independent WakeToRun trigger, so it is the right place to run a check
# that must not depend on the pipeline it watches. It self-alerts + de-dupes; we only surface a log line.
try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'health-heartbeat.ps1') -Alert | ForEach-Object { Write-Output ('heartbeat: ' + $_) } } catch { Write-Output ('heartbeat threw: ' + $_.Exception.Message) }
function NewestAgeDays($globs) {
  $m = $null
  foreach ($g in $globs) {
    $f = Get-ChildItem (Join-Path $out $g) -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($f -and (($null -eq $m) -or ($f.LastWriteTime -gt $m))) { $m = $f.LastWriteTime }
  }
  if ($null -eq $m) { return 9999 }
  return [math]::Round(((Get-Date) - $m).TotalDays, 1)
}
# Baker's: the daily flash agent is now EVENT-DRIVEN (it only scans on a sale-boundary day), so Baker's
#   data files legitimately sit unchanged for days between boundaries. The real staleness signal is the
#   WEEKLY ad pull: if the ad-schedule Baker's window has expired (current.to is in the past) the Wednesday
#   pull was genuinely missed. We read that window and only flag on a missed weekly pull, with a generous
#   file-age backstop (>9d) in case ad-schedule.json itself is missing/broken.
# Sam's/Walmart = weekly browser refresh (Wed-Sat) -> should be <= ~9 days.
$bakersAge = NewestAgeDays @('bakers\bakers-deals-*.json','regular\bakers-regular-*.json')
$weeklyAge = NewestAgeDays @('sams\sams-deals-*.json','regular\walmart-regular-*.json')

# Read the Baker's ad window from the schedule; stale only if that window has expired past a 1-day grace.
$bakersWindowExpired = $false
$bakersTo = $null
try {
  $sched = Get-Content (Join-Path $root 'ad-schedule.json') -Raw | ConvertFrom-Json
  $b = $sched.stores | Where-Object { $_.store -eq "Baker's" } | Select-Object -First 1
  if ($b -and $b.current -and $b.current.to) {
    $bakersTo = $b.current.to
    if (((Get-Date).Date - ([datetime]$bakersTo).Date).TotalDays -gt 1) { $bakersWindowExpired = $true }
  } else {
    # No usable window in the schedule -> fall back to the file-age backstop below.
    $bakersWindowExpired = $bakersAge -gt 9
  }
} catch {
  $bakersWindowExpired = $bakersAge -gt 9
}

$stale = @()
if ($bakersWindowExpired -or $bakersAge -gt 9) {
  $detail = if ($bakersTo) { "ad window ended " + $bakersTo + ", newest data " + $bakersAge + " days old" } else { "newest data " + $bakersAge + " days old" }
  $stale += ("Baker's weekly ad pull looks missed (" + $detail + ") - the Wednesday Baker's browser agent is not refreshing (PC asleep/off, or the Claude app is not running the agent).")
}
if ($weeklyAge -gt 9) { $stale += ("Sam's/Walmart data is " + $weeklyAge + " days old - the weekly browser refresh has not run.") }

$sig = ($stale -join ' | ')
$sigFile = Join-Path $env:LOCALAPPDATA 'smp-watchdog.sig'
$prev = if (Test-Path $sigFile) { (Get-Content $sigFile -Raw).Trim() } else { '' }

if ($stale.Count -eq 0) {
  if (Test-Path $sigFile) { Remove-Item $sigFile -ErrorAction SilentlyContinue }
  Write-Output ("watchdog: all fresh (Baker's " + $bakersAge + "d, weekly " + $weeklyAge + "d)")
  exit 0
}
if ($sig -eq $prev) { Write-Output ("watchdog: still stale, already alerted -> " + $sig); exit 0 }

$body = "The local Omaha grocery browser-store refresh looks stuck:`n`n - " + ($stale -join "`n - ") +
  "`n`nThe cloud pipeline (the server stores) is unaffected and alerts separately if IT fails. Please check that the PC is waking at 5:50am and the Claude app is open so the grocery agents can run.`n`n(You will not get another email for this same issue unless it changes or clears.)"
& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject "Grocery: local browser-store refresh STALE" -Body $body | Out-Null
if ($LASTEXITCODE -eq 0) { Set-Content -Path $sigFile -Value $sig -Encoding UTF8; Write-Output ("watchdog: ALERTED -> " + $sig) }
else { Write-Output "watchdog: alert send FAILED (send-alert returned nonzero)" }
