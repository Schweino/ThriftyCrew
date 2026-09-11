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

  A MUTEX POLL IS NOT A QUEUE, SO A WAITING RUN TAKES A TICKET (2026-09-11, that afternoon). Every waiter
  retried WaitOne(0) on each slot every 500 ms, and a running pool's top-up did the same, so a slot that came
  free went to whoever looked next. Measured from 16:05 (design\MEASURE-gate-queue-2026-09-11.md): about 20
  pushes queued at once, 26 kept hook logs refused at exactly 1,200s, and runs granted after 6s and after
  1,010s side by side - a push that had waited 19 minutes could lose the slot to one that had just arrived,
  or to a run already holding slots, and then exit 3 having been refused by the ORDER, never by the budget.
  So a run that finds nothing it may take writes a TICKET into a queue directory, named by the moment it began
  to wait, and tries the slots only when no live ticket stands ahead of it (Get-TcGateQueueAhead). A run that
  has not had to wait defers to every live ticket, and Add-TcGateSlots does not top a lease up while any gate
  run is queued. The mutexes are still the whole budget; the tickets only decide who may try them.
    THE QUEUE IS MACHINE-WIDE FOR A Global\ PREFIX, under ProgramData, because the sessions that push do not
    share a TEMP. Any other prefix - the self-tests' Local\ ones - queues under this process's TEMP, which
    the child processes it starts inherit, so a fixture never joins the real queue.
    A TICKET IS ALIVE WHILE ITS OWNER'S NAMED MUTEX EXISTS. The owner creates a mutex named after the ticket
    before writing the file and deletes the file before closing it, and a named mutex vanishes with its last
    handle, so a run KILLED in the queue leaves a file whose mutex is gone: the next reader skips it and
    deletes it. No pid, so pid reuse cannot keep a dead ticket alive.
    AND WHILE ITS OWNER IS STILL POLLING. The owner touches its ticket on every poll, and a ticket untouched
    for $TcGateTicketStalePolls of its own polls (plus 10s) is skipped though its owner lives. Without it, one
    hung waiter at the head would hold every push on the box, where before this change it held nobody.
    DELIBERATE LOAD YIELDS TO PUSHES. An -Exact ticket never holds back a gate run, and an -Exact request
    defers to every queued gate run - the priority the no-squat rule for -Exact below already gave pushes.
    MIXED CHECKOUTS. A run from a checkout older than this change polls and ignores the queue, so until every
    worktree carries this file such a run can still take a slot out of turn. The budget holds either way.

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
  below keeps a second process's handle open across the release. The ticket liveness above uses the same
  effect on purpose.

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
  never reached. Round 4, the queue: see design\MEASURE-gate-queue-2026-09-11.md for each mutant and the case
  that killed it.

  NO param() BLOCK, for the reason lib\guard-contract.ps1 spells out: PS 5.1 runs a dot-sourced param()
  block in the CALLER's scope, so declaring [switch]$SelfTest here would reset the caller's.
#>
$__gsSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

# THE BUDGET. Brad's ruling, 2026-09-11: a fixed 10 across the machine. NOT a sweep and not derived from a
# width curve - the measured curve (MEASURE-gate-cost-2026-09-09) has points at 16, 24 and 32 only, so what
# a lone run costs at 10 is unmeasured here. Registered in docs\CONTROL-CONSTANTS.md.
$script:TcGateSlotTotal = 10
$script:TcGateSlotPrefix = 'Global\tc-gate-worker-slot-'
$script:TcGateQueueRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'ThriftyCrew\gate-queue'
# HOW MANY OF ITS OWN POLLS A TICKET MAY GO UNTOUCHED before it stops holding the queue, plus a 10s floor: 20 s
# at the 500 ms default. First plausible value, NOT a sweep. Too small and a live waiter slowed by a loaded box
# briefly loses its place, which is the old polling behaviour and never a breach; too large and a hung waiter
# holds the queue longer. Registered in docs\CONTROL-CONSTANTS.md.
$script:TcGateTicketStalePolls = 20
# <ticks at which the wait began, 19 digits>-<id>-<g gate run | x exact load>-<owner's poll ms>.ticket
$script:TcGateTicketRx = '^(\d{19})-([0-9a-f]{32})-([gx])-(\d{1,9})\.ticket$'

