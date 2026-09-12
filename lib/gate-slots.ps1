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
    - WHAT THE 1,200 s DOES WHEN THE PRODUCERS NEVER STOP, which is the reading the ops rules ask for beside what a
      threshold does when a producer STOPS. It never fires, and a waiter's wait is then UNBOUNDED - but its SERVICE
      is guaranteed, because no later arrival can overtake a live ticket, so the wait is set by the drain rate and
      not by luck. That is the whole trade against the fixed 20-minute total it replaced: the old number bounded the
      WAIT and left service to chance, so on 2026-09-11 the unlucky refused while later arrivals ran; this one bounds
      NOTHING about the wait and makes the order a guarantee. THE FAILURE IT CANNOT SEE is a queue that keeps moving
      and fills faster than it drains: everybody is served, nobody is refused, and every wait grows without bound.
      There is no floor here on the drain rate, and by the ops rule on thresholds a floor is the only thing that
      could catch it - this is an upper bound on NO PROGRESS, so it cannot fire on a queue that is merely too slow.
      The detective cover for that is the hook's own telemetry, never this function.
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

  RE-MEASURED AT 20 ARRIVALS, 2026-09-12, through ops\probe-gate-slot-fairness.ps1 at commit 8b7d7ff4d - the harness
  this file's first measurement described but never committed, which is why that one cost a re-write to repeat. Bars
  written before the run; 3 rounds, arms alternating round by round, 20 arrivals wanting 3 slots each of a private
  budget of 4. THIS TREE: 0 of 190 pairs served out of arrival order in every round, worst arrival passed by 0 of 19
  later ones, 0 of 20 refused, peak 4 of 4. THE PRE-QUEUE MUTANT (Get-TcGateQueueAhead answering 0, original verified
  byte-identical by md5 after): 47, 49 and 53 of 190 inverted, and one arrival passed by 9, 9 and 15 of 19.
  **THE SHAPE MATTERS MORE THAN THE TOTAL**: 47 of 190 is well under the 95 a uniformly random order averages,
  because a waiter that arrives earlier also starts polling earlier and usually does win. The damage was never spread
  - it fell hard on a FEW runs, which is exactly the production signature, most pushes fine and a handful refused.
  AND THE FIX DOES NOT MAKE THE AVERAGE WAIT BETTER: median wait rose from 2.3-4.3 s to 5.1-5.2 s while the max held
  at about 10.5 s in both arms. It cannot, and it is not meant to - the budget and the work are unchanged, so the
  same queue drains in the same time and all that moves is WHO waits. What it buys is that the wait is now bounded
  by the drain rather than by luck.

  FOLD-MUTANT 2026-09-12, for the eight cases folded in from the three branches that fixed this starvation and did
  not land. Single mutants, each from a temp mirror, the original verified byte-identical by md5 after every round,
  mirrors removed; the predicted kill was written in the probe before the run. Control green from the mirror first,
  so a kill is the mutant and not the harness. **7 of 8 killed, each by its own predicted case**: a ticket that
  throws again on CreateDirectory, one that throws on the write, the admission guard removed, a fast path that
  creates the queue directory, an -Exact that queues, a sweep that ignores -Before, and a ticket file never deleted.
  THE SURVIVOR IS EQUIVALENT, and for the reason the ABANDONED MUTEX paragraph above gives: it made Test-TcGateTicketLive's typed
  AbandonedMutexException catch treat the ticket as not taken, and that catch is never reached on this runtime, so
  the mutant cannot change behaviour. That left the pinned-ticket case unproven, so it was re-probed on a line that
  IS reached - the probe answering LIVE always - which went red in 4 cases including the pinned one. A survivor on
  an unreachable line is not a missing case, but only a second mutant can tell those apart, which is why it was run.

  SCOPE OF A CLEAN REPORT: the self-test proves on this machine, with every competitor in its own process, that the
  budget holds, that the earlier of two waiters is served first, that a holder does not top up past a queued run,
  that a killed waiter's ticket is swept, that deliberate load does not jump the queue, that an abandon check ends a
  wait, and the stall rule over synthetic time. It proves nothing about how fast a real queue drains.

  NO param() BLOCK, for the reason lib\guard-contract.ps1 spells out: PS 5.1 runs a dot-sourced param()
  block in the CALLER's scope, so declaring [switch]$SelfTest here would reset the caller's.
