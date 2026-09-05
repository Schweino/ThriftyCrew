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
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
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

# How stale the NEWEST board may be before this is a finding (2026-08-30, queue 2026-08-22-fe7b43).
# Section 3 used to ask Test-Path comparison-<today>.json, which is structurally wrong on this estate:
# the board is NAMED after the newest ads file, never after today - guards.ps1 says so in its own line,
# "the board is built from the newest ads file (ads-2026-08-26 -> comparison-2026-08-26)". So on every
# day the ad window had not rolled over, NO BOARD FOR TODAY fired while the heartbeat two sections up
# reported that same board 1.3 h fresh, and the watchdog task sat at LastResult=1 for over a week. A
# watchdog that is red on quiet days teaches its reader to ignore it, which is worse than not running.
# FRESHNESS was always the question; the filename never was.
# 26h = one 24h cadence plus 2h slack. Deliberately NARROWER than two cadences, so a genuinely dead day
# cannot be alibied by yesterday's output (the tolerance-wider-than-period trap).
$script:BoardStaleHours = 26

function Test-BoardStale {
  <#
    .SYNOPSIS Is the newest board older than one capture cadence?
    .DESCRIPTION Pure, so the -SelfTest fixtures below can drive it with frozen timestamps
                 instead of whatever out\ happens to hold on the day the test runs.
  #>
  param([datetime]$BoardWritten, [datetime]$Now, [int]$MaxHours = 0)
  if ($MaxHours -le 0) { $MaxHours = $script:BoardStaleHours }
  if (-not $BoardWritten -or $BoardWritten.Year -lt 2000) { return $false }
  return ((($Now - $BoardWritten).TotalHours) -gt $MaxHours)
}

function Test-RunSuperseded {
  <#
    .SYNOPSIS Did the board get rebuilt AND shipped after a task exited non-zero?
    .DESCRIPTION
      Pure, so the -SelfTest fixtures can drive it with frozen timestamps.

      WHY (2026-08-31). The 08:00 task exits 1 whenever guards refuse to publish - which is the guard
      doing its job, not the capture failing. This watchdog ran at 09:30 back then and reported that exit code
      as "FAILED", so on a day the blocker was found and cleared in between, the email announced a
      failure about a board that was live, current and correct. Measured that morning: the run exited 1
      at 08:00, the board was rebuilt at 09:26 and published, and this watchdog's OWN healthy lines
      said so three rows below the FAILED it had just written. An alert that contradicts itself in the
      same message is how a real signal gets trained into noise.

      SUPERSEDED IS NOT THE SAME AS FINE, and this deliberately does not suppress. The caller reports
      it as a resolved run with both facts on the record - what exited, and what fixed it - so a day
      that needed a human still reads differently from a day that just worked.

      BOTH halves are required. A board rebuilt but NOT shipped is the "rebuilt but never published"
      defect section 4 exists to catch, so it must not count as superseding anything; that is why the
      publish time is checked against the board rather than against the run.
  #>
  param($RunAt, $BoardWritten, $PublishedWritten, [int]$PublishSlackMinutes = 30)
  if ($null -eq $RunAt -or $null -eq $BoardWritten -or $null -eq $PublishedWritten) { return $false }
  $r = [datetime]$RunAt; $b = [datetime]$BoardWritten; $p = [datetime]$PublishedWritten
  if ($r.Year -lt 2000 -or $b.Year -lt 2000 -or $p.Year -lt 2000) { return $false }
  if ($b -le $r) { return $false }                                  # board is no newer than the failed run
  if ($p -lt $b.AddMinutes(-$PublishSlackMinutes)) { return $false } # rebuilt but never shipped
  return $true
}

