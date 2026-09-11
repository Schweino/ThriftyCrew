<#
  triage-due.ps1 - 2-second guard for the grocery-alert-triage scheduled agent.
  Prints IDLE (nothing open) or DUE with a compact list of open queue items. The agent runs hourly while
  the Claude app is open precisely so that a queue written while the app was CLOSED gets drained on the
  first tick after Brad opens it - the guard is what makes that cheap.
  Since 2026-09-10 open items sit in two lanes: an item with lane 'weekly' (send-alert.ps1 -Lane weekly,
  used for triage-created residuals) is always listed but makes the run DUE only when the weekly lane is.
  -SelfTest runs the RE-MEASURE FIRST fixtures against a temp git repo and exits, touching no live file.
#>
# [CmdletBinding()] so -SelfTest cannot fall into $args and run the LIVE report instead ([[arg-silently-ignored]]).
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$qFile = Join-Path $root 'triage-queue.json'
# RETURNS ARE FAILURES (2026-09-10, ruling 5): the one copy of the RETURN rule, shared with validate-triage-plan.ps1.
# A lib that fails to load costs the RETURN lines, never the triage tick; the self-test below fails loudly instead.
try { . (Join-Path $root 'triage-return-lib.ps1') } catch { }

# ---- DID THE EMITTING CODE CHANGE AFTER THE ALERT FIRED? (2026-09-05, queue 2026-09-04-bf1642) ----------
# FOUNDING CASE: alert 2026-09-04-bf1642 fired at 14:57:31 saying the recipe pool's dedup evidence had gone
# stale. Commit bb8de6a0 landed at 15:56:16 - 59 minutes later - and DELETED the arm that emitted that body.
# The alert was stale by construction the moment the fix landed, and nothing said so: a queue item recorded
# what broke and when, never which code said so. Proving it stale cost a git log across three files plus a
# timestamp comparison, and every triage round would pay that again for every same-day fix in this estate.
# So send-alert.ps1 now stamps `emitter` (a repo-relative path) on new items, and this prints one line.
# ADVISORY, NEVER FATAL. Three ways this must stay quiet rather than break:
#   - an item written before 2026-09-05 has no emitter field at all,
#   - an emitter whose path was renamed or deleted has no commits under that name,
#   - git may be missing, or the tree may not be a repo.
# Each of those is "I cannot tell", and the correct output for "I cannot tell" is nothing. A triage guard
# that throws is a triage tick that does not happen.
function Get-EmitterCommitTime {
  <# .SYNOPSIS Committer time of the newest commit touching RelPath, or $null. Pure, never throws. #>
  param([string]$RepoDir, [string]$RelPath)
  if (-not $RelPath -or -not $RepoDir) { return $null }
  # NEVER 2>&1, AND NEVER A REDIRECT UNDER EAP=Stop. In PS 5.1 redirecting a native command's stderr wraps
  # each line in a NativeCommandError, and with $ErrorActionPreference='Stop' the first one is a terminating
  # throw - the exact shape that killed capture-run on 2026-08-22. Dropping to Continue first makes the
  # redirect safe, and the redirect is what keeps git's "fatal: not a git repository" out of a triage report
  # that has to stay readable. Restored in the finally either way.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = @(& git -C $RepoDir log -1 --format=%cI -- $RelPath 2>$null) | Where-Object { $_ } | Select-Object -First 1
    if (-not $out) { return $null }
    return ([datetimeoffset]::Parse(([string]$out).Trim(), [Globalization.CultureInfo]::InvariantCulture)).LocalDateTime
  } catch { return $null }
  finally { $ErrorActionPreference = $prev }
}
function Get-RemeasureLines {
  <# .SYNOPSIS One 'RE-MEASURE FIRST' line per open item whose emitter changed after the item's ts. #>
  param($Items, [string]$RepoDir)
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($i in @($Items)) {
    $em = ''
    if ($i -and $i.PSObject.Properties['emitter']) { $em = ([string]$i.emitter).Trim() }
    if (-not $em) { continue }
    $ct = Get-EmitterCommitTime $RepoDir $em
    if ($null -eq $ct) { continue }
    $its = $null
    try { $its = [datetime]([string]$i.ts) } catch { $its = $null }
    if ($null -eq $its) { continue }
    if ($ct -gt $its) {
      [void]$lines.Add(('  RE-MEASURE FIRST: ' + [string]$i.id + ' - ' + $em + ' changed at ' + $ct.ToString('s') +
                        ', AFTER this alert fired at ' + $its.ToString('s') + '. The behaviour it describes may already be gone.'))
    }
  }
  return $lines
}

