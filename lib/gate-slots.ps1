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

# ====================================================================================================
# THE QUEUE (2026-09-11, Brad's ruling on design\PLAN-gate-queue-2026-09-11.md).
#
# THE BUDGET WORKED AND THE WAITING DID NOT. Ten slots were held at every sample, but a waiter simply
# polled all ten mutexes every 500 ms, so the winner was whoever polled first after a release. MEASURED
# that afternoon from the hook's own kept logs: a run created at 16:11:14 was served after 322s while
# SEVEN runs created 16:04:15 to 16:08:20 were still waiting, and all seven timed out at 1,200s. A run
# created at 16:24:16 was served while the 16:08:20 run timed out 9 seconds later. Arrival ran at about
# 89 an hour against a service rate near 40, and 18 of 53 failed runs failed only because their worktree
# had never been seeded. So the wait bound was being spent by the wrong runs, in the wrong order.
#
# A TICKET IS A FILE WHOSE NAME IS ITS WHOLE CONTENT: <arrivalTicks>-<pid>-<processStartTicks>-<guid>.tkt.
# Nothing is read, only listed, so a poll costs a directory listing rather than an open per waiter.
#
# LIVENESS IS THE SAME PROPERTY THE MUTEXES RELY ON. A killed run's mutex comes back ABANDONED; a killed
# run's ticket names a pid whose process is gone, or whose start time differs (a recycled pid is NOT the
# same process, which is why the start time is in the name). Either way the ticket is skipped and pruned,
# so a crash cannot wedge the queue the way a semaphore would.
#
# HEAD OF QUEUE ONLY, AND IT COSTS O(1) IN THE NORMAL CASE. A waiter attempts the mutexes only when no
# LIVE earlier ticket exists. The check walks earlier tickets in arrival order and STOPS at the first live
# one, so the usual answer costs a single Get-Process. Full position, which costs one check per earlier
# ticket, is computed only when a number is about to be printed or an estimate made.
#
# FAIL OPEN, NEVER CLOSED. If the queue directory cannot be created, listed or written, every function
# here degrades to "you are the head" and the run proceeds exactly as it did before the queue existed.
# The SLOTS are the safety property and they are untouched; the queue only decides whose turn it is. A
# queue that could refuse a run because %TEMP% hiccuped would be a worse failure than the one it fixes.
# ====================================================================================================
$script:TcGateQueueDir = Join-Path $env:TEMP 'tc-gate-queue'
# THE FALLBACK COST, used only until this machine has recorded runs of its own. MEASURED 2026-09-11 over
# the 9 runs that got a slot and finished: gate work 776 to 1,543s, median 909. NOT a sweep and not a
# target: it is one day's median under a jam, and Get-TcGateRunCost replaces it with observed runs as soon
# as there are any. Registered in docs\CONTROL-CONSTANTS.md.
$script:TcGateDefaultRunCostSec = 909
$script:TcGateCostKeep = 20        # how many recent run costs the estimate averages

function Get-TcGateQueueDirPath {
  param([string]$QueueDir = $script:TcGateQueueDir)
  try {
    if (-not [IO.Directory]::Exists($QueueDir)) { $null = [IO.Directory]::CreateDirectory($QueueDir) }
    return $QueueDir
  } catch { return $null }
}

function New-TcGateTicket {
  <# Join the queue. Returns $null if the queue cannot be used, which every caller treats as "no queue". #>
  param([string]$QueueDir = $script:TcGateQueueDir)
  $dir = Get-TcGateQueueDirPath -QueueDir $QueueDir
  if (-not $dir) { return $null }
  try {
    $start = (Get-Process -Id $PID).StartTime.Ticks
    $name = ('{0:D19}-{1}-{2}-{3}.tkt' -f [DateTime]::UtcNow.Ticks, $PID, $start, [guid]::NewGuid().ToString('N').Substring(0, 8))
    $path = Join-Path $dir $name
    [IO.File]::WriteAllText($path, '')
    return [pscustomobject]@{ Path = $path; Name = $name; Dir = $dir }
  } catch { return $null }
}

function Remove-TcGateTicket {
  param([object]$Ticket)
  if (-not $Ticket) { return }
  try { [IO.File]::Delete($Ticket.Path) } catch { }
}

