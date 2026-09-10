<#
.SYNOPSIS
  The nightly matching chain: emit -> sweep -> SIDECAR EXITS -> llama-server -> resolve -> Stage 1 ->
  LLAMA-SERVER EXITS. One card, two model stacks, never at the same time.

.DESCRIPTION
  PLAN-local-matching-2026-08-22 section 2, phase 2. Until today the two halves of this chain were
  run by hand, in whichever order the human remembered, and the rule that kept them apart was a
  sentence in a doc plus one guard that could only say NO:

      llama-server takes ~13 GB of a 16 GB card. The semantic sidecar sweep needs ~3 GB. With the
      server up the sweep OOMs, so audit-semantic-identity.ps1 checks nvidia-smi first and goes
      BLIND rather than crash. BLIND is safe and BLIND is also a day with no semantic opinion,
      which is what "on-demand only, start it by hand, stop it before 07:00" bought us in practice.

  The fix is not a better warning. It is an owner. This script owns the whole GPU window: it starts
  nothing until the previous stage has given the card back, and it stops llama-server in a finally
  block that runs on success, on failure, on timeout and on Ctrl-C. The nvidia-smi guard inside
  audit-semantic-identity.ps1 stays exactly as it is -- it is now a backstop for a rule something
  actually enforces, instead of the rule itself.

  ORDER, AND WHY IT IS THIS ORDER

    1  emit      resolve.py --emit-contested. CPU only, READ-ONLY on the database, ~2 s. It runs
                 FIRST because the sweep needs to know which pairs are contested, and the only
                 honest source of that is the resolver's own deterministic pass. The sidecar
                 deciding for itself what "contested" means is the two-implementations bug this
                 estate keeps getting bitten by.
    1b defs      emit_commodity_defs.py. Read-only, ~1 s, and BLIND rather than fatal. The
                 contested questions come from the GRAPH and are 97% recipe-namespace, which the
                 staple catalogue cannot define - without this file the contested lane can score
                 15 of 435. The identity and coverage lanes never read it, so the daily alert
                 does not move (measured: identity 181, coverage 86, either way).
    2  sweep     audit-semantic-identity.ps1. Preps the corpus (the regex lives on the PowerShell
                 side, byte-identical to the pricing engine), then runs sweep.py: identity,
                 coverage, and now the contested lane, which scores those pairs and warms every
                 vector the resolve lane will want. The sidecar process EXITS at the end of this
                 stage; that is what frees the card.
    3  serve     tools\local-llm\serve.ps1. Started here and nowhere else in any scheduled path.
    4  resolve   resolve.py --llm over the contested set, now behind the HELPER FILTER (plan §2
                 step 2): a question the trained cross-encoder scores below --helper-threshold is
                 banked helper_rejected and never reaches the model. Reject-only - v_current_rows
                 admits include_hit and llm_confirmed only, so nothing in this stage can price a
                 cell. Checkpointed and resumable by construction, which is what makes a deadline
                 kill safe: stopping it at minute 40 keeps the first 40 minutes of verdicts.
    5  stage1    graph\learning\stage1_analyze.py, the free local half of the learning loop.
    6  stop      llama-server down, verified, always.

  WHAT THIS SCRIPT WILL NOT DO

  * It will not run past its deadline. -HardStop is a wall-clock time the card MUST be free by, and
    it is checked before every stage and while resolve runs. The point is not tidiness: the 07:00 ad
    pull and the 08:00 daily capture both run the semantic sweep, and a chain that overruns turns
    those into BLIND days -- exactly the failure it exists to end.
  * It will not start llama-server while anything else holds the card. Free VRAM is read from
    nvidia-smi and the sidecar's own python must have exited.
  * It will not block anything. Every stage is BLIND-not-block: a stage that fails is recorded and
    the chain continues to teardown. The board does not depend on this box being healthy, and this
    script publishes nothing.

.EXAMPLE
  powershell -File graph\pipeline\nightly.ps1                 # the chain
  powershell -File graph\pipeline\nightly.ps1 -SelfTest       # frozen fixtures, no GPU, no data
  powershell -File graph\pipeline\nightly.ps1 -WhatIfOnly     # print the plan, run nothing
  powershell -File graph\pipeline\nightly.ps1 -StopOnly       # just put the card back
#>
param(
  [switch]$SelfTest,
  [switch]$WhatIfOnly,
  [switch]$StopOnly,
  # The wall-clock time the card must be free by. Default 06:30 protects the 07:00 ad pull and the
  # 08:00 daily capture, both of which run the sweep. A time already past today means TOMORROW at
  # that time, so a chain launched at 22:00 gets its full window instead of refusing instantly.
  [string]$HardStop = '06:30',
  # Total budget regardless of the clock. Belt and braces: a machine whose clock jumps (DST, a
  # resume from sleep, an NTP correction) must still hand the card back.
  [int]$MaxMinutes = 150,
  # Minimum window worth starting. Below this the chain does nothing rather than start a resolve run
  # it will have to kill in five minutes.
  [int]$MinMinutes = 12,
  [int]$Jobs = 4,
  [string]$Python = '',
  # The sidecar's OWN interpreter (sidecar\.venv), which is a different thing from -Python: two
  # interpreters, two purposes (grocery\python-lib.ps1's header). Passed through to the audit for the
  # same reason the audit takes it - a BLIND path nobody can exercise on demand is untestable.
  [string]$SidecarPython = '',
  # The helper filter's cut (plan section 2 step 2). Measured 2026-08-23 two ways, and both land
  # here: on the corpus's COLD holdout 1e-4 rejects 43.7% of negatives at a 0.28% false-reject rate
  # against the local model's own 2.0%; and on the 435 live contested pairs of 2026-08-22, whose
  # model verdicts are already banked, it filtered 21 - 19 the model also rejected and 0 it matched.
  # The next decade up (1e-3) disagrees with the model on 5. Raising this is a decision about
  # cells that never get priced, so it is a parameter with a measured default, not a constant.
  [double]$HelperThreshold = 1e-4,
  [switch]$SkipSweep,
  [switch]$SkipStage1,
  # PLAN-ingredient-memory D4. CPU-only, read-mostly, ~2 s, and it runs BEFORE the card changes
  # hands - it has nothing to do with the GPU window and must never be able to eat into it.
  [switch]$SkipHunterIngest
)
$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # repo root
$graph    = Join-Path $root 'graph'
$grocery  = Join-Path $root 'grocery'
$sidecar  = Join-Path $root 'sidecar'
$statusF  = Join-Path $grocery 'out\logs\graph-nightly-status.json'

# THE RUN RECORD (2026-09-06, backlog E29). This task runs -WindowStyle Hidden and its only persisted
# output was the status JSON written at the very END - so a run that died before that line left
# nothing at all, which is indistinguishable from a run that never started. graph-nightly-status.json
# is KEPT; the transcript is the half that was missing, and Done() stamps the exit code last.
#
# THE CALL ITSELF LIVES BELOW THE -StopOnly AND -WhatIfOnly BRANCHES, and it used to live here
# (2026-09-09, queue 2026-09-09-d3e937). Start-RunLog ran for EVERY verb except -SelfTest, so a
# hand-typed `-StopOnly` or `-WhatIfOnly` wrote a today-dated graph-nightly-<date>.log for a job that
# did no work - and neither branch reaches Done(), so the file carried no `rc=` stamp either. On
# 2026-09-09 that is exactly what happened: two transcripts, 07:31 and 08:03, on the morning after
# the 09-08 21:30 occurrence was lost to a Windows Update reboot. Anyone triaging by "is there a log
# dated today" read green over a 37-hour gap. A log that makes a non-run look like a run is how that
# gap survived triage, so only the chain may write under the chain's name. The rule generalises: if
# a verb wants a record, it gets its OWN name and its own rc stamp, never the run's.
. (Join-Path $grocery 'run-log-lib.ps1')
$runLog = $null
function Done {
  param([int]$Rc = 0)
  Stop-RunLog -ExitCode $Rc -Path $runLog
  exit $Rc
}

# VRAM the sweep needs, and the floor llama-server needs to be worth starting. Both are the numbers
# already used elsewhere in the estate, restated here rather than imported so this script can
# self-test with no other file loaded.
$SWEEP_NEED_MIB = 3500
$LLAMA_NEED_MIB = 13500

# WRITE-OUTPUT WOULD BE A BUG HERE, and was one for exactly one run. A PowerShell function returns
# EVERYTHING written to its success stream, so a Log call inside Stop-Llama made `$freed` an array of
# two log lines and a boolean, and the run-status file recorded `card_free: [...text..., true]`. The
# first version of this script shipped that. [Console]::WriteLine writes to the process's stdout
# without touching any PowerShell stream, so it is still captured by Invoke-Stage's redirection and
# still cannot contaminate a return value.
function Log([string]$m) { [Console]::WriteLine("[{0}] {1}", (Get-Date -Format 'HH:mm:ss'), $m) }

