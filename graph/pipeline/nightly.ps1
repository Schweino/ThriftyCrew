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
  [switch]$SkipStage1
)
$ErrorActionPreference = 'Stop'

$root     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # repo root
$graph    = Join-Path $root 'graph'
$grocery  = Join-Path $root 'grocery'
$sidecar  = Join-Path $root 'sidecar'
$statusF  = Join-Path $grocery 'out\logs\graph-nightly-status.json'

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

Log ("nightly matching chain: now {0}, deadline {1} ({2} min), jobs {3}" -f `
     $started.ToString('HH:mm'), $deadline.ToString('yyyy-MM-dd HH:mm'), [int]($deadline - $started).TotalMinutes, $Jobs)

if ($WhatIfOnly) {
  Log 'plan only:'
  Write-Output "  1 emit     $py graph\pipeline\resolve.py --emit-contested sidecar\data\contested-pairs.json"
  Write-Output "  1b defs    $py graph\pipeline\emit_commodity_defs.py --out sidecar\data\commodity-defs-graph.json"
  Write-Output "  2 sweep    grocery\audit-semantic-identity.ps1        (sidecar takes and releases the card)"
  Write-Output "  3 serve    tools\local-llm\serve.ps1 -Slots $Jobs"
  Write-Output "  4 resolve  $py graph\pipeline\resolve.py --llm --jobs $Jobs --helper-scores sidecar\out\contested-scores.json --helper-threshold $HelperThreshold"
  Write-Output "  5 stage1   $py graph\learning\stage1_analyze.py"
  Write-Output "  6 stop     llama-server down, verified"
  if ($refuse) { Write-Output "  REFUSED: $refuse" }
  exit 0
}

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
  $r = Invoke-Stage 'serve' 'powershell' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root 'tools\local-llm\serve.ps1'), '-Slots', $Jobs) 420
  $llamaStarted = Test-LlamaUp
  if (-not $r.Ok -or -not $llamaStarted) { Record 'serve' 'BLIND' 'llama-server did not come up; no model stages this run' $r.Elapsed; throw 'WINDOW' }
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
  $rvArgs = @('graph\pipeline\resolve.py', '--llm', '--jobs', $Jobs)
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
exit 0
