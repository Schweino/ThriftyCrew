<#
.SYNOPSIS
  Register (or remove) the one scheduled task allowed to start llama-server.

.DESCRIPTION
  PLAN-local-matching-2026-08-22 section 2, phase 2. Before today the rule was "llama-server is
  ON-DEMAND ONLY, NEVER SCHEDULED", written into tools\local-llm\serve.ps1's header. That rule was
  never about scheduling. It was about the card: the 27B and the semantic sidecar cannot be resident
  at the same time, and with nothing owning the ordering, the only way to be sure was to let a human
  own it. The cost was paid nightly in graph work that simply did not happen.

  nightly.ps1 owns the ordering now, and stops llama-server in a finally block that runs on success,
  failure, timeout and Ctrl-C. So the rule becomes what it always meant:

      NOTHING MAY START LLAMA-SERVER EXCEPT graph\pipeline\nightly.ps1, AND NOTHING MAY SCHEDULE
      NIGHTLY.PS1 EXCEPT THIS FILE.

  WHY THE DEFAULT TIME IS 21:30 AND NOT 07:00

  The plan sketches the chain hanging off the 07:00 sweep. On this box it cannot: the 07:00 ad pull,
  the 08:00 daily capture and the 09:30 watchdog all run in the morning, and the first two BOTH run
  the semantic sweep through check-ad-cycles. A chain that holds 13 GB of card anywhere in that
  stretch turns them BLIND, which is the exact failure this work exists to end. 21:30 is after the
  day's captures have long finished and its default 06:30 hard stop leaves half an hour of margin
  before the 07:00 job even begins. The chain is also the right length for the slot: a full contested
  run measured 7 minutes on 338 questions.

  The task deliberately does NOT set -WakeToRun. A machine woken from sleep to hold a GPU for ten
  minutes is a decision Brad should make deliberately, not one an installer makes for him; if the box
  is asleep at 21:30 the chain simply does not run that night.

  WHY THE TRIGGER REPEATS HOURLY UNTIL 05:30 (2026-09-09, queue 2026-09-09-d3e937)

  The line above used to end "and -StartWhenAvailable catches it at the next login". THAT IS NOT WHAT
  StartWhenAvailable DOES, and this estate lost a night finding out. On 2026-09-08 Windows Update
  restarted the box three times between 20:29 and 20:33, nobody signed in until 03:29 the next
  morning, and this task runs as an InteractiveToken - so the 21:30 occurrence had no session to run
  in and the scheduler counted it missed. StartWhenAvailable did NOT re-queue it: measured on this
  box, a session existed from 03:29, the 07:00, 08:00 and 10:30 Interactive tasks all fired, and this
  one's LastRunTime stayed at 2026-09-07 21:30 for 37 hours until the heartbeat paged TASK STALE.
  StartWhenAvailable re-queues an occurrence the machine slept through; an occurrence REFUSED for
  want of a session is simply gone.

  So the trigger now carries a repetition: 21:30 every hour for 8 hours, giving occurrences at 21:30,
  22:30 ... 05:30. Each is independent, so the first one after a sign-in runs, and nightly.ps1's own
  Test-AlreadyRanThisWindow makes every later one a no-op once the night's resolve stage has
  completed. The last occurrence (05:30) still has 60 minutes against the 06:30 hard stop, comfortably
  above the chain's MinMinutes of 12, and nothing can fire in daylight because the duration ends at
  05:30. The chain's own two clocks are untouched.

  THE 8 HOURS IS DERIVED, NOT TUNED. It is the span from -At to one hour before -HardStop, which is
  the largest window in which a fresh occurrence still has more than MinMinutes to work with. No
  sweep of values was run and none is meaningful: any smaller number just gives up catch-up chances,
  and any larger one starts the chain with less time than it needs.

  WHAT ELSE WAS CONSIDERED, and why not:
    * A LOGON TRIGGER. Rejected: Brad signs in around 07:00-07:30, so a logon-triggered chain would
      take the card and hold it straight through the 08:00 daily capture's semantic sweep - the exact
      BLIND-morning failure this whole lane exists to end.
    * AN S4U / PASSWORD PRINCIPAL, which would run with nobody signed in at all. Rejected here and
      left to Brad: the chain ends in a git push through the signed-in user's credential store
      (lib\pipeline-commit.ps1 -Push), and a non-interactive token cannot open DPAPI-protected
      secrets. Running the GPU with nobody present is the same class of decision as WakeToRun above.