#>
# gate-inputs: lib\gate-slots.ps1
# WHY THIS FILE DECLARES (Brad, 2026-09-12). The inference refused it on ONE line - `return (Join-Path $Root $leaf)`
# in Get-TcGateQueueDir - reading `$Root` as a repo root because of its NAME. It is not: it defaults to
# $script:TcGateQueueRoot, which is under LocalApplicationData, so no repo file is involved at all. That refusal
# cost 34s on every push and poisoned four more gates that merely dot-source this one (cpu-load among them),
# because unkeyability travels up a load graph. This suite reads nothing but its own bytes: its children
# dot-source $PSCommandPath, its mutexes live in a private Local\ prefix and its queue root is a per-run guid.
$__gsSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

# THE BUDGET. Brad's ruling, 2026-09-11: a fixed 10 across the machine. NOT a sweep and not derived from a
# width curve - the measured curve (MEASURE-gate-cost-2026-09-09) has points at 16, 24 and 32 only, so what
# a lone run costs at 10 is unmeasured here. Registered in docs\CONTROL-CONSTANTS.md.
#
# RAISED TO 24 (Brad, 2026-09-12). The wall clock of a gate run is its WORK divided by the width it gets, and at 10
# machine-wide the width was the binding half: measured that morning, a warm run did 778 s of gate work and got
# width 4, for 224 s wall, while the box - 32 logical processors - sat at 36% busy with 3 runs on it. Halving the
# work by caching bought nothing, because the width halved with it. 24 leaves 8 processors for the capture lanes,
# the daemons and the daily bot, which also live here.
# NOT A SWEEP EITHER, and it is recorded as such: it is 3/4 of the processor count, chosen because the contention
# was visible and the headroom was measured, not because 24 beat 16 and 32 on a curve. What it does when the
# producer stops is nothing - it is a ceiling on concurrency, so an idle box simply uses less of it.
# MIXED VERSIONS ARE SAFE. The slots are Global\ mutexes named by index, so a checkout still on 10 contends only
# for 0-9 and never takes 10-23; the two budgets do not corrupt each other, and the box's true ceiling during a
# rollout is whatever the newest checkout says. That is the same degrade-to-the-old-behaviour rule the push lock
# takes, and for the same reason: this queue stands in front of every checkout on the box, most of them older.
$script:TcGateSlotTotal = 24
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
     is the arrival time in ticks, so an ordinal sort of the names is arrival order.

     A TICKET THAT CANNOT BE WRITTEN RETURNS $null, IT NEVER THROWS (2026-09-12). This is reached from
     ops\run-gates.ps1, which runs under $ErrorActionPreference = 'Stop', and from ops\hooks\pre-push below it: a
     throw here is a could-not-evaluate for every push on this box, out of one unwritable directory - a stray file
     where the queue root goes, a full disk, a permission change. The push lock already follows the estate rule that
     every lock path degrades to the behaviour of the day before and never to a refusal (ops\hold-push-lock.ps1); the
     queue had not. So the caller waits OUT OF TURN, exactly as it did before there was a queue, and says why. The
     budget of 10 is enforced by the slot mutexes and is untouched by this, so the degraded run is gated no less.
     Found by claude\gate-slot-fifo and folded in on 2026-09-12; driven with a FILE sitting where the queue root
     goes, which made CreateDirectory throw. #>
  param([string]$Prefix, [string]$Dir, [ref]$Why)
  $name = '{0:D19}-{1}-{2}' -f [DateTime]::UtcNow.Ticks, $PID, [guid]::NewGuid().ToString('N').Substring(0, 8)
  try { $null = [IO.Directory]::CreateDirectory($Dir) }
  catch { if ($Why) { $Why.Value = 'queue directory unavailable: ' + $_.Exception.Message }; return $null }
  $mx = New-Object System.Threading.Mutex($false, ($Prefix + 'q-' + $name))
  $got = $false
  try { $got = $mx.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) { $mx.Dispose(); throw ('New-TcGateTicket: a brand-new ticket mutex was already held: ' + $name) }
  $path = Join-Path $Dir ($name + '.ticket')
  # The mutex is already held, so a failure here must give it back rather than leave a name nobody can take.
  try { [IO.File]::WriteAllText($path, [string]$PID) }
  catch {
    if ($Why) { $Why.Value = 'queue ticket unwritable: ' + $_.Exception.Message }
    try { $mx.ReleaseMutex() } catch { }
    try { $mx.Dispose() } catch { }
    return $null
  }
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
  # QueueBroke is the reason this run could not take a ticket, empty when it could. A degraded run is gated exactly
  # as before, so this is not a failure field - but a queue that silently stopped queueing is indistinguishable from
  # one nobody is waiting in, which is the shape this estate keeps paying for.
  # NOTHING PRINTS IT YET, AND THAT IS A DELIBERATE OMISSION WITH A REASON (2026-09-12). The line belongs in
  # ops\run-gates.ps1, which is the only caller holding the lease - and TWO recorded measurements name that file as
  # their harness (design\MEASURE-gate-queue-window-2026-09-11.md and MEASURE-gate-slot-admission-2026-09-11.md,
  # both citing b2460165e). So a seven-line diagnostic print there makes both conclusions UNQUALIFIED and breaks
  # ops\audit-conclusion-currency.ps1's ratchet, and re-qualifying them needs a re-read citing the editing commit,
  # which every push-main rebase renames - measured three times on this very push. Trading two sessions'
  # measurements for a print that fires only when the queue directory is unwritable is the wrong trade, so the
  # reason is carried HERE, on the lease, where any caller can read it. Add the print in a change that also
  # re-reads those two documents. design\PLAN-gate-slot-consolidation-2026-09-12.md has the whole account.
  param($Held, $Idx, [int]$Count, [double]$WaitedMs, [bool]$TimedOut, [string]$Abandoned, [string]$Prefix, [int]$Total, [string]$Dir, [int]$Ahead, [string]$QueueBroke = '')
  return [pscustomobject]@{ Mutexes = $Held; Indices = $Idx; Count = $Count; WaitedMs = $WaitedMs; TimedOut = $TimedOut; Abandoned = $Abandoned; Prefix = $Prefix; Total = $Total; QueueDir = $Dir; Ahead = $Ahead; QueueBroke = $QueueBroke }
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
  $spoke = $false; $ticket = $null; $ahead = 0; $first = $true; $queueBroke = ''
  try {
    while ($true) {
      $sweep = $first -or ($sweepSw.Elapsed.TotalSeconds -ge $SweepEverySec)
      if ($sweep) { $sweepSw.Restart() }
      $first = $false
      $mine = if ($ticket) { $ticket.Name } else { '' }
      $ahead = Get-TcGateQueueAhead -Dir $dir -Prefix $Prefix -Before $mine -Sweep:$sweep
      # A run that could not take a ticket has no turn to wait for, so deferring to the queue would leave it passed
      # over for as long as the queue keeps moving - a livelock, which is a worse refusal than the one this avoids.
      # It stops deferring and polls for a free slot exactly as it did before there was a queue, and the stall rule
      # below becomes the old fixed deadline for it. It still takes only FREE slots, so the machine-wide budget is
      # untouched and the run is gated no less. $ahead stays honest for the report; only admission ignores it.
      if ($queueBroke -and -not $ticket) { $ahead = 0 }
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
          return (New-TcGateLease -Held $held -Idx $idx -Count 0 -WaitedMs $sw.Elapsed.TotalMilliseconds -TimedOut $true -Abandoned '' -Prefix $Prefix -Total $Total -Dir $dir -Ahead $ahead -QueueBroke $queueBroke)
        }
      } else {
        # Joining after a pass that found nothing: every live ticket counted in $ahead arrived before this one.
        # A ticket that cannot be written leaves this run waiting OUT OF TURN rather than refusing the push - see
        # New-TcGateTicket's header. It is retried on the next pass, so a directory that comes back joins the queue.
        # NOT named $why: the abandon block below already owns that name in this scope, and PowerShell names are
        # case-insensitive and function-scoped, so sharing it would make one reason silently become the other.
        if (-not $ticket) {
          $ticketWhy = ''
          $ticket = New-TcGateTicket -Prefix $Prefix -Dir $dir -Why ([ref]$ticketWhy)
          if (-not $ticket -and -not $queueBroke) { $queueBroke = $ticketWhy }
        }
        if (Step-TcGateQueueWait -State $stall -Ahead $ahead -NowMs $sw.Elapsed.TotalMilliseconds -WaitSec $WaitSec) {
          return (New-TcGateLease -Held $held -Idx $idx -Count 0 -WaitedMs $sw.Elapsed.TotalMilliseconds -TimedOut $true -Abandoned '' -Prefix $Prefix -Total $Total -Dir $dir -Ahead $ahead -QueueBroke $queueBroke)
        }
      }
      if ($Abandon -and $abandonSw.Elapsed.TotalSeconds -ge $AbandonEverySec) {
        $abandonSw.Restart()
        $said = & $Abandon
        $said = @($said)
        $why = if ($said.Count) { [string]$said[$said.Count - 1] } else { '' }
        if ($why) {
          return (New-TcGateLease -Held $held -Idx $idx -Count 0 -WaitedMs $sw.Elapsed.TotalMilliseconds -TimedOut $false -Abandoned $why -Prefix $Prefix -Total $Total -Dir $dir -Ahead $ahead -QueueBroke $queueBroke)
        }
      }
      # OUT-DEFAULT, NOT THE OUTPUT STREAM (2026-09-11). Anything OnWait writes would otherwise join this
      # function's return, so `$lease = Enter-TcGateSlots` became an ARRAY of the message and the lease: the
      # message never printed, and `$lease.Count` read the array's length (2) instead of the slots held, so a
      # run-gates that had waited for one slot sized its pool at 2. Found by cpu-load.ps1's self-test.
      if (-not $spoke -and $OnWait) { & $OnWait $ahead | Out-Default; $spoke = $true }
      Start-Sleep -Milliseconds $PollMs
    }
    return (New-TcGateLease -Held $held -Idx $idx -Count $held.Count -WaitedMs $sw.Elapsed.TotalMilliseconds -TimedOut $false -Abandoned '' -Prefix $Prefix -Total $Total -Dir $dir -Ahead 0 -QueueBroke $queueBroke)
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
  # EVERY FIXTURE NAME IS CLAIMED ONCE (2026-09-12). A name is the stem of this run's .waiting/.ready/.release
  # files, so two fixtures sharing one means the second reads the first's stale .ready and finds a .release that
  # already says "go" - its holder frees the slots immediately and the case passes against a machine nobody is
  # holding. That is what happened folding the 2026-09-11 branches in: 'b' and 'e' were each claimed twice and
  # the broken-queue case read got=1 where it should have read 0. It THROWS rather than warns, because the whole
  # defect is that the quiet version looks like a pass. Same trap as the fixed-temp-name rule in
  # .claude\rules\ops-and-gates.md, one scope down.
  $claimed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  function Claim-FixtureName([string]$Name) {
    if (-not $claimed.Add($Name)) { throw ("self-test fixture name used twice: '" + $Name + "' - every fixture owns its own .ready and .release files") }
    return $Name
  }

  # A HOLDER IS ANOTHER PROCESS, for the one-thread reason in the header. It writes a waiting marker, tries
  # slots 0..N-1 of the prefix with up to WaitMs each, writes HOW MANY IT HOLDS to its ready file, and keeps
  # them until a release file appears (or 60s pass). The count is the point: a holder that merely says
  # "ready" passes every "another process can take them" case whether or not it took anything.
  function Start-Holder([string]$Pfx, [int]$N, [string]$Name, [int]$WaitMs = 2000, [switch]$ReturnWhileWaiting) {
    $Name = Claim-FixtureName $Name
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
    $Name = Claim-FixtureName $Name
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
    $Name = Claim-FixtureName $Name
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
  # A DELIBERATE-LOAD WAITER IN ANOTHER PROCESS: -Exact, so it must never take a ticket. Checking after it exits
  # could not tell "never took one" from "took one and cleaned up", so it holds the wait open while this run counts.
  function Start-ExactWaiter([string]$Name, [string]$Pfx, [int]$Want, [int]$Total) {
    $Name = Claim-FixtureName $Name
    $ready = Join-Path $tmp ($Name + '.ready')
    $body = @'
. '__LIB__'
[IO.File]::WriteAllText('__READY__', 'waiting')
$l = Enter-TcGateSlots -Want __WANT__ -Total __TOTAL__ -Prefix '__PFX__' -Exact -QueueRoot '__QROOT__' -WaitSec 25 -PollMs 100
Exit-TcGateSlots $l
'@
    $body = $body.Replace('__LIB__', $PSCommandPath).Replace('__WANT__', [string]$Want).Replace('__TOTAL__', [string]$Total)
    $body = $body.Replace('__PFX__', $Pfx).Replace('__QROOT__', $qroot).Replace('__READY__', $ready)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $p = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru -WindowStyle Hidden
    $script:holders.Add($p)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $ready) -and $sw.Elapsed.TotalSeconds -lt 30 -and -not $p.HasExited) { Start-Sleep -Milliseconds 50 }
    [pscustomobject]@{ Proc = $p; Started = (Test-Path -LiteralPath $ready) }
  }
  # PINS A TICKET'S MUTEX NAME OPEN from a third process: it finds the ticket file, opens a HANDLE on that ticket's
  # mutex without ever taking it, and holds the handle. That is what makes the header's handle-destruction effect
  # visible - with the pin, a killed owner's mutex comes back ABANDONED instead of the name vanishing and a fresh
  # one being created. Without it the sweep case passes down the easy path and proves the harder one by luck.
  function Start-TicketPinner([string]$Name, [string]$Pfx) {
    $Name = Claim-FixtureName $Name
    $ready = Join-Path $tmp ($Name + '.ready'); $release = Join-Path $tmp ($Name + '.release')
    $body = @'
$d = '__DIR__'
$sw = [Diagnostics.Stopwatch]::StartNew()
$f = $null
while ($sw.Elapsed.TotalSeconds -lt 30) {
  $all = @([IO.Directory]::GetFiles($d, '*.ticket'))
  if ($all.Count -ge 1) { $f = $all[0]; break }
  Start-Sleep -Milliseconds 25
}
if (-not $f) { [IO.File]::WriteAllText('__READY__', 'NOTICKET'); exit }
$n = [IO.Path]::GetFileNameWithoutExtension($f)
$mx = New-Object System.Threading.Mutex($false, ('__PFX__' + 'q-' + $n))
[IO.File]::WriteAllText('__READY__', $n)
$sw2 = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath '__RELEASE__') -and $sw2.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 50 }
$mx.Dispose()
'@
    $dir = Get-TcGateQueueDir -Prefix $Pfx -Root $qroot
    $null = [IO.Directory]::CreateDirectory($dir)
    $body = $body.Replace('__DIR__', $dir).Replace('__PFX__', $Pfx).Replace('__READY__', $ready).Replace('__RELEASE__', $release)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $p = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru -WindowStyle Hidden
    $script:holders.Add($p)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $ready) -and $sw.Elapsed.TotalSeconds -lt 30 -and -not $p.HasExited) { Start-Sleep -Milliseconds 50 }
    $pinned = ''
    if (Test-Path -LiteralPath $ready) { try { $pinned = [IO.File]::ReadAllText($ready).Trim() } catch { } }
    [pscustomobject]@{ Proc = $p; Release = $release; Pinned = $pinned }
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

    # ------------------------------------------------------------------------------------------------------
    # FOLDED IN 2026-09-12 from the three branches that fixed this starvation and did not land
    # (claude\gate-slot-fifo, claude\gate-slot-line, claude\gate-slot-starvation). Each case below asserts a
    # property THIS implementation already claims and nothing asserted. The rival branches' heartbeat cases - a
    # live-but-frozen waiter aged out of the line - are deliberately NOT here: this file's header states the
    # frozen-waiter wedge as a chosen behaviour, so folding them in would be a second queue design, not a
    # missing case. design\PLAN-gate-slot-consolidation-2026-09-12.md has the whole ruling.
    # ------------------------------------------------------------------------------------------------------

    # THE FAST PATH TOUCHES NOTHING. A run that never waits must not create the queue directory or a ticket:
    # every run on an idle box takes this path, and a ticket written there would be swept by somebody else's
    # probe and cost a real turn.
    $pQn = $prefix + 'qn-'
    $qN = Join-Path $tmp ('qn-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $lQn = Enter-TcGateSlots -Want 2 -Total 2 -Prefix $pQn -WaitSec 5 -PollMs 100 -QueueRoot $qN
    $nGot = $lQn.Count
    $nDir = [IO.Directory]::Exists((Get-TcGateQueueDir -Prefix $pQn -Root $qN))
    Exit-TcGateSlots $lQn
    T 'MUST NOT FIRE  a run that never has to wait takes NO ticket and does not even create the queue directory - only a run that waits joins the queue' `
      ($nGot -eq 2 -and -not $nDir) ("got={0} queueDirCreated={1}" -f $nGot, $nDir)

    # A BROKEN QUEUE DEGRADES, IT NEVER REFUSES. run-gates runs under EAP=Stop and pre-push runs run-gates, so a
    # throw out of Enter is a could-not-evaluate for every push on this box. A FILE where the queue root goes makes
    # CreateDirectory throw - the shape a stray file, a full disk or a permission change produces.
    $pQb = $prefix + 'qb-'
    $qB = Join-Path $tmp ('qbad-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [IO.File]::WriteAllText($qB, 'a file, not a directory')
    $hQb = Start-Holder $pQb 2 'zzb'
    $bThrew = ''
    $bGot = -1; $bTimed = $false; $bWhy = ''
    try {
      $lQb = Enter-TcGateSlots -Want 1 -Total 2 -Prefix $pQb -WaitSec 1 -PollMs 100 -QueueRoot $qB
      $bGot = $lQb.Count; $bTimed = $lQb.TimedOut; $bWhy = [string]$lQb.QueueBroke
      Exit-TcGateSlots $lQb
    } catch { $bThrew = $_.Exception.Message }
    T 'MUST NOT FIRE  a queue directory that cannot be written does not REFUSE a push - the run waits out of turn as it did before there was a queue, times out loudly on the slots, and carries the reason instead of throwing out of Enter' `
      (-not $bThrew -and $bGot -eq 0 -and $bTimed -and $bWhy) ("threw='{0}' got={1} timedOut={2} why='{3}'" -f $bThrew, $bGot, $bTimed, $bWhy)
    [IO.File]::WriteAllText($hQb.Release, 'go'); [void]$hQb.Proc.WaitForExit(10000)
    $bGot2 = -1; $bThrew2 = ''
    try {
      $lB2 = Enter-TcGateSlots -Want 2 -Total 2 -Prefix $pQb -WaitSec 5 -PollMs 100 -QueueRoot $qB
      $bGot2 = $lB2.Count
      Exit-TcGateSlots $lB2
    } catch { $bThrew2 = $_.Exception.Message }
    T 'CLEAN TWIN with the queue still broken and the slots free, the run is gated exactly as before - it takes its whole want, so degrading costs the budget nothing' `
      (-not $bThrew2 -and $bGot2 -eq 2) ("threw='{0}' got={1}" -f $bThrew2, $bGot2)

    # THE HARDER HALF, AND THE ONLY ONE THAT EXERCISES THE ADMISSION GUARD. Above, the queue ROOT is a file, so the
    # directory never exists, Get-TcGateQueueAhead answers 0 and the run would have been admitted with or without
    # the guard. The guard exists for the other shape: a queue directory this run can READ, holding somebody else's
    # LIVE ticket, that it cannot WRITE into - a deny-write ACL here, a full disk or a locked-down profile in
    # production. Without the guard such a run defers to a queue it can never join and is refused for as long as
    # the queue keeps moving; with it, it stops deferring, takes the free slot and is gated as it was before there
    # was a queue. The budget is untouched either way, because it still only ever takes a FREE slot.
    $denyOk = $false; $dThrew = ''; $dGot = -1; $dWhy = ''; $dAhead = -1
    $pQd = $prefix + 'qd-'
    $tQd = Start-TicketHolder 'zzdt' $pQd
    $null = Wait-TicketCount $pQd 1 30
    $dDir = Get-TcGateQueueDir -Prefix $pQd -Root $qroot
    try {
      $acl = Get-Acl -LiteralPath $dDir
      $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
      $deny = New-Object Security.AccessControl.FileSystemAccessRule($me, 'CreateFiles,WriteData', 'ContainerInherit,ObjectInherit', 'None', 'Deny')
      $acl.AddAccessRule($deny); Set-Acl -LiteralPath $dDir -AclObject $acl
      # PROVE THE DENY BIT, never assume it: an ACL that did not take would make the case pass down the ordinary
      # path and assert nothing at all.
      try { [IO.File]::WriteAllText((Join-Path $dDir 'probe.tmp'), 'x'); [IO.File]::Delete((Join-Path $dDir 'probe.tmp')) }
      catch { $denyOk = $true }
      if ($denyOk) {
        try {
          $lQd = Enter-TcGateSlots -Want 1 -Total 1 -Prefix $pQd -WaitSec 3 -PollMs 100
          $dGot = $lQd.Count; $dWhy = [string]$lQd.QueueBroke; $dAhead = [int]$lQd.Ahead
          Exit-TcGateSlots $lQd
        } catch { $dThrew = $_.Exception.Message }
      }
    } catch { $dThrew = 'acl: ' + $_.Exception.Message }
    finally {
      try { $a2 = Get-Acl -LiteralPath $dDir; $a2.RemoveAccessRuleAll($deny); Set-Acl -LiteralPath $dDir -AclObject $a2 } catch { }
      [IO.File]::WriteAllText($tQd.Release, 'go'); [void]$tQd.Proc.WaitForExit(10000)
    }
    T 'MUST NOT FIRE  a run that can READ the queue but cannot WRITE a ticket into it is not held behind the live ticket it can see - it stops deferring to a queue it can never join, takes the free slot and is gated, rather than being refused for a permission' `
      ($denyOk -and -not $dThrew -and $dGot -eq 1 -and $dWhy) `
      ("denyTook={0} threw='{1}' got={2} aheadSeen={3} why='{4}'" -f $denyOk, $dThrew, $dGot, $dAhead, $dWhy)

    # DELIBERATE LOAD TAKES NO TICKET. The queue case above proves load does not JUMP the queue; this is the other
    # direction - a waiting -Exact must be invisible to it, or a load test would hold back every gate run on the box.
    # Counted WHILE it waits: after it exits, "never took one" and "took one and tidied up" are the same bytes.
    $pQe = $prefix + 'qe-'
    $hQe = Start-Holder $pQe 2 'zze'
    $wQe = Start-ExactWaiter 'zzew' $pQe 2 2
    Start-Sleep -Milliseconds 1200
    $eTickets = Get-TicketCount $pQe
    $eAlive = -not $wQe.Proc.HasExited
    T 'MUST NOT FIRE  a deliberate-load request WAITING for its cores takes no ticket, so it can never hold a gate run back - counted while it is still waiting, not after it tidied up' `
      ($wQe.Started -and $eAlive -and $eTickets -eq 0) ("started={0} stillWaiting={1} tickets={2}" -f $wQe.Started, $eAlive, $eTickets)
    [IO.File]::WriteAllText($hQe.Release, 'go'); [void]$hQe.Proc.WaitForExit(10000); [void]$wQe.Proc.WaitForExit(30000)

    # A PROBE MUST NOT SWEEP ITS OWN TICKET. A mutex is re-entrant for the thread that owns it, so a waiter that
    # probed its own ticket would find it takeable, read it as dead and DELETE it - losing its own turn, silently,
    # and only under load. The header claims a probe never touches the ticket of the thread probing; nothing
    # asserted it. The first half asserts the hazard is real, the second that the -Before skip is what avoids it.
    $pS2 = $prefix + 's2-'
    $dS2 = Get-TcGateQueueDir -Prefix $pS2 -Root $qroot
    $tS2 = New-TcGateTicket -Prefix $pS2 -Dir $dS2
    $selfReadsDead = -not (Test-TcGateTicketLive -Prefix $pS2 -Name $tS2.Name)
    $null = Get-TcGateQueueAhead -Dir $dS2 -Prefix $pS2 -Before $tS2.Name -Sweep
    $selfSurvived = [IO.File]::Exists($tS2.Path)
    T 'CLEAN TWIN a waiter sweeping the queue never sweeps ITSELF - its own ticket mutex is re-entrant and so reads as takeable, and the ticket file is still there afterwards because the sweep skips everything from its own name on' `
      ($selfReadsDead -and $selfSurvived) ("ownProbeReadsDead={0} ownTicketSurvived={1}" -f $selfReadsDead, $selfSurvived)
    Remove-TcGateTicket $tS2

    # A KILLED WAITER'S TICKET, WITH THE NAME PINNED OPEN. The header warns that a named mutex nobody else has open
    # is DESTROYED with its last handle, so a one-process fixture "recovers" for the wrong reason. With a third
    # process holding a handle, the killed owner's mutex comes back ABANDONED instead - the production shape, and
    # the path the typed catch exists for.
    $pQp = $prefix + 'qp-'
    $tQp = Start-TicketHolder 'zzpt' $pQp
    $null = Wait-TicketCount $pQp 1 30
    $pin = Start-TicketPinner 'zzpin' $pQp
    $pinnedOk = ($pin.Pinned -and $pin.Pinned -ne 'NOTICKET')
    try { $tQp.Proc.Kill() } catch { }
    [void]$tQp.Proc.WaitForExit(10000)
    $lQp = Enter-TcGateSlots -Want 1 -Total 1 -Prefix $pQp -WaitSec 5 -PollMs 100
    $pGot = $lQp.Count
    Exit-TcGateSlots $lQp
    $pSwept = (Get-TicketCount $pQp) -eq 0
    T 'CLEAN TWIN a waiter KILLED while queued does not hold the queue even when a third process pins its ticket mutex OPEN, so the mutex comes back ABANDONED rather than the name vanishing - the next run is served and the dead ticket is swept' `
      ($pinnedOk -and $pGot -eq 1 -and $pSwept) ("pinned='{0}' got={1} swept={2}" -f $pin.Pinned, $pGot, $pSwept)
    [IO.File]::WriteAllText($pin.Release, 'go'); [void]$pin.Proc.WaitForExit(10000)

    # NOBODY LEAVES A TICKET BEHIND. A ticket outliving its run is the wedge this queue's refusal exists to report,
    # so it would turn a bug into a machine-wide stall. Both exits are asserted: the run that TIMED OUT in the
    # queue, and the run that was ADMITTED after waiting. Only the abandon exit was covered before.
    $pQl = $prefix + 'ql-'
    $hQl = Start-Holder $pQl 1 'zzl'
    $lQl = Enter-TcGateSlots -Want 1 -Total 1 -Prefix $pQl -WaitSec 1 -PollMs 100
    $lTimed = $lQl.TimedOut
    Exit-TcGateSlots $lQl
    $afterTimeout = Get-TicketCount $pQl
    [IO.File]::WriteAllText($hQl.Release, 'go'); [void]$hQl.Proc.WaitForExit(10000)
    $hQl2 = Start-Holder $pQl 1 'zzl2'
    $wQl = Start-Waiter 'zzlw' $pQl 1 100
    $null = Wait-TicketCount $pQl 1 30
    [IO.File]::WriteAllText($hQl2.Release, 'go'); [void]$hQl2.Proc.WaitForExit(10000)
    $lwGot = Read-HolderCount $wQl.Ready 30
    $afterAdmit = Get-TicketCount $pQl
    [IO.File]::WriteAllText($wQl.Release, 'go'); [void]$wQl.Proc.WaitForExit(30000)
    T 'CLEAN TWIN no run leaves a ticket behind - neither the one REFUSED after the queue stopped moving nor the one ADMITTED after waiting, so a finished run can never stall the queue behind it' `
      ($lTimed -and $afterTimeout -eq 0 -and $lwGot -eq 1 -and $afterAdmit -eq 0) `
      ("timedOut={0} ticketsAfterRefusal={1} waiterGot={2} ticketsAfterAdmission={3}" -f $lTimed, $afterTimeout, $lwGot, $afterAdmit)
  } finally {
    foreach ($p in $holders) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  # THE CASE COUNT IS ASSERTED, NOT JUST PRINTED (2026-09-12). These cases are a LITERAL LIST, so the number that
  # should run is knowable in advance and a shortfall is a defect rather than a smaller tree. claude\gate-slot-fifo's
  # suite printed PASS with a case never reached: a fixture variable $pS IS $PS - PowerShell names are
  # case-insensitive - so it overwrote the powershell.exe path and every child after it failed to start. This file
  # uses $PS for exactly that, so the trap is live here; the count is what makes it loud. Raise it when you add a
  # case, which is the point: an edit that silently drops one cannot pass.
  $expected = 37
  if ($cases -ne $expected) {
    Write-Output ("FAIL  MUST" + " FIRE  the suite runs every case it declares - a case that silently never ran would print PASS   got: ran={0} expected={1}" -f $cases, $expected)
    $f++
  }
  if ($f) { Write-Output ("SELF-TEST FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("SELF-TEST PASS: {0} cases - {1} must-fire led by a full machine refusing a new run and the earlier of two queued runs being served first, {2} must-not-fire led by a lone run getting its whole want, and {3} clean twins led by a killed run freeing its slots at once" -f $cases, $kinds[$kMF], $kinds[$kMNF], $kinds[$kCT])
  exit 0
}
