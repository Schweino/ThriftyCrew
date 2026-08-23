<#
  fanout-lib.ps1 - ONE copy of "run these independent children side by side, and prove every
  one of them ran."

  WHY THIS EXISTS, AND WHY IT IS NOT THE 2026-08-22 EXPERIMENT AGAIN. On 2026-08-22 four
  advisory audits were launched side by side in check-ad-cycles.ps1 and the change was
  reverted the same morning on a measurement: serial 30.9 min vs parallel 41.7 min, with
  match-soundness going 111 s -> 904 s and the CPU sitting at 14%. That measurement is not
  evidence, and the reason is in the commit timestamps:

      08-22 07:24  31f4835b  audits run side by side - through Invoke-Bounded, which at that
                             moment launched every child with Start-Job
      08-22 10:09  9825bb80  parallel REVERTED on the 30.9-vs-41.7 measurement
      08-22 11:14  9a23e342  Invoke-Bounded itself is measured at 3.8 MINUTES per call for a
                             1-second script, because a PS 5.1 job is a whole child
                             PowerShell plus runspace construction plus session-state
                             serialisation - and is rewritten to Start-Process

  The parallel verdict was recorded ONE HOUR BEFORE the machinery it was measured through was
  proven to cost minutes per call, and was never re-measured after the fix. So the old comment
  in check-ad-cycles.ps1 has been corrected rather than obeyed. What the 08-22 run DOES leave
  standing is an untested hypothesis - that these audits contend on I/O and memory (each
  re-parsing ~40 MB of JSON) rather than on CPU - which is why -Sequential exists and why the
  caller logs its own wall time both ways. Measure before believing either story.

  THE RULES THIS FILE ENFORCES, each one a way a fan-out turns a watcher into a blind watcher:

  1. EVERY CHILD'S COMPLETION IS POSITIVELY ACCOUNTED FOR. Collecting "no error" from N lanes
     does not prove N lanes ran. Each lane returns a record; the collector asserts the record
     count equals the launch count, and a lane that returns nothing becomes a BLIND record with
     rc = -1 - never silence. A missing lane must read as "we did not check", never as "clean".

  2. RECORDS COME BACK IN LAUNCH ORDER, NEVER FINISH ORDER. The daily summary is diffed by eye;
     a block that reshuffles every run cannot be read. Lanes are launched in list order and the
     results are returned in list order regardless of who finished first.

  3. A LANE NEVER LOGS AND NEVER ALERTS. It returns LogLines; the caller emits them, in launch
     order, after the join. Two reasons, both load-bearing:
       - check-ad-cycles' Log is Add-Content on ONE file with a retry-then-sidecar fallback.
         Eight lanes contending on it would push some lines into ad-cycle-log.LOCKED-<day>.txt
         and scatter a single run across two files - the shape that made three runs look dead
         on 08-21/22.
       - Send-Alert's once-per-type-per-day gate is a read-then-append on alert-sent-<day>.txt,
         a check-then-act race. (Hardened with a named mutex on 2026-08-23 for the children
         that alert on their own behalf, but a lane still must not page from inside the pool.)

  4. RUNSPACES HOLD CHILD PROCESSES; THEY DO NOT DO THE WORK. Measured 2026-08-23 while
     building efe803f5: an in-process runspace pool over PowerShell regex scales NEGATIVELY -
     8.9 s CPU at 1 runspace to 215.5 s at 16, wall flat - because -match/-replace call the
     STATIC Regex methods and .NET Framework routes every one through a single process-wide
     pattern cache behind one lock. Every lane here launches a real OS process and then WAITS,
     so the runspace is doing nothing but holding a handle. That is the shape a pool is for.
     If you are ever tempted to move a lane's actual work onto the runspace to "save a
     process", re-read that measurement first.

  5. THE EAP=Stop RULE HOLDS INSIDE EVERY RUNSPACE. A native child's stderr under
     $ErrorActionPreference = 'Stop' is a terminating error, and 2>$null CAUSES it rather than
     preventing it (native-lib.ps1 has the whole account). Nothing here redirects with 2>&1 or
     2>$null: stdout and stderr are captured BY FILE through Start-Process, exactly as
     Invoke-Bounded does, which routes around the ErrorRecord machinery entirely.

  6. A LANE'S FAILURE IS A RECORD, NOT AN EXCEPTION. Nothing a lane does may throw out of the
     pool. A launch failure, a timeout and a crash all come back as records with rc = 3 or -1
     and a reason, because the 2026-08-23 downstream rc=1 was ONE unguarded gate ending a whole
     chain two thirds of the way through.

  Exit-code contract, unchanged from Invoke-Bounded so consumers need no new branches:
      0..2  the child's own code       3  could-not-evaluate (timeout, launch failure) = BLIND
        -1  the lane itself broke (no record came back, or the pool threw) = BLIND
