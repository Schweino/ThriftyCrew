# ledger-fixture.ps1 - launch N concurrent writers against a locked ledger and know what each one did.
#
# WHY THIS EXISTS (2026-09-11). Three ledgers here take a named mutex around a read-modify-write
# (meal-prep\pipeline\source-domains.ps1, meal-prep\pipeline\ingredient-resolutions.ps1,
# grocery\ingredient-queue.ps1), and each self-test proves it by launching several writers at once and
# counting what landed. Two things were wrong with how those fixtures launched them:
#
#   * A LOCK THAT IS DISABLED WAS CAUGHT MOST RUNS, NOT EVERY RUN. The barrier sat in a Start-Job child
#     BEFORE `& powershell -File`, so every writer still paid its own powershell.exe start-up - about a
#     second, and variable - after it was released. That spread the writers further than the barrier
#     closed. Measured 2026-09-11 with WaitOne and ReleaseMutex both skipped: ingredient-resolutions red in
#     6 of 11 runs, ingredient-queue 2 of 3. A must-fire that misses half the time is a coin, not a gate.
#   * A WRITER THAT COULD NOT RUN READ LIKE A LOST ROW. Start-Job children and their results were collected
#     with -ErrorAction SilentlyContinue, so a job that failed to start, a writer that died before the lock
#     and a writer still running at the 180 s wait all printed the same "N writer(s) returned NO result".
#
# THE RULE. The barrier belongs INSIDE the writer, after its start-up, immediately before it asks for the
# lock - so start-up is spent before the barrier and the writers reach WaitOne together. The writer waits on
# a named manual-reset kernel event, so one Set() releases every waiter at once with no polling spread. The
# parent launches each writer as its own process with its stdout and stderr in files, and returns one row
# per writer: launched, at the barrier when released, released by the parent or by its own hang guard, how
# many writers were at the barrier when IT was released, exited or killed, exit code, stdout, stderr.
#
# WHAT IT BOUGHT, MEASURED 2026-09-11 with each ledger's lock disabled (WaitOne and ReleaseMutex skipped) in a
# temp mirror, against the fixture it replaced, under uncontrolled load (other sessions' gate runs; 32 CPU burners
# from another session after 11:47):
#   ledger                  lock disabled: old fixture  new fixture    lock intact: old  new
#   source-domains                         10 of 10     20 of 20 red                0/20 0/20 red, paired
#   ingredient-resolutions                  9 of 10     20 of 20 red                0/20 0/20 red, paired
#   ingredient-queue                       10 of 10     10 of 10 red, paired        0/10 0/10 red, paired
# The disabled-lock old arms for the first two ran in an earlier window than the new ones, so those two are not a
# clean pair; 9f3ca3cbd had measured the old ingredient-resolutions fixture at 6 of 11. On this load the old
# fixture already caught most disabled locks, so the gain is the one run in thirty it missed plus a start-up spread
# that is now gone by construction and asserted as a count every run - not a large change in rate.
# Harness: a scratch harness running each arm's -SelfTest back to back, at 00c3527d7 plus this change.
#
# WHY NOT lib\concurrency-probe.ps1, the exemplar for proving overlap without a clock. Its children poll a
# started\ count until all N are there, which proves a POOL overlapped. This barrier has three needs that does
# not meet: it sits inside a production script rather than in a probe child, the parent must release the
# survivors at once when a writer dies before the barrier instead of each waiting out a deadline, and one
# kernel Set() releases every waiter together where polling spreads them by the timer resolution. The proof
# is the same shape - each writer records how many were at the barrier when IT was released - so a
# self-test asserts a count, never a speed.
#
# THE WRITER SIDE IS A NO-OP IN PRODUCTION. It does nothing at all unless TC_LEDGER_FIXTURE_GATE is set, and
# only Invoke-TcLedgerWriters sets it, in its own process, for the children it launches. Same idiom as
# TC_EVENT_BUS in lib\event-bus.ps1.
#
# THE LOCK WAIT UNDER A FIXTURE. With the gate set, Get-TcLedgerFixtureLockMs returns a hang guard instead of
# the ledger's production timeout, and the production value is NOT changed. A self-test's question is whether
# the lock loses a write; whether 15 s is long enough for eight writers on a starved box is a production
# question, and production answers it loudly (a refused write exits non-zero and, in source-domains, writes a
# ledger-write-refused event). Letting the production timeout decide a hermetic gate is the wall-clock bar
# the ops rules forbid, one step removed: load would redden it without anything being wrong.
#
# THE TUNING CONSTANTS, AND WHAT THEY ARE: 120 s for a writer to be released, 120 s for its lock wait, 180 s
# for the writers to exit after release, 100 s for the parent to see every writer at the barrier. First
# plausible numbers, NOT the survivors of a sweep; the fixtures these replace used 150 s and 180 s. Each is a
# hang guard only - no case passes or fails on how long anything took. What they do when the producer stops:
# a writer that never starts is reported as never reaching the barrier once the parent's wait runs out.
#
# SCOPE OF A CLEAN REPORT: the self-test drives real powershell.exe children on this machine. A pass proves
# the barrier releases every writer together, that each writer's exit code, output and failure to run are
# kept and named, and that the writer side is inert without the gate. It says nothing about any ledger's
# lock; each ledger's own suite owns that.
#
# Dot-source:  . (Join-Path $repoRoot 'lib\ledger-fixture.ps1')
# Self-test:   powershell -File lib\ledger-fixture.ps1 -SelfTest
#
# NO param() BLOCK HERE, DELIBERATELY - dot-sourced under PS 5.1 a param() block runs in the CALLER's scope
# and would reset the caller's own -SelfTest. Same rule as lib\atomic-write.ps1.
$__lfSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

