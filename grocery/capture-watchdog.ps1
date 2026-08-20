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
  # Check 7 below may only indict a headless lane on a day the daily capture actually ran.
  if ($isDaily) { $dailyRanToday = [bool]$ranToday }

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


# ---- 7. did each STORE actually contribute a fresh row, or just the pipeline? -------------------------
# THE HOLE THIS CLOSES. Checks 1-6 are all pipeline-level: the tasks fired, a board exists, it published.
# Every one of them passes while an individual store captures NOTHING, because carry-forward keeps that
# store's row count up and the board builds and ships regardless. Measured 2026-08-20: Fareway's sanctioned
# agent had gone structurally blind (the storefront went client-rendered, so its fetch-and-regex probe
# matched zero products and returned EMPTY for every term). A full sweep would have exited 0, raised no
# wall, and recorded that Fareway carries none of the ~700 things it sells - and this watchdog would have
# reported healthy, because a board WAS built and it WAS published.
#
# So this asks the one question the others do not: whose prices are actually NEW today?
#
# TWO POPULATIONS, TWO BARS, because one bar would be either noise or nothing:
#   HEADLESS lanes (Hy-Vee, Baker's, Family Fare) pull themselves. On a day the 08:00 job ran, a lane that
#     contributed zero fresh rows is broken - that is the Fareway shape, and it is a finding.
#   BROWSER lanes (Walmart, Sam's Club, Fareway, Aldi) are bot-walled and need a human in Chrome, so zero
#     rows on any given day is normal and flagging it daily would train the reader to ignore this email.
#     They are judged on AGE instead: under a 90-day rotation a store must keep contributing SOMETHING or
#     it can never finish a quarter. Seven days without a single fresh row means its rotation has stalled.
#     On the day this shipped that was true of Sam's Club (19d) and Walmart (9d) - both real, both already
#     carrying rescue worklists. It is not a quiet start; it is an accurate one.
$HEADLESS_LANES = @('Hy-Vee', "Baker's", 'Family Fare')
$BROWSER_STALE_DAYS = 7
$freshByStore = @{}; $newestByStore = @{}
foreach ($rf in (Get-ChildItem (Join-Path $OutDir 'regular\*-regular-*.json') -ErrorAction SilentlyContinue)) {
  try { $doc = Get-Content $rf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
  $st = [string]$doc.store
  if (-not $st) { continue }
  if (-not $freshByStore.ContainsKey($st)) { $freshByStore[$st] = 0 }
  foreach ($row in @($doc.deals)) {
    $a = [string]$row.as_of
    if ($a.Length -lt 10) { continue }
    $a = $a.Substring(0, 10)
    if ($a -eq $todayS) { $freshByStore[$st] = $freshByStore[$st] + 1 }
    if (-not $newestByStore.ContainsKey($st) -or $a -gt $newestByStore[$st]) { $newestByStore[$st] = $a }
  }
}
if (-not $newestByStore.Count) {
  # No dated rows anywhere is not "every store is fine" - it is this check failing to look.
  [void]$findings.Add('STORE FRESHNESS BLIND: no out\regular file carried a single dated row, so this check examined nothing. That is not a pass.')
} else {
  foreach ($st in ($newestByStore.Keys | Sort-Object)) {
    $fresh = [int]$freshByStore[$st]
    $newest = [string]$newestByStore[$st]
    $age = [int]((Get-Date $todayS) - (Get-Date $newest)).TotalDays
    if ($HEADLESS_LANES -contains $st) {
      # Only a day the daily job actually ran can indict a headless lane; otherwise nobody asked it for
      # anything and zero is the correct answer.
      if ($dailyRanToday -and $fresh -eq 0) {
        [void]$findings.Add(("NO FRESH ROWS: {0} has a headless lane and the 08:00 capture ran, but it contributed ZERO rows dated {1} (newest {2}, {3}d old). Its puller ran and saw nothing - check that lane before trusting its cells." -f $st, $todayS, $newest, $age))
      } else {
        [void]$ok.Add(("{0}: {1} fresh row(s) today (newest {2})" -f $st, $fresh, $newest))
      }
    } else {
      if ($age -gt $BROWSER_STALE_DAYS) {
        [void]$findings.Add(("ROTATION STALLED: {0} has contributed no fresh row for {1} day(s) (newest {2}). It is bot-walled, so this needs a Chrome pass - out\rescue-terms-*.txt names the cells that leave the board if it keeps slipping." -f $st, $age, $newest))
      } else {
        [void]$ok.Add(("{0}: {1} fresh row(s) today, newest {2} ({3}d)" -f $st, $fresh, $newest, $age))
      }
    }
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