#>

function New-FanoutLane {
  <#
    One lane. Name must be unique within a call - it is how the caller fetches the record.

    Marker is optional and is the strongest check available: a regex the child's output must
    contain to count as having run to the end. A lane that exits 0 without its marker did NOT
    finish, and saying so is the entire guard-contract lesson (lib\guard-contract.ps1).

    32 OF THE 34 INSPECT LANES DECLARE ONE. An earlier note here said none of them could,
    because the markers PLAN-use-the-cores named did not exist in the tree. That note was wrong
    and the mistake is worth keeping: the check behind it grepped for a literal '<NAME>-COMPLETE'
    string and so missed every script that emits its marker through the helper, which is most of
    them. audit-store-registry.ps1 does print STORE-REGISTRY-COMPLETE - via
    Write-GuardComplete -Name 'store-registry'. Grepping for one of two legal spellings and
    concluding the thing does not exist is the same shape as the backspace-in-the-regex scanner
    that reported green for a day while watching nothing.

    The two lanes without a marker are discover-hyvee and scaler-pricing; neither emits one, so
    neither declares one. Every other lane's marker was confirmed to actually appear on a live
    run before it was demanded - a marker a script does not print turns a working audit into a
    BLIND line every morning, which is the false-alarm mirror of the failure this file guards.

    Due=$false means the caller's cadence gate said skip. The lane is not launched and its
    record comes back with Skipped=$true - which is NOT a pass, and the caller must log it as
    a skip with the last-run date exactly as it does today.
  #>
  param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$File,
    [string[]]$Arguments = @(),
    [int]$TimeoutSec = 600,
    [string]$Marker = '',
    [bool]$Due = $true
  )
  # NULLS STRIPPED, AND THIS WAS A LIVE BUG NOT A PRECAUTION (2026-08-23). check-ad-cycles built one
  # lane as `-Arguments $(if (-not $NoAlert) { @('-Alert') } else { @() })`. In PowerShell a $( )
  # that yields an EMPTY collection collapses to $null, [string[]]$Arguments happily binds $null,
  # and @($null) is an array holding ONE NULL - so Start-Process refused the entire ArgumentList and
  # the lane never launched. It reported BLIND, correctly, on every -NoAlert run: which is exactly
  # what the GitHub Actions daily backup uses, so the store-registry audit would have been dead on
  # precisely the days Brad's machine was off. Caught by demanding completion markers, not by review.
  # The call site is fixed too; this makes the shape unrepresentable rather than merely fixed once.
  $argv = @(@($Arguments) | Where-Object { $null -ne $_ })
  return [pscustomobject]@{
    Name       = $Name
    File       = $File
    Arguments  = $argv
    TimeoutSec = $TimeoutSec
    Marker     = $Marker
    Due        = $Due
  }
}