function Split-TcGateTicketName {
  <# Pure: the name IS the record. Returns $null for anything that does not parse, so a stray file in the
     directory can never be read as a waiter. #>
  param([string]$Name)
  $base = $Name
  if ($base.EndsWith('.tkt')) { $base = $base.Substring(0, $base.Length - 4) }
  $p = $base.Split('-')
  if ($p.Count -lt 4) { return $null }
  $arr = [int64]0; $tpid = 0; $st = [int64]0
  if (-not [int64]::TryParse($p[0], [ref]$arr)) { return $null }
  if (-not [int]::TryParse($p[1], [ref]$tpid)) { return $null }
  if (-not [int64]::TryParse($p[2], [ref]$st)) { return $null }
  return [pscustomobject]@{ Arrived = $arr; Pid = $tpid; Start = $st; Name = $Name }
}

function Test-TcGateTicketAlive {
  <# A recycled pid is not the same process, so the START TIME decides, not the pid. #>
  param([int]$TicketPid, [int64]$Start)
  try {
    $p = Get-Process -Id $TicketPid -ErrorAction Stop
    return ($p.StartTime.Ticks -eq $Start)
  } catch { return $false }
}

function Get-TcGateEarlierTickets {
  <# Tickets that arrived before $Name, oldest first. Ordering is by arrival ticks then pid, so two tickets
     written in the same tick still have a total order every waiter agrees on. #>
  param([string]$Name, [string]$QueueDir = $script:TcGateQueueDir)
  $dir = Get-TcGateQueueDirPath -QueueDir $QueueDir
  if (-not $dir) { return @() }
  $mine = Split-TcGateTicketName $Name
  $rows = @()
  try { $files = [IO.Directory]::GetFiles($dir, '*.tkt') } catch { return @() }
  foreach ($f in $files) {
    $r = Split-TcGateTicketName ([IO.Path]::GetFileName($f))
    if (-not $r) { continue }
    if ($mine -and ($r.Name -eq $mine.Name)) { continue }
    if ($mine -and (($r.Arrived -gt $mine.Arrived) -or (($r.Arrived -eq $mine.Arrived) -and ($r.Pid -ge $mine.Pid)))) { continue }
    $rows += [pscustomobject]@{ Path = $f; Arrived = $r.Arrived; Pid = $r.Pid; Start = $r.Start; Name = $r.Name }
  }
  $sorted = @($rows | Sort-Object Arrived, Pid)
  return $sorted
}

function Test-TcGateAtHead {
  <# STOPS AT THE FIRST LIVE EARLIER TICKET, so the normal answer costs one Get-Process rather than one per
     waiter in the queue. Dead tickets found on the way are pruned. No ticket means no queue: head. #>
  param([object]$Ticket, [string]$QueueDir = $script:TcGateQueueDir)
  if (-not $Ticket) { return $true }
  $earlier = Get-TcGateEarlierTickets -Name $Ticket.Name -QueueDir $QueueDir
  foreach ($e in $earlier) {
    if (Test-TcGateTicketAlive -TicketPid $e.Pid -Start $e.Start) { return $false }
    try { [IO.File]::Delete($e.Path) } catch { }
  }
  return $true
}

function Get-TcGateQueuePosition {
  <# 1 is the head. Costs one liveness check per earlier ticket, so it is called when a number is printed or
     an estimate made, never on every poll. Depth counts this ticket and every live one behind it too. #>
  param([object]$Ticket, [string]$QueueDir = $script:TcGateQueueDir)
  if (-not $Ticket) { return [pscustomobject]@{ Position = 1; Depth = 1 } }
  $dir = Get-TcGateQueueDirPath -QueueDir $QueueDir
  if (-not $dir) { return [pscustomobject]@{ Position = 1; Depth = 1 } }
  $ahead = 0; $live = 0
  $mine = Split-TcGateTicketName $Ticket.Name
  try { $files = [IO.Directory]::GetFiles($dir, '*.tkt') } catch { return [pscustomobject]@{ Position = 1; Depth = 1 } }
  foreach ($f in $files) {
    $r = Split-TcGateTicketName ([IO.Path]::GetFileName($f))
    if (-not $r) { continue }
    if (-not (Test-TcGateTicketAlive -TicketPid $r.Pid -Start $r.Start)) { try { [IO.File]::Delete($f) } catch { }; continue }
    $live++
    if ($mine -and (($r.Arrived -lt $mine.Arrived) -or (($r.Arrived -eq $mine.Arrived) -and ($r.Pid -lt $mine.Pid)))) { $ahead++ }
  }
  return [pscustomobject]@{ Position = ($ahead + 1); Depth = [Math]::Max(1, $live) }
}

