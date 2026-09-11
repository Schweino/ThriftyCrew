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
  # PROVEN BY THE CHILDREN, NOT TIMED BY THE CLOCK (2026-09-11). This was "six 600ms jobs in under 2.5s",
  # and it went red at 6.89s in a pre-push run-gates sharing the machine with at least three other
  # sessions' gates (337 gates, 792s against 106s quiet), blocking a push that touched neither file; solo
  # straight after it passed 3 of 3. A wall-clock bar measures the machine as well as the pool. Each job
  # now runs lib\concurrency-probe.ps1's rendezvous child, which waits until all six have started - a
  # serial loop can never satisfy that, and load only makes it slower.
  . (Join-Path $PSScriptRoot 'concurrency-probe.ps1')
  $rdv = New-TcRendezvousProbe -Count 6
  try {
    $par = Invoke-TcParallel -Jobs @(1..6 | ForEach-Object { [pscustomobject]@{ Exe = $PS; ArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $rdv.Script) } }) -Concurrency 6
    $rv = Get-TcRendezvousVerdict -Probe $rdv
    $rc0 = @($par | Where-Object { $_.ExitCode -eq 0 }).Count
    T 'CLEAN TWIN six jobs at concurrency 6 are all alive at the same instant, each having waited for the other five to start - the whole point, asserted rather than assumed, and never timed' `
      ($rv.Ok -and @($par).Count -eq 6 -and $rc0 -eq 6) ("{0}; {1} of 6 jobs exit 0" -f $rv.Detail, $rc0)
    Write-Output ('info  ' + $rv.Detail)   # the start-gap margin, visible on a green run and not only a red one
  } finally {
    Remove-TcRendezvousProbe -Probe $rdv
  }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 3 must-fire cases led by job-order results and exact exit codes, 3 must-not-fire cases led by concurrency 1 matching the pool, and 4 clean twins including proven overlap'
  exit 0
}