# THE LANE BODY. Self-contained on purpose: a runspace does NOT inherit the caller's
# dot-sourced functions, so anything this needs it defines. It is a faithful copy of
# Invoke-Bounded's contract (Start-Process, real exit code, WaitForExit budget, whole process
# tree killed on expiry, rc 3 for could-not-evaluate) with the Log calls replaced by returned
# LogLines - because rule 3 says a lane does not touch the log file.
$script:FanoutLaneBody = {
  param([string]$Name, [string]$File, [string[]]$Arguments, [int]$TimeoutSec, [string]$Marker, [int]$Index)

  # Inside a runspace nothing has set this, and an unguarded default could turn a stray
  # non-terminating error into a lane that vanishes. Continue is the only safe value here;
  # every outcome below is reported through the record instead.
  $ErrorActionPreference = 'Continue'

  function Stop-FanoutTree([int]$procId) {
    foreach ($c in @(Get-CimInstance Win32_Process -Filter ("ParentProcessId = " + $procId) -ErrorAction SilentlyContinue)) {
      Stop-FanoutTree ([int]$c.ProcessId)
    }
    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
  }

  $logs = New-Object System.Collections.ArrayList

  # A MISSING SCRIPT MUST READ AS BLIND, NOT AS CLEAN - and this was caught by this file's own
  # fixture rather than reasoned about. `powershell -File does-not-exist.ps1` does not fail to
  # LAUNCH: it starts, prints its banner and the -File complaint on stderr, and exits
  # -196608 (0xFFFD0000). With no marker declared, that lane came back rc<0, no findings, and
  # Blind=$false - a check that no longer exists reporting a clean board, which is the precise
  # failure class the whole roster exists against. Refuse before launching, and say why.
  if (-not (Test-Path -LiteralPath $File)) {
    [void]$logs.Add(($Name + ' BLIND: its script is missing (' + $File + ') - that check did not run this cycle'))
    return [pscustomobject]@{
      Name = $Name; Index = $Index; ExitCode = 3
      Output = @($Name + ' BLIND: script not found at ' + $File + ' - nothing proven')
      StdOut = @(); StdErr = @()
      TimedOut = $false; Elapsed = 0; Blind = $true
      BlindReason = ('its script is missing (' + $File + ') - that check did not run this cycle')
      Skipped = $false; Launched = $false; LogLines = @($logs.ToArray())
    }
  }

  $so = [IO.Path]::GetTempFileName(); $se = [IO.Path]::GetTempFileName()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $File) + @($Arguments)
  $p = $null
  try {
    $p = Start-Process -FilePath 'powershell' -ArgumentList $argv -PassThru -NoNewWindow `
                       -RedirectStandardOutput $so -RedirectStandardError $se
    $null = $p.Handle   # PS 5.1: without touching Handle first, ExitCode reads $null after the exit
  } catch {
    $sw.Stop()
    Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
    [void]$logs.Add(($Name + ' could not be launched: ' + $_.Exception.Message))
    return [pscustomobject]@{
      Name = $Name; Index = $Index; ExitCode = 3; Output = @($Name + ' could not be launched - BLIND, nothing proven')
      StdOut = @(); StdErr = @()
      TimedOut = $false; Elapsed = 0; Blind = $true
      BlindReason = ('could not be launched: ' + $_.Exception.Message)
      Skipped = $false; Launched = $true; LogLines = @($logs.ToArray())
    }
  }

  $done = $p.WaitForExit($TimeoutSec * 1000)
  $sw.Stop(); $elapsed = [int]$sw.Elapsed.TotalSeconds
  if (-not $done) {
    try { Stop-FanoutTree ([int]$p.Id) } catch { }
    try { $null = $p.WaitForExit(5000) } catch { }
    Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
    [void]$logs.Add(("TIMED OUT: $Name exceeded its $TimeoutSec s budget and was stopped - reported as BLIND (could-not-evaluate); the board still ships"))
    return [pscustomobject]@{
      Name = $Name; Index = $Index; ExitCode = 3; Output = @("$Name TIMED OUT after $TimeoutSec s - BLIND, nothing proven")
      StdOut = @(); StdErr = @()
      TimedOut = $true; Elapsed = $elapsed; Blind = $true
      BlindReason = ("timed out after $TimeoutSec s")
      Skipped = $false; Launched = $true; LogLines = @($logs.ToArray())
    }
  }

  # STDOUT AND STDERR ARE KEPT APART AS WELL AS TOGETHER. Output stays merged because every existing
  # consumer reads it that way (Invoke-Bounded's contract, unchanged), but the marker check below can
  # only be asked of STDOUT: this appends stderr AFTER stdout, so on any child that writes a single
  # warning line the marker stops being last and a correct guard would be called BLIND.
  $stdout = @(); $stderr = @()
  try { $stdout = @(Get-Content $so -ErrorAction SilentlyContinue) } catch { }
  try { $stderr = @(Get-Content $se -ErrorAction SilentlyContinue) } catch { }
  Remove-Item $so, $se -Force -ErrorAction SilentlyContinue
  $rc = try { [int]$p.ExitCode } catch { 3 }
  $stdout = @($stdout | ForEach-Object { [string]$_ })
  $stderr = @($stderr | ForEach-Object { [string]$_ })
  $out = @($stdout + $stderr)

  # THE MARKER IS THE ONLY THING THAT PROVES THE END WAS REACHED. An exit code says the process
  # stopped, not that the check finished - test-auditors once threw 242 checks early, printed
  # 176 lines of PASS and exited 1. If a lane declares a marker and stdout does not END with it,
  # the lane is BLIND no matter what it exited with.
  #
  # LAST NON-EMPTY LINE, NOT "SOMEWHERE IN THE OUTPUT" (tightened 2026-08-23). The first version of
  # this matched the marker anywhere, which is strictly weaker than the estate's own contract:
  # lib\guard-contract.ps1's Test-GuardComplete requires it to be the LAST non-empty line, because
  # "a guard that printed it and then kept going (and died) has not finished either". A weaker copy
  # of a contract is worse than no copy - it looks like the rule is enforced. Same predicate here.
  $blind = $false; $why = ''
  if ($Marker) {
    $lines = @($stdout | Where-Object { $_.Trim() -ne '' })
    $ends = ($lines.Count -gt 0) -and ($lines[-1].Trim() -match $Marker)
    if (-not $ends) {
      $blind = $true
      $seen = if (($stdout -join "`n") -match $Marker) { ' (it appears earlier in the output, but the run did not END there - it kept going and stopped somewhere else)' } else { '' }
      $why = ("exited $rc without its completion marker (" + $Marker + ") as the last line" + $seen + " - it did not run to the end, so its verdict proves nothing")
    }
  }
  # The exit-code reasons are checked independently of the marker rather than chained onto it: a lane
  # can be blind for more than one reason at once, and the first one found is a fine thing to report,
  # but "already blind" must never stop a later check from running.
  if (-not $blind -and $rc -eq 3) {
    $blind = $true; $why = 'the child reported could-not-evaluate (rc=3)'
  }
  if (-not $blind -and $rc -lt 0) {
    # A NEGATIVE CODE IS NOT ONE OF THE CHILD'S. The estate's scripts exit 0..3; anything below
    # zero came from the host refusing to run one (a bad -File, a fatal CLR exit), so it says
    # nothing about the check and must not be read as a verdict.
    $blind = $true
    $why = ("exited $rc - the host refused to run it, so this is not a verdict: " + ((@($out) | Select-Object -Last 1) -join ' '))
  }
  if ($elapsed -ge 30) { [void]$logs.Add(("{0}: {1} s (rc={2})" -f $Name, $elapsed, $rc)) }

  return [pscustomobject]@{
    Name = $Name; Index = $Index; ExitCode = $rc; Output = $out
    # StdOut separately, because the marker contract is about STDOUT and Output has stderr appended
    # to it. A consumer that wants to re-check completion itself must be able to ask the same
    # question this lane asked, not a merged approximation of it.
    StdOut = $stdout; StdErr = $stderr
    TimedOut = $false; Elapsed = $elapsed; Blind = $blind; BlindReason = $why
    Skipped = $false; Launched = $true; LogLines = @($logs.ToArray())
  }
}