$script:TcLedgerFixtureReleaseMs = 120000
$script:TcLedgerFixtureLockMs = 120000

function Get-TcLedgerFixtureEventName([string]$Gate) {
  return ('Local\tc-ledger-fixture-' + (Split-Path -Leaf $Gate))
}

function Wait-TcLedgerFixtureGate {
  <# Writer side. Returns immediately unless a fixture set TC_LEDGER_FIXTURE_GATE. Otherwise: says it is
     ready, waits to be released, and records who released it and how many writers were ready then. #>
  $gate = [string]$env:TC_LEDGER_FIXTURE_GATE
  if (-not $gate) { return }
  $ev = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, (Get-TcLedgerFixtureEventName $gate))
  try {
    [IO.File]::WriteAllText((Join-Path $gate ('ready-' + $PID)), '')
    $byGo = $ev.WaitOne($script:TcLedgerFixtureReleaseMs)
    $seen = @(Get-ChildItem -LiteralPath $gate -Filter 'ready-*').Count
    [IO.File]::WriteAllText((Join-Path $gate ('released-' + $PID)), ('{0} {1}' -f $(if ($byGo) { 'go' } else { 'guard' }), $seen))
  } finally { $ev.Dispose() }
}

function Get-TcLedgerFixtureLockMs([int]$Default) {
  <# The ledger's own lock timeout in production; a hang guard when a fixture launched this writer. #>
  if ([string]$env:TC_LEDGER_FIXTURE_GATE) { return $script:TcLedgerFixtureLockMs }
  return $Default
}