.EXAMPLE
  powershell -File graph\pipeline\install-nightly-task.ps1
  powershell -File graph\pipeline\install-nightly-task.ps1 -At '02:00'
  powershell -File graph\pipeline\install-nightly-task.ps1 -Show
  powershell -File graph\pipeline\install-nightly-task.ps1 -Uninstall
#>
param(
  [string]$At = '21:30',
  [string]$HardStop = '06:30',
  [int]$MaxMinutes = 150,
  # How long the hourly catch-up repetition stays open. Derived from -At and -HardStop; see the
  # header. Changing it does not change either of the chain's own clocks.
  [int]$CatchUpHours = 8,
  [switch]$Uninstall,
  [switch]$Show,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

$taskName = 'TC Graph Nightly Matching'
$chain    = Join-Path $PSScriptRoot 'nightly.ps1'
$repo     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$registry = Join-Path $repo 'grocery\expected-automations.json'
$xmlOut   = Join-Path $repo 'ops\scheduled-tasks\tc-graph-nightly-matching.xml'

function Test-TaskWatched {
  <#
    .SYNOPSIS Is this task named in the watcher's registry? '' to proceed, else the refusal reason.
    .DESCRIPTION THE WATCH ENTRY IS AN INPUT TO REGISTRATION (2026-09-09, queue 2026-09-09-d3e937).
                 This task was registered on 2026-08-22 and added to
                 grocery\expected-automations.json on 2026-08-25, so for three mornings nothing in
                 the estate would have noticed if it stopped. The only cover was health-heartbeat
                 printing TASK UNWATCHED the next day, which is an alarm whose only follower is a
                 human typing an entry - and the harvest crawl was hand-added the same way two days
                 later, so it is a class and not an incident.

                 A SECOND, IDENTICAL COPY LIVES IN meal-prep\pipeline\install-harvest-task.ps1, on
                 purpose: the two registrars own different lanes and must not take a dependency on
                 each other. The two cannot drift apart silently because
                 ops\audit-task-registration.ps1 fails the push when a registrar with a committed
                 definition does not carry the refusal.

                 Pure over its arguments. $Registry is the parsed registry document, or $null.
  #>
  param([Parameter(Mandatory=$true)][string]$TaskName, $Registry)
  if (-not $Registry) {
    return ("{0} could not be read, so whether '{1}' is watched is UNKNOWN. Unreadable is not watched." -f 'grocery\expected-automations.json', $TaskName)
  }
  $watch = $null
  foreach ($row in @($Registry.windows_tasks)) { if ($row -and ([string]$row.name -eq $TaskName)) { $watch = $row } }
  if (-not $watch) {
    return ("grocery\expected-automations.json has no windows_tasks entry for '{0}', so health-heartbeat could not notice if it stopped firing. Add the entry (name, max_age_hours, why, proves) FIRST, then register." -f $TaskName)
  }
  foreach ($f in @('max_age_hours', 'why', 'proves')) {
    if (-not $watch.PSObject.Properties[$f] -or -not [string]$watch.$f) {
      return ("the windows_tasks entry for '{0}' has no '{1}'. A row without one is a row that cannot page usefully." -f $TaskName, $f)
    }
  }
  return ''
}

if ($SelfTest) {
  # PURE. Registers nothing, reads no scheduler, so ops\run-gates.ps1 can discover and run it.
  $bad = 0
  $ran = 0
  function T([string]$n, [bool]$ok, $got = '') {
    $script:ran++
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     {0}   got: {1}" -f $n, $got); $script:bad++ }
  }

  # MUST FIRE, FROZEN FROM THE ESTATE'S REAL STATE ON 2026-08-22..08-25: the task is about to be
  # registered and the registry does not name it. Nothing at change time saw that; only the next
  # morning's heartbeat line, three mornings running.
  $rMissing = [pscustomobject]@{ windows_tasks = @([pscustomobject]@{ name = 'TC Grocery Ad Pulls 0700'; max_age_hours = 30; why = 'x'; proves = 'y' }) }
  $w1 = Test-TaskWatched -TaskName $taskName -Registry $rMissing
  T 'MUST FIRE  a task the registry does not name is refused, by name' `
    ($w1 -like "*$taskName*" -and $w1 -like '*no windows_tasks entry*') $w1
  $rThin = [pscustomobject]@{ windows_tasks = @([pscustomobject]@{ name = $taskName; max_age_hours = 30; why = 'x' }) }
  T 'MUST FIRE  an entry with no ''proves'' is refused - a row that cannot page usefully is not a watch' `
    ((Test-TaskWatched -TaskName $taskName -Registry $rThin) -like "*no 'proves'*") (Test-TaskWatched -TaskName $taskName -Registry $rThin)
  T 'MUST FIRE  a registry that could not be read is refused rather than assumed clean' `
    ((Test-TaskWatched -TaskName $taskName -Registry $null) -like '*Unreadable is not watched*') (Test-TaskWatched -TaskName $taskName -Registry $null)
  if (Test-Path $registry) {
    $rReal = $null
    try { $rReal = [IO.File]::ReadAllText($registry) | ConvertFrom-Json } catch { $rReal = $null }
    $w2 = Test-TaskWatched -TaskName $taskName -Registry $rReal
    T 'MUST NOT FIRE the row shipped in grocery\expected-automations.json today permits registration' ($w2 -eq '') $w2
  } else { T 'the registry exists' $false $registry }

  # SOURCE ASSERTIONS over the registration path. Needles built by concatenation so these lines are
  # not their own matches.
  $src = [IO.File]::ReadAllText($PSCommandPath)
  $nCall = 'Test-Task' + 'Watched -TaskName $taskName -Registry $regDoc'
  T 'CLEAN TWIN the registration path actually calls the refusal before registering' `
    ($src.Contains($nCall)) 'the refusal is defined but never called'
  # MUST FIRE: the catch-up repetition is the whole of what queue 2026-09-09-d3e937 added here, and a
  # silent revert to a single daily occurrence must not pass as a fix.
  $nRep = '$trigger.Repe' + 'tition = (New-ScheduledTaskTrigger -Once'
  T 'MUST FIRE  the daily trigger carries the in-night catch-up repetition' ($src.Contains($nRep)) 'no repetition on the trigger'
  # MUST FIRE: StopAtDurationEnd must stay FALSE. True would let Task Scheduler kill a running chain
  # at 05:30, which skips the finally block that hands the card back - the failure this lane exists
  # to end - and would kill the 05:30 catch-up occurrence at the instant it started.
  $nStop = '$trigger.Repetition.StopAtDuration' + 'End = $false'
  T 'MUST FIRE  StopAtDurationEnd stays FALSE, so no scheduler kill can skip the card teardown' ($src.Contains($nStop)) 'StopAtDurationEnd is not pinned false'
  # MUST FIRE: the registrar exports the definition it just created, or the committed XML goes stale
  # the first time anyone re-runs this and three gates read a file that is no longer the live task.
  $nExp = 'Export-Scheduled' + 'Task -TaskName $taskName'
  T 'MUST FIRE  the registrar exports the definition it just registered' ($src.Contains($nExp)) 'no export step'
  # MUST FIRE: the export must never commit an account SID.
  $nSid = "Replace(`$sid, '__CURRENT_USER_" + "SID__')"
  T 'MUST FIRE  the export substitutes the account SID before writing' ($src.Contains($nSid)) 'the SID is not substituted'
  # CLEAN TWIN: the two clocks this catch-up must live inside are untouched.
  T 'CLEAN TWIN the chain''s two clocks are unchanged - hard stop 06:30, budget 150 min' `
    ($HardStop -eq '06:30' -and $MaxMinutes -eq 150) ("$HardStop / $MaxMinutes")
  # CLEAN TWIN: the catch-up window ends one hour before the hard stop, so the last occurrence still
  # has more than the chain's MinMinutes of 12 to work with.
  $lastAt = [datetime]::ParseExact($At, 'HH:mm', $null).AddHours($CatchUpHours)
  $hardAt = [datetime]::ParseExact($HardStop, 'HH:mm', $null).AddDays(1)
  T 'CLEAN TWIN the last catch-up occurrence still has 60 min against the hard stop' `
    ([int]($hardAt - $lastAt).TotalMinutes -eq 60) ([int]($hardAt - $lastAt).TotalMinutes)

  if ($bad -gt 0) { Write-Output ("install-nightly-task SELF-TEST FAIL: {0} of {1} case(s)" -f $bad, $ran); exit 1 }
  Write-Output ("install-nightly-task SELF-TEST PASS: {0} case(s) - the watch-entry refusal (registry silent about the task, a thin entry, an unreadable registry, the live row), the catch-up repetition, StopAtDurationEnd pinned false, the export step and its SID substitution, and the two chain clocks left alone" -f $ran)
  exit 0
}

if ($Show) {
  $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if (-not $t) { Write-Output "$taskName is NOT installed."; exit 0 }
  $i = Get-ScheduledTaskInfo -TaskName $taskName
  Write-Output ("{0}: {1}" -f $taskName, $t.State)
  Write-Output ("  action    : {0} {1}" -f $t.Actions[0].Execute, $t.Actions[0].Arguments)
  # THE REPETITION IS PRINTED, because it is the whole of what queue 2026-09-09-d3e937 added and an
  # -Show that did not name it would let a silent revert look identical to the fix.
  foreach ($g in @($t.Triggers)) {
    Write-Output ("  trigger   : {0}" -f $g.StartBoundary)
    if ($g.Repetition -and $g.Repetition.Interval) {
      Write-Output ("  catch-up  : every {0} for {1} (stop at duration end: {2})" -f `
                    $g.Repetition.Interval, $g.Repetition.Duration, [bool]$g.Repetition.StopAtDurationEnd)
    } else {
      Write-Output '  catch-up  : NONE - a night lost to a reboot before sign-in cannot be picked up'
    }
  }
  Write-Output ("  next run  : {0}" -f $i.NextRunTime)
  Write-Output ("  last run  : {0}  (result {1})" -f $i.LastRunTime, $i.LastTaskResult)
  Write-Output ("  missed    : {0}" -f $i.NumberOfMissedRuns)
  exit 0
}

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Output "Removed $taskName. Nothing schedules llama-server now."
  exit 0
}

if (-not (Test-Path -LiteralPath $chain)) { throw "the chain is missing: $chain" }

# A task whose script fails its own fixtures is worse than no task: it would run nightly, hold the
# card, and prove nothing. Refuse to install one.
& powershell -NoProfile -ExecutionPolicy Bypass -File $chain -SelfTest | Out-Null
if ($LASTEXITCODE -ne 0) { throw "nightly.ps1 -SelfTest failed (exit $LASTEXITCODE); refusing to schedule it" }

# THE WATCH ENTRY IS AN INPUT TO REGISTRATION, NOT AN AFTERTHOUGHT (2026-09-09, queue
# 2026-09-09-d3e937). This task was registered on 2026-08-22 and added to the watcher's registry on
# 2026-08-25, so for three mornings nothing in the estate would have noticed if it stopped. The only
# thing that covered the gap was health-heartbeat printing TASK UNWATCHED the next day, which is an
# alarm whose only follower is a human typing an entry. TC Recipe Harvest Crawl was hand-added the
# same way. Refusing here makes "registered but unwatched" impossible to create rather than merely
# reported, and ops\audit-task-registration.ps1 is the change-time gate for the ones already in the
# tree.
$regDoc = $null
if (Test-Path -LiteralPath $registry) {
  try { $regDoc = [IO.File]::ReadAllText($registry) | ConvertFrom-Json } catch { $regDoc = $null }
}
$notWatched = Test-TaskWatched -TaskName $taskName -Registry $regDoc
if ($notWatched) { throw ("REFUSING to register '{0}': {1}" -f $taskName, $notWatched) }
Write-Output ("watch entry OK for '{0}'" -f $taskName)

$argLine = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -HardStop {1} -MaxMinutes {2}' -f $chain, $HardStop, $MaxMinutes)
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
# THE IN-NIGHT CATCH-UP. See the header for why StartWhenAvailable is not enough and what else was
# considered. Built by lifting the Repetition off a throwaway -Once trigger, which is the only way
# PowerShell 5.1 exposes a repetition on a daily trigger.
$trigger   = New-ScheduledTaskTrigger -Daily -At $At
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At $At `
                         -RepetitionInterval (New-TimeSpan -Hours 1) `
                         -RepetitionDuration (New-TimeSpan -Hours $CatchUpHours)).Repetition
# StopAtDurationEnd STAYS FALSE, and this is a deliberate departure from the plan's exact wording
# (2026-09-09, queue 2026-09-09-d3e937). It does NOT control whether new occurrences fire in daylight
# - the duration already does that - it controls whether Task Scheduler KILLS a chain that is still
# running when the duration ends. A scheduler kill terminates the process, which skips the finally
# block that hands the card back, so llama-server would keep 13 GB through the 07:00 and 08:00
# sweeps: the exact failure this whole lane exists to end, and the reason the ExecutionTimeLimit
# comment below already says the third clock must only ever fire after the script's own two have.
# It would also kill the 05:30 catch-up occurrence at the instant it started.
$trigger.Repetition.StopAtDurationEnd = $false
$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited
# ExecutionTimeLimit is a THIRD clock, deliberately looser than the script's own two: Task Scheduler
# killing the process would skip the finally block that hands the card back, so it must only ever
# fire when the script's own deadline has already failed to.
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
                                          -ExecutionTimeLimit (New-TimeSpan -Minutes ($MaxMinutes + 30))
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Force `
    -Description 'Nightly local matching chain: emit contested -> semantic sweep -> llama-server -> resolve -> Learning Stage 1 -> llama-server down. The ONLY scheduled path allowed to start llama-server; it stops it in a finally block so the 07:00 sweep always finds a free card.' | Out-Null

# EXPORT THE DEFINITION THE REGISTRAR JUST CREATED. Until today the committed XML was a hand-made
# before-image exported once on 2026-09-06, so any later run of this registrar silently drifted the
# live task away from the file that three gates read as the truth. Two edits to the raw export, both
# load-bearing and both documented in ops\install-grocery-tasks.ps1's header:
#   * the account SID becomes __CURRENT_USER_SID__ - a raw export carries S-1-5-21-..., which is
#     identifying, machine-specific, and names a nonexistent account anywhere else
#   * the declaration says UTF-16 (what the scheduler emits) while the bytes are written UTF-8
# Written with WriteAllText and LF, no BOM: .gitattributes stores this tree LF, and Set-Content would
# add a BOM that the XML parsers here read as content.
$exported = Export-ScheduledTask -TaskName $taskName
$sid = [string]([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
$exported = $exported.Replace($sid, '__CURRENT_USER_SID__')
$exported = [regex]::Replace($exported, '^\s*<\?xml[^>]*\?>', '<?xml version="1.0" encoding="UTF-8"?>')
$exported = $exported -replace "`r`n", "`n"
if (-not $exported.EndsWith("`n")) { $exported += "`n" }
if ($exported -match 'S-1-5-21-') { throw "REFUSING to write $xmlOut - the export still carries an account SID after substitution" }
[IO.File]::WriteAllText($xmlOut, $exported, (New-Object Text.UTF8Encoding($false)))
Write-Output ("exported the live definition to {0} ({1} bytes)" -f $xmlOut, $exported.Length)

Write-Output ("Installed {0} for {1} daily (hard stop {2}, budget {3} min)." -f $taskName, $At, $HardStop, $MaxMinutes)
Write-Output ("  catch-up: every hour for {0} h from {1}, so the last occurrence is {2}" -f `
              $CatchUpHours, $At, ([datetime]::ParseExact($At, 'HH:mm', $null).AddHours($CatchUpHours).ToString('HH:mm')))
Write-Output ("  {0} {1}" -f 'powershell.exe', $argLine)
Write-Output '  Status after each run: grocery\out\logs\graph-nightly-status.json'