function Invoke-Fanout {
  <#
    Runs every DUE lane concurrently and returns one record per lane IN LAUNCH ORDER.

    -Sequential runs them one at a time, in the same order, through the same lane body - so
    "is this a concurrency problem?" is one flag away rather than one revert away, and the two
    transcripts are directly diffable. Anything attended, anything that opens a window, and
    anything that mutates a shared input belongs OUTSIDE this call regardless of the flag.

    Records always come back one-per-lane. A lane the pool lost entirely still gets a record,
    with rc = -1 and Blind = $true, because a fan-out that silently returns 7 of 8 is exactly
    the false-green this estate keeps rediscovering.
  #>
  param(
    [Parameter(Mandatory)][object[]]$Lanes,
    [int]$MaxParallel = 8,
    [switch]$Sequential
  )

  $lanes = @($Lanes | Where-Object { $_ })
  if ($lanes.Count -eq 0) { return @() }
  if ($MaxParallel -lt 1) { $MaxParallel = 1 }

  # Skipped lanes never reach the pool - the caller's cadence gate already decided. They still
  # get a record so the caller's accounting (count in == count out) holds without special cases.
  $records = New-Object 'object[]' $lanes.Count
  $live = New-Object System.Collections.ArrayList
  for ($i = 0; $i -lt $lanes.Count; $i++) {
    $L = $lanes[$i]
    if (-not $L.Due) {
      $records[$i] = [pscustomobject]@{
        Name = [string]$L.Name; Index = $i; ExitCode = 0; Output = @()
        StdOut = @(); StdErr = @()
        TimedOut = $false; Elapsed = 0; Blind = $false; BlindReason = ''
        Skipped = $true; Launched = $false; LogLines = @()
      }
      continue
    }
    [void]$live.Add(@{ Index = $i; Lane = $L })
  }

  if ($live.Count -eq 0) { return @($records) }

  if ($Sequential) {
    foreach ($e in $live) {
      $L = $e.Lane
      $r = $null
      try {
        $r = & $script:FanoutLaneBody ([string]$L.Name) ([string]$L.File) (@($L.Arguments)) ([int]$L.TimeoutSec) ([string]$L.Marker) ([int]$e.Index)
      } catch {
        $r = $null
      }
      $records[$e.Index] = if ($r) { $r } else {
        [pscustomobject]@{
          Name = [string]$L.Name; Index = [int]$e.Index; ExitCode = -1
          Output = @(([string]$L.Name) + ' produced no record - BLIND, nothing proven')
          StdOut = @(); StdErr = @()
          TimedOut = $false; Elapsed = 0; Blind = $true
          BlindReason = 'the lane returned no record'
          Skipped = $false; Launched = $true; LogLines = @()
        }
      }
    }
    return @($records)
  }

  # A RUNSPACE POOL, NOT Start-Job. A job is a whole new powershell.exe with a fresh module load
  # per call (measured at 3.8 minutes for a 1-second script on 2026-08-22); a runspace is a
  # thread. Every lane below spends its life inside WaitForExit on a real OS process, so the
  # thread is a handle-holder and nothing more - see rule 4 in the header.
  $pool = [runspacefactory]::CreateRunspacePool(1, $MaxParallel)
  $pool.ApartmentState = 'MTA'
  $pool.Open()
  $handles = New-Object System.Collections.ArrayList
  try {
    foreach ($e in $live) {
      $L = $e.Lane
      $ps = [powershell]::Create()
      $ps.RunspacePool = $pool
      [void]$ps.AddScript($script:FanoutLaneBody.ToString())
      [void]$ps.AddArgument([string]$L.Name)
      [void]$ps.AddArgument([string]$L.File)
      [void]$ps.AddArgument(@($L.Arguments))
      [void]$ps.AddArgument([int]$L.TimeoutSec)
      [void]$ps.AddArgument([string]$L.Marker)
      [void]$ps.AddArgument([int]$e.Index)
      [void]$handles.Add(@{ Index = $e.Index; Name = [string]$L.Name; PS = $ps; Async = $ps.BeginInvoke() })
    }
    # Joined in LAUNCH order. EndInvoke blocks on each in turn, so the wall time is still the
    # slowest lane, but the records land in the order the caller declared them (rule 2).
    foreach ($h in $handles) {
      $r = $null; $err = ''
      try {
        $res = @($h.PS.EndInvoke($h.Async))
        $r = @($res | Where-Object { $_ -and $_.PSObject.Properties['Name'] }) | Select-Object -Last 1
        if ($h.PS.Streams.Error.Count -gt 0 -and -not $r) { $err = [string]$h.PS.Streams.Error[0] }
      } catch {
        $err = $_.Exception.Message
      }
      if ($r) {
        $records[$h.Index] = $r
      } else {
        # THE WHOLE POINT OF THE COUNT ASSERTION, MATERIALISED. A lane whose runspace died gets
        # a BLIND record by name rather than a hole in the array, so the caller's summary says
        # "this did not run" instead of quietly reporting on N-1 checks.
        $records[$h.Index] = [pscustomobject]@{
          Name = [string]$h.Name; Index = [int]$h.Index; ExitCode = -1
          Output = @(([string]$h.Name) + ' produced no record - BLIND, nothing proven')
          StdOut = @(); StdErr = @()
          TimedOut = $false; Elapsed = 0; Blind = $true
          BlindReason = ('the lane returned no record' + $(if ($err) { ': ' + $err } else { '' }))
          Skipped = $false; Launched = $true; LogLines = @()
        }
      }
      try { $h.PS.Dispose() } catch { }
    }
  } finally {
    try { $pool.Close() } catch { }
    try { $pool.Dispose() } catch { }
  }

  # Belt and braces on rule 1: any slot still empty (which should be impossible) is BLIND, not
  # $null. A $null in this array would flow into a consumer as "no findings".
  for ($i = 0; $i -lt $records.Count; $i++) {
    if ($null -eq $records[$i]) {
      $records[$i] = [pscustomobject]@{
        Name = [string]$lanes[$i].Name; Index = $i; ExitCode = -1
        Output = @(([string]$lanes[$i].Name) + ' produced no record - BLIND, nothing proven')
        StdOut = @(); StdErr = @()
        TimedOut = $false; Elapsed = 0; Blind = $true
        BlindReason = 'no record was produced for this lane'
        Skipped = $false; Launched = $true; LogLines = @()
      }
    }
  }
  return @($records)
}

