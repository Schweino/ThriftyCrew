<#
  chain-queue.ps1 - An ORDERED machine-wide queue of chain-touching pushes, where each ticket rehearses on the tip of
  the tickets ahead of it and swaps only after they have landed or left.

  Dot-source:  . (Join-Path $repoRoot 'lib\chain-queue.ps1')
  Self-test:   powershell -File lib\chain-queue.ps1 -SelfTest
  Interface:   design\backlog-inbox\pd-queue-interface-2026-09-23.md (what push-main does at each step)
  Spec:        design\PLAN-push-derived-conflicts-2026-09-23.md, section 16.3, W9.2 (replaces W6.1's lease)

  WHY (2026-09-23). Of 23 chain-touching landings measured after the rehearsal gate, 13 missed an early verdict, and
  12 of those 13 were voided by one or two OTHER chain landings between the commit and the push (plan 16.1). A chain
  push is a rehearsal of about 14 minutes plus its legs; optimistic concurrency pays only at low contention
  (concurrency-craft/concurrency-correctness.md section 5), and at 2 or 3 chain pushes in flight every one voids the
  others. So the chain path gets ORDERING: a member's rehearsal is of origin PLUS every range queued ahead of it, and
  it swaps only after those have landed, so the members ahead cannot void it.

  THE QUEUE IS lib\gate-slots.ps1's TICKET MECHANISM, DELIBERATELY NOT A SECOND COPY, the way lib\push-lock.ps1 wraps
  it. New-TcGateTicket gives arrival order (a ticket's name is its arrival time in ticks), Test-TcGateTicketLive gives
  liveness by the ticket's MUTEX and never its file, Get-TcGateQueueAhead -Sweep removes a dead ticket's file, and
  Remove-TcGateTicket leaves. Those rules were measured and fixtured there. What is NEW here, and what this file's
  fixtures pin: a JSON RECORD beside each ticket (range, state, rh_key), the STACK FILE built from the records ahead,
  the HEAD WAIT that clears on landed, left or dead, and the RESTACK rule. This file NEVER calls Enter-TcGateSlots: the
  queue grants no slot, so it excludes nobody from running a leg.

  LOCK ORDER 0b (plan 16.6), and it is NOT a lock held across a leg. While a member holds a ticket every other push,
  member or not, runs run-gates, test-auditors and its rehearsal freely. The only thing a ticket defers is the NEXT
  member's SWAP, which refs/heads/main serialises already, so this serialises the push and never the gate (Brad,
  2026-09-12). A holder then waits on the push lock (1), gate slots (2) and a rehearsal slot (2b, another process), so
  the ticket sits outside all three. Its own blocking wait, for the tickets ahead, is safe under the blocking-wait
  rule: a ticket ahead never waits on anything behind it, and no holder of the push lock, a gate slot or a rehearsal
  slot ever waits on a ticket. The hook's W8.3 probe (Test-TcChainQueueHolderToken, Get-TcChainQueueLive) waits on
  nothing.

  THE BOUND, stated beside the fix as the ops rules require (ORDER DECIDES WHICH PUSHES ARE REFUSED, NEVER HOW MANY).
  The queue orders chain landings and adds no rehearsal capacity. The ceiling is the rehearsal slots divided by the
  rehearsal's length: 6 slots over 800 to 1,240 s is about 17 to 27 chain landings an hour (review), against about 4.2
  an hour offered at the 09-19 peak (plan). Its cost is head-of-line: a member ready before the one ahead waits for it,
  up to that member's remaining rehearsal (about 21 minutes, review). It cannot livelock: the only re-rehearsal is a
  restack after a ticket ahead left, died or changed its key, and every one of those removes or changes a ticket AHEAD,
  which a finite queue can do only finitely often.

  EVERY FAILURE DEGRADES TO THE DAY BEFORE (ops rules, "EVERY LOCK PATH DEGRADES TO THE DAY BEFORE"). A queue that
  cannot be created, read or written returns Queue = 'error' with the reason in words, and the caller proceeds as the
  W2.2R path does: unqueued, gated no less. A waiter whose queue has not moved for $script:TcChainQueueStallSec
  returns 'timeout' and proceeds the same way. Nothing here refuses a push. The ONE throw is Assert-TcChainQueueInstance,
  which refuses the PRODUCTION prefix or root while TC_CHAIN_QUEUE_SELFTEST is set, so a fixture that forgets its seam
  is red rather than queueing real pushes behind itself.

  THE RECORD IS WRITTEN AFTER THE TICKET FILE, and that is the one place this file breaks "write the pointed-to object
  first", on purpose. New-TcGateTicket names the ticket and writes its file in one call, and changing it would move
  the harness of two recorded measurements (design\MEASURE-gate-queue-window-2026-09-11.md and
  MEASURE-gate-slot-admission-2026-09-11.md). So a reader that finds a LIVE ticket with no record waits for the record
  up to $script:TcChainQueueRecordWaitSec (a hang guard: the joiner writes it within milliseconds), and a record still
  missing after that makes the STACK not Ok, which the caller reads as queue=error. Never a guess at a range.

  ONE THREAD. A ticket's mutex belongs to the thread that joined, and a mutex is RE-ENTRANT for its owner: a probe of
  your own ticket from your own thread takes it and reads it as DEAD. So nothing here probes the caller's own ticket,
  Exit must run on the joining thread, and every fixture below puts each competing member in its own process.

  SCOPE OF A CLEAN REPORT: the self-test proves on this machine, with every competing member in its own process, that
  the production instance is refused under the self-test variable, that a stack lists origin plus exactly the ranges
  of the live tickets ahead, that a member's head wait does not return until the ticket ahead has landed (read by a
  probe from another process), that a ticket that leaves, dies or changes its key restacks and one that lands does not,
  that a frozen head times a waiter out naming the holder, that -Mode off creates nothing, that an unwritable root is
  an error and not a throw, and that a waiting member holds neither the push lock nor a gate slot. It proves nothing
  about push-main's use of it; ops\drill-chain-queue.ps1 drives the whole sequence through real git in a sandbox.

  NO param() BLOCK: dot-sourced under PS 5.1 a param() block runs in the CALLER's scope (lib\guard-contract.ps1).
#>
# USE WHEN: order chain-touching pushes so each rehearses on the tickets ahead of it and swaps only after they land; Join-TcChainQueue, New-TcChainStackFile, Wait-TcChainQueueHead and Exit-TcChainQueue bracket push-main's chain path (design\backlog-inbox\pd-queue-interface-2026-09-23.md), so a session lands a chain change through push-main rather than calling this directly
# ENFORCED BY: none (none)
# gate-inputs: lib\chain-queue.ps1, lib\gate-slots.ps1, lib\push-lock.ps1, lib\atomic-write.ps1, lib\mutex-hold.ps1
$__cqSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
. (Join-Path $PSScriptRoot 'push-lock.ps1')     # Test-TcProcessAlive, and through it lib\gate-slots.ps1's tickets
. (Join-Path $PSScriptRoot 'atomic-write.ps1')  # Write-TcAtomicFile: a record is read by other processes mid-rewrite

$script:TcChainQueuePrefix = 'Global\tc-chain-queue-'
# Per user, like the gate queue and the push lock and for the same reason: every session on this box runs as one user
# and every push-main must see one queue. A name deliberately shared across runs; the self-test uses a per-run root.
$script:TcChainQueueRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ThriftyCrew\chain-queue'
$script:TcChainQueueEnvVar = 'TC_CHAIN_QUEUE_HOLDER'
$script:TcChainQueueSelfTestEnvVar = 'TC_CHAIN_QUEUE_SELFTEST'
# Plan 16.3 W9.2 step 8: the bound on time WITHOUT QUEUE MOVEMENT, the first plausible value above the longest single
# state a head ticket holds (one rehearsal plus its legs and 3 hand-backs, about 45 minutes). NOT SWEPT. What it does
# when the producer stops: a head that stops moving times its waiters out after an hour and they proceed unqueued, so
# a wedge costs the queue's ordering and never a push. A queue that keeps moving never times anybody out, however long
# it is, because a waiter that leaves a moving queue lands unstacked and voids the tickets behind it.
$script:TcChainQueueStallSec = 3600
# How often a waiter prints its position and depth (step 5). A report interval, not a control constant.
$script:TcChainQueueReportSec = 300
# How often a waiter re-reads the queue. First plausible; one directory listing and a few small reads per poll.
$script:TcChainQueuePollMs = 1000
# A HANG GUARD, not a tuned number: how long a reader waits for the record of a live ticket whose joiner has written
# the ticket file and not yet the record (the header's THE RECORD IS WRITTEN AFTER THE TICKET FILE).
$script:TcChainQueueRecordWaitSec = 30
# Records outlive their tickets so a landed ticket stays distinguishable from a dead one; a join sweeps the old ones.
$script:TcChainQueueRecordKeepHours = 24
$script:TcChainQueueStates = @('rehearsing', 'ready', 'swapping', 'landed', 'left')