function Add-TcGateRunCost {
  <# ONE FILE PER RUN, never an append. Several gate runs finish at once on this box, and a shared appended
     file loses lines to a concurrent appender (measured 2026-09-11: 13 of 200 with two processes). A file
     per run has no such race, and pruning keeps the directory from growing without limit. #>
  param([double]$SlotSeconds, [string]$QueueDir = $script:TcGateQueueDir)
  if ($SlotSeconds -le 0) { return }
  $dir = Get-TcGateQueueDirPath -QueueDir $QueueDir
  if (-not $dir) { return }
  try {
    $p = Join-Path $dir ('{0:D19}-{1}.cost' -f [DateTime]::UtcNow.Ticks, $PID)
    [IO.File]::WriteAllText($p, ([string][Math]::Round($SlotSeconds, 1)))
    $all = @([IO.Directory]::GetFiles($dir, '*.cost') | Sort-Object)
    if ($all.Count -gt (2 * $script:TcGateCostKeep)) {
      foreach ($old in $all[0..($all.Count - $script:TcGateCostKeep - 1)]) { try { [IO.File]::Delete($old) } catch { } }
    }
  } catch { }
}

function Get-TcGateRunCost {
  <# Mean SLOT-SECONDS of the most recent runs this machine actually recorded, with the count it averaged so
     the estimate can say what it rests on. Falls back to the measured default when nothing is recorded. #>
  param([string]$QueueDir = $script:TcGateQueueDir)
  $dir = Get-TcGateQueueDirPath -QueueDir $QueueDir
  if (-not $dir) { return [pscustomobject]@{ CostSec = $script:TcGateDefaultRunCostSec; Samples = 0 } }
  $vals = @()
  try {
    $files = @([IO.Directory]::GetFiles($dir, '*.cost') | Sort-Object)
    if ($files.Count -gt $script:TcGateCostKeep) { $files = @($files[($files.Count - $script:TcGateCostKeep)..($files.Count - 1)]) }
    foreach ($f in $files) {
      $v = 0.0
      try { if ([double]::TryParse([IO.File]::ReadAllText($f).Trim(), [ref]$v) -and $v -gt 0) { $vals += $v } } catch { }
    }
  } catch { }
  if (-not $vals.Count) { return [pscustomobject]@{ CostSec = $script:TcGateDefaultRunCostSec; Samples = 0 } }
  $mean = ($vals | Measure-Object -Average).Average
  return [pscustomobject]@{ CostSec = $mean; Samples = $vals.Count }
}