# ---- TWO LANES (2026-09-10, Brad, after a 1.35M-token triage day) -----------------------------------------
# FOUNDING CASE: 4 of that day's 11 open items were "Triage residual" items minted by the PREVIOUS day's
# triage, and the run minted 6 more, so every morning paid the reviewer-plus-developer price to re-work the
# last morning's leftovers and the queue fed itself. A leftover a triage run writes down is design work about
# a class, not a live condition: when the condition IS live it re-pages through its own emitter (test-auditors,
# the capture watchdog, guards) and lands in the daily lane anyway. So an item born with lane 'weekly'
# (send-alert.ps1 -Lane weekly) is always LISTED, never hidden, and makes the run DUE only when its lane is:
# the lane stamp is 7 or more days old, missing or unreadable, or any weekly item has waited 21 days.
# The orchestrator writes the stamp only after a weekly-lane run passes its closing gate, so it records a lane
# that was WORKED, never one that was merely tried (the test-guards stamp lesson, queue 2026-09-10-267ba6).
# 7 and 21 are the first plausible numbers, not the survivors of a sweep. Revisit them from
# triage-plans\cost-ledger.jsonl once four weekly runs exist.
$script:WeeklyEveryDays = 7
$script:WeeklyOverdueDays = 21
function Get-LaneSplit {
  <# .SYNOPSIS Split open items into the daily and weekly lanes and decide whether the weekly lane is due. Pure. #>
  param($Items, $StampTime, [datetime]$Now)
  $daily = New-Object System.Collections.Generic.List[object]
  $weekly = New-Object System.Collections.Generic.List[object]
  $overdue = New-Object System.Collections.Generic.List[object]
  foreach ($i in @($Items)) {
    if (-not $i) { continue }
    $lane = ''
    if ($i.PSObject.Properties['lane']) { $lane = ([string]$i.lane).Trim() }
    if ($lane -ne 'weekly') { [void]$daily.Add($i); continue }   # no lane field = every item written before 2026-09-10
    [void]$weekly.Add($i)
    $its = $null
    try { $its = [datetime]([string]$i.ts) } catch { $its = $null }
    if ($null -ne $its -and ($Now - $its).TotalDays -ge $script:WeeklyOverdueDays) { [void]$overdue.Add($i) }
  }
  $stampOld = ($null -eq $StampTime) -or (($Now - [datetime]$StampTime).TotalDays -ge $script:WeeklyEveryDays)
  $nextDue = if ($null -eq $StampTime) { $Now } else { ([datetime]$StampTime).AddDays($script:WeeklyEveryDays) }
  return [pscustomobject]@{
    Daily = $daily.ToArray(); Weekly = $weekly.ToArray(); Overdue = $overdue.ToArray()
    WeeklyDue = ($weekly.Count -gt 0 -and ($stampOld -or $overdue.Count -gt 0))
    NextDue = $nextDue
  }
}
function Read-LaneStamp {
  <# .SYNOPSIS The weekly lane's last WORKED time, or $null when missing or unreadable. Both read as due. #>
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $raw = ([string](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)).Trim()
    if (-not $raw) { return $null }
    return [datetime]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
  } catch { return $null }
}
# ---- PREVENTION IS WEEKLY WHETHER OR NOT ANYTHING IS OPEN (2026-09-10, ruling 6) -----------------------------
# The weekly lane plans prevention for the scoreboard's top recurring class every week, "whether or not that class
# fired that day". The lane used to wake only when a weekly-lane ITEM was open, so a clean week skipped
# prevention entirely, which is the week this plan exists to produce. The fix is NOT to make a clear queue read
# as DUE: test-auditors pins "IDLE only when the queue is really clear", and that meaning is right. So the IDLE
# and DUE lines keep their meaning, and this adds a separate PREVENTION DUE line that the SKILL acts on. It uses
# the lane's own stamp and 7 days, so one worked lane run satisfies both.
function Test-PreventionDue {
  <# .SYNOPSIS Is the weekly prevention step owed? Pure. A missing or unreadable stamp is owed, never recent. #>
  param($StampTime, [datetime]$Now)
  return (($null -eq $StampTime) -or (($Now - [datetime]$StampTime).TotalDays -ge $script:WeeklyEveryDays))
}
function Format-PreventionDueLine {
  <# .SYNOPSIS The one line the SKILL's STEP 0 reads. Pure. #>
  param($StampTime)
  $last = if ($null -eq $StampTime) { 'never' } else { ([datetime]$StampTime).ToString('yyyy-MM-dd HH:mm') }
  return ('PREVENTION DUE  the weekly lane last planned prevention: ' + $last + ' - run the SKILL''s STEP 3.5 prevention step today even if no weekly item is open (ruling 6)')
}

