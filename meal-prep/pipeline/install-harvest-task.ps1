<#
.SYNOPSIS
  Register (or remove) the scheduled harvest crawl. The ONLY thing allowed to schedule harvest-crawl.ps1.

.DESCRIPTION
  Brad's ruling 2026-08-24: schedule the CRAWL, keep the RUN manual.

  THE SPLIT THIS ENFORCES. Harvesting is free - sitemaps, cached fetches, and parsing the
  machine-readable recipe block publishers embed for Google. No Claude, no graphics card. Everything
  that SPENDS lives in a run, and a run stays manual because that is where the tokens go. So this
  file schedules the free half and deliberately schedules nothing else.

  WHY IT NEEDED SCHEDULING AT ALL. Nothing about the Recipe Hunter was scheduled - not the run, and
  not the crawl. `NIGHTLY_CAP = 60` is named nightly but nothing ran nightly; it is a politeness
  BUDGET that resets at midnight. So the candidate shelf never restocked itself, and on 2026-08-24 a
  proving run reached for a corpus that was not there.

  WHY 18:00. Not contention - this never loads a model, so the llama-server ordering rule does not
  reach it (graph\pipeline\nightly.ps1 owns the card, and only install-nightly-task.ps1 may schedule
  that). 18:00 simply keeps one job per part of the day for whoever reads the task list: 07:00 ad
  pull, 08:00 capture, 09:30 watchdog, 18:00 crawl, 21:30 graph nightly.

  SAFE TO RUN TWICE. harvest.py caps itself at 60 network fetches per publisher per calendar day and
  keeps its own count, so a second run in the same day finds no room and fetches nothing.

  Usage:
    install-harvest-task.ps1              register (or update) the task
    install-harvest-task.ps1 -Remove      remove it
    install-harvest-task.ps1 -Status      show what is registered
    install-harvest-task.ps1 -At 17:00    a different daily time
