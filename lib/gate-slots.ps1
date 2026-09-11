<#
  gate-slots.ps1 - A MACHINE-WIDE budget of gate workers, shared by every run-gates on this box.

  Self-test:   powershell -File lib\gate-slots.ps1 -SelfTest

  WHY (2026-09-11, Brad: "The cap needs to be fixed at 10 total"). run-gates sized its pool as if it owned
  the machine - min(16, processors - 2) - and every session pushes through it. Measured that morning on the
  32-processor box: SEVEN run-gates live at once, 112 gate workers, CPU pinned at 100% for over half an
  hour, and each of three identical loaded runs took about 390s of wall. The same gates take 51s alone at
  width 16 and 372s SERIALLY (design\MEASURE-gate-cost-2026-09-09.md), so the pile-up was slower than no
  parallelism at all. A per-run cap cannot fix that: seven runs at 8 each is still 56 workers. The number
  that has to be bounded is the TOTAL.

  HOW. $TcGateSlotTotal named system mutexes, one per worker slot. A run takes as many free slots as it
  wants, up to the total, and sizes its pool to what it got. When every slot is held it WAITS for one, and
  says so, rather than running over the budget. So the total across the machine never exceeds the budget,
  and a lone run still gets the whole of it.

  MUTEXES, NOT A SEMAPHORE, AND THAT IS THE CRASH CASE. A Windows semaphore is not released when its
  holder dies: a gate run killed by Ctrl+C would leak its slots for as long as any other process kept the
  semaphore open, and a queue of waiting runs keeps it open forever. A mutex whose owner dies comes back
  ABANDONED, and the next WaitOne acquires it - the same property ingredient-resolutions.ps1 relies on for
  its write lock. A killed run therefore frees its slots the moment it is gone.

  ONE THREAD. A mutex belongs to the thread that took it, and it is RE-ENTRANT for that thread: a second
  Enter on the same thread would re-acquire the slots it already holds and count them twice. run-gates
  enters once, dispatches, and exits on the same thread. The self-test puts every competing holder in its
  own process for exactly this reason - an in-process fixture would pass while proving nothing.

  A NAMED MUTEX NOBODY ELSE HAS OPEN IS DESTROYED WHEN ITS LAST HANDLE CLOSES, and that hides a bug from
  any fixture that tests one process at a time: a release that only Disposes "recovers", because the object
  vanishes and the next open makes a fresh one. It stops recovering the moment another process is WAITING on
  the slot and holding its own handle - exactly the production shape, a queue of pushes. So the last case
  below keeps a second process's handle open across the release.

  AN ABANDONED MUTEX DOES NOT THROW HERE. Measured 2026-09-11 on this box's PS 5.1: a holder process took a
  mutex and was killed, and the next WaitOne(0) returned True with no exception at all. The typed catch in
  Enter-TcGateSlots is therefore not reached on this runtime; it stays because the documented .NET contract
  is to throw, and treating that as acquired is the only safe reading. ingredient-resolutions.ps1 carries
  the same catch for the same reason.

  MUTATION-PROBED 2026-09-11, single mutants from a temp mirror, original verified byte-identical by md5
  afterwards. Round 1, five mutants, killed 2. Two survivors were one FIXTURE defect: the holder process
  announced itself ready whether or not it had taken its slots, so "another process takes all of them" was
  asserted against a holder that had quietly timed out; it now reports how many it HOLDS. The third was a
  clamp of Want to Total, an equivalent mutant - the loop already stops at Total - so the clamp was removed
  rather than tested. Round 2 kept surviving release-noop by the handle-destruction effect above, which is
  why the waiter case exists. Round 3, six mutants, killed 5. The survivor treats an abandoned slot as NOT
  taken, and it is equivalent on this runtime for the reason in the paragraph above: the catch it edits is
  never reached.

  NO param() BLOCK, for the reason lib\guard-contract.ps1 spells out: PS 5.1 runs a dot-sourced param()
  block in the CALLER's scope, so declaring [switch]$SelfTest here would reset the caller's.
#>
$__gsSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

# THE BUDGET. Brad's ruling, 2026-09-11: a fixed 10 across the machine. NOT a sweep and not derived from a
# width curve - the measured curve (MEASURE-gate-cost-2026-09-09) has points at 16, 24 and 32 only, so what
# a lone run costs at 10 is unmeasured here. Registered in docs\CONTROL-CONSTANTS.md.
$script:TcGateSlotTotal = 10
$script:TcGateSlotPrefix = 'Global\tc-gate-worker-slot-'

