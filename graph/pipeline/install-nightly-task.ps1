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
  is asleep at 21:30 the chain simply does not run that night, and -StartWhenAvailable catches it at
  the next login.

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
  [switch]$Uninstall,
  [switch]$Show
)
$ErrorActionPreference = 'Stop'

$taskName = 'TC Graph Nightly Matching'
$chain    = Join-Path $PSScriptRoot 'nightly.ps1'

if ($Show) {
  $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if (-not $t) { Write-Output "$taskName is NOT installed."; exit 0 }
  $i = Get-ScheduledTaskInfo -TaskName $taskName
  Write-Output ("{0}: {1}" -f $taskName, $t.State)
  Write-Output ("  action    : {0} {1}" -f $t.Actions[0].Execute, $t.Actions[0].Arguments)
  Write-Output ("  next run  : {0}" -f $i.NextRunTime)
  Write-Output ("  last run  : {0}  (result {1})" -f $i.LastRunTime, $i.LastTaskResult)
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

$argLine = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -HardStop {1} -MaxMinutes {2}' -f $chain, $HardStop, $MaxMinutes)
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
$trigger   = New-ScheduledTaskTrigger -Daily -At $At
$principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel Limited
# ExecutionTimeLimit is a THIRD clock, deliberately looser than the script's own two: Task Scheduler
# killing the process would skip the finally block that hands the card back, so it must only ever
# fire when the script's own deadline has already failed to.
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
                                          -ExecutionTimeLimit (New-TimeSpan -Minutes ($MaxMinutes + 30))
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Principal $principal -Force `
    -Description 'Nightly local matching chain: emit contested -> semantic sweep -> llama-server -> resolve -> Learning Stage 1 -> llama-server down. The ONLY scheduled path allowed to start llama-server; it stops it in a finally block so the 07:00 sweep always finds a free card.' | Out-Null

Write-Output ("Installed {0} for {1} daily (hard stop {2}, budget {3} min)." -f $taskName, $At, $HardStop, $MaxMinutes)
Write-Output ("  {0} {1}" -f 'powershell.exe', $argLine)
Write-Output '  Status after each run: grocery\out\logs\graph-nightly-status.json'
