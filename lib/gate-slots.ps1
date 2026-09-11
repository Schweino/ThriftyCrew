<#
  gate-slots.ps1 - A MACHINE-WIDE budget of gate workers, shared by every run-gates on this box and handed out in
  ARRIVAL ORDER.

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

  THE QUEUE (2026-09-11, later the same day). The budget held and the machine starved behind it. At 16:39, 27
  run-gates were live, 8 of them held all 10 slots at width 1 or 2, and 19 held none; 24 kept pre-push logs
  between 15:08 and 16:35 end in a refusal after the full 1,200 s. design\MEASURE-gate-slot-starvation-2026-09-11.md
  has every number. Three of the causes were in this file:
    1. NOT FIFO. Every waiter polled WaitOne(0) every 500 ms and whoever polled first after a release won. A probe
       of this function - one private slot, 8 waiter processes arriving 400 ms apart, 3 rounds - served the FIRST
       arrival 6th, 8th and 5th, with 19, 13 and 15 of 28 pairs out of order, where a random order averages 14. A
       run that had waited 19 minutes was no likelier to be served than one that arrived that second.
    2. A FIXED DEADLINE. 1,200 s of total waiting refused a run whose queue was still moving.
    3. THE TOP-UP RACED THE QUEUE. Add-TcGateSlots took a freed slot for a run that already held one while runs
       holding nothing waited.

  So a waiter that finds no free slot takes a TICKET: a file in a queue directory named for its budget, whose name
  is its arrival time, plus a named mutex it holds while it waits. Only the OLDEST LIVE ticket may take slots.
    - LIVENESS IS THE MUTEX, NEVER THE FILE. A killed waiter abandons its ticket mutex, the next probe takes it, and
      the file is swept. The mutex is taken BEFORE the file is written, so no probe can see a ticket whose owner is
      still creating it.
    - THE DEADLINE IS "THE QUEUE STOPPED MOVING". A waiter refuses only when the count of live tickets ahead of it
      has not fallen for WaitSec (Step-TcGateQueueWait). A wedged head still ends in a loud refusal; a long queue
      that keeps moving does not.
    - A RUN HOLDING SLOTS DOES NOT TOP UP while any ticket is live. The freed slot is the queue's.
    - DELIBERATE LOAD (-Exact) NEVER QUEUES AND NEVER JUMPS THE QUEUE. It takes nothing while any ticket is live and
      keeps its fixed deadline: gates go first, and a load test waits for an idle machine or times out.
    - ABANDON. -Abandon is called every AbandonEverySec while waiting, and a non-empty answer ends the wait holding
      nothing, with the answer in .Abandoned. run-gates uses it to stop waiting for a push that can no longer land
      (lib\push-landable.ps1).
  NOT HANDLED: a waiter that is alive but frozen keeps its ticket. Everyone behind it stops moving and refuses after
  WaitSec, loudly, which is the wedge reading and never a pass.

  MUTEXES, NOT A SEMAPHORE, AND THAT IS THE CRASH CASE. A Windows semaphore is not released when its
  holder dies: a gate run killed by Ctrl+C would leak its slots for as long as any other process kept the
  semaphore open, and a queue of waiting runs keeps it open forever. A mutex whose owner dies comes back
  ABANDONED, and the next WaitOne acquires it - the same property ingredient-resolutions.ps1 relies on for
  its write lock. A killed run therefore frees its slots the moment it is gone.

  ONE THREAD. A mutex belongs to the thread that took it, and it is RE-ENTRANT for that thread: a second
  Enter on the same thread would re-acquire the slots it already holds and count them twice. run-gates
  enters once, dispatches, and exits on the same thread. The self-test puts every competing holder in its
  own process for exactly this reason - an in-process fixture would pass while proving nothing. A ticket's
  mutex is its thread's too, which is why a probe never touches the ticket of the thread probing.

  A NAMED MUTEX NOBODY ELSE HAS OPEN IS DESTROYED WHEN ITS LAST HANDLE CLOSES, and that hides a bug from
  any fixture that tests one process at a time: a release that only Disposes "recovers", because the object
  vanishes and the next open makes a fresh one. It stops recovering the moment another process is WAITING on
  the slot and holding its own handle - exactly the production shape, a queue of pushes. So the last case
  below keeps a second process's handle open across the release. For a ticket the same effect is harmless: a
  ticket whose owner is gone reads as dead whether its mutex comes back abandoned or is created afresh.

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
  QUEUE-MUTANT 2026-09-11: one mutant from a temp mirror, the original verified byte-identical by md5 afterwards -
  Get-TcGateQueueAhead answering 0 always, which is the pre-queue behaviour of Enter and Add (tickets still written,
  never honoured, nothing swept). It went red in 5 of the 29 cases and in exactly the five queue cases: arrival order
  (the later, faster-polling waiter took the slot), the top-up taking a queued run's slot, the queued run then never
  being served, the dead ticket never swept, and deliberate load jumping the queue. The other 24 passed, so the
  mutant is confined to what these cases claim.

  SCOPE OF A CLEAN REPORT: the self-test proves on this machine, with every competitor in its own process, that the
  budget holds, that the earlier of two waiters is served first, that a holder does not top up past a queued run,
  that a killed waiter's ticket is swept, that deliberate load does not jump the queue, that an abandon check ends a
  wait, and the stall rule over synthetic time. It proves nothing about how fast a real queue drains.

  NO param() BLOCK, for the reason lib\guard-contract.ps1 spells out: PS 5.1 runs a dot-sourced param()
  block in the CALLER's scope, so declaring [switch]$SelfTest here would reset the caller's.
