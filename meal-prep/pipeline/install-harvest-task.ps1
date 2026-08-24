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

if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, $got = '') {
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
  Write-Output ''
  if ($bad -gt 0) { Write-Output ("install-harvest-task SELF-TEST FAIL: {0} case(s)" -f $bad); exit 1 }
  Write-Output 'install-harvest-task SELF-TEST PASS'
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

$action  = New-ScheduledTaskAction -Execute 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe' `
                                   -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script)
$trigger = New-ScheduledTaskTrigger -Daily -At $At
$set     = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName $TASK -Action $action -Trigger $trigger -Settings $set -Force | Out-Null
Write-Output ("install-harvest-task: registered '{0}' daily at {1}" -f $TASK, $At)
Write-Output ("  {0}" -f $script)
Write-Output '  costs no Claude tokens and no GPU; harvest caps itself at 60 fetches per publisher per day'
exit 0
