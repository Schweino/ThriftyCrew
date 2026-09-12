<#
  push-lock.ps1 - ONE machine-wide push at a time, so a push that passed its gate is not beaten to the ref by a push
  that started later.

  Dot-source:  . (Join-Path $repoRoot 'lib\push-lock.ps1')
  Self-test:   powershell -File lib\push-lock.ps1 -SelfTest

  WHY (2026-09-11, design\PLAN-push-livelock-2026-09-11.md). git fixes a push's refs when it connects, and the remote
  updates a ref only if it STILL holds the sha the hook was handed. So a push is a compare-and-swap whose critical
  section is the WHOLE pre-push hook. Measured that day across 11 consecutive attempts from one session: the hook took
  577 to 1,840 s, run-gates passed every single time, and every attempt was rejected with "cannot lock ref
  'refs/heads/main' ... is at X but expected Y" while other sessions landed every 15 to 25 minutes.

  That is not bad luck and it is not a gate defect. It is optimistic concurrency control with no contention
  management, and its known failure is the STARVATION OF THE LONGEST TRANSACTION: when a critical section is longer
  than the interval between conflicting commits, it converges on never committing, and each retry restarts the clock.
  The retry is not even free - the session must rebase, a rebase is genuinely new content, so lib\gate-verdict.ps1
  correctly declines to reuse the pass and all 341 to 368 gates run again.

  SERIALISING COSTS NO THROUGHPUT, and that is the objection to answer first. refs/heads/main is ALREADY serialised:
  one push lands at a time whatever anyone does. Today's parallelism is not parallel landing, it is parallel GATING of
  which all but one result is thrown away. N sessions each pay T and N-1 of those T are discarded, so landings per
  hour are 1/T; under the lock one session pays T and lands while the others wait paying nothing, so landings per hour
  are still 1/T - and every discarded T goes back to the machine. The measured landing rate (one per 15 to 25 min
  against a 10 to 30 min hook) is that same number, which is the estate already running at the serial ceiling and
  paying about 4x for it. ops\probe-push-throughput.ps1 is the harness that holds this claim to account.

  IT IS A FAIRNESS DEVICE AND NEVER A SAFETY DEVICE. The GATE is what makes a push safe. Nothing here decides
  anything about a tree, so a lock that is bypassed, inherited or wedged is not a hole in anything - its worst case is
  exactly the behaviour measured above. That is why EVERY failure path degrades to today's behaviour instead of
  refusing: this lock's caller is a hook in the SHARED .git standing in front of every checkout on the box, most of
  them older than this file, and a fairness optimisation must never become the reason nobody can push.

  THE QUEUE IS lib\gate-slots.ps1's, DELIBERATELY NOT A SECOND COPY. A push lock is that queue with a budget of one:
  a ticket named by arrival time, slots served to the oldest LIVE ticket, liveness carried by the ticket's MUTEX and
  never by its file, and a wait bounded by "the queue stopped moving for WaitSec" rather than by a total. Those rules
  were measured and fixtured there on 2026-09-11 (a probe served the first arrival 6th, 8th and 5th of 8 before they
  landed); re-implementing them here would be a second copy to drift, and the estate's own rule is that a defence
  worth having twice is worth a case per copy. So this file's fixtures pin what is NEW - mutual exclusion at a budget
  of one, token inheritance, and the degrade-to-unlocked failure mode - and arrival order stays pinned where it lives.

  INHERITANCE, and why it exists. ops\push-main.ps1 takes this lock BEFORE it fetches and rebases, which is the only
  place the rebase can be guaranteed not to go stale. It then runs `git push`, whose pre-push hook would try to take
  the same lock from a grandchild process - and a Windows mutex is not recursive across processes, so that is a
  deadlock against itself. The holder exports TC_PUSH_LOCK_HOLDER=<pid>|<guid>|<prefix>; a descendant that sees it,
  can see that pid is still alive, AND is asking for the same lock, returns an INHERITED lease that holds nothing and
  releases nothing. A token left behind by a dead holder is ignored and the lock is taken for real, and so is one
  taken on a DIFFERENT lock - see Test-TcPushLockTokenLive for the day that cost.

  SCOPE OF A CLEAN REPORT: a granted lease proves this process holds the one machine-wide push mutex for as long as
  it lives. It proves nothing about a pusher that does not call this (an older checkout, --no-verify, a push from
  another machine), and nothing about whether the push it protects should land - only the gate says that.

  NO param() BLOCK: dot-sourced under PS 5.1 a param() block runs in the CALLER's scope (lib\guard-contract.ps1).
