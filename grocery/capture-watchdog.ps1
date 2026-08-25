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
param([switch]$Alert, [string]$OutDir = '', [string]$Today = '', [switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
$todayS = if ($Today) { $Today } else { (Get-Date).ToString('yyyy-MM-dd') }
. (Join-Path $root 'run-log-lib.ps1')
. (Join-Path $root 'native-lib.ps1')   # Invoke-Native: the ONLY safe way to redirect a native child under EAP=Stop

# Runs hidden from a scheduled task, so its findings only existed in an email.
# The transcript keeps the evidence even when the alert de-dup suppresses the mail.
# -SelfTest is excluded: it is a foreground developer action, not a scheduled run.
$runLog = if ($SelfTest) { $null } else { Start-RunLog -Name 'capture-watchdog' -OutDir $OutDir -Today $todayS }

# How long a registered-but-never-fired task is still innocently "waiting for its trigger".
# One full daily cycle plus a margin: a task registered AFTER today's slot (exactly how the
# 07:00 and 08:00 capture tasks were created on 2026-08-20, at 08:24) legitimately cannot run
# until tomorrow, and calling that broken on day one would train the reader to ignore this
# watchdog before it had ever reported anything real.
$script:NeverRanGraceHours = 30

function Test-NeverRanTooLong {
  <#
    .SYNOPSIS Has a task that has NEVER fired been waiting long enough to call it broken?
    .DESCRIPTION Pure, so the -SelfTest fixture below can drive it without a real Task
                 Scheduler. Returns $false when the start boundary is unknown: an unreadable
                 trigger is not evidence of a fault, and inventing one would be worse than
                 the silence this replaces.
  #>
  param([datetime]$TriggerStart, [datetime]$Now, [int]$GraceHours = 0)
  if ($GraceHours -le 0) { $GraceHours = $script:NeverRanGraceHours }
  if (-not $TriggerStart -or $TriggerStart.Year -lt 2000) { return $false }
  return ((($Now - $TriggerStart).TotalHours) -gt $GraceHours)
}

if ($SelfTest) {
  # Frozen fixtures: the founding bug (a task that never runs, reported green forever) and
  # its clean twin (a task legitimately still waiting for its first slot).
  $fail = 0
  $now = [datetime]'2026-08-21 06:47'

  # MUST FIRE: registered four days ago, still never run.
  if (-not (Test-NeverRanTooLong -TriggerStart ([datetime]'2026-08-17 07:00') -Now $now)) {
    Write-Output 'FAIL  a task registered 4 days ago that never fired read as ok - the gate cannot arm'; $fail++
  } else { Write-Output 'ok    4-day-old never-run task is a finding' }

  # CLEAN TWIN: registered yesterday after its own slot; its first real chance is today.
  if (Test-NeverRanTooLong -TriggerStart ([datetime]'2026-08-20 07:00') -Now $now) {
    Write-Output 'FAIL  a task still inside its first cycle was called broken - day-one false alarm'; $fail++
  } else { Write-Output 'ok    task still inside its first cycle stays ok' }

  # An unreadable trigger must not manufacture a finding.
  if (Test-NeverRanTooLong -TriggerStart ([datetime]'1999-11-30') -Now $now) {
    Write-Output 'FAIL  an unknown trigger start produced a finding out of nothing'; $fail++
  } else { Write-Output 'ok    unknown trigger start -> no invented finding' }

  Write-Output ("SELFTEST " + $(if ($fail) { "FAILED ($fail)" } else { 'PASSED' }))
  exit $(if ($fail) { 1 } else { 0 })
}
. (Join-Path $root 'alert-lib.ps1')

# ---- 0. SILENT-DEATH HEARTBEAT (moved here 2026-08-22 from the retired local-watchdog.ps1) ----------
# health-heartbeat.ps1 watches expected-automations.json for a task that quietly stopped being scheduled
# or an output that quietly went stale. Its only runner was local-watchdog, retired with the old 8:30
# pipeline, so for two days nothing ran it. It self-alerts and de-dupes; this just surfaces a line.
# No 2>&1 on the child (EAP=Stop turns its first stderr line into a terminating throw - test-native-stderr-eap.ps1).
try { $hbOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'health-heartbeat.ps1') -Alert; @($hbOut) | ForEach-Object { Write-Output ('heartbeat: ' + $_) } } catch { Write-Output ('heartbeat threw: ' + $_.Exception.Message) }

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
    # "Not yet" is only innocent while it is still EARLY. A task registered days ago that has
    # still never fired is not waiting for its trigger, it is broken - a bad principal, a
    # condition that never holds, a StartBoundary in the past. Left as a permanent `ok` this
    # is a gate that can never arm: the one state it exists to catch would read green forever.
    # The grace is one full cycle plus a margin, so a task created after today's slot (which is
    # exactly how these two were registered on 2026-08-20) still gets its first real chance.
    $start = $null
    try { if ($t.Triggers[0].StartBoundary) { $start = [datetime]$t.Triggers[0].StartBoundary } } catch { }
    if (Test-NeverRanTooLong -TriggerStart $start -Now (Get-Date)) {
      $days = [int]((Get-Date) - $start).TotalDays
      [void]$findings.Add("NEVER RAN: '$name' was registered $days day(s) ago (trigger $($start.ToString('yyyy-MM-dd HH:mm'))) and has still never fired. Next says $next. A trigger that has never produced a run is not waiting, it is misconfigured.")
    } else {
      [void]$ok.Add("$name has not run yet (registered; next $next)")
    }
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

# ---- 2b. the run's OWN record (2026-08-22) ---------------------------------------------------
# capture-run.ps1 stamps out\logs\capture-run-status.json at start / capturing / downstream / complete
# with its exit code. Task Scheduler only knows the process ended; this knows how far it got. A run
# stuck in 'downstream' hours later, or one that never reached 'complete', is a finding even when the
# task reports rc=0 - and it does not depend on ad-cycle-log.txt, which another process can hold mute.
$statusF = Join-Path $OutDir 'logs\capture-run-status.json'
if (Test-Path $statusF) {
  try {
    $st = Get-Content $statusF -Raw | ConvertFrom-Json
    foreach ($kind in @('ad', 'daily')) {
      $r = $st.$kind
      if (-not $r) { continue }
      if ([string]$r.date -ne $todayS) { if ($kind -eq 'daily') { [void]$findings.Add("RUN RECORD: the daily capture-run left no record for today (last $($r.date), stage $($r.stage)).") }; continue }
      $ageMin = [int]((Get-Date) - [datetime]$r.updated).TotalMinutes
      if ([string]$r.stage -eq 'complete') {
        if ([int]$r.exit_code -ne 0) { [void]$findings.Add("RUN RECORD: capture-run [$kind] completed with exit $($r.exit_code) - see $($r.log)") }
        else { [void]$ok.Add("capture-run [$kind] completed rc=0 at $($r.updated)") }
      } elseif (@('started','capturing','downstream','publishing') -notcontains [string]$r.stage) {
        # An UNRECOGNISED stage is not a healthy one. 'whatif' used to land here and read as ok simply
        # because it was under the age bar - the failure mode this whole check exists to end.
        [void]$findings.Add("RUN RECORD: capture-run [$kind] left stage '$($r.stage)', which is not a stage a real run passes through. Its record cannot be trusted to say whether today's prices were built.")
      } elseif ($ageMin -gt 90) {
        [void]$findings.Add("RUN RECORD: capture-run [$kind] has sat in stage '$($r.stage)' for $ageMin min (pid $($r.pid)) - it never reached 'complete'. Log: $($r.log)")
      } else { [void]$ok.Add("capture-run [$kind] in stage '$($r.stage)' ($ageMin min)") }
    }
  } catch { [void]$findings.Add("RUN RECORD: $statusF is unreadable ($($_.Exception.Message))") }
} else {
  [void]$findings.Add("RUN RECORD: $statusF does not exist - capture-run has not written its own record; only Task Scheduler's word says it ran.")
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

# ---- 4b. DID IT REACH MAIN? (added 2026-08-22, after four days of the answer being "no") ------------
# CHECK 4 ABOVE COMPARES TWO LOCAL FILES AND IS SATISFIED BY BOTH BEING FRESH ON DISK. That is not the
# product. Cloudflare deploys public\** FROM THE GIT REPO, so a price reaches a reader only once it is
# committed AND pushed. When the 2026-08-20 cutover moved the pipeline onto the three TC tasks it left
# the commit+push step behind in run-daily-local.ps1: the board was rebuilt every morning, check 4 said
# "current with the comparison" every morning, and the last smp-pipeline-bot commit was 2026-08-18. The
# live site served four-day-old prices while every check in this file was green.
# So ask the question the product cares about: is what the pipeline computed actually ON MAIN? Two
# independent signals, because either alone can lie - a bot commit can exist without the served files in
# it, and a clean tree can mean "nothing ran" as easily as "everything shipped".
$repoRoot = Split-Path $root -Parent
try {
  # Invoke-Native, not `git ... 2>$null`. This file sets EAP='Stop', and under Stop a redirect on a
  # native child turns its FIRST stderr line into a TERMINATING error - `2>$null` causes that, it does
  # not prevent it. git writes ordinary progress to stderr, so the watchdog's own "did it reach main?"
  # check was one noisy git invocation away from killing the watchdog. See native-lib.ps1.
  $lbR = Invoke-Native 'git' '-C' $repoRoot 'log' '--author=smp-pipeline-bot' '-1' '--format=%cd' '--date=format:%Y-%m-%d'
  $lastBot = @($lbR.Output) | Select-Object -First 1
  $botAge = if ($lastBot) { [int]((Get-Date).Date - ([datetime]$lastBot)).TotalDays } else { 9999 }
  # the served files, as git sees them: dirty = computed but never shipped
  $dirtyR = Invoke-Native 'git' '-C' $repoRoot 'status' '--porcelain' '--' 'public/board.json' 'public/smp-feed.json'
  $dirty = @($dirtyR.Output | Where-Object { $_ })
  if ($botAge -gt 2) {
    $seen = if ($lastBot) { "the last pipeline commit is $lastBot ($botAge days ago)" } else { 'there is NO pipeline commit in this history' }
    [void]$findings.Add("NEVER REACHED MAIN: $seen. Cloudflare deploys public\** from the repo, so the live board and feed are stale by that much no matter how fresh the local files look. Check the publish stage at the end of capture-run.ps1 (commit -> push -> edge verify).")
  } elseif ($dirty.Count) {
    [void]$findings.Add("COMPUTED BUT NOT SHIPPED: " + ($dirty -join ', ') + " are modified in the working tree after today's run. The pipeline rebuilt them and the commit/push did not take them, so readers still get the previous board.")
  } else {
    [void]$ok.Add("reached main: last pipeline commit $lastBot, served files clean in git")
  }
} catch { [void]$findings.Add("could not ask git whether today's prices reached main ($($_.Exception.Message)) - the one check that speaks for the READER is unavailable") }

# ---- 5. ad health ------------------------------------------------------------
$adsc = Join-Path $root 'audit-ad-status.ps1'
if (Test-Path $adsc) {
  # NO 2>&1 (fixed 2026-08-22, same class as the capture-run downstream call).
  # This script sets EAP=Stop, and in PS 5.1 redirecting a native child's stderr
  # turns each line into a NativeCommandError that TERMINATES the caller. The day
  # audit-ad-status.ps1 writes a single warning, this watchdog would die right here
  # - silently skipping checks 6-8, which are the browser-flag and store-freshness
  # checks. A watchdog that stops examining halfway and still exits through its own
  # summary is worse than no watchdog: it reports on what it managed to reach.
  # Latent when found (audit-ad-status is currently quiet); fixed while it is cheap.
  $adOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $adsc -OutDir $OutDir -Today $todayS
  $adRc = $LASTEXITCODE
  $line = ($adOut | Where-Object { $_ -match 'stores needing a pull' } | Select-Object -First 1)
  if ($adRc -ne 0) { [void]$findings.Add("AD STALE: $line") } else { [void]$ok.Add(($line -replace '\s+', ' ').Trim()) }
}

# ---- 5b. rollback / instant-savings windows about to expire ------------------
# THE OTHER HALF OF "STALE IS NOT A BAD THING". Everyday prices are allowed to be a quarter old;
# a PROMO price is not. Walmart, Sam's Club and Fareway publish no end date for a rollback, so
# rollback-ttl-lib anchors a 30-day window to first detection and the builders revert the price when
# it lapses. That revert is invisible until it happens: a wave of cells quietly gets more expensive.
# Reported as a COUNT with the nearest date, not per item - it is a heads-up, never a failure.
#
# WHAT THIS CHECK MEASURES, AND WHY IT CHANGED (2026-08-25). It used to report the number of LEDGER
# entries past their TTL and say "if this count does not fall after the next capture, the revert is
# not running". THAT TEST CAN NEVER PASS. rollback-first-seen.json is append-only by design - see
# rollback-ttl-lib.ps1: first_seen is "written ONCE per (store, item) and is NEVER advanced", and
# nothing prunes an entry - so once a window passes day 30 it stays past day 30 forever and the count
# only ever climbs. It sat at exactly 47 for four days while the board was in fact reverting every
# one of them, which is a false alarm that teaches the reader to skip this section - the failure mode
# a watchdog can least afford. The FAILURE the finding was reaching for is a board that still SELLS
# an expired promo, so that is what is counted now: live cells whose ad window closed before this
# board's date. That number can fall, and zero is provable. The ledger count is kept, demoted to an
# ok line, and labelled cumulative so its flatness is never read as a stall again.
try {
  $rbLedger = Join-Path $root 'rollback-first-seen.json'
  if (Test-Path $rbLedger) {
    $rb = Get-Content $rbLedger -Raw -Encoding UTF8 | ConvertFrom-Json
    $ttl = if ($rb.ttl_days) { [int]$rb.ttl_days } else { $ROLLBACK_TTL }
    $expired = 0; $soon = 0; $nextDate = ''; $ledgerTotal = 0
    foreach ($e in @($rb.entries)) {
      $fs = [string]$e.first_seen
      if ($fs.Length -lt 10) { continue }
      try { $exp = ([datetime]::ParseExact($fs, 'yyyy-MM-dd', $null)).AddDays($ttl) } catch { continue }
      $ledgerTotal++
      $daysLeft = [int]($exp - (Get-Date $todayS)).TotalDays
      if ($daysLeft -lt 0) { $expired++ }
      elseif ($daysLeft -le 7) {
        $soon++
        if (-not $nextDate -or $exp.ToString('yyyy-MM-dd') -lt $nextDate) { $nextDate = $exp.ToString('yyyy-MM-dd') }
      }
    }

    # THE HALF THAT CAN ACTUALLY FAIL: an expired window still priced on the board readers see.
    # price-table-<today>.json is the per-cell artifact that carries ad_to, so it is what gets asked.
    $ptf = Join-Path $OutDir "price-table-$todayS.json"
    if (Test-Path $ptf) {
      $boardDate = Get-Date $todayS
      $staleCells = 0; $adCells = 0; $oldestClosed = ''
      $pt = Get-Content $ptf -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($it in @($pt.items)) {
        foreach ($sp in $it.stores.PSObject.Properties) {
          $cell = $sp.Value
          if ($null -eq $cell.ad) { continue }
          $adCells++
          $at = [string]$cell.ad_to
          if ($at -notmatch '^\d{4}-\d{2}-\d{2}$') { continue }
          try { $atd = [datetime]::ParseExact($at, 'yyyy-MM-dd', $null) } catch { continue }
          if ($atd -lt $boardDate) {
            $staleCells++
            if (-not $oldestClosed -or $at -lt $oldestClosed) { $oldestClosed = $at }
          }
        }
      }
      if ($staleCells -gt 0) {
        [void]$findings.Add(("ROLLBACK NOT REVERTING: {0} of {1} live board cell(s) still serve a promo price whose window has closed (oldest closed {2}). The builders should have reverted these to everyday pricing - THIS is the count that must fall after the next capture." -f $staleCells, $adCells, $oldestClosed))
      } else {
        [void]$ok.Add(("rollback revert: 0 of {0} live ad cell(s) carry a closed window - every lapsed promo reverted to everyday pricing" -f $adCells))
      }
    } else {
      # Say so rather than pass silently: an unrun check must never read as a clean one.
      [void]$ok.Add(("rollback revert: NOT CHECKED - price-table-$todayS.json is not present"))
    }

    if ($expired -gt 0) {
      # DELIBERATELY an ok line and not a finding, for the reason set out in the header: this number
      # is cumulative and does not fall, so on its own it can never be a regression signal.
      [void]$ok.Add(("rollback ledger: {0} of {1} window(s) past their {2}-day TTL - cumulative, and NOT expected to fall (first_seen never advances, entries are never pruned); what matters is whether any reach the board, checked above" -f $expired, $ledgerTotal, $ttl))
    }
    if ($soon -gt 0) {
      [void]$ok.Add(("rollback windows: {0} expire within 7 days (first {1}) - those cells revert to everyday pricing" -f $soon, $nextDate))
    } elseif ($expired -eq 0) {
      [void]$ok.Add(("rollback windows: none expired, none expiring within 7 days ({0}-day TTL)" -f $ttl))
    }
  }
} catch { [void]$ok.Add('rollback window check skipped: ' + $_.Exception.Message) }

# ---- 6. browser work left undone --------------------------------------------
# The browser stores cannot be captured headlessly, so the runner leaves a flag.
# A flag older than a day means nobody worked the list and those stores are
# silently aging - which is exactly what happened to Fareway for five days.
# ONE FINDING, NOT ONE PER DAY (2026-08-22). capture-run writes a NEW dated flag every
# run and NOTHING ever deletes one, so this loop emitted a separate finding per unworked
# day - an email that grows by a line a day and, within a fortnight, buries the finding
# that actually matters (ROTATION STALLED, check 7) under a wall of near-identical lines.
# This file's own header warns against exactly that: "flagging it daily would train the
# reader to ignore this email." It became urgent on 2026-08-22, when the browser capture
# routine was retired and the flags stopped being worked by anything at all.
# Report the BACKLOG as one line - how many, and how old the oldest is - and prune the
# ancient ones so out\ does not accumulate without bound. Pruning is capped well beyond
# the point the message is made; it is housekeeping, not the signal.
$flags = @(Get-ChildItem (Join-Path $OutDir 'browser-capture-due-*.flag') -EA SilentlyContinue)
$staleFlags = @($flags | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalDays -gt 1.5 })
if ($staleFlags.Count) {
  $oldest = ($staleFlags | Sort-Object LastWriteTime | Select-Object -First 1)
  $oldestAge = [int]((Get-Date) - $oldest.LastWriteTime).TotalDays
  [void]$findings.Add(("BROWSER WORK STALE: {0} unworked capture flag(s), oldest {1} at {2} day(s). The walled stores are not being captured by anything - open a Chrome tab per store and work out\worklists\." -f $staleFlags.Count, $oldest.Name, $oldestAge))
}
foreach ($f in ($flags | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalDays -gt 45 })) {
  try { Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue } catch { }
}