function Test-FlagStoreCold {
  <#
    .SYNOPSIS Is a store named on a capture flag actually still uncaptured?
    .DESCRIPTION
      Pure, so the -SelfTest fixtures below can drive it with frozen dates.

      TWO STANDARDS WERE FIGHTING (2026-08-30, queue 2026-08-30-40c75d). Check 6b called a store COLD when
      it had no rows dated TODAY, while the per-store scan twenty lines up grades the SAME store against
      the 90-day rotation - and prints lines like "Aldi: 0 fresh rows today, newest 2026-08-29 (1d of 90d
      carry)" as OK on the same run. A flag is a TODO, capture-run writes a new one every day, nothing
      deletes one before the 45-day prune, so ONE store not yet reached by 09:32 relit all ten flags on
      disk: 8 unworked, oldest 9 days, "still cold: Aldi" - on a day Aldi was one day old and inside every
      band. That is the alarm-that-accuses-healthy-things class this very check was rewritten for on
      2026-08-25, one standard short.

      A store is COLD only when BOTH are true: nothing has been captured since the flag was written (so
      the todo really is outstanding), AND its newest capture is past the same ROTATION_DEBT band the
      per-store scan uses. A store with no readable capture date at all is COLD - unprovable is not done,
      and this check must never excuse itself on data it failed to read.
  #>
  param([string]$NewestCapture, [datetime]$FlagWritten, [datetime]$Now, [int]$RotationDebtDays)
  if (-not $NewestCapture) { return $true }
  $n = [datetime]'1900-01-01'
  if (-not [datetime]::TryParse($NewestCapture, [ref]$n)) { return $true }
  if ($n.Date -ge $FlagWritten.Date) { return $false }
  return ((($Now.Date - $n.Date).TotalDays) -gt $RotationDebtDays)
}

function Test-FlagWorked {
  <#
    .SYNOPSIS Has every store this flag names been captured since the flag was written?
    .DESCRIPTION
      Pure. A flag is a todo with no completion mechanism - that is the whole defect. This is the
      completion test, and it is STRICTER than the cold test on purpose: a store merely inside its
      rotation band has not had this todo worked, it is just not late yet, so the flag stays on disk.
      Only a flag whose every store carries a capture at or after the flag date is finished and deleted.
  #>
  param([string[]]$Stores, $NewestByStore, [datetime]$FlagWritten)
  if (-not @($Stores).Count) { return $false }
  foreach ($s in @($Stores)) {
    $v = [string]$NewestByStore[[string]$s]
    if (-not $v) { return $false }
    $n = [datetime]'1900-01-01'
    if (-not [datetime]::TryParse($v, [ref]$n)) { return $false }
    if ($n.Date -lt $FlagWritten.Date) { return $false }
  }
  return $true
}

function Measure-CursorAdvances {
  <#
    How many times a store advanced its term cursor since $Since, read off capture-cursor-log.jsonl.
    PURE, and lifted out of the watcher below so -SelfTest can drive it with frozen lines instead of a
    live log - the same reason compute-v2's package decision is a function. A cadence check whose only
    test is "run it and see" is a check nobody can prove fires.
    A line that does not parse, or carries no readable timestamp, is SKIPPED rather than counted: this
    number is used to decide that a window is MISSING, so an unreadable line must not manufacture one.
  #>
  param([string[]]$Lines, [Parameter(Mandatory)][string]$Store, [Parameter(Mandatory)][datetime]$Since)
  $n = 0
  foreach ($ln in @($Lines)) {
    if (-not ("$ln").Trim()) { continue }
    $rec = $null; try { $rec = "$ln" | ConvertFrom-Json } catch { continue }
    if ([string]$rec.store -ne $Store) { continue }
    $at = [datetime]'1900-01-01'
    if (-not [datetime]::TryParse([string]$rec.at, [ref]$at)) { continue }
    if ($at -ge $Since) { $n++ }
  }
  return $n
}