#>
$__gsSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

# THE BUDGET. Brad's ruling, 2026-09-11: a fixed 10 across the machine. NOT a sweep and not derived from a
# width curve - the measured curve (MEASURE-gate-cost-2026-09-09) has points at 16, 24 and 32 only, so what
# a lone run costs at 10 is unmeasured here. Registered in docs\CONTROL-CONSTANTS.md.
$script:TcGateSlotTotal = 10
$script:TcGateSlotPrefix = 'Global\tc-gate-worker-slot-'
# WHERE THE QUEUE LIVES. Per user, not per checkout: the slots are machine-wide Global\ mutexes and every session on
# this box runs as one user, so every run-gates - any worktree, any clone - must see one queue. Not %TEMP%: this is a
# name deliberately shared across runs, so it stays fixed, and the self-test points its own at a per-run directory.
$script:TcGateQueueRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ThriftyCrew\gate-slot-queue'

function Get-TcGateQueueDir {
  <# The queue directory for one budget, named from its mutex prefix, so a private test budget has a private queue. #>
  param([string]$Prefix, [string]$Root = $script:TcGateQueueRoot)
  $leaf = ($Prefix -replace '[^A-Za-z0-9-]', '_').Trim('_')
  if (-not $leaf) { $leaf = 'default' }
  return (Join-Path $Root $leaf)
}