if ($SelfTest) {
  $fail = 0; $cases = 0
  function _T([string]$label, [bool]$cond, [string]$detail) {
    $script:cases++
    if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label  - $detail"; $script:fail++ } }
  $fx = Join-Path $env:TEMP ('triagedue-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  # git writes progress and hints to stderr; under EAP=Stop one of those lines can end this run. The live
  # path above never shells out under Stop for that reason, and the fixture builder below shells out a lot.
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    New-Item -ItemType Directory -Force (Join-Path $fx 'grocery') | Out-Null
    Set-Content (Join-Path $fx 'grocery\emitter.ps1') '# the arm that emitted the alert' -Encoding UTF8
    & git -C $fx init --quiet | Out-Null
    & git -C $fx config user.name t | Out-Null
    & git -C $fx config user.email t@t | Out-Null
    & git -C $fx add -A | Out-Null
    & git -C $fx commit -q -m 'the same-day fix that removed the emitting arm' | Out-Null
    $ct = Get-EmitterCommitTime $fx 'grocery/emitter.ps1'
    _T 'the resolver reads a real committer time out of git for a tracked emitter' ($null -ne $ct) 'got $null'

    if ($null -ne $ct) {
      # MUST FIRE: the founding shape. The alert fired an hour BEFORE the commit that changed its emitter.
      $firedBefore = @([pscustomobject]@{ id = '2026-09-04-bf1642'; ts = $ct.AddHours(-1).ToString('s'); emitter = 'grocery/emitter.ps1' })
      $l = @(Get-RemeasureLines $firedBefore $fx)
      _T 'MUST-FIRE an emitter committed AFTER the alert fired prints RE-MEASURE FIRST, naming the item' `
        ($l.Count -eq 1 -and ($l -join ' ') -match 'RE-MEASURE FIRST' -and ($l -join ' ') -match '2026-09-04-bf1642' -and ($l -join ' ') -match 'grocery/emitter\.ps1') `
        (($l -join ' | '))
      # CLEAN TWIN: the alert fired an hour AFTER the last commit, so it describes live behaviour.
      $firedAfter = @([pscustomobject]@{ id = '2026-09-04-bf1642'; ts = $ct.AddHours(1).ToString('s'); emitter = 'grocery/emitter.ps1' })
      _T 'CLEAN TWIN an emitter last committed BEFORE the alert fired prints nothing' `
        ((@(Get-RemeasureLines $firedAfter $fx)).Count -eq 0) 'a line was printed'
    }
    # CLEAN TWIN: every item written before 2026-09-05 has no emitter field. Silence, never a failure.
    $noEmitter = @([pscustomobject]@{ id = '2026-08-01-aaaaaa'; ts = '2026-08-01T09:00:00' })
    _T 'CLEAN TWIN an item with no emitter field at all prints nothing and does not throw' `
      ((@(Get-RemeasureLines $noEmitter $fx)).Count -eq 0) 'a line was printed'
    # CLEAN TWIN: a renamed or deleted emitter has no commits under that name. Nothing to say, NOT an error.
    $renamed = @([pscustomobject]@{ id = '2026-09-01-bbbbbb'; ts = '2026-09-01T09:00:00'; emitter = 'grocery/this-file-was-renamed.ps1' })
    _T 'CLEAN TWIN a renamed or missing emitter path prints nothing and does not error' `
      ((@(Get-RemeasureLines $renamed $fx)).Count -eq 0) 'a line was printed'
    # CLEAN TWIN: not a git repository at all. "I cannot tell" is not "nothing changed", and neither is a crash.
    $noRepo = Join-Path $env:TEMP ('triagedue-norepo-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $noRepo | Out-Null
    try {
      _T 'CLEAN TWIN a directory that is not a git repo prints nothing and does not throw' `
        ((@(Get-RemeasureLines $renamed $noRepo)).Count -eq 0) 'a line was printed'
    } finally { Remove-Item $noRepo -Recurse -Force -ErrorAction SilentlyContinue }
    # An unparseable ts must not throw either - a queue item is data, and data can be wrong.
    $badTs = @([pscustomobject]@{ id = '2026-09-01-cccccc'; ts = 'not a date'; emitter = 'grocery/emitter.ps1' })
    _T 'CLEAN TWIN an unparseable item ts prints nothing rather than throwing' `
      ((@(Get-RemeasureLines $badTs $fx)).Count -eq 0) 'a line was printed'
  } finally {
    $ErrorActionPreference = $prevEap
    Remove-Item $fx -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ---- TWO LANES (2026-09-10) -----------------------------------------------------------------------------
  $now = [datetime]'2026-09-17T09:45:00'
  $wk = [pscustomobject]@{ id = '2026-09-10-272117'; ts = '2026-09-10T12:56:56'; lane = 'weekly'; count = 1; subject = 'Triage residual: a day with no sign-in' }
  $aged = [pscustomobject]@{ id = '2026-08-20-dddddd'; ts = '2026-08-20T09:00:00'; lane = 'weekly'; count = 1; subject = 'Triage residual: aged' }
  $plain = [pscustomobject]@{ id = '2026-09-17-eeeeee'; ts = '2026-09-17T08:11:12'; count = 1; subject = 'Grocery: GUARDS FAILED' }
  # MUST FIRE: the lane was last worked 7 days ago, so its items are today's work.
  $s1 = Get-LaneSplit @($wk) ([datetime]'2026-09-10T09:00:00') $now   # 7 days 45 min before $now
  _T 'MUST-FIRE a weekly item whose lane was last worked 7 days ago makes the weekly lane DUE' ($s1.WeeklyDue -eq $true) "WeeklyDue=$($s1.WeeklyDue)"
  # MUST FIRE: a lane that has never been worked is due. A missing stamp is not a recent one.
  $s2 = Get-LaneSplit @($wk) $null $now
  _T 'MUST-FIRE a weekly item with NO lane stamp is DUE' ($s2.WeeklyDue -eq $true) "WeeklyDue=$($s2.WeeklyDue)"
  # MUST FIRE: the floor. An item that has waited 21 days is due even the day after a lane run.
  $s3 = Get-LaneSplit @($aged) ([datetime]'2026-09-16T10:00:00') $now
  _T 'MUST-FIRE a weekly item open 21+ days is DUE even when the lane ran yesterday' ($s3.WeeklyDue -eq $true -and @($s3.Overdue).Count -eq 1) "WeeklyDue=$($s3.WeeklyDue) overdue=$(@($s3.Overdue).Count)"
  # MUST NOT FIRE: lane worked 2 days ago, item fresh. Listed as weekly, not due, and NOT counted as daily work.
  $s4 = Get-LaneSplit @($wk) ([datetime]'2026-09-15T10:00:00') $now
  _T 'MUST-NOT-FIRE a fresh weekly item two days after a lane run is not due and not daily work' ($s4.WeeklyDue -eq $false -and @($s4.Daily).Count -eq 0 -and @($s4.Weekly).Count -eq 1) "due=$($s4.WeeklyDue) daily=$(@($s4.Daily).Count) weekly=$(@($s4.Weekly).Count)"
  # CLEAN TWIN: every item written before this change has no lane field and is still daily work.
  $s5 = Get-LaneSplit @($plain, $wk) ([datetime]'2026-09-15T10:00:00') $now
  _T 'CLEAN TWIN an item with no lane field is still daily work beside a weekly one' (@($s5.Daily).Count -eq 1 -and [string]@($s5.Daily)[0].id -eq '2026-09-17-eeeeee') "daily=$(@($s5.Daily).Count)"
  $stF = Join-Path $env:TEMP ('triagedue-stamp-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
  try {
    # MUST FIRE: an unreadable stamp reads as never worked, never as "just ran".
    Set-Content -LiteralPath $stF -Value 'not a date' -Encoding ascii
    _T 'MUST-FIRE an unreadable lane stamp reads as never worked' ($null -eq (Read-LaneStamp $stF)) 'a time was parsed'
    # CLEAN TWIN: a real stamp round-trips to the time that was written.
    Set-Content -LiteralPath $stF -Value '2026-09-15T10:00:00.0000000' -Encoding ascii
    _T 'CLEAN TWIN a real lane stamp round-trips' ((Read-LaneStamp $stF) -eq [datetime]'2026-09-15T10:00:00') 'did not round-trip'
  } finally { Remove-Item -LiteralPath $stF -Force -ErrorAction SilentlyContinue }

  # ---- PREVENTION IS WEEKLY WHETHER OR NOT ANYTHING IS OPEN (2026-09-10, ruling 6) ----
  $pNow = [datetime]'2026-09-17T09:45:00'
  # MUST FIRE: the founding gap. A clear queue and a lane never worked still owes this week's prevention.
  _T 'MUST-FIRE a lane that has never run owes prevention even with nothing open' (Test-PreventionDue $null $pNow) 'not owed'
  # MUST FIRE: a lane last worked 8 days ago owes it.
  _T 'MUST-FIRE a lane last worked 8 days ago owes prevention' (Test-PreventionDue ([datetime]'2026-09-09T09:00:00') $pNow) 'not owed'
  # MUST NOT FIRE: a lane worked 2 days ago does not.
  _T 'MUST-NOT-FIRE a lane worked 2 days ago owes no prevention' (-not (Test-PreventionDue ([datetime]'2026-09-15T10:00:00') $pNow)) 'owed'
  # CLEAN TWIN: the line names the last lane run, so the SKILL and a reader see how overdue it is.
  _T 'CLEAN TWIN the PREVENTION DUE line names the last lane run date' ((Format-PreventionDueLine ([datetime]'2026-09-09T09:00:00')) -match '^PREVENTION DUE .*2026-09-09') (Format-PreventionDueLine ([datetime]'2026-09-09T09:00:00'))

  # ---- RETURNS ARE FAILURES (2026-09-10, Brad's ruling 5) ------------------------------------------------
  # The founding measurement: 25 types fired on 3+ days over 2026-08-22..09-10 and all 25 came back after a
  # close. These pin the pure rule in triage-return-lib.ps1, which validate-triage-plan.ps1 enforces too.
  $rNow = [datetime]'2026-09-10T09:00:00'
  $rType = 'grocery guards failed board not published'
  $rP1 = [pscustomobject]@{ id = '2026-08-22-aaaaa1'; ts = '2026-08-22T08:15:00'; type = $rType; status = 'resolved' }
  $rP2 = [pscustomobject]@{ id = '2026-09-05-aaaaa2'; ts = '2026-09-05T08:15:00'; type = $rType; status = 'resolved' }
  $rOld = [pscustomobject]@{ id = '2026-08-01-aaaaa0'; ts = '2026-08-01T08:15:00'; type = $rType; status = 'resolved' }
  $rParked = [pscustomobject]@{ id = '2026-09-06-aaaaa3'; ts = '2026-09-06T08:15:00'; type = $rType; status = 'needs-brad' }
  $rOther = [pscustomobject]@{ id = '2026-09-06-bbbbb1'; ts = '2026-09-06T08:15:00'; type = 'grocery semantic sweep found product s no rule can see'; status = 'resolved' }
  $rCur = [pscustomobject]@{ id = '2026-09-10-ccccc1'; ts = '2026-09-10T08:15:00'; type = $rType; status = 'open' }
  try {
    # MUST FIRE: a type triage closed twice inside the window, raised again, prints one RETURN line naming both closes.
    $rl = Get-TriageReturnLines @($rCur) @($rP1, $rP2, $rCur, $rOther) $rNow
    $rl = @($rl)
    $want = '  RETURN: 2026-09-10-ccccc1 - grocery guards failed board not published was closed 2 time(s) in 30 days (2026-08-22-aaaaa1, 2026-09-05-aaaaa2)'
    _T 'MUST-FIRE an open item whose type was closed twice in 30 days prints RETURN naming both prior ids' ($rl.Count -eq 1 -and $rl[0] -eq $want) (($rl -join ' | '))
    # MUST NOT FIRE: a first-time type beside closes of other types is not a return.
    $rFirst = [pscustomobject]@{ id = '2026-09-10-ccccc2'; ts = '2026-09-10T08:15:00'; type = 'grocery a type never closed before'; status = 'open' }
    $rl2 = Get-TriageReturnLines @($rFirst) @($rP1, $rP2, $rOther, $rFirst) $rNow
    _T 'MUST-NOT-FIRE a first-time type prints no RETURN line' ((@($rl2)).Count -eq 0) (($rl2 -join ' | '))
    # MUST NOT FIRE: a close older than the queue's 30-day window is outside what the queue can show.
    $rl3 = Get-TriageReturnLines @($rCur) @($rOld, $rCur) $rNow
    _T 'MUST-NOT-FIRE a close older than 30 days is not a return' ((@($rl3)).Count -eq 0) (($rl3 -join ' | '))
    # MUST NOT FIRE: an earlier item parked needs-brad was never closed, so nothing failed to hold.
    $rl4 = Get-TriageReturnLines @($rCur) @($rParked, $rCur) $rNow
    _T 'MUST-NOT-FIRE an earlier needs-brad item of the same type is not a close' ((@($rl4)).Count -eq 0) (($rl4 -join ' | '))
    # CLEAN TWIN: beside another type's close and an aged-out one, the count is exactly the one real prior close.
    $rl5 = Get-TriageReturnLines @($rCur) @($rOld, $rP2, $rOther, $rCur) $rNow
    $rl5 = @($rl5)
    $want5 = '  RETURN: 2026-09-10-ccccc1 - grocery guards failed board not published was closed 1 time(s) in 30 days (2026-09-05-aaaaa2)'
    _T 'CLEAN TWIN a returned type counts exactly its own in-window closes' ($rl5.Count -eq 1 -and $rl5[0] -eq $want5) (($rl5 -join ' | '))
  } catch {
    _T 'the RETURN rule loads and runs (triage-return-lib.ps1)' $false $_.Exception.Message
  }
  Write-Output ''
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output "SELF-TEST PASS ($cases triage-due cases)"
  exit 0
}
# EMAIL MUTED? (2026-08-14) Say so up front. With the inbox silenced, this guard and the agent behind it are
# the ONLY thing that notices an alert, so the mute has to be visible exactly where the response happens -
# an indefinite mute nobody is reminded of is how a rule silently outlives its reason.
#
# ASK THE MAILER'S OWN RULE, do not re-decide it here (2026-08-31). This used to be a bare
# `if (Test-Path $muteFile)`, which is not the same question send-alert.ps1 answers: the documented
# in-place off switch is `muted:false`, which KEEPS the file so the mute period stays on the record.
# So the day the mail came back this banner went on announcing "email alerts are OFF" above a queue
# that was being emailed normally. One copy now, in mute-lib.ps1.
$muteFile = Join-Path $root 'alerts-muted.json'
. (Join-Path $root 'mute-lib.ps1')
$mute = Get-MuteState -Path $muteFile -Today (Get-Date -Format 'yyyy-MM-dd')
if ($mute.muted) {
  Write-Output ('MUTED  email alerts are OFF (' + $mute.why + ', grocery\alerts-muted.json) - alerts still queue here and still get worked; only the mail stopped.')
}
if (-not (Test-Path $qFile)) { Write-Output 'IDLE  no triage queue file - no alert has ever fired'; exit 0 }
# FAIL CLOSED. 2026-07-28: send-alert.ps1 rewrote this file in place, and a read landing inside that window
# returned an empty string. '' | ConvertFrom-Json yields $null in PS 5.1 WITHOUT throwing, so the catch below
# never fired, $q.items was $null, and the guard printed IDLE while 5 real alerts sat open - the tick was
# skipped and Brad had to notice the emails himself. Writes are atomic now; this retries anyway (a swap is
# still a moment where the handle can miss) and treats "cannot read a queue that exists" as DUE, never IDLE.
$q = $null
for ($try = 1; $try -le 4; $try++) {
  try {
    # -Encoding utf8 (worklist C5): PS 5.1 decodes a BOM-less file as ANSI, so the triage agent
    # was shown mangled product names even though this reader never writes the file back.
    $raw = Get-Content $qFile -Raw -Encoding UTF8 -ErrorAction Stop
    if ($raw -and $raw.Trim()) { $q = $raw | ConvertFrom-Json }
  } catch { $q = $null }
  if ($q -and $q.PSObject.Properties['items']) { break }
  $q = $null
  Start-Sleep -Milliseconds 250
}
if (-not $q) { Write-Output 'DUE  triage-queue.json exists but read back empty/unparseable after 4 tries - that itself is the first item to fix'; exit 0 }
$open = @($q.items | Where-Object { $_.status -eq 'open' })
# a spool file means send-alert could not reach the queue at all - those alerts are unworked by definition
$spools = @(Get-ChildItem (Join-Path $root 'triage-spool-*.jsonl') -ErrorAction SilentlyContinue)
if ($spools.Count -gt 0) {
  Write-Output ('DUE  ' + $spools.Count + ' triage SPOOL file(s) - send-alert could not write the queue; drain and delete them:')
  foreach ($s in $spools) { Write-Output ('  ' + $s.Name) }
}
$needsBrad = @($q.items | Where-Object { $_.status -eq 'needs-brad' })
$laneStampFile = Join-Path $root 'triage-weekly-lane-stamp.txt'
$laneStamp = Read-LaneStamp $laneStampFile
$split = Get-LaneSplit $open $laneStamp (Get-Date)
$daily = @($split.Daily)
$weekly = @($split.Weekly)
$overdueIds = @($split.Overdue | ForEach-Object { [string]$_.id })
if ($daily.Count -eq 0 -and -not $split.WeeklyDue) {
  if ($spools.Count -gt 0) { exit 0 }   # spool lines above already said DUE
  $nb = ''; if ($needsBrad.Count) { $nb = ' (' + $needsBrad.Count + ' item(s) parked needs-brad - do not re-triage, they are his)' }
  $wl = ''; if ($weekly.Count) { $wl = ' (' + $weekly.Count + ' weekly-lane item(s) wait for ' + $split.NextDue.ToString('yyyy-MM-dd') + ')' }
  Write-Output ('IDLE  triage queue clear' + $wl + $nb)
  if (Test-PreventionDue $laneStamp (Get-Date)) { Write-Output (Format-PreventionDueLine $laneStamp) }
  exit 0
}
if ($daily.Count) {
  Write-Output ("DUE  " + $daily.Count + " open alert(s) to triage:")
  foreach ($i in $daily) { Write-Output ('  [' + $i.id + '] x' + $i.count + '  ' + $i.subject) }
}
if ($weekly.Count) {
  $lastTxt = if ($null -eq $laneStamp) { 'never' } else { $laneStamp.ToString('yyyy-MM-dd HH:mm') }
  if ($split.WeeklyDue) {
    $lead = if ($daily.Count) { 'WEEKLY LANE DUE' } else { 'DUE  WEEKLY LANE' }
    Write-Output ($lead + '  ' + $weekly.Count + ' triage-created item(s), last lane run ' + $lastTxt + ' - worked after the daily lane, by the SKILL''s WEEKLY LANE step:')
  } else {
    Write-Output ('WEEKLY LANE  ' + $weekly.Count + ' item(s) wait for ' + $split.NextDue.ToString('yyyy-MM-dd') + ' (last lane run ' + $lastTxt + '). Listed for PULL-FORWARD only: work one today only when a daily alert above is its live symptom:')
  }
  foreach ($i in $weekly) {
    $ov = if ($overdueIds -contains [string]$i.id) { '  OVERDUE (open 21+ days)' } else { '' }
    Write-Output ('  [' + $i.id + '] x' + $i.count + '  ' + $i.subject + $ov)
  }
}
# a due weekly lane already runs prevention first; otherwise say when prevention alone is owed (ruling 6)
if (-not $split.WeeklyDue -and (Test-PreventionDue $laneStamp (Get-Date))) { Write-Output (Format-PreventionDueLine $laneStamp) }
# An item whose emitter was committed after the alert fired may be describing code that no longer exists.
# Wrapped: this is provenance, and provenance must never cost a triage tick.
try { foreach ($l in (Get-RemeasureLines $open (Split-Path -Parent $root))) { Write-Output $l } } catch { }
# RETURNS ARE FAILURES (2026-09-10, Brad's ruling 5). An open item whose type triage already closed inside the
# queue's 30-day window is a fix that did not hold. The orchestrator pastes these lines into the reviewer's
# dispatch, and validate-triage-plan.ps1 derives the same status from the queue and demands prior_closes,
# prevention at the source and a fixture from every occurrence. Advisory here, and never fatal, like RE-MEASURE.
try {
  $retLines = Get-TriageReturnLines $open $q.items (Get-Date)
  foreach ($l in @($retLines)) { if ($l) { Write-Output $l } }
} catch { }

# ---------------------------------------------------------------- BOARD GENERATION, pinned for both stages
# WHY (2026-08-06): the reviewer froze a 26,013-name routing corpus at 06:44 against comparison-2026-08-05, a
# board build landed at ~06:50, and the developer then implemented against 08-06 data. Three of six items came
# back "deviated" and EVERY deviation traced to the board moving underneath the plan, not to a bad diagnosis:
# coverage gaps re-derived 43/8 against the plan's 51/7, a 21st aisle BLOCK appeared, and a cell the plan
# called an empty gap had been filled by a wrong product. The developer paid a second time for a measurement
# the reviewer had already bought. Nothing here blocks a run - the whole point of this system is that an
# alert never waits - but both stages must be able to name the generation they measured, and starting inside
# a build is worth one line of warning.
$outDir = Join-Path $root 'out'
$cmp = @(Get-ChildItem (Join-Path $outDir 'comparison-*.json') -ErrorAction SilentlyContinue |
         Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object LastWriteTime -Descending)
if (-not $cmp.Count) {
  Write-Output 'BOARD UNKNOWN  no comparison-*.json on disk - measure nothing against "the board" until one exists'
} else {
  $newest = $cmp[0]
  $ageMin = [int]((Get-Date) - $newest.LastWriteTime).TotalMinutes
  Write-Output ("BOARD " + $newest.BaseName + "  built " + $newest.LastWriteTime.ToString('HH:mm:ss') + " (" + $ageMin + " min ago)")
  # MID-BUILD: compare-deals writes candidates-*.json a beat BEFORE comparison-*.json, so candidates being the
  # newer of the two means a build is in flight right now and neither file is a stable thing to measure.
  $cand = @(Get-ChildItem (Join-Path $outDir 'candidates-*.json') -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -match '^candidates-\d{4}-\d{2}-\d{2}$' } | Sort-Object LastWriteTime -Descending)
  if ($cand.Count -and $cand[0].LastWriteTime -gt $newest.LastWriteTime) {
    Write-Output '  MID-BUILD: candidates is newer than comparison, so a board build is writing RIGHT NOW.'
    Write-Output '             Wait for it to finish before measuring, or the plan will be stale on arrival.'
  } elseif ($ageMin -le 10) {
    Write-Output '  JUST LANDED: this board is minutes old, which usually means a build just finished or another'
    Write-Output '               is close behind. Pin this generation in the plan and re-check it before shipping.'
  }
  Write-Output ('  Pin it: the reviewer records this name in board_week, the developer re-checks it before acting,')
  Write-Output ('  and any item whose freshness line names a different generation gets re-measured, not assumed.')
}
exit 0