function Get-TcGateQueueDir {
  <# The queue directory for one slot prefix - machine-wide for Global\, this process's TEMP otherwise. #>
  param([string]$Prefix)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Prefix)), 0, 8).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  $root = if ($Prefix.StartsWith('Global\', [StringComparison]::OrdinalIgnoreCase)) { $script:TcGateQueueRoot } else { $env:TEMP }
  return (Join-Path $root ('tc-gq-' + $hash))
}

function New-TcGateTicket {
  <# Takes this run's place in the queue: the liveness mutex first, then the file. Throws when it cannot. #>
  param([string]$Prefix, [int]$PollMs, [switch]$Exact)
  $dir = Get-TcGateQueueDir -Prefix $Prefix
  $id = [guid]::NewGuid().ToString('N')
  $mx = New-Object System.Threading.Mutex($false, ($Prefix + 'q-' + $id))
  $kind = if ($Exact) { 'x' } else { 'g' }
  $body = ('pid={0} started={1} cwd={2}' -f $PID, [DateTime]::UtcNow.ToString('o'), (Get-Location).Path)
  $name = '{0:D19}-{1}-{2}-{3}.ticket' -f [DateTime]::UtcNow.Ticks, $id, $kind, [Math]::Max(1, $PollMs)
  $last = $null
  for ($try = 0; $try -lt 5; $try++) {
    try {
      $null = [IO.Directory]::CreateDirectory($dir)
      [IO.File]::WriteAllText((Join-Path $dir $name), $body)
      return [pscustomobject]@{ Path = (Join-Path $dir $name); Name = $name; Id = $id; Dir = $dir; Body = $body; Mutex = $mx }
    } catch [IO.DirectoryNotFoundException] {
      $last = $_   # an emptying queue removed its directory between the two calls; make it again
    } catch {
      $last = $_; break
    }
  }
  $mx.Dispose()
  throw ("could not write a queue ticket in {0}: {1}" -f $dir, $last.Exception.Message)
}

function Update-TcGateTicket {
  <# The heartbeat. A ticket that has gone - removed by hand - is put back under the SAME name, keeping the place. #>
  param([object]$Ticket)
  if (-not $Ticket) { return }
  try { [IO.File]::SetLastWriteTimeUtc($Ticket.Path, [DateTime]::UtcNow) }
  catch {
    try { $null = [IO.Directory]::CreateDirectory($Ticket.Dir); [IO.File]::WriteAllText($Ticket.Path, $Ticket.Body) } catch { }
  }
}

function Remove-TcGateTicket {
  param([object]$Ticket)
  if (-not $Ticket) { return }
  try { [IO.File]::Delete($Ticket.Path) } catch { }
  # An emptied queue takes its directory with it, so a fixture's queue leaves nothing behind. Delete refuses a
  # directory that is not empty, and a writer that loses this race makes it again.
  try { [IO.Directory]::Delete($Ticket.Dir) } catch { }
  try { $Ticket.Mutex.Dispose() } catch { }
}

function Get-TcGateQueueAhead {
  <# How many LIVE tickets stand ahead of the caller. With a ticket, a gate run counts the gate-run tickets older
     than its own; an -Exact caller counts every gate-run ticket and the -Exact tickets older than its own.
     Without a ticket - a caller that has not had to wait yet - every live ticket that would be ahead of one
     taken now. A ticket whose mutex is gone is deleted; one whose owner stopped polling is skipped. #>
  param([string]$Prefix, [object]$Ticket = $null, [switch]$Exact)
  $dir = Get-TcGateQueueDir -Prefix $Prefix
  $files = $null
  try { $files = [IO.Directory]::GetFiles($dir, '*.ticket') } catch { return 0 }
  $now = [DateTime]::UtcNow
  $ahead = 0
  foreach ($full in $files) {
    $leaf = [IO.Path]::GetFileName($full)
    if (-not ($leaf -match $script:TcGateTicketRx)) { continue }
    $id = $Matches[2]
    $isExact = [string]::Equals($Matches[3], 'x', [StringComparison]::Ordinal)
    $poll = [double]$Matches[4]
    if ($Ticket -and [string]::Equals($id, $Ticket.Id, [StringComparison]::Ordinal)) { continue }
    $older = (-not $Ticket) -or ([string]::CompareOrdinal($leaf, $Ticket.Name) -lt 0)
    $counts = if ($Exact) { (-not $isExact) -or $older } else { (-not $isExact) -and $older }
    if (-not $counts) { continue }
    $m = $null
    $alive = [System.Threading.Mutex]::TryOpenExisting(($Prefix + 'q-' + $id), [ref]$m)
    if ($m) { $m.Dispose() }
    if (-not $alive) {
      try { [IO.File]::Delete($full) } catch { }
      continue
    }
    $ageMs = ($now - [IO.File]::GetLastWriteTimeUtc($full)).TotalMilliseconds
    if ($ageMs -gt ($poll * $script:TcGateTicketStalePolls + 10000)) { continue }
    $ahead++
  }
  return $ahead
}

function Enter-TcGateSlots {
  <# Returns Mutexes (the held slots - pass the whole object to Exit-TcGateSlots), Count, WaitedMs, TimedOut,
     Ahead and QueueError. Count is between 1 and min(Want, Total) on success. On TimedOut, Count is 0 and nothing
     is held: the caller must REFUSE rather than run, because running anyway is the pile-up this exists to stop.
     OnWait runs ONCE, the first time the run has to wait, and is handed how many runs are queued ahead of it.
     Ahead is how many were still queued ahead when a run gave up (0 on a grant). QueueError says why a run could
     not take a ticket; it then waits out of turn, the old polling behaviour, and the budget still holds.

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
  $idx = [Collections.Generic.List[int]]::new()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $spoke = $false
  $ticket = $null
  $queueError = $null
  $ahead = 0
  try {
    while ($true) {
      $ahead = Get-TcGateQueueAhead -Prefix $Prefix -Ticket $ticket -Exact:$Exact
      # A RUN WITH ANYONE AHEAD OF IT DOES NOT TRY THE SLOTS AT ALL - that one line is the fairness.
      if ($ahead -eq 0) {
        # The loop stops at Total, so a want above the total is granted the total without a separate clamp.
        for ($i = 0; ($i -lt $Total) -and ($held.Count -lt $Want); $i++) {
          $mx = New-Object System.Threading.Mutex($false, ($Prefix + $i))
          $got = $false
          try { $got = $mx.WaitOne(0) }
          catch [System.Threading.AbandonedMutexException] { $got = $true }   # a killed run, not a wedge
          if ($got) { $held.Add($mx); $idx.Add($i) } else { $mx.Dispose() }
        }
      }
      if ($held.Count -ge $Want) { break }
      if (-not $Exact -and $held.Count -ge 1) { break }
      if ($Exact -and $held.Count) {
        foreach ($h in $held) { try { $h.ReleaseMutex() } catch { }; try { $h.Dispose() } catch { } }
        $held.Clear(); $idx.Clear()
      }
      if ($ticket) { Update-TcGateTicket $ticket }
      elseif (-not $queueError) {
        try { $ticket = New-TcGateTicket -Prefix $Prefix -PollMs $PollMs -Exact:$Exact } catch { $queueError = [string]$_.Exception.Message }
      }
      if ($sw.Elapsed.TotalSeconds -ge $WaitSec) {
        return [pscustomobject]@{ Mutexes = $held; Indices = $idx; Count = 0; WaitedMs = $sw.Elapsed.TotalMilliseconds; TimedOut = $true; Prefix = $Prefix; Total = $Total; Ahead = $ahead; QueueError = $queueError }
      }
      # OUT-DEFAULT, NOT THE OUTPUT STREAM (2026-09-11). Anything OnWait writes would otherwise join this
      # function's return, so `$lease = Enter-TcGateSlots` became an ARRAY of the message and the lease: the
      # message never printed, and `$lease.Count` read the array's length (2) instead of the slots held, so a
      # run-gates that had waited for one slot sized its pool at 2. Found by cpu-load.ps1's self-test.
      if (-not $spoke -and $OnWait) { & $OnWait $ahead | Out-Default; $spoke = $true }
      Start-Sleep -Milliseconds $PollMs
    }
  } finally {
    Remove-TcGateTicket $ticket
  }
  return [pscustomobject]@{ Mutexes = $held; Indices = $idx; Count = $held.Count; WaitedMs = $sw.Elapsed.TotalMilliseconds; TimedOut = $false; Prefix = $Prefix; Total = $Total; Ahead = 0; QueueError = $queueError }
}

function Add-TcGateSlots {
  <# NON-BLOCKING top-up of a lease toward Want, for a pool that still has gates queued. It tries only the slot
     indices this lease does NOT already hold: a mutex is re-entrant for the thread that owns it, so retrying
     slot 0 would "succeed" and count a slot twice. It takes NOTHING while a gate run is queued: a freed slot is
     that run's, and a pool already running can finish at the width it has. Emits nothing - read $Lease.Count.
     Same thread as Enter. #>
  param([object]$Lease, [int]$Want)
  if (-not $Lease -or $Lease.TimedOut) { return }
  if ($Want -gt $Lease.Total) { $Want = $Lease.Total }
  if ($Lease.Mutexes.Count -ge $Want) { $Lease.Count = $Lease.Mutexes.Count; return }
  if ((Get-TcGateQueueAhead -Prefix $Lease.Prefix) -gt 0) { $Lease.Count = $Lease.Mutexes.Count; return }
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
  # UNDER Stop, WITH A COUNTED CATCH AND A LITERAL CASE COUNT (2026-09-11). The first run of the queue cases printed
  # PASS with one case never reached: a fixture variable named $pS IS $PS - PowerShell names ignore case - so it
  # overwrote the powershell.exe path, the next Start-Process failed without stopping anything, and the case's line
  # simply never printed. The cases are a literal list, so the number that must run is known.
  $ErrorActionPreference = 'Stop'
  $expectCases = 28
  $f = 0; $cases = 0; $mf = 0; $mnf = 0; $ct = 0
  function T($m, $cond, $got) {
    $script:cases++
    if ($m -like 'MUST FIRE*') { $script:mf++ } elseif ($m -like 'MUST NOT FIRE*') { $script:mnf++ } else { $script:ct++ }
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }
  $PS = (Get-Command powershell).Source
  # Local\ and a fresh guid per run: the fixtures must never touch the real Global\ slots, because this
  # self-test runs INSIDE a run-gates that is holding them. A Local\ prefix also keeps every fixture ticket in a
  # queue under TEMP, never in the machine-wide one.
  $prefix = 'Local\tc-gate-slot-selftest-' + [guid]::NewGuid().ToString('N') + '-'
  $tmp = Join-Path $env:TEMP ('tc-gate-slots-' + [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Force $tmp
  $holders = [Collections.Generic.List[object]]::new()

  # A HOLDER IS ANOTHER PROCESS, for the one-thread reason in the header. It writes a waiting marker, tries
  # slots From..From+N-1 of the prefix with up to WaitMs each, writes HOW MANY IT HOLDS to its ready file, and
  # keeps them until a release file appears (or 60s pass). The count is the point: a holder that merely says
  # "ready" passes every "another process can take them" case whether or not it took anything.
  function Start-Holder([string]$Pfx, [int]$N, [string]$Name, [int]$WaitMs = 2000, [switch]$ReturnWhileWaiting, [int]$From = 0) {
    $waiting = Join-Path $tmp ($Name + '.waiting'); $ready = Join-Path $tmp ($Name + '.ready'); $release = Join-Path $tmp ($Name + '.release')
    $body = @'
$ms = @()
$handles = @()
foreach ($i in __FROM__..(__FROM__ + __N__ - 1)) { $handles += New-Object System.Threading.Mutex($false, ('__PFX__' + $i)) }
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
    $body = $body.Replace('__FROM__', [string]$From).Replace('__N__', [string]$N).Replace('__PFX__', $Pfx).Replace('__WAITMS__', [string]$WaitMs)
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
  # A WAITER IS A REAL Enter-TcGateSlots IN ANOTHER PROCESS. Its OnWait writes the queued marker - which it can
  # only reach after taking its ticket - its grant writes the count, and it holds until released. A waiter with
  # a PollMs of ten minutes has taken its place in the queue and will not look at the slots again during a case:
  # that is how a case stands a push in line without letting it take what the case frees.
  function Start-Waiter([string]$Pfx, [int]$Total, [string]$Name, [int]$PollMs, [int]$Want = 1, [switch]$Exact) {
    $waiting = Join-Path $tmp ($Name + '.queued'); $granted = Join-Path $tmp ($Name + '.granted'); $release = Join-Path $tmp ($Name + '.release')
    $body = @'
. '__LIB__'
$r = Enter-TcGateSlots -Want __WANT__ -Total __TOTAL__ -Prefix '__PFX__' -WaitSec 300 -PollMs __POLL__ __EXACT__-OnWait { [IO.File]::WriteAllText('__WAITING__', [string]$args[0]) }
[IO.File]::WriteAllText('__GRANTED__', [string]$r.Count)
$sw = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path -LiteralPath '__RELEASE__') -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 50 }
Exit-TcGateSlots $r
'@
    $exactArg = if ($Exact) { '-Exact ' } else { '' }
    $body = $body.Replace('__LIB__', $PSCommandPath).Replace('__WANT__', [string]$Want).Replace('__TOTAL__', [string]$Total).Replace('__PFX__', $Pfx)
    $body = $body.Replace('__POLL__', [string]$PollMs).Replace('__EXACT__', $exactArg)
    $body = $body.Replace('__WAITING__', $waiting).Replace('__GRANTED__', $granted).Replace('__RELEASE__', $release)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $p = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru -WindowStyle Hidden
    $script:holders.Add($p)
    [pscustomobject]@{ Proc = $p; Queued = $waiting; Granted = $granted; Release = $release }
  }
  # A HANG GUARD, NEVER A BAR: every wait below ends on the file appearing, and the seconds only stop a broken
  # case from hanging the gate. A process that has exited cannot write the file, so its wait ends too.
  function Wait-ForFile([string]$Path, [int]$GuardSec, [object]$Proc = $null) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $GuardSec) {
      if (Test-Path -LiteralPath $Path) { return $true }
      if ($Proc -and $Proc.HasExited) { return (Test-Path -LiteralPath $Path) }
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
    $cDir = Get-TcGateQueueDir -Prefix $pC
    $cDirThere = Test-Path -LiteralPath $cDir
    T 'MUST NOT FIRE  a run that never waits writes nothing to the queue - only a run that has to wait takes a ticket' `
      (-not $cDirThere) ("queueDirExists={0} at {1}" -f $cDirThere, $cDir)
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

    # THE QUEUE (2026-09-11). Each case stands a push in line in another process, frees a slot, and asks who may
    # take it. Under the old polling every one of the three MUST FIRE cases below is decided on the first try by
    # whoever looks, which is never the push in line: the cases wait on files, and no clock decides any of them.
    $pQ = $prefix + 'q-'
    $hQa = Start-Holder $pQ 1 'qa'
    $hQb = Start-Holder $pQ 1 'qb' -From 1
    $wQ = Start-Waiter $pQ 2 'qw' -PollMs 600000
    $wQueued = Wait-ForFile $wQ.Queued 30 $wQ.Proc
    [IO.File]::WriteAllText($hQb.Release, 'go'); [void]$hQb.Proc.WaitForExit(10000)
    $nQ = Enter-TcGateSlots -Want 1 -Total 2 -Prefix $pQ -WaitSec 1 -PollMs 100
    $nQGot = $nQ.Count; $nQOut = $nQ.TimedOut; $nQAhead = $nQ.Ahead
    Exit-TcGateSlots $nQ
    T 'MUST FIRE  THE ORDER - a slot freed while a push is queued is that push''s: a run arriving after it does not take the slot, and is told 1 run is ahead of it' `
      ($hQa.Held -eq 1 -and $hQb.Held -eq 1 -and $wQueued -and $nQOut -and $nQGot -eq 0 -and $nQAhead -eq 1) ("holders={0}+{1} pushQueued={2} newcomerTimedOut={3} newcomerGot={4} ahead={5}" -f $hQa.Held, $hQb.Held, $wQueued, $nQOut, $nQGot, $nQAhead)
    $xQ = Enter-TcGateSlots -Want 1 -Total 2 -Prefix $pQ -Exact -WaitSec 1 -PollMs 100
    $xQGot = $xQ.Count; $xQOut = $xQ.TimedOut
    Exit-TcGateSlots $xQ
    T 'MUST FIRE  deliberate load yields to a queued push - an -Exact request for the one free slot does not take it while a gate run waits' `
      ($wQueued -and $xQOut -and $xQGot -eq 0) ("pushQueued={0} exactTimedOut={1} exactGot={2}" -f $wQueued, $xQOut, $xQGot)
    try { $wQ.Proc.Kill() } catch { }
    [void]$wQ.Proc.WaitForExit(10000)
    $script:spokeQ = 0
    $kQ = Enter-TcGateSlots -Want 1 -Total 2 -Prefix $pQ -WaitSec 5 -PollMs 100 -OnWait { $script:spokeQ++ }
    $kQGot = $kQ.Count
    Exit-TcGateSlots $kQ
    $qDir = Get-TcGateQueueDir -Prefix $pQ
    $qLeft = if (Test-Path -LiteralPath $qDir) { ([IO.Directory]::GetFiles($qDir, '*.ticket')).Count } else { 0 }
    T 'CLEAN TWIN a push KILLED while queued does not hold the queue - its ticket''s mutex went with it, so the next run takes the free slot on its first try and the dead ticket is swept' `
      ($kQGot -eq 1 -and $script:spokeQ -eq 0 -and $qLeft -eq 0) ("got={0} spoke={1} ticketsLeft={2}" -f $kQGot, $script:spokeQ, $qLeft)
    [IO.File]::WriteAllText($hQa.Release, 'go'); [void]$hQa.Proc.WaitForExit(10000)

    $pGq = $prefix + 'gq-'
    $lG = Enter-TcGateSlots -Want 1 -Total 2 -Prefix $pGq -WaitSec 5 -PollMs 100
    $hGb = Start-Holder $pGq 1 'gqb' -From 1
    $wG = Start-Waiter $pGq 2 'gqw' -PollMs 600000
    $wGQueued = Wait-ForFile $wG.Queued 30 $wG.Proc
    [IO.File]::WriteAllText($hGb.Release, 'go'); [void]$hGb.Proc.WaitForExit(10000)
    Add-TcGateSlots -Lease $lG -Want 2
    $gHeld = $lG.Count
    T 'MUST FIRE  a running pool does not top itself up past a queued push - Add-TcGateSlots leaves the freed slot for the run that is waiting' `
      ($lG.Mutexes.Count -eq 1 -and $hGb.Held -eq 1 -and $wGQueued -and $gHeld -eq 1) ("leaseStart=1 holder={0} pushQueued={1} afterTopUp={2}" -f $hGb.Held, $wGQueued, $gHeld)
    try { $wG.Proc.Kill() } catch { }
    [void]$wG.Proc.WaitForExit(10000)
    Add-TcGateSlots -Lease $lG -Want 2
    $gGrown = $lG.Count
    T 'CLEAN TWIN once nobody is queued, the same top-up takes the free slot' `
      ($gGrown -eq 2) ("afterQueueEmptied={0}" -f $gGrown)
    Exit-TcGateSlots $lG

    $pO = $prefix + 'o-'
    $hOa = Start-Holder $pO 1 'oa'
    $hOb = Start-Holder $pO 1 'ob' -From 1
    $w1 = Start-Waiter $pO 2 'o1' -PollMs 100
    $w1Queued = Wait-ForFile $w1.Queued 30 $w1.Proc
    $w2 = Start-Waiter $pO 2 'o2' -PollMs 100
    $w2Queued = Wait-ForFile $w2.Queued 30 $w2.Proc
    # THE HEARTBEAT'S OWN HALF: backdate the younger push's ticket an hour and wait for its owner to touch it again.
    $oTickets = @([IO.Directory]::GetFiles((Get-TcGateQueueDir -Prefix $pO), '*.ticket') | Sort-Object)
    $touched = $false
    if ($oTickets.Count -eq 2) {
      $oYoung = $oTickets[1]
      $back = [DateTime]::UtcNow.AddHours(-1)
      [IO.File]::SetLastWriteTimeUtc($oYoung, $back)
      $swT = [Diagnostics.Stopwatch]::StartNew()
      while (-not $touched -and $swT.Elapsed.TotalSeconds -lt 30) {
        if ([IO.File]::GetLastWriteTimeUtc($oYoung) -gt $back.AddMinutes(30)) { $touched = $true } else { Start-Sleep -Milliseconds 50 }
      }
    }
    T 'CLEAN TWIN a queued push keeps its own ticket fresh - backdated an hour, it is touched again on the owner''s next poll, so a long wait never ages out of its turn' `
      ($oTickets.Count -eq 2 -and $touched) ("tickets={0} touchedAgain={1}" -f $oTickets.Count, $touched)
    [IO.File]::WriteAllText($hOb.Release, 'go'); [void]$hOb.Proc.WaitForExit(10000)
    $w1First = Wait-ForFile $w1.Granted 30 $w1.Proc
    $w2Early = Test-Path -LiteralPath $w2.Granted
    [IO.File]::WriteAllText($hOa.Release, 'go'); [void]$hOa.Proc.WaitForExit(10000)
    $w2Then = Wait-ForFile $w2.Granted 30 $w2.Proc
    T 'CLEAN TWIN two pushes queued in turn are granted in turn, both polling - the first slot freed goes to the older, and the younger gets the next' `
      ($hOa.Held -eq 1 -and $hOb.Held -eq 1 -and $w1Queued -and $w2Queued -and $w1First -and -not $w2Early -and $w2Then) ("queued={0},{1} olderGrantedFirst={2} youngerGrantedEarly={3} youngerGrantedNext={4}" -f $w1Queued, $w2Queued, $w1First, $w2Early, $w2Then)
    [IO.File]::WriteAllText($w1.Release, 'go'); [IO.File]::WriteAllText($w2.Release, 'go')
    [void]$w1.Proc.WaitForExit(10000); [void]$w2.Proc.WaitForExit(10000)

    # A ticket whose owner is ALIVE - this process holds its mutex - but whose heartbeat stopped an hour ago.
    $pStale = $prefix + 's-'
    $sDir = Get-TcGateQueueDir -Prefix $pStale
    $sId = [guid]::NewGuid().ToString('N')
    $sMx = New-Object System.Threading.Mutex($false, ($pStale + 'q-' + $sId))
    $null = [IO.Directory]::CreateDirectory($sDir)
    $sPath = Join-Path $sDir ('{0:D19}-{1}-g-100.ticket' -f [DateTime]::UtcNow.AddHours(-1).Ticks, $sId)
    [IO.File]::WriteAllText($sPath, 'fixture: an owner that is alive and has stopped polling')
    [IO.File]::SetLastWriteTimeUtc($sPath, [DateTime]::UtcNow.AddHours(-1))
    $sAheadStale = Get-TcGateQueueAhead -Prefix $pStale
    $script:spokeS = 0
    $lS = Enter-TcGateSlots -Want 1 -Total 1 -Prefix $pStale -WaitSec 5 -PollMs 100 -OnWait { $script:spokeS++ }
    $sGot = $lS.Count
    Exit-TcGateSlots $lS
    T 'MUST NOT FIRE  a queued run that is alive but has stopped polling - its ticket an hour stale - does not hold every push behind it' `
      ($sAheadStale -eq 0 -and $sGot -eq 1 -and $script:spokeS -eq 0) ("ahead={0} got={1} spoke={2}" -f $sAheadStale, $sGot, $script:spokeS)
    [IO.File]::SetLastWriteTimeUtc($sPath, [DateTime]::UtcNow)
    $sAheadFresh = Get-TcGateQueueAhead -Prefix $pStale
    T 'CLEAN TWIN the same ticket touched just now counts as queued ahead - the heartbeat goes stale, not the ticket' `
      ($sAheadFresh -eq 1) ("ahead={0}" -f $sAheadFresh)
    try { [IO.File]::Delete($sPath) } catch { }
    $sMx.Dispose()

    # A QUEUE IT CANNOT WRITE MUST NOT REFUSE THE PUSH. A file sitting where the queue directory would go makes
    # every ticket attempt fail; the run says so and waits out of turn, which is the behaviour this change replaced,
    # and the budget still decides. Refusing here would be a new way to block every push on the box.
    $pBlock = $prefix + 'bq-'
    $blockPath = Get-TcGateQueueDir -Prefix $pBlock
    [IO.File]::WriteAllText($blockPath, 'fixture: not a directory')
    $hBq = Start-Holder $pBlock 1 'bq'
    $relBq = $hBq.Release
    $releaserBq = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-Command', ("Start-Sleep -Milliseconds 1500; [IO.File]::WriteAllText('{0}', 'go')" -f $relBq)) -PassThru -WindowStyle Hidden
    $holders.Add($releaserBq)
    $lBq = Enter-TcGateSlots -Want 1 -Total 1 -Prefix $pBlock -WaitSec 30 -PollMs 100
    $bqGot = $lBq.Count; $bqErr = [string]$lBq.QueueError
    Exit-TcGateSlots $lBq
    T 'MUST NOT FIRE  a queue directory that cannot be written does not refuse a push - the run says why, waits out of turn as it did before there was a queue, and is gated' `
      ($hBq.Held -eq 1 -and $bqGot -eq 1 -and $bqErr.Length -gt 0) ("holder={0} got={1} queueError={2}" -f $hBq.Held, $bqGot, $bqErr)
    Remove-Item -LiteralPath $blockPath -Force -ErrorAction SilentlyContinue

    $pX = $prefix + 'x-'
    $hXa = Start-Holder $pX 1 'xa'
    $eX = Start-Waiter $pX 2 'xw' -PollMs 600000 -Want 2 -Exact
    $eXQueued = Wait-ForFile $eX.Queued 30 $eX.Proc
    $lX = Enter-TcGateSlots -Want 1 -Total 2 -Prefix $pX -WaitSec 5 -PollMs 100
    $xGot = $lX.Count; $xOut = $lX.TimedOut
    Exit-TcGateSlots $lX
    T 'MUST NOT FIRE  a queued -Exact load does not hold back a gate run - the run takes the free slot at once' `
      ($hXa.Held -eq 1 -and $eXQueued -and -not $xOut -and $xGot -eq 1) ("holder={0} exactQueued={1} timedOut={2} got={3}" -f $hXa.Held, $eXQueued, $xOut, $xGot)
    try { $eX.Proc.Kill() } catch { }
    [void]$eX.Proc.WaitForExit(10000)
    [IO.File]::WriteAllText($hXa.Release, 'go'); [void]$hXa.Proc.WaitForExit(10000)
  } catch {
    $f++
    Write-Output ("FAIL  the suite threw after {0} case(s) and did not finish: {1} (line {2})" -f $cases, $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
  } finally {
    foreach ($p in $holders) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    # Every fixture queue, including one a killed waiter left.
    foreach ($leaf in @('a-', 'b-', 'c-', 'd-', 'e-', 'f-', 'j-', 'g-', 'h-', 'i-', 'k-', 'q-', 'gq-', 'o-', 's-', 'x-', 'bq-')) {
      Remove-Item -LiteralPath (Get-TcGateQueueDir -Prefix ($prefix + $leaf)) -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  if ($cases -ne $expectCases) { Write-Output ("FAIL  ran {0} case(s) of the {1} this suite lists - a case that never ran proved nothing" -f $cases, $expectCases); $f++ }
  if ($f) { Write-Output ("SELF-TEST FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("SELF-TEST PASS: {0} cases - {1} must-fire led by a full machine refusing a new run and a queued push keeping its turn, {2} must-not-fire led by a lone run getting its whole want, and {3} clean twins led by a killed run freeing its slots at once" -f $cases, $mf, $mnf, $ct)
  exit 0
}