#>
param([switch]$Remove, [switch]$Status, [string]$At = '18:00', [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$TASK = 'TC Recipe Harvest Crawl'
$script = Join-Path $here 'harvest-crawl.ps1'
$repo     = Split-Path -Parent (Split-Path -Parent $here)
$registry = Join-Path $repo 'grocery\expected-automations.json'
$xmlOut   = Join-Path $repo 'ops\scheduled-tasks\tc-recipe-harvest-crawl.xml'

function Test-TaskWatched {
  <#
    .SYNOPSIS Is this task named in the watcher's registry? '' to proceed, else the refusal reason.
    .DESCRIPTION THE WATCH ENTRY IS AN INPUT TO REGISTRATION (2026-09-09, queue 2026-09-09-d3e937).
                 This task was registered on 2026-08-24 and hand-added to
                 grocery\expected-automations.json later, so it was unwatched from birth - the same
                 shape as the graph task registered two days before it. The only thing covering
                 either was health-heartbeat printing TASK UNWATCHED the next morning, an alarm whose
                 only follower is a human typing an entry.

                 A SECOND, IDENTICAL COPY OF THIS RULE LIVES IN graph\pipeline\install-nightly-task.ps1
                 and that is deliberate rather than careless: the two registrars own different lanes
                 and must not take a dependency on each other. The two copies cannot drift apart
                 silently because ops\audit-task-registration.ps1 fails the push when a registrar
                 with a committed definition does not carry the refusal.

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
  $bad = 0
  $ran = 0
  # THE COUNT IS COUNTED, NEVER TYPED. A hand-written total goes stale the first time a case is added
  # or deleted, and a deleted case can leave exit 0 with a large-looking tally.
  function T([string]$n, [bool]$ok, $got = '') {
    $script:ran++
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     {0}   got: {1}" -f $n, $got); $script:bad++ }
  }
  T 'the wrapper it schedules exists' (Test-Path $script) $script
  T 'MUST FIRE  and the thing it schedules IS the crawl wrapper, by path' `
    ($script -like '*harvest-crawl.ps1') $script
  # THE SCAN IS OVER THE EXECUTING REGION, delimited by the marker below, and it asserts SHAPE rather
  # than searching for words. Earlier shapes of this greped for 'claude' and matched this file's own
  # output line "costs no Claude tokens", and looked for the literal 'harvest-crawl.ps1' which lives
  # in a variable ABOVE the marker. A grep over a file that contains the grep, or over text the file
  # legitimately prints, proves nothing.
  $src = Get-Content $PSCommandPath -Raw
  $mk = $src.LastIndexOf('# ---- EXECUTION BEGINS')
  $code = if ($mk -ge 0) { $src.Substring($mk) } else { '' }
  T 'the execution marker is present, or the guards below scan nothing' ($code.Length -gt 0) 'no marker'
  T 'MUST FIRE  it registers exactly ONE action, built from $script and nothing else' `
    ($code.Length -gt 0 -and ([regex]::Matches($code, 'New-ScheduledTaskAction')).Count -eq 1 `
     -and $code -match '-f \$script') 'not exactly one action built from $script'
  # A scheduler that could quietly register a RUN is the whole thing this split exists to prevent.
  T 'MUST FIRE  it never schedules a run or the card - no hunt-daemon, no serve.ps1, no nightly.ps1' `
    ($code.Length -gt 0 -and -not ($code -match 'hunt-daemon|serve\.ps1|nightly\.ps1')) `
    'found something it must not schedule'

  # ---- the watch entry is an input to registration (2026-09-09, queue 2026-09-09-d3e937) ---------
  # MUST FIRE, FROZEN FROM THE ESTATE'S REAL STATE ON 2026-08-24: the task is about to be registered
  # and the registry does not name it. That is what actually happened, and nothing at change time saw
  # it - only the next morning's heartbeat line, which a human then had to act on.
  $rMissing = [pscustomobject]@{ windows_tasks = @([pscustomobject]@{ name = 'TC Grocery Ad Pulls 0700'; max_age_hours = 30; why = 'x'; proves = 'y' }) }
  $w1 = Test-TaskWatched -TaskName $TASK -Registry $rMissing
  T 'MUST FIRE  a task the registry does not name is refused, by name' `
    ($w1 -like "*$TASK*" -and $w1 -like '*no windows_tasks entry*') $w1
  # MUST FIRE: an entry that exists but carries no proof or no why cannot page usefully.
  $rThin = [pscustomobject]@{ windows_tasks = @([pscustomobject]@{ name = $TASK; max_age_hours = 30; why = 'x' }) }
  T 'MUST FIRE  an entry with no ''proves'' is refused' `
    ((Test-TaskWatched -TaskName $TASK -Registry $rThin) -like "*no 'proves'*") (Test-TaskWatched -TaskName $TASK -Registry $rThin)
  # MUST FIRE: an unreadable registry is UNKNOWN, never watched.
  T 'MUST FIRE  a registry that could not be read is refused rather than assumed clean' `
    ((Test-TaskWatched -TaskName $TASK -Registry $null) -like '*Unreadable is not watched*') (Test-TaskWatched -TaskName $TASK -Registry $null)
  # MUST NOT FIRE, against the REAL registry on disk. This is the assertion a frozen fixture cannot
  # make: that the row shipped in this tree today would let this registrar run.
  if (Test-Path $registry) {
    $rReal = $null
    try { $rReal = [IO.File]::ReadAllText($registry) | ConvertFrom-Json } catch { $rReal = $null }
    $w2 = Test-TaskWatched -TaskName $TASK -Registry $rReal
    T 'MUST NOT FIRE the row shipped in grocery\expected-automations.json today permits registration' ($w2 -eq '') $w2
  } else {
    T 'the registry exists' $false $registry
  }
  # CLEAN TWIN: the refusal is wired into the EXECUTING region, not just defined. A function nobody
  # calls is a rule nobody follows. Needle built, so this line is not its own match.
  $nCall = 'Test-Task' + 'Watched -TaskName $TASK -Registry $regDoc'
  T 'CLEAN TWIN the execution path actually calls the refusal before registering' `
    ($code.Length -gt 0 -and $code.Contains($nCall)) 'the refusal is defined but never called'

  Write-Output ''
  if ($bad -gt 0) { Write-Output ("install-harvest-task SELF-TEST FAIL: {0} of {1} case(s)" -f $bad, $ran); exit 1 }
  Write-Output ("install-harvest-task SELF-TEST PASS: {0} case(s) - the wrapper it schedules, the one-action shape, the never-schedule-a-run guard, and the watch-entry refusal (registry silent about the task, a thin entry, an unreadable registry, and the live row)" -f $ran)
  exit 0
}

# ---- EXECUTION BEGINS ------------------------------------------------------------------------------
if ($Status) {
  $t = Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue
  if (-not $t) { Write-Output ("install-harvest-task: '{0}' is NOT registered" -f $TASK); exit 0 }
  Write-Output ("install-harvest-task: '{0}' is {1}" -f $TASK, $t.State)
  foreach ($a in $t.Actions)  { Write-Output ("  action  {0} {1}" -f $a.Execute, $a.Arguments) }
  foreach ($g in $t.Triggers) { Write-Output ("  trigger {0}" -f $g.StartBoundary) }
  exit 0
}

if ($Remove) {
  if (Get-ScheduledTask -TaskName $TASK -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TASK -Confirm:$false
    Write-Output ("install-harvest-task: removed '{0}'" -f $TASK)
  } else {
    Write-Output ("install-harvest-task: '{0}' was not registered" -f $TASK)
  }
  exit 0
}

if (-not (Test-Path $script)) { Write-Output ("install-harvest-task: CANNOT RUN - no wrapper at {0}" -f $script); exit 2 }

# THE WATCH ENTRY IS AN INPUT TO REGISTRATION (2026-09-09, queue 2026-09-09-d3e937). This task was
# registered on 2026-08-24 and hand-added to grocery\expected-automations.json later, so it was
# unwatched from birth - the same shape as the graph task registered two days before it. The only
# thing that covered either was health-heartbeat printing TASK UNWATCHED the next morning, which is an
# alarm whose only follower is a human typing an entry. Refusing here makes the state impossible to
# create; ops\audit-task-registration.ps1 is the change-time gate over the registrars already here.
$regDoc = $null
if (Test-Path -LiteralPath $registry) {
  try { $regDoc = [IO.File]::ReadAllText($registry) | ConvertFrom-Json } catch { $regDoc = $null }
}
$notWatched = Test-TaskWatched -TaskName $TASK -Registry $regDoc
if ($notWatched) {
  Write-Output ("install-harvest-task: REFUSING to register '{0}' - {1}" -f $TASK, $notWatched); exit 2
}
Write-Output ("install-harvest-task: watch entry OK for '{0}'" -f $TASK)

$action  = New-ScheduledTaskAction -Execute 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe' `
                                   -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script)
$trigger = New-ScheduledTaskTrigger -Daily -At $At
# HOURLY CATCH-UP INSIDE A 6-HOUR WINDOW (2026-09-10, queue 2026-09-10-2b79d3). A one-occurrence daily trigger on an
# Interactive task is unrunnable when a Windows Update restart lands before a sign-in, and StartWhenAvailable does not
# re-queue that occurrence. A repeat of THIS task is already a no-op by harvest.py's own per-publisher daily budget
# (the header above: "a second run in the same day finds no room and fetches nothing"), so it needs no run-once wrapper. Repetition
# is lifted off a throwaway -Once trigger, the only way PowerShell 5.1 exposes it on a daily trigger - the same
# construction the nightly matching registrar uses.
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At $At -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Hours 6)).Repetition
$set     = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TASK -Action $action -Trigger $trigger -Settings $set -Force | Out-Null

# EXPORT THE DEFINITION THIS REGISTRAR JUST CREATED, so three gates read a file that matches the live
# task instead of a hand-made before-image taken once on 2026-09-06. Two edits to the raw export, both
# load-bearing and both documented in ops\install-grocery-tasks.ps1's header: the account SID becomes
# __CURRENT_USER_SID__ (a raw export carries S-1-5-21-..., which is identifying and machine-specific),
# and the declaration says UTF-16 while the bytes are written UTF-8. LF, no BOM: .gitattributes stores
# this tree LF and Set-Content would add a BOM the XML parsers here read as content.
$exported = Export-ScheduledTask -TaskName $TASK
$sid = [string]([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
$exported = $exported.Replace($sid, '__CURRENT_USER_SID__')
$exported = [regex]::Replace($exported, '^\s*<\?xml[^>]*\?>', '<?xml version="1.0" encoding="UTF-8"?>')
$exported = $exported -replace "`r`n", "`n"
if (-not $exported.EndsWith("`n")) { $exported += "`n" }
if ($exported -match 'S-1-5-21-') {
  Write-Output ("install-harvest-task: REFUSING to write {0} - the export still carries an account SID after substitution" -f $xmlOut); exit 2
}
[IO.File]::WriteAllText($xmlOut, $exported, (New-Object Text.UTF8Encoding($false)))
Write-Output ("install-harvest-task: exported the live definition to {0} ({1} bytes)" -f $xmlOut, $exported.Length)

Write-Output ("install-harvest-task: registered '{0}' daily at {1}" -f $TASK, $At)
Write-Output ("  {0}" -f $script)
Write-Output '  costs no Claude tokens and no GPU; harvest caps itself at 60 fetches per publisher per day'
exit 0