function Get-TcChainQueueFullRoot([string]$Root) {
  try { return ([IO.Path]::GetFullPath($Root)).TrimEnd('\', '/') } catch { return ([string]$Root).TrimEnd('\', '/') }
}

function Assert-TcChainQueueInstance {
  <# THE ONE THROW. While TC_CHAIN_QUEUE_SELFTEST is set, the production prefix or the production root is refused, so a
     self-test that forgot to pass its private instance fails loudly instead of standing in the real queue. #>
  param([string]$Prefix = $script:TcChainQueuePrefix, [string]$QueueRoot = $script:TcChainQueueRoot)
  $flag = [Environment]::GetEnvironmentVariable($script:TcChainQueueSelfTestEnvVar)
  if (-not $flag) { return }
  if ([string]::Equals($Prefix, $script:TcChainQueuePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw ('chain-queue: the production prefix ' + $script:TcChainQueuePrefix + ' was used while ' + $script:TcChainQueueSelfTestEnvVar + ' is set; a self-test must pass its own -Prefix')
  }
  if ([string]::Equals((Get-TcChainQueueFullRoot $QueueRoot), (Get-TcChainQueueFullRoot $script:TcChainQueueRoot), [StringComparison]::OrdinalIgnoreCase)) {
    throw ('chain-queue: the production queue root ' + $script:TcChainQueueRoot + ' was used while ' + $script:TcChainQueueSelfTestEnvVar + ' is set; a self-test must pass its own -QueueRoot')
  }
}

function Read-TcChainQueueRecord {
  <# One record, or $null. Opened sharing ReadWrite and Delete, so a reader never costs its writer the replace
     (the ops rule: a lock-free reader can cost a locked writer its write). #>
  param([string]$Path)
  if (-not $Path -or -not [IO.File]::Exists($Path)) { return $null }
  try {
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $sr = New-Object IO.StreamReader($fs, (New-Object Text.UTF8Encoding($false))); $txt = $sr.ReadToEnd() } finally { $fs.Dispose() }
    if (-not $txt.Trim()) { return $null }
    return ($txt | ConvertFrom-Json)
  } catch { return $null }
}

function Get-TcChainRecordRange($Rec) {
  if (-not $Rec -or $null -eq $Rec.range) { return @() }
  $out = @()
  foreach ($s in @($Rec.range)) { if ($s) { $out += [string]$s } }
  return , $out
}

function New-TcChainMember {
  param([string]$Prefix, [string]$QueueRoot, [string]$Checkout)
  return [pscustomobject]@{
    Queue = 'error'; Reason = ''; Name = ''; Position = 0; Token = ''; Prefix = $Prefix; QueueRoot = $QueueRoot
    Dir = (Get-TcGateQueueDir -Prefix $Prefix -Root $QueueRoot); RecordPath = ''; Record = $null; Ticket = $null
    Checkout = $Checkout; Stacks = 0; Restacks = 0; StackState = 'none'; LastStack = $null; ConflictWith = $null
    WaitMs = 0.0; AheadAtTimeout = ''; Final = ''
  }
}

function Save-TcChainMemberRecord {
  <# Writes the member's in-memory record. $true, or $false when it could not (the caller degrades, never refuses). #>
  param($Member)
  if (-not $Member -or -not $Member.RecordPath -or -not $Member.Record) { return $false }
  $Member.Record['seq'] = [int]$Member.Record['seq'] + 1
  $Member.Record['updated_utc'] = [DateTime]::UtcNow.ToString('o')
  try {
    $json = ConvertTo-Json -InputObject $Member.Record -Depth 5 -Compress
    $null = Write-TcAtomicFile -Path $Member.RecordPath -Text $json -NoBom -NoNewline
    return $true
  } catch { return $false }
}

function Join-TcChainQueue {
  <# Takes a ticket for a chain-touching push. Returns a MEMBER whose .Queue is 'joined', 'off' or 'error' (the
     interface file has the whole contract). Never throws except from Assert-TcChainQueueInstance. #>
  param(
    [string]$Checkout = '',
    [string]$Base = '',
    [string[]]$Range = @(),
    [ValidateSet('live', 'off')][string]$Mode = 'live',
    [string]$Prefix = $script:TcChainQueuePrefix,
    [string]$QueueRoot = $script:TcChainQueueRoot
  )
  Assert-TcChainQueueInstance -Prefix $Prefix -QueueRoot $QueueRoot
  $m = New-TcChainMember -Prefix $Prefix -QueueRoot $QueueRoot -Checkout $Checkout
  if ($Mode -eq 'off') {
    # THE ROLLBACK (step 9). Not even the directory is created, so an 'off' push leaves no trace a probe could read.
    $m.Queue = 'off'; $m.Reason = '-ChainQueue off: the queue was not opened'
    return $m
  }
  $t = $null
  try {
    $why = ''
    $t = New-TcGateTicket -Prefix $Prefix -Dir $m.Dir -Why ([ref]$why)
    if (-not $t) { $m.Reason = ('the chain queue could not be joined: ' + $why); return $m }
    $m.Ticket = $t; $m.Name = $t.Name
    $m.RecordPath = Join-Path $m.Dir ($t.Name + '.json')
    $rng = @(); foreach ($s in @($Range)) { if ($s) { $rng += [string]$s } }
    $m.Record = [ordered]@{
      ticket = $t.Name; pid = $PID; checkout = $Checkout; base = $Base; range = $rng; state = 'rehearsing'
      rh_key = ''; rh_range = @(); updated_utc = ''; seq = 0; final_utc = ''
    }
    if (-not (Save-TcChainMemberRecord $m)) {
      Remove-TcGateTicket $t; $m.Ticket = $null
      $m.Reason = 'the chain queue record could not be written beside ticket ' + $t.Name
      return $m
    }
    $aheadAll = Get-TcChainQueueAheadList -Member $m
    $ahead = @($aheadAll)
    $m.Position = @($ahead | Where-Object { -not $_.Cleared }).Count
    Clear-TcChainQueueOldRecords -Dir $m.Dir
    $m.Token = '{0}|{1}|{2}' -f $PID, $t.Name, $Prefix
    Set-Item -LiteralPath ('Env:' + $script:TcChainQueueEnvVar) -Value $m.Token
    $m.Queue = 'joined'; $m.Reason = 'joined'
    return $m
  } catch {
    if ($t) { Remove-TcGateTicket $t }
    $m.Ticket = $null
    $m.Queue = 'error'; $m.Reason = ('the chain queue could not be joined: ' + $_.Exception.Message)
    return $m
  }
}

function Clear-TcChainQueueOldRecords {
  <# Removes records whose ticket file is gone and which are older than the keep window. Housekeeping only: a failure
     here changes no decision, so it is swallowed. #>
  param([string]$Dir)
  try {
    $cut = [DateTime]::UtcNow.AddHours(-$script:TcChainQueueRecordKeepHours)
    foreach ($j in [IO.Directory]::GetFiles($Dir, '*.json')) {
      $nm = [IO.Path]::GetFileNameWithoutExtension($j)
      if ([IO.File]::Exists((Join-Path $Dir ($nm + '.ticket')))) { continue }
      if ([IO.File]::GetLastWriteTimeUtc($j) -lt $cut) { try { [IO.File]::Delete($j) } catch { } }
    }
  } catch { }
}

function Get-TcChainQueueEntry {
  <# One ticket by name: its record, whether its mutex is held, and whether it is CLEARED (landed, left, or dead). A
     live ticket whose record has not appeared is waited for up to the record hang guard when -NeedRecord. #>
  param([string]$Dir, [string]$Prefix, [string]$Name, [switch]$NeedRecord)
  $rp = Join-Path $Dir ($Name + '.json')
  $rec = Read-TcChainQueueRecord $rp
  $state = if ($rec) { [string]$rec.state } else { '' }
  $final = ($state -eq 'landed' -or $state -eq 'left')
  $live = $false
  if (-not $final) {
    $live = [IO.File]::Exists((Join-Path $Dir ($Name + '.ticket'))) -and (Test-TcGateTicketLive -Prefix $Prefix -Name $Name)
    if ($live -and -not $rec -and $NeedRecord) {
      $sw = [Diagnostics.Stopwatch]::StartNew()
      while (-not $rec -and $sw.Elapsed.TotalSeconds -lt $script:TcChainQueueRecordWaitSec) {
        Start-Sleep -Milliseconds 25
        $rec = Read-TcChainQueueRecord $rp
      }
      if ($rec) { $state = [string]$rec.state; $final = ($state -eq 'landed' -or $state -eq 'left') }
    }
  }
  $pidv = 0; $co = ''
  if ($rec) { try { $pidv = [int]$rec.pid } catch { }; $co = [string]$rec.checkout }
  return [pscustomobject]@{
    Name = $Name; Live = $live; State = $state; Record = $rec; Cleared = ($final -or -not $live)
    Pid = $pidv; Checkout = $co
  }
}

function Get-TcChainQueueAheadList {
  <# Every ticket FILE that sorts before the member's, oldest first, as entries. Never probes the member's own ticket. #>
  param($Member, [switch]$NeedRecord)
  $out = @()
  if (-not $Member -or -not $Member.Name -or -not [IO.Directory]::Exists($Member.Dir)) { return , $out }
  $names = @()
  foreach ($f in [IO.Directory]::GetFiles($Member.Dir, '*.ticket')) {
    $nm = [IO.Path]::GetFileNameWithoutExtension($f)
    if ([string]::CompareOrdinal($nm, $Member.Name) -lt 0) { $names += $nm }
  }
  $sorted = [string[]]$names
  [Array]::Sort($sorted, [StringComparer]::Ordinal)
  foreach ($nm in $sorted) { $out += (Get-TcChainQueueEntry -Dir $Member.Dir -Prefix $Member.Prefix -Name $nm -NeedRecord:$NeedRecord) }
  return , $out
}

function Get-TcChainQueueAhead {
  <# The live, uncleared tickets ahead of the member, oldest first. #>
  param($Member)
  $all = Get-TcChainQueueAheadList -Member $Member
  return , @($all | Where-Object { -not $_.Cleared })
}

function New-TcChainStackFile {
  <# Writes the per-run stack file W9.1 step 1 reads: line 1 is -Origin, then the range of every live ticket ahead that
     has not landed or left, in ticket order, oldest first. The member's OWN range is not in it. Returns a STACK. #>
  param($Member, [string]$Origin, [string]$Path)
  $st = [pscustomobject]@{ Ok = $false; Path = $Path; Base = $Origin; Ahead = @(); Lines = @(); Reason = '' }
  try {
    if (-not $Member -or $Member.Queue -ne 'joined' -or -not $Member.Ticket) { $st.Reason = 'not a queue member'; return $st }
    if ($Origin -notmatch '^[0-9a-f]{40}$') { $st.Reason = 'origin is not a full sha: ' + $Origin; return $st }
    $lines = @($Origin); $ahead = @()
    $list = Get-TcChainQueueAheadList -Member $Member -NeedRecord
    foreach ($e in @($list)) {
      if ($e.Cleared) { continue }
      if (-not $e.Record) { $st.Reason = ('ticket ' + $e.Name + ' ahead is live and wrote no record within ' + $script:TcChainQueueRecordWaitSec + ' s'); return $st }
      $rng = Get-TcChainRecordRange $e.Record
      foreach ($s in $rng) {
        if ($s -notmatch '^[0-9a-f]{40}$') { $st.Reason = ('ticket ' + $e.Name + ' ahead records a range entry that is not a full sha: ' + $s); return $st }
        $lines += $s
      }
      $ahead += [pscustomobject]@{
        Name = $e.Name; Pid = $e.Pid; Checkout = $e.Checkout; Range = $rng; RhKey = [string]$e.Record.rh_key
        Seq = [int]$e.Record.seq
      }
    }
    [IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    $st.Ahead = $ahead; $st.Lines = $lines; $st.Ok = $true
    $Member.Stacks++
    $Member.Restacks = [Math]::Max(0, $Member.Stacks - 1)
    $Member.LastStack = $st
    $Member.StackState = 'ok'
    $Member.ConflictWith = $null
    return $st
  } catch {
    $st.Ok = $false; $st.Reason = ('the stack file could not be built: ' + $_.Exception.Message)
    return $st
  }
}

function Set-TcChainQueueState {
  <# Rewrites the member's record. -Base and -Range after every worktree rebase; -RhKey when a verdict for the stacked
     tip is recorded or found (it stamps rh_range, the range that key was computed for). -State for rehearsing, ready
     and swapping; the final landed and left belong to Exit-TcChainQueue. $true, or $false when nothing was written. #>
  param($Member, [string]$State = '', [string]$Base = '', [string[]]$Range = $null, [string]$RhKey = $null)
  if (-not $Member -or $Member.Queue -notin @('joined', 'timeout') -or -not $Member.Ticket -or -not $Member.Record) { return $false }
  if ($State) {
    if ($State -notin @('rehearsing', 'ready', 'swapping')) { throw ('Set-TcChainQueueState: unknown or final state ' + $State + '; landed and left are written by Exit-TcChainQueue') }
    $Member.Record['state'] = $State
  }
  if ($Base) { $Member.Record['base'] = $Base }
  # A PRESENCE QUESTION IS ASKED WITH ContainsKey: a [string] parameter bound to nothing reads as '', never $null, so
  # "-ne $null" would rewrite rh_key to empty on every call (found by the keep-the-key case below).
  if ($PSBoundParameters.ContainsKey('Range')) { $r = @(); foreach ($s in @($Range)) { if ($s) { $r += [string]$s } }; $Member.Record['range'] = $r }
  if ($PSBoundParameters.ContainsKey('RhKey')) { $Member.Record['rh_key'] = $RhKey; $Member.Record['rh_range'] = @($Member.Record['range']) }
  return (Save-TcChainMemberRecord $Member)
}

function Test-TcChainStackMoved {
  <# Did any ticket in the stack move so that the stacked key moves? A ticket that LANDED did not (its commits are now
     origin's). One that LEFT, DIED without landing, or recorded a DIFFERENT rh_key did. While a stacked ticket had no
     key when the stack was built, its first key is ADOPTED when it was computed for the range that was stacked, and
     otherwise its range is compared. Returns the reason in words, or '' when nothing moved. #>
  param($Member, $Stack)
  if (-not $Stack -or -not $Stack.Ok) { return '' }
  foreach ($a in @($Stack.Ahead)) {
    $e = Get-TcChainQueueEntry -Dir $Member.Dir -Prefix $Member.Prefix -Name $a.Name
    if ($e.State -eq 'landed') { continue }
    if ($e.State -eq 'left') { return ('ticket ' + $a.Name + ' ahead left the queue') }
    if (-not $e.Live) { return ('ticket ' + $a.Name + ' ahead died without landing') }
    $rec = $e.Record
    if (-not $rec) { continue }
    $recKey = [string]$rec.rh_key
    if (-not $a.RhKey -and $recKey) {
      $kr = (Get-TcChainRecordRange ([pscustomobject]@{ range = $rec.rh_range })) -join ','
      if ([string]::Equals($kr, (@($a.Range) -join ','), [StringComparison]::Ordinal)) { $a.RhKey = $recKey; continue }
      return ('ticket ' + $a.Name + ' ahead recorded a key for a range this stack did not hold')
    }
    if ($a.RhKey -and $recKey) {
      if (-not [string]::Equals($a.RhKey, $recKey, [StringComparison]::Ordinal)) { return ('ticket ' + $a.Name + ' ahead changed its rehearsal key') }
      continue
    }
    $now = (Get-TcChainRecordRange $rec) -join ','
    if (-not [string]::Equals($now, (@($a.Range) -join ','), [StringComparison]::Ordinal)) { return ('ticket ' + $a.Name + ' ahead rewrote its range') }
  }
  return ''
}

function Wait-TcChainQueueHead {
  <# Blocks until every ticket ahead is landed, left or dead, holding nothing but the ticket. Outcome 'head',
     'restack', 'timeout' or 'error' (the interface file). A push that holds no ticket gets 'head' at once: nothing is
     ahead of a push that is not queued. #>
  param(
    $Member,
    $Stack = $null,
    [int]$StallSec = $script:TcChainQueueStallSec,
    [int]$PollMs = $script:TcChainQueuePollMs,
    [int]$ReportEverySec = $script:TcChainQueueReportSec,
    [scriptblock]$OnReport = $null
  )
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $res = [pscustomobject]@{ Outcome = 'head'; WaitedMs = 0.0; Position = 0; Head = $null; Reason = '' }
  if (-not $Member -or $Member.Queue -ne 'joined' -or -not $Member.Ticket) { $res.Reason = 'not a queue member'; return $res }
  $stall = New-TcGateQueueState
  $reportSw = [Diagnostics.Stopwatch]::StartNew()
  try {
    while ($true) {
      $null = Get-TcGateQueueAhead -Dir $Member.Dir -Prefix $Member.Prefix -Before $Member.Name -Sweep
      $moved = Test-TcChainStackMoved -Member $Member -Stack $Stack
      if ($moved) { $res.Outcome = 'restack'; $res.Reason = $moved; break }
      $pendingAll = Get-TcChainQueueAhead -Member $Member
      $pending = @($pendingAll)
      $res.Position = $pending.Count
      if ($pending.Count -eq 0) { $res.Outcome = 'head'; $res.Reason = 'every ticket ahead has landed, left or died'; break }
      if (Step-TcGateQueueWait -State $stall -Ahead $pending.Count -NowMs $sw.Elapsed.TotalMilliseconds -WaitSec $StallSec) {
        $h = $pending[0]
        $res.Outcome = 'timeout'
        $res.Head = [pscustomobject]@{ Name = $h.Name; Pid = $h.Pid; Checkout = $h.Checkout; State = $h.State }
        $res.Reason = ('the chain queue did not move for {0}s; the head is ticket {1} (pid {2}, {3}, state {4})' -f $StallSec, $h.Name, $h.Pid, $h.Checkout, $h.State)
        $Member.Queue = 'timeout'
        $Member.AheadAtTimeout = ('{0}:{1}' -f $h.Pid, $h.Checkout)
        break
      }
      if ($OnReport -and $reportSw.Elapsed.TotalSeconds -ge $ReportEverySec) {
        $reportSw.Restart()
        & $OnReport $pending.Count $pending.Count ([int]$sw.Elapsed.TotalSeconds) | Out-Default
      }
      Start-Sleep -Milliseconds $PollMs
    }
  } catch {
    $res.Outcome = 'error'; $res.Reason = ('the chain queue could not be read: ' + $_.Exception.Message)
    $Member.Queue = 'error'
  }
  $res.WaitedMs = $sw.Elapsed.TotalMilliseconds
  $Member.WaitMs = [double]$Member.WaitMs + $res.WaitedMs
  return $res
}

function Resolve-TcChainStackCommit {
  <# The ahead entry of $Stack whose range holds $Sha, or $null (the member's own commit, or not in the stack). #>
  param($Stack, [string]$Sha)
  if (-not $Stack -or -not $Sha) { return $null }
  foreach ($a in @($Stack.Ahead)) {
    foreach ($s in @($a.Range)) { if ([string]::Equals($s, $Sha, [StringComparison]::OrdinalIgnoreCase)) { return $a } }
  }
  return $null
}

function Set-TcChainStackConflict {
  <# Records a stack conflict (step 7): a WARNING, never a refusal. The member keeps its place. The ticket named is the
     one whose range holds the commit the cherry-pick stopped on; when it stopped on the member's OWN commit, the
     caller names the ahead ticket whose range touched the conflicting files with -Ticket (it can run git; this
     cannot). #>
  param($Member, $Stack, [string]$Sha, [string[]]$Files = @(), [string]$Ticket = '')
  if (-not $Member) { return $null }
  $Member.StackState = 'conflict'
  $a = Resolve-TcChainStackCommit -Stack $Stack -Sha $Sha
  if (-not $a -and $Ticket -and $Stack) { foreach ($x in @($Stack.Ahead)) { if ($x.Name -eq $Ticket) { $a = $x; break } } }
  $Member.ConflictWith = if ($a) { [pscustomobject]@{ Name = $a.Name; Pid = $a.Pid; Checkout = $a.Checkout; Files = @($Files); Sha = $Sha } } else { [pscustomobject]@{ Name = ''; Pid = 0; Checkout = ''; Files = @($Files); Sha = $Sha } }
  return $Member.ConflictWith
}

function Exit-TcChainQueue {
  <# Leaves the queue as 'landed' or 'left'. Safe with $null, twice, and on 'off' or 'error'. Same thread as the join.
     The record is kept (a landed ticket must stay distinguishable from a dead one). #>
  param($Member, [ValidateSet('landed', 'left')][string]$State = 'left')
  if (-not $Member -or -not $Member.Ticket) { return }
  if ($Member.Record) {
    $Member.Record['state'] = $State
    $Member.Record['final_utc'] = [DateTime]::UtcNow.ToString('o')
    $null = Save-TcChainMemberRecord $Member
  }
  Remove-TcGateTicket $Member.Ticket
  $Member.Ticket = $null
  $Member.Final = $State
  try {
    $cur = [string](Get-Item -LiteralPath ('Env:' + $script:TcChainQueueEnvVar) -ErrorAction SilentlyContinue).Value
    if ($cur -and [string]::Equals($cur, $Member.Token, [StringComparison]::Ordinal)) {
      Remove-Item -LiteralPath ('Env:' + $script:TcChainQueueEnvVar) -ErrorAction SilentlyContinue
    }
  } catch { }
}

function Test-TcChainQueueHolderToken {
  <# For the hook's W8.3 probe: does this TC_CHAIN_QUEUE_HOLDER value name a live ticket of THIS instance? The token
     names its instance, as TC_PUSH_LOCK_HOLDER learnt to: a token taken on another prefix is never an inheritance. #>
  param([string]$Token, [string]$Prefix = $script:TcChainQueuePrefix, [string]$QueueRoot = $script:TcChainQueueRoot)
  Assert-TcChainQueueInstance -Prefix $Prefix -QueueRoot $QueueRoot
  if (-not $Token) { return $false }
  if ($Token -notmatch '^(\d+)\|(\d{19}-\d+-[0-9a-f]{8})\|(.+)$') { return $false }
  $tp = [int]$Matches[1]; $tn = $Matches[2]; $tpre = $Matches[3]
  if (-not [string]::Equals($tpre, $Prefix, [StringComparison]::Ordinal)) { return $false }
  if (-not (Test-TcProcessAlive -ProcessId $tp)) { return $false }
  $dir = Get-TcGateQueueDir -Prefix $Prefix -Root $QueueRoot
  if (-not [IO.File]::Exists((Join-Path $dir ($tn + '.ticket')))) { return $false }
  return (Test-TcGateTicketLive -Prefix $Prefix -Name $tn)
}

function Get-TcChainQueueLive {
  <# The live tickets of an instance, oldest first. Waits on nothing. Never call it from a thread holding a ticket and
     expect to see that ticket (a mutex is re-entrant for its owner). #>
  param([string]$Prefix = $script:TcChainQueuePrefix, [string]$QueueRoot = $script:TcChainQueueRoot)
  Assert-TcChainQueueInstance -Prefix $Prefix -QueueRoot $QueueRoot
  $dir = Get-TcGateQueueDir -Prefix $Prefix -Root $QueueRoot
  $out = @()
  if (-not [IO.Directory]::Exists($dir)) { return , $out }
  $names = @()
  try { foreach ($f in [IO.Directory]::GetFiles($dir, '*.ticket')) { $names += [IO.Path]::GetFileNameWithoutExtension($f) } } catch { return , $out }
  $sorted = [string[]]$names
  [Array]::Sort($sorted, [StringComparer]::Ordinal)
  foreach ($nm in $sorted) {
    $e = Get-TcChainQueueEntry -Dir $dir -Prefix $Prefix -Name $nm
    if ($e.Live) { $out += $e }
  }
  return , $out
}

function Get-TcChainQueueRow {
  <# The W9.2 step 11 row fields, to merge into push-main's W0.1R row. #>
  param($Member)
  $row = [ordered]@{ queue = 'not-chain'; queue_pos = 0; queue_wait_ms = 0; queue_ahead = ''; stacked_on = ''; restacks = 0; stack = 'none' }
  if (-not $Member) { return $row }
  $row.queue = [string]$Member.Queue
  $row.queue_pos = [int]$Member.Position
  $row.queue_wait_ms = [int][Math]::Round([double]$Member.WaitMs)
  $row.queue_ahead = [string]$Member.AheadAtTimeout
  if ($Member.LastStack -and $Member.LastStack.Ok) {
    $b = [string]$Member.LastStack.Base
    $row.stacked_on = ('{0}+{1}' -f $b.Substring(0, [Math]::Min(9, $b.Length)), @($Member.LastStack.Ahead).Count)
  }
  $row.restacks = [int]$Member.Restacks
  $row.stack = [string]$Member.StackState
  return $row
}

if ($__cqSelfTest) {
  $ErrorActionPreference = 'Stop'
  $f = 0; $cases = 0
  # THE LITERAL COUNT. This suite's cases are a literal list, so it knows its own number and a shortfall is a defect
  # (ops rules, A SUITE WHOSE CASES ARE A LITERAL LIST ASSERTS HOW MANY RAN).
  $expected = 29
  # Kind names by concatenation, so these lines are not counted as assertions by ops\audit-mustfire-census.ps1.
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  $kinds = @{ $kMF = 0; $kMNF = 0; $kCT = 0 }
  function T($m, $cond, $got) {
    $script:cases++
    foreach ($k in @($kMNF, $kMF, $kCT)) { if (([string]$m).StartsWith($k)) { $script:kinds[$k]++; break } }
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }
  . (Join-Path $PSScriptRoot 'mutex-hold.ps1')
  $PSExe = (Get-Command powershell).Source
  # A PRIVATE INSTANCE PER RUN: a Local\ prefix and a per-run root. This self-test runs inside run-gates, which a real
  # push may be running under, so it must never stand in the real chain queue.
  $prefix = 'Local\tc-cq-st-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '-'
  $tmp = Join-Path $env:TEMP ('tc-cq-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $tmp
  $qroot = Join-Path $tmp 'q'
  $prevFlag = [Environment]::GetEnvironmentVariable($script:TcChainQueueSelfTestEnvVar)
  $prevTok = [Environment]::GetEnvironmentVariable($script:TcChainQueueEnvVar)
  $env:TC_CHAIN_QUEUE_SELFTEST = '1'
  Remove-Item -LiteralPath ('Env:' + $script:TcChainQueueEnvVar) -ErrorAction SilentlyContinue
  $kids = [Collections.Generic.List[object]]::new()
  function Sha([string]$Seed) {
    $h = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Seed))
    return (($h | ForEach-Object { $_.ToString('x2') }) -join '')
  }
  $origin = Sha 'origin'

  # AN AHEAD MEMBER IS ANOTHER PROCESS (the header's ONE THREAD). It joins, reports its ticket, then runs commands the
  # parent writes one file at a time and acknowledges each, so every case drives it by CONDITION, never by clock.
  # Commands: rhkey:<k>  range:<csv>  state:<s>  exit:<landed|left>  die  await:<path>:<state,state>  wait  quit.
  function Start-Member([string]$Name, [string[]]$Range, [string]$Checkout) {
    $body = @'
$ErrorActionPreference = 'Stop'
$env:TC_CHAIN_QUEUE_SELFTEST = '1'
. '__LIB__'
$d = '__TMP__'; $n = '__NAME__'
$rng = @('__RANGE__' -split ',' | Where-Object { $_ })
$m = Join-TcChainQueue -Checkout '__CO__' -Base '__ORIGIN__' -Range $rng -Prefix '__PFX__' -QueueRoot '__QROOT__'
[IO.File]::WriteAllText((Join-Path $d ($n + '.joined')), ('{0}|{1}|{2}' -f $m.Queue, $m.Name, $m.Token))
$i = 0
while ($true) {
  $cf = Join-Path $d ('{0}.cmd.{1}' -f $n, $i)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not [IO.File]::Exists($cf)) { Start-Sleep -Milliseconds 10; if ($sw.Elapsed.TotalSeconds -gt 180) { exit 9 } }
  $c = [IO.File]::ReadAllText($cf).Trim()
  $ack = 'ok'
  if ($c -like 'rhkey:*') { $null = Set-TcChainQueueState -Member $m -RhKey $c.Substring(6) }
  elseif ($c -like 'range:*') { $null = Set-TcChainQueueState -Member $m -Range @($c.Substring(6) -split ',' | Where-Object { $_ }) }
  elseif ($c -like 'state:*') { $null = Set-TcChainQueueState -Member $m -State $c.Substring(6) }
  elseif ($c -like 'exit:*') { Exit-TcChainQueue -Member $m -State $c.Substring(5) }
  elseif ($c -eq 'die') { [IO.File]::WriteAllText((Join-Path $d ('{0}.ack.{1}' -f $n, $i)), 'dying'); [Environment]::Exit(7) }
  elseif ($c -like 'await:*') {
    $p = $c.Substring(6); $cut = $p.LastIndexOf(':'); $rp = $p.Substring(0, $cut); $want = @($p.Substring($cut + 1) -split ',')
    $sw2 = [Diagnostics.Stopwatch]::StartNew(); $seen = ''
    while ($sw2.Elapsed.TotalSeconds -lt 120) {
      $r = Read-TcChainQueueRecord $rp
      if ($r -and ($want -contains [string]$r.state)) { $seen = [string]$r.state; break }
      Start-Sleep -Milliseconds 5
    }
    $ack = 'saw=' + $seen
  }
  elseif ($c -like 'wait*') {
    $st = New-TcChainStackFile -Member $m -Origin '__ORIGIN__' -Path (Join-Path $d ($n + '.stack'))
    $null = Set-TcChainQueueState -Member $m -State ready
    $w = Wait-TcChainQueueHead -Member $m -Stack $st -StallSec 120 -PollMs 20
    $ack = 'outcome=' + $w.Outcome
  }
  elseif ($c -eq 'quit') { Exit-TcChainQueue -Member $m -State left; [IO.File]::WriteAllText((Join-Path $d ('{0}.ack.{1}' -f $n, $i)), 'bye'); exit 0 }
  else { $ack = 'unknown command ' + $c }
  [IO.File]::WriteAllText((Join-Path $d ('{0}.ack.{1}' -f $n, $i)), $ack)
  $i++
}
'@
    $body = $body.Replace('__LIB__', $PSCommandPath).Replace('__TMP__', $tmp).Replace('__NAME__', $Name).Replace('__RANGE__', ($Range -join ','))
    $body = $body.Replace('__CO__', $Checkout).Replace('__ORIGIN__', $origin).Replace('__PFX__', $prefix).Replace('__QROOT__', $qroot)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $p = Start-Process -FilePath $PSExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru -WindowStyle Hidden
    $null = $p.Handle
    $script:kids.Add($p)
    $jf = Join-Path $tmp ($Name + '.joined')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($jf) -and -not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt 90) { Start-Sleep -Milliseconds 20 }
    $parts = if ([IO.File]::Exists($jf)) { @([IO.File]::ReadAllText($jf) -split '\|') } else { @('never', '', '') }
    $o = [pscustomobject]@{ Name = $Name; Proc = $p; Queue = $parts[0]; Ticket = $parts[1]; Token = ($parts[2..($parts.Count - 1)] -join '|'); Next = 0 }
    $o | Add-Member -NotePropertyName RecordPath -NotePropertyValue (Join-Path (Get-TcGateQueueDir -Prefix $prefix -Root $qroot) ($o.Ticket + '.json'))
    return $o
  }
  # Sends one command; with -NoWait returns at once (the ack is read later by Read-Ack), otherwise waits for its ack.
  function Send-Cmd($M, [string]$Cmd, [switch]$NoWait) {
    $i = $M.Next; $M.Next++
    [IO.File]::WriteAllText((Join-Path $tmp ('{0}.cmd.{1}' -f $M.Name, $i)), $Cmd)
    if ($NoWait) { return $i }
    return (Read-Ack $M $i)
  }
  function Read-Ack($M, [int]$I, [int]$Sec = 120) {
    $af = Join-Path $tmp ('{0}.ack.{1}' -f $M.Name, $I)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($af) -and $sw.Elapsed.TotalSeconds -lt $Sec) { Start-Sleep -Milliseconds 10 }
    if (-not [IO.File]::Exists($af)) { return 'no-ack' }
    Start-Sleep -Milliseconds 5
    return [IO.File]::ReadAllText($af).Trim()
  }
  function Stop-Member($M) {
    if (-not $M) { return }
    if (-not $M.Proc.HasExited) { $null = Send-Cmd $M 'quit' -NoWait; $null = $M.Proc.WaitForExit(30000) }
  }
  # A PROBE IS A THIRD PROCESS. It polls the two records and logs, the FIRST time it reads the member in state
  # 'swapping', what state the ticket ahead was in at that read. The ahead lands only on the parent's command, which
  # the ordering case sends only after the member's wait has refused to say 'head', so no clock decides the case.
  function Start-OrderProbe([string]$AheadRec, [string]$MemberRec, [string]$Out) {
    $body = @'
. '__LIB__'
[IO.File]::WriteAllText('__OUT__.up', 'up')
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt 150) {
  $mr = Read-TcChainQueueRecord '__MREC__'
  $ms = if ($mr) { [string]$mr.state } else { '' }
  if ($ms -eq 'swapping') {
    $ar = Read-TcChainQueueRecord '__AREC__'
    $as = if ($ar) { [string]$ar.state } else { 'no-record' }
    [IO.File]::WriteAllText('__OUT__', ('ahead=' + $as)); exit 0
  }
  Start-Sleep -Milliseconds 2
}
[IO.File]::WriteAllText('__OUT__', 'ahead=never-saw-swapping')
'@
    $body = $body.Replace('__LIB__', $PSCommandPath).Replace('__MREC__', $MemberRec).Replace('__AREC__', $AheadRec).Replace('__OUT__', $Out)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $p = Start-Process -FilePath $PSExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru -WindowStyle Hidden
    $script:kids.Add($p)
    $null = Wait-File ($Out + '.up') 60
    return $p
  }
  # A TICKET WATCHER counts the .ticket files it ever sees in a queue directory until told to stop: "a probe from
  # another process sees none throughout".
  function Start-TicketWatch([string]$Dir, [string]$Out, [string]$Stop) {
    $body = @'
$max = 0; $dirSeen = 0; $sw = [Diagnostics.Stopwatch]::StartNew()
[IO.File]::WriteAllText('__OUT__.up', 'up')
while (-not [IO.File]::Exists('__STOP__') -and $sw.Elapsed.TotalSeconds -lt 120) {
  if ([IO.Directory]::Exists('__DIR__')) { $dirSeen = 1; $n = @([IO.Directory]::GetFiles('__DIR__', '*.ticket')).Count; if ($n -gt $max) { $max = $n } }
  Start-Sleep -Milliseconds 2
}
[IO.File]::WriteAllText('__OUT__', ('{0}|{1}' -f $max, $dirSeen))
'@
    $body = $body.Replace('__DIR__', $Dir).Replace('__OUT__', $Out).Replace('__STOP__', $Stop)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $p = Start-Process -FilePath $PSExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru -WindowStyle Hidden
    $script:kids.Add($p)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($Out + '.up') -and $sw.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 20 }
    return $p
  }
  function Wait-File([string]$P, [int]$Sec = 120) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists($P) -and $sw.Elapsed.TotalSeconds -lt $Sec) { Start-Sleep -Milliseconds 10 }
    return [IO.File]::Exists($P)
  }
  $qdir = Get-TcGateQueueDir -Prefix $prefix -Root $qroot

  try {
    # ---- the production instance is refused under the self-test variable ----
    $threw = ''
    try { $null = Join-TcChainQueue -Checkout 'x' -Base $origin -Prefix $script:TcChainQueuePrefix -QueueRoot $qroot } catch { $threw = $_.Exception.Message }
    T ($kMF + '  with TC_CHAIN_QUEUE_SELFTEST set, a join on the production prefix throws') ($threw -match 'production prefix') $threw
    $threw2 = ''
    try { $null = Join-TcChainQueue -Checkout 'x' -Base $origin -Prefix $prefix -QueueRoot $script:TcChainQueueRoot } catch { $threw2 = $_.Exception.Message }
    T ($kMF + '  with TC_CHAIN_QUEUE_SELFTEST set, a join on the production queue root throws') ($threw2 -match 'production queue root') $threw2
    $threw3 = ''
    try { $null = Test-TcChainQueueHolderToken -Token 'x' } catch { $threw3 = $_.Exception.Message }
    T ($kMF + '  with TC_CHAIN_QUEUE_SELFTEST set, the hook probe on the production instance throws too') ($threw3 -match 'production') $threw3

    # ---- a lone member ----
    $solo = Join-TcChainQueue -Checkout 'C:\co\solo' -Base $origin -Range @((Sha 's1')) -Prefix $prefix -QueueRoot $qroot
    $rec = Read-TcChainQueueRecord $solo.RecordPath
    T ($kCT + '  a private join takes a ticket at position 0 and writes its record with every field') `
      ($solo.Queue -eq 'joined' -and $solo.Position -eq 0 -and $rec -and $rec.state -eq 'rehearsing' -and [string]$rec.checkout -eq 'C:\co\solo' -and @($rec.range).Count -eq 1 -and $rec.base -eq $origin -and [int]$rec.pid -eq $PID -and $null -ne $rec.rh_key -and $rec.updated_utc) `
      ("queue={0} pos={1} rec={2}" -f $solo.Queue, $solo.Position, ($rec | ConvertTo-Json -Compress))
    T ($kCT + '  a joined member exports a holder token naming its instance and its ticket') `
      ($env:TC_CHAIN_QUEUE_HOLDER -eq $solo.Token -and $solo.Token -eq ('{0}|{1}|{2}' -f $PID, $solo.Name, $prefix)) ("env={0} token={1}" -f $env:TC_CHAIN_QUEUE_HOLDER, $solo.Token)
    $soloStack = New-TcChainStackFile -Member $solo -Origin $origin -Path (Join-Path $tmp 'solo.stack')
    $soloLines = @(Get-Content -LiteralPath (Join-Path $tmp 'solo.stack'))
    T ($kMNF + '  a lone member stacks on origin alone, and its OWN range is never in its stack file') `
      ($soloStack.Ok -and $soloLines.Count -eq 1 -and $soloLines[0] -eq $origin -and @($soloStack.Ahead).Count -eq 0) ("ok={0} lines={1}" -f $soloStack.Ok, ($soloLines -join ','))
    $bytes = [IO.File]::ReadAllBytes((Join-Path $tmp 'solo.stack'))
    T ($kCT + '  the stack file is LF with a trailing LF and no BOM, the shape rehearse-chain reads') `
      ($bytes.Length -eq 41 -and $bytes[40] -eq 10 -and $bytes[0] -ne 0xEF -and -not ($bytes -contains 13)) ("len={0}" -f $bytes.Length)
    $wSolo = Wait-TcChainQueueHead -Member $solo -Stack $soloStack -StallSec 30 -PollMs 20
    T ($kCT + '  a lone member is at the head at once') ($wSolo.Outcome -eq 'head' -and $wSolo.Position -eq 0) ("outcome={0}" -f $wSolo.Outcome)
    $probeTok = $solo.Token
    Exit-TcChainQueue -Member $solo -State landed
    $recAfter = Read-TcChainQueueRecord $solo.RecordPath
    T ($kCT + '  a landed exit keeps the record reading landed, removes the ticket file, and clears the token') `
      ($recAfter -and $recAfter.state -eq 'landed' -and -not [IO.File]::Exists((Join-Path $qdir ($solo.Name + '.ticket'))) -and -not $env:TC_CHAIN_QUEUE_HOLDER) `
      ("state={0} env={1}" -f $recAfter.state, $env:TC_CHAIN_QUEUE_HOLDER)
    Exit-TcChainQueue -Member $solo -State left
    T ($kMNF + '  a second exit is a no-op and cannot turn a landed ticket into a left one') ((Read-TcChainQueueRecord $solo.RecordPath).state -eq 'landed') 'the second exit rewrote the record'
    T ($kMF + '  a token whose ticket was released is not a live holder') (-not (Test-TcChainQueueHolderToken -Token $probeTok -Prefix $prefix -QueueRoot $qroot)) $probeTok

    # ---- the holder token from another process ----
    $a = Start-Member 'tok' @((Sha 't1')) 'C:\co\tok'
    T ($kCT + '  a live member''s token is read as live by the hook probe from another process') `
      ($a.Queue -eq 'joined' -and (Test-TcChainQueueHolderToken -Token $a.Token -Prefix $prefix -QueueRoot $qroot)) ("queue={0} token={1}" -f $a.Queue, $a.Token)
    $other = $a.Token -replace [regex]::Escape($prefix), 'Local\tc-cq-some-other-queue-'
    T ($kMF + '  a live token taken on ANOTHER queue instance is not an inheritance, and a malformed one is not live') `
      ((-not (Test-TcChainQueueHolderToken -Token $other -Prefix $prefix -QueueRoot $qroot)) -and (-not (Test-TcChainQueueHolderToken -Token 'yes' -Prefix $prefix -QueueRoot $qroot)) -and (-not (Test-TcChainQueueHolderToken -Token '' -Prefix $prefix -QueueRoot $qroot))) $other
    $liveAll = Get-TcChainQueueLive -Prefix $prefix -QueueRoot $qroot
    $live = @($liveAll)
    T ($kCT + '  the live listing the hook reads names that ticket with its checkout') ($live.Count -eq 1 -and $live[0].Name -eq $a.Ticket -and $live[0].Checkout -eq 'C:\co\tok') ("n={0}" -f $live.Count)
    Stop-Member $a

    # ---- stacking, and the ordering read by a probe from another process ----
    $r1 = @((Sha 'a1'), (Sha 'a2'))
    $ah = Start-Member 'ahead' $r1 'C:\co\ahead'
    $mb = Join-TcChainQueue -Checkout 'C:\co\member' -Base $origin -Range @((Sha 'm1')) -Prefix $prefix -QueueRoot $qroot
    $st = New-TcChainStackFile -Member $mb -Origin $origin -Path (Join-Path $tmp 'mb.stack')
    $lines = @(Get-Content -LiteralPath (Join-Path $tmp 'mb.stack'))
    T ($kMF + '  stacking: with a ticket ahead, the stack file is origin PLUS the ahead ticket''s range, oldest first, not origin alone') `
      ($st.Ok -and $mb.Position -eq 1 -and ($lines -join ',') -eq (@($origin) + $r1 -join ',') -and @($st.Ahead).Count -eq 1 -and $st.Ahead[0].Checkout -eq 'C:\co\ahead') `
      ("ok={0} pos={1} lines={2}" -f $st.Ok, $mb.Position, ($lines -join ','))
    $pout = Join-Path $tmp 'order.out'
    $null = Start-OrderProbe $ah.RecordPath $mb.RecordPath $pout
    $null = Set-TcChainQueueState -Member $mb -State ready
    # THE MEMBER SWAPS THE MOMENT ITS WAIT SAYS 'head'. With the ahead live and ready, a correct wait cannot say so,
    # so under a short bound it times out and the ahead is told to land only then. A wait that skips the ahead (M12)
    # says 'head' at once and the member swaps while the ahead has not even been told to land: the probe sees it.
    $w0 = Wait-TcChainQueueHead -Member $mb -Stack $st -StallSec 1 -PollMs 20
    $wo = $w0
    if ($w0.Outcome -ne 'head') {
      $mb.Queue = 'joined'
      $null = Send-Cmd $ah 'exit:landed'
      $wo = Wait-TcChainQueueHead -Member $mb -Stack $st -StallSec 120 -PollMs 20
    }
    $null = Set-TcChainQueueState -Member $mb -State swapping
    $null = Wait-File $pout 60
    $saw = if ([IO.File]::Exists($pout)) { [IO.File]::ReadAllText($pout) } else { 'no probe output' }
    $lk = Enter-TcPushLock -Prefix ($prefix + 'push-') -QueueRoot (Join-Path $tmp 'pq') -WaitSec 30 -PollMs 20 -NoInherit
    T ($kMF + '  ordering: a member whose legs finished first is not swapping until the ticket ahead has LANDED, read by a probe from another process before its first lock take') `
      ($w0.Outcome -eq 'timeout' -and $wo.Outcome -eq 'head' -and $saw -eq 'ahead=landed' -and $lk.Held) ("first={0} then={1} probe={2} lock={3}" -f $w0.Outcome, $wo.Outcome, $saw, $lk.Held)
    Exit-TcPushLock $lk
    T ($kCT + '  a ticket ahead that LANDED is not a restack: the member reached the head with restacks=0') `
      ($wo.Outcome -eq 'head' -and $mb.Restacks -eq 0 -and $mb.Stacks -eq 1) ("outcome={0} restacks={1}" -f $wo.Outcome, $mb.Restacks)
    Exit-TcChainQueue -Member $mb -State landed
    Stop-Member $ah

    # ---- restack on left, on death, and on a changed key; none on a rebase that kept the key ----
    $rL = @((Sha 'l1'))
    $al = Start-Member 'leaver' $rL 'C:\co\leaver'
    $ml = Join-TcChainQueue -Checkout 'C:\co\m2' -Base $origin -Range @((Sha 'm2')) -Prefix $prefix -QueueRoot $qroot
    $sl = New-TcChainStackFile -Member $ml -Origin $origin -Path (Join-Path $tmp 'ml.stack')
    $null = Send-Cmd $al 'exit:left'
    $wl = Wait-TcChainQueueHead -Member $ml -Stack $sl -StallSec 120 -PollMs 20
    $sl2 = New-TcChainStackFile -Member $ml -Origin $origin -Path (Join-Path $tmp 'ml2.stack')
    T ($kMF + '  restack: a ticket ahead that is refused turns left, and the member restacks onto origin alone with restacks=1') `
      ($wl.Outcome -eq 'restack' -and $wl.Reason -match 'left' -and $sl2.Ok -and @($sl2.Lines).Count -eq 1 -and $sl2.Lines[0] -eq $origin -and $ml.Restacks -eq 1 -and (Get-TcChainQueueRow $ml).restacks -eq 1) `
      ("outcome={0} reason={1} lines={2} restacks={3}" -f $wl.Outcome, $wl.Reason, @($sl2.Lines).Count, $ml.Restacks)
    Exit-TcChainQueue -Member $ml -State left
    Stop-Member $al

    $ad = Start-Member 'dier' @((Sha 'd1')) 'C:\co\dier'
    $md = Join-TcChainQueue -Checkout 'C:\co\m3' -Base $origin -Range @((Sha 'm3')) -Prefix $prefix -QueueRoot $qroot
    $sd = New-TcChainStackFile -Member $md -Origin $origin -Path (Join-Path $tmp 'md.stack')
    $null = Send-Cmd $ad 'die'
    $null = $ad.Proc.WaitForExit(30000)
    $wd = Wait-TcChainQueueHead -Member $md -Stack $sd -StallSec 120 -PollMs 20
    T ($kMF + '  restack: a ticket ahead that DIES without landing restacks the member, read from its abandoned mutex') `
      ($wd.Outcome -eq 'restack' -and $wd.Reason -match 'died') ("outcome={0} reason={1}" -f $wd.Outcome, $wd.Reason)
    Exit-TcChainQueue -Member $md -State left

    $rk = @((Sha 'k1'))
    $ak = Start-Member 'keyer' $rk 'C:\co\keyer'
    $mk = Join-TcChainQueue -Checkout 'C:\co\m4' -Base $origin -Range @((Sha 'm4')) -Prefix $prefix -QueueRoot $qroot
    $sk = New-TcChainStackFile -Member $mk -Origin $origin -Path (Join-Path $tmp 'mk.stack')
    # The ahead records its key for the range this member stacked, then rebases (a new range) and keeps the key: the
    # shape of a ticket whose own ticket-ahead landed. The member must adopt the key and NOT restack.
    $null = Send-Cmd $ak 'rhkey:KEY-A'
    $w1 = Wait-TcChainQueueHead -Member $mk -Stack $sk -StallSec 1 -PollMs 20
    $mk.Queue = 'joined'
    $null = Send-Cmd $ak ('range:' + (Sha 'k1-rebased'))
    $w2 = Wait-TcChainQueueHead -Member $mk -Stack $sk -StallSec 1 -PollMs 20
    T ($kCT + '  a ticket ahead that rebases and KEEPS its key is not a restack (the drill''s restacks=0 depends on it)') `
      ($w1.Outcome -eq 'timeout' -and $w2.Outcome -eq 'timeout' -and $sk.Ahead[0].RhKey -eq 'KEY-A') ("w1={0} w2={1} adopted={2} reason={3}" -f $w1.Outcome, $w2.Outcome, $sk.Ahead[0].RhKey, $w2.Reason)
    $mk.Queue = 'joined'
    $null = Send-Cmd $ak 'rhkey:KEY-B'
    $w3 = Wait-TcChainQueueHead -Member $mk -Stack $sk -StallSec 60 -PollMs 20
    T ($kMF + '  restack: a ticket ahead that records a DIFFERENT key restacks the member') ($w3.Outcome -eq 'restack' -and $w3.Reason -match 'key') ("outcome={0} reason={1}" -f $w3.Outcome, $w3.Reason)
    Exit-TcChainQueue -Member $mk -State left
    Stop-Member $ak

    # ---- the timed-out branch: a holder that never changes state, held from another process ----
    $fakeName = '{0:D19}-{1}-{2}' -f ([DateTime]::UtcNow.Ticks - 10000000), 4242, 'abcdef01'
    $null = [IO.Directory]::CreateDirectory($qdir)
    $hold = Start-TcMutexHold -Name ($prefix + 'q-' + $fakeName)
    [IO.File]::WriteAllText((Join-Path $qdir ($fakeName + '.ticket')), '4242')
    $fakeRec = [ordered]@{ ticket = $fakeName; pid = 4242; checkout = 'C:\co\frozen'; base = $origin; range = @((Sha 'f1')); state = 'ready'; rh_key = ''; rh_range = @(); updated_utc = ''; seq = 1; final_utc = '' }
    [IO.File]::WriteAllText((Join-Path $qdir ($fakeName + '.json')), (ConvertTo-Json -InputObject $fakeRec -Compress))
    $mt = Join-TcChainQueue -Checkout 'C:\co\m5' -Base $origin -Range @((Sha 'm5')) -Prefix $prefix -QueueRoot $qroot
    $stt = New-TcChainStackFile -Member $mt -Origin $origin -Path (Join-Path $tmp 'mt.stack')
    $wt = Wait-TcChainQueueHead -Member $mt -Stack $stt -StallSec 1 -PollMs 20
    $rowT = Get-TcChainQueueRow $mt
    T ($kMF + '  the timed-out branch: a head held by a frozen holder in another process and a lowered bound gives queue=timeout naming the holder') `
      ($hold.Held -and $wt.Outcome -eq 'timeout' -and $wt.Head.Checkout -eq 'C:\co\frozen' -and $wt.Head.Pid -eq 4242 -and $rowT.queue -eq 'timeout' -and $rowT.queue_ahead -eq '4242:C:\co\frozen') `
      ("held={0} outcome={1} row={2}" -f $hold.Held, $wt.Outcome, ($rowT | ConvertTo-Json -Compress))
    Exit-TcChainQueue -Member $mt -State left
    T ($kCT + '  a timed-out member leaves cleanly, so the push proceeds holding nothing') (-not $mt.Ticket -and (Read-TcChainQueueRecord $mt.RecordPath).state -eq 'left') 'the timed-out member still held its ticket'
    Stop-TcMutexHold $hold
    Remove-Item -LiteralPath (Join-Path $qdir ($fakeName + '.ticket')) -Force -ErrorAction SilentlyContinue

    # ---- the lock order: a waiting member holds neither the push lock nor a gate slot ----
    $h1 = Start-Member 'lo-head' @((Sha 'h1')) 'C:\co\lohead'
    $w8 = Start-Member 'lo-waiter' @((Sha 'w1')) 'C:\co\lowaiter'
    $iW = Send-Cmd $w8 'wait' -NoWait
    $null = Wait-File (Join-Path $tmp 'lo-waiter.stack') 60
    $wrec = $w8.RecordPath
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 60 -and (Read-TcChainQueueRecord $wrec).state -ne 'ready') { Start-Sleep -Milliseconds 20 }
    $plk = Enter-TcPushLock -Prefix ($prefix + 'push-') -QueueRoot (Join-Path $tmp 'pq') -WaitSec 10 -PollMs 20 -NoInherit
    $gsl = Enter-TcGateSlots -Want 1 -Total 1 -Prefix ($prefix + 'gate-') -QueueRoot (Join-Path $tmp 'gq') -WaitSec 10 -PollMs 20
    $waitingStill = -not (Wait-File (Join-Path $tmp ('lo-waiter.ack.' + $iW)) 0)
    T ($kMNF + '  the lock order: while a member waits for the head, another process takes the push lock and a gate slot, so the ticket holds neither') `
      ($waitingStill -and (Read-TcChainQueueRecord $wrec).state -eq 'ready' -and $plk.Held -and $gsl.Count -eq 1) ("waiting={0} lock={1} slot={2}" -f $waitingStill, $plk.Held, $gsl.Count)
    Exit-TcGateSlots $gsl; Exit-TcPushLock $plk
    $null = Send-Cmd $h1 'exit:landed'
    $ackW = Read-Ack $w8 $iW
    T ($kCT + '  that waiter reaches the head once the ticket ahead lands') ($ackW -eq 'outcome=head') $ackW
    Stop-Member $w8; Stop-Member $h1

    # ---- the stack conflict names the ticket ahead ----
    $rc = @((Sha 'c1'), (Sha 'c2'))
    $ac = Start-Member 'conflicter' $rc 'C:\co\conflicter'
    $mc = Join-TcChainQueue -Checkout 'C:\co\m6' -Base $origin -Range @((Sha 'm6')) -Prefix $prefix -QueueRoot $qroot
    $sc = New-TcChainStackFile -Member $mc -Origin $origin -Path (Join-Path $tmp 'mc.stack')
    $cw = Set-TcChainStackConflict -Member $mc -Stack $sc -Sha $rc[1] -Files @('ops/x.ps1')
    $own = Resolve-TcChainStackCommit -Stack $sc -Sha (Sha 'm6')
    $rowC = Get-TcChainQueueRow $mc
    T ($kMF + '  the stack conflict names the ticket ahead whose commit stopped the cherry-pick, and the row reads stack=conflict') `
      ($cw.Checkout -eq 'C:\co\conflicter' -and $cw.Name -eq $ac.Ticket -and $rowC.stack -eq 'conflict' -and $null -eq $own -and $mc.Ticket) `
      ("with={0} row={1}" -f $cw.Checkout, ($rowC | ConvertTo-Json -Compress))
    T ($kCT + '  the row carries every W9.2 step 11 field') `
      (@('queue', 'queue_pos', 'queue_wait_ms', 'queue_ahead', 'stacked_on', 'restacks', 'stack' | Where-Object { $rowC.Contains($_) }).Count -eq 7 -and $rowC.stacked_on -eq ($origin.Substring(0, 9) + '+1') -and $rowC.queue_pos -eq 1) ($rowC | ConvertTo-Json -Compress)
    Exit-TcChainQueue -Member $mc -State left
    Stop-Member $ac

    # ---- the rollback, and a broken queue ----
    $offRoot = Join-Path $tmp 'offq'
    $offDir = Get-TcGateQueueDir -Prefix $prefix -Root $offRoot
    $wout = Join-Path $tmp 'watch.out'; $wstop = Join-Path $tmp 'watch.stop'
    $null = Start-TicketWatch $offDir $wout $wstop
    $off = Join-TcChainQueue -Mode off -Checkout 'C:\co\off' -Base $origin -Range @((Sha 'o1')) -Prefix $prefix -QueueRoot $offRoot
    $offStack = New-TcChainStackFile -Member $off -Origin $origin -Path (Join-Path $tmp 'off.stack')
    $offWait = Wait-TcChainQueueHead -Member $off -StallSec 5 -PollMs 20
    Exit-TcChainQueue -Member $off
    [IO.File]::WriteAllText($wstop, 'stop')
    $null = Wait-File $wout 60
    $wv = if ([IO.File]::Exists($wout)) { [IO.File]::ReadAllText($wout) } else { 'never' }
    T ($kCT + '  the rollback: -Mode off takes no ticket (a probe from another process sees none throughout), creates no directory, and records queue=off') `
      ($off.Queue -eq 'off' -and $wv -eq '0|0' -and -not [IO.Directory]::Exists($offDir) -and (Get-TcChainQueueRow $off).queue -eq 'off' -and -not $offStack.Ok -and $offWait.Outcome -eq 'head' -and -not $env:TC_CHAIN_QUEUE_HOLDER) `
      ("queue={0} watch={1} dir={2}" -f $off.Queue, $wv, [IO.Directory]::Exists($offDir))
    $fileRoot = Join-Path $tmp 'not-a-dir'
    [IO.File]::WriteAllText($fileRoot, 'a file where the queue root goes')
    $er = $null; $erThrew = ''
    try { $er = Join-TcChainQueue -Checkout 'C:\co\err' -Base $origin -Range @((Sha 'e1')) -Prefix $prefix -QueueRoot $fileRoot } catch { $erThrew = $_.Exception.Message }
    T ($kCT + '  an unwritable queue root records queue=error with its reason in words, and never throws') `
      ($er -and $er.Queue -eq 'error' -and $er.Reason -match 'could not be joined' -and -not $erThrew -and -not $er.Ticket -and (Get-TcChainQueueRow $er).queue -eq 'error') `
      ("queue={0} reason={1} threw={2}" -f $(if ($er) { $er.Queue } else { '' }), $(if ($er) { $er.Reason } else { '' }), $erThrew)
  } catch {
    T ('SELF-TEST ABORTED  ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber) $false 'threw'
  } finally {
    foreach ($p in $kids) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    try { Stop-TcMutexHold } catch { }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($prevFlag) { $env:TC_CHAIN_QUEUE_SELFTEST = $prevFlag } else { Remove-Item -LiteralPath Env:TC_CHAIN_QUEUE_SELFTEST -ErrorAction SilentlyContinue }
    if ($prevTok) { $env:TC_CHAIN_QUEUE_HOLDER = $prevTok } else { Remove-Item -LiteralPath Env:TC_CHAIN_QUEUE_HOLDER -ErrorAction SilentlyContinue }
  }

  if ($cases -ne $expected) { Write-Output ("chain-queue self-test FAIL: ran {0} case(s), the literal list holds {1}" -f $cases, $expected); exit 1 }
  if ($f) { Write-Output ("chain-queue self-test FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("chain-queue self-test PASS: {0} cases - {1} must-fire led by the ordering case a probe reads from another process, {2} must-not-fire led by a waiting member holding neither the push lock nor a gate slot, and {3} clean twins led by a landed ticket ahead not restacking the member" -f $cases, $kinds[$kMF], $kinds[$kMNF], $kinds[$kCT])
  exit 0
}