if ($SelfTest) {
  # Frozen fixtures: the founding bug (a task that never runs, reported green forever) and
  # its clean twin (a task legitimately still waiting for its first slot).
  $fail = 0
  $now = [datetime]'2026-08-21 06:47'

  # ---- FF SHARD CADENCE (2026-09-01, queue 2026-09-01-056e6b) ---------------------------------
  # Frozen from the real log shape. The MUST-FIRE case is the condition that actually existed on
  # 2026-09-01: one window a day where three are configured. The clean twin is the fixed state.
  # A third case pins the reason the check was unbuildable before: a log carrying every OTHER
  # store and no Family Fare line must read as ZERO windows, not as "nothing to see".
  $cadSince = [datetime]'2026-09-01 06:00'
  $ffOneWindow = @(
    '{"at":"2026-09-01T08:01:55","store":"Family Fare","from":593,"to":600,"day":"2026-09-01","caller":"capture-run.ps1","pid":1}'
  )
  $ffThreeWindows = @(
    '{"at":"2026-09-01T07:00:41","store":"Family Fare","from":579,"to":586,"day":"2026-09-01","caller":"capture-run.ps1","pid":1}',
    '{"at":"2026-09-01T08:01:55","store":"Family Fare","from":586,"to":593,"day":"2026-09-01","caller":"capture-run.ps1","pid":2}',
    '{"at":"2026-09-01T09:31:02","store":"Family Fare","from":593,"to":600,"day":"2026-09-01","caller":"capture-watchdog.ps1","pid":3}'
  )
  # the real 2026-09-01 log: six stores advancing, Family Fare absent entirely
  $ffNoneAtAll = @(
    '{"at":"2026-09-01T08:03:05","store":"Sam''s Club","from":70,"to":77,"day":"2026-09-01","caller":"build-sams-deals.ps1","pid":48676}',
    '{"at":"2026-09-01T08:03:10","store":"Fareway","from":84,"to":91,"day":"2026-09-01","caller":"build-fareway-regular.ps1","pid":44468}',
    '{"at":"2026-09-01T09:08:23","store":"Walmart","from":35,"to":42,"day":"2026-09-01","caller":"build-walmart-deals.ps1","pid":14848}'
  )
  $cadA = Measure-CursorAdvances -Lines $ffOneWindow -Store 'Family Fare' -Since $cadSince
  if ($cadA -lt 3) { Write-Output "ok    FF cadence MUST-FIRE: one window a day against three configured reads as $cadA and pages MISSING-WINDOW" }
  else { Write-Output "FAIL  FF cadence counted $cadA windows from a single advance - the 2026-09-01 condition would not page"; $fail++ }
  $cadB = Measure-CursorAdvances -Lines $ffThreeWindows -Store 'Family Fare' -Since $cadSince
  if ($cadB -eq 3) { Write-Output 'ok    FF cadence CLEAN TWIN: all three shard windows advancing reads as 3 and stays silent' }
  else { Write-Output "FAIL  FF cadence counted $cadB of 3 healthy windows - a working cadence would page every day and be muted"; $fail++ }
  $cadC = Measure-CursorAdvances -Lines $ffNoneAtAll -Store 'Family Fare' -Since $cadSince
  if ($cadC -eq 0) { Write-Output 'ok    FF cadence reads a log full of OTHER stores as zero Family Fare windows (the state that made this check unbuildable until pull-regular-familyfare started logging)' }
  else { Write-Output "FAIL  FF cadence counted $cadC Family Fare windows in a log with none - it is matching the wrong store"; $fail++ }
  $cadD = Measure-CursorAdvances -Lines @('not json at all', '{"at":"","store":"Family Fare"}') -Store 'Family Fare' -Since $cadSince
  if ($cadD -eq 0) { Write-Output 'ok    FF cadence skips an unparseable line rather than counting it (an unreadable line must not invent a window)' }
  else { Write-Output "FAIL  FF cadence counted $cadD window(s) from unreadable lines"; $fail++ }

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

  # ---- board freshness (2026-08-30, queue 2026-08-22-fe7b43) ----------------------------------------
  # FROZEN, not read from out\. The whole defect was a check that consulted a rotating filename, so a
  # fixture rebuilt from the live board on the day of the run would encode whatever the ad cycle happened
  # to be doing and could pass by finding nothing.
  $bNow = [datetime]'2026-08-30 09:30'

  # MUST FIRE: the real failing shape. A board that has not been rebuilt since the morning before.
  if (-not (Test-BoardStale -BoardWritten ([datetime]'2026-08-29 06:10') -Now $bNow)) {
    Write-Output 'FAIL  a board last written 27.3 h ago read as fresh - the staleness gate cannot arm'; $fail++
  } else { Write-Output 'ok    a board 27.3 h old is a finding' }

  # CLEAN TWIN: the exact 08-27..08-30 shape that made the OLD check fire every day. comparison-2026-08-26
  # is named four days back because the board takes the newest ADS file's name, and it was rebuilt at
  # 14:45 the previous afternoon. Filename old, board fresh, watchdog must stay silent.
  if (Test-BoardStale -BoardWritten ([datetime]'2026-08-29 14:45') -Now $bNow) {
    Write-Output 'FAIL  comparison-2026-08-26 rebuilt 18.8 h ago was called stale - the ad-cycle false positive is back'; $fail++
  } else { Write-Output 'ok    a 4-day-old FILENAME with an 18.8 h-old rebuild stays silent' }

  # The bar sits under two cadences, so a dead day cannot hide behind yesterday's output.
  if ($script:BoardStaleHours -ge 48) {
    Write-Output 'FAIL  the staleness window is at least two capture cadences wide - a skipped day would be alibied by the previous one'; $fail++
  } else { Write-Output 'ok    staleness window is narrower than two cadences' }

  # ---- browser-work flags (2026-08-30, queue 2026-08-30-40c75d) --------------------------------------
  # FROZEN, not read from out\browser-capture-due-*.flag. The flags on disk are rewritten daily and the
  # captures behind them move every few hours, so a fixture built from the live tree would encode whatever
  # the browser agent happened to have finished that morning and could pass by finding nothing.
  $fNow = [datetime]'2026-08-30 09:32'
  $fFlag = [datetime]'2026-08-21 09:00'   # the oldest flag actually on disk that morning
  $rot = 30                               # ROTATION_DEBT_DAYS = QUARTER_DAYS / 3

  # MUST FIRE: the real freeze. 2026-08-22..25, when the browser stores went uncaptured for days and the
  # old routine had been retired - nothing since the flag AND past the rotation band.
  if (-not (Test-FlagStoreCold -NewestCapture '2026-07-14' -FlagWritten $fFlag -Now $fNow -RotationDebtDays $rot)) {
    Write-Output 'FAIL  a store with no capture since the flag and 47 days old read as worked - a real freeze is now invisible'; $fail++
  } else { Write-Output 'ok    a store 47 days stale with nothing since the flag is still COLD' }

  # MUST FIRE: a store the flag names that has no capture date at all. Unprovable is not done.
  if (-not (Test-FlagStoreCold -NewestCapture '' -FlagWritten $fFlag -Now $fNow -RotationDebtDays $rot)) {
    Write-Output 'FAIL  a store with NO readable capture date read as worked - the check excused itself on data it could not read'; $fail++
  } else { Write-Output 'ok    a store with no readable capture date is COLD, not excused' }

  # CLEAN TWIN: today's real shape. Aldi, newest 2026-08-29, one day old, not captured since a 08-21 flag
  # but nowhere near the rotation band. This is the exact row that lit BROWSER WORK STALE on a healthy day.
  if (Test-FlagStoreCold -NewestCapture '2026-08-29' -FlagWritten $fFlag -Now $fNow -RotationDebtDays $rot) {
    Write-Output 'FAIL  Aldi at 1 day old was called cold - the daily-freshness bar is back and it contradicts the rotation bands'; $fail++
  } else { Write-Output 'ok    a store 1 day old is not cold, the same verdict the per-store scan prints' }

  # CLEAN TWIN: captured AFTER the flag - the todo was worked, whatever its age band says.
  if (Test-FlagStoreCold -NewestCapture '2026-08-30' -FlagWritten $fFlag -Now $fNow -RotationDebtDays $rot) {
    Write-Output 'FAIL  a store captured after the flag was still called cold - the watchdog cannot see the work it asked for'; $fail++
  } else { Write-Output 'ok    a store captured after the flag is worked' }

  # COMPLETION: every store newer than the flag = a finished todo, and only then is the flag deleted.
  $nbs = @{ 'Walmart' = '2026-08-30'; 'Aldi' = '2026-08-29'; 'Fareway' = '2026-08-30' }
  if (-not (Test-FlagWorked -Stores @('Walmart', 'Fareway') -NewestByStore $nbs -FlagWritten ([datetime]'2026-08-29 09:00'))) {
    Write-Output 'FAIL  a flag whose every store was captured after it was written did not read as finished - flags never die'; $fail++
  } else { Write-Output 'ok    a flag whose every store has a newer capture is a finished todo' }
  if (Test-FlagWorked -Stores @('Walmart', 'Aldi') -NewestByStore $nbs -FlagWritten ([datetime]'2026-08-30 09:00')) {
    Write-Output 'FAIL  a flag with one store still uncaptured was deleted as finished - the todo would vanish unworked'; $fail++
  } else { Write-Output 'ok    a flag with one store still uncaptured is NOT deleted' }
  if (Test-FlagWorked -Stores @() -NewestByStore $nbs -FlagWritten $fFlag) {
    Write-Output 'FAIL  an unparseable flag naming no store read as finished - a file it could not read would be deleted'; $fail++
  } else { Write-Output 'ok    a flag naming no store is never treated as finished' }

  # ---- Test-RunSuperseded: a non-zero exit judged on OUTCOME, not on the exit code ---------------------
  # THE FOUNDING DAY, to the minute. 2026-08-31: the 08:00 task exited 1 because guards refused to publish
  # (the same log says "lanes run=3 failed=0"), the blocker was cleared, and the board was rebuilt 09:26 and
  # published. At 09:32 this watchdog emailed "FAILED" about a board that was live and correct.
  $r0800 = [datetime]'2026-08-31 08:00'
  if (Test-RunSuperseded -RunAt $r0800 -BoardWritten ([datetime]'2026-08-31 09:26') -PublishedWritten ([datetime]'2026-08-31 09:28')) {
    Write-Output 'ok    a run whose board was rebuilt and shipped after it reads as SUPERSEDED'
  } else { Write-Output 'FAIL  the founding case still reads as a live failure - the 09:30 email contradicts its own healthy lines'; $fail++ }
  # MUST-FIRE TWINS: the states that are genuinely still broken and must keep paging.
  if (Test-RunSuperseded -RunAt $r0800 -BoardWritten ([datetime]'2026-08-31 07:10') -PublishedWritten ([datetime]'2026-08-31 07:12')) {
    Write-Output 'FAIL  a board OLDER than the failed run was accepted as superseding it'; $fail++
  } else { Write-Output 'ok    a board older than the failed run supersedes nothing' }
  if (Test-RunSuperseded -RunAt $r0800 -BoardWritten ([datetime]'2026-08-31 09:26') -PublishedWritten ([datetime]'2026-08-30 09:28')) {
    Write-Output 'FAIL  rebuilt-but-never-published counted as superseded - that is the exact defect section 4 exists for'; $fail++
  } else { Write-Output 'ok    a board rebuilt but NOT shipped does not supersede a failure' }
  if (Test-RunSuperseded -RunAt $r0800 -BoardWritten $null -PublishedWritten ([datetime]'2026-08-31 09:28')) {
    Write-Output 'FAIL  a missing board read as superseding'; $fail++
  } else { Write-Output 'ok    a missing board supersedes nothing (unprovable is not resolved)' }
  # CLEAN TWIN: publish a few minutes BEFORE the board write still counts - the ship path writes
  # public\board.json and the comparison seconds apart and their order is not guaranteed, which is the same
  # 30-minute slack section 4 already allows. Without it every healthy day would read as a live failure.
  if (Test-RunSuperseded -RunAt $r0800 -BoardWritten ([datetime]'2026-08-31 09:26') -PublishedWritten ([datetime]'2026-08-31 09:25')) {
    Write-Output 'ok    a publish minutes either side of the board write still counts as shipped'
  } else { Write-Output 'FAIL  the publish/board write-order slack is gone - healthy days will page'; $fail++ }

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
# Tasks that exited non-zero, held until sections 3 and 4 can say whether the board was rebuilt and
# shipped after them. See the note at the deferral below.
$failedTasks = New-Object System.Collections.Generic.List[object]

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
    # DEFERRED ON PURPOSE (2026-08-31). A non-zero exit here is usually the guards refusing to publish,
    # which is the guard WORKING - and by the time this runs at 10:30 the blocker may already have been
    # cleared and the board shipped. Reporting the stale exit code as FAILED then emails a failure about a
    # board that is live and correct, which is how a real alert gets trained into noise. The facts that
    # settle it (was the board rebuilt after this run, and did it ship) are computed in sections 3 and 4
    # below, so the verdict waits for them rather than looking them up a second time here.
    [void]$failedTasks.Add([pscustomobject]@{ name = $name; last = $last; rc = $rc; at = $last })
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
    $st = Read-JsonFile $statusF
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

# ---- 3. was the board REBUILT recently? -------------------------------------
# Freshness, not a filename. See Test-BoardStale above for why comparison-<today>.json was the wrong
# question: the board is named after the newest ads file, so on every non-rollover day this section
# reported NO BOARD FOR TODAY about a board that had been rebuilt hours earlier.
$cmp = $null
$newest = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') -EA SilentlyContinue |
          Sort-Object Name -Descending | Select-Object -First 1
if (-not $newest) {
  [void]$findings.Add("NO BOARD AT ALL: no comparison-*.json under $OutDir. Nothing has been built here, so there is nothing to publish.")
} else {
  $cmp = $newest.FullName
  $ageH = [math]::Round(((Get-Date) - $newest.LastWriteTime).TotalHours, 1)
  if (Test-BoardStale -BoardWritten $newest.LastWriteTime -Now (Get-Date)) {
    [void]$findings.Add("BOARD IS STALE: the newest board $($newest.Name) was last written $($newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm')), $ageH h ago - past the $($script:BoardStaleHours)h bar. Capture may have run, but the board was not recomputed.")
  } else {
    [void]$ok.Add("newest board $($newest.Name) rebuilt $ageH h ago")
  }
}

# ---- 4. did it reach the live site? -----------------------------------------
# public\board.json is what the Worker serves. If it is OLDER than the comparison,
# the recompute happened but the publish did not, and the site is serving a board
# that no longer matches the data behind it.
$pub = Join-Path (Split-Path $root -Parent) 'public\board.json'
# $cmp is now the NEWEST board rather than comparison-<today>.json. That matters here too, and it is the
# same defect wearing a different hat: while $cmp was a today-named path that mostly did not exist, this
# whole check was skipped on every non-rollover day - a gate that could only arm when the ad window
# happened to roll. It arms daily now.
if ($cmp -and (Test-Path $cmp) -and (Test-Path $pub)) {
  $cT = (Get-Item $cmp).LastWriteTime; $pT = (Get-Item $pub).LastWriteTime
  if ($pT -lt $cT.AddMinutes(-30)) {
    [void]$findings.Add("NOT PUBLISHED: public\board.json is $([int]($cT - $pT).TotalMinutes) min older than today's comparison. The board was rebuilt but never shipped.")
  } else {
    [void]$ok.Add('public\board.json is current with the comparison')
  }
}

# ---- 4b. the deferred verdict on tasks that exited non-zero (2026-08-31) -----
# Sections 3 and 4 have now established when the newest board was written and whether it shipped, so a
# non-zero exit can finally be judged on OUTCOME rather than on its exit code alone - which is what the
# header of this file says it is for ("IT CHECKS OUTCOMES, NOT JUST EXIT CODES"). A run whose board was
# subsequently rebuilt AND published was superseded: still worth saying, because it needed something to
# happen, but it is not a live failure and must not read as one.
$boardW = if ($newest) { $newest.LastWriteTime } else { $null }
$pubW   = if ($pub -and (Test-Path $pub)) { (Get-Item $pub).LastWriteTime } else { $null }
foreach ($ft in $failedTasks) {
  if (Test-RunSuperseded -RunAt $ft.at -BoardWritten $boardW -PublishedWritten $pubW) {
    [void]$ok.Add("$($ft.name) exited $($ft.rc) at $($ft.last) - SUPERSEDED: the board was rebuilt $($boardW.ToString('HH:mm')) and published after it, so the live page is current. Usually the guards refusing to ship, then the blocker cleared.")
  } else {
    [void]$findings.Add("FAILED: '$($ft.name)' last run $($ft.last) exited $($ft.rc), and no board has been rebuilt and published since. The live page is NOT carrying that run's work.")
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
# THE FINDING ITSELF NOW LIVES BELOW CHECK 7 (moved 2026-08-25). A flag is a TODO, and whether the todo
# is DONE can only be answered by the per-store freshness scan, which has not run yet at this point in
# the file. $staleFlags is carried down to it. Only the pruning stays here, because that is housekeeping
# and needs nothing but the file dates.
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

# ---- 6b (deferred from check 6). BROWSER WORK: is the todo actually still outstanding? ---------------
# A flag records what the 08:00 driver could NOT capture, and NOTHING ever deletes one - so the finding
# was purely "a file exists and is older than a day". It stayed lit after the work was done, and on
# 2026-08-25 it was the only finding left standing at the end of a day on which every store it named had
# been captured: Walmart 193 rows and Aldi 264, both dated today, both through Brad's Chrome. A watchdog
# that cannot see the work it asked for being finished is asking for it forever, which is the fourth
# alarm-that-accuses-healthy-things found that day.
#
# So ask the question the flag is really posing: do the stores this flag names have fresh rows TODAY? A
# flag whose stores are all fresh is a completed todo and is reported as ok. One with a store still cold
# is a real finding, and so is one whose store list cannot be read - unprovable is not the same as done,
# and this check must never excuse itself on a file it failed to parse.
if ($staleFlags.Count) {
  # JUDGED BY THE SAME BANDS THE PER-STORE SCAN USES, and a finished todo is deleted rather than kept
  # forever (2026-08-30, queue 2026-08-30-40c75d - see Test-FlagStoreCold for the measurement). The old
  # bar was "no rows dated TODAY", which contradicted the OK line this same run prints for the same store.
  $unworked = @(); $finished = @(); $coldNames = @{}
  $nowFlags = Get-Date
  foreach ($ff in $staleFlags) {
    $fstores = @()
    try { $fstores = @((Get-Content $ff.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).stores) } catch { $fstores = @() }
    if (-not $fstores.Count) { $unworked += $ff; continue }   # unreadable is not done
    $coldOnes = @($fstores | Where-Object {
        Test-FlagStoreCold -NewestCapture ([string]$newestByStore[[string]$_]) -FlagWritten $ff.LastWriteTime -Now $nowFlags -RotationDebtDays $ROTATION_DEBT_DAYS })
    if ($coldOnes.Count) { $unworked += $ff; $coldNames[$ff.Name] = $coldOnes }
    elseif (Test-FlagWorked -Stores @($fstores | ForEach-Object { [string]$_ }) -NewestByStore $newestByStore -FlagWritten $ff.LastWriteTime) { $finished += $ff }
  }
  if ($unworked.Count) {
    $oldest = ($unworked | Sort-Object LastWriteTime | Select-Object -First 1)
    $oldestAge = [int]((Get-Date) - $oldest.LastWriteTime).TotalDays
    $still = @($coldNames[$oldest.Name])
    $who = if ($still.Count) { ' still cold: ' + ($still -join ', ') } else { '' }
    [void]$findings.Add(("BROWSER WORK STALE: {0} unworked capture flag(s), oldest {1} at {2} day(s).{3} The walled stores are not being captured by anything - open a Chrome tab per store and work out\worklists\." -f $unworked.Count, $oldest.Name, $oldestAge, $who))
  } else {
    [void]$ok.Add(("browser work: {0} capture flag(s) on disk and every store each one names is inside its rotation band - nothing behind them is outstanding" -f $staleFlags.Count))
  }
  # A FINISHED TODO IS DELETED. Same housekeeping-not-signal doctrine as the 45-day prune above: a flag
  # that nothing can ever close is what made ONE unreached store relight ten days of them at once.
  if ($finished.Count) {
    [void]$ok.Add(("browser work: pruned {0} completed capture flag(s) - every store each one named has a capture dated at or after the flag" -f $finished.Count))
    foreach ($ff in $finished) { try { Remove-Item $ff.FullName -Force -ErrorAction SilentlyContinue } catch { } }
  }
}
# ---- PAID CONTENT SERVED FREE (2026-08-29) -----------------------------------
# THE DIRECTION NOBODY WATCHED. build-hub-grid already verifies visibility per slug, but only for slugs
# LISTED in free-rotation.json - it warns when a listed-free post is NOT public, which protects the badge.
# Nothing anywhere asked the dangerous question: is any post NOT listed free being served free? On
# 2026-08-29 the answer was 22 - full paid recipes, ingredients, every step, cost and scaler, readable by
# anonymous visitors - and it took an unrelated wave's post-publish review to notice one of them.
# It lives HERE rather than on the ship path because it is a health question, not a publish gate, and the
# watchdog already raises exactly one email a day. It costs one Ghost read per recipe, so it is deliberately
# NOT in the 0800 chain's fan-out where it would sit on the critical path to the board.
# The sweep alerts on its own (-Alert) AND contributes a line here, because the two have different readers:
# the alert names every slug for whoever fixes it, this line tells the daily health reader it happened.
try {
  $visPs1 = Join-Path (Split-Path $PSScriptRoot -Parent) 'meal-prep\set-recipe-visibility.ps1'
  if (-not (Test-Path $visPs1)) {
    # A MISSING CHECKER IS A FINDING, NOT A SKIP. The first version of this block wrapped everything
    # in `if (Test-Path)`, so deleting the sweep would have made the watchdog quietly stop asking the
    # question and report a clean day - the same shape as every other blind guard in this estate.
    [void]$findings.Add('VISIBILITY SWEEP MISSING: meal-prep\set-recipe-visibility.ps1 is gone, so nothing checks whether a paid recipe is being served free. That check found 22 on 2026-08-29.')
  } else {
    $visOut = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $visPs1 -Audit -Alert)
    $visLine = [string](@($visOut) -match '^VISIBILITY-AUDIT-COMPLETE' | Select-Object -First 1)
    if ($visLine -match 'disagreements=(\d+)') {
      $nBad = [int]$Matches[1]
      if ($nBad -gt 0) {
        [void]$findings.Add("PAID CONTENT SERVED FREE: $nBad live recipe(s) disagree with recipes-db about who may read them - see the VISIBILITY alert for the slugs. Nothing self-heals this: the rotation refuses to re-paywall a post it does not own, and publish.ps1 preserves live visibility on update. Fix with meal-prep\set-recipe-visibility.ps1 -Slug <slug> -Apply.")
      } else {
        [void]$ok.Add(("visibility: every live recipe agrees with recipes-db on who may read it ({0})" -f ($visLine -replace '^VISIBILITY-AUDIT-COMPLETE\s*','')))
      }
    } else {
      # A sweep that could not finish must not read as a clean one - that is the whole lesson of the class.
      [void]$findings.Add('VISIBILITY SWEEP DID NOT COMPLETE: set-recipe-visibility -Audit produced no verdict line, so whether a paid recipe is being served free is UNKNOWN this run, not clean.')
    }
  }
} catch { [void]$findings.Add('VISIBILITY SWEEP THREW: ' + $_.Exception.Message + ' - whether a paid recipe is being served free is unknown this run.') }

# ---- FAMILY FARE SHARD WINDOW 3 OF 3, and the cadence check that watches it ---------------------
# (2026-09-01, queue 2026-09-01-056e6b.) Window 1 rides the 07:00 ad task, window 2 is the 08:00 daily
# run's own FF lane, and this is window 3. No new scheduled task: the automation inventory stays at
# three grocery jobs. The cursor design makes a repeated or a missed window safe by construction, so
# running FF here cannot corrupt anything - a window that buys nothing commits no cursor.
$FF_EXPECTED_WINDOWS = 3
if (-not $SelfTest) {
  try {
    Write-Output 'capture-watchdog: Family Fare shard window (3 of 3)'
    # NO 2>&1 - see capture-run.ps1: EAP=Stop plus a native child's redirected stderr is a terminating
    # throw in PS 5.1, and it would kill the watchdog before it reported anything.
    $ffOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'pull-regular-familyfare.ps1') -MaxMinutes 5
    foreach ($l in @($ffOut)) { Write-Output ('  ff> ' + $l) }
  } catch { Write-Output ('  ff> shard window threw (not fatal, the cursor did not commit): ' + $_.Exception.Message) }
}

# THE CADENCE WATCHER. The point of 2026-09-01-056e6b is not that Family Fare was throttled; it is that
# the designed cadence never existed and NOTHING was watching for its absence, so a missing schedule
# paged three weeks later as "catalog is degrading" instead of as itself. This asks the direct question.
#
# It reads capture-cursor-log.jsonl, and that file could not answer it until today: every other rotation
# store writes an advance line there and Family Fare never did (17 Fareway, 11 Sam's Club, 11 Hy-Vee, 10
# Baker's, 8 Walmart, 7 Aldi, 0 Family Fare on 2026-09-01), because pull-regular-familyfare called
# Save-CaptureCursor without the separate Write-CursorLog every other builder calls. That call was added
# in the same commit as this check; without it this watcher would have been a gate that can never arm.
try {
  $curLog = Join-Path $OutDir 'capture-cursor-log.jsonl'
  if (Test-Path $curLog) {
    $since = (Get-Date).AddHours(-24)
    $ffAdv = Measure-CursorAdvances -Lines (Get-Content $curLog -ErrorAction SilentlyContinue) -Store 'Family Fare' -Since $since
    if ($ffAdv -lt $FF_EXPECTED_WINDOWS) {
      [void]$findings.Add(("MISSING-WINDOW: Family Fare advanced its term cursor $ffAdv time(s) in the last 24h, against $FF_EXPECTED_WINDOWS configured shard windows (07:00 ad task, 08:00 daily run, 10:30 watchdog). The sweep is sized for several windows a day - about 7 of 526 terms each - so a lost window is not a slow day, it is coverage the 90-day carry has to cover for. This is the check that makes a dead window page as itself instead of surfacing weeks later as 'the catalog is degrading'."))
    } else {
      [void]$ok.Add("Family Fare shard cadence: $ffAdv cursor advance(s) in the last 24h, at or above the $FF_EXPECTED_WINDOWS configured windows")
    }
  }
} catch { }

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