# ---------------------------------------------------------------- the pure decisions, fixtured below
function Resolve-Deadline {
  <#
    .SYNOPSIS When must the card be free? The EARLIER of the wall-clock hard stop and the budget.
    .DESCRIPTION Two clocks because they fail differently. HardStop protects a known downstream job
                 and is meaningless if the system clock moves; MaxMinutes is immune to the clock but
                 knows nothing about 07:00. Taking the earlier of the two means either one alone is
                 enough to get the card back.
  #>
  param([datetime]$Now, [string]$HardStop, [int]$MaxMinutes)
  $t = [datetime]::ParseExact($HardStop, 'HH:mm', $null)
  $stop = $Now.Date.AddHours($t.Hour).AddMinutes($t.Minute)
  if ($stop -le $Now) { $stop = $stop.AddDays(1) }     # already past today -> tomorrow
  $budget = $Now.AddMinutes($MaxMinutes)
  if ($budget -lt $stop) { return $budget }
  return $stop
}

function Test-WindowUsable {
  <#
    .SYNOPSIS Is there enough time to be worth starting? Returns '' to proceed, or the reason not to.
    .DESCRIPTION A refusal here is a GOOD outcome, not a failure: the alternative is loading 13 GB of
                 weights, adjudicating for four minutes and killing it, which costs the card and buys
                 nothing.
  #>
  param([datetime]$Now, [datetime]$Deadline, [int]$MinMinutes)
  $left = [int]($Deadline - $Now).TotalMinutes
  if ($left -lt $MinMinutes) {
    return ("only {0} min to the deadline ({1}); the chain needs at least {2}" -f $left, $Deadline.ToString('HH:mm'), $MinMinutes)
  }
  return ''
}

function Get-NightWindowStart {
  <#
    .SYNOPSIS Which night is $Now in? Returns the datetime of that night's first occurrence.
    .DESCRIPTION A night SPANS MIDNIGHT, so "today" is the wrong unit. 23:30 on the 9th and 03:30 on
                 the 10th belong to the same night, whose start is the 9th at 21:30. Before 21:30 the
                 night that is running is YESTERDAY's. Pure.
  #>
  param([datetime]$Now, [string]$WindowStart = '21:30')
  $t = [datetime]::ParseExact($WindowStart, 'HH:mm', $null)
  $s = $Now.Date.AddHours($t.Hour).AddMinutes($t.Minute)
  if ($Now -lt $s) { $s = $s.AddDays(-1) }
  return $s
}

function Test-AlreadyRanThisWindow {
  <#
    .SYNOPSIS Has the chain already done this night's work? Returns '' to run, or the skip reason.
    .DESCRIPTION THE GUARD ON THE CATCH-UP (2026-09-09, queue 2026-09-09-d3e937). The task now has
                 hourly occurrences from 21:30 to 05:30 so a night lost to a Windows Update reboot
                 can still be picked up at the next sign-in. That only works if the SECOND occurrence
                 after a good run is a no-op, and the shape of the no-op decides whether the catch-up
                 exists at all.

                 IT KEYS ON THE STATUS STAMP, and specifically on `started` plus a resolve stage that
                 reached OK or PARTIAL. The two obvious alternatives are both wrong in the same
                 direction and would silently retire the feature:

                   * LastRunTime - the scheduler advances it for an occurrence that STARTED, so a
                     window the chain refused (Test-WindowUsable) or a crash before resolve would
                     read as "ran" and nothing would ever retry.
                   * the transcript - written the moment the chain starts, so it says a run began and
                     nothing about whether it finished.

                 A refused or crashed earlier occurrence therefore does NOT count as ran, on purpose:
                 that is the case the repetition exists for. PARTIAL counts because a resolve run
                 stopped at the deadline has banked its verdicts and is checkpointed - re-running it
                 would spend the card re-deciding what it already decided.

                 Pure over its arguments. $Status is the parsed graph-nightly-status.json, or $null.
  #>
  param([datetime]$Now, [string]$WindowStart = '21:30', $Status)
  if (-not $Status) { return '' }
  $startedRaw = ''
  try { $startedRaw = [string]$Status.started } catch { $startedRaw = '' }
  if (-not $startedRaw) { return '' }
  $started = [datetime]::MinValue
  if (-not [datetime]::TryParse($startedRaw, [ref]$started)) { return '' }
  $windowOpened = Get-NightWindowStart -Now $Now -WindowStart $WindowStart
  if ($started -lt $windowOpened) { return '' }        # a stamp from an earlier night proves nothing
  $resolved = $false
  foreach ($s in @($Status.stages)) {
    if (-not $s) { continue }
    if ([string]$s.stage -eq 'resolve' -and (@('OK', 'PARTIAL') -contains [string]$s.state)) { $resolved = $true }
  }
  if (-not $resolved) { return '' }                    # refused or died before resolve: retry it
  # PARENTHESISED, not `"a" + "b" -f x`: + and -f sit in different precedence groups and this estate
  # has already paid for a concatenated format string binding in the order nobody expected.
  $fmt = ('already ran this night at {0} (window opened {1}); the resolve stage completed, ' +
          'so this repetition is a no-op')
  return ($fmt -f $started.ToString('yyyy-MM-ddTHH:mm:ss'), $windowOpened.ToString('yyyy-MM-ddTHH:mm'))
}

function Test-LlamaStartable {
  <#
    .SYNOPSIS May llama-server take the card now? Returns '' for yes, or the reason for no.
    .DESCRIPTION THE ORDERING RULE, as a function. Two things must be true: the sidecar's python must
                 have exited (a sweep still running would be OOMed by us, the exact crime in reverse)
                 and the card must actually have room. A null VRAM reading is NOT a block -- no
                 nvidia-smi is a reason to proceed carefully, never a reason to invent an obstacle;
                 that is the same rule audit-semantic-identity.ps1 follows.
  #>
  param([Nullable[int]]$FreeMiB, [bool]$SidecarRunning, [int]$NeedMiB = $LLAMA_NEED_MIB)
  if ($SidecarRunning) { return 'the sidecar sweep is still running - it must exit before llama-server may take the card' }
  if ($null -eq $FreeMiB) { return '' }
  if ($FreeMiB -lt $NeedMiB) {
    return ("only {0} MiB free; llama-server needs ~{1} MiB - something else holds the card" -f $FreeMiB, $NeedMiB)
  }
  return ''
}

function Test-SweepStartable {
  <#
    .SYNOPSIS May the sidecar sweep take the card now? '' for yes, else the reason.
    .DESCRIPTION The mirror of the rule above, and the one this chain must never violate itself: the
                 sweep runs FIRST, so if llama-server is up at that point it is a leftover from a
                 previous run or a human session, and the honest thing is to say so by name.
  #>
  param([Nullable[int]]$FreeMiB, [bool]$LlamaRunning, [int]$NeedMiB = $SWEEP_NEED_MIB)
  if ($LlamaRunning) { return 'llama-server holds the card - the chain stops it before the sweep' }
  if ($null -eq $FreeMiB) { return '' }
  if ($FreeMiB -lt $NeedMiB) { return ("only {0} MiB free; the sweep needs ~{1} MiB" -f $FreeMiB, $NeedMiB) }
  return ''
}

# ---------------------------------------------------------------- the machine's actual state
function Get-FreeVramMiB {
  try {
    $q = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
    if ($LASTEXITCODE -eq 0 -and $q) { return [int](([string]@($q)[0]).Trim()) }
  } catch { }
  return $null
}
function Test-LlamaUp { return [bool](Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue) }