function Enter-TcGateSlots {
  <# Returns Mutexes (the held slots - pass the whole object to Exit-TcGateSlots), Count, WaitedMs and
     TimedOut. Count is between 1 and min(Want, Total) on success. On TimedOut, Count is 0 and nothing is
     held: the caller must REFUSE rather than run, because running anyway is the pile-up this exists to stop.
     OnWait runs ONCE, the first time every slot is found taken, so the wait is spoken rather than silent.

     -Exact is ALL OR NOTHING, for deliberate load (ops\cpu-load.ps1): a load test granted 3 of the 8 cores it
     asked for would record a condition it never ran under. Whatever a pass took short of Want is RELEASED
     before the wait, so an exact waiter never squats on slots a gate run could be using. A want above the
     total is granted the total, because an exact want the machine can never satisfy would only time out. #>
  param(
    [int]$Want,
    [int]$Total = $script:TcGateSlotTotal,
    [string]$Prefix = $script:TcGateSlotPrefix,
    [int]$WaitSec = 1200,
    [int]$PollMs = 500,
    [scriptblock]$OnWait = $null,
    [switch]$Exact
  )
  if ($Total -lt 1) { $Total = 1 }
  if ($Want -lt 1) { $Want = 1 }
  if ($Exact -and $Want -gt $Total) { $Want = $Total }
  $held = [Collections.Generic.List[object]]::new()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $spoke = $false
  while ($true) {
    # The loop stops at Total, so a want above the total is granted the total without a separate clamp.
    for ($i = 0; ($i -lt $Total) -and ($held.Count -lt $Want); $i++) {
      $mx = New-Object System.Threading.Mutex($false, ($Prefix + $i))
      $got = $false
      try { $got = $mx.WaitOne(0) }
      catch [System.Threading.AbandonedMutexException] { $got = $true }   # a killed run, not a wedge
      if ($got) { $held.Add($mx) } else { $mx.Dispose() }
    }
    if ($held.Count -ge $Want) { break }
    if (-not $Exact -and $held.Count -ge 1) { break }
    if ($Exact -and $held.Count) {
      foreach ($h in $held) { try { $h.ReleaseMutex() } catch { }; try { $h.Dispose() } catch { } }
      $held.Clear()
    }
    if ($sw.Elapsed.TotalSeconds -ge $WaitSec) {
      return [pscustomobject]@{ Mutexes = @(); Count = 0; WaitedMs = $sw.Elapsed.TotalMilliseconds; TimedOut = $true }
    }
    # OUT-DEFAULT, NOT THE OUTPUT STREAM (2026-09-11). Anything OnWait writes would otherwise join this
    # function's return, so `$lease = Enter-TcGateSlots` became an ARRAY of the message and the lease: the
    # message never printed, and `$lease.Count` read the array's length (2) instead of the slots held, so a
    # run-gates that had waited for one slot sized its pool at 2. Found by cpu-load.ps1's self-test.
    if (-not $spoke -and $OnWait) { & $OnWait | Out-Default; $spoke = $true }
    Start-Sleep -Milliseconds $PollMs
  }
  return [pscustomobject]@{ Mutexes = $held.ToArray(); Count = $held.Count; WaitedMs = $sw.Elapsed.TotalMilliseconds; TimedOut = $false }
}

function Exit-TcGateSlots {
  param([object]$Lease)
  if (-not $Lease) { return }
  foreach ($mx in @($Lease.Mutexes)) {
    try { $mx.ReleaseMutex() } catch { }
    try { $mx.Dispose() } catch { }
  }
}