function Get-FanoutRecord {
  <#
    Fetch one lane's record by name. A name that is not in the set returns a BLIND record
    rather than $null - asking for a lane that was never defined is a code bug, and a code bug
    here must read as "we did not check", never as an empty result the consumer treats as clean.
  #>
  param(
    [Parameter(Mandatory, Position = 0)][string]$Name,
    [Parameter(Mandatory, Position = 1)][AllowEmptyCollection()][object[]]$Records
  )
  foreach ($r in @($Records)) { if ($r -and [string]$r.Name -eq $Name) { return $r } }
  return [pscustomobject]@{
    Name = $Name; Index = -1; ExitCode = -1
    Output = @($Name + ' has no fan-out record - BLIND, nothing proven')
    StdOut = @(); StdErr = @()
    TimedOut = $false; Elapsed = 0; Blind = $true
    BlindReason = 'no lane by that name was defined'
    Skipped = $false; Launched = $false; LogLines = @()
  }
}

function Test-FanoutComplete {
  <#
    The collector's assertion, as one call. Returns the BLIND findings as strings, ready to go
    straight into $summary - empty means every launched lane came back accounted for.

    It asserts the COUNT first and by name, because "N records for N lanes" is the only thing
    that distinguishes "all clear" from "we lost one".
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Lanes,
    [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records
  )
  $findings = @()
  $lanes = @($Lanes | Where-Object { $_ })
  $recs  = @($Records | Where-Object { $_ })
  if ($recs.Count -ne $lanes.Count) {
    $findings += ('REVIEW    fan-out returned ' + $recs.Count + ' record(s) for ' + $lanes.Count +
                  ' lane(s) - at least one advisory audit did NOT run and its silence is not a clean board')
  }
  foreach ($L in $lanes) {
    $r = $null
    foreach ($x in $recs) { if ([string]$x.Name -eq [string]$L.Name) { $r = $x; break } }
    if (-not $r) {
      $findings += ('REVIEW    fan-out lane ' + [string]$L.Name + ' returned NO record - BLIND, that check did not run this cycle')
      continue
    }
    if ($r.Skipped) { continue }        # a cadence skip is the caller's to report, with its date
    if ($r.Blind) {
      $findings += ('REVIEW    ' + [string]$r.Name + ' is BLIND - ' + [string]$r.BlindReason)
    }
  }
  return @($findings)
}