function Get-TcGateWaitEstimateSec {
  <# Position 1 waits for nothing. Every run ahead occupies the whole budget for CostSec/Total seconds, so a
     waiter at position p expects (p-1) * CostSec / Total. Pure, so the self-test drives it with numbers. #>
  param([int]$Position, [int]$Total, [double]$CostSec)
  if ($Total -lt 1) { $Total = 1 }
  if ($Position -lt 1) { $Position = 1 }
  return [int][Math]::Ceiling((($Position - 1) * $CostSec) / $Total)
}

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
    [switch]$Exact,
    [string]$QueueDir = $script:TcGateQueueDir,
    [switch]$NoQueue
  )
  if ($Total -lt 1) { $Total = 1 }
  if ($Want -lt 1) { $Want = 1 }
  if ($Exact -and $Want -gt $Total) { $Want = $Total }
  $held = [Collections.Generic.List[object]]::new()
  $idx = [Collections.Generic.List[int]]::new()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $spoke = $false
  # THE TICKET IS TAKEN BEFORE THE FIRST ATTEMPT, so arrival order is the order runs asked, not the order
  # they happened to poll. It is given back in the finally below, on EVERY path: a ticket represents a run
  # that is WAITING, so a run holding slots must not still be in the queue (Add-TcGateSlots reads it).
  $ticket = $null
  if (-not $NoQueue) { $ticket = New-TcGateTicket -QueueDir $QueueDir }
  $q = Get-TcGateQueuePosition -Ticket $ticket -QueueDir $QueueDir
  $costRow = Get-TcGateRunCost -QueueDir $QueueDir
  $eta = Get-TcGateWaitEstimateSec -Position $q.Position -Total $Total -CostSec $costRow.CostSec
  # ADMISSION AT ARRIVAL (2026-09-11). A run whose turn cannot come inside the bound learns that NOW, in
  # seconds, instead of holding a session for 20 minutes to be refused anyway. MEASURED that day: 18 runs
  # timed out at 1,200s having run no gate at all, and 20 of 27 timed-out attempts were retried by the same
  # session, so the queue refilled as fast as it drained. Refusing at the door costs the session nothing it
  # was going to get, and says what to wait for. It can only fire when a run is BEHIND others: at position 1
  # the estimate is 0 by construction.
  if ($ticket -and ($eta -gt $WaitSec)) {
    Remove-TcGateTicket $ticket
    return [pscustomobject]@{ Mutexes = $held; Indices = $idx; Count = 0; WaitedMs = 0; TimedOut = $true
      Refused = 'admission'; Position = $q.Position; Depth = $q.Depth; EstimateSec = $eta
      CostSec = $costRow.CostSec; CostSamples = $costRow.Samples; Prefix = $Prefix; Total = $Total }
  }
  try {
    while ($true) {
      # HEAD OF QUEUE ONLY. Without this the mutex attempt below is a lottery among every waiter, which is
      # exactly how seven earlier arrivals timed out while a later one was served.
      if (Test-TcGateAtHead -Ticket $ticket -QueueDir $QueueDir) {
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
      if ($sw.Elapsed.TotalSeconds -ge $WaitSec) {
        $qEnd = Get-TcGateQueuePosition -Ticket $ticket -QueueDir $QueueDir
        return [pscustomobject]@{ Mutexes = $held; Indices = $idx; Count = 0; WaitedMs = $sw.Elapsed.TotalMilliseconds; TimedOut = $true
          Refused = 'timeout'; Position = $qEnd.Position; Depth = $qEnd.Depth; EstimateSec = $eta
          CostSec = $costRow.CostSec; CostSamples = $costRow.Samples; Prefix = $Prefix; Total = $Total }
      }
      # OUT-DEFAULT, NOT THE OUTPUT STREAM (2026-09-11). Anything OnWait writes would otherwise join this
      # function's return, so `$lease = Enter-TcGateSlots` became an ARRAY of the message and the lease: the
      # message never printed, and `$lease.Count` read the array's length (2) instead of the slots held, so a
      # run-gates that had waited for one slot sized its pool at 2. Found by cpu-load.ps1's self-test.
      # IT IS HANDED THE POSITION, THE DEPTH AND THE ESTIMATE, recomputed here rather than reused from
      # arrival, so the line a waiter prints says where it actually is. A scriptblock that ignores the
      # arguments still works, which is what cpu-load's does.
      if (-not $spoke -and $OnWait) {
        $qNow = Get-TcGateQueuePosition -Ticket $ticket -QueueDir $QueueDir
        $etaNow = Get-TcGateWaitEstimateSec -Position $qNow.Position -Total $Total -CostSec $costRow.CostSec
        & $OnWait $qNow.Position $qNow.Depth $etaNow $costRow.Samples | Out-Default
        $spoke = $true
      }
      Start-Sleep -Milliseconds $PollMs
    }
  } finally { Remove-TcGateTicket $ticket }
  return [pscustomobject]@{ Mutexes = $held; Indices = $idx; Count = $held.Count; WaitedMs = $sw.Elapsed.TotalMilliseconds; TimedOut = $false
    Refused = ''; Position = $q.Position; Depth = $q.Depth; EstimateSec = $eta
    CostSec = $costRow.CostSec; CostSamples = $costRow.Samples; Prefix = $Prefix; Total = $Total }
}

function Test-TcGateAnyWaiting {
  <# Is ANY run currently queued for slots? A ticket exists only while its run is WAITING - Enter gives it
     back the moment it is granted or refused - so a live ticket here is a run that has not started. #>
  param([string]$QueueDir = $script:TcGateQueueDir)
  $dir = Get-TcGateQueueDirPath -QueueDir $QueueDir
  if (-not $dir) { return $false }
  try { $files = [IO.Directory]::GetFiles($dir, '*.tkt') } catch { return $false }
  foreach ($f in $files) {
    $r = Split-TcGateTicketName ([IO.Path]::GetFileName($f))
    if (-not $r) { continue }
    if (Test-TcGateTicketAlive -TicketPid $r.Pid -Start $r.Start) { return $true }
    try { [IO.File]::Delete($f) } catch { }
  }
  return $false
}

