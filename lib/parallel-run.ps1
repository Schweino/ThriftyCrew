<#
  parallel-run.ps1 - Run N child processes with a bounded concurrency pool, results in JOB ORDER.

  Self-test:   powershell -File lib\parallel-run.ps1 -SelfTest

  WHY (2026-09-07, Brad: "our gates and full suite of tests take WAY too long ... this doesn't scale as
  we continue to grow"). run-gates spawns 269 fresh processes SERIALLY. Measured that day: 490s, of
  which ~51s is process startup alone, on a machine with 32 logical processors sitting idle. The gates
  are independent by construction - each is a separate process with its own exit code - so the serial
  loop is the whole cost and none of the safety.

  SEPARATE PROCESSES, NOT RUNSPACES, AND THAT IS A MEASURED RULING RATHER THAN A PREFERENCE. PS 5.1
  shares a static Regex cache behind a lock, so running regex-heavy work in parallel runspaces is
  SLOWER than serial. Only separate processes actually parallelise here, and gate code is almost
  entirely regex ([[ps5-static-regex-lock]]).

  THREE PROPERTIES THIS OWES ITS CALLER, all of which a naive pool loses:

    1. RESULTS IN JOB ORDER, never completion order. A gate suite whose output reshuffles run to run
       cannot be diffed, and the reader loses the ability to see what changed.
    2. THE EXIT CODE, EXACTLY. This estate runs three different exit-code vocabularies at once and the
       verdict logic reads the number ([[exit-code-first-tally-second]]). A pool that collapses exit
       codes to pass/fail destroys the distinction between "found something" and "could not run".
    3. STDOUT DRAINED WHILE THE CHILD RUNS. WaitForExit-then-read DEADLOCKS the moment a child fills
       the pipe buffer - about 4KB - and several gates here emit far more. The read starts before the
       wait, which is the entire reason this is a library and not four lines inline.

  STDERR IS DELIBERATELY NOT REDIRECTED, for parity with the `& powershell ...` calls this replaces:
  those let stderr through to the console, and capturing it here would change what a caller sees. It
  also sidesteps the estate's standing trap where merging a native exe's stderr fakes a failure at
  exit 0.

  NO param() BLOCK, for the reason lib\guard-contract.ps1 spells out: PS 5.1 runs a dot-sourced
  param() block in the CALLER's scope, so declaring [switch]$SelfTest here would reset the -SelfTest of
  every script that dot-sources this.
#>
$__prSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

function Format-TcProcArg {
  <# .NET Framework's ProcessStartInfo has no ArgumentList - only a single Arguments STRING - so every
     argument has to be quoted by hand. A path with a space in it silently becomes two arguments
     otherwise, and the gate it names is then reported as missing. #>
  param([string]$Value)
  if ($Value -match '[\s"]') { return '"' + ($Value -replace '"', '\"') + '"' }
  return $Value
}

function ConvertTo-TcOutputLines {
  <# Split captured stdout the way PowerShell splits a native command's output, so verdict logic that
     reads $out[-1] or $out.Count behaves identically to the `& exe` call this replaces. Exactly ONE
     trailing newline is dropped - PS keeps the empty line a "text`n`n" child produced. #>
  param([string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return ,@() }
  $t = $Text -replace "`r`n", "`n"
  if ($t.EndsWith("`n")) { $t = $t.Substring(0, $t.Length - 1) }
  if ($t.Length -eq 0) { return ,@('') }
  return ,($t -split "`n")
}

function Invoke-TcParallel {
  <# Jobs: objects carrying Exe and ArgList. Returns one result per job, IN JOB ORDER, each with
     Out (string[]), ExitCode (int), Ms (double) and TimedOut (bool).

     A TIMED-OUT JOB IS A HARD FAILURE, NOT A PASS. It comes back with the killed process's own exit
     code discarded and ExitCode 3 - could-not-evaluate - because a gate that hung proved nothing and
     must never be scored as silence. #>
  param(
    [object[]]$Jobs,
    [int]$Concurrency = 12,
    [int]$TimeoutSec = 900,
    [string]$WorkingDirectory = $null
  )
  $n = @($Jobs).Count
  $results = New-Object object[] $n
  if ($n -eq 0) { return ,$results }
  if ($Concurrency -lt 1) { $Concurrency = 1 }

  $running = [Collections.Generic.List[object]]::new()
  $next = 0
  while (($next -lt $n) -or ($running.Count -gt 0)) {
    while (($next -lt $n) -and ($running.Count -lt $Concurrency)) {
      $j = $Jobs[$next]
      $psi = New-Object Diagnostics.ProcessStartInfo
      $psi.FileName = [string]$j.Exe
      $psi.Arguments = (@($j.ArgList) | ForEach-Object { Format-TcProcArg ([string]$_) }) -join ' '
      $psi.UseShellExecute = $false
      $psi.RedirectStandardOutput = $true
      $psi.CreateNoWindow = $true
      if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
      $p = [Diagnostics.Process]::Start($psi)
      # THE READ STARTS BEFORE THE WAIT. Reversed, a child that fills the ~4KB pipe buffer blocks on
      # write while we block on exit, and neither ever moves.
      $running.Add([pscustomobject]@{
        Index = $next; Proc = $p; Task = $p.StandardOutput.ReadToEndAsync()
        Sw = [Diagnostics.Stopwatch]::StartNew()
      })
      $next++
    }

    $done = @($running | Where-Object { $_.Proc.HasExited -or ($_.Sw.Elapsed.TotalSeconds -gt $TimeoutSec) })
    foreach ($r in $done) {
      $timedOut = $false
      if (-not $r.Proc.HasExited) {
        $timedOut = $true
        try { $r.Proc.Kill() } catch { }
        try { [void]$r.Proc.WaitForExit(5000) } catch { }
      }
      $r.Sw.Stop()
      $text = ''
      try { $text = [string]$r.Task.Result } catch { $text = '' }
      $code = if ($timedOut) { 3 } else { [int]$r.Proc.ExitCode }
      $results[$r.Index] = [pscustomobject]@{
        Out = (ConvertTo-TcOutputLines $text); ExitCode = $code
        Ms = $r.Sw.Elapsed.TotalMilliseconds; TimedOut = $timedOut
      }
      try { $r.Proc.Dispose() } catch { }
      [void]$running.Remove($r)
    }
    if ($running.Count -ge $Concurrency -or ($next -ge $n -and $running.Count -gt 0)) {
      Start-Sleep -Milliseconds 15
    }
  }
  return ,$results
}

<# ---- CONCURRENCY PROBE ---------------------------------------------------------------------------------
  Proves a pool REALLY runs N jobs at once, without timing the jobs (2026-09-11).

  WHY NOT A STOPWATCH. This file's self-test asserted "six 600ms jobs at concurrency 6 finish in under
  2.5s", and grocery\fanout-lib.ps1 asserted "8 x 3s in under 12s wall". Both are claims about the
  MACHINE, not the pool: run-gates runs 337 gates at width 16 beside whatever sibling sessions are up, and
  on 2026-09-11 the first failed at 11.71s inside run-gates and 3.39s solo at 100% CPU, then blocked an
  unrelated push from the pre-push hook; the second failed at 14.9s. A correct pool on a saturated box does
  not get faster, so a wall-time bar is red exactly when the box is busy, which in run-gates is always.

  WHAT IT ASSERTS INSTEAD. Each job holds a named kernel token for its whole life (the OS drops it however
  the process exits) and polls how many of the N tokens exist. When one job sees all N it sets a quorum
  event the TEST holds, so the event outlives the jobs. N tokens alive at one instant is concurrency by
  definition, and load only delays that instant, it cannot prevent it. A SERIAL pool can never set it:
  job k starts after job k-1 has exited, so every job sees exactly one token - its own - whatever the load.

  THE ONE REMAINING BOUND IS LIVENESS, NOT SPEED. A job that has waited -WaitSec with no quorum gives up and
  sets an abandon event, so later jobs in a serial pool exit at once instead of each waiting again. It only
  decides how long a BROKEN pool takes to be reported; for a correct pool it would have to exceed the gap
  between the first and last of N children reaching their first line. The measurement behind the default
  is in the self-test comment where it is used.

  WHAT ELSE WAS TRIED, and why each was not taken. Every design below except the first was run beside the probe
  on 2026-09-11: 8 rounds at 18-100% CPU on 32 logical cores (4 of them at 100%), each round running every arm
  on the same jobs back to back, one row per round per arm, through a scratch harness at 7d75b0d90. The old
  2.5s bar passed 5 of 8; a serial/parallel ratio of at least 2 passed 7 of 8 (1.62 at 100%); job-stamped
  overlap passed 7 of 8 (4 of 6 overlapping at 100%); the quorum passed 8 of 8, and a serial pool failed it 8
  of 8. Through grocery\fanout-lib.ps1's pool the quorum also passed 8 of 8 and its width-1 twin failed 8 of 8.
    - RAISE THE LIMIT. Weakens the gate and only moves the load at which it goes red. Refused by rule.
    - A SERIAL BASELINE IN THE SAME RUN, ASSERTING A SPEEDUP RATIO. Still load-dependent: the two arms run
      seconds apart under a load that swings within the run, and on a saturated box six PowerShell start-ups
      contend for the same cores, so a correct pool's ratio sinks toward 1. It also doubles the fixture cost.
    - PER-JOB START/END TIMESTAMPS WRITTEN BY THE JOBS, ASSERTING OVERLAP. A child records its start only
      after PowerShell has initialised, and under load that start-up jitter exceeds a short job's duration,
      so the intervals stop overlapping. Making the job long enough to cover the jitter is a wall-time guess
      again. The quorum is this idea with the guess removed: each job WAITS for its siblings.
    - REPORT BLIND WHEN A CALIBRATION PROBE SAYS THE BOX IS SATURATED. The box is saturated on nearly every
      run-gates run, so the case would read BLIND on almost every push and a real serial regression would
      ship as a pass-with-a-note. It gives the coverage up exactly where the gate runs.
#>
function New-TcConcurrencyProbe {
  <# Writes the job script into -Dir (the caller owns and removes the directory) and creates the two events
     the TEST holds. Close it with Close-TcConcurrencyProbe. Jobs are launched with
     `powershell -NoProfile -ExecutionPolicy Bypass -File <Script> <Get-TcConcurrencyProbeArgs ...>`. #>
  param([Parameter(Mandatory)][int]$Count, [Parameter(Mandatory)][string]$Dir, [int]$WaitSec = 120)
  $run = [guid]::NewGuid().ToString('N')
  # Local\ is the session namespace, and the GUID keeps two run-gates in sibling worktrees - which run this
  # same self-test at the same moment - from counting each other's tokens.
  $prefix = 'Local\tc-probe-' + $run
  $child = @'
param([string]$Prefix, [int]$Index, [int]$Count, [int]$WaitSec)
$token = New-Object Threading.Mutex($false, ($Prefix + '-live-' + $Index))
$initMs = [int]((Get-Date) - (Get-Process -Id $PID).StartTime).TotalMilliseconds
$quorum = $null; $abandon = $null
$okQ = [Threading.EventWaitHandle]::TryOpenExisting(($Prefix + '-quorum'), [ref]$quorum)
$okA = [Threading.EventWaitHandle]::TryOpenExisting(($Prefix + '-abandon'), [ref]$abandon)
if (-not ($okQ -and $okA)) {
  Write-Output ('PROBE index={0} quorum=nohandles max_live=0 init_ms={1} waited_ms=0' -f $Index, $initMs); exit 3
}
$max = 0; $how = 'missed'; $sw = [Diagnostics.Stopwatch]::StartNew()
while ($true) {
  $live = 0
  for ($i = 1; $i -le $Count; $i++) {
    $h = $null
    if ([Threading.Mutex]::TryOpenExisting(($Prefix + '-live-' + $i), [ref]$h)) { $live++; $h.Dispose() }
  }
  if ($live -gt $max) { $max = $live }
  if ($live -ge $Count) { [void]$quorum.Set() }
  if ($quorum.WaitOne(0)) { $how = 'reached'; break }
  if ($abandon.WaitOne(0)) { $how = 'abandoned'; break }
  if ($sw.Elapsed.TotalSeconds -ge $WaitSec) { [void]$abandon.Set(); $how = 'timedout'; break }
  Start-Sleep -Milliseconds 20
}
Write-Output ('PROBE index={0} quorum={1} max_live={2} init_ms={3} waited_ms={4}' -f $Index, $how, $max, $initMs, [int]$sw.Elapsed.TotalMilliseconds)
$token.Dispose()
exit 0
'@
  $script = Join-Path $Dir ('concurrency-probe-' + $run.Substring(0, 8) + '.ps1')
  [IO.File]::WriteAllText($script, $child, (New-Object Text.UTF8Encoding($false)))
  $manual = [Threading.EventResetMode]::ManualReset
  return [pscustomobject]@{
    Prefix = $prefix; Count = $Count; WaitSec = $WaitSec; Script = $script
    Quorum = (New-Object Threading.EventWaitHandle($false, $manual, ($prefix + '-quorum')))
    Abandon = (New-Object Threading.EventWaitHandle($false, $manual, ($prefix + '-abandon')))
  }
}

function Get-TcConcurrencyProbeArgs {
  <# The arguments for job -Index, 1-based. Every index 1..Count must be launched exactly once. #>
  param([Parameter(Mandatory)]$Probe, [Parameter(Mandatory)][int]$Index)
  return @('-Prefix', $Probe.Prefix, '-Index', [string]$Index, '-Count', [string]$Probe.Count, '-WaitSec', [string]$Probe.WaitSec)
}

function Test-TcConcurrencyProbe {
  <# The verdict. -Lines is every stdout line the jobs produced, flattened. Reached is true only when the
     test's own quorum event was set AND every index 1..Count reported quorum=reached - so a job that never
     ran, crashed or printed nothing cannot be scored as having been in flight. MaxLive is the most tokens
     any one job saw at once: exactly 1 is the signature of a serial pool. #>
  param([Parameter(Mandatory)]$Probe, [AllowEmptyCollection()][object[]]$Lines)
  $seen = @{}; $maxLive = 0; $maxWait = 0
  foreach ($l in @($Lines)) {
    if ("$l" -match '^PROBE index=(\d+) quorum=(\w+) max_live=(\d+) init_ms=(-?\d+) waited_ms=(\d+)') {
      $seen[[int]$Matches[1]] = $Matches[2]
      if ([int]$Matches[3] -gt $maxLive) { $maxLive = [int]$Matches[3] }
      if ([int]$Matches[5] -gt $maxWait) { $maxWait = [int]$Matches[5] }
    }
  }
  $event = $Probe.Quorum.WaitOne(0)
  $reachedJobs = 0
  for ($i = 1; $i -le $Probe.Count; $i++) { if ($seen[$i] -eq 'reached') { $reachedJobs++ } }
  $states = (@($seen.Keys | Sort-Object | ForEach-Object { "$_=" + $seen[$_] }) -join ' ')
  return [pscustomobject]@{
    Reached = ($event -and $reachedJobs -eq $Probe.Count)
    MaxLive = $maxLive
    Detail = ("quorum_event={0} reached {1} of {2} job(s), max_live={3}, longest wait {4}ms, abandon={5} [{6}]" -f `
      $event, $reachedJobs, $Probe.Count, $maxLive, $maxWait, $Probe.Abandon.WaitOne(0), $states)
  }
}

function Close-TcConcurrencyProbe {
  param($Probe)
  if ($Probe) { try { $Probe.Quorum.Dispose() } catch { }; try { $Probe.Abandon.Dispose() } catch { } }
}

if ($__prSelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }
  $PS = (Get-Command powershell).Source
  function MkJob($cmd) { [pscustomobject]@{ Exe = $PS; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) } }

  # MUST FIRE - the three properties a naive pool loses.
  $slowFirst = @(
    (MkJob 'Start-Sleep -Milliseconds 700; Write-Output "first"'),
    (MkJob 'Write-Output "second"')
  )
  $r = Invoke-TcParallel -Jobs $slowFirst -Concurrency 4
  T 'MUST FIRE  THE ONE THIS EXISTS FOR - results come back in JOB order even though job 2 finished long before job 1, or a gate suite reshuffles every run and its output can never be diffed' `
    (($r[0].Out[0] -eq 'first') -and ($r[1].Out[0] -eq 'second')) (($r | ForEach-Object { $_.Out[0] }) -join ',')
  $codes = Invoke-TcParallel -Jobs @((MkJob 'exit 0'), (MkJob 'exit 1'), (MkJob 'exit 2'), (MkJob 'exit 3')) -Concurrency 4
  T 'MUST FIRE  every exit code survives EXACTLY - three vocabularies are live in this estate at once and the verdict logic reads the number, so collapsing 2 and 3 to "failed" destroys "found something" versus "could not run"' `
    ((($codes | ForEach-Object { $_.ExitCode }) -join ',') -eq '0,1,2,3') (($codes | ForEach-Object { $_.ExitCode }) -join ',')
  $big = Invoke-TcParallel -Jobs @((MkJob '1..4000 | ForEach-Object { "line $_ padded out to make this exceed the pipe buffer" }')) -Concurrency 2
  T 'MUST FIRE  a child emitting far more than the ~4KB pipe buffer neither deadlocks nor truncates - reading after WaitForExit is the classic hang this library exists to prevent' `
    ($big[0].Out.Count -eq 4000 -and $big[0].Out[3999] -match 'line 4000') ([string]$big[0].Out.Count)

  # MUST NOT FIRE - the legal inputs.
  $ser = Invoke-TcParallel -Jobs $slowFirst -Concurrency 1
  T 'MUST NOT FIRE  concurrency 1 gives the same answers as the pool, so -Serial stays a real fallback rather than a different code path' `
    (($ser[0].Out[0] -eq 'first') -and ($ser[1].Out[0] -eq 'second')) (($ser | ForEach-Object { $_.Out[0] }) -join ',')
  $none = Invoke-TcParallel -Jobs @() -Concurrency 4
  T 'MUST NOT FIRE  an empty job list returns empty and does not hang' (@($none).Count -eq 0) ([string]@($none).Count)
  $quiet = Invoke-TcParallel -Jobs @((MkJob 'exit 0')) -Concurrency 2
  T 'MUST NOT FIRE  a job that prints nothing yields an EMPTY array, not $null - a verdict that pipes $null counts 1 in PS 5.1 and would score a silent gate as having spoken' `
    ($null -ne $quiet[0].Out -and $quiet[0].Out.Count -eq 0) ([string]$quiet[0].Out.Count)

  # CLEAN TWIN - adjacent behaviour that still works.
  T 'CLEAN TWIN line splitting matches what `& exe` produces - exactly one trailing newline dropped, so verdict logic reading $out[-1] behaves identically' `
    (((ConvertTo-TcOutputLines "a`r`nb`r`n").Count -eq 2) -and ((ConvertTo-TcOutputLines "a`nb`n`n").Count -eq 3)) `
    ([string](ConvertTo-TcOutputLines "a`nb`n`n").Count)
  T 'CLEAN TWIN an argument containing a space stays ONE argument - .NET Framework has no ArgumentList, so an unquoted path would silently name a different file' `
    ((Format-TcProcArg 'C:\Program Files\x.ps1') -eq '"C:\Program Files\x.ps1"') (Format-TcProcArg 'C:\Program Files\x.ps1')
  T 'CLEAN TWIN an ordinary argument is NOT quoted, so nothing downstream sees quotes it did not have' `
    ((Format-TcProcArg '-SelfTest') -eq '-SelfTest') (Format-TcProcArg '-SelfTest')
  # THE WHOLE POINT - THE POOL REALLY RUNS ITS JOBS AT ONCE - ASSERTED ON OVERLAP, NOT ON A STOPWATCH
  # (2026-09-11). This was "six 600ms jobs finish in under 2.5s", which is a claim about the machine: it
  # failed at 11.71s inside run-gates, at 3.39s solo on a 100%-CPU box, and blocked an unrelated push from
  # the pre-push hook. The CONCURRENCY PROBE header above has the mechanism and what else was tried.
  # WaitSec 120 IS A LIVENESS BOUND, NOT A SPEED BAR: it only has to exceed the gap between the first and
  # last of six children reaching their first line. Measured 2026-09-11 over 8 rounds at 18-100% CPU through
  # a scratch harness at 7d75b0d90: the longest any child here waited for its siblings was 1,486 ms, against a
  # PowerShell start-up of up to 3,606 ms; one earlier single round at 100% saw 3,503 ms and 4,906 ms. Through
  # fanout-lib's runspace pool the longest was 6,662 ms. 60 was the first value, and it was raised to 120 on
  # that fanout figure rather than swept, because the bound is FREE for a correct pool - quorum releases every
  # job the moment it forms - and a broken pool pays it once, since the first job to give up tells the rest.
  $probeDir = Join-Path ([IO.Path]::GetTempPath()) ('parallel-run-probe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
  try {
    function Invoke-ProbeAt([int]$Count, [int]$Width, [int]$WaitSec) {
      $p = New-TcConcurrencyProbe -Count $Count -Dir $probeDir -WaitSec $WaitSec
      try {
        $jobs = @(1..$Count | ForEach-Object {
          [pscustomobject]@{ Exe = $PS; ArgList = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $p.Script) + (Get-TcConcurrencyProbeArgs -Probe $p -Index $_)) }
        })
        $res = Invoke-TcParallel -Jobs $jobs -Concurrency $Width
        $lines = @(); $allButLast = @()
        foreach ($x in $res) { $lines += @($x.Out) }
        foreach ($x in @($res)[0..($Count - 2)]) { $allButLast += @($x.Out) }
        $v = Test-TcConcurrencyProbe -Probe $p -Lines $lines
        $vShort = Test-TcConcurrencyProbe -Probe $p -Lines $allButLast
        return [pscustomobject]@{ Reached = $v.Reached; MaxLive = $v.MaxLive; Detail = $v.Detail; Jobs = @($res).Count; ReachedMissingOne = $vShort.Reached }
      } finally { Close-TcConcurrencyProbe $p }
    }
    $conc = Invoke-ProbeAt -Count 6 -Width 6 -WaitSec 120
    T 'CLEAN TWIN six jobs at concurrency 6 are all IN FLIGHT AT ONCE - witnessed by the jobs themselves, so a loaded box can delay the proof but cannot fail it' `
      ($conc.Reached -and $conc.MaxLive -eq 6 -and $conc.Jobs -eq 6) $conc.Detail
    T 'MUST FIRE  a job that printed no probe line is NOT counted as in flight - the quorum event alone is not the verdict, or a job that crashed would score as concurrent' `
      ($conc.Reached -and -not $conc.ReachedMissingOne) ("reached=" + $conc.Reached + " reached_without_job_6=" + $conc.ReachedMissingOne)
    # WaitSec does not decide this verdict: in a serial pool job k starts after job k-1 has EXITED, so no
    # job can ever see a token but its own. 2s only keeps the case cheap.
    $serial = Invoke-ProbeAt -Count 3 -Width 1 -WaitSec 2
    T 'MUST FIRE  THE BUG THE CLEAN TWIN EXISTS FOR - the same probe calls a SERIAL pool serial: at concurrency 1 every job sees only its own token and no quorum forms' `
      ((-not $serial.Reached) -and $serial.MaxLive -eq 1 -and $serial.Jobs -eq 3) $serial.Detail
  } finally { Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 5 must-fire cases led by job-order results, exact exit codes and a serial pool failing the concurrency probe, 3 must-not-fire cases led by concurrency 1 matching the pool, and 4 clean twins including all six jobs witnessed in flight at once'
  exit 0
}