function Test-TcGateTicketLive {
  <# A ticket is live while its mutex is held. One that anybody can take has no owner: killed (abandoned), or gone
     without removing its file (the name no longer exists, so a fresh mutex is created). A probe that cannot look
     answers LIVE: sweeping on a guess could hand a slot past a real waiter. #>
  param([string]$Prefix, [string]$Name)
  $mx = $null
  try {
    $mx = New-Object System.Threading.Mutex($false, ($Prefix + 'q-' + $Name))
    $got = $false
    try { $got = $mx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if ($got) { try { $mx.ReleaseMutex() } catch { } }
    return (-not $got)
  } catch {
    return $true
  } finally {
    if ($mx) { $mx.Dispose() }
  }
}

function Get-TcGateQueueAhead {
  <# How many LIVE tickets sort before $Before - all of them when $Before is empty. -Sweep probes each one and deletes
     the file of a dead one; without it the files are only counted, which is what a waiter does between sweeps. #>
  param([string]$Dir, [string]$Prefix, [string]$Before = '', [switch]$Sweep)
  if (-not $Dir -or -not [IO.Directory]::Exists($Dir)) { return 0 }
  $files = @()
  try { $files = [IO.Directory]::GetFiles($Dir, '*.ticket') } catch { return 0 }
  $n = 0
  foreach ($f in $files) {
    $nm = [IO.Path]::GetFileNameWithoutExtension($f)
    if ($Before -and [string]::CompareOrdinal($nm, $Before) -ge 0) { continue }
    if ($Sweep -and -not (Test-TcGateTicketLive -Prefix $Prefix -Name $nm)) {
      try { [IO.File]::Delete($f) } catch { }
      continue
    }
    $n++
  }
  return $n
}

function New-TcGateTicket {
  <# Joins the queue: the mutex first, then the file, so no probe can see the file before its owner holds it. The name
     is the arrival time in ticks, so an ordinal sort of the names is arrival order. #>
  param([string]$Prefix, [string]$Dir)
  $null = [IO.Directory]::CreateDirectory($Dir)
  $name = '{0:D19}-{1}-{2}' -f [DateTime]::UtcNow.Ticks, $PID, [guid]::NewGuid().ToString('N').Substring(0, 8)
  $mx = New-Object System.Threading.Mutex($false, ($Prefix + 'q-' + $name))
  $got = $false
  try { $got = $mx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) { $mx.Dispose(); throw ('New-TcGateTicket: a brand-new ticket mutex was already held: ' + $name) }
  $path = Join-Path $Dir ($name + '.ticket')
  [IO.File]::WriteAllText($path, [string]$PID)
  return [pscustomobject]@{ Name = $name; Path = $path; Mutex = $mx }
}

function Remove-TcGateTicket {
  <# Leaves the queue. Safe with $null, and safe twice. #>
  param([object]$Ticket)
  if (-not $Ticket -or -not $Ticket.Mutex) { return }
  try { [IO.File]::Delete($Ticket.Path) } catch { }
  try { $Ticket.Mutex.ReleaseMutex() } catch { }
  try { $Ticket.Mutex.Dispose() } catch { }
  $Ticket.Mutex = $null
}

function New-TcGateQueueState { return [pscustomobject]@{ Best = $null; ProgressAt = 0.0 } }

function Step-TcGateQueueWait {
  <# THE STALL RULE, kept apart from the clock so its fixtures drive it with synthetic time. Progress is the count of
     live tickets ahead FALLING below the lowest seen so far. $true once nothing has moved for WaitSec. #>
  param([object]$State, [int]$Ahead, [double]$NowMs, [int]$WaitSec)
  if ($null -eq $State.Best -or $Ahead -lt [int]$State.Best) { $State.Best = $Ahead; $State.ProgressAt = $NowMs }
  return (($NowMs - [double]$State.ProgressAt) -ge ($WaitSec * 1000.0))
}

function New-TcGateLease {
  param($Held, $Idx, [int]$Count, [double]$WaitedMs, [bool]$TimedOut, [string]$Abandoned, [string]$Prefix, [int]$Total, [string]$Dir, [int]$Ahead)
  return [pscustomobject]@{ Mutexes = $Held; Indices = $Idx; Count = $Count; WaitedMs = $WaitedMs; TimedOut = $TimedOut; Abandoned = $Abandoned; Prefix = $Prefix; Total = $Total; QueueDir = $Dir; Ahead = $Ahead }
}

function Enter-TcGateSlots {
  <# Returns Mutexes (the held slots - pass the whole object to Exit-TcGateSlots), Count, WaitedMs, TimedOut, Abandoned
     and Ahead. Count is between 1 and min(Want, Total) on success. On TimedOut or Abandoned, Count is 0 and nothing is
     held: the caller must REFUSE rather than run, because running anyway is the pile-up this exists to stop.
     OnWait runs ONCE, the first time the run has to wait, and is handed the number of runs queued ahead of it.

     A run that waits QUEUES (the header's THE QUEUE): slots go to the oldest live ticket first, and WaitSec bounds how
     long the queue may go without moving, not the whole wait.

     -Exact is ALL OR NOTHING, for deliberate load (ops\cpu-load.ps1): a load test granted 3 of the 8 cores it
     asked for would record a condition it never ran under. Whatever a pass took short of Want is RELEASED
     before the wait, so an exact waiter never squats on slots a gate run could be using. A want above the
     total is granted the total, because an exact want the machine can never satisfy would only time out. An exact
     request never queues, takes nothing while a gate run is queued, and WaitSec is its whole wait. #>
  param(
    [int]$Want,
    [int]$Total = $script:TcGateSlotTotal,
    [string]$Prefix = $script:TcGateSlotPrefix,
    [int]$WaitSec = 1200,
    [int]$PollMs = 500,
    [scriptblock]$OnWait = $null,
    [switch]$Exact,
    [string]$QueueRoot = $script:TcGateQueueRoot,
    [scriptblock]$Abandon = $null,
    [int]$AbandonEverySec = 60,
    [int]$SweepEverySec = 5
  )
  if ($Total -lt 1) { $Total = 1 }
  if ($Want -lt 1) { $Want = 1 }
  if ($Exact -and $Want -gt $Total) { $Want = $Total }
  $dir = Get-TcGateQueueDir -Prefix $Prefix -Root $QueueRoot
  $held = [Collections.Generic.List[object]]::new()
  $idx = [Collections.Generic.List[int]]::new()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $sweepSw = [Diagnostics.Stopwatch]::StartNew()
  $abandonSw = [Diagnostics.Stopwatch]::StartNew()
  $stall = New-TcGateQueueState
  $spoke = $false; $ticket = $null; $ahead = 0; $first = $true
  try {
    while ($true) {
      $sweep = $first -or ($sweepSw.Elapsed.TotalSeconds -ge $SweepEverySec)
      if ($sweep) { $sweepSw.Restart() }
      $first = $false
      $mine = if ($ticket) { $ticket.Name } else { '' }
      $ahead = Get-TcGateQueueAhead -Dir $dir -Prefix $Prefix -Before $mine -Sweep:$sweep
      if ($ahead -eq 0) {
        # The loop stops at Total, so a want above the total is granted the total without a separate clamp.
        for ($i = 0; ($i -lt $Total) -and ($held.Count -lt $Want); $i++) {
          $mx = New-Object System.Threading.Mutex($false, ($Prefix + $i))
          $got = $false
          try { $got = $mx.WaitOne(0) }
          catch [System.Threading.AbandonedMutexException] { $got = $true }   # a killed run, not a wedge
          if ($got) { $held.Add($mx); $idx.Add($i) } else { $mx.Dispose() }
        }
        if ($held.Count -ge $Want) { break }
        if (-not $Exact -and $held.Count -ge 1) { break }
        if ($Exact -and $held.Count) {
          foreach ($h in $held) { try { $h.ReleaseMutex() } catch { }; try { $h.Dispose() } catch { } }
          $held.Clear(); $idx.Clear()
        }
      }
      if ($Exact) {
        if ($sw.Elapsed.TotalSeconds -ge $WaitSec) {
          return (New-TcGateLease -Held $held -Idx $idx -Count 0 -WaitedMs $sw.Elapsed.TotalMilliseconds -TimedOut $true -Abandoned '' -Prefix $Prefix -Total $Total -Dir $dir -Ahead $ahead)
        }
      } else {
        # Joining after a pass that found nothing: every live ticket counted in $ahead arrived before this one.
        if (-not $ticket) { $ticket = New-TcGateTicket -Prefix $Prefix -Dir $dir }
        if (Step-TcGateQueueWait -State $stall -Ahead $ahead -NowMs $sw.Elapsed.TotalMilliseconds -WaitSec $WaitSec) {
          return (New-TcGateLease -Held $held -Idx $idx -Count 0 -WaitedMs $sw.Elapsed.TotalMilliseconds -TimedOut $true -Abandoned '' -Prefix $Prefix -Total $Total -Dir $dir -Ahead $ahead)
        }
      }
      if ($Abandon -and $abandonSw.Elapsed.TotalSeconds -ge $AbandonEverySec) {
        $abandonSw.Restart()
        $said = & $Abandon
        $said = @($said)
        $why = if ($said.Count) { [string]$said[$said.Count - 1] } else { '' }
        if ($why) {
          return (New-TcGateLease -Held $held -Idx $idx -Count 0 -WaitedMs $sw.Elapsed.TotalMilliseconds -TimedOut $false -Abandoned $why -Prefix $Prefix -Total $Total -Dir $dir -Ahead $ahead)
        }
      }
      # OUT-DEFAULT, NOT THE OUTPUT STREAM (2026-09-11). Anything OnWait writes would otherwise join this
      # function's return, so `$lease = Enter-TcGateSlots` became an ARRAY of the message and the lease: the
      # message never printed, and `$lease.Count` read the array's length (2) instead of the slots held, so a
      # run-gates that had waited for one slot sized its pool at 2. Found by cpu-load.ps1's self-test.
      if (-not $spoke -and $OnWait) { & $OnWait $ahead | Out-Default; $spoke = $true }
      Start-Sleep -Milliseconds $PollMs
    }
    return (New-TcGateLease -Held $held -Idx $idx -Count $held.Count -WaitedMs $sw.Elapsed.TotalMilliseconds -TimedOut $false -Abandoned '' -Prefix $Prefix -Total $Total -Dir $dir -Ahead 0)
  } finally {
    Remove-TcGateTicket $ticket
  }
}

function Add-TcGateSlots {
  <# NON-BLOCKING top-up of a lease toward Want, for a pool that still has gates queued. It tries only the slot
     indices this lease does NOT already hold: a mutex is re-entrant for the thread that owns it, so retrying
     slot 0 would "succeed" and count a slot twice. It takes NOTHING while any run is queued for a slot, because a
     slot freed then is the queue's. Emits nothing - read $Lease.Count. Same thread as Enter. #>
  param([object]$Lease, [int]$Want)
  if (-not $Lease -or $Lease.TimedOut) { return }
  if ($Lease.QueueDir -and (Get-TcGateQueueAhead -Dir $Lease.QueueDir -Prefix $Lease.Prefix -Sweep) -gt 0) { return }
  if ($Want -gt $Lease.Total) { $Want = $Lease.Total }
  for ($i = 0; ($i -lt $Lease.Total) -and ($Lease.Mutexes.Count -lt $Want); $i++) {
    if ($Lease.Indices.Contains($i)) { continue }
    $mx = New-Object System.Threading.Mutex($false, ($Lease.Prefix + $i))
    $got = $false
    try { $got = $mx.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $got = $true }
    if ($got) { $Lease.Mutexes.Add($mx); $Lease.Indices.Add($i) } else { $mx.Dispose() }
  }
  $Lease.Count = $Lease.Mutexes.Count
}

function Reduce-TcGateSlots {
  <# Give back every slot beyond Keep, newest first, for a pool whose dispatch is done and whose running gates
     no longer need them. Emits nothing - read $Lease.Count. Same thread as Enter. #>
  param([object]$Lease, [int]$Keep)
  if (-not $Lease -or $Lease.TimedOut) { return }
  if ($Keep -lt 0) { $Keep = 0 }
  while ($Lease.Mutexes.Count -gt $Keep) {
    $last = $Lease.Mutexes.Count - 1
    $mx = $Lease.Mutexes[$last]
    try { $mx.ReleaseMutex() } catch { }
    try { $mx.Dispose() } catch { }
    $Lease.Mutexes.RemoveAt($last); $Lease.Indices.RemoveAt($last)
  }
  $Lease.Count = $Lease.Mutexes.Count
}

function Exit-TcGateSlots {
  param([object]$Lease)
  if (-not $Lease) { return }
  foreach ($mx in @($Lease.Mutexes)) {
    try { $mx.ReleaseMutex() } catch { }
    try { $mx.Dispose() } catch { }
  }
  # Cleared, so a lease already reduced to nothing, or exited twice, releases nothing twice.
  if ($Lease.Mutexes -is [Collections.IList]) { $Lease.Mutexes.Clear() }
  if ($Lease.Indices -is [Collections.IList]) { $Lease.Indices.Clear() }
  $Lease.Count = 0
}

if ($__gsSelfTest) {
  $f = 0; $cases = 0
  # Kind names by concatenation, so these lines are not counted as assertions by ops\audit-mustfire-census.ps1.
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  $kinds = @{ $kMF = 0; $kMNF = 0; $kCT = 0 }
  function T($m, $cond, $got) {
    $script:cases++
    foreach ($k in @($kMNF, $kMF, $kCT)) { if (([string]$m).StartsWith($k)) { $script:kinds[$k]++; break } }
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }
  $PS = (Get-Command powershell).Source
  # Local\ and a fresh guid per run: the fixtures must never touch the real Global\ slots, because this
  # self-test runs INSIDE a run-gates that is holding them.
  $prefix = 'Local\tc-gate-slot-selftest-' + [guid]::NewGuid().ToString('N') + '-'
  $tmp = Join-Path $env:TEMP ('tc-gate-slots-' + [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Force $tmp
  # The queue too: every Enter in this process and in every child below queues under this run's own directory.
  $qroot = Join-Path $tmp 'q'
  $script:TcGateQueueRoot = $qroot
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
  # A QUEUED RUN IS ANOTHER PROCESS too: it calls Enter-TcGateSlots for one slot under this run's queue root, writes
  # the count it was granted, and holds it until its release file appears.
  function Start-Waiter([string]$Name, [string]$Pfx, [int]$Total, [int]$PollMs) {
    $ready = Join-Path $tmp ($Name + '.ready'); $release = Join-Path $tmp ($Name + '.release')
    $body = @'
. '__LIB__'
$l = Enter-TcGateSlots -Want 1 -Total __TOTAL__ -Prefix '__PFX__' -QueueRoot '__QROOT__' -WaitSec 60 -PollMs __POLL__
[IO.File]::WriteAllText('__READY__', [string]$l.Count)
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath '__RELEASE__') -and $sw.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 50 }
Exit-TcGateSlots $l
'@
    $body = $body.Replace('__LIB__', $PSCommandPath).Replace('__TOTAL__', [string]$Total).Replace('__PFX__', $Pfx)
    $body = $body.Replace('__QROOT__', $qroot).Replace('__POLL__', [string]$PollMs).Replace('__READY__', $ready).Replace('__RELEASE__', $release)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $p = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru -WindowStyle Hidden
    $script:holders.Add($p)
    [pscustomobject]@{ Proc = $p; Ready = $ready; Release = $release }
  }
  # A bare ticket in another process: queued, and never asking for a slot.
  function Start-TicketHolder([string]$Name, [string]$Pfx) {
    $release = Join-Path $tmp ($Name + '.release')
    $body = @'
. '__LIB__'
$t = New-TcGateTicket -Prefix '__PFX__' -Dir (Get-TcGateQueueDir -Prefix '__PFX__' -Root '__QROOT__')
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath '__RELEASE__') -and $sw.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 50 }
Remove-TcGateTicket $t
'@
    $body = $body.Replace('__LIB__', $PSCommandPath).Replace('__PFX__', $Pfx).Replace('__QROOT__', $qroot).Replace('__RELEASE__', $release)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $p = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru -WindowStyle Hidden
    $script:holders.Add($p)
    [pscustomobject]@{ Proc = $p; Release = $release }
  }
  function Get-TicketCount([string]$Pfx) {
    $d = Get-TcGateQueueDir -Prefix $Pfx -Root $qroot
    if (-not [IO.Directory]::Exists($d)) { return 0 }
    return @([IO.Directory]::GetFiles($d, '*.ticket')).Count
  }
  function Wait-TicketCount([string]$Pfx, [int]$N, [int]$WithinSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $WithinSec) {
      if ((Get-TicketCount $Pfx) -ge $N) { return $true }
      Start-Sleep -Milliseconds 50
    }
    return $false
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
    # READ BEFORE EXIT: Exit-TcGateSlots zeroes the lease's Count, so a count read afterwards says nothing
    # about what was held.
    $firstG = $l.Count
    Exit-TcGateSlots $l
    $h = Start-Holder $pG 2 'g'
    T 'CLEAN TWIN slots released by Exit-TcGateSlots are really free - another process takes all of them straight away' `
      ($firstG -eq 2 -and $h.Held -eq 2) ("first={0} otherProcessHeld={1}" -f $firstG, $h.Held)
    [IO.File]::WriteAllText($h.Release, 'go'); [void]$h.Proc.WaitForExit(10000)

    # THE PRODUCTION SHAPE: a second push is already WAITING, holding its own handles, when this run exits.
    # Its handles keep the mutex objects alive, so only a real ReleaseMutex hands the slots over.
    $pH = $prefix + 'h-'
    $l = Enter-TcGateSlots -Want 2 -Total 2 -Prefix $pH -WaitSec 5 -PollMs 100
    $firstH = $l.Count
    $w = Start-Holder $pH 2 'h' -WaitMs 8000 -ReturnWhileWaiting
    Start-Sleep -Milliseconds 300
    Exit-TcGateSlots $l
    $waiterHeld = Read-HolderCount $w.ReadyFile 25
    T 'CLEAN TWIN a run already WAITING in another process, with its handles open, gets every slot the moment this run exits its lease' `
      ($firstH -eq 2 -and $w.Waiting -and $waiterHeld -eq 2) ("first={0} waiterWasWaiting={1} waiterHeld={2}" -f $firstH, $w.Waiting, $waiterHeld)
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
    $wBody = ". '__LIB__'; `$r = Enter-TcGateSlots -Want 3 -Total 3 -Prefix '__PFX__' -QueueRoot '__QROOT__' -Exact -WaitSec 30 -PollMs 100; [IO.File]::WriteAllText('__OUT__', [string]`$r.Count); Start-Sleep -Milliseconds 300; Exit-TcGateSlots `$r"
    $wBody = $wBody.Replace('__LIB__', $PSCommandPath).Replace('__PFX__', $pI).Replace('__QROOT__', $qroot).Replace('__OUT__', $waitOut)
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

    # GROW AND SHRINK, which run-gates' pool calls so its grant moves with its work.
    $pK = $prefix + 'k-'
    $lK = Enter-TcGateSlots -Want 2 -Total 3 -Prefix $pK -WaitSec 5 -PollMs 100
    $hK = Start-Holder $pK 3 'k' -WaitMs 400
    $addOut = Add-TcGateSlots -Lease $lK -Want 3
    $blockedCount = $lK.Count
    T 'MUST FIRE  Add-TcGateSlots never re-counts a slot this lease already holds - a mutex is re-entrant for its own thread, so retrying slot 0 would read as a new grant' `
      ($lK.Count -ge 2 -and $hK.Held -eq 1 -and $blockedCount -eq 2 -and $null -eq $addOut) ("leaseStart=2 otherProcessHeld={0} afterTopUp={1} emitted={2}" -f $hK.Held, $blockedCount, ($null -ne $addOut))
    [IO.File]::WriteAllText($hK.Release, 'go'); [void]$hK.Proc.WaitForExit(10000)
    Add-TcGateSlots -Lease $lK -Want 3
    $grown = $lK.Count
    T 'CLEAN TWIN Add-TcGateSlots takes the slot another run just gave back, topping the lease up to what it wanted' `
      ($grown -eq 3) ("afterRelease={0}" -f $grown)
    Reduce-TcGateSlots -Lease $lK -Keep 1
    $kept = $lK.Count
    $hK2 = Start-Holder $pK 3 'k2' -WaitMs 400
    T 'CLEAN TWIN Reduce-TcGateSlots really gives back what it drops - keeping 1 of 3, another process takes the other 2 at once' `
      ($kept -eq 1 -and $hK2.Held -eq 2) ("kept={0} otherProcessHeld={1}" -f $kept, $hK2.Held)
    [IO.File]::WriteAllText($hK2.Release, 'go'); [void]$hK2.Proc.WaitForExit(10000)
    Exit-TcGateSlots $lK
    $hK3 = Start-Holder $pK 3 'k3' -WaitMs 400
    T 'CLEAN TWIN Exit after Reduce leaves every slot free, and the lease reads 0' `
      ($hK3.Held -eq 3 -and $lK.Count -eq 0) ("otherProcessHeld={0} leaseCount={1}" -f $hK3.Held, $lK.Count)
    [IO.File]::WriteAllText($hK3.Release, 'go'); [void]$hK3.Proc.WaitForExit(10000)

    # ---- THE QUEUE ----
    # ARRIVAL ORDER. The later waiter polls 16 times as often as the earlier one, so code where the first poll after a
    # release wins hands it the slot nearly every time. In arrival order it must wait.
    $pQ = $prefix + 'q-'
    $hQ = Start-Holder $pQ 1 'q'
    $wA = Start-Waiter 'qa' $pQ 1 400
    $aQueued = Wait-TicketCount $pQ 1 30
    $wB = Start-Waiter 'qb' $pQ 1 25
    $bQueued = Wait-TicketCount $pQ 2 30
    [IO.File]::WriteAllText($hQ.Release, 'go')
    $gotA = Read-HolderCount $wA.Ready 25
    $bEarly = Test-Path -LiteralPath $wB.Ready
    T 'MUST FIRE  THE STARVATION FIX - two runs wait for one slot and the one that ARRIVED FIRST gets it, though the later one polls 16 times as often' `
      ($hQ.Held -eq 1 -and $aQueued -and $bQueued -and $gotA -eq 1 -and -not $bEarly) ("holderHeld={0} queued={1}/{2} firstGot={3} laterAlreadyServed={4}" -f $hQ.Held, $aQueued, $bQueued, $gotA, $bEarly)
    [IO.File]::WriteAllText($wA.Release, 'go')
    $gotB = Read-HolderCount $wB.Ready 25
    T 'CLEAN TWIN the later run is served next, as soon as the first gives the slot back' ($gotB -eq 1) ("laterGot={0}" -f $gotB)
    [IO.File]::WriteAllText($wB.Release, 'go')
    [void]$hQ.Proc.WaitForExit(10000); [void]$wA.Proc.WaitForExit(10000); [void]$wB.Proc.WaitForExit(10000)

    # THE TOP-UP YIELDS. Slot 0 is this run's, slot 1 another process's, and a third run queues for one. When slot 1
    # comes back, this run's top-up must leave it for the queued run. The queued run polls slowly, so a top-up that
    # ignores the queue gets there first.
    $pY = $prefix + 'y-'
    $lY = Enter-TcGateSlots -Want 1 -Total 2 -Prefix $pY -WaitSec 5 -PollMs 100
    $yStart = $lY.Count
    $hY = Start-Holder $pY 2 'y' -WaitMs 400
    $wY = Start-Waiter 'yw' $pY 2 1500
    $yQueued = Wait-TicketCount $pY 1 30
    [IO.File]::WriteAllText($hY.Release, 'go'); [void]$hY.Proc.WaitForExit(10000)
    Add-TcGateSlots -Lease $lY -Want 2
    $yTop = $lY.Count
    T 'MUST FIRE  a run already holding a slot does NOT top up while another run waits in the queue with none - the freed slot is the queued run''s' `
      ($yStart -eq 1 -and $hY.Held -eq 1 -and $yQueued -and $yTop -eq 1) ("leaseStart={0} otherHeld={1} queued={2} afterTopUp={3}" -f $yStart, $hY.Held, $yQueued, $yTop)
    $gotY = Read-HolderCount $wY.Ready 25
    T 'CLEAN TWIN the queued run gets that slot' ($gotY -eq 1) ("queuedGot={0}" -f $gotY)
    [IO.File]::WriteAllText($wY.Release, 'go'); [void]$wY.Proc.WaitForExit(10000)
    Add-TcGateSlots -Lease $lY -Want 2
    $yTop2 = $lY.Count
    T 'CLEAN TWIN with the queue empty again, the same top-up takes the free slot' ($yTop2 -eq 2) ("afterQueueEmpty={0}" -f $yTop2)
    Exit-TcGateSlots $lY

    # A KILLED WAITER. Its ticket file stays behind; its mutex does not.
    $pZ = $prefix + 'z-'
    $lZ = Enter-TcGateSlots -Want 1 -Total 1 -Prefix $pZ -WaitSec 5 -PollMs 100
    $wZ = Start-Waiter 'zw' $pZ 1 200
    $zQueued = Wait-TicketCount $pZ 1 30
    try { $wZ.Proc.Kill() } catch { }
    [void]$wZ.Proc.WaitForExit(10000)
    $zLeft = Get-TicketCount $pZ
    Exit-TcGateSlots $lZ
    $lZ2 = Enter-TcGateSlots -Want 1 -Total 1 -Prefix $pZ -WaitSec 10 -PollMs 100
    $zGot = $lZ2.Count
    $zAfter = Get-TicketCount $pZ
    Exit-TcGateSlots $lZ2
    T 'CLEAN TWIN a waiter KILLED in the queue does not block it - the next run takes the slot at once' `
      ($zQueued -and $zLeft -eq 1 -and $zGot -eq 1) ("queued={0} ticketsAfterKill={1} nextGot={2}" -f $zQueued, $zLeft, $zGot)
    T 'MUST FIRE  the killed waiter''s ticket file is swept by the next probe, because anyone can now take its mutex' `
      ($zLeft -eq 1 -and $zAfter -eq 0) ("ticketsAfterKill={0} ticketsAfterNextRun={1}" -f $zLeft, $zAfter)

    # THE STALL RULE, over synthetic time.
    $st = New-TcGateQueueState
    $stalledAt = -1
    foreach ($tm in @(0, 400, 999, 1000, 1500)) { if (Step-TcGateQueueWait -State $st -Ahead 3 -NowMs $tm -WaitSec 1) { $stalledAt = $tm; break } }
    T 'MUST FIRE  a queue that does not move for WaitSec is refused - three runs ahead for one full second of synthetic time' `
      ($stalledAt -eq 1000) ("stalledAt={0}" -f $stalledAt)
    $st2 = New-TcGateQueueState
    $ahead2 = 12; $lastT = -1
    for ($tm = 0; $tm -le 10800; $tm += 900) {
      if (Step-TcGateQueueWait -State $st2 -Ahead $ahead2 -NowMs $tm -WaitSec 1) { break }
      $lastT = $tm
      if ($ahead2 -gt 0) { $ahead2-- }
    }
    T 'CLEAN TWIN a queue that keeps moving is waited out far past WaitSec - one run served every 0.9 s over 10.8 s of synthetic time at WaitSec 1, and the run reaches the head' `
      ($lastT -eq 10800 -and $ahead2 -eq 0) ("waitedTo={0}ms aheadAtEnd={1}" -f $lastT, $ahead2)

    # ABANDON - the hook's push that can no longer land.
    $pAb = $prefix + 'ab-'
    $hAb = Start-Holder $pAb 1 'ab'
    $lAb = Enter-TcGateSlots -Want 1 -Total 1 -Prefix $pAb -WaitSec 30 -PollMs 100 -Abandon { 'origin main moved' } -AbandonEverySec 0
    $abLeft = Get-TicketCount $pAb
    T 'MUST FIRE  a waiter whose abandon check gives a reason leaves at once, holding nothing, carrying the reason, and leaves no ticket behind' `
      ($hAb.Held -eq 1 -and $lAb.Abandoned -eq 'origin main moved' -and $lAb.Count -eq 0 -and -not $lAb.TimedOut -and $abLeft -eq 0) ("holderHeld={0} abandoned=[{1}] count={2} timedOut={3} tickets={4}" -f $hAb.Held, $lAb.Abandoned, $lAb.Count, $lAb.TimedOut, $abLeft)
    $lAb2 = Enter-TcGateSlots -Want 1 -Total 1 -Prefix $pAb -WaitSec 1 -PollMs 100 -Abandon { '' } -AbandonEverySec 0
    T 'MUST NOT FIRE  an abandon check that finds nothing keeps the run waiting - it ends by the stall rule, not by abandoning' `
      ($lAb2.TimedOut -and -not $lAb2.Abandoned) ("timedOut={0} abandoned=[{1}]" -f $lAb2.TimedOut, $lAb2.Abandoned)
    [IO.File]::WriteAllText($hAb.Release, 'go'); [void]$hAb.Proc.WaitForExit(10000)

    # DELIBERATE LOAD YIELDS TO THE QUEUE.
    $pX = $prefix + 'x-'
    $tX = Start-TicketHolder 'xt' $pX
    $xQueued = Wait-TicketCount $pX 1 30
    $lX = Enter-TcGateSlots -Want 2 -Total 2 -Prefix $pX -Exact -WaitSec 1 -PollMs 100
    $xGot = $lX.Count; $xTimed = $lX.TimedOut
    Exit-TcGateSlots $lX
    T 'MUST FIRE  deliberate load does not jump the gate queue - an EXACT request takes nothing while a gate run is queued, though both slots are free' `
      ($xQueued -and $xTimed -and $xGot -eq 0) ("queued={0} timedOut={1} got={2}" -f $xQueued, $xTimed, $xGot)
    [IO.File]::WriteAllText($tX.Release, 'go'); [void]$tX.Proc.WaitForExit(10000)
    $lX2 = Enter-TcGateSlots -Want 2 -Total 2 -Prefix $pX -Exact -WaitSec 5 -PollMs 100
    $xGot2 = $lX2.Count
    Exit-TcGateSlots $lX2
    T 'CLEAN TWIN once the queue is empty, the same EXACT request gets both slots' ($xGot2 -eq 2) ("got={0}" -f $xGot2)
  } finally {
    foreach ($p in $holders) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("SELF-TEST PASS: {0} cases - {1} must-fire led by a full machine refusing a new run and the earlier of two queued runs being served first, {2} must-not-fire led by a lone run getting its whole want, and {3} clean twins led by a killed run freeing its slots at once" -f $cases, $kinds[$kMF], $kinds[$kMNF], $kinds[$kCT])
  exit 0
}