# ---- 6b. IS ANYTHING STILL HOLDING THE RUN LOG MUTE? (2026-08-25) ------------------------------------
# check-ad-cycles.ps1 already survives a locked ad-cycle-log.txt: it diverts the run's trail to a dated
# LOCKED-<day> sidecar, and the next run that CAN write the primary folds the sidecar back in and deletes
# it. Both halves worked. What nothing checked was the case where the lock never lifts.
#
# On 2026-08-22 at 08:53 an abandoned Claude session left `tail -n 0 -F grocery/ad-cycle-log.txt` running.
# It held the file for 67 HOURS. Every run from 08-22 on diverted to a sidecar, and the recovery fold
# correctly refused to delete anything it could not first append - so the sidecars simply accumulated:
# three of them, 3,560 lines, the entire trail of three days of runs, sitting outside the log that is
# supposed to hold them and outside git. The recovery design was right. It was just waiting for a run
# that could write, and no such run was ever going to come while that process lived.
#
# A PRIOR-DAY SIDECAR IS ITSELF THE ALARM. Its existence means today's fold could not append, which means
# the primary is still held. That is a one-line check and it would have fired on the morning of 08-23.
# Name the holder if we can - "something has it" sends the reader hunting; a PID and a command line ends
# the question. Get-CimInstance is best-effort and must never take the watchdog down with it.
$sidecars = @(Get-ChildItem (Join-Path $PSScriptRoot 'ad-cycle-log.LOCKED-*.txt') -EA SilentlyContinue |
              Where-Object { $_.BaseName -match 'LOCKED-(\d{4}-\d{2}-\d{2})$' -and $Matches[1] -lt $todayS })