function Get-CiBlockDetail {
  <#
    .SYNOPSIS Did Windows Code Integrity refuse to load our binaries during this stage? '' if not.
    .DESCRIPTION A Code Integrity kill is invisible everywhere anyone would think to look. The
                 process exits 0xC0E90002 having written no output, llama.cpp never reaches the
                 line that opens its own log, and NOTHING is written to the Application event log.
                 It is recorded in Microsoft-Windows-CodeIntegrity/Operational and nowhere else.
                 On 2026-08-25 this stage recorded the bare 'llama-server did not come up' and a
                 day went into a CUDA fault that did not exist, while the answer sat one event log
                 away. A BLIND line that does not say WHY is the failure this chain exists to end.
                 Event messages carry NT device paths (\Device\HarddiskVolumeN\Codex\...) and
                 never drive letters, so the match is on the drive-stripped tail of the path.
  #>
  param([datetime]$Since, [string]$PathHint = 'C:\Codex\llm\bin')
  $needle = $PathHint -replace '^[A-Za-z]:', ''
  $ev = @()
  try {
    $ev = @(Get-WinEvent -FilterHashtable @{
              LogName = 'Microsoft-Windows-CodeIntegrity/Operational'
              Id      = 3077
              StartTime = $Since.AddSeconds(-5)
            } -ErrorAction Stop | Where-Object { $_.Message -like "*$needle*" })
  } catch { return '' }
  if ($ev.Count -eq 0) { return '' }

  $files = @($ev | ForEach-Object {
               if ($_.Message -match 'attempted to load (\S+)') { Split-Path $matches[1] -Leaf }
             } | Select-Object -Unique)
  $sac = ''
  try {
    $st = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState
    if ($st -eq 1) {
      $sac = ' Smart App Control is ON and enforcing and the llama.cpp binaries are unsigned;' +
             ' rebuilding or re-downloading them will NOT fix it, a new build is equally unsigned.'
    }
  } catch { }
  return ('BLOCKED BY WINDOWS CODE INTEGRITY - {0} event(s) refusing to load {1}.{2}' -f `
          $ev.Count, ($files -join ', '), $sac)
}

function Stop-Llama {
  <#
    .SYNOPSIS Put the card back. Idempotent, and it VERIFIES rather than assuming.
    .DESCRIPTION Called from finally, so it must survive being called when nothing is running and
                 must never throw -- a teardown that throws inside finally masks the real error that
                 got us there. It also waits: Stop-Process returns immediately and a 13 GB process
                 does not release VRAM instantly, so a caller that trusted the return would hand a
                 still-occupied card to the 07:00 sweep.
  #>
  param([int]$WaitSec = 45)
  $procs = @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
  if (-not $procs.Count) { return $true }
  Log ("stopping llama-server (pid {0})" -f (($procs | ForEach-Object { $_.Id }) -join ', '))
  foreach ($p in $procs) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { } }
  $deadline = (Get-Date).AddSeconds($WaitSec)
  while ((Get-Date) -lt $deadline) {
    if (-not (Test-LlamaUp)) {
      Log ("llama-server down; {0} MiB free" -f (Get-FreeVramMiB))
      return $true
    }
    Start-Sleep -Seconds 2
  }
  Log 'WARNING: llama-server did not exit within the teardown window - the next sweep will go BLIND and name it'
  return $false
}

function Test-SidecarUp {
  # The sidecar's interpreter, identified by PATH rather than by name: every python.exe on this box
  # is called python.exe, and only the one under sidecar\.venv is the one holding bge-m3.
  try {
    $rows = @(Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue)
    foreach ($r in $rows) {
      if ([string]$r.ExecutablePath -like (Join-Path $sidecar '*')) { return $true }
      if ([string]$r.CommandLine -match '(?i)sweep\.py') { return $true }
    }
  } catch { }
  return $false
}

# ---------------------------------------------------------------- bounded child processes
function Stop-Tree([int]$procId) {
  foreach ($c in @(Get-CimInstance Win32_Process -Filter ("ParentProcessId = " + $procId) -ErrorAction SilentlyContinue)) { Stop-Tree ([int]$c.ProcessId) }
  Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
}
function Invoke-Stage {
  <#
    .SYNOPSIS Run one stage under a timeout. Returns @{ Ok; ExitCode; TimedOut; Elapsed; Tail }.
    .DESCRIPTION ExitCode 3 is the estate's could-not-evaluate code and a timeout returns it, so a
                 killed stage can never read as a clean pass. stderr is captured BY FILE and never
                 by 2>&1: redirecting a native child's stderr under EAP=Stop makes its first line a
                 terminating throw, and Python writes plenty of benign stderr (SyntaxWarnings,
                 HuggingFace notices, tqdm bars). That trap already cost this estate one audit.
  #>
  param([string]$Name, [string]$Exe, [string[]]$Arguments, [int]$TimeoutSec, [string]$WorkDir = $root)
  $so = [IO.Path]::GetTempFileName(); $se = [IO.Path]::GetTempFileName()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = $null
  try {
    $p = Start-Process -FilePath $Exe -ArgumentList $Arguments -PassThru -NoNewWindow `
                       -WorkingDirectory $WorkDir -RedirectStandardOutput $so -RedirectStandardError $se
    $null = $p.Handle    # PS 5.1: without touching Handle first, ExitCode reads $null after exit
  } catch {
    Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
    Log ("$Name could not be launched: " + $_.Exception.Message)
    return [pscustomobject]@{ Ok = $false; ExitCode = 3; TimedOut = $false; Elapsed = 0; Tail = @("could not launch: " + $_.Exception.Message) }
  }
  $done = $p.WaitForExit([int]([math]::Max(1, $TimeoutSec)) * 1000)
  $sw.Stop(); $elapsed = [int]$sw.Elapsed.TotalSeconds
  if (-not $done) {
    try { Stop-Tree ([int]$p.Id) } catch { }
    try { $null = $p.WaitForExit(5000) } catch { }
    $tail = @()
    try { $tail = @(Get-Content $so -Tail 5 -ErrorAction SilentlyContinue) } catch { }
    Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
    Log ("TIMED OUT: $Name exceeded its $TimeoutSec s budget and was stopped")
    return [pscustomobject]@{ Ok = $false; ExitCode = 3; TimedOut = $true; Elapsed = $elapsed; Tail = @($tail) }
  }
  $out = @()
  try { $out += @(Get-Content $so -ErrorAction SilentlyContinue) } catch { }
  try { $out += @(Get-Content $se -ErrorAction SilentlyContinue) } catch { }
  Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
  $rc = try { [int]$p.ExitCode } catch { 3 }
  Log ("{0}: rc={1} in {2}s" -f $Name, $rc, $elapsed)
  foreach ($l in @($out | Select-Object -Last 4)) { Write-Output ("    | " + $l) }
  return [pscustomobject]@{ Ok = ($rc -eq 0); ExitCode = $rc; TimedOut = $false; Elapsed = $elapsed
                            Tail = @(@($out | Select-Object -Last 14) | ForEach-Object { [string]$_ }) }
}