#>
$__plkSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')
. (Join-Path $PSScriptRoot 'gate-slots.ps1')   # the arrival-order queue; no param() block, so it cannot reset ours

# ONE. Not a tuning constant and not a sweep: it is the number of pushes refs/heads/main can accept at once, which is
# a property of git and not of this box. Registered in docs\CONTROL-CONSTANTS.md as fixed by the mechanism.
$script:TcPushLockTotal = 1
$script:TcPushLockPrefix = 'Global\tc-push-lock-'
# Per user, like the gate queue and for the same reason: every session on this box runs as one user and must see one
# queue. A name deliberately shared across runs, so it is fixed rather than per-run; the self-test points its own at a
# per-run directory under a private Local\ prefix.
$script:TcPushLockQueueRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ThriftyCrew\push-lock-queue'
$script:TcPushLockEnvVar = 'TC_PUSH_LOCK_HOLDER'

function Test-TcProcessAlive {
  <# Is this pid a live process? A probe that cannot look answers LIVE, because treating a holder as dead on a guess
     would hand the lock out twice - the one outcome this file exists to prevent. #>
  param([int]$ProcessId)
  if ($ProcessId -le 0) { return $false }
  try {
    $p = Get-Process -Id $ProcessId -ErrorAction Stop
    return ($null -ne $p)
  } catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
    return $false
  } catch {
    return $true
  }
}

function Test-TcPushLockTokenLive {
  <# A TC_PUSH_LOCK_HOLDER value names a live holder OF THIS LOCK. '' is no token. A token whose pid is gone is stale:
     the holder died without clearing its environment, and its descendants must take the lock for real rather than
     assume it.

     THE TOKEN CARRIES THE PREFIX IT WAS TAKEN ON, and a mismatch is NOT an inheritance (2026-09-11, found by
     run-gates refusing this very change). The first version was `<pid>:<guid>` and recorded nothing about WHICH lock
     it held, so anything asking for a different lock inherited it. That is not only a fixture problem: run-gates
     runs under ops\push-main.ps1, which holds the real Global\ lock, so every suite that redirects to a private
     Local\ lock was handed `inherited` and believed it held a lock nobody had taken - `ops\hold-push-lock.ps1` and
     `ops\test-prepush-hook.ps1` both went red for it, which is the gate doing its job. It is the
     identity-graph-commodity-is-namespaced shape: an agreeing answer about something else. #>
  param([string]$Token, [string]$Prefix = $script:TcPushLockPrefix)
  if (-not $Token) { return $false }
  if ($Token -notmatch '^(\d+)\|[0-9a-f]{8,}\|(.+)$') { return $false }
  if (-not [string]::Equals($Matches[2], $Prefix, [StringComparison]::Ordinal)) { return $false }
  return (Test-TcProcessAlive -ProcessId ([int]$Matches[1]))
}

function New-TcPushLockLease {
  param([bool]$Held, $Lease, [bool]$Inherited, [double]$WaitedMs, [bool]$TimedOut, [int]$Ahead, [string]$Reason, [string]$Token)
  return [pscustomobject]@{
    Held = $Held; Lease = $Lease; Inherited = $Inherited; WaitedMs = $WaitedMs
    TimedOut = $TimedOut; Ahead = $Ahead; Reason = $Reason; Token = $Token
  }
}