if ($sidecars.Count) {
  $scLines = 0
  foreach ($sc in $sidecars) { try { $scLines += @(Get-Content $sc.FullName -EA SilentlyContinue).Count } catch { } }
  $oldestSc = ($sidecars | Sort-Object Name | Select-Object -First 1)
  $holder = ''
  try {
    $primary = Join-Path $PSScriptRoot 'ad-cycle-log.txt'
    try { $fsT = [System.IO.File]::Open($primary, 'Append', 'Write', 'None'); $fsT.Close() }
    catch {
      # NEVER ACCUSE OURSELVES. Command-line matching is a heuristic, and the watchdog's own launch chain
      # mentions this log whenever a human runs it by hand from a shell one-liner - the first draft of
      # this check named the parent PowerShell that started it, which is a false lead wearing a PID.
      # Walk our own ancestry out of the candidate set first, then prefer the documented culprits
      # (tail/bash) over any shell, so the reader gets the process actually sitting on the handle.
      $mine = @{}; $walk = $PID
      for ($h = 0; $h -lt 12 -and $walk; $h++) {
        $mine[[int]$walk] = $true
        $pp = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$walk) -EA SilentlyContinue
        if (-not $pp) { break }
        $walk = $pp.ParentProcessId
      }
      $cands = @(Get-CimInstance Win32_Process -EA SilentlyContinue |
                 Where-Object { -not $mine.ContainsKey([int]$_.ProcessId) -and [string]$_.CommandLine -like '*ad-cycle-log*' })
      $pick = @($cands | Where-Object { $_.Name -in @('tail.exe','bash.exe') } | Select-Object -First 1)
      if (-not $pick.Count) { $pick = @($cands | Select-Object -First 1) }
      if ($pick.Count) { $holder = "  HOLDER: pid $($pick[0].ProcessId) ($($pick[0].Name)) since $($pick[0].CreationDate) :: " + ([string]$pick[0].CommandLine).Trim() }
      else { $holder = '  HOLDER: the primary log is locked but no other process command line names it - check open handles (Sysinternals handle.exe / Resource Monitor).' }
    }
  } catch { }
  # SINGLE-QUOTED, DELIBERATELY. In a double-quoted PowerShell string the backtick before "tail" is an
  # escape and 'tail -F' silently became a TAB character in the alert - the check fired correctly and the
  # sentence telling the reader what to look for had eaten its own subject. Caught by running it.
  $mute = 'RUN LOG HELD MUTE: {0} prior-day LOCKED sidecar(s) survive, oldest {1}, holding {2} line(s) of run history that never reached ad-cycle-log.txt. The recovery fold only deletes a sidecar it could append first, so a surviving one means the primary is STILL locked by another process - kill it and the next run folds them back automatically. An abandoned "tail -F" from a dead session did this for 67 hours from 2026-08-22.{3}'
  [void]$findings.Add(($mute -f $sidecars.Count, $oldestSc.Name, $scLines, $holder))
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