# ---------------------------------------------------------------- self-test
if ($SelfTest) {
  $bad = 0
  Write-Output 'nightly.ps1 self-test (no GPU, no data files, no processes touched)'

  # -- deadline: the EARLIER of the two clocks wins, in both directions
  $now = [datetime]'2026-08-22 23:00'
  $d = Resolve-Deadline -Now $now -HardStop '06:30' -MaxMinutes 150
  if ($d -ne [datetime]'2026-08-23 01:30') { Write-Output "  X budget must win when it is earlier than the hard stop (got $d)"; $bad++ }
  $d = Resolve-Deadline -Now $now -HardStop '06:30' -MaxMinutes 600
  if ($d -ne [datetime]'2026-08-23 06:30') { Write-Output "  X hard stop must win when it is earlier than the budget (got $d)"; $bad++ }
  # MUST-FIRE: a hard stop already past today is TOMORROW's, not an instant refusal.
  $d = Resolve-Deadline -Now ([datetime]'2026-08-22 08:00') -HardStop '06:30' -MaxMinutes 6000
  if ($d -ne [datetime]'2026-08-23 06:30') { Write-Output "  X a hard stop already past today must roll to tomorrow (got $d)"; $bad++ }

  # -- window: refuse a window too short to be worth the weights
  if (-not (Test-WindowUsable -Now $now -Deadline $now.AddMinutes(5) -MinMinutes 12)) { Write-Output '  X MUST-FIRE: a 5-minute window must be refused'; $bad++ }
  if (Test-WindowUsable -Now $now -Deadline $now.AddMinutes(90) -MinMinutes 12) { Write-Output '  X CLEAN TWIN: a 90-minute window must be accepted'; $bad++ }

  # -- the ordering rule. MUST-FIRE: a live sweep blocks llama-server even on an empty card.
  if (-not (Test-LlamaStartable -FreeMiB 15000 -SidecarRunning $true)) { Write-Output '  X MUST-FIRE: a running sidecar must block llama-server whatever the VRAM says'; $bad++ }
  # MUST-FIRE: no room means no start.
  $why = Test-LlamaStartable -FreeMiB 4000 -SidecarRunning $false
  if (-not $why) { Write-Output '  X MUST-FIRE: 4000 MiB free must block a 13.5 GB server'; $bad++ }
  elseif ($why -notmatch '4000') { Write-Output "  X the refusal must quote the reading it refused on: $why"; $bad++ }
  # CLEAN TWIN: a free card and no sidecar -> go.
  if (Test-LlamaStartable -FreeMiB 15000 -SidecarRunning $false) { Write-Output '  X CLEAN TWIN: an empty card with no sidecar must start'; $bad++ }
  # CLEAN TWIN: no nvidia-smi reading is never an invented block.
  if (Test-LlamaStartable -FreeMiB $null -SidecarRunning $false) { Write-Output '  X CLEAN TWIN: a missing VRAM reading must not invent a block'; $bad++ }

  # -- the mirror rule, so the chain cannot OOM its own sweep
  if (-not (Test-SweepStartable -FreeMiB 15000 -LlamaRunning $true)) { Write-Output '  X MUST-FIRE: llama-server up must block the sweep'; $bad++ }
  if (Test-SweepStartable -FreeMiB 15000 -LlamaRunning $false) { Write-Output '  X CLEAN TWIN: an empty card must let the sweep run'; $bad++ }
  if (Test-SweepStartable -FreeMiB $null -LlamaRunning $false) { Write-Output '  X CLEAN TWIN: a missing VRAM reading must not block the sweep'; $bad++ }

  # -- MUST-FIRE for the return-value bug this script shipped once: Log must write NOTHING to the
  #    success stream, or every value-returning function below silently returns its own transcript.
  $captured = @(Log 'self-test: this line must not be a return value')
  if ($captured.Count -ne 0) { Write-Output ("  X MUST-FIRE: Log leaked {0} object(s) into the success stream - Stop-Llama would return its own log" -f $captured.Count); $bad++ }

  # -- the hunter-identity ingest's SLOT, which is the whole of what this script decides about it.
  #    PURE ONLY: no data files, no processes, no graph. The ingest's own behaviour is fixtured in
  #    graph\learning\ingest_hunter_events.py --selftest; what belongs HERE is the ordering rule -
  #    it must sit before anything holds the card and it must not be in the teardown.
  $src = [IO.File]::ReadAllText($PSCommandPath)
  # EVERY occurrence, not the first. Measured here on 2026-08-25: a neuter that left the original
  # call in place and added a SECOND one inside `finally` came back 0 RED against IndexOf, because
  # the first match was still in the right place. A chain with two hunter stages is a chain that
  # runs one of them in teardown, which is the thing these three checks exist to forbid.
  $hunters = @([regex]::Matches($src, [regex]::Escape("Invoke-Stage " + "'hunter'")) |
               ForEach-Object { $_.Index })
  # EVERY needle is BUILT. Measured, twice, in this one block: written out as literals, the check
  # lines matched THEMSELVES - `$iSweep` found its own source line at index 21230 and reported the
  # real sweep as running before a stage 7,600 characters later. A source-reading fixture that can
  # see itself is a fixture reading the wrong file.
  $iSweep  = $src.IndexOf('if (-not $Skip' + 'Sweep) {')
  $iServe  = $src.IndexOf("Invoke-Stage " + "'serve'")
  $iFinal  = $src.IndexOf('finally' + ' {')
  if ($hunters.Count -ne 1) { Write-Output ("  X MUST-FIRE: the chain must hold EXACTLY ONE hunter-identity stage, found " + $hunters.Count); $bad++ }
  # MUST-FIRE: it runs BEFORE the sweep, which is the first thing that takes the card. A stage that
  # crept below `serve` would be spending the GPU window on a CPU job.
  foreach ($h in $hunters) {
    if ($iSweep -ge 0 -and $h -gt $iSweep) { Write-Output '  X MUST-FIRE: the hunter ingest must run BEFORE the sweep takes the card'; $bad++ }
    if ($iServe -ge 0 -and $h -gt $iServe) { Write-Output '  X MUST-FIRE: the hunter ingest must run before llama-server takes the card'; $bad++ }
    # MUST-FIRE: never in the finally. Teardown's one job is handing the card back, and a teardown
    # that does work is a teardown that can fail at it.
    if ($iFinal -ge 0 -and $h -gt $iFinal) { Write-Output '  X MUST-FIRE: the hunter ingest must not run in the teardown block'; $bad++ }
  }
  # MUST-FIRE: exit 3 is BLIND, not FAILED. The ingest returns 3 when the event log is absent, which
  # is a real outcome and not a failure of this chain; recording it as FAILED would train its owner
  # to ignore the line.
  # THE NEEDLES ARE BUILT, NOT WRITTEN OUT, or each check would be its own match. Measured here on
  # 2026-08-25: deleting the stage's BLIND branch came back 0 RED because the CHECK LINE contained
  # the literal it was searching for. Same class as the rebid call-site pin, one script over.
  $nBlind   = "Record 'hunter' " + "'BLIND'"
  $nSkipped = "Record 'hunter' " + "'SKIPPED'"
  $nPlan    = '1c' + ' hunter'
  if (-not $src.Contains($nBlind)) { Write-Output '  X MUST-FIRE: the hunter stage must record BLIND on the could-not-evaluate exit'; $bad++ }
  if (-not $src.Contains($nSkipped)) { Write-Output '  X MUST-FIRE: -SkipHunterIngest must record SKIPPED rather than vanishing'; $bad++ }
  # CLEAN TWIN: the plan line names it too, or -WhatIfOnly describes a chain that is not the chain.
  if (-not $src.Contains($nPlan)) { Write-Output '  X CLEAN TWIN: -WhatIfOnly must print the hunter stage'; $bad++ }

  # MUST-FIRE: the serve stage must ASK Windows why, not just report that it did not come up. The
  # Code Integrity block that killed 2026-08-25 is absent from the Application log, from
  # llama.cpp's own log and from the process output, so a stage that does not read the
  # CodeIntegrity log cannot tell a blocked start from a crashed one. Needle built, not written.
  $nCiAsk = 'Get-CiBlock' + 'Detail -Since $serveStart'
  if (-not $src.Contains($nCiAsk)) { Write-Output '  X MUST-FIRE: the serve stage must check Code Integrity before recording BLIND'; $bad++ }

  # ---- the in-night catch-up guard (2026-09-09, queue 2026-09-09-d3e937) ------------------------
  # -- which night is it? A night spans midnight, so this is the unit the guard reasons in.
  if ((Get-NightWindowStart -Now ([datetime]'2026-09-09 23:30') -WindowStart '21:30') -ne [datetime]'2026-09-09 21:30') {
    Write-Output '  X MUST-FIRE: 23:30 belongs to tonight, whose window opened at 21:30'; $bad++ }
  if ((Get-NightWindowStart -Now ([datetime]'2026-09-10 03:30') -WindowStart '21:30') -ne [datetime]'2026-09-09 21:30') {
    Write-Output '  X MUST-FIRE: 03:30 belongs to YESTERDAY''s night, not to a window that has not opened'; $bad++ }

  # MUST-FIRE: a repetition that follows a good night is a no-op. Frozen from the real stamp shape -
  # grocery\out\logs\graph-nightly-status.json of 2026-09-07 carried started 21:30:02 and all ten
  # stages OK, and the 22:30 occurrence must not re-run that.
  $stRan = [pscustomobject]@{ started = '2026-09-09T21:30:02'; stages = @(
    [pscustomobject]@{ stage = 'window';  state = 'OK' }
    [pscustomobject]@{ stage = 'resolve'; state = 'OK' }
    [pscustomobject]@{ stage = 'stop';    state = 'OK' }) }
  $sk = Test-AlreadyRanThisWindow -Now ([datetime]'2026-09-09 23:30') -WindowStart '21:30' -Status $stRan
  if (-not $sk) { Write-Output '  X MUST-FIRE: a repetition after a completed resolve must skip'; $bad++ }
  elseif ($sk -notmatch '2026-09-09T21:30:02') { Write-Output "  X the skip reason must quote the run it found: $sk"; $bad++ }

  # MUST-NOT-FIRE, THE FOUNDING CASE: the 09-08 night that was LOST. The newest stamp is from 09-07,
  # the box came back at 03:29 on 09-09, and the catch-up occurrence must RUN. If the guard keyed on
  # LastRunTime or on the transcript instead of the stamp, this is the case that would silently
  # retire the whole feature.
  $stOld = [pscustomobject]@{ started = '2026-09-07T21:30:02'; stages = @(
    [pscustomobject]@{ stage = 'resolve'; state = 'OK' }) }
  if (Test-AlreadyRanThisWindow -Now ([datetime]'2026-09-09 03:30') -WindowStart '21:30' -Status $stOld) {
    Write-Output '  X MUST-NOT-FIRE: a stamp from an EARLIER night must never skip tonight'; $bad++ }

  # MUST-NOT-FIRE: an occurrence that REFUSED its window (or died before resolve) has done no work,
  # so the next repetition retries. This is the other half of the catch-up.
  $stRefused = [pscustomobject]@{ started = '2026-09-09T21:30:05'; stages = @(
    [pscustomobject]@{ stage = 'window'; state = 'REFUSED'; detail = 'only 4 min to the deadline' }
    [pscustomobject]@{ stage = 'stop';   state = 'OK' }) }
  if (Test-AlreadyRanThisWindow -Now ([datetime]'2026-09-09 22:30') -WindowStart '21:30' -Status $stRefused) {
    Write-Output '  X MUST-NOT-FIRE: a REFUSED window is not a run - the next repetition must retry'; $bad++ }
  # CLEAN TWIN: a resolve stopped at the deadline HAS banked its verdicts and is checkpointed, so it
  # counts as ran. Re-running it would spend the card re-deciding what it already decided.
  $stPartial = [pscustomobject]@{ started = '2026-09-09T21:30:02'; stages = @(
    [pscustomobject]@{ stage = 'resolve'; state = 'PARTIAL'; detail = 'stopped at the deadline' }) }
  if (-not (Test-AlreadyRanThisWindow -Now ([datetime]'2026-09-10 01:30') -WindowStart '21:30' -Status $stPartial)) {
    Write-Output '  X CLEAN TWIN: a PARTIAL resolve is banked work and must count as ran'; $bad++ }
  # CLEAN TWIN: no stamp at all is a reason to RUN. A first-ever night, or a deleted status file,
  # must never read as "already done".
  if (Test-AlreadyRanThisWindow -Now ([datetime]'2026-09-09 23:30') -WindowStart '21:30' -Status $null) {
    Write-Output '  X CLEAN TWIN: a missing status stamp must not skip the run'; $bad++ }

  # MUST-FIRE, SOURCE ASSERTION: the run transcript must start BELOW both non-run verbs, or a
  # hand-typed -StopOnly writes a today-dated graph-nightly-<date>.log for a job that did nothing and
  # anyone triaging by "is there a log dated today" reads green over a lost night. NEEDLES BUILT BY
  # CONCATENATION, or these three check lines would be their own matches.
  $nStart  = "Start-Run" + "Log -Name 'graph-nightly' -OutDir"
  $nStop   = 'if ($Stop' + 'Only) {'
  $nWhatIf = 'if ($What' + 'IfOnly) {'
  $iStart  = $src.IndexOf($nStart)
  $iStop   = $src.IndexOf($nStop)
  $iWhatIf = $src.IndexOf($nWhatIf)
  if ($iStart -lt 0) { Write-Output '  X MUST-FIRE: the run transcript call is gone entirely'; $bad++ }
  if ($iStop -lt 0 -or $iWhatIf -lt 0) { Write-Output '  X MUST-FIRE: a non-run verb branch vanished, so the ordering below proves nothing'; $bad++ }
  if ($iStart -ge 0 -and $iStop -ge 0 -and $iStart -lt $iStop) {
    Write-Output '  X MUST-FIRE: the run transcript must start BELOW the -StopOnly branch'; $bad++ }
  if ($iStart -ge 0 -and $iWhatIf -ge 0 -and $iStart -lt $iWhatIf) {
    Write-Output '  X MUST-FIRE: the run transcript must start BELOW the -WhatIfOnly branch'; $bad++ }
  # MUST-FIRE: exactly ONE transcript under the run's name. A second call anywhere would re-open the
  # hole from the other end, and IndexOf alone cannot see it - the same neuter that came back green
  # against the hunter-slot check on 2026-08-25.
  $nRunNames = @([regex]::Matches($src, [regex]::Escape($nStart)) | ForEach-Object { $_.Index })
  if ($nRunNames.Count -ne 1) {
    Write-Output ("  X MUST-FIRE: exactly ONE transcript may be opened under the run's name, found " + $nRunNames.Count); $bad++ }
  # CLEAN TWIN: the skip path still leaves a record, under its OWN name and through Stop-RunLog so it
  # carries an rc stamp. A silent skip would be a different false green.
  $nSkipName = "Start-Run" + "Log -Name 'graph-nightly-skipped'"
  if (-not $src.Contains($nSkipName)) { Write-Output '  X CLEAN TWIN: a skipped occurrence must still leave a record, under its own name'; $bad++ }

  if ($bad) { Write-Output "SELF-TEST FAILED ($bad)"; exit 2 }
  Write-Output 'self-test OK'
  exit 0
}

