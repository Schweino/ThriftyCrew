    # ---- W9.2: THE CHAIN QUEUE, PUSH-MAIN'S INTEGRATION (2026-09-23) ----
    # Founding figure (plan 16.1): 12 of the 13 early-rehearsal misses were a rehearsal voided by another chain landing,
    # which the queue stacks on instead. Production shape: every push is a WORKTREE of one repo (a shared object store,
    # which is what lets a rehearsal clone, or diff-tree, read an ahead ticket's commits), so these cases build a box
    # clone of the fixture origin and one worktree per push. A ticket ahead is held by a HELPER PROCESS (a mutex belongs
    # to its thread, and a ticket held by this thread reads as dead to it), which joins the private queue and then does
    # what its mode says once the member's record reads ready: land (push its commit, then exit landed), leave, hold, or
    # probe the push lock and a gate slot first. Every queue is this run's private Local\ prefix and root.
    $env:TC_CHAIN_QUEUE_SELFTEST = '1'
    $qBox = Join-Path $tmp 'qbox'
    $null = & git clone -q $origin $qBox 2>$null
    $null = & git -C $qBox config user.name Probe 2>$null; $null = & git -C $qBox config user.email p@p 2>$null
    $script:qwtN = 0
    function New-StQueueWorktree([string]$Name, [string]$File, [string]$Text) {
      $script:qwtN++
      $null = & git -C $qBox fetch -q origin 2>$null
      $wtd = Join-Path $tmp ('qw-' + $Name)
      $null = & git -C $qBox worktree add -q -b ('qb-' + $Name + '-' + $script:qwtN) $wtd origin/main 2>$null
      $full = Join-Path $wtd ($File -replace '/', '\')
      $null = New-Item -ItemType Directory -Force (Split-Path -Parent $full)
      [IO.File]::WriteAllText($full, $Text)
      $null = & git -C $wtd add -- $File 2>$null; $null = & git -C $wtd commit -q -m ('q ' + $Name) 2>$null
      return $wtd
    }
    $qHelper = Join-Path $tmp 'q-helper.ps1'
    [IO.File]::WriteAllText($qHelper, @'
param([string]$Repo, [string]$Prefix, [string]$Root, [string]$Wt, [string]$Mode, [string]$Out, [string]$PushPrefix = '', [string]$PushRoot = '', [string]$SlotPrefix = '', [string]$SlotRoot = '')
$ErrorActionPreference = 'Continue'
. (Join-Path $Repo 'lib\chain-queue.ps1')
. (Join-Path $Repo 'lib\push-lock.ps1')
function W([string]$Leaf, [string]$Text) { [IO.File]::WriteAllText((Join-Path $Out $Leaf), $Text) }
$base = ((& git -C $Wt merge-base HEAD origin/main) | Select-Object -First 1).Trim()
$range = @((& git -C $Wt rev-list --reverse ($base + '..HEAD')) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$cq = Join-TcChainQueue -Mode live -Checkout $Wt -Base $base -Range $range -Prefix $Prefix -QueueRoot $Root
W 'joined.txt' ([string]$cq.Queue + ' ' + $cq.Name + ' ' + $PID)
if ($cq.Queue -ne 'joined') { exit 3 }
$null = Set-TcChainQueueState -Member $cq -State ready
try {
  if ($Mode -eq 'hold') { while (-not (Test-Path -LiteralPath (Join-Path $Out 'release.txt'))) { Start-Sleep -Milliseconds 50 }; Exit-TcChainQueue -Member $cq -State left; exit 0 }
  # WAIT UNTIL A MEMBER BEHIND THIS TICKET IS READY (it has rehearsed and is waiting for the head), a hang guard of 180 s.
  $sw = [Diagnostics.Stopwatch]::StartNew(); $seen = $false
  while (-not $seen -and $sw.Elapsed.TotalSeconds -lt 180 -and -not (Test-Path -LiteralPath (Join-Path $Out 'release.txt'))) {
    foreach ($f in [IO.Directory]::GetFiles($cq.Dir, '*.json')) {
      if ([IO.Path]::GetFileNameWithoutExtension($f) -eq $cq.Name) { continue }
      try { $r = [IO.File]::ReadAllText($f) | ConvertFrom-Json; if ($r.state -eq 'ready' -and [string]::CompareOrdinal([string]$r.ticket, $cq.Name) -gt 0) { $seen = $true } } catch { }
    }
    if (-not $seen) { Start-Sleep -Milliseconds 50 }
  }
  W 'saw-member-ready.txt' ([string]$seen)
  if ($Mode -eq 'land-after-wait') {
    # THE MEMBER IS REALLY WAITING: its own head-wait report wrote this file (a hang guard of 120 s, never a clock that
    # decides). A member that never waits never writes it, and reaches its lock before this ticket lands.
    $sw2 = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath (Join-Path $Out 'member-waiting.txt')) -and $sw2.Elapsed.TotalSeconds -lt 120 -and -not (Test-Path -LiteralPath (Join-Path $Out 'release.txt'))) { Start-Sleep -Milliseconds 50 }
    $Mode = 'land'
  }
  if ($Mode -eq 'probe-then-land') {
    $lk = Enter-TcPushLock -Prefix $PushPrefix -QueueRoot $PushRoot -WaitSec 20 -PollMs 50 -NoInherit
    W 'probe-lock.txt' ([string]$lk.Held); Exit-TcPushLock $lk
    $gs = Enter-TcGateSlots -Want 1 -Prefix $SlotPrefix -QueueRoot $SlotRoot -WaitSec 20
    W 'probe-slot.txt' ([string]$gs.Count); Exit-TcGateSlots $gs
    $Mode = 'land'
  }
  if ($Mode -eq 'land') {
    $null = & git -C $Wt push -q origin HEAD:main 2>$null
    W 'pushed.txt' ([string]$LASTEXITCODE)
    Exit-TcChainQueue -Member $cq -State landed
    W 'landed.txt' ([string][DateTime]::UtcNow.Ticks)
    exit 0
  }
  if ($Mode -eq 'leave') { Exit-TcChainQueue -Member $cq -State left; W 'left.txt' 'left'; exit 0 }
  exit 2
} finally { Exit-TcChainQueue -Member $cq -State left }
'@)
    $script:qhN = 0
    function Start-StQueueHelper([string]$Wt, [string]$Mode) {
      $script:qhN++
      $hOut = Join-Path $tmp ('qh-' + $script:qhN)
      $null = New-Item -ItemType Directory -Force -ErrorAction Stop $hOut
      $hArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $qHelper + '"'), '-Repo', ('"' + $repo + '"'), '-Prefix', $script:TcPmChainQueuePrefix,
        '-Root', ('"' + $script:TcPmChainQueueRoot + '"'), '-Wt', ('"' + $Wt + '"'), '-Mode', $Mode, '-Out', ('"' + $hOut + '"'),
        '-PushPrefix', $prefix, '-PushRoot', ('"' + $qroot + '"'), '-SlotPrefix', ('Local\tc-pm-slot-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '-'), '-SlotRoot', ('"' + (Join-Path $tmp ('slots-' + $script:qhN)) + '"'))
      $hp = Start-Process -FilePath 'powershell.exe' -ArgumentList $hArgs -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $hOut 'out.txt') -RedirectStandardError (Join-Path $hOut 'err.txt')
      $null = $hp.Handle
      $hw = [Diagnostics.Stopwatch]::StartNew()
      while (-not (Test-Path -LiteralPath (Join-Path $hOut 'joined.txt')) -and -not $hp.HasExited -and $hw.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 50 }
      return [pscustomobject]@{ Proc = $hp; Out = $hOut; Joined = $(if (Test-Path -LiteralPath (Join-Path $hOut 'joined.txt')) { ([IO.File]::ReadAllText((Join-Path $hOut 'joined.txt'))).Trim() } else { '' }) }
    }
    function Stop-StQueueHelper($H) { if ($null -eq $H) { return }; [IO.File]::WriteAllText((Join-Path $H.Out 'release.txt'), 'go'); if (-not $H.Proc.WaitForExit(60000)) { try { $H.Proc.Kill() } catch { } } }
    # THE REHEARSAL STUB FOR QUEUE CASES: a real child that copies the stack file it was handed (if any) into a numbered
    # record, says "rehearsing HEAD now" only when it was stacked (a new verdict), and passes. -Mode conflict makes it
    # report a STACK CONFLICT on its first call, as rehearse-chain does, naming the files it was told.
    $qRhStub = Join-Path $tmp 'q-rehearse-stub.ps1'
    [IO.File]::WriteAllText($qRhStub, @'
param([switch]$ForPush, [string]$Remote, [string]$Branch, [string]$StackFile, [string]$StopFile, [string]$Rec = '', [string]$Mode = 'pass', [string]$Files = '')
$n = @([IO.Directory]::GetFiles($Rec, 'call-*.txt')).Count + 1
$stack = $(if ($StackFile -and (Test-Path -LiteralPath $StackFile)) { [IO.File]::ReadAllText($StackFile) } else { '<none>' })
[IO.File]::WriteAllText((Join-Path $Rec ('call-' + $n + '.txt')), $stack)
if ($Mode -eq 'conflict' -and $n -eq 1) {
  Write-Output ('chain-rehearsal: STACK CONFLICT - applying 000000000 onto the stack conflicts in: ' + $Files)
  Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=3 outcome=could-not-rehearse blind=stack-conflict'
  exit 3
}
if ($StackFile) { Write-Output 'chain-rehearsal: this push changes the chain and has no usable rehearsal verdict - rehearsing HEAD now, OUTSIDE the push lock.' }
Write-Output 'chain-rehearsal: PASSED - fixture'
Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass'
exit 0
'@)
    $script:qRec = ''
    $script:qRhMode = 'pass'; $script:qRhFiles = ''
    $qStarter = { param($d, $stack, $stop) Start-TcRehearsalChild -Dir $d -Remote 'origin' -Branch 'main' -StackFile $stack -StopFile $stop -Script $qRhStub -ExtraArgs @('-Rec', ('"' + $script:qRec + '"'), '-Mode', $script:qRhMode, '-Files', ('"' + $script:qRhFiles + '"')) }
    $qChain = { param($d, $h, $r) [pscustomobject]@{ Touching = $true; Outcome = 'rehearsed-pass'; Why = 'fixture: chain-touching' } }
    $qNotChain = { param($d, $h, $r) [pscustomobject]@{ Touching = $false; Outcome = 'not-needed'; Why = 'fixture: not chain-touching' } }
    $qGateHeads = [Collections.Generic.List[string]]::new()
    $qGate = { param($d) [void]$qGateHeads.Add(([string](@(& git -C $d log --format=%s 2>$null)) )); [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    function New-StQueueRec { $script:qRec = Join-Path $tmp ('qrec-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); $null = New-Item -ItemType Directory -Force $script:qRec }
    function Get-StQueueCalls { return , ([string[]]@([IO.Directory]::GetFiles($script:qRec, 'call-*.txt') | Sort-Object | ForEach-Object { ([IO.File]::ReadAllText($_)).Trim() })) }
    function Get-StRow([string]$Root) { $rr = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $Root); $rs = @($rr); if ($rs.Count) { return $rs[$rs.Count - 1] } else { return $null } }

    # MUST FIRE, stacking; MUST FIRE, ordering; CLEAN TWIN, it lands after the one ahead with no second rehearsal.
    # A helper holds the ticket ahead (its commit touches chain/a.txt) and lands once this member is ready. The member's
    # rehearsal must have judged origin + the helper's range; its first lock take must come after the helper landed; and
    # after the catch-up rebase over the landed ticket, its rehearsal leg reuses (no second "rehearsing HEAD now").
    New-StQueueRec
    $h1wt = New-StQueueWorktree 'h1' 'chain/a.txt' 'h1'
    $m1wt = New-StQueueWorktree 'm1' 'chain/b.txt' 'm1'
    $qOrigin1 = & $tipOf
    $h1Sha = ([string](@(& git -C $h1wt rev-parse HEAD 2>$null))[0]).Trim()
    # THE HELPER LANDS ONLY AFTER THE MEMBER REPORTS IT IS WAITING (the head-wait's report seam, every 1 s here): so a
    # member that skipped the wait reaches its lock take before the ticket ahead has landed, every time (M12's case).
    $h1 = Start-StQueueHelper $h1wt 'land-after-wait'
    $script:lockMoves = @({ $script:lmLandedAtTake = Test-Path -LiteralPath (Join-Path $h1.Out 'landed.txt') })
    $script:lmLandedAtTake = $null
    $ledQ1 = Join-Path $tmp 'ledq1'
    $reportWas = $script:TcPmChainQueueReportSec
    $script:TcPmChainQueueReportSec = 1
    $script:TcPmOnQueueReport = { param($qpos, $qsec) [IO.File]::WriteAllText((Join-Path $h1.Out 'member-waiting.txt'), [string]$qpos) }
    try { $rQ1q = Invoke-WithLockMover { Invoke-TcPushMain -Dir $m1wt -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalStarter $qStarter -ChainTouchingProbe $qChain -LedgerRoot $ledQ1 } -LmCap -1 }
    finally { $script:TcPmChainQueueReportSec = $reportWas; $script:TcPmOnQueueReport = $null }
    Stop-StQueueHelper $h1
    $q1Calls = Get-StQueueCalls
    $q1Row = Get-StRow $ledQ1
    $q1Stack = $(if ($q1Calls.Count) { @($q1Calls[0] -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @() })
    T ($kMF + '  stacking: with a ticket ahead, the member''s rehearsal judged origin plus the ahead ticket''s range (its own is applied on top by rehearse-chain), not origin alone') `
      ($h1.Joined -match '^joined ' -and $q1Stack.Count -eq 2 -and $q1Stack[0] -ceq $qOrigin1 -and $q1Stack[1] -ceq $h1Sha) ("helper={0} stack={1} origin={2} ahead={3}" -f $h1.Joined, ($q1Stack -join '|'), $qOrigin1, $h1Sha)
    T ($kMF + '  ordering: a member whose legs finished first took the push lock only after the ticket ahead had landed (read by the lock-entry wrapper, from the helper''s own landed file)') `
      ($rQ1q -eq 0 -and $script:lmLandedAtTake -eq $true) ("rc={0} landedAtFirstTake={1}" -f $rQ1q, $script:lmLandedAtTake)
    T ($kCT + '  the member lands after the one ahead with no second rehearsal: one rehearsing call, rehearsed 1, restacks 0, queue joined, stacked_on the join origin + 1, and its commit sits on top of the helper''s') `
      ($rQ1q -eq 0 -and @($q1Calls | Where-Object { $_ -ne '<none>' }).Count -eq 1 -and $null -ne $q1Row -and [int]$q1Row.rehearsed -eq 1 -and [int]$q1Row.restacks -eq 0 -and [string]$q1Row.queue -ceq 'joined' -and `
        [string]$q1Row.stacked_on -ceq ($qOrigin1.Substring(0, 9) + '+1') -and (& $isAnc $m1wt $h1Sha (& $tipOf))) `
      ("rc={0} calls={1} rehearsed={2} restacks={3} queue={4} stacked={5}" -f $rQ1q, ($q1Calls -join ' / '), $(if ($q1Row) { $q1Row.rehearsed }), $(if ($q1Row) { $q1Row.restacks }), $(if ($q1Row) { $q1Row.queue }), $(if ($q1Row) { $q1Row.stacked_on }))

    # MUST FIRE, restack; MUST NOT FIRE, the safety case. The helper ahead LEAVES once this member is ready: the member
    # rehearses once more onto origin alone (restacks 1), lands, and neither its worktree HEAD (read by every leg) nor its
    # landed commit ever carried the helper's commit.
    New-StQueueRec
    $h2wt = New-StQueueWorktree 'h2' 'chain/c.txt' 'h2'
    $m2wt = New-StQueueWorktree 'm2' 'chain/d.txt' 'm2'
    $h2Sha = ([string](@(& git -C $h2wt rev-parse HEAD 2>$null))[0]).Trim()
    $h2 = Start-StQueueHelper $h2wt 'leave'
    $qGateHeads.Clear()
    $ledQ2 = Join-Path $tmp 'ledq2'
    $rQ2q = Invoke-TcPushMain -Dir $m2wt -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $qGate -RehearsalStarter $qStarter -ChainTouchingProbe $qChain -LedgerRoot $ledQ2
    Stop-StQueueHelper $h2
    $q2Calls = Get-StQueueCalls
    $q2Row = Get-StRow $ledQ2
    $q2Second = $(if ($q2Calls.Count -ge 2) { @($q2Calls[1] -split "`n" | Where-Object { $_.Trim() }) } else { @() })
    T ($kMF + '  restack: a ticket ahead that leaves makes the member rehearse once more onto origin alone, restacks 1, and it lands') `
      ($rQ2q -eq 0 -and $q2Calls.Count -eq 2 -and $q2Second.Count -eq 1 -and $null -ne $q2Row -and [int]$q2Row.restacks -eq 1 -and ([string]$q2Row.outcome).StartsWith('landed')) `
      ("rc={0} calls={1} secondStack={2} restacks={3} outcome={4}" -f $rQ2q, $q2Calls.Count, ($q2Second -join '|'), $(if ($q2Row) { $q2Row.restacks }), $(if ($q2Row) { $q2Row.outcome }))
    T ($kMNF + '  safety: after the ticket ahead left, the member''s landed commit has none of its commits among its ancestors, and no leg ever saw them in the worktree') `
      ($rQ2q -eq 0 -and -not (& $isAnc $m2wt $h2Sha (& $tipOf)) -and $qGateHeads.Count -ge 1 -and @($qGateHeads | Where-Object { $_ -match '\bq h2\b' }).Count -eq 0) ("rc={0} helperInLanded={1} legsSawIt={2}" -f $rQ2q, (& $isAnc $m2wt $h2Sha (& $tipOf)), @($qGateHeads | Where-Object { $_ -match '\bq h2\b' }).Count)

    # MUST NOT FIRE: a non-chain push never takes a ticket, and lands while a member is queued (a helper holds a ticket).
    $h3wt = New-StQueueWorktree 'h3' 'chain/e.txt' 'h3'
    $n3wt = New-StQueueWorktree 'n3' 'other/f.txt' 'n3'
    $h3 = Start-StQueueHelper $h3wt 'hold'
    $ledQ3 = Join-Path $tmp 'ledq3'
    $rQ3q = Invoke-TcPushMain -Dir $n3wt -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -ChainTouchingProbe $qNotChain -LedgerRoot $ledQ3
    $q3Live = Get-TcChainQueueLive -Prefix $script:TcPmChainQueuePrefix -QueueRoot $script:TcPmChainQueueRoot
    Stop-StQueueHelper $h3
    $q3Row = Get-StRow $ledQ3
    T ($kMNF + '  a non-chain push never takes a ticket and lands while another member is queued: queue not-chain, and the one live ticket is still the helper''s') `
      ($rQ3q -eq 0 -and $null -ne $q3Row -and [string]$q3Row.queue -ceq 'not-chain' -and @($q3Live).Count -eq 1 -and [int]@($q3Live)[0].Pid -eq $h3.Proc.Id) ("rc={0} queue={1} live={2}" -f $rQ3q, $(if ($q3Row) { $q3Row.queue }), (@($q3Live | ForEach-Object { $_.Pid }) -join ','))

    # MUST FIRE: a -NoRehearsal chain-touching push takes a ticket. The real Get-TcChainTouchingNow asks a stub
    # rehearse-chain -CheckPush in the worktree, which says bypassed under TC_NO_REHEARSAL, as rehearse-chain does.
    $nrwt = New-StQueueWorktree 'nr' 'chain/g.txt' 'nr'
    $null = New-Item -ItemType Directory -Force (Join-Path $nrwt 'ops')
    Add-Content -LiteralPath (Join-Path $qBox '.git\info\exclude') -Value @('ops/') -Encoding ascii
    [IO.File]::WriteAllText((Join-Path $nrwt 'ops\rehearse-chain.ps1'), "param([switch]`$CheckPush, [switch]`$ForPush, [string]`$Remote, [string]`$Branch, [string]`$RefsFile)`nif (`$env:TC_NO_REHEARSAL) { Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=bypassed'; exit 0 }`nWrite-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=not-needed'`nexit 0`n")
    $ledQ4 = Join-Path $tmp 'ledq4'
    $nrWas = $env:TC_NO_REHEARSAL; $env:TC_NO_REHEARSAL = 'fixture: a loud bypass'
    try { $rQ4q = Invoke-TcPushMain -Dir $nrwt -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -LedgerRoot $ledQ4 }
    finally { if ($null -eq $nrWas) { Remove-Item -LiteralPath Env:TC_NO_REHEARSAL -ErrorAction SilentlyContinue } else { $env:TC_NO_REHEARSAL = $nrWas } }
    $q4Row = Get-StRow $ledQ4
    T ($kMF + '  a -NoRehearsal chain-touching push takes a ticket: rehearse-chain -CheckPush says bypassed, the row says queue joined, and it lands') `
      ($rQ4q -eq 0 -and $null -ne $q4Row -and [string]$q4Row.queue -ceq 'joined') ("rc={0} queue={1}" -f $rQ4q, $(if ($q4Row) { $q4Row.queue }))

    # MUST FIRE, the stack conflict: the member's rehearsal reports a STACK CONFLICT against the ticket ahead, whose commit
    # touched the same file. It records stack=conflict naming that ticket's checkout, keeps its place, and once that
    # ticket lands it is refused by the catch-up rebase with phase catchup.
    New-StQueueRec
    $h5wt = New-StQueueWorktree 'h5' 'chain/same.txt' 'theirs'
    $m5wt = New-StQueueWorktree 'm5' 'chain/same.txt' 'mine'
    $h5 = Start-StQueueHelper $h5wt 'land'
    $script:qRhMode = 'conflict'; $script:qRhFiles = 'chain/same.txt'
    $ledQ5 = Join-Path $tmp 'ledq5'
    $q5Cap = Invoke-StCapture { Invoke-TcPushMain -Dir $m5wt -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalStarter $qStarter -ChainTouchingProbe $qChain -LedgerRoot $ledQ5 }
    $script:qRhMode = 'pass'; $script:qRhFiles = ''
    Stop-StQueueHelper $h5
    $q5Row = Get-StRow $ledQ5
    T ($kMF + '  a stack conflict with the ticket ahead is a warning naming that ticket''s checkout: stack conflict, the member kept its place, and once that ticket landed the catch-up rebase refused it with phase catchup') `
      ($q5Cap.Result -eq 1 -and $null -ne $q5Row -and [string]$q5Row.stack -ceq 'conflict' -and [string]$q5Row.outcome -ceq 'refused-rebase-conflict' -and [string]$q5Row.phase -ceq 'catchup' -and `
        $q5Cap.Text -match [regex]::Escape($h5wt) -and (Test-Path -LiteralPath (Join-Path $h5.Out 'landed.txt'))) `
      ("rc={0} stack={1} outcome={2} phase={3} namedTicket={4} helperLanded={5}" -f $q5Cap.Result, $(if ($q5Row) { $q5Row.stack }), $(if ($q5Row) { $q5Row.outcome }), $(if ($q5Row) { $q5Row.phase }), ($q5Cap.Text -match [regex]::Escape($h5wt)), (Test-Path -LiteralPath (Join-Path $h5.Out 'landed.txt')))

    # MUST FIRE, the timed-out branch: an ahead ticket held by a helper that never changes state, and a lowered stall bound,
    # give queue timeout with queue_ahead naming the helper (pid:checkout), and a push that proceeds and lands.
    New-StQueueRec
    $h6wt = New-StQueueWorktree 'h6' 'chain/h.txt' 'h6'
    $m6wt = New-StQueueWorktree 'm6' 'chain/i.txt' 'm6'
    $h6 = Start-StQueueHelper $h6wt 'hold'
    $stallWas = $script:TcPmChainQueueStallSec; $script:TcPmChainQueueStallSec = 3
    $ledQ6 = Join-Path $tmp 'ledq6'
    try { $rQ6q = Invoke-TcPushMain -Dir $m6wt -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalStarter $qStarter -ChainTouchingProbe $qChain -LedgerRoot $ledQ6 }
    finally { $script:TcPmChainQueueStallSec = $stallWas }
    Stop-StQueueHelper $h6
    $q6Row = Get-StRow $ledQ6
    T ($kMF + '  a frozen head and a lowered bound give queue timeout, queue_ahead naming the holder, and a push that proceeds and lands (never a refusal)') `
      ($rQ6q -eq 0 -and $null -ne $q6Row -and [string]$q6Row.queue -ceq 'timeout' -and [string]$q6Row.queue_ahead -ceq ([string]$h6.Proc.Id + ':' + $h6wt) -and ([string]$q6Row.outcome).StartsWith('landed')) `
      ("rc={0} queue={1} ahead={2} want={3}:{4}" -f $rQ6q, $(if ($q6Row) { $q6Row.queue }), $(if ($q6Row) { $q6Row.queue_ahead }), $h6.Proc.Id, $h6wt)

    # MUST FIRE: with TC_CHAIN_QUEUE_SELFTEST set, a join with the PRODUCTION prefix throws, so a case that forgot the seam
    # can never queue real pushes behind it.
    $prodThrew = ''
    try { $null = Join-TcChainQueue -Mode live -Checkout $tmp -Base $qOrigin1 -Range @() -Prefix $script:TcChainQueuePrefix -QueueRoot $script:TcPmChainQueueRoot } catch { $prodThrew = [string]$_.Exception.Message }
    T ($kMF + '  with TC_CHAIN_QUEUE_SELFTEST set, a join on the production prefix throws') ([bool]$prodThrew) ("threw={0}" -f $prodThrew)
    # MUST FIRE (pure): a member's rh_key is the key= token of the rehearsal's CHAIN-REHEARSAL-COMPLETE line; a reuse,
    # which prints no such line, gives none, so the member keeps the key it had. Found by the drill through push-main: with
    # no rh_key, a ticket ahead's catch-up rebase rewrote its range, and the member behind restacked for nothing.
    $rkA = Get-TcRehearsalKey -Lines @('chain-rehearsal: rehearsing HEAD now', 'CHAIN-REHEARSAL-COMPLETE verdict=pass stage=- key=51afc2ef636f data=2026-09-23 secs=865', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass')
    $rkB = Get-TcRehearsalKey -Lines @('chain-rehearsal: PASSED - reused', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass')
    T ($kMF + '  the rehearsal key is read off its CHAIN-REHEARSAL-COMPLETE line, and a reuse gives none') ($rkA -ceq '51afc2ef636f' -and $rkB -ceq '') ("rehearsed={0} reused={1}" -f $rkA, $rkB)

    # CLEAN TWIN: an unwritable queue root records queue error, and the push lands as the W2.2R path does.
    $q7wt = New-StQueueWorktree 'q7' 'chain/j.txt' 'q7'
    $q7File = Join-Path $tmp 'a-file-not-a-dir.txt'; [IO.File]::WriteAllText($q7File, 'x')
    $rootWas = $script:TcPmChainQueueRoot; $script:TcPmChainQueueRoot = Join-Path $q7File 'q'
    $ledQ7 = Join-Path $tmp 'ledq7'
    try { $rQ7q = Invoke-TcPushMain -Dir $q7wt -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalStarter $qStarter -ChainTouchingProbe $qChain -LedgerRoot $ledQ7 }
    finally { $script:TcPmChainQueueRoot = $rootWas }
    $q7Row = Get-StRow $ledQ7
    T ($kCT + '  an unwritable queue root records queue error, and the push lands as the W2.2R path does') ($rQ7q -eq 0 -and $null -ne $q7Row -and [string]$q7Row.queue -ceq 'error' -and ([string]$q7Row.outcome).StartsWith('landed')) ("rc={0} queue={1}" -f $rQ7q, $(if ($q7Row) { $q7Row.queue }))

    # CLEAN TWIN, the rollback: -ChainQueue off takes no ticket (a watcher in ANOTHER process sees none throughout), records
    # queue off, and the push lands as the W2.2R path does.
    $q8wt = New-StQueueWorktree 'q8' 'chain/k.txt' 'q8'
    $q8Watch = Join-Path $tmp 'q8-watch.ps1'
    $q8Seen = Join-Path $tmp 'q8-seen.txt'; $q8Stop = Join-Path $tmp 'q8-stop.txt'
    [IO.File]::WriteAllText($q8Watch, ("`$d = '" + (Get-TcGateQueueDir -Prefix $script:TcPmChainQueuePrefix -Root $script:TcPmChainQueueRoot) + "'`n`$n = 0`nwhile (-not (Test-Path -LiteralPath '" + $q8Stop + "')) { if ((Test-Path -LiteralPath `$d) -and @([IO.Directory]::GetFiles(`$d, '*.ticket')).Count) { `$n++ }; Start-Sleep -Milliseconds 20 }`n[IO.File]::WriteAllText('" + $q8Seen + "', [string]`$n)`n"))
    $q8p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $q8Watch + '"')) -PassThru -NoNewWindow
    $null = $q8p.Handle
    $ledQ8 = Join-Path $tmp 'ledq8'
    $rQ8q = Invoke-TcPushMain -Dir $q8wt -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalStarter $qStarter -ChainTouchingProbe $qChain -ChainQueue 'off' -LedgerRoot $ledQ8
    [IO.File]::WriteAllText($q8Stop, 'stop'); $null = $q8p.WaitForExit(30000)
    $q8n = $(if (Test-Path -LiteralPath $q8Seen) { [int]([IO.File]::ReadAllText($q8Seen)).Trim() } else { -1 })
    $q8Row = Get-StRow $ledQ8
    T ($kCT + '  the rollback: -ChainQueue off records queue off, lands, and a watcher in another process saw no ticket at any moment') `
      ($rQ8q -eq 0 -and $null -ne $q8Row -and [string]$q8Row.queue -ceq 'off' -and $q8n -eq 0 -and ([string]$q8Row.outcome).StartsWith('landed')) ("rc={0} queue={1} ticketSightings={2}" -f $rQ8q, $(if ($q8Row) { $q8Row.queue }), $q8n)

    # MUST NOT FIRE, the lock order: while the member waits for the head, the helper (ANOTHER process) takes the push lock
    # and a gate slot at once: the ticket holds neither.
    $h9wt = New-StQueueWorktree 'h9' 'chain/l.txt' 'h9'
    $m9wt = New-StQueueWorktree 'm9' 'chain/m.txt' 'm9'
    New-StQueueRec
    $h9 = Start-StQueueHelper $h9wt 'probe-then-land'
    $ledQ9 = Join-Path $tmp 'ledq9'
    $rQ9q = Invoke-TcPushMain -Dir $m9wt -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalStarter $qStarter -ChainTouchingProbe $qChain -LedgerRoot $ledQ9
    Stop-StQueueHelper $h9
    $q9Lock = $(if (Test-Path -LiteralPath (Join-Path $h9.Out 'probe-lock.txt')) { ([IO.File]::ReadAllText((Join-Path $h9.Out 'probe-lock.txt'))).Trim() } else { '<none>' })
    $q9Slot = $(if (Test-Path -LiteralPath (Join-Path $h9.Out 'probe-slot.txt')) { ([IO.File]::ReadAllText((Join-Path $h9.Out 'probe-slot.txt'))).Trim() } else { '<none>' })
    T ($kMNF + '  while a member waits for the head, another process takes the push lock and a gate slot: the ticket holds neither, and the member then lands') `
      ($rQ9q -eq 0 -and $q9Lock -ceq 'True' -and $q9Slot -match '^[1-9]') ("rc={0} lock={1} slot={2}" -f $rQ9q, $q9Lock, $q9Slot)

    # W9.4 CLEAN TWIN: a queue member that is handed back keeps its ticket: in the hand-back round, a probe in ANOTHER
    # process reads it live and at the head.
    $haWt = New-StQueueWorktree 'ha' 'chain/n.txt' 'ha'
    New-StQueueRec
    $haProbe = Join-Path $tmp 'ha-probe.ps1'; $haOut = Join-Path $tmp 'ha-probe.txt'
    [IO.File]::WriteAllText($haProbe, ("`$env:TC_CHAIN_QUEUE_SELFTEST = '1'`n. '" + (Join-Path $repo ('lib\chain-' + 'queue.ps1')) + "'`n`$l = Get-TcChainQueueLive -Prefix '" + $script:TcPmChainQueuePrefix + "' -QueueRoot '" + $script:TcPmChainQueueRoot + "'`n[IO.File]::WriteAllText('" + $haOut + "', ((@(`$l) | ForEach-Object { [string]`$_.Pid }) -join ','))`n"))
    $script:haGates = 0
    $haGate = { param($d) $script:haGates++; if ($script:haGates -eq 2) { $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $haProbe }; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $script:lockMoves = @('notes.txt')
    $ledHa = Join-Path $tmp 'ledha'
    $rHa = Invoke-WithLockMover { Invoke-TcPushMain -Dir $haWt -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $haGate -RehearsalStarter $qStarter -ChainTouchingProbe $qChain -LedgerRoot $ledHa } -LmCap -1
    $haSeen = $(if (Test-Path -LiteralPath $haOut) { ([IO.File]::ReadAllText($haOut)).Trim() } else { '<no probe>' })
    $haRow = Get-StRow $ledHa
    T ($kCT + '  (W9.4) a queue member handed back keeps its ticket: in the hand-back round another process read exactly its ticket live, at the head, and it lands with hand_backs 1') `
      ($rHa -eq 0 -and $haSeen -ceq [string]$PID -and $null -ne $haRow -and [int]$haRow.hand_backs -eq 1 -and [string]$haRow.queue -ceq 'joined') ("rc={0} liveTickets={1} me={2} handBacks={3} queue={4}" -f $rHa, $haSeen, $PID, $(if ($haRow) { $haRow.hand_backs }), $(if ($haRow) { $haRow.queue }))
    # CLEAN TWIN: a READER that throws costs its field, never the push. The gate's result says its run-gates leg took
    # 'not-a-number' seconds, so Add-TcRunnerReadings' [int] cast throws; the push must land and the row keep leg_sec.rg
    # null. NOT a throwing ScriptProperty: PowerShell swallows a getter's exception on member access and reads $null, and
    # the first version of this case, built that way, survived the mutant that removes the guard (0 reds).
    $tr2 = & $newPusher 'tr'
    $readerThrowGate = { param($d) [pscustomobject]@{ Ran = $true; Code = 0; Why = ''; RgSec = 'not-a-number' } }
    $ledTr = Join-Path $tmp 'ledtr'
    $rTr = $null
    try { $rTr = Invoke-StUnderStop { Invoke-TcPushMain -Dir $tr2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $readerThrowGate -RehearsalRunner $rhGreen -LedgerRoot $ledTr } }
    catch { $rTr = 'threw: ' + $_.Exception.Message }
    $trRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTr)
    $trRows = @($trRaw)
    $trRow = $(if ($trRows.Count) { $trRows[0] } else { $null })
    T ($kCT + '  a row reader that throws outside the lock costs only its field: the push still lands, one row, leg_sec.rg null') `
      ($rTr -eq 0 -and $trRows.Count -eq 1 -and [string]$trRow.outcome -ceq 'landed' -and $null -ne $trRow.leg_sec -and $null -eq $trRow.leg_sec.rg) `
      ("rc={0} rows={1} outcome={2} rg={3}" -f $rTr, $trRows.Count, $(if ($trRow) { $trRow.outcome }), $(if ($trRow) { $trRow.leg_sec.rg }))

    # MUST NOT FIRE (W2.1R step 3): a rebase that fails with NOTHING UNMERGED and no rebase directory never started, so it
    # is COULD-NOT-REBASE, not a conflict. Origin moves before the push starts and the checkout holds an index.lock, so the
    # pre-flight rebase cannot begin; it degrades, the gate runs (and, as the lock's real holder would, lets go of it), and
    # the rebase inside the lock lands the push. The day before, W0.1R's row read this as refused-rebase-conflict.
    $il = & $newPusher 'il'
    & $moveOrigin 'notes.txt'
    $ilLock = Join-Path $il '.git\index.lock'
    [IO.File]::WriteAllText($ilLock, '')
    $ledIl = Join-Path $tmp 'ledil'
    $script:ilGateRuns = 0
    $ilGate = { param($d) $script:ilGateRuns++; Remove-Item -LiteralPath (Join-Path $d '.git\index.lock') -Force -ErrorAction SilentlyContinue; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    try {
      $rIl = Invoke-TcPushMain -Dir $il -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $ilGate -RehearsalRunner $rhGreen -LedgerRoot $ledIl
    } finally { Remove-Item -LiteralPath $ilLock -Force -ErrorAction SilentlyContinue }
    $ilRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledIl)
    $ilRows = @($ilRaw)
    $ilRow = $(if ($ilRows.Count) { $ilRows[0] } else { $null })
    # Since W2.2R the catch-up fetch after round 1's legs is what rebases it, outside the lock, so round 2's legs run too.
    T ($kMNF + '  a pre-flight rebase an index.lock stopped from starting is could-not-rebase, not a conflict: the gate ran, the row says degraded rebase, and the catch-up rebase outside the lock lands it') `
      ($rIl -eq 0 -and $script:ilGateRuns -eq 2 -and $ilRows.Count -eq 1 -and [string]$ilRow.outcome -ceq 'landed-after-rebase' -and [string]$ilRow.degraded -ceq 'rebase' -and $null -eq $ilRow.conflict_files -and (@($ilRow.rebase_phases) -join ',') -ceq 'preflight,catchup') `
      ("rc={0} gateRuns={1} rows={2} outcome={3} degraded={4} files={5} phases={6}" -f $rIl, $script:ilGateRuns, $ilRows.Count, $(if ($ilRow) { $ilRow.outcome }), $(if ($ilRow) { $ilRow.degraded }), $(if ($ilRow) { ConvertTo-Json -Compress -InputObject $ilRow.conflict_files }), $(if ($ilRow) { @($ilRow.rebase_phases) -join ',' }))

    # ---- W2.1R AND W8.1: THE PRE-FLIGHT'S OWN CASES (2026-09-23) ----
    # MUST FIRE: a second push-main in this checkout, while ANOTHER PROCESS holds its guard, is refused at once and names
    # the holder's pid. The holder is lib\mutex-hold.ps1 on this run's private name; its pid goes in the info file, as a
    # real holder's would. Nothing ran: no gate, no fetch, no lock take.
    $gd = & $newPusher 'gd'
    $gKey = Get-TcCheckoutGuardKey -Dir $gd
    $gHold = Start-TcMutexHold -Name ($script:TcPmGuardPrefix + $gKey)
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop $script:TcPmGuardInfoRoot
    [IO.File]::WriteAllText((Join-Path $script:TcPmGuardInfoRoot ($gKey + '.json')), ('{"pid":' + $gHold.Process.Id + ',"start_utc":"2026-09-23T20:00:00.0000000Z","checkout":"fixture"}'))
    $ledGd = Join-Path $tmp 'ledgd'
    $script:gateRuns = 0
    $gdCap = Invoke-StCapture { Invoke-TcPushMain -Dir $gd -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -RehearsalRunner $rhGreen -LedgerRoot $ledGd }
    Stop-TcMutexHold -Hold $gHold
    $gdRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledGd)
    $gdRows = @($gdRaw)
    $gdRow = $(if ($gdRows.Count) { $gdRows[0] } else { $null })
    T ($kMF + '  a second push-main in a checkout whose guard another process holds is refused at once, names that pid, and runs no gate and takes no lock') `
      ($gHold.Held -and $gdCap.Result -eq 1 -and $script:gateRuns -eq 0 -and $gdRows.Count -eq 1 -and [string]$gdRow.outcome -ceq 'refused-not-ready' -and [int]$gdRow.lock_takes -eq 0 -and `
        [string]$gdRow.guard_holder -match ('pid ' + $gHold.Process.Id + '\b') -and $gdCap.Text -match 'do not relaunch' -and $gdCap.Text -match ('pid ' + $gHold.Process.Id + '\b')) `
      ("held={0} rc={1} gateRuns={2} rows={3} outcome={4} takes={5} holder={6}" -f $gHold.Held, $gdCap.Result, $script:gateRuns, $gdRows.Count, $(if ($gdRow) { $gdRow.outcome }), $(if ($gdRow) { $gdRow.lock_takes }), $(if ($gdRow) { $gdRow.guard_holder }))

    # MUST FIRE: a conflicting commit that lands AFTER THE LEGS and the catch-up fetch (the lock-entry mover pushes it,
    # W2.2R) is refused IN THE LOCK: phase inlock, the one conflicted file, the rebase aborted, and HEAD back at the sha
    # the legs judged. (A conflict landed during the legs is now the catch-up's, and has its own case below.)
    $ic = New-Clone 'ic'
    [IO.File]::WriteAllText((Join-Path $ic 'clashI.txt'), 'mine')
    $null = & git -C $ic add -- clashI.txt 2>$null; $null = & git -C $ic commit -q -m 'ic mine' 2>$null
    $script:icHeadAtLegs = ''
    $icRunner = { param($d) $script:icHeadAtLegs = ([string](@(& git -C $d rev-parse HEAD 2>$null))[0]).Trim(); [pscustomobject]@{ Code = 0; Why = 'fixture: rehearsed-pass' } }
    $script:lockMoves = @({ & $moveOriginText 'clashI.txt' 'theirs' })
    $ledIc = Join-Path $tmp 'ledic'
    $rIc = Invoke-WithLockMover { Invoke-TcPushMain -Dir $ic -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $icRunner -LedgerRoot $ledIc }
    $icRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledIc)
    $icRows = @($icRaw)
    $icRow = $(if ($icRows.Count) { $icRows[0] } else { $null })
    $icHead = ([string](@(& git -C $ic rev-parse HEAD 2>$null))[0]).Trim()
    $icMid = Test-TcRebaseInProgress -Dir $ic
    $icFiles = @($(if ($icRow) { $icRow.conflict_files } else { @() }))
    T ($kMF + '  a conflicting commit landed after the catch-up fetch is refused in the lock: phase inlock, the one conflicted file, the rebase aborted, and HEAD the sha the legs judged') `
      ($rIc -eq 1 -and $icRows.Count -eq 1 -and [string]$icRow.outcome -ceq 'refused-rebase-conflict' -and [string]$icRow.phase -ceq 'inlock' -and $icFiles.Count -eq 1 -and [string]$icFiles[0] -ceq 'clashI.txt' -and `
        -not $icMid -and $script:icHeadAtLegs -and [string]::Equals($icHead, $script:icHeadAtLegs, [StringComparison]::Ordinal) -and [int]$icRow.lock_takes -eq 1) `
      ("rc={0} rows={1} outcome={2} phase={3} files={4} mid={5} head={6} atLegs={7}" -f $rIc, $icRows.Count, $(if ($icRow) { $icRow.outcome }), $(if ($icRow) { $icRow.phase }), ($icFiles -join ','), $icMid, $icHead, $script:icHeadAtLegs)

    # MUST FIRE: a branch whose only commit is already on origin as an IDENTICAL PATCH is refused-already-on-main. The
    # rebase exits 0 having skipped it, and `git push` would then say Everything up-to-date and exit 0: the day before
    # recorded that as a landing. No leg runs, the remote is untouched, and no row says landed.
    $am = New-Clone 'am'
    [IO.File]::WriteAllText((Join-Path $am 'am.txt'), 'the same change twice')
    $null = & git -C $am add -- am.txt 2>$null; $null = & git -C $am commit -q -m 'am duplicate lane work' 2>$null
    $null = & git -C $mover pull -q --rebase origin main 2>$null
    $null = & git -C $mover fetch -q $am HEAD 2>$null
    # ANOTHER COMMITTER, so the copy is a different commit with the same patch: the same identity cherry-picking in the
    # same second writes a byte-identical commit object, the SAME sha, and the case read "nothing to push" instead
    # (seen once in the first runs of this case).
    $null = & git -C $mover -c user.name=Lane2 -c user.email=l2@p cherry-pick FETCH_HEAD 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    $amTip = & $tipOf
    $ledAm = Join-Path $tmp 'ledam'
    $script:gateRuns = 0
    $amCap = Invoke-StCapture { Invoke-TcPushMain -Dir $am -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -RehearsalRunner $rhGreen -LedgerRoot $ledAm }
    $amRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledAm)
    $amRows = @($amRaw)
    $amRow = $(if ($amRows.Count) { $amRows[0] } else { $null })
    T ($kMF + '  a branch already on main as an identical patch is refused-already-on-main: no leg ran, the remote is untouched, no row says landed, and the dropped commit is named') `
      ($amCap.Result -eq 1 -and $script:gateRuns -eq 0 -and (& $tipOf) -eq $amTip -and $amRows.Count -eq 1 -and [string]$amRow.outcome -ceq 'refused-already-on-main' -and [string]$amRow.phase -ceq 'preflight' -and $amCap.Text -match 'am duplicate lane work') `
      ("rc={0} gateRuns={1} tipMoved={2} rows={3} outcome={4} phase={5} said={6}" -f $amCap.Result, $script:gateRuns, ((& $tipOf) -ne $amTip), $amRows.Count, $(if ($amRow) { $amRow.outcome }), $(if ($amRow) { $amRow.phase }), (($amCap.Text -split "`n" | Where-Object { $_ -match 'REFUSED' }) -join ' / '))

    # MUST FIRE: an abort that fails (the seam answers exit 1) is could-not-evaluate: exit 3, blind=rebase-abort-failed,
    # and the message says the branch may be mid-rebase and NEVER that it is exactly where it was.
    $ab = New-Clone 'ab'
    [IO.File]::WriteAllText((Join-Path $ab 'clashA.txt'), 'mine')
    $null = & git -C $ab add -- clashA.txt 2>$null; $null = & git -C $ab commit -q -m 'ab mine' 2>$null
    & $moveOriginText 'clashA.txt' 'theirs'
    $ledAb = Join-Path $tmp 'ledab'
    $script:TcPmRebaseAbort = { param($d) [pscustomobject]@{ Code = 1; Out = @(); Err = @('fixture: the abort refused'); Text = 'fixture: the abort refused' } }
    try {
      $abCap = Invoke-StCapture { Invoke-TcPushMain -Dir $ab -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -RehearsalRunner $rhGreen -LedgerRoot $ledAb }
    } finally {
      $script:TcPmRebaseAbort = { param($d) Invoke-TcGit -Dir $d -Arguments @('rebase', '--abort') }
      $null = & git -C $ab rebase --abort 2>$null
    }
    $abRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledAb)
    $abRows = @($abRaw)
    $abRow = $(if ($abRows.Count) { $abRows[0] } else { $null })
    T ($kMF + '  an abort that exits 1 is exit 3 with blind=rebase-abort-failed, says the branch may be mid-rebase, and never says it is exactly where it was') `
      ($abCap.Result -eq 3 -and $abRows.Count -eq 1 -and [string]$abRow.outcome -ceq 'blind-rebase-abort-failed' -and $abCap.Text -match 'blind=rebase-abort-failed' -and $abCap.Text -match 'MAY BE MID-REBASE' -and $abCap.Text -notmatch 'exactly where it was') `
      ("rc={0} rows={1} outcome={2} saysBlind={3} saysWhere={4}" -f $abCap.Result, $abRows.Count, $(if ($abRow) { $abRow.outcome }), ($abCap.Text -match 'blind=rebase-abort-failed'), ($abCap.Text -match 'exactly where it was'))

    # MUST FIRE: a pre-flight rebase that brings in a CHANGED push-main re-executes the new copy once. A tracked file in the
    # clone stands in for this checkout's own push-main (as the pm_blob case above does), and origin replaces it with a
    # stub that records how it was called and writes the push's one row with its own blob. The parent writes none.
    $reRel = 'pmre/push-main.ps1'
    $reMarker = Join-Path $tmp 'reexec-marker.txt'
    $reStub = { param([string]$Tag)
      $ledgerLib = Join-Path $repo ('lib\push-' + 'ledger.ps1')
      ("param([string]`$Remote, [string]`$Branch, [int]`$LockWaitSec, [switch]`$DryRun, [string]`$ChainQueue = 'live')`n" +
       ". '" + $ledgerLib + "'`n" +
       "`$b = ([string](@(& git -C (Split-Path -Parent `$PSCommandPath) hash-object `$PSCommandPath))[0]).Trim()`n" +
       "[IO.File]::WriteAllText('" + $reMarker + "', ('reexec=' + `$env:TC_PUSH_MAIN_REEXEC + ' remote=' + `$Remote + ' branch=' + `$Branch + ' cq=' + `$ChainQueue + ' tag=" + $Tag + "'))`n" +
       "`$null = Write-TcPushRow -Event 'push-main' -Outcome 'landed' -Checkout 'reexec-child' -Fields ([ordered]@{ schema = 2; pm_blob = `$b })`n" +
       "exit 0`n")
    }
    $null = & git -C $mover pull -q --rebase origin main 2>$null
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $mover 'pmre')
    [IO.File]::WriteAllText((Join-Path $mover $reRel), (& $reStub 'v1'))
    $null = & git -C $mover add -- $reRel 2>$null; $null = & git -C $mover commit -q -m 'pmre v1' 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    $re1 = & $newPusher 're1'
    $re2 = & $newPusher 're2'
    $reStart1 = ([string](@(& git -C $re1 hash-object (Join-Path $re1 $reRel) 2>$null))[0]).Trim()
    [IO.File]::WriteAllText((Join-Path $mover $reRel), (& $reStub 'v2'))
    $null = & git -C $mover add -- $reRel 2>$null; $null = & git -C $mover commit -q -m 'pmre v2' 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    $ledRe = Join-Path $tmp 'ledre'
    $pmPathWas2 = $script:TcPushMainPath
    $ledEnvWas = $env:TC_PUSH_LEDGER_ROOT
    $rRe = $null
    try {
      $script:TcPushMainPath = Join-Path $re1 $reRel
      $env:TC_PUSH_LEDGER_ROOT = $ledRe
      $rRe = Invoke-TcPushMain -Dir $re1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -RehearsalRunner $rhGreen -LedgerRoot $ledRe -ChainQueue off
    } finally { $script:TcPushMainPath = $pmPathWas2; $env:TC_PUSH_LEDGER_ROOT = $ledEnvWas }
    $reNow1 = ([string](@(& git -C $re1 hash-object (Join-Path $re1 $reRel) 2>$null))[0]).Trim()
    $reRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRe)
    $reRows = @($reRaw)
    $reRow = $(if ($reRows.Count) { $reRows[0] } else { $null })
    $reSaid = $(if (Test-Path -LiteralPath $reMarker) { ([IO.File]::ReadAllText($reMarker)).Trim() } else { '<not run>' })
    T ($kMF + '  a pre-flight rebase that brings in a changed push-main runs the NEW copy once, with the same arguments (-ChainQueue off among them) and TC_PUSH_MAIN_REEXEC=1; its exit is the run''s, and its row, with the new blob, is the only row') `
      ($rRe -eq 0 -and $reSaid -ceq 'reexec=1 remote=origin branch=main cq=off tag=v2' -and $reRows.Count -eq 1 -and [string]$reRow.checkout -ceq 'reexec-child' -and [string]$reRow.pm_blob -ceq $reNow1 -and $reNow1 -ne $reStart1) `
      ("rc={0} child={1} rows={2} checkout={3} blob={4} new={5} start={6}" -f $rRe, $reSaid, $reRows.Count, $(if ($reRow) { $reRow.checkout }), $(if ($reRow) { $reRow.pm_blob }), $reNow1, $reStart1)
    # CLEAN TWIN, the command line's road: every top-level call of Invoke-TcPushMain in this script binds -ChainQueue to
    # the script's own -ChainQueue. Read from the AST of this file, because a fixture drives the function and never the
    # entry point: W9.2's first commit bound it nowhere, so `-ChainQueue off` on the command line was silently live.
    $epErrs = $null
    $epAst = [System.Management.Automation.Language.Parser]::ParseFile($script:TcPushMainPath, [ref]$null, [ref]$epErrs)
    $epCalls = @($epAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Invoke-TcPushMain' }, $true) | Where-Object {
      $p = $_.Parent; $inFn = $false
      while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $inFn = $true; break }; $p = $p.Parent }
      # THE ENTRY POINT is the call on -Dir $repo: the suite's own fixture calls sit at the top level too, on temp clones.
      $isEntry = $false; $ce = @($_.CommandElements)
      for ($k = 0; $k -lt $ce.Count - 1; $k++) { if ($ce[$k] -is [System.Management.Automation.Language.CommandParameterAst] -and $ce[$k].ParameterName -ceq 'Dir' -and $ce[$k + 1] -is [System.Management.Automation.Language.VariableExpressionAst] -and $ce[$k + 1].VariablePath.UserPath -ceq 'repo') { $isEntry = $true } }
      (-not $inFn) -and $isEntry })
    $epBound = @($epCalls | Where-Object {
      $els = @($_.CommandElements); $ok = $false
      for ($i = 0; $i -lt $els.Count - 1; $i++) {
        if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -ceq 'ChainQueue' -and $els[$i + 1] -is [System.Management.Automation.Language.VariableExpressionAst] -and $els[$i + 1].VariablePath.UserPath -ceq 'ChainQueue') { $ok = $true }
      }
      $ok })
    T ($kCT + '  the command line''s -ChainQueue reaches the push: the entry point''s Invoke-TcPushMain call (on -Dir $repo) binds -ChainQueue $ChainQueue') `
      (@($epErrs).Count -eq 0 -and $epCalls.Count -eq 1 -and $epBound.Count -eq $epCalls.Count) `
      ("parseErrors={0} calls={1} bound={2}" -f @($epErrs).Count, $epCalls.Count, $epBound.Count)
    # CLEAN TWIN: with TC_PUSH_MAIN_REEXEC already set (a run that IS the new copy) it never re-executes again: the
    # stand-in moves once more, the push lands through this copy, and its own row carries the blob it started with.
    $reStart2 = ([string](@(& git -C $re2 hash-object (Join-Path $re2 $reRel) 2>$null))[0]).Trim()
    [IO.File]::WriteAllText((Join-Path $mover $reRel), (& $reStub 'v3'))
    $null = & git -C $mover add -- $reRel 2>$null; $null = & git -C $mover commit -q -m 'pmre v3' 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    Remove-Item -LiteralPath $reMarker -Force -ErrorAction SilentlyContinue
    $ledRe2 = Join-Path $tmp 'ledre2'
    $rRe2 = $null
    try {
      $script:TcPushMainPath = Join-Path $re2 $reRel
      $env:TC_PUSH_MAIN_REEXEC = '1'
      $rRe2 = Invoke-TcPushMain -Dir $re2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -RehearsalRunner $rhGreen -LedgerRoot $ledRe2
    } finally { $script:TcPushMainPath = $pmPathWas2; Remove-Item -LiteralPath Env:TC_PUSH_MAIN_REEXEC -ErrorAction SilentlyContinue }
    $re2Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRe2)
    $re2Rows = @($re2Raw)
    $re2Row = $(if ($re2Rows.Count) { $re2Rows[0] } else { $null })
    T ($kCT + '  with TC_PUSH_MAIN_REEXEC set the run does not re-execute again: no child ran, it landed itself, and its row carries its start blob and reexec true') `
      ($rRe2 -eq 0 -and -not (Test-Path -LiteralPath $reMarker) -and $re2Rows.Count -eq 1 -and [string]$re2Row.outcome -ceq 'landed-after-rebase' -and [string]$re2Row.pm_blob -ceq $reStart2 -and $re2Row.reexec -eq $true) `
      ("rc={0} childRan={1} rows={2} outcome={3} blob={4} start={5} reexec={6}" -f $rRe2, (Test-Path -LiteralPath $reMarker), $re2Rows.Count, $(if ($re2Row) { $re2Row.outcome }), $(if ($re2Row) { $re2Row.pm_blob }), $reStart2, $(if ($re2Row) { $re2Row.reexec }))

    # CLEAN TWIN (split plan D3): with no pieces folder beside the host, the re-exec key IS the host blob, so a checkout
    # from before the split keys exactly as pm_blob always did. re1 was cloned before any piece existed.
    $skPath1 = Join-Path $re1 $reRel
    $skKey1 = Get-TcScriptSetKey -Path $skPath1
    $skBlob1 = Get-TcScriptBlob -Path $skPath1
    T ($kCT + '  with no push-main pieces folder beside the host, the re-exec key is exactly the host blob') `
      ($skBlob1 -match '^[0-9a-f]{40}$' -and [string]::Equals($skKey1, $skBlob1, [StringComparison]::Ordinal)) ("key={0} blob={1}" -f $skKey1, $skBlob1)
    # MUST FIRE (split plan D3): a pre-flight rebase that changes ONLY a piece under the host's push-main folder, leaving
    # the host byte-identical, still runs the NEW copy once. A key over the host alone would let the stale copy land.
    $pcRel = 'pmre/push-main/readings.ps1'
    $null = & git -C $mover pull -q --rebase origin main 2>$null
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $mover 'pmre\push-main')
    [IO.File]::WriteAllText((Join-Path $mover $pcRel), "# piece v1`n")
    $null = & git -C $mover add -- $pcRel 2>$null; $null = & git -C $mover commit -q -m 'piece v1' 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    $re3 = & $newPusher 're3'
    $re3HostStart = Get-TcScriptBlob -Path (Join-Path $re3 $reRel)
    [IO.File]::WriteAllText((Join-Path $mover $pcRel), "# piece v2`n")
    $null = & git -C $mover add -- $pcRel 2>$null; $null = & git -C $mover commit -q -m 'piece v2' 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    Remove-Item -LiteralPath $reMarker -Force -ErrorAction SilentlyContinue
    $ledRe3 = Join-Path $tmp 'ledre3'
    $rRe3 = $null
    try {
      $script:TcPushMainPath = Join-Path $re3 $reRel
      $env:TC_PUSH_LEDGER_ROOT = $ledRe3
      $rRe3 = Invoke-TcPushMain -Dir $re3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -RehearsalRunner $rhGreen -LedgerRoot $ledRe3 -ChainQueue off
    } finally { $script:TcPushMainPath = $pmPathWas2; $env:TC_PUSH_LEDGER_ROOT = $ledEnvWas }
    $re3HostNow = Get-TcScriptBlob -Path (Join-Path $re3 $reRel)
    $re3Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRe3)
    $re3Rows = @($re3Raw)
    $re3Said = $(if (Test-Path -LiteralPath $reMarker) { ([IO.File]::ReadAllText($reMarker)).Trim() } else { '<not run>' })
    T ($kMF + '  a pre-flight rebase that changes only a piece under ops\push-main\ (host byte-identical) still runs the NEW copy once, and the child writes the only row') `
      ($rRe3 -eq 0 -and $re3Said -ceq 'reexec=1 remote=origin branch=main cq=off tag=v3' -and $re3Rows.Count -eq 1 -and [string]$re3Rows[0].checkout -ceq 'reexec-child' -and $re3HostStart -and [string]::Equals($re3HostStart, $re3HostNow, [StringComparison]::Ordinal)) `
      ("rc={0} child={1} rows={2} checkout={3} hostStart={4} hostNow={5}" -f $rRe3, $re3Said, $re3Rows.Count, $(if ($re3Rows.Count) { $re3Rows[0].checkout }), $re3HostStart, $re3HostNow)
    # CLEAN TWIN: pieces present, and the rebase brings in only an unrelated file: no child runs, the push lands itself.
    $re4 = & $newPusher 're4'
    [IO.File]::WriteAllText((Join-Path $mover 'pmre-other.txt'), 'other')
    $null = & git -C $mover add -- 'pmre-other.txt' 2>$null; $null = & git -C $mover commit -q -m 'unrelated' 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    Remove-Item -LiteralPath $reMarker -Force -ErrorAction SilentlyContinue
    $ledRe4 = Join-Path $tmp 'ledre4'
    $rRe4 = $null
    try {
      $script:TcPushMainPath = Join-Path $re4 $reRel
      $env:TC_PUSH_LEDGER_ROOT = $ledRe4
      $rRe4 = Invoke-TcPushMain -Dir $re4 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -RehearsalRunner $rhGreen -LedgerRoot $ledRe4 -ChainQueue off
    } finally { $script:TcPushMainPath = $pmPathWas2; $env:TC_PUSH_LEDGER_ROOT = $ledEnvWas }
    $re4Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRe4)
    $re4Rows = @($re4Raw)
    T ($kCT + '  with pieces present, a rebase that brings in only an unrelated file runs no child and the push lands itself') `
      ($rRe4 -eq 0 -and -not (Test-Path -LiteralPath $reMarker) -and $re4Rows.Count -eq 1 -and [string]$re4Rows[0].outcome -ceq 'landed-after-rebase') `
      ("rc={0} childRan={1} rows={2} outcome={3}" -f $rRe4, (Test-Path -LiteralPath $reMarker), $re4Rows.Count, $(if ($re4Rows.Count) { $re4Rows[0].outcome }))

    # MUST NOT FIRE: a fetch that fails ONCE with `cannot lock ref` succeeds on its retry. Origin moves so the fetch must
    # update the remote-tracking ref, and that ref's .lock file exists (git creates a lock with O_EXCL, so a file present
    # is exactly what another updater holding it looks like to git) until the retry seam removes it, after the first try.
    $fr = & $newPusher 'fr'
    & $moveOrigin 'notes.txt'
    $frLockDir = Join-Path $fr '.git\refs\remotes\origin'
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop $frLockDir
    $frLock = Join-Path $frLockDir 'main.lock'
    [IO.File]::WriteAllText($frLock, '')
    $script:frRetries = 0
    $script:TcPmBeforeFetchRetry = { param($d) $script:frRetries++; Remove-Item -LiteralPath (Join-Path $d '.git\refs\remotes\origin\main.lock') -Force -ErrorAction SilentlyContinue }
    $ledFr = Join-Path $tmp 'ledfr'
    try {
      $rFr = Invoke-TcPushMain -Dir $fr -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhGreen -LedgerRoot $ledFr
    } finally { $script:TcPmBeforeFetchRetry = $null; Remove-Item -LiteralPath $frLock -Force -ErrorAction SilentlyContinue }
    $frRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledFr)
    $frRows = @($frRaw)
    $frRow = $(if ($frRows.Count) { $frRows[0] } else { $null })
    T ($kMNF + '  a fetch that fails once with cannot lock ref retries once and succeeds: the push lands, rebased at the pre-flight, and nothing degraded') `
      ($rFr -eq 0 -and $script:frRetries -eq 1 -and $frRows.Count -eq 1 -and [string]$frRow.outcome -ceq 'landed-after-rebase' -and $null -eq $frRow.degraded -and (@($frRow.rebase_phases) -join ',') -ceq 'preflight') `
      ("rc={0} retries={1} rows={2} outcome={3} degraded={4} phases={5}" -f $rFr, $script:frRetries, $frRows.Count, $(if ($frRow) { $frRow.outcome }), $(if ($frRow) { $frRow.degraded }), $(if ($frRow) { @($frRow.rebase_phases) -join ',' }))

    # MUST NOT FIRE: a fetch that keeps failing OUTSIDE the lock does not refuse. The clone's remote points nowhere until its
    # gate stub puts it back, so the pre-flight fetch fails, the stub still runs, and the fetch inside the lock lands it.
    $fx = & $newPusher 'fx'
    $null = & git -C $fx remote set-url origin (Join-Path $tmp 'no-such-remote') 2>$null
    $script:fxGateRuns = 0
    $fxGate = { param($d) $script:fxGateRuns++; $null = & git -C $d remote set-url origin $origin 2>$null; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledFx = Join-Path $tmp 'ledfx'
    $rFx = Invoke-TcPushMain -Dir $fx -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $fxGate -RehearsalRunner $rhGreen -LedgerRoot $ledFx
    $fxRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledFx)
    $fxRows = @($fxRaw)
    $fxRow = $(if ($fxRows.Count) { $fxRows[0] } else { $null })
    T ($kMNF + '  a fetch that keeps failing outside the lock does not refuse: the gate stub ran, the row says degraded fetch, and the fetch inside the lock lands it') `
      ($rFx -eq 0 -and $script:fxGateRuns -eq 1 -and $fxRows.Count -eq 1 -and [string]$fxRow.degraded -ceq 'fetch' -and ([string]$fxRow.outcome).StartsWith('landed')) `
      ("rc={0} gateRuns={1} rows={2} degraded={3} outcome={4}" -f $rFx, $script:fxGateRuns, $fxRows.Count, $(if ($fxRow) { $fxRow.degraded }), $(if ($fxRow) { $fxRow.outcome }))

    # MUST NOT FIRE: -DryRun never moves HEAD, even when origin moved and a rebase is needed, and it runs ONE round.
    $dr = & $newPusher 'dr'
    & $moveOrigin 'notes.txt'
    $drHead0 = ([string](@(& git -C $dr rev-parse HEAD 2>$null))[0]).Trim()
    $ledDr = Join-Path $tmp 'leddr'
    $script:gateRuns = 0
    $drCap = Invoke-StCapture { Invoke-TcPushMain -Dir $dr -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -RehearsalRunner $rhGreen -LedgerRoot $ledDr }
    $drHead1 = ([string](@(& git -C $dr rev-parse HEAD 2>$null))[0]).Trim()
    $drRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledDr)
    $drRows = @($drRaw)
    $drRow = $(if ($drRows.Count) { $drRows[0] } else { $null })
    T ($kMNF + '  -DryRun with a rebase needed never moves HEAD, says the rebase was not run, and runs one round') `
      ($drCap.Result -eq 0 -and $drHead0 -eq $drHead1 -and $script:gateRuns -eq 1 -and $drRows.Count -eq 1 -and [string]$drRow.outcome -ceq 'dry-run' -and [int]$drRow.rounds -eq 1 -and @($drRow.rebase_phases).Count -eq 0 -and $drCap.Text -match 'was NOT run') `
      ("rc={0} headMoved={1} gateRuns={2} rows={3} outcome={4} rounds={5} phases={6}" -f $drCap.Result, ($drHead0 -ne $drHead1), $script:gateRuns, $drRows.Count, $(if ($drRow) { $drRow.outcome }), $(if ($drRow) { $drRow.rounds }), $(if ($drRow) { @($drRow.rebase_phases) -join ',' }))

    # W8.1, MUST FIRE: a runner stub that writes a TRACKED file makes the tree dirty during the legs, and the push is refused
    # with dirty_since during-legs naming that file. Since W2.2R the catch-up sync after the legs is what finds it, so the
    # refusal is phase catchup, before the lock. MUST NOT FIRE: an ignored file the stub writes does not refuse.
    $dw = & $newPusher 'dw'
    $dwGate = { param($d) [IO.File]::WriteAllText((Join-Path $d 'seed.txt'), 'written by a leg'); [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledDw = Join-Path $tmp 'leddw'
    $dwCap = Invoke-StCapture { Invoke-TcPushMain -Dir $dw -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $dwGate -RehearsalRunner $rhGreen -LedgerRoot $ledDw }
    $dwRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledDw)
    $dwRows = @($dwRaw)
    $dwRow = $(if ($dwRows.Count) { $dwRows[0] } else { $null })
    $dwPaths = @($(if ($dwRow) { $dwRow.dirty_paths } else { @() }))
    T ($kMF + '  a leg that writes a tracked file is refused by the catch-up sync with dirty_since during-legs naming that file, before the lock, and the message says the pre-flight was clean') `
      ($dwCap.Result -eq 1 -and $dwRows.Count -eq 1 -and [string]$dwRow.outcome -ceq 'refused-not-ready' -and [string]$dwRow.phase -ceq 'catchup' -and [int]$dwRow.lock_takes -eq 0 -and [string]$dwRow.dirty_since -ceq 'during-legs' -and $dwPaths.Count -eq 1 -and ([string]$dwPaths[0]).Trim() -ceq 'M seed.txt' -and $dwCap.Text -match 'clean at the pre-flight') `
      ("rc={0} rows={1} outcome={2} phase={3} since={4} paths={5}" -f $dwCap.Result, $dwRows.Count, $(if ($dwRow) { $dwRow.outcome }), $(if ($dwRow) { $dwRow.phase }), $(if ($dwRow) { $dwRow.dirty_since }), ($dwPaths -join '|'))
    $dgi = & $newPusher 'dgi'
    Add-Content -LiteralPath (Join-Path $dgi '.git\info\exclude') -Value @('ign.txt') -Encoding ascii
    $dgiGate = { param($d) [IO.File]::WriteAllText((Join-Path $d 'ign.txt'), 'ignored output'); [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $rDgi = Invoke-TcPushMain -Dir $dgi -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $dgiGate -RehearsalRunner $rhGreen
    T ($kMNF + '  an ignored file a leg writes does not refuse: the push lands') ($rDgi -eq 0 -and (& $tipOf) -eq ([string](@(& git -C $dgi rev-parse HEAD 2>$null))[0]).Trim()) ("rc={0}" -f $rDgi)

    # MUST FIRE: pm_blob names the script AS IT WAS AT START. A file tracked in the clone stands in for the checkout's own
    # push-main, and origin changes it before the push starts, so the round-1 rebase rewrites it on disk before any leg
    # runs. $script:TcPushMainPath points at that copy for this one run and is put back in finally.
    $pbRel = 'pmfx/push-main.ps1'
    $null = & git -C $mover pull -q --rebase origin main 2>$null
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $mover 'pmfx')
    [IO.File]::WriteAllText((Join-Path $mover $pbRel), "# the push-main this checkout started with`n")
    $null = & git -C $mover add -- $pbRel 2>$null; $null = & git -C $mover commit -q -m 'pmfx start' 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    $pb = & $newPusher 'pb'
    $pbPath = Join-Path $pb $pbRel
    $pbAtStart = ([string](@(& git -C $pb hash-object $pbPath 2>$null))[0]).Trim()
    & $moveOrigin $pbRel
    $ledPb = Join-Path $tmp 'ledpb'
    $pmPathWas = $script:TcPushMainPath
    $rPb = $null
    try {
      $script:TcPushMainPath = $pbPath
      # -NoReexec: this case is about the hash at START, and the stand-in here is no runnable script (the re-exec cases
      # below drive one that is).
      $rPb = Invoke-TcPushMain -Dir $pb -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhGreen -LedgerRoot $ledPb -NoReexec $true
    } finally {
      $script:TcPushMainPath = $pmPathWas
    }
    $pbNow = ([string](@(& git -C $pb hash-object $pbPath 2>$null))[0]).Trim()
    $pbRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledPb)
    $pbRows = @($pbRaw)
    $pbRow = $(if ($pbRows.Count) { $pbRows[$pbRows.Count - 1] } else { $null })
    T ($kMF + '  pm_blob is the hash of the script as it was at START, although the round-1 rebase rewrote that very file on disk before anything else ran') `
      ($rPb -eq 0 -and $pbRows.Count -eq 1 -and $pbAtStart -match '^[0-9a-f]{40}$' -and [string]$pbRow.pm_blob -ceq $pbAtStart -and $pbNow -match '^[0-9a-f]{40}$' -and $pbNow -ne $pbAtStart -and `
        (@($pbRow.rebase_phases) -join ',') -ceq 'preflight') `
      ("rc={0} rows={1} pm_blob={2} atStart={3} onDiskNow={4} phases={5}" -f $rPb, $pbRows.Count, $(if ($pbRow) { $pbRow.pm_blob }), $pbAtStart, $pbNow, $(if ($pbRow) { @($pbRow.rebase_phases) -join ',' }))
    T ($kCT + '  the running script''s path is back after that case, so every later row hashes this file') `
      ([string]::Equals([string]$script:TcPushMainPath, [string]$pmPathWas, [StringComparison]::Ordinal) -and [string]$script:TcPushMainPath) ("path={0}" -f $script:TcPushMainPath)

    # THE CLONES ARE $cloneA, $cloneB AND $cloneC, never $a, $b and $c (2026-09-23): PowerShell names ignore case, so
    # `$a = New-Clone 'a'` WAS the $A sha constant above, and every case after this point that used $A or $B read a
    # clone path. The first one to do so wrote a malformed ledger row out of the path's backslashes.
    $cloneA = New-Clone 'a'
    [IO.File]::WriteAllText((Join-Path $cloneA 'a.txt'), 'a')
    $null = & git -C $cloneA add -- a.txt 2>$null; $null = & git -C $cloneA commit -q -m a 2>$null
    $r1 = Invoke-TcPushMain -Dir $cloneA -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate
    $remA = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    $headA = ([string](@(& git -C $cloneA rev-parse HEAD 2>$null))[0]).Trim()
    T ($kMNF + '  a clean branch on a current base lands on its first attempt') `
      ($r1 -eq 0 -and $remA -eq $headA) ("rc={0} remote={1} head={2}" -f $r1, $remA, $headA)

    # MAIN MOVES UNDER A SECOND CHECKOUT: the reported failure's exact shape.
    $cloneB = New-Clone 'b'
    [IO.File]::WriteAllText((Join-Path $cloneB 'b.txt'), 'b')
    $null = & git -C $cloneB add -- b.txt 2>$null; $null = & git -C $cloneB commit -q -m b 2>$null
    $cloneC = New-Clone 'c'
    [IO.File]::WriteAllText((Join-Path $cloneC 'c.txt'), 'c')
    $null = & git -C $cloneC add -- c.txt 2>$null; $null = & git -C $cloneC commit -q -m c 2>$null
    $null = & git -C $cloneC push -q origin HEAD:main 2>$null      # c lands while b is still holding a stale base
    $r2 = Invoke-TcPushMain -Dir $cloneB -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate
    $remB = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    $headB = ([string](@(& git -C $cloneB rev-parse HEAD 2>$null))[0]).Trim()
    $hasC = @(& git -C $cloneB log --oneline 2>$null) -match ' c$'
    T ($kMF + '  a branch whose base the remote moved past is rebased before the lock and still lands on its first attempt') `
      ($r2 -eq 0 -and $remB -eq $headB -and @($hasC).Count -ge 1) ("rc={0} remote={1} head={2} carriesC={3}" -f $r2, $remB, $headB, @($hasC).Count)

    # A DIRTY TREE IS REFUSED, and the branch is not touched.
    $d2 = New-Clone 'd'
    [IO.File]::WriteAllText((Join-Path $d2 'd.txt'), 'd')
    $null = & git -C $d2 add -- d.txt 2>$null; $null = & git -C $d2 commit -q -m d 2>$null
    [IO.File]::WriteAllText((Join-Path $d2 'dirty.txt'), 'uncommitted')
    $headD0 = ([string](@(& git -C $d2 rev-parse HEAD 2>$null))[0]).Trim()
    $ledD2 = Join-Path $tmp 'ledd2'
    $script:gateRuns = 0
    $r3 = Invoke-TcPushMain -Dir $d2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -LedgerRoot $ledD2
    $headD1 = ([string](@(& git -C $d2 rev-parse HEAD 2>$null))[0]).Trim()
    T ($kMF + '  a dirty checkout is refused and its branch is left exactly where it was') `
      ($r3 -eq 1 -and $headD0 -eq $headD1) ("rc={0} before={1} after={2}" -f $r3, $headD0, $headD1)
    # W8.1: THE DIRT IS NAMED, and it was there at the START, so no leg ran.
    $d2Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledD2)
    $d2Rows = @($d2Raw)
    $d2Row = $(if ($d2Rows.Count) { $d2Rows[0] } else { $null })
    $d2Paths = @($(if ($d2Row) { $d2Row.dirty_paths } else { @() }))
    T ($kMF + '  a tree dirty at the start is refused before the runner stub runs, with dirty_since start and the path') `
      ($r3 -eq 1 -and $script:gateRuns -eq 0 -and $d2Rows.Count -eq 1 -and [string]$d2Row.dirty_since -ceq 'start' -and [string]$d2Row.phase -ceq 'preflight' -and $d2Paths.Count -eq 1 -and ([string]$d2Paths[0]).Trim() -ceq '?? dirty.txt') `
      ("rc={0} gateRuns={1} rows={2} since={3} phase={4} paths={5}" -f $r3, $script:gateRuns, $d2Rows.Count, $(if ($d2Row) { $d2Row.dirty_since }), $(if ($d2Row) { $d2Row.phase }), ($d2Paths -join '|'))

    # A CONFLICTING REBASE IS ABORTED, not left half-applied for the next session to inherit.
    $e = New-Clone 'e'
    [IO.File]::WriteAllText((Join-Path $e 'clash.txt'), 'mine')
    $null = & git -C $e add -- clash.txt 2>$null; $null = & git -C $e commit -q -m mine 2>$null
    $g = New-Clone 'g'
    [IO.File]::WriteAllText((Join-Path $g 'clash.txt'), 'theirs')
    $null = & git -C $g add -- clash.txt 2>$null; $null = & git -C $g commit -q -m theirs 2>$null
    $null = & git -C $g push -q origin HEAD:main 2>$null
    $headE0 = ([string](@(& git -C $e rev-parse HEAD 2>$null))[0]).Trim()
    $r4 = Invoke-TcPushMain -Dir $e -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate
    $headE1 = ([string](@(& git -C $e rev-parse HEAD 2>$null))[0]).Trim()
    $midRebase = (Test-Path -LiteralPath (Join-Path $e '.git\rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $e '.git\rebase-apply'))
    T ($kMF + '  a conflicting rebase is aborted, refused, and leaves no half-finished rebase behind') `
      ($r4 -eq 1 -and $headE0 -eq $headE1 -and -not $midRebase) ("rc={0} before={1} after={2} midRebase={3}" -f $r4, $headE0, $headE1, $midRebase)
    $eStatus = @(& git -C $e status --porcelain 2>$null | Where-Object { "$_".Trim() })
    T ($kCT + '  after a refused pre-flight the checkout is the original sha with an empty git status --porcelain') `
      ($headE0 -eq $headE1 -and $eStatus.Count -eq 0) ("head={0} status={1}" -f $headE1, ($eStatus -join ' | '))

    # NOTHING TO PUSH IS A REFUSAL, not a claimed landing.
    $h = New-Clone 'h'
    $r5 = Invoke-TcPushMain -Dir $h -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate
    T ($kMF + '  a checkout with nothing to push is refused rather than reporting a landing') ($r5 -eq 1) ("rc={0}" -f $r5)

    # -DryRun DOES EVERYTHING BUT THE PUSH, and the remote is untouched.
    $i = New-Clone 'i'
    [IO.File]::WriteAllText((Join-Path $i 'i.txt'), 'i')
    $null = & git -C $i add -- i.txt 2>$null; $null = & git -C $i commit -q -m i 2>$null
    $remBefore = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    $r6 = Invoke-TcPushMain -Dir $i -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate
    $remAfter = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    T ($kCT + '  -DryRun leaves the remote exactly where it was and still reports success') `
      ($r6 -eq 0 -and $remBefore -eq $remAfter) ("rc={0} before={1} after={2}" -f $r6, $remBefore, $remAfter)
    # ---- THE GATE RUNS BEFORE THE LOCK (Brad, 2026-09-12) ----
    # The assertion is the ORDER, read from the MECHANISM and never from a clock: $okGate tries to take the push lock
    # itself while it runs, and can only succeed if the caller has not taken it yet. A wall-clock bar here would be
    # the shape ops-and-gates.md forbids - several sessions push from this box, so any duration is somebody else's
    # load - and it could not tell "the gate ran first" from "the gate ran fast".
    # THE ORDERING CASE GETS ITS OWN RUN, WITH THE INHERITANCE TOKEN CLEARED. Reading the flag left by whichever case
    # ran last made it FLAKY, and a flaky case is an insensitive one: the mutant that hoists the lock back above the
    # gate died in only 1 of 2 paired rounds. The reason is lib\push-lock.ps1's inheritance - a lease taken while
    # TC_PUSH_LOCK_HOLDER names a live holder HOLDS NOTHING and releases nothing, by design, so whether the mutant
    # really owned the mutex when the probe looked depended on what an earlier case had left in this process's
    # environment. Cleared here, the mutant owns it every time.
    $o = New-Clone 'o'
    [IO.File]::WriteAllText((Join-Path $o 'o.txt'), 'o')
    $null = & git -C $o add -- o.txt 2>$null; $null = & git -C $o commit -q -m o 2>$null
    $tokenWas = $env:TC_PUSH_LOCK_HOLDER
    $env:TC_PUSH_LOCK_HOLDER = $null
    $script:gateSawLock = $null
    $rOrder = Invoke-TcPushMain -Dir $o -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate
    $env:TC_PUSH_LOCK_HOLDER = $tokenWas
    T ($kMF + '  the gate runs BEFORE the push lock is taken, so gating is not serialised behind every other session') `
      ($script:gateSawLock -eq $true -and $rOrder -eq 0) ("lockWasFreeWhenTheGateRan={0} rc={1}" -f $script:gateSawLock, $rOrder)

    # A RED GATE NEVER ENTERS THE QUEUE. Before this change it took the lock, ran its whole set, and held up every
    # other push on the box before refusing.
    $j = New-Clone 'j'
    [IO.File]::WriteAllText((Join-Path $j 'j.txt'), 'j')
    $null = & git -C $j add -- j.txt 2>$null; $null = & git -C $j commit -q -m j 2>$null
    $remJ0 = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    $script:gateSawLock = $null
    $rRed = Invoke-TcPushMain -Dir $j -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $redGate
    $remJ1 = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    $lockFreeAfterRed = Enter-TcPushLock -Prefix $prefix -QueueRoot $qroot -WaitSec 5 -PollMs 50 -NoInherit
    T ($kMF + '  a red gate refuses the push and never takes the lock, so a failing push stops blocking everyone else') `
      ($rRed -eq 1 -and $remJ0 -eq $remJ1 -and $lockFreeAfterRed.Held) ("rc={0} remoteMoved={1} lockFree={2}" -f $rRed, ($remJ0 -ne $remJ1), $lockFreeAfterRed.Held)
    Exit-TcPushLock $lockFreeAfterRed

    # A 3 IS NOT A REFUSAL. Could-not-evaluate outside the lock is usually slot contention on this box, and treating
    # it as red would make a busy box unpushable; treating it as green would be reading a 3 as a pass, which this
    # estate refuses everywhere. It degrades to the behaviour of the day before: take the lock, let the hook gate it.
    $k = New-Clone 'k'
    [IO.File]::WriteAllText((Join-Path $k 'k.txt'), 'k')
    $null = & git -C $k add -- k.txt 2>$null; $null = & git -C $k commit -q -m k 2>$null
    $rBlind = Invoke-TcPushMain -Dir $k -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $blindGate
    $remK = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    $headK = ([string](@(& git -C $k rev-parse HEAD 2>$null))[0]).Trim()
    T ($kCT + '  a gate that could not evaluate outside the lock still pushes under it, gated by the hook exactly as before') `
      ($rBlind -eq 0 -and $remK -eq $headK) ("rc={0} remote={1} head={2}" -f $rBlind, $remK, $headK)

    # ---- THE ROW EACH PUSH RECORDS (2026-09-12, lib\push-ledger.ps1) ----
    # The case above proves a stale base lands on the first attempt. This proves the box can SAY SO afterwards: the
    # row carries what the remote held when the push queued, what it held under the lock, and how it ended, so
    # "did the remote move while this push waited" stops being archaeology over a %TEMP% that drops its successes.
    $ledRoot = Join-Path $tmp 'led'
    $m1 = New-Clone 'm1'
    [IO.File]::WriteAllText((Join-Path $m1 'm1.txt'), 'm1')
    $null = & git -C $m1 add -- m1.txt 2>$null; $null = & git -C $m1 commit -q -m m1 2>$null
    $m2 = New-Clone 'm2'
    [IO.File]::WriteAllText((Join-Path $m2 'm2.txt'), 'm2')
    $null = & git -C $m2 add -- m2.txt 2>$null; $null = & git -C $m2 commit -q -m m2 2>$null
    $null = & git -C $m2 push -q origin HEAD:main 2>$null     # m2 lands while m1 is still on a base that has moved
    $rLed = Invoke-TcPushMain -Dir $m1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -LedgerRoot $ledRoot
    $ledRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRoot)
    $ledRows = @($ledRaw)
    $mLed = Measure-TcPushRows $ledRows
    T ($kMF + '  a push whose base the remote moved past records a row saying the remote MOVED and that it landed after a rebase') `
      ($rLed -eq 0 -and $ledRows.Count -eq 1 -and $mLed.Moved -eq 1 -and $ledRows[0].outcome -eq 'landed-after-rebase') `
      ("rc={0} rows={1} moved={2} outcome={3}" -f $rLed, $ledRows.Count, $mLed.Moved, $(if ($ledRows.Count) { $ledRows[0].outcome } else { '' }))

    # A REFUSAL IS RECORDED TOO. A ledger that only holds the pushes that landed is the same biased population the
    # %TEMP% logs already were, and it is the refusals that say whether the path converges.
    $ledRoot2 = Join-Path $tmp 'led2'
    $n1 = New-Clone 'n1'
    # ONE PATH CONFLICTS, and both commits carry ONE SUBJECT: two sessions landing the same fix is the shape
    # sibling_same_subject exists to name.
    [IO.File]::WriteAllText((Join-Path $n1 'clash2.txt'), 'mine')
    $null = & git -C $n1 add -- clash2.txt 2>$null; $null = & git -C $n1 commit -q -m 'shared subject two' 2>$null
    $n2 = New-Clone 'n2'
    [IO.File]::WriteAllText((Join-Path $n2 'clash2.txt'), 'theirs')
    $null = & git -C $n2 add -- clash2.txt 2>$null; $null = & git -C $n2 commit -q -m 'shared subject two' 2>$null
    $null = & git -C $n2 push -q origin HEAD:main 2>$null
    $n2Sha = ([string](@(& git -C $n2 rev-parse HEAD 2>$null))[0]).Trim()
    $script:gateRuns = 0
    $rRef = Invoke-TcPushMain -Dir $n1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -LedgerRoot $ledRoot2
    $refRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRoot2)
    $refRows = @($refRaw)
    T ($kMF + '  a push refused because its rebase conflicts records that refusal by name, so the ledger is not just the pushes that landed') `
      ($rRef -eq 1 -and $refRows.Count -eq 1 -and $refRows[0].outcome -eq 'refused-rebase-conflict') `
      ("rc={0} rows={1} outcome={2}" -f $rRef, $refRows.Count, $(if ($refRows.Count) { $refRows[0].outcome } else { '' }))
    # RECORD THE CASE AT THE MOMENT IT FAILS (W0.1): the unmerged paths exist only until `git rebase --abort`, so a row
    # that read them afterwards would say [] here. Exactly the one path, scoped to the commit the rebase stopped on.
    # THE CONFLICT IS FOUND IN THE PRE-FLIGHT NOW (W0.1R): n2 landed before this push started, so the round-1 fetch and
    # rebase meet it before any leg runs, and the files are read inside Invoke-TcSyncToRemote's failure branch.
    $cr = $(if ($refRows.Count) { $refRows[0] } else { $null })
    $crFiles = @($(if ($cr) { $cr.conflict_files } else { @() }))
    T ($kMF + '  that row names exactly the one conflicted path, read before the abort, with conflict_scope first-stop, phase preflight and rebase_phases preflight, and no leg ran') `
      ($null -ne $cr -and $crFiles.Count -eq 1 -and [string]$crFiles[0] -ceq 'clash2.txt' -and [string]$cr.conflict_scope -ceq 'first-stop' -and [string]$cr.phase -ceq 'preflight' -and (@($cr.rebase_phases) -join ',') -ceq 'preflight' -and $script:gateRuns -eq 0) `
      ("files={0} scope={1} phase={2} phases={3} gateRuns={4}" -f ($crFiles -join ','), $(if ($cr) { $cr.conflict_scope }), $(if ($cr) { $cr.phase }), $(if ($cr) { @($cr.rebase_phases) -join ',' }), $script:gateRuns)
    $crAll = @($(if ($cr) { $cr.conflict_files_all } else { @() }))
    T ($kCT + '  the same row carries the whole-range list from merge-tree, labelled approximate') `
      ($null -ne $cr -and ($crAll -ccontains 'clash2.txt') -and [string]$cr.conflict_all_basis -ceq 'merge-tree-approximate') ("all={0} basis={1}" -f ($crAll -join ','), $(if ($cr) { $cr.conflict_all_basis }))
    $crSib = @($(if ($cr) { $cr.sibling_same_subject } else { @() }))
    T ($kMF + '  a main commit whose subject is the branch''s own is named in sibling_same_subject by its short sha') `
      ($crSib.Count -eq 1 -and $n2Sha.StartsWith([string]$crSib[0]) -and ([string]$crSib[0]).Length -ge 7) ("siblings={0} n2={1}" -f ($crSib -join ','), $n2Sha)

    # ---- THE REFUSAL CLASS, from a real pre-push hook that prints a frozen text and refuses (W0.1 step 2) ----
    # A stub hook in the clone's own .git\hooks prints the hook's wording and exits 1, so git rejects the push and
    # Invoke-TcPushMain classifies git's real output. Each text is the shape ops\hooks\pre-push prints for that refusal.
    $hk = New-Clone 'hk'
    [IO.File]::WriteAllText((Join-Path $hk 'hk.txt'), 'hk')
    $null = & git -C $hk add -- hk.txt 2>$null; $null = & git -C $hk commit -q -m hk 2>$null
    $plainGate = { param($d) [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $script:hookRun = 0
    function Invoke-StubHookPush([string]$HookText) {
      $script:hookRun++
      $hp = Join-Path $hk '.git\hooks\pre-push'
      $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Split-Path -Parent $hp)
      [IO.File]::WriteAllText($hp, ("#!/bin/sh`ncat >&2 <<'TCSTUBEOF'`n" + $HookText + "`nTCSTUBEOF`nexit 1`n"), (New-Object Text.UTF8Encoding($false)))
      $root = Join-Path $tmp ('ledhk' + $script:hookRun)
      $rc = Invoke-TcPushMain -Dir $hk -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $plainGate -LedgerRoot $root
      $rowsRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $root)
      $rows = @($rowsRaw)
      return [pscustomobject]@{ Rc = $rc; Rows = $rows.Count; Row = $(if ($rows.Count) { $rows[$rows.Count - 1] } else { $null }) }
    }
    $hkRh = Invoke-StubHookPush ("chain-rehearsal: REFUSED - 1 chain script(s) changed (fixture/chain.ps1) and no rehearsal verdict is recorded for this content (key 0123456789ab).`n`n" + `
      "pre-push: BLOCKED - this push changes the daily chain and carries no passing rehearsal over recent data (exit 1).`n          Rehearse:  powershell -File the rehearsal script")
    $hkRhLines = @($(if ($hkRh.Row) { $hkRh.Row.reject_lines } else { @() }))
    T ($kMF + '  an in-lock rehearsal refusal in the hook''s wording records reject_class rehearsal and keeps its BLOCKED line') `
      ($hkRh.Rc -eq 1 -and $hkRh.Rows -eq 1 -and [string]$hkRh.Row.outcome -ceq 'push-rejected' -and [string]$hkRh.Row.reject_class -ceq 'rehearsal' -and `
        @($hkRhLines | Where-Object { ([string]$_).StartsWith('pre-push: BLOCKED - this push changes the daily chain') }).Count -eq 1) `
      ("rc={0} rows={1} class={2} lines={3}" -f $hkRh.Rc, $hkRh.Rows, $(if ($hkRh.Row) { $hkRh.Row.reject_class }), ($hkRhLines -join ' | '))
    $ccGate = 'ops\audit-' + 'conclusion-currency.ps1'
    $hkRg = Invoke-StubHookPush ("pre-push: running the gate (about 51s) - once for this push, not once per commit.`n`n" + `
      "pre-push: BLOCKED - run-gates exited 1. This tree must not be pushed until it passes.`n          Fix the cause, never the gate.`n" + `
      "  FAIL  " + $ccGate + "  (exit 2) - conclusion currency`n          full gate output kept at: /tmp/tc-prepush-1.log")
    T ($kMF + '  an in-lock run-gates red whose FAIL line names the conclusion-currency audit records run-gates:<that gate>') `
      ($hkRg.Rc -eq 1 -and [string]$hkRg.Row.reject_class -ceq ('run-gates:' + $ccGate)) ("rc={0} class={1}" -f $hkRg.Rc, $(if ($hkRg.Row) { $hkRg.Row.reject_class }))
    $hkPp = Invoke-StubHookPush ("pre-push: BLOCKED - the test-auditors check exited 1. This push leaves a watcher that cannot see its own bug.`nPRE-PUSH-REFUSED cause=rehearsal")
    $hkPpLines = @($(if ($hkPp.Row) { $hkPp.Row.reject_lines } else { @() }))
    T ($kMF + '  a PRE-PUSH-REFUSED cause=rehearsal line wins over the older test-auditors wording printed ABOVE it in the same text') `
      ($hkPp.Rc -eq 1 -and [string]$hkPp.Row.reject_class -ceq 'rehearsal' -and $hkPpLines.Count -eq 1 -and [string]$hkPpLines[0] -ceq 'PRE-PUSH-REFUSED cause=rehearsal') `
      ("class={0} lines={1}" -f $(if ($hkPp.Row) { $hkPp.Row.reject_class }), ($hkPpLines -join ' | '))
    $hkUn = Invoke-StubHookPush (('z' * 400) + "`na second line no rule was written for")
    $hkUnLines = @($(if ($hkUn.Row) { $hkUn.Row.reject_lines } else { @() }))
    $hkUnLens = @($hkUnLines | ForEach-Object { ([string]$_).Length })
    T ($kMNF + '  a hook text no rule knows records unknown with its first lines, each at most 300 characters, and the push path does not throw') `
      ($hkUn.Rc -eq 1 -and [string]$hkUn.Row.reject_class -ceq 'unknown' -and $hkUnLines.Count -ge 2 -and $hkUnLines.Count -le 3 -and $hkUnLens[0] -eq 300 -and ($hkUnLens | Measure-Object -Maximum).Maximum -le 300) `
      ("rc={0} class={1} count={2} lengths={3}" -f $hkUn.Rc, $(if ($hkUn.Row) { $hkUn.Row.reject_class }), $hkUnLines.Count, ($hkUnLens -join ','))
    $hkHead = ([string](@(& git -C $hk rev-parse HEAD 2>$null))[0]).Trim()
    $hkRemote = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    # A REJECTED PUSH IS AN IN-LOCK REFUSAL (W0.1R step 4), whichever check in the hook refused it.
    $hkPhases = @(@($hkRh, $hkRg, $hkPp, $hkUn) | ForEach-Object { if ($_.Row) { [string]$_.Row.phase } else { '<no row>' } }) -join ','
    T ($kCT + '  every one of those refusals was a real rejected push: the remote never took the stub clone''s commit, a row was written each time, and each row says phase inlock') `
      ($script:hookRun -eq 4 -and $hkHead -ne $hkRemote -and $hkRh.Rows -eq 1 -and $hkRg.Rows -eq 1 -and $hkPp.Rows -eq 1 -and $hkUn.Rows -eq 1 -and $hkPhases -ceq 'inlock,inlock,inlock,inlock') `
      ("runs={0} head={1} remote={2} phases={3}" -f $script:hookRun, $hkHead, $hkRemote, $hkPhases)
    # MUST FIRE (review of W0.1R): a could-not-evaluate refusal under the fixed line is NOT a red on the row. The hook ran
    # test-auditors IN FULL inside the lock, which hook_ta_scope keeps, and the check could not evaluate (exit 3).
    $hkC3 = Invoke-StubHookPush ("prepush-test-auditors: running grocery\test-auditors.ps1 in full (measured 500s on 2026-09-10, bound 900s)`n" + `
      "pre-push: BLOCKED - the test-auditors check COULD NOT EVALUATE (exit 3). That is not a pass.`nPRE-PUSH-REFUSED cause=test-auditors")
    T ($kMF + '  a real rejected push whose hook could not evaluate records reject_rc 3 beside class test-auditors, hook_ta ran and hook_ta_scope full; the reds above record reject_rc 1, and an unknown text none') `
      ($hkC3.Rc -eq 1 -and $hkC3.Rows -eq 1 -and [string]$hkC3.Row.reject_class -ceq 'test-auditors' -and $hkC3.Row.reject_rc -eq 3 -and [string]$hkC3.Row.hook_ta -ceq 'ran' -and [string]$hkC3.Row.hook_ta_scope -ceq 'full' -and `
        $hkRg.Row.reject_rc -eq 1 -and $hkRh.Row.reject_rc -eq 1 -and $null -eq $hkUn.Row.reject_rc) `
      ("c3={0}/{1}/{2}/{3} rg={4} rh={5} unknown={6}" -f $(if ($hkC3.Row) { $hkC3.Row.reject_class }), $(if ($hkC3.Row) { $hkC3.Row.reject_rc }), $(if ($hkC3.Row) { $hkC3.Row.hook_ta }), $(if ($hkC3.Row) { $hkC3.Row.hook_ta_scope }), $hkRg.Row.reject_rc, $hkRh.Row.reject_rc, $hkUn.Row.reject_rc)

    # ---- THE CLEAN TWIN: a clean rebase through the DEFAULT legs, each a stub in the clone's own ops\ (W0.1) ----
    # No -GateRunner and no -RehearsalRunner: Invoke-TcDefaultLegs runs the stub run-gates and then the stub test-auditors
    # check, and Start-TcRehearsalChild runs the stub rehearsal as a child, so every reading below travels the production road.
    # ops\ is excluded in the clone, as the seeded paths are gitignored in the real repo, so the tree stays clean.
    # THE CLONES ARE dl1 AND dl2 (default legs), never q1 and q2: the rehearsal cases above already made clones by those
    # names under this run's root, and a second `git clone` into one fails and is counted as a clone that came up empty.
    # THE REHEARSAL STUB ANSWERS -CheckPush TOO (W0.1R step 8), and ends with its completion marker either way: if a rebase
    # ever happened inside the lock here, Invoke-TcRehearsalCheck would run this stub, and a stub that could not bind
    # -CheckPush -RefsFile would print no marker, read as could-not-decide, and hand the lock back for the wrong reason.
    $dl1 = New-Clone 'dl1'
    Add-Content -LiteralPath (Join-Path $dl1 '.git\info\exclude') -Value @('ops/') -Encoding ascii
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $dl1 'ops')
    [IO.File]::WriteAllText((Join-Path $dl1 'ops\run-gates.ps1'), ("Write-Output '" + $rgLine + "'`nWrite-Output 'RUN-GATES-COMPLETE pass=7 fail=0'`nexit 0`n"))
    [IO.File]::WriteAllText((Join-Path $dl1 'ops\prepush-test-auditors.ps1'), ("param([switch]`$RefsFromStdin)`n`$null = [Console]::In.ReadToEnd()`nWrite-Output '" + $tmLine + "'`nWrite-Output 'prepush-test-auditors: running the fixture suite in full'`nWrite-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n"))
    [IO.File]::WriteAllText((Join-Path $dl1 'ops\rehearse-chain.ps1'), ("param([switch]`$ForPush, [switch]`$CheckPush, [string]`$Remote, [string]`$Branch, [string]`$RefsFile)`nWrite-Output 'chain-rehearsal: no chain-manifest script changed in this push; no rehearsal needed'`nWrite-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=not-needed'`nexit 0`n"))
    [IO.File]::WriteAllText((Join-Path $dl1 'dl1.txt'), 'dl1')
    $null = & git -C $dl1 add -- dl1.txt 2>$null; $null = & git -C $dl1 commit -q -m dl1 2>$null
    $dl1Base = ([string](@(& git -C $dl1 rev-parse refs/remotes/origin/main 2>$null))[0]).Trim()
    $dl2 = New-Clone 'dl2'
    [IO.File]::WriteAllText((Join-Path $dl2 'dl2.txt'), 'dl2')
    $null = & git -C $dl2 add -- dl2.txt 2>$null; $null = & git -C $dl2 commit -q -m dl2 2>$null
    $null = & git -C $dl2 push -q origin HEAD:main 2>$null      # main moves, so dl1 is rebased by the round-1 fetch
    $dl2Tip = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    $ledDl = Join-Path $tmp 'leddl'
    $rDl = Invoke-TcPushMain -Dir $dl1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -LedgerRoot $ledDl
    $dlRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledDl)
    $dlRows = @($dlRaw)
    $dlRow = $(if ($dlRows.Count) { $dlRows[$dlRows.Count - 1] } else { $null })
    $blobWant = ([string](@(& git -C (Split-Path -Parent $script:TcPushMainPath) hash-object $script:TcPushMainPath 2>$null))[0]).Trim()
    T ($kCT + '  a clean rebase writes landed-after-rebase with no conflict_files, a numeric lock_held_ms, schema 2 and a 40-hex pm_blob equal to git hash-object of the script under test') `
      ($rDl -eq 0 -and $dlRows.Count -eq 1 -and [string]$dlRow.outcome -ceq 'landed-after-rebase' -and $null -eq $dlRow.conflict_files -and $null -eq $dlRow.phase -and `
        ($dlRow.lock_held_ms -is [int] -or $dlRow.lock_held_ms -is [long]) -and [int]$dlRow.schema -eq 2 -and [string]$dlRow.pm_blob -match '^[0-9a-f]{40}$' -and [string]$dlRow.pm_blob -ceq $blobWant -and `
        (@($dlRow.rebase_phases) -join ',') -ceq 'preflight') `
      ("rc={0} rows={1} outcome={2} conflict={3} held={4} schema={5} blob={6} want={7} phases={8}" -f $rDl, $dlRows.Count, $(if ($dlRow) { $dlRow.outcome }), $(if ($dlRow) { $dlRow.conflict_files }), $(if ($dlRow) { $dlRow.lock_held_ms }), $(if ($dlRow) { $dlRow.schema }), $(if ($dlRow) { $dlRow.pm_blob }), $blobWant, $(if ($dlRow) { @($dlRow.rebase_phases) -join ',' }))
    T ($kCT + '  the same row carries every leg: integer seconds for rg, ta and rh, run-gates'' 3 of 7 with 2 unkeyable, ta_rc 0, the TA-KEY-MOVED line, and chain_touching false from outcome not-needed') `
      ($null -ne $dlRow -and $dlRow.leg_sec.rg -is [int] -and $dlRow.leg_sec.ta -is [int] -and $dlRow.leg_sec.rh -is [int] -and $dlRow.rg_reused -eq 3 -and $dlRow.rg_selftests -eq 7 -and $dlRow.rg_unkeyable -eq 2 -and `
        $dlRow.ta_rc -eq 0 -and [string]$dlRow.ta_moved -ceq $tmLine -and $dlRow.chain_touching -eq $false -and [string]$dlRow.rh_outcome -ceq 'not-needed') `
      ("legs={0} reuse={1}/{2}/{3} ta_rc={4} moved={5} chain={6} rh={7}" -f $(if ($dlRow) { ConvertTo-Json $dlRow.leg_sec -Compress }), $(if ($dlRow) { $dlRow.rg_reused }), $(if ($dlRow) { $dlRow.rg_selftests }), $(if ($dlRow) { $dlRow.rg_unkeyable }), $(if ($dlRow) { $dlRow.ta_rc }), $(if ($dlRow) { $dlRow.ta_moved }), $(if ($dlRow) { $dlRow.chain_touching }), $(if ($dlRow) { $dlRow.rh_outcome }))
    # THE CHANGE ID NAMES THE CHANGE, NOT THE COMMIT: dl1's commit was rewritten by the rebase, and its diff over its new
    # parent must still give the id the row took before any fetch. A commit sha in its place would be 40-hex too, and
    # would fail here. A different change (the stub-hook clone's) must give a different id.
    $dlAfterId = Get-TcChangeId -Dir $dl1 -Base ([string](@(& git -C $dl1 rev-parse HEAD~1 2>$null))[0]).Trim()
    $hkId = Get-TcChangeId -Dir $hk -Base ([string](@(& git -C $hk rev-parse HEAD~1 2>$null))[0]).Trim()
    T ($kCT + '  the change_id taken before the rebase equals the rebased commit''s own, and a different change has a different one') `
      ($null -ne $dlRow -and [string]$dlRow.change_id -match '^[0-9a-f]{40}$' -and [string]::Equals([string]$dlRow.change_id, $dlAfterId, [StringComparison]::Ordinal) -and $hkId -match '^[0-9a-f]{40}$' -and $hkId -ne $dlAfterId) `
      ("row={0} afterRebase={1} other={2}" -f $(if ($dlRow) { $dlRow.change_id }), $dlAfterId, $hkId)
    $dlSib = @($(if ($dlRow) { $dlRow.sibling_same_subject } else { @('<no row>') }))
    T ($kCT + '  it also names where the branch left main (branch_base, with its date), a 40-hex change_id, and no sibling when no subject repeats') `
      ($null -ne $dlRow -and [string]$dlRow.branch_base -ceq $dl1Base -and [string]$dlRow.branch_base_ts -match '^\d{4}-\d\d-\d\dT' -and [string]$dlRow.change_id -match '^[0-9a-f]{40}$' -and $dlSib.Count -eq 0 -and $null -ne $dlRow.sibling_same_subject) `
      ("base={0} want={1} ts={2} change={3} siblings={4}" -f $(if ($dlRow) { $dlRow.branch_base }), $dl1Base, $(if ($dlRow) { $dlRow.branch_base_ts }), $(if ($dlRow) { $dlRow.change_id }), ($dlSib -join ','))
    # W0.1R's CLEAN TWIN: a push that lands in ONE round. Its row counts one leg set, one take and one rehearsal leg that
    # needed no rehearsal, no catch-up time, a whole-ms wait, a check that never ran (no rebase happened in the lock), the
    # remote tip the round-1 fetch saw, and the subjects its commits carried at start, hashed here independently.
    $shaT = [Security.Cryptography.SHA256]::Create()
    try { $dlSubjWant = ([BitConverter]::ToString($shaT.ComputeHash([Text.Encoding]::UTF8.GetBytes('dl1'))) -replace '-', '').ToLowerInvariant() } finally { $shaT.Dispose() }
    T ($kCT + '  a one-round landing records rounds 1, lock_takes 1, inlock_check not-run, rehearsals 1 with rehearsed 0, catchup_sec 0, the round-1 FETCH_HEAD as preflight_sha, and the SHA-256 of its one subject') `
      ($null -ne $dlRow -and [int]$dlRow.rounds -eq 1 -and [int]$dlRow.lock_takes -eq 1 -and [string]$dlRow.inlock_check -ceq 'not-run' -and [int]$dlRow.rehearsals -eq 1 -and [int]$dlRow.rehearsed -eq 0 -and `
        [int]$dlRow.catchup_sec -eq 0 -and ($dlRow.lock_wait_ms_total -is [int] -or $dlRow.lock_wait_ms_total -is [long]) -and [string]$dlRow.preflight_sha -ceq $dl2Tip -and [string]$dlRow.subjects_sha -ceq $dlSubjWant) `
      ("rounds={0} takes={1} check={2} rehearsals={3} rehearsed={4} catchup={5} waitTotal={6} preflight={7} want={8} subjects={9} want={10}" -f $(if ($dlRow) { $dlRow.rounds }), $(if ($dlRow) { $dlRow.lock_takes }), $(if ($dlRow) { $dlRow.inlock_check }), $(if ($dlRow) { $dlRow.rehearsals }), $(if ($dlRow) { $dlRow.rehearsed }), $(if ($dlRow) { $dlRow.catchup_sec }), $(if ($dlRow) { $dlRow.lock_wait_ms_total }), $(if ($dlRow) { $dlRow.preflight_sha }), $dl2Tip, $(if ($dlRow) { $dlRow.subjects_sha }), $dlSubjWant)

    # CLEAN TWIN (review of W0.1R): the same one-round row carries the per-subject hashes, the commit count and the branch
    # it pushed from, and none of the refusal-only fields.
    $dlShWant = $dlSubjWant.Substring(0, 16)
    $dlShs = @($(if ($dlRow) { $dlRow.subject_shas } else { @() }))
    T ($kCT + '  a one-round landing records subject_shas as the 16-hex prefix of its one subject''s hash, subject_count 1 and head_ref main, and no conflict_target, reject_rc or hook_ta_scope') `
      ($null -ne $dlRow -and $dlShs.Count -eq 1 -and [string]$dlShs[0] -ceq $dlShWant -and [int]$dlRow.subject_count -eq 1 -and [string]$dlRow.head_ref -ceq 'main' -and `
        $null -eq $dlRow.conflict_target -and $null -eq $dlRow.reject_rc -and $null -eq $dlRow.hook_ta_scope) `
      ("shas={0} want={1} count={2} head_ref={3} target={4} rc={5} scope={6}" -f ($dlShs -join ','), $dlShWant, $(if ($dlRow) { $dlRow.subject_count }), $(if ($dlRow) { $dlRow.head_ref }), $(if ($dlRow) { $dlRow.conflict_target }), $(if ($dlRow) { $dlRow.reject_rc }), $(if ($dlRow) { $dlRow.hook_ta_scope }))
    # W8.1 CLEAN TWIN: a clean tree lands, and its row carries no dirty field, nothing degraded and no guard holder.
    T ($kCT + '  a clean tree lands through the default legs, and the row has no dirty_paths, no dirty_since, nothing degraded and no guard_holder') `
      ($rDl -eq 0 -and $null -ne $dlRow -and $null -eq $dlRow.dirty_paths -and $null -eq $dlRow.dirty_since -and $null -eq $dlRow.degraded -and $null -eq $dlRow.guard_holder -and $dlRow.reexec -eq $false) `
      ("rc={0} paths={1} since={2} degraded={3} holder={4} reexec={5}" -f $rDl, $(if ($dlRow) { $dlRow.dirty_paths }), $(if ($dlRow) { $dlRow.dirty_since }), $(if ($dlRow) { $dlRow.degraded }), $(if ($dlRow) { $dlRow.guard_holder }), $(if ($dlRow) { $dlRow.reexec }))
    # ---- AN OLD-SHAPE ROW STILL PARSES IN THE CONVERGENCE PROBE (W0.1) ----
    # The probe itself is run, as a child, over a ledger holding the schema-2 row above and a row written before it. An
    # empty reflog file and an empty log directory keep it off this box's real history.
    # A FROZEN LITERAL, shas and all: this row first took them from $A and $B while a clone named $a still shadowed $A
    # (see the clone cases above), and the path's backslashes made it malformed JSON.
    $oldRow = '{"ts":"2026-09-22T10:00:00Z","pid":1,"run":"run-old-fixture","event":"push-main","waitMs":3,"state":"held","base":"1111111111111111111111111111111111111111","grant":"2222222222222222222222222222222222222222","outcome":"landed-after-rebase","checkout":"old"}'
    $null = Add-TcLine -Path (Get-TcPushLedgerPath -Root $ledDl) -Text $oldRow
    $emptyReflog = Join-Path $tmp 'empty-reflog.txt'
    [IO.File]::WriteAllText($emptyReflog, '')
    $emptyLogs = Join-Path $tmp 'empty-logs'
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop $emptyLogs
    $probeOut = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'ops\probe-push-convergence.ps1') -LedgerRoot $ledDl -ReflogFile $emptyReflog -LogDir $emptyLogs)
    $probeRc = $LASTEXITCODE
    $probeRows = @($probeOut | Where-Object { [string]$_ -match 'rows=2 \(malformed=0\)' })
    T ($kMNF + '  a row in the old shape and a schema-2 row read side by side in ops\probe-push-convergence.ps1: exit 0, two rows, none malformed') `
      ($probeRc -eq 0 -and $probeRows.Count -eq 1) ("rc={0} line={1}" -f $probeRc, (@($probeOut | Where-Object { [string]$_ -match 'rows=' }) -join ' | '))

    T ($kMNF + '  every clone these cases ran against carried the seeded history, so none of them judged an empty repository') `
      ($script:cloneFails -eq 0) ("clonesThatCameUpEmpty={0}" -f $script:cloneFails)
    $freeNow = Enter-TcPushLock -Prefix $prefix -QueueRoot $qroot -WaitSec 5 -PollMs 50 -NoInherit
    T ($kCT + '  every one of those runs handed the push lock back, including the refusals') ($freeNow.Held) ("held={0}" -f $freeNow.Held)
    Exit-TcPushLock $freeNow

    # ---- THE MAIN CHECKOUT LANDS THROUGH A THROWAWAY WORKTREE (W8.2) ----
    # A clone IS a main checkout (its git dir is the common dir), so each case makes one dirty in the three ways the real
    # main checkout is: a modified tracked file, an untracked file, and another session's STAGED entry. The landing runs
    # in a detached worktree under $tmp\via, and every case also asserts that no throwaway is left, on every outcome.
    $vwRoot = Join-Path $tmp 'via'
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop $vwRoot
    $vwLeft = { param($d) @(@(Get-ChildItem -LiteralPath $vwRoot -Force -ErrorAction SilentlyContinue).Count, @(@(& git -C $d worktree list --porcelain 2>$null) | Where-Object { "$_" -like 'worktree *' }).Count) -join '|' }
    $vwMd5 = { param($p) if (Test-Path -LiteralPath $p) { (Get-FileHash -Algorithm MD5 -LiteralPath $p).Hash } else { '<absent>' } }
    $vwArgs = [ordered]@{ LockPrefix = $prefix; LockQueueRoot = $qroot; GateRunner = $greenGate; RehearsalRunner = $rhGreen; NoReexec = $true }
    $null = & git -C $mover pull -q --rebase origin main 2>$null
    foreach ($vf in @('vw-tracked.txt', 'vw-landed.txt')) { [IO.File]::WriteAllText((Join-Path $mover $vf), ('base ' + $vf)) }
    $null = & git -C $mover add -- vw-tracked.txt vw-landed.txt 2>$null; $null = & git -C $mover commit -q -m 'vw base' 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    $vwDirty = { param($d)
      [IO.File]::WriteAllText((Join-Path $d 'vw-tracked.txt'), 'a local edit nobody committed')
      [IO.File]::WriteAllText((Join-Path $d 'vw-untracked.txt'), 'an untracked file')
      [IO.File]::WriteAllText((Join-Path $d 'vw-staged.txt'), 'another session staged this')
      $null = & git -C $d add -- vw-staged.txt 2>$null
    }
    $vwState = { param($d) ((@(& git -C $d status --porcelain=v1 -uall 2>$null) + @('--') + @(& git -C $d ls-files -s 2>$null)) -join "`n") }

    # MUST FIRE, the founding shape: a DIRTY main checkout with a commit ahead lands through the throwaway. Its dirty and
    # untracked files are byte-identical afterwards, the staged entry keeps its content (unstaged, git's --keep table),
    # and local main is the landed tip, so the bot's replay has nothing left to carry.
    $vm1 = & $newPusher 'vwmain1'
    & $vwDirty $vm1
    $vm1Before = @((& $vwMd5 (Join-Path $vm1 'vw-tracked.txt')), (& $vwMd5 (Join-Path $vm1 'vw-untracked.txt')), (& $vwMd5 (Join-Path $vm1 'vw-staged.txt'))) -join '|'
    $ledV1 = Join-Path $tmp 'ledvw1'
    $rV1 = Invoke-TcPushMainViaWorktree -MainDir $vm1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -WorktreeRoot $vwRoot -PushArgs $vwArgs -LedgerRoot $ledV1
    $vm1After = @((& $vwMd5 (Join-Path $vm1 'vw-tracked.txt')), (& $vwMd5 (Join-Path $vm1 'vw-untracked.txt')), (& $vwMd5 (Join-Path $vm1 'vw-staged.txt'))) -join '|'
    $vm1Head = ([string](@(& git -C $vm1 rev-parse HEAD 2>$null))[0]).Trim()
    $vm1Cached = @(& git -C $vm1 diff --cached --name-only 2>$null)
    $vm1RowsRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledV1)
    $vm1Rows = @($vm1RowsRaw)
    $vm1Row = $(if ($vm1Rows.Count) { $vm1Rows[-1] } else { $null })
    $vm1Left = & $vwLeft $vm1
    T ($kMF + '  a dirty main checkout lands through a throwaway worktree: dirty and untracked files byte-identical, the staged entry kept unstaged, local main at the landed tip, row via_worktree and main_sync reset-keep, no throwaway left') `
      ($rV1 -eq 0 -and $vm1After -ceq $vm1Before -and $vm1Head -ceq (& $tipOf) -and @(& git -C $origin ls-tree --name-only main 2>$null) -contains 'vwmain1.txt' -and $vm1Cached.Count -eq 0 -and $vm1Rows.Count -eq 1 -and $vm1Row.via_worktree -eq $true -and [string]$vm1Row.main_sync -ceq 'reset-keep' -and $vm1Left -ceq '0|1') `
      ("rc={0} md5same={1} head={2} tip={3} cached={4} rows={5} via={6} sync={7} left={8}" -f $rV1, ($vm1After -ceq $vm1Before), $vm1Head, (& $tipOf), ($vm1Cached -join ','), $vm1Rows.Count, $(if ($vm1Row) { $vm1Row.via_worktree }), $(if ($vm1Row) { $vm1Row.main_sync }), $vm1Left)

    # MUST FIRE: a remote that MOVES while the legs run is rebased over IN THE THROWAWAY, never in the main checkout. The
    # main checkout's reflog holds no rebase at all, and it still ends at the landed tip, which carries both commits.
    $vm2 = & $newPusher 'vwmain2'
    & $vwDirty $vm2
    $script:vwMoved = $false
    $vwMoveGate = { param($d) if (-not $script:vwMoved) { $script:vwMoved = $true; & $moveOrigin 'vw-moved.txt' }; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $vwArgs2 = [ordered]@{ LockPrefix = $prefix; LockQueueRoot = $qroot; GateRunner = $vwMoveGate; RehearsalRunner = $rhGreen; NoReexec = $true }
    $ledV2 = Join-Path $tmp 'ledvw2'
    $rV2 = Invoke-TcPushMainViaWorktree -MainDir $vm2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -WorktreeRoot $vwRoot -PushArgs $vwArgs2 -LedgerRoot $ledV2
    $vm2Head = ([string](@(& git -C $vm2 rev-parse HEAD 2>$null))[0]).Trim()
    $vm2Reflog = @(& git -C $vm2 reflog --format=%gs 2>$null)
    $vm2Rebases = @($vm2Reflog | Where-Object { "$_" -like 'rebase*' })
    $vm2Tree = @(& git -C $origin ls-tree --name-only main 2>$null)
    $vm2Left = & $vwLeft $vm2
    T ($kMF + '  a remote that moves during the legs is rebased in the throwaway and never in the main checkout (its reflog holds no rebase), and the main checkout still ends at the landed tip carrying both') `
      ($rV2 -eq 0 -and $script:vwMoved -and $vm2Rebases.Count -eq 0 -and $vm2Head -ceq (& $tipOf) -and $vm2Tree -contains 'vwmain2.txt' -and $vm2Tree -contains 'vw-moved.txt' -and $vm2Left -ceq '0|1') `
      ("rc={0} moved={1} rebasesInMain={2} head={3} tip={4} left={5}" -f $rV2, $script:vwMoved, $vm2Rebases.Count, $vm2Head, (& $tipOf), $vm2Left)

    # MUST FIRE, the manual road: the main checkout's HEAD MOVES while the run is in flight (a session commits there).
    # It lands, the main checkout is left exactly as that session left it, and the row says main_sync manual.
    $vm3 = & $newPusher 'vwmain3'
    $script:vwCommitted = $false
    $vwCommitGate = { param($d)
      if (-not $script:vwCommitted) {
        $script:vwCommitted = $true
        [IO.File]::WriteAllText((Join-Path $vm3 'vw-later.txt'), 'committed while the run was in flight')
        $null = & git -C $vm3 add -- vw-later.txt 2>$null; $null = & git -C $vm3 commit -q -m 'vw later' 2>$null
      }
      [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $vwArgs3 = [ordered]@{ LockPrefix = $prefix; LockQueueRoot = $qroot; GateRunner = $vwCommitGate; RehearsalRunner = $rhGreen; NoReexec = $true }
    $ledV3 = Join-Path $tmp 'ledvw3'
    $rV3 = Invoke-TcPushMainViaWorktree -MainDir $vm3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -WorktreeRoot $vwRoot -PushArgs $vwArgs3 -LedgerRoot $ledV3
    $vm3Head = ([string](@(& git -C $vm3 rev-parse HEAD 2>$null))[0]).Trim()
    $vm3Subj = ([string](@(& git -C $vm3 log -1 --format=%s 2>$null))[0]).Trim()
    $vm3RowsRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledV3)
    $vm3Rows = @($vm3RowsRaw)
    $vm3Row = $(if ($vm3Rows.Count) { $vm3Rows[-1] } else { $null })
    $vm3Left = & $vwLeft $vm3
    T ($kMF + '  a main checkout whose HEAD moved while the run was in flight is left exactly as it is: the push lands, main_sync is manual, no throwaway left') `
      ($rV3 -eq 0 -and $vm3Subj -ceq 'vw later' -and $vm3Head -cne (& $tipOf) -and @(& git -C $origin ls-tree --name-only main 2>$null) -contains 'vwmain3.txt' -and $vm3Row -and [string]$vm3Row.main_sync -ceq 'manual' -and $vm3Left -ceq '0|1') `
      ("rc={0} subj={1} sync={2} left={3}" -f $rV3, $vm3Subj, $(if ($vm3Row) { $vm3Row.main_sync }), $vm3Left)

    # MUST FIRE, --keep refuses: a local edit to a file the LANDING changes (origin moves vw-landed.txt during the legs,
    # and the main checkout has an uncommitted edit to it). It lands, the edit is byte-identical, main_sync is manual.
    $vm4 = & $newPusher 'vwmain4'
    [IO.File]::WriteAllText((Join-Path $vm4 'vw-landed.txt'), 'a local edit to a file the landing will change')
    $vm4Md5 = & $vwMd5 (Join-Path $vm4 'vw-landed.txt')
    $vm4Start = ([string](@(& git -C $vm4 rev-parse HEAD 2>$null))[0]).Trim()
    $script:vwMoved = $false
    $vwMoveLanded = { param($d) if (-not $script:vwMoved) { $script:vwMoved = $true; & $moveOrigin 'vw-landed.txt' }; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $vwArgs4 = [ordered]@{ LockPrefix = $prefix; LockQueueRoot = $qroot; GateRunner = $vwMoveLanded; RehearsalRunner = $rhGreen; NoReexec = $true }
    $ledV4 = Join-Path $tmp 'ledvw4'
    $rV4 = Invoke-TcPushMainViaWorktree -MainDir $vm4 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -WorktreeRoot $vwRoot -PushArgs $vwArgs4 -LedgerRoot $ledV4
    $vm4RowsRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledV4)
    $vm4Rows = @($vm4RowsRaw)
    $vm4Row = $(if ($vm4Rows.Count) { $vm4Rows[-1] } else { $null })
    $vm4Head = ([string](@(& git -C $vm4 rev-parse HEAD 2>$null))[0]).Trim()
    $vm4Left = & $vwLeft $vm4
    T ($kMF + '  a local edit to a file the landing changes makes reset --keep refuse: the push lands, the edit and HEAD are untouched, main_sync is manual') `
      ($rV4 -eq 0 -and $script:vwMoved -and (& $vwMd5 (Join-Path $vm4 'vw-landed.txt')) -ceq $vm4Md5 -and $vm4Head -ceq $vm4Start -and $vm4Row -and [string]$vm4Row.main_sync -ceq 'manual' -and $vm4Left -ceq '0|1') `
      ("rc={0} moved={1} md5same={2} headSame={3} sync={4} left={5}" -f $rV4, $script:vwMoved, ((& $vwMd5 (Join-Path $vm4 'vw-landed.txt')) -ceq $vm4Md5), ($vm4Head -ceq $vm4Start), $(if ($vm4Row) { $vm4Row.main_sync }), $vm4Left)

    # MUST NOT FIRE: a REFUSED run (a red gate) leaves the main checkout's status and index byte-identical, origin where
    # it was, and no throwaway.
    $vm5 = & $newPusher 'vwmain5'
    & $vwDirty $vm5
    $vm5Before = & $vwState $vm5
    $vm5Tip = & $tipOf
    $vwArgs5 = [ordered]@{ LockPrefix = $prefix; LockQueueRoot = $qroot; GateRunner = { param($d) [pscustomobject]@{ Ran = $true; Code = 1; Why = 'fixture: red' } }; RehearsalRunner = $rhGreen; NoReexec = $true }
    $rV5 = Invoke-TcPushMainViaWorktree -MainDir $vm5 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -WorktreeRoot $vwRoot -PushArgs $vwArgs5 -LedgerRoot (Join-Path $tmp 'ledvw5')
    $vm5Left = & $vwLeft $vm5
    T ($kMNF + '  a refused run through the throwaway leaves the main checkout''s status and index byte-identical, origin unmoved, and no throwaway') `
      ($rV5 -eq 1 -and [string]::Equals((& $vwState $vm5), $vm5Before, [StringComparison]::Ordinal) -and (& $tipOf) -ceq $vm5Tip -and $vm5Left -ceq '0|1') `
      ("rc={0} stateSame={1} tipSame={2} left={3}" -f $rV5, [string]::Equals((& $vwState $vm5), $vm5Before, [StringComparison]::Ordinal), ((& $tipOf) -ceq $vm5Tip), $vm5Left)

    # MUST NOT FIRE: a main checkout with NOTHING ahead of origin is refused before any worktree is made, and says so.
    $vm6 = New-Clone 'vwmain6'
    $ledV6 = Join-Path $tmp 'ledvw6'
    $rV6 = Invoke-TcPushMainViaWorktree -MainDir $vm6 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -WorktreeRoot $vwRoot -PushArgs $vwArgs -LedgerRoot $ledV6
    $vm6RowsRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledV6)
    $vm6Rows = @($vm6RowsRaw)
    $vm6Left = & $vwLeft $vm6
    T ($kMNF + '  a main checkout with nothing ahead is refused (1) with no throwaway made, and its row says via_worktree refused-not-ready') `
      ($rV6 -eq 1 -and $vm6Left -ceq '0|1' -and $vm6Rows.Count -eq 1 -and $vm6Rows[0].via_worktree -eq $true -and [string]$vm6Rows[0].outcome -ceq 'refused-not-ready') `
      ("rc={0} left={1} rows={2}" -f $rV6, $vm6Left, $vm6Rows.Count)

    # CLEAN TWIN, the road is chosen by the checkout: a clone reads as a main checkout and a linked worktree of it does
    # not, so the entry point routes the first through the throwaway and runs the second in place, as before.
    $vm7Wt = Join-Path $tmp 'vwlinked'
    $null = & git -C $vm6 worktree add -q --detach $vm7Wt 2>$null
    T ($kCT + '  a clone reads as the main checkout (so it goes through the throwaway) and a linked worktree of it does not (so it lands in place)') `
      ((Test-TcMainCheckout -Dir $vm6) -and -not (Test-TcMainCheckout -Dir $vm7Wt)) ("main={0} linked={1}" -f (Test-TcMainCheckout -Dir $vm6), (Test-TcMainCheckout -Dir $vm7Wt))
    $null = & git -C $vm6 worktree remove --force $vm7Wt 2>$null

    # NOTHING THIS SUITE WROTE REACHED THE PRODUCTION LEDGER. Keyed on this RUN's id, not on the file's size (a real
    # push from another session may append while these cases run) and NOT on this process's pid: the production file
    # is one per day for the whole box, pids recycle within it, and a stranger's row carrying this pid refused two of
    # three unrelated pushes on 2026-09-12 (backlog I171). lib\push-ledger.ps1's suite holds the collision fixture.
    $prodRaw = Read-TcPushRows -Path $prodLedger
    $prodMineRaw = Select-TcPushRowsOfRun -Rows $prodRaw -Run $suiteRun
    $prodMine = @($prodMineRaw)
    T ($kMF + '  no row this suite wrote reached the production ledger, so the convergence report is never computed over temp clones') `
      ($prodMine.Count -eq 0) ("run={0} rowsFromThisRunInProduction={1}" -f $suiteRun, $prodMine.Count)
    # THE CHECK ABOVE CAN SEE: the cases that pass no -LedgerRoot wrote into the suite's redirect, and those rows are
    # found by the same run id. Without this, an id the rows never carried would make the zero above agree forever.
    $suiteRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root (Join-Path $tmp 'suite-ledger'))
    $suiteMineRaw = Select-TcPushRowsOfRun -Rows $suiteRaw -Run $suiteRun
    $suiteMine = @($suiteMineRaw)
    T ($kCT + '  the rows these cases wrote to the suite''s redirect are found by the run id the production check filters on') `
      ($suiteMine.Count -ge 1 -and $suiteMine.Count -eq @($suiteRaw).Count) ("rowsInRedirect={0} rowsOfThisRun={1}" -f @($suiteRaw).Count, $suiteMine.Count)