if ($__gsSelfTest) {
  $f = 0; $cases = 0
  function T($m, $cond, $got) { $script:cases++; if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }
  $PS = (Get-Command powershell).Source
  # Local\ and a fresh guid per run: the fixtures must never touch the real Global\ slots, because this
  # self-test runs INSIDE a run-gates that is holding them.
  $prefix = 'Local\tc-gate-slot-selftest-' + [guid]::NewGuid().ToString('N') + '-'
  $tmp = Join-Path $env:TEMP ('tc-gate-slots-' + [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Force $tmp
  $holders = [Collections.Generic.List[object]]::new()

  # A HOLDER IS ANOTHER PROCESS, for the one-thread reason in the header. It writes a waiting marker, tries
  # slots 0..N-1 of the prefix with up to WaitMs each, writes HOW MANY IT HOLDS to its ready file, and keeps
  # them until a release file appears (or 60s pass). The count is the point: a holder that merely says
  # "ready" passes every "another process can take them" case whether or not it took anything.
  function Start-Holder([string]$Pfx, [int]$N, [string]$Name, [int]$WaitMs = 2000, [switch]$ReturnWhileWaiting) {
    $waiting = Join-Path $tmp ($Name + '.waiting'); $ready = Join-Path $tmp ($Name + '.ready'); $release = Join-Path $tmp ($Name + '.release')
    $body = @'
$ms = @()
$handles = @()
foreach ($i in 0..(__N__ - 1)) { $handles += New-Object System.Threading.Mutex($false, ('__PFX__' + $i)) }
[IO.File]::WriteAllText('__WAITING__', 'open')
foreach ($m in $handles) {
  $got = $false
  try { $got = $m.WaitOne(__WAITMS__) } catch [System.Threading.AbandonedMutexException] { $got = $true }
  if ($got) { $ms += $m }
}
[IO.File]::WriteAllText('__READY__', [string]$ms.Count)
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath '__RELEASE__') -and $sw.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 50 }
foreach ($m in $ms) { try { $m.ReleaseMutex() } catch { } }
'@
    $body = $body.Replace('__N__', [string]$N).Replace('__PFX__', $Pfx).Replace('__WAITMS__', [string]$WaitMs)
    $body = $body.Replace('__WAITING__', $waiting).Replace('__READY__', $ready).Replace('__RELEASE__', $release)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $p = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru -WindowStyle Hidden
    $script:holders.Add($p)
    $h = [pscustomobject]@{ Proc = $p; Held = -1; Waiting = $false; ReadyFile = $ready; Release = $release }
    # WAIT ON THE CONDITION, NOT A SLEEP: a holder that never reported fails loudly as Held = -1, instead of
    # letting the case below pass against slots nobody holds.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $mark = if ($ReturnWhileWaiting) { $waiting } else { $ready }
    while (-not (Test-Path -LiteralPath $mark) -and $sw.Elapsed.TotalSeconds -lt 30 -and -not $p.HasExited) { Start-Sleep -Milliseconds 50 }
    $h.Waiting = (Test-Path -LiteralPath $waiting)
    if (-not $ReturnWhileWaiting) { $h.Held = Read-HolderCount $ready 1 }
    $h
  }
  function Read-HolderCount([string]$ReadyFile, [int]$WithinSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $WithinSec) {
      if (Test-Path -LiteralPath $ReadyFile) {
        try { return [int]([IO.File]::ReadAllText($ReadyFile).Trim()) } catch { }
      }
      Start-Sleep -Milliseconds 50
    }
    return -1
  }

  try {
    # MUST FIRE - the budget holds against another process.
    $pA = $prefix + 'a-'
    $h = Start-Holder $pA 3 'a'
    $l = Enter-TcGateSlots -Want 3 -Total 3 -Prefix $pA -WaitSec 1 -PollMs 100
    T 'MUST FIRE  THE ONE THIS EXISTS FOR - with every slot held by another gate run, a new run gets NONE and times out rather than running over the machine-wide total' `
      ($h.Held -eq 3 -and $l.TimedOut -and $l.Count -eq 0) ("holderHeld={0} timedOut={1} count={2}" -f $h.Held, $l.TimedOut, $l.Count)
    Exit-TcGateSlots $l
    [IO.File]::WriteAllText($h.Release, 'go'); [void]$h.Proc.WaitForExit(10000)

    $pB = $prefix + 'b-'
    $h = Start-Holder $pB 2 'b'
    $l = Enter-TcGateSlots -Want 3 -Total 3 -Prefix $pB -WaitSec 1 -PollMs 100
    T 'MUST FIRE  with 2 of 3 slots held elsewhere, a run that wants 3 gets exactly the 1 that is left - its width is the share, not its wish' `
      ($h.Held -eq 2 -and -not $l.TimedOut -and $l.Count -eq 1) ("holderHeld={0} count={1}" -f $h.Held, $l.Count)
    Exit-TcGateSlots $l
    [IO.File]::WriteAllText($h.Release, 'go'); [void]$h.Proc.WaitForExit(10000)

    # MUST NOT FIRE - legal inputs.
    $pC = $prefix + 'c-'
    $script:spokeC = 0
    $l = Enter-TcGateSlots -Want 3 -Total 3 -Prefix $pC -WaitSec 5 -PollMs 100 -OnWait { $script:spokeC++ }
    T 'MUST NOT FIRE  a lone run on an idle machine gets its whole want at once and never announces a wait' `
      (-not $l.TimedOut -and $l.Count -eq 3 -and $script:spokeC -eq 0) ("count={0} spoke={1} waited={2:N0}ms" -f $l.Count, $script:spokeC, $l.WaitedMs)
    Exit-TcGateSlots $l
    $pD = $prefix + 'd-'
    $big = Enter-TcGateSlots -Want 50 -Total 4 -Prefix $pD -WaitSec 5 -PollMs 100
    $cntBig = $big.Count
    Exit-TcGateSlots $big
    $zero = Enter-TcGateSlots -Want 0 -Total 4 -Prefix $pD -WaitSec 5 -PollMs 100
    $cntZero = $zero.Count
    Exit-TcGateSlots $zero
    T 'MUST NOT FIRE  a want above the total is granted the total and no more, and a want of 0 still runs at width 1 rather than refusing' `
      ($cntBig -eq 4 -and $cntZero -eq 1) ("want50={0} want0={1}" -f $cntBig, $cntZero)

    # CLEAN TWIN - adjacent behaviour that still works.
    $pE = $prefix + 'e-'
    $h = Start-Holder $pE 3 'e'
    $killedHeld = $h.Held
    try { $h.Proc.Kill() } catch { }
    [void]$h.Proc.WaitForExit(10000)
    $script:spokeE = 0
    $l = Enter-TcGateSlots -Want 3 -Total 3 -Prefix $pE -WaitSec 5 -PollMs 100 -OnWait { $script:spokeE++ }
    $recovered = $l.Count
    Exit-TcGateSlots $l
    T 'CLEAN TWIN a gate run KILLED while holding every slot frees them all AT ONCE - an abandoned mutex is re-acquired on the first try, with no wait announced, which a semaphore would never give back' `
      ($killedHeld -eq 3 -and $recovered -eq 3 -and $script:spokeE -eq 0) ("killedHeld={0} recovered={1} spoke={2}" -f $killedHeld, $recovered, $script:spokeE)

    $pF = $prefix + 'f-'
    $h = Start-Holder $pF 3 'f'
    $script:spokeF = 0
    $rel = $h.Release
    $releaser = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-Command', ("Start-Sleep -Milliseconds 1500; [IO.File]::WriteAllText('{0}', 'go')" -f $rel)) -PassThru -WindowStyle Hidden
    $holders.Add($releaser)
    $l = Enter-TcGateSlots -Want 3 -Total 3 -Prefix $pF -WaitSec 30 -PollMs 100 -OnWait { $script:spokeF++ }
    T 'CLEAN TWIN a run that found every slot taken announces the wait ONCE, then proceeds as soon as the holder finishes, with at least one slot' `
      ($h.Held -eq 3 -and -not $l.TimedOut -and $l.Count -ge 1 -and $script:spokeF -eq 1 -and $l.WaitedMs -ge 1000) ("holderHeld={0} count={1} spoke={2} waited={3:N0}ms" -f $h.Held, $l.Count, $script:spokeF, $l.WaitedMs)
    Exit-TcGateSlots $l

    # THE CALLERS' SHAPE: run-gates and cpu-load both pass an OnWait that WRITES a line. That line must reach
    # the console and must NOT join the returned lease, or the lease is an array and .Count is its length.
    $pJ = $prefix + 'j-'
    $h = Start-Holder $pJ 3 'j'
    $relJ = $h.Release
    $releaserJ = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-Command', ("Start-Sleep -Milliseconds 1200; [IO.File]::WriteAllText('{0}', 'go')" -f $relJ)) -PassThru -WindowStyle Hidden
    $holders.Add($releaserJ)
    $lJ = Enter-TcGateSlots -Want 1 -Total 3 -Prefix $pJ -WaitSec 30 -PollMs 100 -OnWait { Write-Output '  (fixture) waiting line from OnWait' }
    $isArray = $lJ -is [array]
    $grant = if ($isArray) { -1 } else { $lJ.Count }
    T 'MUST FIRE  an OnWait that WRITES output does not pollute the lease - Enter returns ONE object whose Count is the slots held, not an array of the message and the lease' `
      ($h.Held -eq 3 -and -not $isArray -and $grant -eq 1) ("holderHeld={0} returnedArray={1} count={2}" -f $h.Held, $isArray, $(if ($isArray) { @($lJ).Count } else { $lJ.Count }))
    foreach ($x in @($lJ)) { if ($x -isnot [string]) { Exit-TcGateSlots $x } }

    $pG = $prefix + 'g-'
    $l = Enter-TcGateSlots -Want 2 -Total 2 -Prefix $pG -WaitSec 5 -PollMs 100
    Exit-TcGateSlots $l
    $h = Start-Holder $pG 2 'g'
    T 'CLEAN TWIN slots released by Exit-TcGateSlots are really free - another process takes all of them straight away' `
      ($l.Count -eq 2 -and $h.Held -eq 2) ("first={0} otherProcessHeld={1}" -f $l.Count, $h.Held)
    [IO.File]::WriteAllText($h.Release, 'go'); [void]$h.Proc.WaitForExit(10000)

    # THE PRODUCTION SHAPE: a second push is already WAITING, holding its own handles, when this run exits.
    # Its handles keep the mutex objects alive, so only a real ReleaseMutex hands the slots over.
    $pH = $prefix + 'h-'
    $l = Enter-TcGateSlots -Want 2 -Total 2 -Prefix $pH -WaitSec 5 -PollMs 100
    $w = Start-Holder $pH 2 'h' -WaitMs 8000 -ReturnWhileWaiting
    Start-Sleep -Milliseconds 300
    Exit-TcGateSlots $l
    $waiterHeld = Read-HolderCount $w.ReadyFile 25
    T 'CLEAN TWIN a run already WAITING in another process, with its handles open, gets every slot the moment this run exits its lease' `
      ($l.Count -eq 2 -and $w.Waiting -and $waiterHeld -eq 2) ("first={0} waiterWasWaiting={1} waiterHeld={2}" -f $l.Count, $w.Waiting, $waiterHeld)
    [IO.File]::WriteAllText($w.Release, 'go'); [void]$w.Proc.WaitForExit(10000)

    # -EXACT, the all-or-nothing request ops\cpu-load.ps1 makes for deliberate load.
    $pI = $prefix + 'i-'
    $h = Start-Holder $pI 2 'i'
    $l = Enter-TcGateSlots -Want 3 -Total 3 -Prefix $pI -Exact -WaitSec 1 -PollMs 100
    T 'MUST FIRE  an EXACT request for 3 cores with 2 held elsewhere gets NONE and times out - a load test granted 1 of 3 would record a condition it never ran under' `
      ($h.Held -eq 2 -and $l.TimedOut -and $l.Count -eq 0) ("holderHeld={0} timedOut={1} count={2}" -f $h.Held, $l.TimedOut, $l.Count)
    Exit-TcGateSlots $l
    # The exact waiter runs in ANOTHER process, so this one can test whether it squats on the free slot.
    $waitOut = Join-Path $tmp 'i-waiter.out'
    $wBody = ". '__LIB__'; `$r = Enter-TcGateSlots -Want 3 -Total 3 -Prefix '__PFX__' -Exact -WaitSec 30 -PollMs 100; [IO.File]::WriteAllText('__OUT__', [string]`$r.Count); Start-Sleep -Milliseconds 300; Exit-TcGateSlots `$r"
    $wBody = $wBody.Replace('__LIB__', $PSCommandPath).Replace('__PFX__', $pI).Replace('__OUT__', $waitOut)
    $wEnc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wBody))
    $waiter = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $wEnc) -PassThru -WindowStyle Hidden
    $holders.Add($waiter)
    Start-Sleep -Milliseconds 1500
    # A second holder tries all three slots for 1.5s each: 0 and 1 are held, so only slot 2 can be taken - and
    # only if the exact waiter lets go of it between passes.
    $h2 = Start-Holder $pI 3 'i2' -WaitMs 1500
    T 'MUST NOT FIRE  an EXACT waiter does not squat: while it waits for all 3, another process can still take the one free slot' `
      ($h2.Held -eq 1 -and -not $waiter.HasExited) ("otherProcessHeld={0} waiterStillWaiting={1}" -f $h2.Held, (-not $waiter.HasExited))
    [IO.File]::WriteAllText($h.Release, 'go'); [IO.File]::WriteAllText($h2.Release, 'go')
    [void]$h.Proc.WaitForExit(10000); [void]$h2.Proc.WaitForExit(10000)
    $waiterGot = Read-HolderCount $waitOut 25
    T 'CLEAN TWIN an EXACT waiter gets all 3 the moment every slot is free, and proceeds' `
      ($waiterGot -eq 3) ("waiterGot={0}" -f $waiterGot)
    [void]$waiter.WaitForExit(10000)
  } finally {
    foreach ($p in $holders) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("SELF-TEST PASS: {0} cases - 4 must-fire led by a full machine refusing a new run, 3 must-not-fire led by a lone run getting its whole want, and 5 clean twins led by a killed run freeing its slots at once" -f $cases)
  exit 0
}
