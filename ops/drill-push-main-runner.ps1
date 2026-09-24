<#
  drill-push-main-runner.ps1 - drive ops\drill-chain-queue.ps1's three-push drill through the REAL ops\push-main.ps1.

  Run:  powershell -NoProfile -File ops\drill-chain-queue.ps1 -Drill -Rounds 3 -Runner ops\drill-push-main-runner.ps1
        powershell -NoProfile -File ops\drill-chain-queue.ps1 -SelfTest -Runner ops\drill-push-main-runner.ps1
  Spec: design\PLAN-push-derived-conflicts-2026-09-23.md 16.3 W9.2 step 12 (READY, proved before landing), and the
        queue lane's contract design\backlog-inbox\pd-queue-interface-2026-09-23.md ("-Runner <script> swaps the
        reference runner for a real one ... so the push-main lane can drive this drill through push-main itself").

  WHAT IT IS. The drill starts `<runner> -RunnerConfig <json>` once per push and reads back the reference runner's row
  file, rehearsal records and checkpoints. This script is that runner, and all it adds is the sandbox's STUBS: it
  dot-sources ops\push-main.ps1 (which returns before its main body when dot-sourced) and calls Invoke-TcPushMain itself,
  with the drill's private push lock, queue prefix and root, a private per-checkout guard, and these seams:
    - legs (-GateRunner): wait on the config's legsAfter, write <name>.legs, wait on swapAfter and holdBeforeSwap, and
      answer the config's legsRc;
    - the rehearsal (-RehearsalStarter): the drill's own stub, the same steps as its Invoke-DRehearsal (a --shared clone of
      the sandbox box, the stack's base checked out, the stacked commits and then the member's own cherry-picked, the tree
      of chain\ at the tip recorded as the verdict key, one <name>.rh.<n>.json per rehearsal), with the one thing a
      real -ForPush does that the reference runner never needs: a push at the head, no longer stacked, whose own HEAD's
      key already has a verdict REUSES it, records nothing and counts no rehearsal;
    - chain-touching (-ChainTouchingProbe): the push changes a file under chain\, as the reference runner reads it;
    - the in-lock check (-RehearsalCheck): a verdict exists for HEAD's chain\ tree.
  Everything else - the guard, the fetch and rebase, the join, the stack, the wait for the head, the restack, the
  catch-up, the hand-back, the lock, the push, the exit from the queue - is push-main's own code, which is the point.
  The row the drill reads is built from push-main's own ledger row and from what push-main SAID (the conflict it named,
  the head and restack lines), so a field the adapter could not read stays empty rather than guessed.

  SCOPE OF A CLEAN REPORT: a drill pass through this runner proves that ops\push-main.ps1's W9.2 path, in a sandbox on
  this machine with every push in its own process, joins, stacks, waits, restacks, lands in ticket order and leaves the
  queue the way W9.2 says. It proves nothing about the real legs or the real rehearse-chain, whose own suites cover them.
#>
param([Parameter(Mandatory)][string]$RunnerConfig)
$ErrorActionPreference = 'Stop'
$drRepo = Split-Path -Parent $PSScriptRoot
$drCfg = [IO.File]::ReadAllText($RunnerConfig) | ConvertFrom-Json
. (Join-Path $drRepo 'ops\push-main.ps1')   # library mode: it defines its functions and returns before its main body
$env:TC_CHAIN_QUEUE_SELFTEST = '1'
foreach ($v in @('TC_CHAIN_QUEUE_HOLDER', 'TC_PUSH_LOCK_HOLDER', 'TC_PUSH_MAIN_REEXEC')) { Remove-Item -LiteralPath ('Env:' + $v) -ErrorAction SilentlyContinue }
if ($drCfg.noRehearsal) { $env:TC_NO_REHEARSAL = 'drill: noRehearsal' }
$drWt = [string]$drCfg.wt; $drName = [string]$drCfg.name; $drLogs = [string]$drCfg.logs
$drCk = Join-Path $drLogs ($drName + '.ckpt.jsonl')
$script:drState = @{ RhN = 0; Ticket = ''; AheadNames = @(); AheadAtLock = @(); Stacked = $false }