# ---------------------------------------------------------------- StopOnly: just hand the card back
if ($StopOnly) {
  $ok = Stop-Llama
  if ($ok) { exit 0 }
  exit 3
}

# ---------------------------------------------------------------- plan the window
$started  = Get-Date
$deadline = Resolve-Deadline -Now $started -HardStop $HardStop -MaxMinutes $MaxMinutes
$refuse   = Test-WindowUsable -Now $started -Deadline $deadline -MinMinutes $MinMinutes

$py = if ($Python) { $Python } else { '' }
if (-not $py) {
  $lib = Join-Path $grocery 'python-lib.ps1'
  if (Test-Path $lib) { . $lib; $py = Get-GraphPython }
}
$sidecarPy = Join-Path $sidecar '.venv\Scripts\python.exe'

# THE WINDOW HEADER IS PRINTED TWICE, ONCE PER PATH, AND NOT ONCE ABOVE BOTH. It used to sit here,
# above the -WhatIfOnly branch and above Start-RunLog, so the run's own header line was the one line
# the run transcript did NOT contain. Printing it inside each path costs a duplicated format string
# and buys a transcript that opens by saying what window it is working in.
if ($WhatIfOnly) {
  Log ("nightly matching chain: now {0}, deadline {1} ({2} min), jobs {3}" -f `
       $started.ToString('HH:mm'), $deadline.ToString('yyyy-MM-dd HH:mm'), [int]($deadline - $started).TotalMinutes, $Jobs)
  Log 'plan only:'
  Write-Output "  0b expiry  $py graph\learning\verdict_expiry.py --emit   (tonight's re-ask list, capped; resolve ignores a stale one)"
  Write-Output "  1 emit     $py graph\pipeline\resolve.py --emit-contested sidecar\data\contested-pairs.json"
  Write-Output "  1b defs    $py graph\pipeline\emit_commodity_defs.py --out sidecar\data\commodity-defs-graph.json"
  Write-Output "  1c hunter  $py graph\learning\ingest_hunter_events.py   (CPU only, read-mostly, before the card changes hands)"
  Write-Output "  2 sweep    grocery\audit-semantic-identity.ps1        (sidecar takes and releases the card)"
  Write-Output "  3 serve    tools\local-llm\serve.ps1 -Slots $Jobs"
  Write-Output "  4 resolve  $py graph\pipeline\resolve.py --llm --jobs $Jobs --adversarial --helper-scores sidecar\out\contested-scores.json --helper-threshold $HelperThreshold"
  Write-Output "  5 stage1   $py graph\learning\stage1_analyze.py"
  Write-Output "  5b packet  $py graph\learning\stage2_review.py --emit-packet   (writes the review packet; ingest and apply stay human)"
  Write-Output "  5c gold    $py graph\gold\seed_gold.py   (rebuilds gold from human and agent rulings only)"
  Write-Output "  5d score   $py graph\eval\score.py --context nightly   (ONLY when an input is newer than the last run)"
  Write-Output "  5e lint    $py graph\learning\lint_adjacency.py   (report: excludes word order and plurals defeat)"
  Write-Output "  5f family  $py graph\learning\local_triage.py --cluster-rejections --limit 600   (WEEKLY, needs 20 min with the model up)"
  Write-Output "  6 stop     llama-server down, verified"
  if ($refuse) { Write-Output "  REFUSED: $refuse" }
  exit 0
}

# ---------------------------------------------------------------- has this night already been done?
# THE OTHER HALF OF THE CATCH-UP (2026-09-09, queue 2026-09-09-d3e937). The task fires hourly from
# 21:30 to 05:30 so a night lost to a Windows Update reboot is picked up at the next sign-in; without
# this the same night would be re-run eight times, each holding 13 GB of card for nothing.
#
# IT MUST NOT REWRITE THE STAMP. graph-nightly-status.json is written by the chain's finally block and
# carries the real run's figures - contested count, elapsed, per-stage states - and it is what this
# guard READS. A skipped occurrence that rewrote it would erase the evidence it just consulted and,
# worse, would hand health-heartbeat a fresh stamp for a night that did no work: the exact false-green
# shape this item exists to close. So the skip records itself under its OWN log name and exits.
$skipWhy = ''
try {
  if (Test-Path $statusF) {
    $skipWhy = Test-AlreadyRanThisWindow -Now $started -WindowStart '21:30' `
                 -Status ([IO.File]::ReadAllText($statusF) | ConvertFrom-Json)
  }
} catch { $skipWhy = '' }   # an unreadable stamp is a reason to RUN, never a reason to skip
if ($skipWhy) {
  $skipLog = Start-RunLog -Name 'graph-nightly-skipped' -OutDir (Join-Path $grocery 'out')
  Log ("window: SKIPPED - " + $skipWhy)
  Stop-RunLog -ExitCode 0 -Path $skipLog
  exit 0
}