function Enter-TcPushLock {
  <# Take the one machine-wide push lock. Returns Held, Inherited, WaitedMs, TimedOut, Ahead and Reason.

     Held = $true  - this process (or an ancestor, when Inherited) holds it. Pass the whole object to Exit-TcPushLock.
     Held = $false - it was NOT taken, and Reason says why in words. THE CALLER PROCEEDS UNLOCKED, loudly. This is a
                     fairness device: refusing here would turn a wedged queue into a box nobody can push from, which
                     is worse than the livelock it exists to fix.

     OnWait runs once, the first time this call has to wait, and is handed the number of pushes queued ahead of it.
     WaitSec bounds how long the queue may go without MOVING, not the whole wait - a long queue that is being served
     is waited out, and only a wedge gives up. #>
  param(
    [int]$WaitSec = 1200,
    [int]$PollMs = 500,
    [string]$Prefix = $script:TcPushLockPrefix,
    [string]$QueueRoot = $script:TcPushLockQueueRoot,
    [scriptblock]$OnWait = $null,
    [switch]$NoInherit
  )
  if (-not $NoInherit) {
    $tok = [string](Get-Item -LiteralPath ('Env:' + $script:TcPushLockEnvVar) -ErrorAction SilentlyContinue).Value
    if (Test-TcPushLockTokenLive -Token $tok -Prefix $Prefix) {
      return (New-TcPushLockLease -Held $true -Lease $null -Inherited $true -WaitedMs 0 -TimedOut $false -Ahead 0 `
        -Reason ('an ancestor of this process already holds the push lock (' + $tok + '), so it was not taken again') -Token $tok)
    }
  }
  $lease = $null
  try {
    $lease = Enter-TcGateSlots -Want 1 -Total $script:TcPushLockTotal -Prefix $Prefix -QueueRoot $QueueRoot `
      -WaitSec $WaitSec -PollMs $PollMs -OnWait $OnWait
  } catch {
    return (New-TcPushLockLease -Held $false -Lease $null -Inherited $false -WaitedMs 0 -TimedOut $false -Ahead 0 `
      -Reason ('the push lock could not be taken: ' + $_.Exception.Message) -Token '')
  }
  if ($lease.TimedOut -or $lease.Count -lt 1) {
    if ($lease) { Exit-TcGateSlots $lease }
    return (New-TcPushLockLease -Held $false -Lease $null -Inherited $false -WaitedMs $lease.WaitedMs -TimedOut $true `
      -Ahead $lease.Ahead -Reason ('waited {0:N0}s and the push queue did not move for the last {1}s ({2} push(es) still ahead)' -f ($lease.WaitedMs / 1000), $WaitSec, $lease.Ahead) -Token '')
  }
  $token = '{0}|{1}|{2}' -f $PID, [guid]::NewGuid().ToString('N').Substring(0, 12), $Prefix
  Set-Item -LiteralPath ('Env:' + $script:TcPushLockEnvVar) -Value $token
  return (New-TcPushLockLease -Held $true -Lease $lease -Inherited $false -WaitedMs $lease.WaitedMs -TimedOut $false `
    -Ahead 0 -Reason 'held' -Token $token)
}

function Exit-TcPushLock {
  <# Hand the push lock back. Safe with $null, safe twice, and safe on an inherited lease - which holds nothing, so
     releasing it must NOT release the ancestor's. #>
  param($Lock)
  if (-not $Lock) { return }
  if ($Lock.Inherited) { return }
  if ($Lock.Lease) { Exit-TcGateSlots $Lock.Lease; $Lock.Lease = $null }
  if ($Lock.Held) {
    try { Remove-Item -LiteralPath ('Env:' + $script:TcPushLockEnvVar) -ErrorAction SilentlyContinue } catch { }
  }
  $Lock.Held = $false
}

if ($__plkSelfTest) {
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
  # Local\ and a fresh guid: these fixtures must never touch the real Global\ push lock, because this self-test runs
  # inside a run-gates that a REAL push may be holding it for.
  $prefix = 'Local\tc-push-lock-selftest-' + [guid]::NewGuid().ToString('N') + '-'
  # A UNIQUE TEMP DIRECTORY PER RUN, and a short name: run-gates runs every self-test and pre-push runs run-gates, so
  # concurrent pushes run this same file over each other in one %TEMP% (lib\guard-contract.ps1's founding case).
  $tmp = Join-Path $env:TEMP ('tc-plk-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $tmp
  $qroot = Join-Path $tmp 'q'
  $kids = [Collections.Generic.List[object]]::new()

  # A WRITER IS ANOTHER PROCESS, because a mutex held in one thread says nothing about mutual exclusion. Each one
  # starts, reports that it is up, then spins on a release file so the BARRIER IS INSIDE THE WRITER immediately
  # before the contended call - never ahead of its own powershell start-up, which spreads writers further than the
  # barrier closes them (lib\ledger-fixture.ps1's measured case). It records the ticks it entered and left its
  # critical section, so the assertion is on OVERLAP and never on seconds.
  function Start-Writer([string]$Name, [bool]$UseLock, [int]$HoldMs) {
    $up = Join-Path $tmp ($Name + '.up'); $go = Join-Path $tmp 'go'; $out = Join-Path $tmp ($Name + '.span')
    $body = @'
. '__LIB__'
[IO.File]::WriteAllText('__UP__', 'up')
while (-not (Test-Path -LiteralPath '__GO__')) { Start-Sleep -Milliseconds 10 }
$lk = $null
if (__USELOCK__) { $lk = Enter-TcPushLock -Prefix '__PFX__' -QueueRoot '__QROOT__' -WaitSec 60 -PollMs 50 -NoInherit }
$a = [DateTime]::UtcNow.Ticks
Start-Sleep -Milliseconds __HOLD__
$b = [DateTime]::UtcNow.Ticks
[IO.File]::WriteAllText('__OUT__', ("{0} {1} {2}" -f $a, $b, $(if ($lk) { [int]$lk.Held } else { -1 })))
if ($lk) { Exit-TcPushLock $lk }
'@
    $body = $body.Replace('__LIB__', $PSCommandPath).Replace('__UP__', $up).Replace('__GO__', $go).Replace('__OUT__', $out)
    $body = $body.Replace('__USELOCK__', $(if ($UseLock) { '$true' } else { '$false' })).Replace('__PFX__', $prefix)
    $body = $body.Replace('__QROOT__', $qroot).Replace('__HOLD__', [string]$HoldMs)
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $p = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru -WindowStyle Hidden
    $script:kids.Add($p)
    return [pscustomobject]@{ Proc = $p; Up = $up; Out = $out; Name = $Name }
  }
  # A CONTENDER IS ANOTHER PROCESS TOO, and for a sharper reason than the writers above. A Windows mutex is RECURSIVE
  # IN ONE THREAD: Enter-TcPushLock called twice in this process succeeds both times, correctly, because the same
  # thread already owns it. So every "a second push cannot take it" case asserted from here would read held=$true and
  # prove the opposite of what it says. The first draft of this file did exactly that and its four same-thread cases
  # went red - which is the one-thread reason lib\gate-slots.ps1's header gives for its own holders. This takes the
  # lock in a child and reports the BRANCH it landed on: held, whether it timed out, whether it holds a lease at all.
  function Invoke-Taker([string]$Name, [int]$WaitSec, [string]$Token) {
    $out = Join-Path $tmp ($Name + '.take')
    $body = @'
. '__LIB__'
if ('__TOKEN__') { $env:TC_PUSH_LOCK_HOLDER = '__TOKEN__' } else { Remove-Item -LiteralPath Env:TC_PUSH_LOCK_HOLDER -ErrorAction SilentlyContinue }
$lk = Enter-TcPushLock -Prefix '__PFX__' -QueueRoot '__QROOT__' -WaitSec __WAIT__ -PollMs 50 __INHERIT__
[IO.File]::WriteAllText('__OUT__', ("{0}|{1}|{2}|{3}|{4}" -f [int]$lk.Held, [int]$lk.TimedOut, [int]$lk.Inherited, [int]($null -ne $lk.Lease), $lk.Reason))
Exit-TcPushLock $lk
'@
    $body = $body.Replace('__LIB__', $PSCommandPath).Replace('__PFX__', $prefix).Replace('__QROOT__', $qroot)
    $body = $body.Replace('__WAIT__', [string]$WaitSec).Replace('__OUT__', $out).Replace('__TOKEN__', $Token)
    $body = $body.Replace('__INHERIT__', $(if ($Token) { '' } else { '-NoInherit' }))
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
    $p = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) -PassThru -WindowStyle Hidden
    $script:kids.Add($p)
    $null = $p.WaitForExit(120000)
    if (-not (Test-Path -LiteralPath $out)) { return [pscustomobject]@{ Held = -1; TimedOut = -1; Inherited = -1; HasLease = -1; Reason = 'the taker never reported' } }
    $p2 = @([IO.File]::ReadAllText($out) -split '\|')
    return [pscustomobject]@{ Held = [int]$p2[0]; TimedOut = [int]$p2[1]; Inherited = [int]$p2[2]; HasLease = [int]$p2[3]; Reason = [string]$p2[4] }
  }
  function Wait-Up($ws, [int]$Sec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Sec) {
      $n = @($ws | Where-Object { Test-Path -LiteralPath $_.Up }).Count
      if ($n -eq @($ws).Count) { return $true }
      Start-Sleep -Milliseconds 25
    }
    return $false
  }
  # The count of pairs whose critical sections overlap. A writer that never reported is counted as a MISSING span and
  # named, so a fixture where nothing ran can never read as "no overlap" - the empty-result shape this estate has been
  # bitten by five times.
  function Measure-Overlap($ws, [int]$Sec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Sec -and @($ws | Where-Object { Test-Path -LiteralPath $_.Out }).Count -lt @($ws).Count) { Start-Sleep -Milliseconds 25 }
    $spans = [Collections.Generic.List[object]]::new(); $missing = 0; $held = 0
    foreach ($w in @($ws)) {
      if (-not (Test-Path -LiteralPath $w.Out)) { $missing++; continue }
      $p = @(([IO.File]::ReadAllText($w.Out).Trim()) -split '\s+')
      if ($p.Count -lt 3) { $missing++; continue }
      $spans.Add([pscustomobject]@{ A = [long]$p[0]; B = [long]$p[1] })
      if ([int]$p[2] -eq 1) { $held++ }
    }
    $ov = 0
    for ($i = 0; $i -lt $spans.Count; $i++) {
      for ($j = $i + 1; $j -lt $spans.Count; $j++) {
        if ($spans[$i].A -lt $spans[$j].B -and $spans[$j].A -lt $spans[$i].B) { $ov++ }
      }
    }
    return [pscustomobject]@{ Overlaps = $ov; Spans = $spans.Count; Missing = $missing; Held = $held }
  }

  try {
    # ---- mutual exclusion, and a fixture proved able to SEE its absence ----
    $N = 4
    $locked = @(0..($N - 1) | ForEach-Object { Start-Writer ('lk' + $_) $true 250 })
    $allUp = Wait-Up $locked 30
    [IO.File]::WriteAllText((Join-Path $tmp 'go'), 'go')
    $mLock = Measure-Overlap $locked 90
    T ($kMNF + '  four concurrent pushes holding the push lock never overlap, and all four were granted it') `
      ($allUp -and $mLock.Missing -eq 0 -and $mLock.Spans -eq $N -and $mLock.Held -eq $N -and $mLock.Overlaps -eq 0) `
      ("up={0} spans={1} of {2} missing={3} held={4} overlaps={5}" -f $allUp, $mLock.Spans, $N, $mLock.Missing, $mLock.Held, $mLock.Overlaps)

    # THE SAME FIXTURE WITHOUT THE LOCK. Without this the case above passes whether the lock works or whether the
    # writers simply never ran at the same time, and a probe would score it a survivor: the assertion would be true
    # and insensitive (ops\audit-mustfire-census.ps1's founding pair, 2026-09-11).
    Remove-Item -LiteralPath (Join-Path $tmp 'go') -Force
    $free = @(0..($N - 1) | ForEach-Object { Start-Writer ('nl' + $_) $false 250 })
    $allUp2 = Wait-Up $free 30
    [IO.File]::WriteAllText((Join-Path $tmp 'go'), 'go')
    $mFree = Measure-Overlap $free 90
    T ($kMF + '  the same four writers with the lock taken out DO overlap, so the case above can see mutual exclusion failing') `
      ($allUp2 -and $mFree.Missing -eq 0 -and $mFree.Overlaps -gt 0) `
      ("up={0} spans={1} missing={2} overlaps={3}" -f $allUp2, $mFree.Spans, $mFree.Missing, $mFree.Overlaps)

    # ---- a held lock is not handed out twice, and a wedge degrades rather than refusing ----
    $mine = Enter-TcPushLock -Prefix $prefix -QueueRoot $qroot -WaitSec 30 -PollMs 50 -NoInherit
    T ($kMNF + '  a lone push takes the lock at once') ($mine.Held -and -not $mine.Inherited -and -not $mine.TimedOut) ("held={0} inherited={1}" -f $mine.Held, $mine.Inherited)
    # A SECOND TAKE, FROM ANOTHER PROCESS, with the lock held above. WaitSec is short here because what is asserted
    # is the BRANCH, never how long it took - a bar on seconds is the red that teaches --no-verify.
    $second = Invoke-Taker 'second' 1 ''
    T ($kMF + '  a second push cannot take a lock another push holds, and says so in words rather than silently proceeding as the holder') `
      ($second.Held -eq 0 -and $second.TimedOut -eq 1 -and $second.Reason -match 'did not move') ("held={0} timedOut={1} reason={2}" -f $second.Held, $second.TimedOut, $second.Reason)
    T ($kCT + '  a refused take holds nothing, so a caller proceeding unlocked cannot release the real holder''s lock') `
      ($second.HasLease -eq 0) ("hasLease={0}" -f $second.HasLease)
    $third = Invoke-Taker 'third' 1 ''
    T ($kCT + '  the refused take left the original holder holding it, so the push after it is refused too') `
      ($third.Held -eq 0 -and $third.TimedOut -eq 1) ("held={0} timedOut={1}" -f $third.Held, $third.TimedOut)
    Exit-TcPushLock $mine
    $after = Invoke-Taker 'after' 10 ''
    T ($kCT + '  once the holder releases, the next push gets the lock') ($after.Held -eq 1 -and $after.Inherited -eq 0) ("held={0} inherited={1}" -f $after.Held, $after.Inherited)

    # ---- inheritance: a descendant of the holder must not deadlock against its own ancestor ----
    $held2 = Enter-TcPushLock -Prefix $prefix -QueueRoot $qroot -WaitSec 5 -PollMs 50 -NoInherit
    $inh = Invoke-Taker 'inherit' 1 $held2.Token
    T ($kMNF + '  a descendant of the holder inherits the lock instead of deadlocking on it') `
      ($inh.Held -eq 1 -and $inh.Inherited -eq 1 -and $inh.HasLease -eq 0) ("held={0} inherited={1} hasLease={2} reason={3}" -f $inh.Held, $inh.Inherited, $inh.HasLease, $inh.Reason)
    $stillHeld = Invoke-Taker 'stillheld' 1 ''
    T ($kCT + '  that descendant exiting left the ancestor still holding the real lock') `
      ($stillHeld.Held -eq 0 -and $stillHeld.TimedOut -eq 1) ("held={0} timedOut={1}" -f $stillHeld.Held, $stillHeld.TimedOut)
    Exit-TcPushLock $held2

    # A TOKEN WHOSE HOLDER IS GONE IS NOT A LOCK. Without this a killed push's leftover environment would make every
    # descendant of whatever inherits it skip the lock forever.
    $deadPid = 0
    $dead = Start-Process -FilePath $PS -ArgumentList @('-NoProfile', '-Command', 'exit') -PassThru -WindowStyle Hidden
    $null = $dead.WaitForExit(15000); $deadPid = $dead.Id
    T ($kMF + '  a token naming a process that has exited is not treated as a live holder') `
      (-not (Test-TcPushLockTokenLive -Token ("{0}|abcdef123456|{1}" -f $deadPid, $prefix) -Prefix $prefix)) ("pid={0}" -f $deadPid)
    T ($kCT + '  a token naming this live process, on this lock, IS treated as a live holder') `
      (Test-TcPushLockTokenLive -Token ("{0}|abcdef123456|{1}" -f $PID, $prefix) -Prefix $prefix) ("pid={0}" -f $PID)
    # THE CASE THE GATE FOUND (2026-09-11). A token taken on ANOTHER lock is not an inheritance. Without this,
    # run-gates under ops\push-main.ps1 - which holds the real Global\ lock - handed every suite redirected to a
    # private Local\ lock an `inherited` it had not earned, and two suites went red for it.
    T ($kMF + '  a live token taken on a DIFFERENT lock is not inherited, so a private lock is never confused with the real one') `
      (-not (Test-TcPushLockTokenLive -Token ("{0}|abcdef123456|{1}" -f $PID, 'Global\tc-push-lock-') -Prefix $prefix)) `
      'a token from another lock was honoured'
    T ($kMF + '  a malformed token is not treated as a live holder, including the old prefix-less shape') `
      ((-not (Test-TcPushLockTokenLive -Token 'yes' -Prefix $prefix)) -and (-not (Test-TcPushLockTokenLive -Token '' -Prefix $prefix)) `
        -and (-not (Test-TcPushLockTokenLive -Token ("{0}:abcdef123456" -f $PID) -Prefix $prefix))) 'a malformed token was honoured'
    Set-Item -LiteralPath ('Env:' + $script:TcPushLockEnvVar) -Value ("{0}|abcdef123456|{1}" -f $deadPid, $prefix)
    $notInh = Enter-TcPushLock -Prefix $prefix -QueueRoot $qroot -WaitSec 5 -PollMs 50
    T ($kMF + '  a stale token left by a dead holder does not stop the next push taking the lock for real') `
      ($notInh.Held -and -not $notInh.Inherited) ("held={0} inherited={1}" -f $notInh.Held, $notInh.Inherited)
    Exit-TcPushLock $notInh
    Remove-Item -LiteralPath ('Env:' + $script:TcPushLockEnvVar) -ErrorAction SilentlyContinue
  } finally {
    foreach ($p in $kids) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath ('Env:' + $script:TcPushLockEnvVar) -ErrorAction SilentlyContinue
  }

  if ($f) { Write-Output ("push-lock self-test FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("push-lock self-test PASS: {0} cases - {1} must-fire led by four unlocked writers overlapping so the exclusion case can see a failure, {2} must-not-fire led by four locked pushes never overlapping, and {3} clean twins led by the lock passing to the next push once its holder releases" -f $cases, $kinds[$kMF], $kinds[$kMNF], $kinds[$kCT])
  exit 0
}
