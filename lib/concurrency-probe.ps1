<#
  concurrency-probe.ps1 - prove that N child processes were ALIVE AT THE SAME INSTANT, without timing them.

  Self-test:   powershell -File lib\concurrency-probe.ps1 -SelfTest

  WHY (2026-09-11). Two self-tests proved their pool was concurrent with a wall-clock bar:
  grocery\fanout-lib.ps1 ("8 x 3 s in under 12 s wall") and lib\parallel-run.ps1 ("six 600ms jobs in
  under 2.5 s"). Both went red in a pre-push run-gates that shared the box with at least three other
  sessions' gates - 337 gates in 792 s against 106 s quiet, fanout at 19.6 s, parallel-run at 6.89 s -
  and both passed 3 of 3 run solo straight afterwards. The push was blocked on those two alone, for a
  change that touched neither file. A wall-clock bar measures the MACHINE as well as the pool, and the
  machine here is shared by several sessions pushing at once, so it went red at random and invited
  --no-verify.

  THE MECHANISM: A RENDEZVOUS, NOT A STOPWATCH. Each child writes a file into started\, then polls until
  started\ holds all N files, and records how many it saw. It stops waiting on one of three conditions:
    all       started\ holds N files. Checked FIRST, so a healthy child that also sees a finished peer
              still reports success.
    finished  a peer has already written to ended\. In a concurrent run that cannot happen before all N
              have started, so a child that sees it is watching a SERIAL run and gives up at once rather
              than burning its own deadline too. ended\ is read BEFORE started\ on purpose: a peer that
              wrote ended\ had already seen N started files, so a started\ read taken after an ended\
              read sees them too, and a healthy run can never be misread as serial.
    deadline  DeadlineSec passed with neither. The first child of a serial run exits this way.

  ONE CHILD SAYING `all` PROVES NOTHING, and this file's own self-test caught the first draft claiming it
  did. started\ files outlive their writers, so the LAST child of a serial run sees N of them and reports
  `all` among peers that are long dead. The proof is the RUN: when EVERY child reports `all`, every child
  stayed in its loop until the last one had started, so at the instant the last one started all N were
  alive. That is why the verdict is Ok only when all N report `all`, never when any one does.
  It is the grocery rule for pages that load in pieces, applied to processes: wait on a COUNT, never
  sleep and hope. The proof that the work overlapped is built into the wait condition, not bolted on
  after with a clock.

  WHAT LOAD DOES TO IT: makes it slower, never red. A contended box delays when the Nth child starts, and
  every earlier child simply waits longer. The only wall-clock number left is DeadlineSec, and it bounds
  the gap between the first child starting and the last - not the whole run. The verdict prints the
  longest wait it saw, so the margin is visible on every run rather than assumed.

  WHAT BROKEN CONCURRENCY DOES TO IT: red however quiet the box is. A pool of width 1 runs one child,
  which can never see N; a pool of width 2 runs two, which cannot either. A pool that drops a job or
  launches one twice leaves started\ holding a count other than N. None of those depends on timing.

  SCOPE OF A CLEAN REPORT: a pass PROVES all N children were alive at once and each reported. A fail
  means at least one of them did not see the others - broken concurrency, a lost or duplicated launch,
  or a start gap longer than DeadlineSec - and the Detail line says which.

  NO param() BLOCK, for the reason lib\guard-contract.ps1 spells out: PS 5.1 runs a dot-sourced param()
  block in the CALLER's scope, so a [switch]$SelfTest here would reset the -SelfTest of every caller.
#>
$__cpSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

# Every probe directory this process made, so Remove-TcRendezvousProbe with no -Probe can sweep them all:
# the ALLOCATOR remembers, because a fixture that has to remember its own cleanup eventually forgets
# ([[test-suites-leak-temp-dirs]]).
$script:TcRendezvousDirs = [Collections.Generic.List[string]]::new()

# THE DEFAULT DEADLINE IS 60 s, and it is a hang guard with a wide margin, not a tuned number. It caps the
# gap between the FIRST child starting and the LAST - process start-up and runspace construction for N
# children - which is about a second on a quiet box. It is also what a genuinely serial pool costs before
# it goes red, once: the first child waits it out and every later child gives up at once. The start gap
# measured under load when this shipped is in the commit that added this file.
$script:TcRendezvousDefaultDeadlineSec = 60

function New-TcRendezvousProbe {
  <# Makes a fresh probe directory holding rendezvous.ps1. Launch that script N times, through whatever pool
     is under test, with no arguments - it finds its directory from its own path, so no argument quoting
     can break it. Returns Dir, Script, Count and DeadlineSec. #>
  param(
    [Parameter(Mandatory)][int]$Count,
    [int]$DeadlineSec = $script:TcRendezvousDefaultDeadlineSec
  )
  if ($Count -lt 2) { throw "New-TcRendezvousProbe: a rendezvous of $Count proves nothing about concurrency" }
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('tc-rendezvous-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
  foreach ($sub in 'started', 'ended', 'result') { [void][IO.Directory]::CreateDirectory((Join-Path $dir $sub)) }
  [void]$script:TcRendezvousDirs.Add($dir)

  # A GUID, NOT THE PID, NAMES EACH CHILD. In a serial run a child's PID can be reused by the next one,
  # which would overwrite a started\ file and let the count lie.
  $child = @'
$ErrorActionPreference = 'Continue'
$count = __COUNT__
$deadlineSec = __DEADLINE__
$root = $PSScriptRoot
$me = [guid]::NewGuid().ToString('N')
[IO.File]::WriteAllText([IO.Path]::Combine($root, 'started', $me), [string]$PID)
$sw = [Diagnostics.Stopwatch]::StartNew()
$saw = 0
$why = 'deadline'
while ($true) {
  # ended\ FIRST, then started\ - the order is what makes a healthy run impossible to misread as serial.
  $finished = ([IO.Directory]::GetFiles([IO.Path]::Combine($root, 'ended'))).Length
  $saw = ([IO.Directory]::GetFiles([IO.Path]::Combine($root, 'started'))).Length
  if ($saw -ge $count) { $why = 'all'; break }
  if ($finished -gt 0) { $why = 'finished'; break }
  if ($sw.Elapsed.TotalSeconds -ge $deadlineSec) { break }
  Start-Sleep -Milliseconds 50
}
[IO.File]::WriteAllText([IO.Path]::Combine($root, 'result', $me), ('{0} {1} {2}' -f $saw, $why, [int]$sw.Elapsed.TotalMilliseconds))
[IO.File]::WriteAllText([IO.Path]::Combine($root, 'ended', $me), [string]$PID)
exit 0
'@
  $child = $child.Replace('__COUNT__', [string]$Count).Replace('__DEADLINE__', [string]$DeadlineSec)
  $script = Join-Path $dir 'rendezvous.ps1'
  [IO.File]::WriteAllText($script, $child, (New-Object Text.UTF8Encoding($false)))
  return [pscustomobject]@{ Dir = $dir; Script = $script; Count = $Count; DeadlineSec = $DeadlineSec }
}

function Get-TcRendezvousVerdict {
  <# Reads what the children reported. Ok only when exactly Count children started, exactly Count reported,
     and every one of them saw all Count alive at once. Detail carries every denominator. #>
  param([Parameter(Mandatory)]$Probe)
  $n = [int]$Probe.Count
  $started = ([IO.Directory]::GetFiles((Join-Path $Probe.Dir 'started'))).Length
  $files = [IO.Directory]::GetFiles((Join-Path $Probe.Dir 'result'))
  $sawAll = 0; $maxMs = 0
  $why = [ordered]@{ all = 0; finished = 0; deadline = 0; unreadable = 0 }
  foreach ($f in $files) {
    $parts = ([IO.File]::ReadAllText($f)).Trim() -split ' '
    if ($parts.Count -ne 3 -or -not $why.Contains($parts[1])) { $why['unreadable']++; continue }
    $why[$parts[1]]++
    if ([int]$parts[0] -ge $n -and $parts[1] -eq 'all') { $sawAll++ }
    if ([int]$parts[2] -gt $maxMs) { $maxMs = [int]$parts[2] }
  }
  $ok = ($started -eq $n) -and ($files.Length -eq $n) -and ($sawAll -eq $n)
  $detail = ('{0} of {1} children saw all {1} alive at once ({2} of {1} started, {3} of {1} reported; ' +
             'stopped on all={4} finished={5} deadline={6} unreadable={7}); longest wait {8:n1} s against a {9} s deadline') -f `
    $sawAll, $n, $started, $files.Length, $why['all'], $why['finished'], $why['deadline'], $why['unreadable'], ($maxMs / 1000.0), $Probe.DeadlineSec
  return [pscustomobject]@{
    Ok = $ok; SawAll = $sawAll; Started = $started; Reported = $files.Length; LongestWaitMs = $maxMs
    Stopped = [pscustomobject]$why; Detail = $detail
  }
}

function Remove-TcRendezvousProbe {
  <# Removes one probe's directory, or with no -Probe every directory this process made. #>
  param($Probe)
  $dirs = if ($Probe) { @([string]$Probe.Dir) } else { @($script:TcRendezvousDirs.ToArray()) }
  foreach ($d in $dirs) {
    if ($d -and (Test-Path -LiteralPath $d)) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    [void]$script:TcRendezvousDirs.Remove($d)
  }
}

if ($__cpSelfTest) {
  $ErrorActionPreference = 'Continue'
  $script:n = 0; $script:bad = 0
  function T([string]$What, [bool]$Cond, [string]$Detail = '') {
    $script:n++
    if ($Cond) { Write-Output ('  ok    ' + $What) }
    else { $script:bad++; Write-Output ('  FAIL  ' + $What + $(if ($Detail) { ' -> ' + $Detail } else { '' })) }
  }
  $PS = (Get-Command powershell).Source
  # The children are launched with plain Start-Process here, never through either pool under test, so a
  # defect in fanout-lib or parallel-run cannot make this file's own verdicts agree with it.
  function Start-RdvChild($Probe) {
    $p = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Probe.Script + '"')) -PassThru -NoNewWindow
    $null = $p.Handle
    return $p
  }
  # A HANG GUARD, not a speed bar: nothing below is asserted on time, and every child exits on its own
  # deadline long before this.
  function Wait-RdvChildren($Procs) { foreach ($p in @($Procs)) { [void]$p.WaitForExit(180000) } }

  try {
    # The three groups of children launched together start FIRST and run while the serial case below does
    # its work - they are independent probe directories, and waiting for each in turn only cost wall time.
    # MUST FIRE fixture - a pool that LOST A JOB: three of four launched together can never see four.
    $lost = New-TcRendezvousProbe -Count 4 -DeadlineSec 2
    # MUST FIRE fixture - a pool that launched a job TWICE: five children against a rendezvous of four all
    # see at least four, so only the started count can catch it.
    $dup = New-TcRendezvousProbe -Count 4
    # CLEAN TWIN fixture - four launched together, on the default deadline.
    $good = New-TcRendezvousProbe -Count 4
    $together = [Collections.Generic.List[object]]::new()
    foreach ($i in 1..3) { $together.Add((Start-RdvChild $lost)) }
    foreach ($i in 1..5) { $together.Add((Start-RdvChild $dup)) }
    foreach ($i in 1..4) { $together.Add((Start-RdvChild $good)) }

    # MUST FIRE - THE ONE THIS EXISTS FOR. Four children run ONE AT A TIME, which is what a pool of width 1
    # does. The deadline is short because no deadline can rescue a serial run: the first child is alone
    # however long it waits.
    $ser = New-TcRendezvousProbe -Count 4 -DeadlineSec 2
    foreach ($i in 1..4) { $p = Start-RdvChild $ser; Wait-RdvChildren @($p) }
    $sv = Get-TcRendezvousVerdict -Probe $ser
    T 'MUST FIRE  four children run ONE AT A TIME are NOT reported concurrent - a pool of width 1 goes red however quiet the box is' (-not $sv.Ok -and $sv.SawAll -lt 4) $sv.Detail
    # Exact, and deterministic: the first waits out its deadline alone, the middle two see it finished and
    # stop at once, and the LAST sees four started files left by dead peers and says `all` - which is why
    # one child's `all` is never the verdict (see the header).
    T 'a serial run costs ONE deadline, not four - first child deadline, middle two stop on a finished peer, last one alone says all' `
      ($sv.Stopped.deadline -eq 1 -and $sv.Stopped.finished -eq 2 -and $sv.Stopped.all -eq 1) $sv.Detail

    Wait-RdvChildren $together
    $lv = Get-TcRendezvousVerdict -Probe $lost
    T 'MUST FIRE  three of four children launched together (a pool that lost a job) are NOT reported concurrent' (-not $lv.Ok) $lv.Detail
    $dv = Get-TcRendezvousVerdict -Probe $dup
    T 'MUST FIRE  five children against a rendezvous of four (a job launched twice) are NOT a pass' (-not $dv.Ok) $dv.Detail

    # MUST FIRE - nothing launched at all must not read as a pass. An empty result directory is the
    # "no findings" / "never ran" shape this estate keeps rediscovering.
    $none = New-TcRendezvousProbe -Count 4
    $nv = Get-TcRendezvousVerdict -Probe $none
    T 'MUST FIRE  a probe whose children never ran is NOT a pass' (-not $nv.Ok) $nv.Detail

    $gv = Get-TcRendezvousVerdict -Probe $good
    T 'CLEAN TWIN four children launched together are reported concurrent, every one having seen all four' ($gv.Ok -and $gv.SawAll -eq 4) $gv.Detail
    Write-Output ('  info  ' + $gv.Detail)

    $d = $good.Dir
    Remove-TcRendezvousProbe -Probe $good
    T 'removing a probe deletes its directory' (-not (Test-Path -LiteralPath $d)) $d
  } finally {
    Remove-TcRendezvousProbe
  }

  Write-Output ('SELFTEST: {0}/{1} pass' -f ($script:n - $script:bad), $script:n)
  Write-Output ('CONCURRENCY-PROBE-COMPLETE cases={0} failed={1}' -f $script:n, $script:bad)
  if ($script:bad -gt 0) { exit 1 }
  exit 0
}