function Invoke-DrGit([string]$Dir, [string[]]$GitArgs) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & git -C $Dir @GitArgs 2>&1; $rc = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
  return [pscustomobject]@{ Rc = $rc; Lines = @($out | ForEach-Object { [string]$_ }) }
}
function Get-DrSha([string]$Dir, [string]$Rev) { $r = Invoke-DrGit $Dir @('rev-parse', '--verify', '-q', $Rev); $s = @($r.Lines | Where-Object { $_ -match '^[0-9a-f]{40}$' }); if ($s.Count) { return $s[0] } else { return '' } }
function Get-DrSubjects([string]$Dir, [string]$Range) { $r = Invoke-DrGit $Dir @('log', '--reverse', '--format=%s', $Range); return , @($r.Lines | Where-Object { $_ -like 'drill *' -or $_ -eq 'seed' }) }
function Wait-DrFiles($Paths, [int]$Sec = 240) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  foreach ($p in @($Paths)) { if (-not $p) { continue }; while (-not [IO.File]::Exists([string]$p)) { if ($sw.Elapsed.TotalSeconds -gt $Sec) { throw ('a drill file never appeared: ' + $p) }; Start-Sleep -Milliseconds 20 } }
}
function Write-DrCkpt([string]$Step) {
  $subj = Get-DrSubjects $drWt 'HEAD'
  $line = ConvertTo-Json -Compress -InputObject ([ordered]@{ step = $Step; head = (Get-DrSha $drWt 'HEAD'); subjects = @($subj) })
  [IO.File]::AppendAllText($drCk, ($line + "`n"))
}
function Get-DrQueueDir { return (Get-TcGateQueueDir -Prefix ([string]$drCfg.prefix) -Root ([string]$drCfg.qroot)) }