function ConvertTo-TcProcessArg([string]$A) {
  <# One argv token for a Windows command line. Start-Process joins -ArgumentList with spaces and quotes
     nothing, so 'conc term 1' would arrive as three arguments. #>
  if ($A -eq '') { return '""' }
  if ($A -notmatch '[\s"]') { return $A }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"'); $bs = 0
  foreach ($ch in $A.ToCharArray()) {
    if ($ch -eq [char]'\') { $bs++; continue }
    if ($ch -eq [char]'"') { [void]$sb.Append(('\' * ($bs * 2 + 1)) + '"'); $bs = 0; continue }
    if ($bs) { [void]$sb.Append('\' * $bs); $bs = 0 }
    [void]$sb.Append($ch)
  }
  [void]$sb.Append(('\' * ($bs * 2)) + '"')
  return $sb.ToString()
}

function Invoke-TcLedgerWriters {
  <# Launches one writer process per entry of -ArgSets (each an array of arguments after -File <Script>),
     holds them at the barrier until every launched writer is ready or has exited, releases them together,
     and waits for them to exit. Returns @{ writers = rows; ready_at_go; go_ms }. Never throws for a writer. #>
  param(
    [Parameter(Mandatory = $true)][string]$Script,
    [Parameter(Mandatory = $true)][object[]]$ArgSets,
    [string]$Exe = 'powershell',
    [int]$ReadyWaitS = 100,
    [int]$ExitWaitS = 180
  )
  $gate = Join-Path ([IO.Path]::GetTempPath()) ('tc-lf-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $gate -Force | Out-Null
  $ev = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, (Get-TcLedgerFixtureEventName $gate))
  $launched = New-Object System.Collections.Generic.List[object]
  $prevGate = $env:TC_LEDGER_FIXTURE_GATE
  try {
    $env:TC_LEDGER_FIXTURE_GATE = $gate
    try {
      for ($i = 0; $i -lt $ArgSets.Count; $i++) {
        $outF = Join-Path $gate ('out-{0}.txt' -f ($i + 1)); $errF = Join-Path $gate ('err-{0}.txt' -f ($i + 1))
        $argLine = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + @($ArgSets[$i]) | ForEach-Object { ConvertTo-TcProcessArg ([string]$_) }) -join ' '
        $p = $null; $launchErr = ''
        try {
          $p = Start-Process -FilePath $Exe -ArgumentList $argLine -PassThru -NoNewWindow -RedirectStandardOutput $outF -RedirectStandardError $errF -ErrorAction Stop
          $null = $p.Handle   # cache the handle now, or ExitCode reads empty once the process is gone
        } catch { $launchErr = $_.Exception.Message; $p = $null }
        $launched.Add([pscustomobject]@{ n = $i + 1; p = $p; out = $outF; err = $errF; launch_error = $launchErr })
      }
    } finally { $env:TC_LEDGER_FIXTURE_GATE = $prevGate }

    # Hold until every launched writer is at the barrier or has already exited (a dead writer is not waited for).
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $ReadyWaitS) {
      $pending = @($launched | Where-Object { $_.p -and -not $_.p.HasExited -and -not (Test-Path -LiteralPath (Join-Path $gate ('ready-' + $_.p.Id))) })
      if ($pending.Count -eq 0) { break }
      Start-Sleep -Milliseconds 20
    }
    $readyAtGo = @{}
    foreach ($w in $launched) { if ($w.p) { $readyAtGo[$w.n] = (Test-Path -LiteralPath (Join-Path $gate ('ready-' + $w.p.Id))) } else { $readyAtGo[$w.n] = $false } }
    $goMs = $sw.ElapsedMilliseconds
    [void]$ev.Set()

    $exitSw = [Diagnostics.Stopwatch]::StartNew()
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($w in $launched) {
      $exited = $false; $timedOut = $false; $code = $null
      if ($w.p) {
        $left = [int][Math]::Max(0, ($ExitWaitS * 1000) - $exitSw.ElapsedMilliseconds)
        if ($w.p.WaitForExit($left)) { $exited = $true; $w.p.WaitForExit(); $code = $w.p.ExitCode }
        else { $timedOut = $true; try { $w.p.Kill(); [void]$w.p.WaitForExit(10000) } catch { } }
      }
      $relBy = ''; $relSeen = -1
      if ($w.p) {
        $rf = Join-Path $gate ('released-' + $w.p.Id)
        if (Test-Path -LiteralPath $rf) {
          $parts = ([IO.File]::ReadAllText($rf)).Trim() -split ' '
          $relBy = $parts[0]; if ($parts.Count -gt 1) { $relSeen = [int]$parts[1] }
        }
      }
      $o = ''; $e = ''
      if (Test-Path -LiteralPath $w.out) { $o = [string][IO.File]::ReadAllText($w.out) }
      if (Test-Path -LiteralPath $w.err) { $e = [string][IO.File]::ReadAllText($w.err) }
      $rows.Add([pscustomobject]@{
        n = $w.n; pid = $(if ($w.p) { $w.p.Id } else { $null }); launched = [bool]$w.p; launch_error = $w.launch_error
        ready_at_go = [bool]$readyAtGo[$w.n]; released_by = $relBy; ready_seen = $relSeen
        exited = $exited; timed_out = $timedOut; exit = $code; out = $o.Trim(); err = $e.Trim()
        ran = ([bool]$w.p -and [bool]$readyAtGo[$w.n] -and $relBy -eq 'go' -and $exited)
      })
    }
    return [pscustomobject]@{ writers = $rows.ToArray(); ready_at_go = @($readyAtGo.Values | Where-Object { $_ }).Count; go_ms = $goMs }
  } finally {
    $ev.Dispose()
    Remove-Item -LiteralPath $gate -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Format-TcWriterTrouble {
  <# One clause per writer that did not run cleanly, naming WHICH way: could not be launched, never reached
     the barrier, released by its own guard, killed at the hang guard, a non-zero exit, or stderr. Empty when
     every writer ran and exited 0 with nothing on stderr. #>
  param([object[]]$Writers)
  $cut = { param($s) $t = ([string]$s) -replace '\s+', ' '; if ($t.Length -gt 160) { $t.Substring(0, 160) + '...' } else { $t } }
  $parts = foreach ($w in @($Writers)) {
    if (-not $w.launched) { ' | writer {0} could NOT BE LAUNCHED: {1}' -f $w.n, (& $cut $w.launch_error); continue }
    if ($w.timed_out) { ' | writer {0} was still running at the hang guard and was KILLED (released by: {1})' -f $w.n, $(if ($w.released_by) { $w.released_by } else { 'nobody' }); continue }
    if (-not $w.ready_at_go -and $w.released_by -eq '') { ' | writer {0} NEVER REACHED the barrier: exit {1}, out: {2}, err: {3}' -f $w.n, $w.exit, (& $cut $w.out), (& $cut $w.err); continue }
    if (-not $w.ready_at_go) { ' | writer {0} was NOT AT THE BARRIER when the others were released (released by: {1}), exit {2}' -f $w.n, $w.released_by, $w.exit; continue }
    if ($w.released_by -ne 'go') { ' | writer {0} was released by its OWN HANG GUARD, not the parent, exit {1}' -f $w.n, $w.exit; continue }
    if ($w.exit -ne 0) { ' | writer {0} exit {1}: {2}{3}' -f $w.n, $w.exit, (& $cut $w.out), $(if ($w.err) { ' err: ' + (& $cut $w.err) } else { '' }); continue }
    if ($w.err) { ' | writer {0} exit 0 but wrote stderr: {1}' -f $w.n, (& $cut $w.err) }
  }
  return (@($parts) -join '')
}

if ($__lfSelfTest) {
  $ErrorActionPreference = 'Stop'
  $script:cases = 0; $script:failed = 0
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Got) {
    $script:cases++
    if ($Ok) { Write-Output ("  ok    {0}  {1}" -f $Label, $Name) }
    else { $script:failed++; Write-Output ("  X     {0}  {1}   got: {2}" -f $Label, $Name, $Got) }
  }
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('tc-lf-test-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $lib = $PSCommandPath
  try {
    # A stand-in writer: dot-sources this lib, can exit before the barrier, can hang after it, echoes one argument.
    $child = Join-Path $dir 'writer.ps1'
    $childText = @'
param([string]$Lib, [string]$Mode = 'ok', [string]$Echo = '', [int]$Code = 0)
. $Lib
if ($Mode -eq 'early') { Write-Output 'leaving before the barrier'; exit $Code }
Wait-TcLedgerFixtureGate
if ($Mode -eq 'hang') { Start-Sleep -Seconds 120 }
Write-Output ('echo=[' + $Echo + ']')
exit $Code
'@
    [IO.File]::WriteAllText($child, $childText, (New-Object Text.UTF8Encoding($false)))

    # ---- the production side is inert: no gate, no wait, no file, the ledger's own timeout ----
    $prev = $env:TC_LEDGER_FIXTURE_GATE
    $env:TC_LEDGER_FIXTURE_GATE = $null
    Wait-TcLedgerFixtureGate
    $inertLock = Get-TcLedgerFixtureLockMs 15000
    $env:TC_LEDGER_FIXTURE_GATE = (Join-Path $dir 'not-a-gate')
    $fixtureLock = Get-TcLedgerFixtureLockMs 15000
    $env:TC_LEDGER_FIXTURE_GATE = $prev
    Case 'MUST NOT FIRE' 'with no fixture gate set the writer side returns at once and the lock timeout is the production value' ($inertLock -eq 15000) ("lock=$inertLock")
    Case 'CLEAN TWIN' 'with a gate set the lock wait is the fixture hang guard, not the production timeout' ($fixtureLock -eq $script:TcLedgerFixtureLockMs) ("lock=$fixtureLock")

    # ---- the barrier releases every writer together, and each keeps its own exit code and arguments ----
    $awkward = 'conc term "7" at C:\a b\'
    $r = Invoke-TcLedgerWriters -Script $child -ArgSets @(
      , @('-Lib', $lib, '-Echo', $awkward, '-Code', '0')
      , @('-Lib', $lib, '-Echo', 'plain', '-Code', '3')
      , @('-Lib', $lib, '-Echo', 'conc term 1', '-Code', '0'))
    $ws = @($r.writers)
    $allRan = (@($ws | Where-Object { $_.ran }).Count -eq 3)
    $allSawAll = (@($ws | Where-Object { $_.ready_seen -eq 3 }).Count -eq 3)
    Case 'MUST FIRE' 'three writers are held at the barrier and released together: each saw all three ready when it was released' ($allRan -and $allSawAll -and $r.ready_at_go -eq 3) ((@($ws | ForEach-Object { 'w{0} ran={1} by={2} seen={3}' -f $_.n, $_.ran, $_.released_by, $_.ready_seen }) -join '; '))
    Case 'CLEAN TWIN' 'an argument with spaces, embedded quotes and a trailing backslash arrives as ONE argument, character for character' ($ws[0].out -eq ('echo=[' + $awkward + ']') -and $ws[2].out -eq 'echo=[conc term 1]') ("w1 out=" + $ws[0].out + " w3 out=" + $ws[2].out)
    Case 'MUST FIRE' 'each writer keeps its OWN exit code' ($ws[0].exit -eq 0 -and $ws[1].exit -eq 3 -and $ws[2].exit -eq 0) ((@($ws | ForEach-Object { 'w{0}={1}' -f $_.n, $_.exit }) -join ' '))
    $t = Format-TcWriterTrouble $ws
    Case 'MUST FIRE' 'the trouble line names the writer that exited non-zero, and only that one' ($t -match 'writer 2 exit 3' -and $t -notmatch 'writer 1' -and $t -notmatch 'writer 3') $t

    # ---- a writer that could not run reads as exactly that, never as a writer that ran ----
    $r = Invoke-TcLedgerWriters -Script $child -ArgSets @(
      , @('-Lib', $lib, '-Mode', 'ok')
      , @('-Lib', $lib, '-Mode', 'early', '-Code', '5')
      , @('-Lib', $lib, '-Mode', 'ok'))
    $ws = @($r.writers); $t = Format-TcWriterTrouble $ws
    Case 'MUST FIRE' 'a writer that exits BEFORE the barrier reads as NEVER REACHED the barrier, with its exit code' (-not $ws[1].ran -and $ws[1].exit -eq 5 -and $t -match 'writer 2 NEVER REACHED the barrier: exit 5') $t
    Case 'CLEAN TWIN' 'and the writers that did reach it are still released and run - a dead writer is not waited for' ($ws[0].ran -and $ws[2].ran -and $ws[0].exit -eq 0 -and $ws[2].exit -eq 0) ((@($ws | ForEach-Object { 'w{0} ran={1} exit={2}' -f $_.n, $_.ran, $_.exit }) -join '; '))

    $r = Invoke-TcLedgerWriters -Script $child -Exe (Join-Path $dir 'no-such-powershell.exe') -ArgSets @(, @('-Lib', $lib))
    $ws = @($r.writers); $t = Format-TcWriterTrouble $ws
    Case 'MUST FIRE' 'a writer that cannot be launched reads as COULD NOT BE LAUNCHED' (-not $ws[0].launched -and -not $ws[0].ran -and $t -match 'writer 1 could NOT BE LAUNCHED') $t

    # A LOWER bound only: the writer sleeps 120 s against an 8 s guard, and load can only make that more true.
    $r = Invoke-TcLedgerWriters -Script $child -ExitWaitS 8 -ArgSets @(, @('-Lib', $lib, '-Mode', 'hang'))
    $ws = @($r.writers); $t = Format-TcWriterTrouble $ws
    Case 'MUST FIRE' 'a writer still running at the hang guard is KILLED and reads as that, not as a clean exit' ($ws[0].timed_out -and -not $ws[0].ran -and $null -eq $ws[0].exit -and $t -match 'writer 1 was still running at the hang guard and was KILLED') $t
  } finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($script:failed) {
    Write-Output ("ledger-fixture SELF-TEST FAIL ({0} of {1})" -f $script:failed, $script:cases)
    Write-Output ("LEDGER-FIXTURE-COMPLETE cases={0} failed={1}" -f $script:cases, $script:failed)
    exit 1
  }
  Write-Output ("ledger-fixture SELF-TEST PASS ({0} cases)" -f $script:cases)
  Write-Output ("LEDGER-FIXTURE-COMPLETE cases={0} failed=0" -f $script:cases)
  exit 0
}
