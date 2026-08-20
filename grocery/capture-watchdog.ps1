<#
  capture-watchdog.ps1 - did today's capture actually happen, and did it publish?

  WHY THIS EXISTS. The old SMP Grocery Failure Watchdog watched the old jobs; those
  jobs are gone, replaced by TC Grocery Ad Pulls 0700 and TC Grocery Daily Capture
  0800. Without a replacement NOTHING notices if the new schedule stops firing -
  and a capture pipeline that silently stops is indistinguishable from one where
  prices simply have not changed. The board keeps serving, quietly going stale.

  IT CHECKS OUTCOMES, NOT JUST EXIT CODES. A task can report success and still have
  done nothing (the shape this estate keeps rediscovering: a confident ok over an
  empty examination). So this asks, in order:

    1. SCHEDULE     do both tasks still exist, enabled, with a next run?
    2. RAN          did each fire today, and what did it exit with?
    3. CAPTURED     is there a comparison board dated today?
    4. PUBLISHED    is public\board.json newer than that board?
    5. AD HEALTH    audit-ad-status: any store's ad closed or its pull overdue?
    6. BROWSER      is a browser-capture flag still sitting unworked?

  Anything that fails is ONE email, not six. Exit 0 = healthy, 1 = findings.
#>
param([switch]$Alert, [string]$OutDir = '', [string]$Today = '')

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
. (Join-Path $root 'alert-lib.ps1')

$TASKS = @('TC Grocery Ad Pulls 0700', 'TC Grocery Daily Capture 0800')
$findings = New-Object System.Collections.Generic.List[string]
$ok = New-Object System.Collections.Generic.List[string]

# ---- 1 + 2. the schedule, and whether it fired ------------------------------
foreach ($name in $TASKS) {
  $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if (-not $t) { [void]$findings.Add("MISSING TASK: '$name' does not exist. Nothing is capturing on that schedule."); continue }
  if ($t.State -eq 'Disabled') { [void]$findings.Add("DISABLED: '$name' is disabled, so it will never fire."); continue }

  $i = $t | Get-ScheduledTaskInfo
  $last = $i.LastRunTime
  $rc = $i.LastTaskResult

  # The 08:00 job is the one that must run EVERY day. The 07:00 ad job legitimately
  # does nothing on days no ad rolled over, so "did not run today" is only a finding
  # for the daily one; for the ad job we report its last result instead.
  $isDaily = $name -like '*Daily Capture*'
  $ranToday = $last -and ($last.ToString('yyyy-MM-dd') -eq $todayS)

  # Windows sentinels, which are NOT failures and must not be reported as such:
  #   267011 SCHED_S_TASK_HAS_NOT_RUN  - registered but its trigger has not come round yet
  #   267009 SCHED_S_TASK_RUNNING      - in flight right now
  # A task created today reads as 267011 with a 1999 timestamp; calling that
  # "FAILED" on day one would train the reader to ignore this watchdog before it
  # has ever reported anything real.
  $neverRan = ($rc -eq 267011) -or (-not $last) -or ($last.Year -lt 2000)

  if ($neverRan) {
    $next = if ($i.NextRunTime) { $i.NextRunTime.ToString('yyyy-MM-dd HH:mm') } else { 'unscheduled' }
    [void]$ok.Add("$name has not run yet (registered; next $next)")
  } elseif ($rc -eq 267009) {
    [void]$ok.Add("$name is running now")
  } elseif ($isDaily -and -not $ranToday) {
    [void]$findings.Add("DID NOT RUN: '$name' last ran $last - nothing captured today.")
  } elseif ($rc -ne 0) {
    [void]$findings.Add("FAILED: '$name' last run $last exited $rc.")
  } else {
    [void]$ok.Add("$name ran $last rc=$rc")
  }
}

# ---- 3. is there a board for today? -----------------------------------------
$cmp = Join-Path $OutDir "comparison-$todayS.json"
if (-not (Test-Path $cmp)) {
  $newest = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -EA SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1
  [void]$findings.Add("NO BOARD FOR TODAY: comparison-$todayS.json missing (newest is $(if($newest){$newest.Name}else{'none'})). Capture ran but the board was not recomputed.")
} else {
  [void]$ok.Add("board comparison-$todayS.json present")
}

# ---- 4. did it reach the live site? -----------------------------------------
# public\board.json is what the Worker serves. If it is OLDER than the comparison,
# the recompute happened but the publish did not, and the site is serving a board
# that no longer matches the data behind it.
$pub = Join-Path (Split-Path $root -Parent) 'public\board.json'
if ((Test-Path $cmp) -and (Test-Path $pub)) {
  $cT = (Get-Item $cmp).LastWriteTime; $pT = (Get-Item $pub).LastWriteTime
  if ($pT -lt $cT.AddMinutes(-30)) {
    [void]$findings.Add("NOT PUBLISHED: public\board.json is $([int]($cT - $pT).TotalMinutes) min older than today's comparison. The board was rebuilt but never shipped.")
  } else {
    [void]$ok.Add('public\board.json is current with the comparison')
  }
}

# ---- 5. ad health ------------------------------------------------------------
$adsc = Join-Path $root 'audit-ad-status.ps1'
if (Test-Path $adsc) {
  $adOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $adsc -OutDir $OutDir -Today $todayS 2>&1
  $adRc = $LASTEXITCODE
  $line = ($adOut | Where-Object { $_ -match 'stores needing a pull' } | Select-Object -First 1)
  if ($adRc -ne 0) { [void]$findings.Add("AD STALE: $line") } else { [void]$ok.Add(($line -replace '\s+', ' ').Trim()) }
}

# ---- 6. browser work left undone --------------------------------------------
# The browser stores cannot be captured headlessly, so the runner leaves a flag.
# A flag older than a day means nobody worked the list and those stores are
# silently aging - which is exactly what happened to Fareway for five days.
$flags = Get-ChildItem (Join-Path $OutDir 'browser-capture-due-*.flag') -EA SilentlyContinue
foreach ($f in $flags) {
  $age = ((Get-Date) - $f.LastWriteTime).TotalDays
  if ($age -gt 1.5) {
    [void]$findings.Add("BROWSER WORK STALE: $($f.Name) is $([int]$age) day(s) old - the walled stores have not been captured. Open a Chrome tab per store and work out\worklists\.")
  }
}

# ---- report ------------------------------------------------------------------
Write-Output "CAPTURE WATCHDOG - $todayS"
foreach ($o in $ok) { Write-Output "  ok    $o" }
foreach ($f in $findings) { Write-Output "  FIND  $f" }

if ($findings.Count -and $Alert) {
  $body = "Capture watchdog found $($findings.Count) issue(s) on $todayS.`n`n" +
          (($findings | ForEach-Object { " - $_" }) -join "`n") +
          "`n`nHealthy checks:`n" + (($ok | ForEach-Object { " - $_" }) -join "`n")
  try { Send-Alert -Subject "Grocery capture watchdog: $($findings.Count) issue(s) $todayS" -Body $body | Out-Null } catch { }
}

Write-Output ("CAPTURE-WATCHDOG-COMPLETE findings={0}" -f $findings.Count)
if ($findings.Count) { exit 1 } else { exit 0 }