# THE DRILL'S STUB REHEARSAL, as the drill's Invoke-DRehearsal does it, returned as a finished push-main rehearsal job.
$drStarter = {
  param($d, $stack, $stop)
  $tok = [string]$env:TC_CHAIN_QUEUE_HOLDER
  if ($tok -and -not $script:drState.Stacked) {
    $script:drState.Stacked = $true
    $script:drState.Ticket = ($tok -split '\|')[1]
    # THE TICKETS AHEAD AT JOIN, for ahead_at_lock: every record older than this ticket that has not landed or left.
    $qd = Get-DrQueueDir
    $names = @()
    foreach ($f in @([IO.Directory]::GetFiles($qd, '*.json'))) {
      $nm = [IO.Path]::GetFileNameWithoutExtension($f)
      if ([string]::CompareOrdinal($nm, $script:drState.Ticket) -ge 0) { continue }
      try { $rec = [IO.File]::ReadAllText($f) | ConvertFrom-Json; if ($rec.state -ne 'landed' -and $rec.state -ne 'left') { $names += $nm } } catch { }
    }
    $script:drState.AheadNames = @($names | Sort-Object)
    Write-DrCkpt 'stacked'
    [IO.File]::WriteAllText((Join-Path $drLogs ($drName + '.stacked')), 'stacked')
  }
  if ($drCfg.noRehearsal) { return (New-TcRehearsalJob -Done ([pscustomobject]@{ Code = 0; Why = 'drill: bypassed'; Ran = $true; Lines = [string[]]@('CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=bypassed'); Sec = 0; Stopped = $false })) }
  $origin = Get-DrSha $d ('refs/remotes/origin/main')
  # NEVER THROUGH $( ): a subexpression unrolls a one-line stack into a bare string, and $lines[0] is then its first character.
  if ($stack -and [IO.File]::Exists($stack)) { $lines = [string[]]@([IO.File]::ReadAllLines($stack) | Where-Object { $_ }) } else { $lines = [string[]]@($origin) }
  $own = @((Invoke-DrGit $d @('rev-list', '--reverse', ($lines[0] + '..HEAD'))).Lines | Where-Object { $_ -match '^[0-9a-f]{40}$' })
  if (-not $stack) {
    # AT THE HEAD, NOT STACKED: a real -ForPush finds a recorded verdict for HEAD's own key in seconds.
    $k0 = Get-DrSha $d 'HEAD:chain'
    if ($k0 -and [IO.File]::Exists((Join-Path ([string]$drCfg.verdicts) ($k0 + '.pass')))) {
      return (New-TcRehearsalJob -Done ([pscustomobject]@{ Code = 0; Why = 'drill: reused'; Ran = $true; Lines = [string[]]@('chain-rehearsal: PASSED - drill verdict reused', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass'); Sec = 0; Stopped = $false }))
    }
  }
  $script:drState.RhN++
  $n = $script:drState.RhN
  Write-DrCkpt ('rehearse-' + $n)
  $scratch = Join-Path ([string]$drCfg.root) ('rh\' + $drName + '-pm-' + $n)
  $id = @('-c', 'user.name=drill', '-c', 'user.email=drill@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false')
  $res = [pscustomobject]@{ Conflict = $false; Sha = ''; Files = @(); Key = ''; Subjects = @(); Applied = @() }
  try {
    $null = Invoke-DrGit ([string]$drCfg.root) @('clone', '-q', '--shared', '--no-checkout', [string]$drCfg.box, $scratch)
    $null = Invoke-DrGit $scratch ($id + @('checkout', '-q', '--detach', $lines[0]))
    $todo = @(); if ($lines.Count -gt 1) { $todo += $lines[1..($lines.Count - 1)] }; $todo += @($own)
    foreach ($s in $todo) {
      $cp = Invoke-DrGit $scratch ($id + @('cherry-pick', $s))
      if ($cp.Rc -ne 0) {
        $u = Invoke-DrGit $scratch @('diff', '--name-only', '--diff-filter=U')
        $res.Conflict = $true; $res.Sha = $s; $res.Files = @($u.Lines | Where-Object { $_ -and $_ -notmatch '^(warning|error|fatal):' })
        $null = Invoke-DrGit $scratch @('cherry-pick', '--abort')
        break
      }
      $res.Applied += $s
    }
    if (-not $res.Conflict) {
      $res.Key = Get-DrSha $scratch 'HEAD:chain'
      $res.Subjects = Get-DrSubjects $scratch ($lines[0] + '..HEAD')
      [IO.File]::WriteAllText((Join-Path ([string]$drCfg.verdicts) ($res.Key + '.pass')), $drName)
    }
  } finally {
    $rec = [ordered]@{ n = $n; base = $lines[0]; stack = @($lines); applied = @($res.Applied); subjects = @($res.Subjects); key = $res.Key; conflict = $res.Conflict; conflict_sha = $res.Sha; conflict_files = @($res.Files) }
    [IO.File]::WriteAllText((Join-Path $drLogs ('{0}.rh.{1}.json' -f $drName, $n)), (ConvertTo-Json -InputObject $rec -Depth 5 -Compress))
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($res.Conflict) {
    return (New-TcRehearsalJob -Done ([pscustomobject]@{ Code = 3; Why = 'drill: stack conflict'; Ran = $true; Lines = [string[]]@(('chain-rehearsal: STACK CONFLICT - applying ' + $res.Sha.Substring(0, 9) + ' onto the stack conflicts in: ' + (@($res.Files) -join ', ')), 'CHAIN-REHEARSAL-CHECK-COMPLETE code=3 outcome=could-not-rehearse blind=stack-conflict'); Sec = 1; Stopped = $false }))
  }
  return (New-TcRehearsalJob -Done ([pscustomobject]@{ Code = 0; Why = 'drill: rehearsed'; Ran = $true; Lines = [string[]]@('chain-rehearsal: this push changes the chain and has no usable rehearsal verdict - rehearsing HEAD now, OUTSIDE the push lock.', ('CHAIN-REHEARSAL-COMPLETE verdict=pass stage=- key=' + $res.Key.Substring(0, 12)), 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass'); Sec = 1; Stopped = $false; Rehearsed = $true }))
}
$drLegs = {
  param($d)
  Wait-DrFiles @($drCfg.legsAfter)
  Write-DrCkpt 'legs'
  [IO.File]::WriteAllText((Join-Path $drLogs ($drName + '.legs')), (Get-DrSha $d 'HEAD^{tree}'))
  if ([int]$drCfg.legsRc -ne 0) { return [pscustomobject]@{ Ran = $true; Code = 1; Why = 'drill: legs red' } }
  Wait-DrFiles @($drCfg.swapAfter)
  if ($drCfg.holdBeforeSwap) { Wait-DrFiles @([string]$drCfg.holdBeforeSwap) }
  return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' }
}
$drChain = { param($d, $h, $r) $t = Invoke-DrGit $d @('diff', '--name-only', ('origin/main...HEAD')); [pscustomobject]@{ Touching = (@($t.Lines | Where-Object { $_ -like 'chain/*' }).Count -gt 0); Outcome = 'drill'; Why = 'drill: chain\ files' } }
$drCheck = { param($d, $h, $r) $k = Get-DrSha $d 'HEAD:chain'; if ($k -and [IO.File]::Exists((Join-Path ([string]$drCfg.verdicts) ($k + '.pass')))) { [pscustomobject]@{ Code = 0; Why = 'covered' } } else { [pscustomobject]@{ Code = 1; Why = 'drill: no verdict' } } }

# THE ORDER READ, as the reference runner reads it: the states of the tickets ahead at the moment this push decides to
# swap, BEFORE its lock take (a wrapper on Enter-TcPushLock, put back in finally).
$script:drEnterReal = ${function:Enter-TcPushLock}
function script:Enter-TcPushLock {
  param([int]$WaitSec, [int]$PollMs, [string]$Prefix, [string]$QueueRoot, [scriptblock]$OnWait, [switch]$NoInherit)
  if (-not @($script:drState.AheadAtLock).Count -and @($script:drState.AheadNames).Count) {
    $qd = Get-DrQueueDir
    $script:drState.AheadAtLock = @($script:drState.AheadNames | ForEach-Object { $rp = Join-Path $qd ($_ + '.json'); $st = 'no-record'; try { $st = [string]([IO.File]::ReadAllText($rp) | ConvertFrom-Json).state } catch { }; ('{0}={1}' -f $_, $st) })
  }
  Write-DrCkpt 'lock'
  return (& $script:drEnterReal @PSBoundParameters)
}

$row = [ordered]@{ name = $drName; checkout = $drWt; pid = $PID; ticket = ''; result = ''; phase = ''; chain = $false; range_join = @(); rh_count = 0; inlock_check = 'not-run'; landed_sha = ''; ahead_at_lock = @(); conflict_with = ''; conflict_pid = 0; wait_outcomes = @(); queue_reason = '' }
$rc = 3
try {
  [IO.File]::WriteAllText((Join-Path $drLogs ($drName + '.up')), 'up')
  Write-DrCkpt 'start'
  Wait-DrFiles @([string]$drCfg.go)
  Wait-DrFiles @($drCfg.joinAfter)
  $script:TcPmChainQueuePrefix = [string]$drCfg.prefix
  $script:TcPmChainQueueRoot = [string]$drCfg.qroot
  $script:TcPmChainQueueStallSec = [int]$drCfg.stallSec
  $script:TcPmGuardPrefix = 'Local\tc-drill-guard-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '-'
  $script:TcPmGuardInfoRoot = Join-Path ([string]$drCfg.root) 'guard'
  $ledger = Join-Path ([string]$drCfg.root) ('pm-ledger-' + $drName)
  $capOld = [Console]::Out; $capSw = New-Object IO.StringWriter
  [Console]::SetOut($capSw)
  try {
    $rc = Invoke-TcPushMain -Dir $drWt -Remote 'origin' -Branch 'main' -LockWaitSec 120 -DryRun $false -LockPrefix ([string]$drCfg.pushPrefix) -LockQueueRoot ([string]$drCfg.pushQroot) `
      -GateRunner $drLegs -RehearsalStarter $drStarter -ChainTouchingProbe $drChain -RehearsalCheck $drCheck -ChainQueue ([string]$drCfg.mode) -LedgerRoot $ledger -NoReexec $true
  } finally { [Console]::SetOut($capOld) }
  $said = $capSw.ToString()
  [IO.File]::WriteAllText((Join-Path $drLogs ($drName + '.pm.txt')), $said)
  Write-DrCkpt 'end'
  $pmRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledger)
  $pmRows = @($pmRaw)
  $pm = $(if ($pmRows.Count) { $pmRows[$pmRows.Count - 1] } else { $null })
  if ($pm) {
    foreach ($k in @('queue', 'queue_pos', 'queue_wait_ms', 'queue_ahead', 'stacked_on', 'restacks', 'stack')) { $row[$k] = $pm.$k }
    $o = [string]$pm.outcome
    $row.result = $(if ($o -like 'landed*') { 'landed' } elseif ($o -ceq 'refused-gate-red') { 'refused-gate-red' } else { 'refused' })
    $row.phase = [string]$pm.phase
    $row.chain = ($pm.queue -and [string]$pm.queue -cne 'not-chain')
  }
  $row.ticket = $script:drState.Ticket
  $row.rh_count = $script:drState.RhN
  $row.ahead_at_lock = @($script:drState.AheadAtLock)
  foreach ($l in @($said -split "`r?`n")) {
    if ($l -match 'every chain queue ticket ahead has landed or left') { $row.wait_outcomes += 'head' }
    elseif ($l -match 'push-main: RESTACK - ') { $row.wait_outcomes += 'restack' }
    elseif ($l -match 'push-main: the chain queue (timeout|error) ') { $row.wait_outcomes += $Matches[1] }
    $m = [regex]::Match($l, 'conflicts with the chain queue ticket ahead \((.+), pid (\d+)\)')
    if ($m.Success) { $row.conflict_with = $m.Groups[1].Value; $row.conflict_pid = [int]$m.Groups[2].Value }
  }
  if ($row.result -eq 'landed') {
    $row.landed_sha = Get-DrSha $drWt 'HEAD'
    $k = Get-DrSha $drWt 'HEAD:chain'
    if (-not $row.chain) { $row.inlock_check = 'not-chain' }
    elseif ($drCfg.noRehearsal) { $row.inlock_check = 'no-rehearsal' }
    elseif ($k -and [IO.File]::Exists((Join-Path ([string]$drCfg.verdicts) ($k + '.pass')))) { $row.inlock_check = 'covered' }
    else { $row.inlock_check = 'uncovered' }
  }
} catch {
  $row.result = 'threw'; $row.phase = $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber
  $rc = 3
} finally {
  Set-Item -LiteralPath 'function:script:Enter-TcPushLock' -Value $script:drEnterReal
  [IO.File]::WriteAllText((Join-Path $drLogs ($drName + '.row.json')), (ConvertTo-Json -InputObject $row -Depth 5 -Compress))
  if ($env:TC_DRILL_PM_DEBUG) { try { Copy-Item -Path (Join-Path $drLogs ($drName + '.*')) -Destination $env:TC_DRILL_PM_DEBUG -Force } catch { } }
}
exit ([int]$rc)