# ---- SELF-TEST -----------------------------------------------------------------------------------------
# READ OFF $args, AND ONLY WHEN RUN, NEVER WHEN DOT-SOURCED. This file must not declare a param() block:
# in PS 5.1 dot-sourcing a script runs its param() in the CALLER's scope, so a `param([switch]$SelfTest)`
# here would silently reset check-ad-cycles' own switches on the line after the dot-source. That is not
# hypothetical - lib\guard-contract.ps1 shipped exactly that bug and disarmed the self-test of every guard
# that dot-sourced it. Same guard, same reason, same shape.
#   powershell -NoProfile -File grocery\fanout-lib.ps1 -SelfTest
$__foSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
if ($__foSelfTest) {
  $ErrorActionPreference = 'Continue'
  $script:n = 0; $script:bad = 0
  function T([string]$What, [bool]$Cond, [string]$Detail = '') {
    $script:n++
    if ($Cond) { Write-Output ("  ok    " + $What) }
    else { $script:bad++; Write-Output ("  FAIL  " + $What + $(if ($Detail) { ' -> ' + $Detail } else { '' })) }
  }

  $td = Join-Path $env:TEMP ('fanout-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $td -Force | Out-Null
  try {
    Set-Content (Join-Path $td 'ok.ps1')     -Value "Start-Sleep -Milliseconds 600; Write-Output 'hello'; Write-Output 'OK-COMPLETE'; exit 0"
    Set-Content (Join-Path $td 'rc2.ps1')    -Value "Write-Output 'found things'; Write-Output 'OK-COMPLETE'; exit 2"
    Set-Content (Join-Path $td 'nomark.ps1') -Value "Write-Output 'quiet'; exit 0"
    Set-Content (Join-Path $td 'slow.ps1')   -Value "Start-Sleep -Seconds 30; Write-Output 'never'"
    Set-Content (Join-Path $td 'err.ps1')    -Value "[Console]::Error.WriteLine('a stderr line'); Write-Output 'OK-COMPLETE'; exit 0"
    Set-Content (Join-Path $td 'sleep3.ps1') -Value "Start-Sleep -Seconds 3; Write-Output 'done'"
    Set-Content (Join-Path $td 'kept-going.ps1') -Value "Write-Output 'OK-COMPLETE'; Write-Output 'and then it kept going'; exit 0"
    Set-Content (Join-Path $td 'noisy.ps1')      -Value "[Console]::Error.WriteLine('a warning'); Write-Output 'work'; Write-Output 'OK-COMPLETE'; exit 0"

    $lanes = @(
      New-FanoutLane -Name 'ok'      -File (Join-Path $td 'ok.ps1')     -Marker 'OK-COMPLETE'
      New-FanoutLane -Name 'rc2'     -File (Join-Path $td 'rc2.ps1')    -Marker 'OK-COMPLETE'
      New-FanoutLane -Name 'nomark'  -File (Join-Path $td 'nomark.ps1') -Marker 'OK-COMPLETE'
      New-FanoutLane -Name 'slow'    -File (Join-Path $td 'slow.ps1')   -TimeoutSec 2
      New-FanoutLane -Name 'missing' -File (Join-Path $td 'nope.ps1')
      New-FanoutLane -Name 'err'     -File (Join-Path $td 'err.ps1')    -Marker 'OK-COMPLETE'
      New-FanoutLane -Name 'kept'    -File (Join-Path $td 'kept-going.ps1') -Marker 'OK-COMPLETE'
      # THE EXACT SHAPE THAT KILLED store-registry: a $( ) that yields an empty collection, which
      # PowerShell collapses to $null on the way into [string[]]. It must LAUNCH, notreport BLIND.
      New-FanoutLane -Name 'emptyargs' -File (Join-Path $td 'ok.ps1') -Marker 'OK-COMPLETE' -Arguments $(if ($false) { @('-Nope') } else { @() })
      New-FanoutLane -Name 'noisy'   -File (Join-Path $td 'noisy.ps1')  -Marker 'OK-COMPLETE'
      New-FanoutLane -Name 'skipped' -File (Join-Path $td 'ok.ps1')     -Due $false
    )

    $par = @(Invoke-Fanout -Lanes $lanes -MaxParallel 8)
    $seq = @(Invoke-Fanout -Lanes $lanes -MaxParallel 8 -Sequential)

    # RULE 1: N lanes in, N records out. This is the assertion the whole file exists for - a fan-out that
    # returns 6 records for 7 lanes and no error has reported on a check that never ran.
    T 'every lane gets a record (parallel)'   ($par.Count -eq $lanes.Count) ("got " + $par.Count + " of " + $lanes.Count)
    T 'every lane gets a record (sequential)' ($seq.Count -eq $lanes.Count) ("got " + $seq.Count + " of " + $lanes.Count)

    # RULE 2: launch order, not finish order. 'ok' sleeps and MUST still come back first.
    $order = (@($par | ForEach-Object { $_.Name }) -join ',')
    T 'records come back in LAUNCH order, not finish order' ($order -eq (@($lanes | ForEach-Object { $_.Name }) -join ',')) $order

    # MUST FIRE - THE 2026-08-23 FIXTURE. A lane whose script does not exist reports BLIND, never clean.
    # `powershell -File missing.ps1` does NOT fail to launch: it starts, prints its banner, and exits
    # -196608. Before this case existed that came back Blind=$false with no finding at all, which is a
    # deleted check reporting a clean board - the exact failure the fan-out exists to make impossible.
    $mis = @($par | Where-Object { $_.Name -eq 'missing' })[0]
    T 'MUST FIRE  a lane whose script is MISSING is BLIND, not clean' ($mis.Blind -and $mis.ExitCode -eq 3) ("blind=" + $mis.Blind + " rc=" + $mis.ExitCode)

    # MUST FIRE - a lane that exits 0 without its declared completion marker did not run to the end.
    $nm = @($par | Where-Object { $_.Name -eq 'nomark' })[0]
    T 'MUST FIRE  exit 0 without the declared marker is BLIND' ($nm.Blind -and $nm.ExitCode -eq 0) ("blind=" + $nm.Blind)

    # MUST FIRE - a timeout is rc 3 (could-not-evaluate) and BLIND, never a clean pass.
    $sl = @($par | Where-Object { $_.Name -eq 'slow' })[0]
    T 'MUST FIRE  a lane killed at its budget is rc 3 and BLIND' ($sl.Blind -and $sl.ExitCode -eq 3 -and $sl.TimedOut) ("rc=" + $sl.ExitCode)

    # CLEAN TWIN - the checks above must not accuse a healthy lane, or they train the reader to ignore them.
    $okr = @($par | Where-Object { $_.Name -eq 'ok' })[0]
    $r2  = @($par | Where-Object { $_.Name -eq 'rc2' })[0]
    $er  = @($par | Where-Object { $_.Name -eq 'err' })[0]
    T 'CLEAN TWIN a healthy lane with its marker is NOT blind'      (-not $okr.Blind -and $okr.ExitCode -eq 0)
    T 'CLEAN TWIN a findings exit (rc 2) is a verdict, not a BLIND' (-not $r2.Blind -and $r2.ExitCode -eq 2)
    # The native-lib lesson one level up: a child writing to stderr is not a failure of ours, and under
    # EAP=Stop a 2>&1 in the lane body would have terminated the pool instead of returning a record.
    T 'CLEAN TWIN a child that writes to stderr still reports rc 0' (-not $er.Blind -and $er.ExitCode -eq 0 -and (($er.Output -join ' ') -match 'a stderr line'))

    # MUST FIRE - THE MARKER MUST BE THE LAST LINE, NOT MERELY PRESENT. lib\guard-contract.ps1 puts it
    # exactly this way: "a guard that printed it and then kept going (and died) has not finished either".
    # The first version of this file matched the marker ANYWHERE in the output, which is a weaker copy of
    # the estate's own contract - and a weaker copy is worse than none, because it looks enforced.
    $kp = @($par | Where-Object { $_.Name -eq 'kept' })[0]
    T 'MUST FIRE  a marker that is present but NOT last is BLIND' ($kp.Blind -and $kp.ExitCode -eq 0) ("blind=" + $kp.Blind)

    # CLEAN TWIN for the same rule, and the reason StdOut is kept apart from Output: this lane writes one
    # line to STDERR, and Output appends stderr AFTER stdout. Checking the merged stream would put the
    # warning last and call a perfectly finished guard BLIND - a false alarm on every child that warns.
    $ny = @($par | Where-Object { $_.Name -eq 'noisy' })[0]
    T 'CLEAN TWIN a child that warns on stderr still passes the last-line marker check' (-not $ny.Blind -and $ny.ExitCode -eq 0) ("blind=" + $ny.Blind + " why=" + $ny.BlindReason)

    # MUST FIRE, FROM A LIVE REGRESSION (2026-08-23). check-ad-cycles built the store-registry lane as
    # `-Arguments $(if (-not $NoAlert) { @('-Alert') } else { @() })`. An empty $( ) collapses to $null,
    # [string[]] binds it, and @($null) is an array holding one NULL - Start-Process then refuses the
    # whole ArgumentList and the lane never runs. It shipped, and it was dead on exactly the -NoAlert
    # runs the cloud backup makes. A lane built this way must LAUNCH.
    $ea = @($par | Where-Object { $_.Name -eq 'emptyargs' })[0]
    T 'MUST FIRE  an empty $( ) argument list still launches (it collapses to $null, and @($null) is not empty)' (-not $ea.Blind -and $ea.ExitCode -eq 0) ("blind=" + $ea.Blind + " why=" + $ea.BlindReason)

    # A cadence skip is not a pass, but it is also not a BLIND - the caller reports it with its date.
    $sk = @($par | Where-Object { $_.Name -eq 'skipped' })[0]
    T 'a not-due lane is Skipped, not launched, and not accused' ($sk.Skipped -and -not $sk.Launched -and -not $sk.Blind)

    # Test-FanoutComplete turns exactly the three BLIND lanes into findings and accuses nobody else.
    $f = @(Test-FanoutComplete -Lanes $lanes -Records $par)
    T 'the collector reports 4 BLIND finding(s) and no more' ($f.Count -eq 4) (($f -join ' | '))

    # An unknown lane name is a code bug, and a code bug must read as "we did not check".
    $gone = Get-FanoutRecord 'nosuchlane' $par
    T 'asking for an undefined lane returns BLIND, never an empty result' ($gone -and $gone.Blind -and $gone.ExitCode -eq -1)

    # -Sequential MUST agree with the pool on every verdict. That is what makes the flag a diagnosis tool
    # rather than a revert: if the two ever disagree, the difference IS the finding.
    $diff = 0
    for ($i = 0; $i -lt $lanes.Count; $i++) {
      if ($par[$i].Name -ne $seq[$i].Name -or $par[$i].ExitCode -ne $seq[$i].ExitCode -or $par[$i].Blind -ne $seq[$i].Blind) { $diff++ }
    }
    T '-Sequential returns the SAME verdict for every lane as the pool' ($diff -eq 0) ("$diff lane(s) differ")

    # AND IT MUST ACTUALLY BE CONCURRENT. Without this case the whole file could be a slow serial loop and
    # every assertion above would still pass - a fan-out that does not fan out, reporting green.
    # THE SLEEP IS 3 s, NOT 6 (trimmed 2026-08-23 on a measurement). At 6 s this self-test was 12 s, which
    # made it the single most expensive -SelfTest in the estate and 57% of that whole group's runtime - a
    # fixture that costs more than the thing it is measuring is its own small defect. 8 x 3 s is concurrent
    # at ~3-4 s and serial at ~24 s: the gap is still 6x, so a 12 s threshold cannot be flaky, and the case
    # keeps exactly the discrimination it had.
    $probe = 1..8 | ForEach-Object { New-FanoutLane -Name ("L$_") -File (Join-Path $td 'sleep3.ps1') -TimeoutSec 60 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $pr = @(Invoke-Fanout -Lanes $probe -MaxParallel 8)
    $sw.Stop()
    $sum = 0; foreach ($x in $pr) { $sum += [int]$x.Elapsed }
    T 'the pool really runs lanes CONCURRENTLY (8 x 3 s in under 12 s wall)' ($sw.Elapsed.TotalSeconds -lt 12 -and $sum -ge 16) ("wall {0:n1} s, sum {1} s" -f $sw.Elapsed.TotalSeconds, $sum)
  } finally {
    Remove-Item $td -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Output ("SELFTEST: {0}/{1} pass" -f ($script:n - $script:bad), $script:n)
  Write-Output ("FANOUT-LIB-COMPLETE cases={0} failed={1}" -f $script:n, $script:bad)
  if ($script:bad -gt 0) { exit 1 }
  exit 0
}