# ---------------------------------------------------------------- the run transcript starts HERE
# BELOW BOTH NON-RUN VERBS, DELIBERATELY - see the header comment beside the run-log dot-source.
# Start-RunLog appends 'logs' to OutDir itself, so this passes grocery\out and NOT grocery\out\logs -
# the latter would file the transcript under out\logs\logs and hide it from the one directory a human
# already opens.
$runLog = Start-RunLog -Name 'graph-nightly' -OutDir (Join-Path $grocery 'out')
Log ("nightly matching chain: now {0}, deadline {1} ({2} min), jobs {3}" -f `
     $started.ToString('HH:mm'), $deadline.ToString('yyyy-MM-dd HH:mm'), [int]($deadline - $started).TotalMinutes, $Jobs)

$stages = New-Object System.Collections.Generic.List[object]
function Record([string]$name, [string]$state, [string]$detail, [int]$sec) {
  $stages.Add([pscustomobject]@{ stage = $name; state = $state; detail = $detail; sec = $sec })
  Log ("{0}: {1}{2}" -f $name, $state, $(if ($detail) { " - $detail" } else { '' }))
}
function Remaining { return [int]([math]::Max(0, ($deadline - (Get-Date)).TotalSeconds)) }

$llamaStarted = $false
$contestedN = $null
try {
  if ($refuse) { Record 'window' 'REFUSED' $refuse 0; throw 'WINDOW' }
  if (-not $py) { Record 'python' 'BLIND' 'no interpreter for graph\ (see grocery\python-lib.ps1)' 0; throw 'WINDOW' }

  # -- 0. ASSERT THIS CHAIN'S INPUT (2026-09-09, backlog I45). Every stage below reads graph.db, and
  #       graph.db is written by the 08:00 daily capture chain's identity emission - a different
  #       scheduled task, on a different trigger, that can fail quietly. Without this line a nightly
  #       run against a graph that stopped updating three days ago produces verdicts that look
  #       exactly like healthy ones, which is the whole 08:30 shape the item is named for.
  #
  #       IT RECORDS AND CONTINUES; IT DOES NOT REFUSE, and that is deliberate. This script owns the
  #       GPU window and must reach its teardown, so an early exit here is the one failure mode worse
  #       than a stale input. 26 hours is the daily chain's own cadence plus an hour, the same window
  #       capture-watchdog uses on the capture status file.
  . (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'lib\input-assert.ps1')
  $iaRc = Assert-TcInputs -Stage 'graph-nightly' -Inputs @(
    @{ Path = (Join-Path (Split-Path $PSScriptRoot -Parent) 'sqlite\graph.db'); Producer = 'the 08:00 Daily Capture chain (compare-deals identity emission -> graph import)'; MaxAgeHours = 26.0 }
  )
  if ($iaRc -eq 0) { Record 'inputs' 'OK' 'graph.db is inside its 26h window' 0 }
  else { Record 'inputs' 'BLIND' 'graph.db is missing or stale - every verdict below is computed on an input nobody refreshed. NOT a failure and NOT a pass.' 0 }

  # -- 0b. VERDICT EXPIRY (WS 7b, design\PLAN-brain-v2-2026-09-09.md). BEFORE the emit, because the
  #        contested preview and the helper sweep must see tonight's re-ask questions too, or the helper
  #        never scores them. It writes graph\sqlite\verdict-reask.json, capped at MAX_REASKS_PER_NIGHT,
  #        and resolve.py ignores any list not written tonight - so a BLIND stage here re-asks NOTHING,
  #        rather than repeating yesterday's questions. No verdict can expire before 2026-11-19, so until
  #        then this stage writes an empty list and says when the first one will.
  $r = Invoke-Stage 'verdict-expiry' $py @('graph\learning\verdict_expiry.py', '--emit') 180
  $veSum = [string]($r.Tail | Where-Object { $_ -match '^VERDICT-EXPIRY-COMPLETE' } | Select-Object -Last 1)
  $veLand = @($r.Tail | Where-Object { $_ -match 'DID NOT FULLY LAND' }).Count
  if ($r.Ok) {
    $veDetail = ($veSum -replace '^VERDICT-EXPIRY-COMPLETE\s*', '')
    if ($veLand -gt 0) { $veDetail += " - LAST NIGHT'S RE-ASK DID NOT FULLY LAND" }
    Record 'verdict-expiry' 'OK' $veDetail $r.Elapsed
  }
  else { Record 'verdict-expiry' 'BLIND' ("rc=" + $r.ExitCode + ' - never fatal: no list tonight, so resolve re-asks nothing') $r.Elapsed }

  # -- 1. emit the contested set. Read-only; a failure here costs the sweep its contested lane and
  #       nothing else, so it is BLIND, not fatal.
  $contestedF = Join-Path $sidecar 'data\contested-pairs.json'
  $r = Invoke-Stage 'emit' $py @('graph\pipeline\resolve.py', '--emit-contested', $contestedF) 300
  if ($r.Ok) { Record 'emit' 'OK' (($r.Tail | Select-Object -Last 1)) $r.Elapsed }
  else { Record 'emit' 'BLIND' 'the sweep will skip its contested lane' $r.Elapsed }
  # How many questions the model half is actually for. Read from the file rather than scraped out of
  # the log, and recorded, because "contested = 0" is the steady state this whole plan aims at and
  # the scorecard cannot show it falling if nobody writes it down.
  try { $contestedN = [int]((Get-Content $contestedF -Raw | ConvertFrom-Json).contested) } catch { }
  if ($null -ne $contestedN) { Log ("contested questions for the model half: {0}" -f $contestedN) }

  # -- 1b. refresh the graph's own commodity definitions, for the CONTESTED lane only (phase 3).
  #        Read-only on the database (PRAGMA query_only), ~1 s, and BLIND rather than fatal: without
  #        it the sweep scores the contested set against the staple catalogue, which is what phase 2
  #        shipped and covers 15 of 435. The identity and coverage lanes never read this file, which
  #        is what makes this a zero-diff change to the daily alert.
  $gdefsF = Join-Path $sidecar 'data\commodity-defs-graph.json'
  $r = Invoke-Stage 'defs' $py @('graph\pipeline\emit_commodity_defs.py', '--out', $gdefsF) 300
  if ($r.Ok) { Record 'defs' 'OK' (($r.Tail | Select-Object -Last 1)) $r.Elapsed }
  else { Record 'defs' 'BLIND' 'the contested lane falls back to the staple catalogue (15 of 435)' $r.Elapsed }

  # -- 1c. the day's INGREDIENT IDENTITY events, filed into the graph (PLAN-ingredient-memory D4).
  #        CPU-only, read-mostly, ~2 s, and it runs HERE - after defs, before anything holds the
  #        card - for two reasons. It has no business inside the GPU window, which is the scarce
  #        thing this whole script exists to schedule; and it must not be in the `finally`, because
  #        teardown's one job is handing the card back and a teardown that does work is a teardown
  #        that can fail at it.
  #
  #        BLIND-NOT-FATAL, like every stage here. Exit 3 is the ingest's own could-not-evaluate
  #        (no event log at all - the map lane has never written one), which is a real outcome and
  #        not a failure of this chain. It PROMOTES NOTHING: everything it cannot settle goes into
  #        graph\learning\hunter-review-packet.json for a morning verb.
  if (-not $SkipHunterIngest) {
    $r = Invoke-Stage 'hunter' $py @('graph\learning\ingest_hunter_events.py') 300
    if ($r.Ok) { Record 'hunter' 'OK' (($r.Tail | Where-Object { $_ -match 'event' } | Select-Object -Last 1)) $r.Elapsed }
    elseif ($r.ExitCode -eq 3) { Record 'hunter' 'BLIND' (($r.Tail | Select-Object -Last 1)) $r.Elapsed }
    else { Record 'hunter' 'FAILED' ("rc=" + $r.ExitCode + ' ' + (($r.Tail | Select-Object -Last 1))) $r.Elapsed }
  } else { Record 'hunter' 'SKIPPED' '-SkipHunterIngest' 0 }

  # -- 1d. THE GRAPH'S CENTRAL CLAIM, CHECKED (2026-09-07, backlog I30 redirected). graphdb states
  #        that the tracked JSON is truth and graph.db is a rebuildable index, which is what makes the
  #        README's `rm graph.db` safe. Five tables are the exception - learning_proposals,
  #        approved_patches, eval_runs, cell_state, question_verdicts - and they stay mirrored by
  #        EIGHT HAND-PLACED export_learning() calls. rebuild.py --verify proves the convention held
  #        and had ZERO CALLERS until this line: not run-gates, not here, not CI.
  #
  #        FAILED, NOT BLIND, and it is the only stage in this chain that is. Every other one degrades
  #        a downstream result if it does not run; this one is the only thing standing between a
  #        forgotten export call and a month of silent drift, and a chain that shrugs at that is how
  #        the drift gets to be a month long. Exit 3 - no database, the normal state in a worktree -
  #        is still BLIND. Read-only, mode=ro, ~2 s: it cannot touch the WAL.
  $r = Invoke-Stage 'durability' $py @('graph\pipeline\audit_graph_durability.py') 300
  if ($r.Ok) { Record 'durability' 'OK' (($r.Tail | Select-Object -Last 1)) $r.Elapsed }
  elseif ($r.ExitCode -eq 3) { Record 'durability' 'BLIND' (($r.Tail | Select-Object -Last 1)) $r.Elapsed }
  else { Record 'durability' 'FAILED' ("rc=" + $r.ExitCode + ' ' + (($r.Tail | Where-Object { $_ -match 'FINDING|FAILED' } | Select-Object -First 1))) $r.Elapsed }

  # -- 2. the sweep. The chain must not OOM its own sidecar, so llama-server goes down FIRST even
  #       though this script has not started it yet: a leftover from a human session is exactly the
  #       case the ordering rule exists for.
  if (-not $SkipSweep) {
    if (Test-LlamaUp) { Log 'llama-server is up before the sweep (leftover session) - stopping it'; $null = Stop-Llama }
    $why = Test-SweepStartable -FreeMiB (Get-FreeVramMiB) -LlamaRunning (Test-LlamaUp)
    if ($why) {
      Record 'sweep' 'BLIND' $why 0
    } else {
      $budget = [math]::Min(1800, (Remaining))
      $swArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $grocery 'audit-semantic-identity.ps1'))
      if ($SidecarPython) { $swArgs += @('-Python', $SidecarPython) }
      $r = Invoke-Stage 'sweep' 'powershell' $swArgs $budget
      # rc 3 is the sidecar's own could-not-evaluate. It is a real outcome and it is not a failure
      # of this chain; recording it by name is how a BLIND day becomes visible instead of implied.
      if ($r.Ok) { Record 'sweep' 'OK' '' $r.Elapsed }
      elseif ($r.ExitCode -eq 3) { Record 'sweep' 'BLIND' (($r.Tail | Select-Object -Last 1)) $r.Elapsed }
      else { Record 'sweep' 'FAILED' ("rc=" + $r.ExitCode) $r.Elapsed }
    }
  } else { Record 'sweep' 'SKIPPED' '-SkipSweep' 0 }

  # -- 3. the card changes hands. This is the whole point of the script.
  if ((Remaining) -lt ($MinMinutes * 60)) { Record 'serve' 'SKIPPED' 'not enough of the window left after the sweep' 0; throw 'WINDOW' }
  $why = Test-LlamaStartable -FreeMiB (Get-FreeVramMiB) -SidecarRunning (Test-SidecarUp)
  if ($why) { Record 'serve' 'BLIND' $why 0; throw 'WINDOW' }
  $serveStart = Get-Date
  $r = Invoke-Stage 'serve' 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'tools\local-llm\serve.ps1'), '-Slots', $Jobs) 420
  $llamaStarted = Test-LlamaUp
  if (-not $r.Ok -or -not $llamaStarted) {
    # Ask Windows before shrugging. 'did not come up' is true of every cause and useful for none.
    $ciWhy  = Get-CiBlockDetail -Since $serveStart
    $detail = if ($ciWhy) { $ciWhy } else { 'llama-server did not come up; no model stages this run' }
    Record 'serve' 'BLIND' $detail $r.Elapsed
    throw 'WINDOW'
  }
  Record 'serve' 'OK' ("{0} slots" -f $Jobs) $r.Elapsed

  # -- 4. resolve. Bounded by what is left of the window, and safe to kill: resolve_pending
  #       checkpoints every batch and re-selects only rows still unsettled, so a killed run resumes.
  $budget = [math]::Max(60, (Remaining) - 240)   # leave 4 min for stage 1's tail and teardown
  # THE HELPER FILTER (plan section 2 step 2). The scores were written minutes ago by the sweep
  # above, by a TRAINED copy of the cross-encoder, on a card this process was not sharing with it.
  # A contested question the helper scores below the threshold is banked helper_rejected and never
  # reaches the model. REJECT-ONLY: v_current_rows admits include_hit and llm_confirmed only, so
  # nothing here can price a cell. resolve.py REFUSES a scores file the pinned model wrote, and
  # that refusal is fatal to the stage by design - a filter that quietly becomes no filter makes a
  # night's numbers unexplainable. Passed only when the file exists, so a BLIND sweep degrades to
  # the phase-2 behaviour of asking the model everything.
  $hsF = Join-Path $sidecar 'out\contested-scores.json'
  # §3.3, THE ADVERSARIAL SECOND PASS. Every local MATCH is re-asked with the instruction to
  # argue against it, and whether it SURVIVED rides to the review packet. Measured 2026-08-23
  # on 375 Claude-confirmed matches and 191 adjudicated-wrong ones: 88.5% of real matches
  # survive, 2.1% of false ones do - 86.4 points against a pre-registered bar of 30.
  # SIGNAL ONLY. 11.5% of real matches fail the challenge, so auto-rejecting on it would cost
  # one true cell in nine; the row's status is identical either way and nothing here can price
  # anything. It doubles the model calls on the MATCH slice - ~316 extra calls, ~7 minutes
  # against a 150-minute budget - and buys a packet ordered by which leads are worth reading.
  $rvArgs = @('graph\pipeline\resolve.py', '--llm', '--jobs', $Jobs, '--adversarial')
  if (Test-Path $hsF) { $rvArgs += @('--helper-scores', $hsF, '--helper-threshold', $HelperThreshold) }
  else { Log 'no contested-scores.json - the helper filter is off for this run' }
  $r = Invoke-Stage 'resolve' $py $rvArgs $budget
  if ($r.Ok) { Record 'resolve' 'OK' (($r.Tail | Where-Object { $_ -match 'resolved' } | Select-Object -Last 1)) $r.Elapsed }
  elseif ($r.TimedOut) { Record 'resolve' 'PARTIAL' 'stopped at the deadline; checkpointed verdicts stand and the next run resumes' $r.Elapsed }
  else { Record 'resolve' 'FAILED' ("rc=" + $r.ExitCode + ' ' + (($r.Tail | Select-Object -Last 1))) $r.Elapsed }

  # -- 5. Learning Stage 1, only if there is still window for it.
  if ($SkipStage1) { Record 'stage1' 'SKIPPED' '-SkipStage1' 0 }
  elseif ((Remaining) -lt 120) { Record 'stage1' 'SKIPPED' 'no window left' 0 }
  else {
    $r = Invoke-Stage 'stage1' $py @('graph\learning\stage1_analyze.py') ([math]::Max(60, (Remaining) - 60))
    if ($r.Ok) { Record 'stage1' 'OK' (($r.Tail | Select-Object -Last 1)) $r.Elapsed }
    elseif ($r.TimedOut) { Record 'stage1' 'PARTIAL' 'stopped at the deadline' $r.Elapsed }
    else { Record 'stage1' 'FAILED' ("rc=" + $r.ExitCode) $r.Elapsed }

  # -- 5b-5d. THE LOOP CONSUMES WHAT IT PRODUCES (WS 10c, design\PLAN-brain-v2-2026-09-09.md) -------
  # Measured 2026-09-10 by graph\learning\learning_status.py: Stage 1 ran here every night and nothing
  # downstream of it ran on any schedule. 60 proposals had waited since 2026-08-21, the review packet
  # was frozen at 2026-08-21T01:01, and the gold scoreboard's newest run was 2026-08-21 - 19.1 days
  # stale AGAINST ITS INPUTS. A learning loop that produces nightly and consumes never is a queue.
  #
  # ONLY THE MECHANICAL HALF IS SCHEDULED. --emit-packet only WRITES the review packet from the proposals
  # table; --ingest and --apply stay human, because a verdict is a judgement and an applied alias moves a
  # live board. seed_gold.py rebuilds gold ONLY from human and agent rulings (known-wrong, verified links,
  # the dupe allowlist, the escalation review) and never from a model's output, so "a model may not edit
  # the thing it is graded against" still holds. score.py runs DETERMINISTIC-ONLY and only when an input
  # is newer than the last run, so eval-runs.json grows when there is something new to measure and not
  # once a night regardless.
  #
  # EVERY ONE IS BLIND-NOT-FATAL, like every stage in this chain: a report stage that could take down the
  # nightly matching run is the worse trade, and a failure here costs a stale packet, not a board.
  if ((Remaining) -lt 120) { Record 'stage2-packet' 'SKIPPED' 'no window left' 0 }
  else {
    $r = Invoke-Stage 'stage2-packet' $py @('graph\learning\stage2_review.py', '--emit-packet') ([math]::Max(60, [math]::Min(300, (Remaining) - 60)))
    if ($r.Ok) { Record 'stage2-packet' 'OK' (($r.Tail | Select-Object -Last 1)) $r.Elapsed }
    elseif ($r.TimedOut) { Record 'stage2-packet' 'PARTIAL' 'stopped at the deadline' $r.Elapsed }
    else { Record 'stage2-packet' 'BLIND' ("rc=" + $r.ExitCode + ' - never fatal: the packet stays at its last version') $r.Elapsed }
  }

  if ((Remaining) -lt 120) { Record 'gold-seed' 'SKIPPED' 'no window left' 0 }
  else {
    $r = Invoke-Stage 'gold-seed' $py @('graph\gold\seed_gold.py') ([math]::Max(60, [math]::Min(300, (Remaining) - 60)))
    if ($r.Ok) { Record 'gold-seed' 'OK' (($r.Tail | Select-Object -Last 1)) $r.Elapsed }
    elseif ($r.TimedOut) { Record 'gold-seed' 'PARTIAL' 'stopped at the deadline' $r.Elapsed }
    else { Record 'gold-seed' 'BLIND' ("rc=" + $r.ExitCode + ' - never fatal: gold stays at its last build') $r.Elapsed }
  }

  # Is the scoreboard stale against its inputs? Asked of graph's own front door, through Invoke-Stage
  # rather than `& $py ... 2>$null`: under EAP=Stop a native child's stderr line is a terminating throw in
  # PS 5.1, which is the trap Invoke-Stage's own header records costing an audit.
  $stale = $null
  if ((Remaining) -ge 300) {
    $ls = Invoke-Stage 'learning-status' $py @('graph\learning\learning_status.py', '--json') 60
    if ($ls.Ok) {
      try { $stale = (($ls.Tail | Select-Object -Last 1) | ConvertFrom-Json).eval_days_stale_vs_inputs } catch { $stale = $null }
    }
  }
  if ((Remaining) -lt 300) { Record 'gold-score' 'SKIPPED' 'no window left' 0 }
  elseif ($null -eq $stale) { Record 'gold-score' 'BLIND' 'learning_status.py could not say whether the scoreboard is stale, so it is not re-scored blind' 0 }
  elseif ([double]$stale -le 0) { Record 'gold-score' 'SKIP' 'the scoreboard is newer than every input' 0 }
  else {
    $r = Invoke-Stage 'gold-score' $py @('graph\eval\score.py', '--context', 'nightly') ([math]::Max(120, [math]::Min(900, (Remaining) - 60)))
    if ($r.Ok) { Record 'gold-score' 'OK' ("re-scored, inputs were " + $stale + " day(s) newer; " + (($r.Tail | Where-Object { $_ -match 'false|missed|recall' } | Select-Object -Last 1))) $r.Elapsed }
    elseif ($r.TimedOut) { Record 'gold-score' 'PARTIAL' 'stopped at the deadline' $r.Elapsed }
    else { Record 'gold-score' 'BLIND' ("rc=" + $r.ExitCode + ' - never fatal') $r.Elapsed }
  }

  # -- 5e-5f. THE TWO GENERALISATION ENGINES THAT HAD NO CALLER (WS 8c, 2026-09-10) ------------------
  # graph\learning\lint_adjacency.py finds excludes that word order and plurals defeat - the class behind
  # four wrong prices in two days - and graph\learning\local_triage.py --cluster-rejections turns banked
  # model rejections into candidate category-exclude families. Both were built, both self-described as
  # the generalisation half of the loop, and neither had a single caller anywhere in the estate. Both are
  # REPORTS: they propose families and near-misses for a person, and change nothing on a board.
  if ((Remaining) -lt 120) { Record 'lint-adjacency' 'SKIPPED' 'no window left' 0 }
  else {
    $r = Invoke-Stage 'lint-adjacency' $py @('graph\learning\lint_adjacency.py') ([math]::Max(60, [math]::Min(600, (Remaining) - 60)))
    # The summary is printed LAST by the script for exactly this reason: Invoke-Stage keeps 14 lines.
    $lintSum = [string]($r.Tail | Where-Object { $_ -match '^LINT-ADJACENCY-SUMMARY' } | Select-Object -Last 1)
    if ($r.Ok) { Record 'lint-adjacency' 'OK' ($lintSum -replace '^LINT-ADJACENCY-SUMMARY\s*', '') $r.Elapsed }
    elseif ($r.TimedOut) { Record 'lint-adjacency' 'PARTIAL' 'stopped at the deadline' $r.Elapsed }
    else { Record 'lint-adjacency' 'BLIND' ("rc=" + $r.ExitCode + ' - never fatal') $r.Elapsed }
  }

  # WEEKLY, and only with 20 minutes of window left, because it spends model calls on the card this chain
  # already shares with the resolve lane - the same trade the ML suite below makes, for the same reason.
  # llama-server is up at this point (stage 3 started it; the finally block stops it), so an endpoint that
  # did not come up makes the script exit non-zero and the stage record BLIND rather than fail the chain.
  $famStamp = Join-Path $grocery 'out\logs\rejection-families-last.txt'
  $famDue = $true
  try {
    if (Test-Path $famStamp) {
      $famLast = [datetime]((Get-Content $famStamp -Raw -Encoding UTF8).Trim())
      $famDue = ((Get-Date) - $famLast).TotalDays -ge 7
    }
  } catch { $famDue = $true }
  if (-not $famDue) { Record 'rejection-families' 'SKIP' 'ran within the last 7 days' 0 }
  elseif ((Remaining) -lt 1200) { Record 'rejection-families' 'SKIPPED' 'needs 20 min of window with the model up' 0 }
  else {
    $famOut = Join-Path $grocery 'out\logs\rejection-families.json'
    $r = Invoke-Stage 'rejection-families' $py @('graph\learning\local_triage.py', '--cluster-rejections', '--limit', '600', '--jobs', "$Jobs", '--out', $famOut) ([math]::Max(300, [math]::Min(1800, (Remaining) - 120)))
    if ($r.Ok) {
      Record 'rejection-families' 'OK' (($r.Tail | Select-Object -Last 1)) $r.Elapsed
      try { (Get-Date).ToString('s') | Set-Content $famStamp -Encoding UTF8 } catch { }
    }
    elseif ($r.TimedOut) { Record 'rejection-families' 'PARTIAL' 'stopped at the deadline' $r.Elapsed }
    else { Record 'rejection-families' 'BLIND' ("rc=" + $r.ExitCode + ' - tracked, never fatal') $r.Elapsed }
  }

  # -- 6. THE ML REGRESSION SUITE, ON A SCHEDULE (2026-09-07, backlog I18) ---------------------------
  # Nothing ran hardeval, backtest or seed_sweep on any schedule; they ran when a human remembered.
  # A model regression suite needs a schedule rather than a commit trigger, because most of what moves
  # it is not a commit here: commodity_text() is "label plus up to five products the board currently
  # accepts", so every score moves when the BOARD moves - daily, automatically, nothing committed. The
  # estate measured that at AUC 0.9705 to 0.7921 on the same pinned model with only the defs changed.
  #
  # WEEKLY AND NON-FATAL. The suite wants the card and this chain already runs five stages inside a
  # hard deadline; a sixth every night would cost the resolve lane time for something that has to be
  # TRACKED rather than watched. A failure records BLIND and never breaks the chain - a regression
  # report that can take down the nightly matching run is the worse trade.
  #
  # FROZEN DEFS, DELIBERATELY. hardeval compares against a baseline, and backtest.py's own header
  # records what happens without them: the same model scored 17/25 one day and 24/24 another because
  # the BOARD changed. A weekly number measured against today's shelf would track the shelf.
  $evalStamp = Join-Path $grocery 'out\logs\ml-eval-last.txt'
  $evalDue = $true
  try {
    if (Test-Path $evalStamp) {
      $last = [datetime]((Get-Content $evalStamp -Raw -Encoding UTF8).Trim())
      $evalDue = ((Get-Date) - $last).TotalDays -ge 7
    }
  } catch { $evalDue = $true }
  if (-not $evalDue) {
    Record 'ml-eval' 'SKIP' 'ran within the last 7 days' 0
  } elseif (-not (Test-Path $sidecarPy)) {
    Record 'ml-eval' 'BLIND' 'no sidecar interpreter - the suite needs torch' 0
  } else {
    $frozen = Join-Path $sidecar 'data\frozen\phase3-baseline\commodity-defs.json'
    $evalArgs = @((Join-Path $sidecar 'hardeval.py'), '--stage', 'score')
    if (Test-Path $frozen) { $evalArgs += @('--defs', $frozen) }
    $r = Invoke-Stage 'ml-eval' $sidecarPy $evalArgs ([math]::Min(1800, (Remaining)))
    if ($r.Ok) {
      Record 'ml-eval' 'OK' (($r.Tail | Select-Object -Last 1)) $r.Elapsed
      try { (Get-Date).ToString('s') | Set-Content $evalStamp -Encoding UTF8 } catch { }
    }
    elseif ($r.TimedOut) { Record 'ml-eval' 'PARTIAL' 'stopped at the deadline' $r.Elapsed }
    else { Record 'ml-eval' 'BLIND' ("rc=" + $r.ExitCode + " - tracked, never fatal") $r.Elapsed }
  }
  }
}
catch {
  if ("$_" -notmatch 'WINDOW') { Record 'chain' 'FAILED' $_.Exception.Message 0 }
}
finally {
  # THE ONE THING THIS SCRIPT OWES THE MACHINE. Runs on success, on failure, on timeout, on Ctrl-C.
  $freed = Stop-Llama
  Record 'stop' $(if ($freed) { 'OK' } else { 'FAILED' }) $(if ($freed) { '' } else { 'llama-server still up - the next sweep will go BLIND' }) 0

  $status = [ordered]@{
    generated   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    started     = $started.ToString('yyyy-MM-ddTHH:mm:ss')
    deadline    = $deadline.ToString('yyyy-MM-ddTHH:mm:ss')
    hard_stop   = $HardStop
    jobs        = $Jobs
    contested   = $contestedN
    elapsed_sec = [int]((Get-Date) - $started).TotalSeconds
    card_free   = $freed
    free_vram_mib = (Get-FreeVramMiB)
    llama_started = $llamaStarted
    stages      = @($stages.ToArray())
  }
  $dir = Split-Path -Parent $statusF
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  ($status | ConvertTo-Json -Depth 5) | Set-Content -Path $statusF -Encoding UTF8
  Log ("wrote {0}" -f $statusF)
}

# The chain NEVER exits non-zero for a BLIND stage: nothing downstream depends on it, and a
# scheduled task that reports failure for "the GPU was busy" trains its owner to ignore it. The one
# thing worth an alarm is a card this script could not hand back.
if (-not $freed) { exit 3 }
# COMMIT WHAT THIS LANE OWNS (2026-09-07). Same reason as the harvest crawl: capture-run was the only
# committer, so a night's identity, learning and provenance state waited for the morning sweep. The
# provenance file in particular is an append-only record of what this chain decided, and an
# uncommitted one is invisible to anything that reads the newest COMMITTED artefact.
try {
  . (Join-Path $root 'lib\pipeline-commit.ps1')
  $msg = Invoke-PipelineCommit -Repo $root -Paths (Get-PipelinePaths -Kind graph) `
           -Message ("Graph nightly: identity, learning and provenance (" + (Get-Date).ToString('yyyy-MM-dd') + ") [graph]") `
           -Name 'graph-nightly' -Push
  Write-Output $msg
} catch { Write-Output ('graph-nightly: committer threw and was swallowed: ' + $_.Exception.Message) }

Done 0