# THE RULER WAS WRONG (Brad, 2026-08-22: "state is not a bad thing"). This check used a flat
# $BROWSER_STALE_DAYS = 7 and called a store STALLED the moment it went a week without a fresh row.
# That contradicts the policy the estate actually runs on, so it cried wolf on stores behaving exactly
# as designed - and a daily false alarm is how a reader learns to skip this email, which then hides
# the real one. The two governing numbers, read from the libraries that own them rather than
# re-typed here (a copied constant is a constant that will disagree - [[two-copies-of-a-rule]]):
#
#   EVERYDAY prices  -> a 90-day quarter. Every store buys ~total_terms/90 terms per day and rows are
#                       carried MaxCarryDays. An everyday price is SUPPOSED to be up to a quarter old;
#                       it only becomes a problem at the carry cliff, when rows actually leave the board.
#   ROLLBACK / INSTANT SAVINGS at Walmart and Sam's -> a 30-day TTL from FIRST detection, because
#                       neither store publishes an end date (rollback-ttl-lib.ps1 owns that rule and
#                       the builders already enforce it). This is the number that is genuinely tight.
#
# So the question is no longer "is this store older than a week" but "is anything about to leave the
# board, or already past its promised window". Warn band before the cliff, not at it: a store that
# only learns it is expiring on the day it expires cannot be rescued in time.
. (Join-Path $root 'capture-policy-lib.ps1')
. (Join-Path $root 'rollback-ttl-lib.ps1')
$CARRY_DAYS = Get-PolicyMaxCarryDays          # 90 - rows older than this expire off the board
$QUARTER_DAYS = Get-PolicyQuarterDays         # 90 - one full rotation of the catalogue
$ROLLBACK_TTL = Get-RollbackTtlDays           # 30 - Walmart/Sam's promo window
$CLIFF_WARN_DAYS = 14                         # notice before the carry cliff, not on it
# A store that has landed nothing for a third of a quarter cannot finish the rotation on time. This
# is DEBT, reported so it is visible, not an emergency - it is the number Brad reads to decide whether
# to spend a browser session, and it must not be dressed up as a failure.
$ROTATION_DEBT_DAYS = [int][math]::Round($QUARTER_DAYS / 3)
$freshByStore = @{}; $newestByStore = @{}
# A PROBE IS NOT A CAPTURE (2026-08-22). This glob used to swallow
# out\regular\hunter-<store>-regular-<date>.json - files the Recipe Hunter's pricing
# lane promotes via promote-ingredient-queue.ps1 so compare-deals can read them. They
# are a handful of adjudicated ingredient prices, not a rotation slice, and on
# 2026-08-22 all seven stores had one dated 2026-08-16. The effect: Walmart's real
# newest capture was 2026-08-11 (11d, over the 7d line) and Sam's Club was 2026-08-01
# (21d), yet BOTH read "ok ... 6d" here and this check stayed silent about two stores
# whose rotation had genuinely stalled. Exactly the [[promoted-file-is-not-a-capture]]
# shape: a thin dated file becomes the "newest capture" and alibis the stale ones.
# That matters more now than when it shipped - as of 2026-08-22 the browser stores have
# no scheduled capture at all, so this finding is the ONLY thing that reports them going
# cold. Judge rotation freshness on rotation output only.
$captureFiles = @(Get-ChildItem (Join-Path $OutDir 'regular\*-regular-*.json') -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -notlike 'hunter-*' })
# SAM'S ROTATION OUTPUT IS NOT IN out\regular, AND THIS CHECK COULD NOT SEE IT (fixed 2026-08-25).
# Every other store's daily rotation lands in out\regular\<store>-regular-<date>.json, but
# build-sams-deals.ps1 writes out\sams\sams-deals-<date>.json - the name compare-deals globs to find
# Sam's captures. It is rotation output either way: the same 7-terms-a-day worklist feeds it. Reading
# only out\regular left this check looking at sams-regular-2026-08-01.json, an abandoned file nothing
# has written since, so it reported Sam's as 24 days cold while the store was in fact being captured
# every morning - 377 cells on the 2026-08-25 board, 17 of them dated that day. A freshness check that
# reads the wrong directory does not report a stale store, it invents one, and it is the third alarm of
# that shape found today. sams-rejects-*.json is deliberately outside this glob, as it is outside
# compare-deals' - rejected rows must never be read back as captures.
$captureFiles += @(Get-ChildItem (Join-Path $OutDir 'sams\sams-deals-*.json') -ErrorAction SilentlyContinue)
foreach ($rf in $captureFiles) {
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
      # BROWSER STORE. Judged against the real cadence (see the constants above), in three bands.
      if ($age -gt $CARRY_DAYS) {
        [void]$findings.Add(("CELLS EXPIRING NOW: {0}'s newest row is {1} day(s) old, past the {2}-day carry limit - its cells are leaving the board. This is the one that costs coverage; work out\rescue-terms-*.txt for this store first." -f $st, $age, $CARRY_DAYS))
      } elseif ($age -gt ($CARRY_DAYS - $CLIFF_WARN_DAYS)) {
        [void]$findings.Add(("APPROACHING CARRY CLIFF: {0}'s newest row is {1} day(s) old and rows expire at {2}. About {3} day(s) of notice before its cells start leaving the board." -f $st, $age, $CARRY_DAYS, ($CARRY_DAYS - $age)))
      } elseif ($age -gt $ROTATION_DEBT_DAYS) {
        # Deliberately NOT worded as a failure. Everyday prices are on a 90-day refresh by design.
        [void]$ok.Add(("{0}: {1} fresh row(s) today, newest {2} ({3}d) - ROTATION DEBT: no capture for over {4}d, so this quarter will not complete on schedule. Not stale yet ({5}d carry); costs coverage only if it keeps slipping." -f $st, $fresh, $newest, $age, $ROTATION_DEBT_DAYS, $CARRY_DAYS))
      } else {
        [void]$ok.Add(("{0}: {1} fresh row(s) today, newest {2} ({3}d of {4}d carry)" -f $st, $fresh, $newest, $age, $CARRY_DAYS))
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
# NOTE: rc=1 here means "the watchdog WORKED and found something", not "the
# watchdog broke". Do not read a red result on this task as a crash - read the log.
$rcFinal = if ($findings.Count) { 1 } else { 0 }
Stop-RunLog -ExitCode $rcFinal -Path $runLog
exit $rcFinal