function Add-TcGateSlots {
  <# NON-BLOCKING top-up of a lease toward Want, for a pool that still has gates queued. It tries only the slot
     indices this lease does NOT already hold: a mutex is re-entrant for the thread that owns it, so retrying
     slot 0 would "succeed" and count a slot twice. Emits nothing - read $Lease.Count. Same thread as Enter.

     IT DOES NOT GROW WHILE ANYBODY IS QUEUED (2026-09-11). A pool that already holds a slot was topping up
     every 500 ms in the same race as the waiters and blind to them, which is a run that arrived LATER taking
     a slot ahead of runs that had been waiting for minutes: MEASURED that day, pools granted 1 slot reached
     10 and 6 while other runs waited, and in 24 of 30 samples there were more gate workers alive than runs
     holding slots. Growing is an optimisation for an idle budget; being served in order is the property. #>
  param([object]$Lease, [int]$Want, [string]$QueueDir = $script:TcGateQueueDir)
  if (-not $Lease -or $Lease.TimedOut) { return }
  if (Test-TcGateAnyWaiting -QueueDir $QueueDir) { return }
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
  function T($m, $cond, $got) { $script:cases++; if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }
  $PS = (Get-Command powershell).Source
  # Local\ and a fresh guid per run: the fixtures must never touch the real Global\ slots, because this
  # self-test runs INSIDE a run-gates that is holding them.
  $prefix = 'Local\tc-gate-slot-selftest-' + [guid]::NewGuid().ToString('N') + '-'
  $tmp = Join-Path $env:TEMP ('tc-gate-slots-' + [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Force $tmp
  # THE QUEUE IS REDIRECTED FOR THE WHOLE SUITE, exactly as the Local\ prefix redirects the mutexes, and for
  # the same reason: this file runs INSIDE a run-gates that is queued on the real one. Against the production
  # directory a fixture would wait behind real pushes, and worse, its own tickets would make every real
  # waiter on the box think somebody was ahead of them. Every default below reads this variable at call time,
  # so one assignment redirects all of them.
  $script:TcGateQueueDir = Join-Path $tmp 'queue'
  $null = New-Item -ItemType Directory -Force $script:TcGateQueueDir
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

    # ============================================================================================
    # THE QUEUE. Every case below drives the ORDER runs are served in, which is what the slots alone
    # never decided. A ticket is written by hand where a real waiter would write one, because the
    # thing under test is "does a run that is not at the head stand back", and a second PowerShell
    # process would only prove that two processes can both wait.
    # ============================================================================================
    function MakeTicket([int]$TicketPid, [int64]$Start, [int64]$Arrived) {
      $d = Get-TcGateQueueDirPath
      $n = ('{0:D19}-{1}-{2}-{3}.tkt' -f $Arrived, $TicketPid, $Start, [guid]::NewGuid().ToString('N').Substring(0, 8))
      $p = Join-Path $d $n
      [IO.File]::WriteAllText($p, '')
      return $p
    }
    $meProc = Get-Process -Id $PID
    $earlyTick = [DateTime]::UtcNow.AddMinutes(-10).Ticks

    # THE COST IS PINNED FIRST, and the two cases below are why. Admission and the head-of-queue wait are
    # different refusals, and with the fallback cost of 909s a single run ahead already estimates 455s, so a
    # case meaning to test the WAIT was refused at the door instead (measured here on the first run). One
    # recorded run of 2 slot-seconds makes the estimate small enough to admit, so each case drives the
    # refusal it names rather than whichever fires first.
    Add-TcGateRunCost -SlotSeconds 2

    # MUST FIRE - the founding defect: a free slot taken out of turn.
    $pQ = $prefix + 'q-'
    $hQ = Start-Holder $pQ 1 'q'          # holds 1 of 2, so slot 1 is FREE the whole time
    $qProc = Get-Process -Id $hQ.Proc.Id
    $tkLive = MakeTicket $qProc.Id $qProc.StartTime.Ticks $earlyTick
    $lQ = Enter-TcGateSlots -Want 1 -Total 2 -Prefix $pQ -WaitSec 3 -PollMs 100
    T 'MUST FIRE  THE ORDER, NOT THE RACE - with a FREE slot and an earlier LIVE waiter queued, this run takes NOTHING and waits its turn, which is what stopped seven earlier arrivals timing out while a later one ran' `
      ($hQ.Held -eq 1 -and $lQ.TimedOut -and $lQ.Count -eq 0 -and $lQ.Refused -eq 'timeout') ("holderHeld={0} timedOut={1} count={2} refused={3}" -f $hQ.Held, $lQ.TimedOut, $lQ.Count, $lQ.Refused)
    Exit-TcGateSlots $lQ
    # CLEAN TWIN - a ticket whose process is gone must not wedge the queue, the same property the
    # abandoned mutex gives the slots. 999999 is not a live pid here, and the file is pruned on the way past.
    Remove-Item -LiteralPath $tkLive -Force -ErrorAction SilentlyContinue
    $tkDead = MakeTicket 999999 12345 $earlyTick
    $lQ2 = Enter-TcGateSlots -Want 1 -Total 2 -Prefix $pQ -WaitSec 3 -PollMs 100
    T 'CLEAN TWIN a ticket whose process is gone blocks nobody: the run is served at once and the dead ticket is pruned' `
      (-not $lQ2.TimedOut -and $lQ2.Count -ge 1 -and -not (Test-Path -LiteralPath $tkDead)) ("timedOut={0} count={1} deadTicketStillThere={2}" -f $lQ2.TimedOut, $lQ2.Count, (Test-Path -LiteralPath $tkDead))
    Exit-TcGateSlots $lQ2
    [IO.File]::WriteAllText($hQ.Release, 'go'); [void]$hQ.Proc.WaitForExit(10000)

    # CLEAN TWIN - a run that HOLDS slots is not a waiter. If a granted lease left its ticket behind,
    # Add-TcGateSlots below would see a queue that is really itself and never grow again.
    $pT = $prefix + 't-'
    $lT = Enter-TcGateSlots -Want 1 -Total 2 -Prefix $pT -WaitSec 5 -PollMs 100
    $tickWhileHeld = @([IO.Directory]::GetFiles($script:TcGateQueueDir, '*.tkt')).Count
    Exit-TcGateSlots $lT
    T 'CLEAN TWIN a run that was GRANTED its slots leaves no ticket behind - the queue holds waiters only' `
      ($tickWhileHeld -eq 0) ("ticketsWhileHolding={0}" -f $tickWhileHeld)

    # MUST FIRE - admission. Five live tickets ahead, two slots, the recorded default cost: the estimate is
    # far past the bound, so this must refuse AT THE DOOR rather than hold the caller for the whole bound.
    $pA2 = $prefix + 'a2-'
    $ahead = @()
    for ($k = 0; $k -lt 5; $k++) { $ahead += MakeTicket $meProc.Id $meProc.StartTime.Ticks ($earlyTick + $k) }
    # The bound is 1s against an estimate of 5s (5 runs ahead, 2 slots, the 2s cost pinned above), so this
    # can only be the arrival refusal: a run that WAITED would have taken at least the bound to answer.
    $swA = [Diagnostics.Stopwatch]::StartNew()
    $lA = Enter-TcGateSlots -Want 1 -Total 2 -Prefix $pA2 -WaitSec 1 -PollMs 100
    $swA.Stop()
    T 'MUST FIRE  a run whose turn cannot come inside the bound is REFUSED AT ARRIVAL, in seconds, not after holding the session for the whole wait' `
      ($lA.TimedOut -and $lA.Refused -eq 'admission' -and $lA.Count -eq 0 -and $lA.Position -eq 6 -and $lA.WaitedMs -eq 0 -and $swA.Elapsed.TotalSeconds -lt 5) `
      ("refused={0} count={1} position={2} waitedMs={3} took={4:N1}s" -f $lA.Refused, $lA.Count, $lA.Position, $lA.WaitedMs, $swA.Elapsed.TotalSeconds)
    Exit-TcGateSlots $lA
    # MUST FIRE - and the pool does not grow past a queue either, which is the same unfairness one level on.
    # THE QUEUE IS CLEARED BEFORE THIS LEASE IS TAKEN. Measured here: with the five tickets still in place
    # this Enter was itself refused and the case read 0 against 0, which proves nothing about growing.
    foreach ($t in $ahead) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
    $pG2 = $prefix + 'g2-'
    $lG2 = Enter-TcGateSlots -Want 1 -Total 3 -Prefix $pG2 -WaitSec 5 -PollMs 100
    $grantedFirst = $lG2.Count
    $tkWaiter = MakeTicket $meProc.Id $meProc.StartTime.Ticks $earlyTick
    Add-TcGateSlots -Lease $lG2 -Want 3
    $blockedByQueue = $lG2.Count
    Remove-Item -LiteralPath $tkWaiter -Force -ErrorAction SilentlyContinue
    Add-TcGateSlots -Lease $lG2 -Want 3
    $grewWhenClear = $lG2.Count
    T 'MUST FIRE  a pool holding a slot does NOT top up while another run is queued, and tops up again once nobody is waiting' `
      ($grantedFirst -eq 1 -and $blockedByQueue -eq 1 -and $grewWhenClear -eq 3) ("granted={0} whileQueued={1} whenClear={2}" -f $grantedFirst, $blockedByQueue, $grewWhenClear)
    Exit-TcGateSlots $lG2

    # MUST NOT FIRE - a lone run on an empty queue is the head, owes no wait, and is never refused.
    $pN = $prefix + 'n-'
    $lN = Enter-TcGateSlots -Want 2 -Total 2 -Prefix $pN -WaitSec 5 -PollMs 100
    T 'MUST NOT FIRE  a lone run on an empty queue is position 1, estimates no wait at all, and is not refused' `
      (-not $lN.TimedOut -and $lN.Count -eq 2 -and $lN.Position -eq 1 -and $lN.EstimateSec -eq 0 -and $lN.Refused -eq '') `
      ("count={0} position={1} eta={2} refused='{3}'" -f $lN.Count, $lN.Position, $lN.EstimateSec, $lN.Refused)
    Exit-TcGateSlots $lN

    # The arithmetic the estimate rests on, driven with numbers rather than with today's disk.
    T 'the estimate is 0 at the head and is the runs ahead times a run''s cost over the budget' `
      ((Get-TcGateWaitEstimateSec -Position 1 -Total 10 -CostSec 900) -eq 0 -and
       (Get-TcGateWaitEstimateSec -Position 11 -Total 10 -CostSec 900) -eq 900 -and
       (Get-TcGateWaitEstimateSec -Position 3 -Total 2 -CostSec 100) -eq 100) `
      ("head={0} p11={1} p3={2}" -f (Get-TcGateWaitEstimateSec -Position 1 -Total 10 -CostSec 900), (Get-TcGateWaitEstimateSec -Position 11 -Total 10 -CostSec 900), (Get-TcGateWaitEstimateSec -Position 3 -Total 2 -CostSec 100))

    # CLEAN TWIN - a recorded run cost replaces the default, so the estimate follows this machine.
    # ITS OWN DIRECTORY. The suite pinned a 2s cost into the shared test queue above so the cases either side
    # would drive the refusal they name, and this case read that as a third sample and a mean of 200.67 -
    # measured here. A case about averaging must own every number it averages.
    $costDir = Join-Path $tmp 'costq'
    $null = New-Item -ItemType Directory -Force $costDir
    Add-TcGateRunCost -SlotSeconds 200 -QueueDir $costDir
    Add-TcGateRunCost -SlotSeconds 400 -QueueDir $costDir
    $costRow = Get-TcGateRunCost -QueueDir $costDir
    T 'CLEAN TWIN recorded run costs replace the fallback, and the estimate says how many runs it averaged' `
      ($costRow.Samples -eq 2 -and [Math]::Abs($costRow.CostSec - 300) -lt 0.01) ("samples={0} cost={1}" -f $costRow.Samples, $costRow.CostSec)
  } finally {
    foreach ($p in $holders) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("SELF-TEST PASS: {0} cases - 8 must-fire led by a full machine refusing a new run and by a free slot NOT taken out of turn, 4 must-not-fire led by a lone run getting its whole want, 10 clean twins led by a killed run freeing its slots at once, and the estimate's arithmetic" -f $cases)
  exit 0
}
