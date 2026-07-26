<#
  bakers-daily-scan.ps1 - the DAILY 6am Baker's price refresh as a plain script (2026-07-26: converted
  from the grocery-bakers-daily-flash-check Claude agent - every step was deterministic; only the weekly
  ad-flip FLYER vision-read needs an agent, and that stays with the weekly Wednesday agent / triage).

  WHAT IT GUARANTEES (Brad's spec):
   1. The morning a weekly ad ends, expired sale items REPRICE (the API scan returns current shelf price;
      compare-deals reverts them) and the new ad's promo prices flow in the same pull.
   2. Temporary/flash sales: their dates are STORED per item in out\sale-windows.json (rebuilt every run
      by check-ad-cycles -NoPull via build-sale-windows.ps1, refresh_on = sale_end + 1), and because this
      runs EVERY day at 6am, the day-after-sale reprice happens automatically - including for
      UNADVERTISED promos the window log cannot foresee (the Heritage Farm $1.99 lesson, 2026-07-25).

  Steps (mirrors the retired agent SKILL exactly):
    0 guard (bakers-daily-due) - FRESH stops; ADFLIP raises a triage alert for the flyer capture
    0.5 git pull --rebase --autostash (recompute on top of cloud state)
    A pull-regular-bakers-api (Saddlecreek 61500319; refuses unprovable pack bases - never guesses)
      + refresh-bakers-links (link snapshots must carry the same reading)
    C check-ad-cycles -NoPull (re-compare, rebuild sale windows, republish ONLY if the price signature
      changed, guards + visibility preserved)
    D push-data (commit raw store inputs, rebase, push)
  Any failure -> send-alert (lands in triage-queue.json for the twice-daily triage agent) + exit 1.
  Scheduled via Windows task "SMP Bakers Daily Scan" at 6:00 daily (runs Wednesdays too - the API scan
  is cheap and complements the 6:15 weekly browser agent; the guard's FRESH check prevents double work).
#>
param([switch]$Force)   # -Force: skip the FRESH short-circuit (testing / manual re-run)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$logDir = Join-Path $root 'out\logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir ('bakers-daily-scan-' + (Get-Date -Format 'yyyy-MM') + '.log')
# Write-Host, NOT Write-Output: Log is called inside RunChild, and function pipeline output would
# pollute RunChild's return value (the first test's $rc became [logline, logline, 0] - an array).
function Log([string]$m){ $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m; Add-Content -Path $log -Value $line; Write-Host $line }
# Run a child script, tolerant of stderr noise (PS5.1 + EAP=Stop turns redirected child stderr into a
# terminating error - that killed the first test run on a downstream script's non-fatal error line).
function RunChild([string]$file,[object[]]$childArgs,[int]$keep=2,[string]$tag='child'){
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $out = & powershell -ExecutionPolicy Bypass -File $file @childArgs 2>&1 | ForEach-Object { [string]$_ }
    $ec = $LASTEXITCODE
    @($out | Select-Object -Last $keep) | ForEach-Object { Log ($tag + ': ' + $_) }
    return [int]$ec
  } finally { $ErrorActionPreference = $prev }
}
function Alert([string]$subject,[string]$body){
  try { & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'send-alert.ps1') -Subject $subject -Body $body | Out-Null } catch { Log ('send-alert itself failed: ' + $_.Exception.Message) }
}

try {
  # ---- 0 guard ----
  $guard = (& powershell -ExecutionPolicy Bypass -File (Join-Path $root 'bakers-daily-due.ps1')) -join ' '
  Log ('guard: ' + $guard)
  if ($guard -match '^\s*FRESH' -and -not $Force) { Log 'Baker''s already refreshed today - stop.'; exit 0 }
  $adflip = ($guard -match 'ADFLIP')

  # ---- 0.5 sync ----
  try { git -C (Split-Path $root -Parent) pull --rebase --autostash origin main 2>&1 | Select-Object -Last 1 | ForEach-Object { Log ('git: ' + $_) } } catch { Log ('git pull warn: ' + $_.Exception.Message) }

  # ---- A: headless API scan ----
  $rc = RunChild (Join-Path $root 'pull-regular-bakers-api.ps1') @() 2 'api'
  if ($rc -ne 0) { throw "pull-regular-bakers-api exited $rc (thin pull or API failure) - newest existing capture keeps serving" }
  $rc = RunChild (Join-Path $root 'refresh-bakers-links.ps1') @() 1 'links'
  if ($rc -ne 0) { Log 'WARN refresh-bakers-links nonzero (continuing - guard 4 may flag link disagreements)' }

  # ---- C: re-compare + sale windows + publish-if-changed ----
  $rc = RunChild (Join-Path $root 'check-ad-cycles.ps1') @('-NoPull') 3 'cycle'
  if ($rc -ne 0) { throw "check-ad-cycles -NoPull exited $rc" }

  # ---- D: push raw inputs ----
  $rc = RunChild (Join-Path $root 'push-data.ps1') @() 1 'push'

  # ---- ADFLIP: flyer needs eyes (vision). Weekly Wed agent covers Wednesdays 6:15; anything else -> triage.
  if ($adflip) {
    $dow = (Get-Date).DayOfWeek
    if ($dow -ne 'Wednesday') {
      Alert "Baker's ad rolled (ADFLIP) on a $dow - flyer capture needed" "bakers-daily-scan: the guard reported ADFLIP outside the weekly Wednesday agent window. Prices are refreshed headlessly, but the FLYER (vision read) has not been captured. Triage: run the weekly SKILL step A flyer capture for Baker's (bakersplus.com/weeklyad, Pickup at Saddlecreek), then update ad-schedule.json."
      Log 'ADFLIP on non-Wednesday: prices refreshed; flyer capture alert queued for triage.'
    } else {
      Log 'ADFLIP on Wednesday: weekly 6:15 agent will capture the flyer.'
    }
  }
  Log 'bakers-daily-scan OK'
  exit 0
} catch {
  Log ('FAIL: ' + $_.Exception.Message)
  Alert "bakers-daily-scan FAILED" ("bakers-daily-scan.ps1 failed at " + (Get-Date -Format s) + ": " + $_.Exception.Message + " | Log: " + $log + " | The newest existing Baker's capture keeps serving; triage should investigate and re-run.")
  exit 1
}