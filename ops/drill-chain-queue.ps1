<#
  drill-chain-queue.ps1 - The THREE-PUSH SANDBOX DRILL for lib\chain-queue.ps1, and the push-level W9.2 fixtures.

  Drill:      powershell -NoProfile -File ops\drill-chain-queue.ps1 -Drill [-Rounds 3] [-Runner <script>]
  Self-test:  powershell -NoProfile -File ops\drill-chain-queue.ps1 -SelfTest [-Runner <script>]
  Spec:       design\PLAN-push-derived-conflicts-2026-09-23.md, 16.3 W9.2 step 12 (READY, proved before landing)
  Interface:  design\backlog-inbox\pd-queue-interface-2026-09-23.md

  WHAT THE DRILL IS. A sandbox: a temp BARE remote, one clone of it standing in for this repo, and one LINKED WORKTREE
  of that clone per push, which is the production shape (every session here pushes from a worktree of one repo, so
  every worktree's commits are in one shared object store, and that is what lets a rehearsal clone cherry-pick an
  ahead ticket's commits). A private queue prefix and root, a private push lock, stub legs, and a REHEARSAL STUB that
  records what it judged: the stack it applied, the subjects on top of the base, and the key it recorded (the tree of
  chain\ at the stacked tip, this sandbox's analogue of Get-RhManifestSet). Three chain-touching pushes start together
  on a barrier. The drill passes when each stub judged origin plus exactly the ranges ahead of it, all three land in
  ticket order, and each has restacks=0 and one stub rehearsal. The order is read from the queue records and the
  runners' rows, never from a wall clock.

  THE REFERENCE RUNNER stands in for ops\push-main.ps1, which this lane does not edit. It follows the interface file's
  sequence step by step (join, stack, rehearse, legs, ready, wait for the head, catch up, swapping, lock, fetch, check,
  push, landed), with real git against the sandbox remote. -Runner <script> swaps it for a real one: the script is
  started as `<script> -RunnerConfig <json>`, reads the same config and must write the same row file, so the push-main
  lane can drive this drill through push-main itself once its W9.2 integration exists. Until then every verdict this
  file prints is a verdict on the LIBRARY driven by the reference runner, and says so.

  SCOPE OF A CLEAN REPORT: a pass proves, in a sandbox on this machine with every push in its own process, that the
  library orders and stacks real git pushes the way W9.2 says: stacked rehearsals, ticket-order landings, a restack
  when a ticket ahead is refused, a worktree that never holds an ahead ticket's commits, a non-chain push that is never
  queued, a conflict that keeps its place, the off rollback, the error and timeout degrades. It proves nothing about
  ops\push-main.ps1 unless -Runner points at it, and nothing about rehearsal cost or capacity.
#>
# USE WHEN: prove the chain queue before landing it, or after changing lib\chain-queue.ps1 or push-main's W9.2 path; run -Drill -Rounds 3 for the READY drill and -SelfTest for the push-level fixtures, and point -Runner at push-main once it integrates the queue
# ENFORCED BY: none (none)
# gate-inputs: ops\drill-chain-queue.ps1, lib\chain-queue.ps1, lib\gate-slots.ps1, lib\push-lock.ps1, lib\atomic-write.ps1, lib\mutex-hold.ps1, lib\git-repo-env.ps1
param(
  [switch]$SelfTest,
  [switch]$Drill,
  [int]$Rounds = 3,
  [string]$Runner = '',
  [string]$RunnerConfig = ''
)
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'lib\git-repo-env.ps1')
. (Join-Path $repo 'lib\chain-queue.ps1')
Clear-TcGitRepoEnv

# HANG GUARDS, not tuned numbers: a runner is a few seconds of git on a quiet box.
$script:DrillHangSec = 300
$script:DrillFileWaitSec = 240

function Invoke-DGit {
  <# One git call. Native stderr is read under Continue, set as its own statement before the try (the ops rule: a
     catch around a native redirect under Stop is not a guard). #>
  param([string]$Dir, [string[]]$GitArgs)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($Dir) { $out = & git -C $Dir @GitArgs 2>&1 } else { $out = & git @GitArgs 2>&1 }
    $rc = $LASTEXITCODE
  } finally { $ErrorActionPreference = $prev }
  $lines = @($out | ForEach-Object { [string]$_ })
  return [pscustomobject]@{ Rc = $rc; Lines = $lines; Text = ($lines -join "`n") }
}
function Get-DShas([object]$R) { return , @($R.Lines | Where-Object { $_ -match '^[0-9a-f]{40}$' }) }
function Get-DSha([string]$Dir, [string]$Rev) {
  $r = Invoke-DGit $Dir @('rev-parse', '--verify', '-q', $Rev)
  $s = Get-DShas $r
  if ($s.Count) { return $s[0] } else { return '' }
}
function Invoke-DFetch([string]$Dir) {
  # Several runners fetch into ONE shared repo, so refs/remotes/origin/main is contended: retried, never guessed.
  for ($i = 0; $i -lt 40; $i++) {
    $r = Invoke-DGit $Dir @('fetch', '-q', 'origin')
    if ($r.Rc -eq 0) { return $true }
    Start-Sleep -Milliseconds (100 + 25 * $i)
  }
  return $false
}
function Wait-DFiles([string[]]$Paths, [int]$Sec = $script:DrillFileWaitSec) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  foreach ($p in @($Paths)) {
    if (-not $p) { continue }
    while (-not [IO.File]::Exists($p)) {
      if ($sw.Elapsed.TotalSeconds -gt $Sec) { return $false }
      Start-Sleep -Milliseconds 20
    }
  }
  return $true
}
function Get-DSubjects([string]$Dir, [string]$Range) {
  $r = Invoke-DGit $Dir @('log', '--reverse', '--format=%s', $Range)
  return , @($r.Lines | Where-Object { $_ -like 'drill *' -or $_ -eq 'seed' })
}

# ------------------------------------------------------------------------------------------------ the rehearsal stub
function Invoke-DRehearsal {
  <# The stub: a --shared clone of the sandbox repo, the stack's base checked out, every stacked commit and then the
     runner's own range cherry-picked, and the chain\ tree at the tip recorded as the verdict key. Never touches the
     runner's worktree: only this clone moves (W9.2 step 4). #>
  param($Cfg, [string]$StackPath, [string]$Origin, [string[]]$Range, [int]$N)
  $scratch = Join-Path $Cfg.root ('rh\' + $Cfg.name + '-' + $N)
  $id = @('-c', 'user.name=drill', '-c', 'user.email=drill@example.invalid', '-c', 'commit.gpgsign=false', '-c', 'core.autocrlf=false')
  $res = [pscustomobject]@{ Ok = $false; Conflict = $false; Sha = ''; Files = @(); Key = ''; Subjects = @(); Base = ''; Applied = @() }
  try {
    $null = Invoke-DGit '' @('clone', '-q', '--shared', '--no-checkout', $Cfg.box, $scratch)
    $lines = @()
    if ($StackPath) { $lines = @([IO.File]::ReadAllLines($StackPath) | Where-Object { $_ }) } else { $lines = @($Origin) }
    $base = $lines[0]; $res.Base = $base
    $null = Invoke-DGit $scratch ($id + @('checkout', '-q', '--detach', $base))
    $todo = @()
    if ($lines.Count -gt 1) { $todo += $lines[1..($lines.Count - 1)] }
    $todo += @($Range)
    foreach ($s in $todo) {
      $cp = Invoke-DGit $scratch ($id + @('cherry-pick', $s))
      if ($cp.Rc -ne 0) {
        $u = Invoke-DGit $scratch @('diff', '--name-only', '--diff-filter=U')
        $res.Conflict = $true; $res.Sha = $s; $res.Files = @($u.Lines | Where-Object { $_ -and $_ -notmatch '^(warning|error|fatal):' })
        $null = Invoke-DGit $scratch @('cherry-pick', '--abort')
        break
      }
      $res.Applied += $s
    }
    if (-not $res.Conflict) {
      $res.Key = Get-DSha $scratch 'HEAD:chain'
      $res.Subjects = Get-DSubjects $scratch ($base + '..HEAD')
      [IO.File]::WriteAllText((Join-Path $Cfg.verdicts ($res.Key + '.pass')), $Cfg.name)
      $res.Ok = $true
    }
  } finally {
    $rec = [ordered]@{ n = $N; base = $res.Base; stack = @($lines); applied = @($res.Applied); subjects = @($res.Subjects); key = $res.Key; conflict = $res.Conflict; conflict_sha = $res.Sha; conflict_files = @($res.Files) }
    [IO.File]::WriteAllText((Join-Path $Cfg.logs ('{0}.rh.{1}.json' -f $Cfg.name, $N)), (ConvertTo-Json -InputObject $rec -Depth 5 -Compress))
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }
  return $res
}

# ------------------------------------------------------------------------------------------------ the reference runner
function Invoke-DrillRunner {
  <# The stand-in for push-main's W9.2 chain path (the interface file's sequence). Writes <logs>\<name>.row.json. #>
  param([string]$ConfigPath)
  $cfg = [IO.File]::ReadAllText($ConfigPath) | ConvertFrom-Json
  $env:TC_CHAIN_QUEUE_SELFTEST = '1'
  Remove-Item -LiteralPath Env:TC_CHAIN_QUEUE_HOLDER -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath Env:TC_PUSH_LOCK_HOLDER -ErrorAction SilentlyContinue
  $wt = [string]$cfg.wt; $name = [string]$cfg.name; $logs = [string]$cfg.logs
  $ck = Join-Path $logs ($name + '.ckpt.jsonl')
  $row = [ordered]@{
    name = $name; checkout = $wt; pid = $PID; ticket = ''; result = ''; phase = ''; chain = $false; range_join = @()
    rh_count = 0; inlock_check = 'not-run'; landed_sha = ''; ahead_at_lock = @(); conflict_with = ''; conflict_pid = 0
    wait_outcomes = @(); queue_reason = ''
  }
  $cq = $null; $lock = $null; $rc = 3; $st = $null
  function Write-DCkpt([string]$Step) {
    $subj = Get-DSubjects $wt 'HEAD'
    $line = ConvertTo-Json -InputObject ([ordered]@{ step = $Step; head = (Get-DSha $wt 'HEAD'); subjects = @($subj) }) -Compress
    [IO.File]::AppendAllText($ck, ($line + "`n"))
  }
  function Invoke-DRh([int]$N) {
    $res = Invoke-DRehearsal -Cfg $cfg -StackPath $(if ($st -and $st.Ok) { $st.Path } else { '' }) -Origin $script:dOrigin -Range $script:dRange -N $N
    $script:dRow.rh_count++
    if ($res.Conflict) {
      $tk = ''
      if ($st -and $st.Ok) {
        # Stopped on the member's OWN commit: name the ahead ticket whose range touched the conflicting files.
        foreach ($a in @($st.Ahead)) {
          foreach ($s in @($a.Range)) {
            $ch = Invoke-DGit $wt @('diff-tree', '--no-commit-id', '--name-only', '-r', $s)
            if (@($ch.Lines | Where-Object { $res.Files -contains $_ }).Count) { $tk = $a.Name }
          }
        }
      }
      $cw = Set-TcChainStackConflict -Member $cq -Stack $st -Sha $res.Sha -Files $res.Files -Ticket $tk
      if ($cw) { $script:dRow.conflict_with = [string]$cw.Checkout; $script:dRow.conflict_pid = [int]$cw.Pid }
    } elseif ($res.Ok -and $cq -and $cq.Queue -eq 'joined') {
      $null = Set-TcChainQueueState -Member $cq -RhKey $res.Key
    }
    return $res
  }
  $script:dRow = $row
  try {
    [IO.File]::WriteAllText((Join-Path $logs ($name + '.up')), 'up')
    Write-DCkpt 'start'
    if (-not (Wait-DFiles @([string]$cfg.go) )) { throw 'the start barrier never opened' }
    if (-not (Wait-DFiles @($cfg.joinAfter))) { throw 'a joinAfter file never appeared' }
    if (-not (Invoke-DFetch $wt)) { throw 'fetch failed' }
    $rb = Invoke-DGit $wt @('rebase', '-q', 'origin/main')
    if ($rb.Rc -ne 0) { $null = Invoke-DGit $wt @('rebase', '--abort'); $row.result = 'refused'; $row.phase = 'round1'; $rc = 1; return $rc }
    $script:dOrigin = Get-DSha $wt 'origin/main'
    $script:dRange = Get-DShas (Invoke-DGit $wt @('rev-list', '--reverse', 'origin/main..HEAD'))
    $row.range_join = @($script:dRange)
    $touched = Invoke-DGit $wt @('diff', '--name-only', ('origin/main...HEAD'))
    $row.chain = (@($touched.Lines | Where-Object { $_ -like 'chain/*' }).Count -gt 0)
    Write-DCkpt 'rebased'
    $rhN = 0; $lastRh = $null
    if ($row.chain) {
      $cq = Join-TcChainQueue -Mode ([string]$cfg.mode) -Checkout $wt -Base $script:dOrigin -Range $script:dRange -Prefix $cfg.prefix -QueueRoot $cfg.qroot
      $row.ticket = [string]$cq.Name
      if ($cq.Queue -eq 'joined') {
        $st = New-TcChainStackFile -Member $cq -Origin $script:dOrigin -Path (Join-Path $logs ('{0}.stack.{1}' -f $name, ($cq.Stacks + 1)))
        if (-not $st.Ok) { $row.queue_reason = $st.Reason; Exit-TcChainQueue -Member $cq -State left; $cq.Queue = 'error'; $st = $null }
      }
      # M22-SITE. THE WORKTREE IS NEVER REBASED ONTO THE STACK: only the rehearsal's clone applies the ahead commits,
      # because a ticket that leaves would otherwise land its commits with this push (W9.2 step 4).
      Write-DCkpt 'stacked'
      [IO.File]::WriteAllText((Join-Path $logs ($name + '.stacked')), 'stacked')
      if (-not $cfg.noRehearsal) { $rhN++; $lastRh = Invoke-DRh $rhN }
    }
    if (-not (Wait-DFiles @($cfg.legsAfter))) { throw 'a legsAfter file never appeared' }
    $legTree = Get-DSha $wt 'HEAD^{tree}'
    [IO.File]::WriteAllText((Join-Path $logs ($name + '.legs')), $legTree)
    if ([int]$cfg.legsRc -ne 0) {
      $row.result = 'refused-gate-red'; $row.phase = 'legs'
      if ($cq) { Exit-TcChainQueue -Member $cq -State left }
      $rc = 1; return $rc
    }
    if ($cq -and $cq.Queue -eq 'joined') { $null = Set-TcChainQueueState -Member $cq -State ready }
    if (-not (Wait-DFiles @($cfg.swapAfter))) { throw 'a swapAfter file never appeared' }
    if ($cfg.holdBeforeSwap -and -not (Wait-DFiles @([string]$cfg.holdBeforeSwap))) { throw 'the hold before the swap was never released' }
    while ($cq -and $cq.Queue -eq 'joined') {
      $w = Wait-TcChainQueueHead -Member $cq -Stack $st -StallSec ([int]$cfg.stallSec) -PollMs 50
      $row.wait_outcomes += $w.Outcome
      if ($w.Outcome -eq 'restack') {
        if (-not (Invoke-DFetch $wt)) { throw 'fetch failed' }
        $st = New-TcChainStackFile -Member $cq -Origin (Get-DSha $wt 'origin/main') -Path (Join-Path $logs ('{0}.stack.{1}' -f $name, ($cq.Stacks + 1)))
        if (-not $st.Ok) { $row.queue_reason = $st.Reason; Exit-TcChainQueue -Member $cq -State left; $cq.Queue = 'error'; break }
        Write-DCkpt 'restacked'
        if (-not $cfg.noRehearsal) { $rhN++; $lastRh = Invoke-DRh $rhN }
        continue
      }
      if ($w.Outcome -eq 'head') { break }
      $row.queue_reason = $w.Reason
      Exit-TcChainQueue -Member $cq -State left
      break
    }
    # CATCH-UP, outside the lock (W2.2R): a conflict here is the correct refusal for a stack conflict that landed.
    if (-not (Invoke-DFetch $wt)) { throw 'fetch failed' }
    $o2 = Get-DSha $wt 'origin/main'
    if ($o2 -ne $script:dOrigin) {
      $rb2 = Invoke-DGit $wt @('rebase', '-q', 'origin/main')
      if ($rb2.Rc -ne 0) {
        $null = Invoke-DGit $wt @('rebase', '--abort')
        $row.result = 'refused'; $row.phase = 'catchup'
        if ($cq) { Exit-TcChainQueue -Member $cq -State left }
        $rc = 1; return $rc
      }
      if ($cq -and $cq.Queue -eq 'joined') { $null = Set-TcChainQueueState -Member $cq -Base $o2 -Range (Get-DShas (Invoke-DGit $wt @('rev-list', '--reverse', 'origin/main..HEAD'))) }
    }
    Write-DCkpt 'caughtup'
    # THE ORDER READ: the states of the tickets ahead at the moment this member decides to swap, BEFORE its lock take.
    # Read after the lock it would be hidden by the push lock itself, which serialises the swap whatever the queue did.
    if ($st -and $st.Ok) {
      foreach ($a in @($st.Ahead)) {
        $ar = Read-TcChainQueueRecord (Join-Path $cq.Dir ($a.Name + '.json'))
        $row.ahead_at_lock += ('{0}={1}' -f $a.Name, $(if ($ar) { [string]$ar.state } else { 'no-record' }))
      }
    }    if ($cq -and $cq.Queue -eq 'joined') { $null = Set-TcChainQueueState -Member $cq -State swapping }
    $lock = Enter-TcPushLock -Prefix $cfg.pushPrefix -QueueRoot $cfg.pushQroot -WaitSec 120 -PollMs 50 -NoInherit
    if (-not $lock.Held) { throw ('the sandbox push lock was not taken: ' + $lock.Reason) }

    if (-not (Invoke-DFetch $wt)) { throw 'fetch failed' }
    $upToDate = (Invoke-DGit $wt @('merge-base', '--is-ancestor', 'origin/main', 'HEAD')).Rc -eq 0
    if (-not $upToDate) {
      $rb3 = Invoke-DGit $wt @('rebase', '-q', 'origin/main')
      if ($rb3.Rc -ne 0) { $null = Invoke-DGit $wt @('rebase', '--abort'); $row.result = 'refused'; $row.phase = 'inlock'; $rc = 1; return $rc }
    }
    Write-DCkpt 'inlock'
    $key = Get-DSha $wt 'HEAD:chain'
    if (-not $row.chain) { $row.inlock_check = 'not-chain' }
    elseif ($cfg.noRehearsal) { $row.inlock_check = 'no-rehearsal' }
    elseif ([IO.File]::Exists((Join-Path $cfg.verdicts ($key + '.pass')))) { $row.inlock_check = 'covered' }
    else { $row.inlock_check = 'uncovered' }
    $push = Invoke-DGit $wt @('push', '-q', 'origin', 'HEAD:main')
    if ($push.Rc -ne 0) { $row.result = 'refused'; $row.phase = 'push: ' + $push.Text; $rc = 1; return $rc }
    $row.landed_sha = Get-DSha $wt 'HEAD'
    if ($cq) { Exit-TcChainQueue -Member $cq -State landed }
    Exit-TcPushLock $lock
    $row.result = 'landed'; $rc = 0
    return $rc
  } catch {
    $row.result = 'threw'; $row.phase = $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber
    $rc = 3; return $rc
  } finally {
    if ($cq) { Exit-TcChainQueue -Member $cq -State left }
    if ($lock) { Exit-TcPushLock $lock }
    $qrow = if ($row.chain -and $cq) { Get-TcChainQueueRow $cq } else { Get-TcChainQueueRow $null }
    foreach ($k in @($qrow.Keys)) { $row[$k] = $qrow[$k] }
    [IO.File]::WriteAllText((Join-Path $logs ($name + '.row.json')), (ConvertTo-Json -InputObject $row -Depth 5 -Compress))
  }
}

if ($RunnerConfig) {
  $code = Invoke-DrillRunner -ConfigPath $RunnerConfig
  exit ([int]$code)
}

# ------------------------------------------------------------------------------------------------ the sandbox
function New-DrillSandbox {
  <# A bare remote, one clone of it (the "repo"), and a linked worktree per push, each with its commit already made. #>
  param([object[]]$Specs)
  $id = [guid]::NewGuid().ToString('N').Substring(0, 10)
  $root = Join-Path $env:TEMP ('tc-cqd-' + $id)
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $root
  foreach ($d in @('nohooks', 'logs', 'verdicts', 'q', 'pq', 'rh')) { $null = New-Item -ItemType Directory -Force (Join-Path $root $d) }
  $remote = Join-Path $root 'remote.git'; $box = Join-Path $root 'box'
  $null = Invoke-DGit '' @('init', '-q', '--bare', $remote)
  $null = Invoke-DGit $remote @('symbolic-ref', 'HEAD', 'refs/heads/main')
  $null = Invoke-DGit '' @('clone', '-q', $remote, $box)
  foreach ($kv in @(@('user.name', 'drill'), @('user.email', 'drill@example.invalid'), @('core.hooksPath', (Join-Path $root 'nohooks')), @('core.autocrlf', 'false'), @('gc.auto', '0'), @('commit.gpgsign', 'false'))) {
    $null = Invoke-DGit $box @('config', $kv[0], $kv[1])
  }
  $null = Invoke-DGit $box @('checkout', '-q', '-B', 'main')
  $null = New-Item -ItemType Directory -Force (Join-Path $box 'chain'), (Join-Path $box 'other')
  [IO.File]::WriteAllText((Join-Path $box 'chain\base.txt'), "base`n")
  [IO.File]::WriteAllText((Join-Path $box 'chain\shared.txt'), "line one`n")
  [IO.File]::WriteAllText((Join-Path $box 'other\base.txt'), "base`n")
  $null = Invoke-DGit $box @('add', '--', 'chain/base.txt', 'chain/shared.txt', 'other/base.txt')
  $null = Invoke-DGit $box @('commit', '-q', '-m', 'seed')
  $null = Invoke-DGit $box @('push', '-q', 'origin', 'HEAD:main')
  $null = Invoke-DGit $box @('fetch', '-q', 'origin')
  $seed = Get-DSha $box 'origin/main'
  $wts = [ordered]@{}; $commits = [ordered]@{}
  foreach ($s in @($Specs)) {
    $wt = Join-Path $root ('wt-' + $s.Name)
    $null = Invoke-DGit $box @('worktree', 'add', '-q', '-b', ('drill-' + $s.Name), $wt, 'origin/main')
    $paths = @()
    foreach ($k in @($s.Files.Keys)) {
      $full = Join-Path $wt ($k -replace '/', '\')
      $null = New-Item -ItemType Directory -Force (Split-Path -Parent $full)
      [IO.File]::WriteAllText($full, [string]$s.Files[$k])
      $paths += $k
    }
    $null = Invoke-DGit $wt (@('add', '--') + $paths)
    $null = Invoke-DGit $wt @('commit', '-q', '-m', ('drill ' + $s.Name))
    $wts[$s.Name] = $wt; $commits[$s.Name] = Get-DSha $wt 'HEAD'
  }
  $pfx = 'Local\tc-cqd-' + $id + '-'
  return [pscustomobject]@{
    Root = $root; Remote = $remote; Box = $box; Wts = $wts; Commits = $commits; Seed = $seed
    Prefix = $pfx; QRoot = (Join-Path $root 'q'); PushPrefix = ($pfx + 'push-'); PushQRoot = (Join-Path $root 'pq')
    Logs = (Join-Path $root 'logs'); Verdicts = (Join-Path $root 'verdicts')
  }
}

function New-DRunnerConfig($Sb, [string]$Name) {
  return [ordered]@{
    name = $Name; wt = $Sb.Wts[$Name]; box = $Sb.Box; root = $Sb.Root; logs = $Sb.Logs; verdicts = $Sb.Verdicts
    prefix = $Sb.Prefix; qroot = $Sb.QRoot; pushPrefix = $Sb.PushPrefix; pushQroot = $Sb.PushQRoot
    mode = 'live'; noRehearsal = $false; legsRc = 0; go = (Join-Path $Sb.Logs 'go'); joinAfter = @(); legsAfter = @()
    swapAfter = @(); holdBeforeSwap = ''; stallSec = 120
  }
}

function Invoke-DScenario {
  <# Builds a sandbox, starts one runner per spec, waits for all of them, and returns everything the cases read. The
     sandbox is removed before it returns, so every value is read out first. #>
  param([object[]]$Specs, [scriptblock]$Configure = $null, [scriptblock]$OnTick = $null, [string]$RunnerScript = '')
  $PSExe = (Get-Command powershell).Source
  $sb = New-DrillSandbox -Specs $Specs
  $procs = [ordered]@{}
  $res = [pscustomobject]@{ Sb = $sb; Rows = @{}; Rh = @{}; Ckpt = @{}; Exit = @{}; Remote = @(); LandedSubjects = @{}; LandedKey = @{}; Ticks = 0; Note = ''; State = @{} }
  try {
    $cfgs = [ordered]@{}
    foreach ($s in @($Specs)) { $cfgs[$s.Name] = New-DRunnerConfig $sb $s.Name }
    if ($Configure) { & $Configure $sb $cfgs $res.State }
    $script = if ($RunnerScript) { $RunnerScript } else { $PSCommandPath }
    foreach ($n in @($cfgs.Keys)) {
      $cp = Join-Path $sb.Logs ($n + '.cfg.json')
      [IO.File]::WriteAllText($cp, (ConvertTo-Json -InputObject $cfgs[$n] -Depth 5))
      $p = Start-Process -FilePath $PSExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script + '"'), '-RunnerConfig', ('"' + $cp + '"')) `
        -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $sb.Logs ($n + '.out')) -RedirectStandardError (Join-Path $sb.Logs ($n + '.err'))
      $null = $p.Handle
      $procs[$n] = $p
    }
    # THE START BARRIER: every runner reports up, then all are released at once (the drill's "start together").
    $null = Wait-DFiles @($cfgs.Keys | ForEach-Object { Join-Path $sb.Logs ($_ + '.up') }) 120
    [IO.File]::WriteAllText((Join-Path $sb.Logs 'go'), 'go')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (@($procs.Values | Where-Object { -not $_.HasExited }).Count -and $sw.Elapsed.TotalSeconds -lt $script:DrillHangSec) {
      if ($OnTick) { & $OnTick $sb $res.State }
      $res.Ticks++
      Start-Sleep -Milliseconds 25
    }
    foreach ($n in @($procs.Keys)) {
      $p = $procs[$n]
      if (-not $p.HasExited) { try { $p.Kill() } catch { }; $res.Note += ($n + ' hung; ') }
      $null = $p.WaitForExit(10000)
      $res.Exit[$n] = $p.ExitCode
      $rp = Join-Path $sb.Logs ($n + '.row.json')
      $res.Rows[$n] = if ([IO.File]::Exists($rp)) { [IO.File]::ReadAllText($rp) | ConvertFrom-Json } else { $null }
      $rh = @()
      foreach ($f in @(Get-ChildItem -LiteralPath $sb.Logs -Filter ($n + '.rh.*.json') | Sort-Object { [int]($_.Name -replace '^.*\.rh\.(\d+)\.json$', '$1') })) { $rh += ([IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json) }
      $res.Rh[$n] = $rh
      $ckp = Join-Path $sb.Logs ($n + '.ckpt.jsonl')
      $res.Ckpt[$n] = if ([IO.File]::Exists($ckp)) { @([IO.File]::ReadAllLines($ckp) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
      $row = $res.Rows[$n]
      if ($row -and $row.landed_sha) {
        $res.LandedSubjects[$n] = Get-DSubjects $sb.Remote $row.landed_sha
        $res.LandedKey[$n] = Get-DSha $sb.Remote ($row.landed_sha + ':chain')
      }
      if ($res.Exit[$n] -ne 0 -and -not $row) {
        $err = Join-Path $sb.Logs ($n + '.err')
        if ([IO.File]::Exists($err)) { $res.Note += ($n + ' stderr: ' + ([IO.File]::ReadAllText($err) -replace '\s+', ' ').Substring(0, [Math]::Min(300, ([IO.File]::ReadAllText($err) -replace '\s+', ' ').Length)) + '; ') }
      }
    }
    $lg = Invoke-DGit $sb.Remote @('log', '--first-parent', '--reverse', '--format=%s', 'main')
    $res.Remote = @($lg.Lines | Where-Object { $_ -like 'drill *' } | ForEach-Object { $_.Substring(6) })
    return $res
  } finally {
    foreach ($p in @($procs.Values)) { try { if (-not $p.HasExited) { $p.Kill() } } catch { } }
    $null = Invoke-DGit $sb.Box @('worktree', 'prune')
    for ($i = 0; $i -lt 5 -and (Test-Path -LiteralPath $sb.Root); $i++) {
      Remove-Item -LiteralPath $sb.Root -Recurse -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $sb.Root) { Start-Sleep -Milliseconds 300 }
    }
  }
}

function Get-DTicketOrder($Res, [string[]]$Names) {
  # THE ORDER IS READ FROM THE QUEUE RECORDS' TICKET NAMES (arrival ticks), never from a clock the runners share.
  $pairs = @()
  foreach ($n in $Names) { $r = $Res.Rows[$n]; $pairs += [pscustomobject]@{ Name = $n; Ticket = $(if ($r) { [string]$r.ticket } else { '' }) } }
  $sorted = [string[]]@($pairs | ForEach-Object { $_.Ticket })
  [Array]::Sort($sorted, [StringComparer]::Ordinal)
  $out = @()
  foreach ($t in $sorted) { foreach ($p in $pairs) { if ($p.Ticket -eq $t) { $out += $p.Name } } }
  return , $out
}

function Test-DThreePush {
  <# The READY drill (W9.2 step 12) as one verdict object: three chain pushes started together. #>
  param([string]$RunnerScript = '')
  $names = @('t0', 't1', 't2')
  $specs = @($names | ForEach-Object { @{ Name = $_; Files = @{ ('chain/' + $_ + '.txt') = ($_ + "`n") } } })
  $r = Invoke-DScenario -Specs $specs -RunnerScript $RunnerScript -Configure {
    param($sb, $cfgs, $state)
    # Nobody swaps until all three have stacked, so each rehearses on the tickets ahead of it: "start together".
    $all = @($cfgs.Keys | ForEach-Object { Join-Path $sb.Logs ($_ + '.stacked') })
    foreach ($n in @($cfgs.Keys)) { $cfgs[$n].swapAfter = $all }
  }
  $order = Get-DTicketOrder $r $names
  $v = [ordered]@{ order = ($order -join ','); remote = ($r.Remote -join ','); stackedOk = $true; orderOk = $true; onceOk = $true; detail = @() }
  $v.orderOk = ($order.Count -eq 3 -and ($r.Remote -join ',') -eq ($order -join ','))
  for ($k = 0; $k -lt $order.Count; $k++) {
    $n = $order[$k]; $row = $r.Rows[$n]; $rh = @($r.Rh[$n])
    $want = @($order[0..$k] | ForEach-Object { 'drill ' + $_ })
    $judged = if ($rh.Count) { @($rh[0].subjects) } else { @() }
    $okStack = ($rh.Count -ge 1 -and $rh[0].base -eq $r.Sb.Seed -and ($judged -join '|') -eq ($want -join '|') -and @($rh[0].stack).Count -eq (1 + $k))
    $aheadLanded = @($row.ahead_at_lock | Where-Object { $_ -notmatch '=landed$' }).Count -eq 0 -and @($row.ahead_at_lock).Count -eq $k
    $okOnce = ($row -and $row.result -eq 'landed' -and [int]$row.restacks -eq 0 -and [int]$row.rh_count -eq 1 -and $rh.Count -eq 1 -and $row.inlock_check -eq 'covered' -and $row.queue -eq 'joined' -and [int]$row.queue_pos -eq $k -and $r.LandedKey[$n] -eq $rh[0].key -and $r.Exit[$n] -eq 0)
    if (-not $okStack) { $v.stackedOk = $false }
    if (-not $aheadLanded) { $v.orderOk = $false }
    if (-not $okOnce) { $v.onceOk = $false }
    $v.detail += ('{0}: pos={1} judged=[{2}] stack={3} ahead_at_lock=[{4}] restacks={5} rh={6} inlock={7} result={8} exit={9}' -f $n, $(if ($row) { $row.queue_pos } else { '?' }), ($judged -join ';'), $(if ($rh.Count) { @($rh[0].stack).Count } else { 0 }), (@($row.ahead_at_lock) -join ';'), $(if ($row) { $row.restacks } else { '?' }), $(if ($row) { $row.rh_count } else { '?' }), $(if ($row) { $row.inlock_check } else { '?' }), $(if ($row) { $row.result + ' ' + $row.phase } else { 'no row' }), $r.Exit[$n])
  }
  $v.detail += ('note: ' + $r.Note)
  $v.pass = ($v.stackedOk -and $v.orderOk -and $v.onceOk)
  return [pscustomobject]$v
}

if ($Drill) {
  $pass = 0
  for ($i = 1; $i -le $Rounds; $i++) {
    $v = Test-DThreePush -RunnerScript $Runner
    Write-Output ('round {0}: {1}  tickets={2} landed={3} stacked={4} ordered={5} once={6}' -f $i, $(if ($v.pass) { 'PASS' } else { 'FAIL' }), $v.order, $v.remote, $v.stackedOk, $v.orderOk, $v.onceOk)
    foreach ($d in $v.detail) { Write-Output ('    ' + $d) }
    if ($v.pass) { $pass++ }
  }
  $who = if ($Runner) { 'runner ' + $Runner } else { 'the reference runner' }
  Write-Output ('CHAIN-QUEUE-DRILL-COMPLETE rounds={0} passed={1} runner={2}' -f $Rounds, $pass, $(if ($Runner) { 'custom' } else { 'reference' }))
  if ($pass -eq $Rounds) { Write-Output ('chain-queue three-push drill PASS: {0} of {1} rounds, driven by {2}' -f $pass, $Rounds, $who); exit 0 }
  Write-Output ('chain-queue three-push drill FAIL: {0} of {1} rounds passed, driven by {2}' -f $pass, $Rounds, $who); exit 1
}

if ($SelfTest) {
  $ErrorActionPreference = 'Stop'
  $f = 0; $cases = 0
  $expected = 12
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  $kinds = @{ $kMF = 0; $kMNF = 0; $kCT = 0 }
  function T($m, $cond, $got) {
    $script:cases++
    foreach ($k in @($kMNF, $kMF, $kCT)) { if (([string]$m).StartsWith($k)) { $script:kinds[$k]++; break } }
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }
  . (Join-Path $repo 'lib\mutex-hold.ps1')
  $env:TC_CHAIN_QUEUE_SELFTEST = '1'
  try {
    # ---- A. three pushes together: stacking, ticket order, one rehearsal each ----
    $a = Test-DThreePush -RunnerScript $Runner
    $ad = ($a.detail -join ' || ')
    T ($kMF + '  stacking: each of three pushes started together judged origin plus exactly the ranges of the tickets ahead of it') $a.stackedOk $ad
    T ($kMF + '  ordering: every member read each ticket ahead landed when it decided to swap, before its lock take, and the remote holds the three in ticket order') $a.orderOk ("tickets={0} remote={1} {2}" -f $a.order, $a.remote, $ad)
    T ($kCT + '  each landed after the one ahead with no second rehearsal: restacks=0, one stub rehearsal, the in-lock check covered, the judged key the landed key') $a.onceOk $ad

    # ---- B. a ticket ahead is refused: restack, and the worktree never held its commits ----
    $rb = Invoke-DScenario -RunnerScript $Runner -Specs @(@{ Name = 'refused'; Files = @{ 'chain/r.txt' = "r`n" } }, @{ Name = 'behind'; Files = @{ 'chain/b.txt' = "b`n" } }) -Configure {
      param($sb, $cfgs, $state)
      $cfgs['refused'].legsRc = 1
      $cfgs['refused'].legsAfter = @(Join-Path $sb.Logs 'behind.stacked')
      $cfgs['behind'].joinAfter = @(Join-Path $sb.Logs 'refused.stacked')
    }
    $bRow = $rb.Rows['behind']; $rRow = $rb.Rows['refused']; $bRh = @($rb.Rh['behind'])
    T ($kMF + '  restack: a ticket ahead refused by its legs turns left, and the member behind rehearses once more onto origin alone with restacks=1') `
      ($rRow.result -eq 'refused-gate-red' -and $bRow.result -eq 'landed' -and [int]$bRow.restacks -eq 1 -and $bRh.Count -eq 2 -and (@($bRh[0].subjects) -join '|') -eq 'drill refused|drill behind' -and (@($bRh[1].subjects) -join '|') -eq 'drill behind' -and (@($bRow.wait_outcomes) -join ',') -eq 'restack,head' -and $rb.Exit['behind'] -eq 0) `
      ("refused={0} behind={1} restacks={2} rh={3} judged=[{4}] waits={5} note={6}" -f $rRow.result, $bRow.result, $bRow.restacks, $bRh.Count, (($bRh | ForEach-Object { @($_.subjects) -join ';' }) -join ' / '), (@($bRow.wait_outcomes) -join ','), $rb.Note)
    $everHeld = @($rb.Ckpt['behind'] | Where-Object { @($_.subjects) -contains 'drill refused' }).Count
    T ($kMNF + '  the safety case: the member''s landed commit has none of the refused ticket''s commits among its ancestors, and no checkpoint of its worktree HEAD ever held them') `
      ($bRow.landed_sha -and -not (@($rb.LandedSubjects['behind']) -contains 'drill refused') -and $everHeld -eq 0 -and @($rb.Ckpt['behind']).Count -ge 5 -and ($rb.Remote -join ',') -eq 'behind') `
      ("landed=[{0}] checkpoints={1} holding={2} remote={3}" -f (@($rb.LandedSubjects['behind']) -join ';'), @($rb.Ckpt['behind']).Count, $everHeld, ($rb.Remote -join ','))

    # ---- C. a non-chain push is never queued, and lands while two members wait ----
    $rc = Invoke-DScenario -RunnerScript $Runner -Specs @(@{ Name = 'm1'; Files = @{ 'chain/m1.txt' = "m1`n" } }, @{ Name = 'm2'; Files = @{ 'chain/m2.txt' = "m2`n" } }, @{ Name = 'plain'; Files = @{ 'other/p.txt' = "p`n" } }) -Configure {
      param($sb, $cfgs, $state)
      $rel = Join-Path $sb.Logs 'members.release'
      $cfgs['m1'].holdBeforeSwap = $rel; $cfgs['m2'].holdBeforeSwap = $rel
      $cfgs['plain'].joinAfter = @((Join-Path $sb.Logs 'm1.stacked'), (Join-Path $sb.Logs 'm2.stacked'))
      $state['release'] = $rel; $state['plainRow'] = (Join-Path $sb.Logs 'plain.row.json'); $state['minLive'] = 99; $state['maxLive'] = 0; $state['samples'] = 0
    } -OnTick {
      param($sb, $state)
      if ([IO.File]::Exists($state['release'])) { return }
      $plainUp = [IO.File]::Exists((Join-Path $sb.Logs 'm1.stacked')) -and [IO.File]::Exists((Join-Path $sb.Logs 'm2.stacked'))
      if ($plainUp) {
        $lv = Get-TcChainQueueLive -Prefix $sb.Prefix -QueueRoot $sb.QRoot
        $n = @($lv).Count
        $state['samples']++
        if ($n -lt $state['minLive']) { $state['minLive'] = $n }
        if ($n -gt $state['maxLive']) { $state['maxLive'] = $n }
      }
      if ([IO.File]::Exists($state['plainRow'])) { [IO.File]::WriteAllText($state['release'], 'go') }
    }
    $pRow = $rc.Rows['plain']
    T ($kMNF + '  a non-chain push never takes a ticket, and lands first while two members are queued (a probe from another process read 2 live tickets throughout)') `
      ($pRow.queue -eq 'not-chain' -and -not $pRow.ticket -and $pRow.result -eq 'landed' -and $rc.State['minLive'] -eq 2 -and $rc.State['maxLive'] -eq 2 -and $rc.State['samples'] -gt 0 -and @($rc.Remote)[0] -eq 'plain') `
      ("queue={0} ticket={1} result={2} live={3}..{4} over {5} samples remote={6}" -f $pRow.queue, $pRow.ticket, $pRow.result, $rc.State['minLive'], $rc.State['maxLive'], $rc.State['samples'], ($rc.Remote -join ','))
    T ($kCT + '  the two members land behind it in ticket order and their verdicts still cover them, because a non-chain landing moves no key') `
      ($rc.Rows['m1'].result -eq 'landed' -and $rc.Rows['m2'].result -eq 'landed' -and $rc.Rows['m1'].inlock_check -eq 'covered' -and $rc.Rows['m2'].inlock_check -eq 'covered' -and (@($rc.Remote)[1..2] -join ',') -eq ((Get-DTicketOrder $rc @('m1', 'm2')) -join ',')) `
      ("m1={0}/{1} m2={2}/{3} remote={4}" -f $rc.Rows['m1'].result, $rc.Rows['m1'].inlock_check, $rc.Rows['m2'].result, $rc.Rows['m2'].inlock_check, ($rc.Remote -join ','))

    # ---- D. -NoRehearsal still joins ----
    $rd = Invoke-DScenario -RunnerScript $Runner -Specs @(@{ Name = 'norh'; Files = @{ 'chain/n.txt' = "n`n" } }) -Configure { param($sb, $cfgs, $state) $cfgs['norh'].noRehearsal = $true }
    $dRow = $rd.Rows['norh']
    T ($kMF + '  a -NoRehearsal chain-touching push takes a ticket, rehearses nothing, and lands') `
      ($dRow.queue -eq 'joined' -and $dRow.ticket -and [int]$dRow.rh_count -eq 0 -and @($rd.Rh['norh']).Count -eq 0 -and $dRow.result -eq 'landed' -and $dRow.inlock_check -eq 'no-rehearsal') `
      ("queue={0} ticket={1} rh={2} result={3}" -f $dRow.queue, $dRow.ticket, $dRow.rh_count, $dRow.result)

    # ---- E. a stack conflict keeps its place and is refused at catch-up once the ticket ahead lands ----
    $re = Invoke-DScenario -RunnerScript $Runner -Specs @(@{ Name = 'first'; Files = @{ 'chain/shared.txt' = "first wins`n" } }, @{ Name = 'second'; Files = @{ 'chain/shared.txt' = "second loses`n" } }) -Configure {
      param($sb, $cfgs, $state)
      $cfgs['second'].joinAfter = @(Join-Path $sb.Logs 'first.stacked')
      $cfgs['first'].swapAfter = @(Join-Path $sb.Logs 'second.legs')
    }
    $eRow = $re.Rows['second']; $fRow = $re.Rows['first']
    T ($kMF + '  the stack conflict: the member records stack=conflict naming the ticket ahead, keeps its place, and is refused phase=catchup once that ticket lands') `
      ($eRow.stack -eq 'conflict' -and $eRow.conflict_with -eq $fRow.checkout -and [int]$eRow.conflict_pid -eq [int]$fRow.pid -and $eRow.result -eq 'refused' -and $eRow.phase -eq 'catchup' -and $fRow.result -eq 'landed' -and (@($eRow.wait_outcomes) -join ',') -eq 'head' -and ($re.Remote -join ',') -eq 'first') `
      ("stack={0} with={1} pid={2} result={3} phase={4} first={5} waits={6} note={7}" -f $eRow.stack, $eRow.conflict_with, $eRow.conflict_pid, $eRow.result, $eRow.phase, $fRow.result, (@($eRow.wait_outcomes) -join ','), $re.Note)

    # ---- F. the rollback ----
    $rf = Invoke-DScenario -RunnerScript $Runner -Specs @(@{ Name = 'off'; Files = @{ 'chain/o.txt' = "o`n" } }) -Configure {
      param($sb, $cfgs, $state)
      $cfgs['off'].mode = 'off'; $state['dir'] = (Get-TcGateQueueDir -Prefix $sb.Prefix -Root $sb.QRoot); $state['seen'] = 0; $state['dirSeen'] = 0
    } -OnTick {
      param($sb, $state)
      if ([IO.Directory]::Exists($state['dir'])) { $state['dirSeen'] = 1; $n = @([IO.Directory]::GetFiles($state['dir'], '*.ticket')).Count; if ($n -gt $state['seen']) { $state['seen'] = $n } }
    }
    $fr = $rf.Rows['off']
    T ($kCT + '  the rollback: -ChainQueue off takes no ticket (a probe from another process saw none throughout), records queue=off, and lands as the W2.2R path does') `
      ($fr.queue -eq 'off' -and $rf.State['seen'] -eq 0 -and $rf.State['dirSeen'] -eq 0 -and $fr.result -eq 'landed' -and $rf.Ticks -gt 0) `
      ("queue={0} seen={1} dir={2} result={3} ticks={4}" -f $fr.queue, $rf.State['seen'], $rf.State['dirSeen'], $fr.result, $rf.Ticks)

    # ---- G. an unwritable queue root ----
    $rg = Invoke-DScenario -RunnerScript $Runner -Specs @(@{ Name = 'err'; Files = @{ 'chain/e.txt' = "e`n" } }) -Configure {
      param($sb, $cfgs, $state)
      $bad = Join-Path $sb.Root 'a-file-not-a-dir'; [IO.File]::WriteAllText($bad, 'x'); $cfgs['err'].qroot = $bad
    }
    $gr = $rg.Rows['err']
    T ($kCT + '  an unwritable queue root records queue=error and the push lands as the W2.2R path does') ($gr.queue -eq 'error' -and $gr.result -eq 'landed' -and $rg.Exit['err'] -eq 0) ("queue={0} result={1} exit={2}" -f $gr.queue, $gr.result, $rg.Exit['err'])

    # ---- H. the timed-out branch: a head held by a holder that never changes state ----
    $rh = Invoke-DScenario -RunnerScript $Runner -Specs @(@{ Name = 'late'; Files = @{ 'chain/l.txt' = "l`n" } }) -Configure {
      param($sb, $cfgs, $state)
      $cfgs['late'].stallSec = 2
      $fake = '{0:D19}-{1}-{2}' -f ([DateTime]::UtcNow.Ticks - 10000000), 5151, 'fedcba98'
      $dir = Get-TcGateQueueDir -Prefix $sb.Prefix -Root $sb.QRoot
      $null = [IO.Directory]::CreateDirectory($dir)
      $state['hold'] = Start-TcMutexHold -Name ($sb.Prefix + 'q-' + $fake)
      [IO.File]::WriteAllText((Join-Path $dir ($fake + '.ticket')), '5151')
      $rec = [ordered]@{ ticket = $fake; pid = 5151; checkout = 'C:\drill\frozen-head'; base = $sb.Seed; range = @(); state = 'rehearsing'; rh_key = ''; rh_range = @(); updated_utc = ''; seq = 1; final_utc = '' }
      [IO.File]::WriteAllText((Join-Path $dir ($fake + '.json')), (ConvertTo-Json -InputObject $rec -Compress))
    }
    try { Stop-TcMutexHold $rh.State['hold'] } catch { }
    $hr = $rh.Rows['late']
    T ($kMF + '  the timed-out branch: an ahead ticket held by a frozen holder in another process and a lowered bound give queue=timeout, queue_ahead naming the holder, and a push that proceeds and lands') `
      ($rh.State['hold'].Held -and $hr.queue -eq 'timeout' -and $hr.queue_ahead -eq '5151:C:\drill\frozen-head' -and $hr.result -eq 'landed' -and (@($hr.wait_outcomes) -join ',') -eq 'timeout') `
      ("held={0} queue={1} ahead={2} result={3} waits={4}" -f $rh.State['hold'].Held, $hr.queue, $hr.queue_ahead, $hr.result, (@($hr.wait_outcomes) -join ','))
  } catch {
    T ('SELF-TEST ABORTED  ' + $_.Exception.Message + ' at line ' + $_.InvocationInfo.ScriptLineNumber) $false 'threw'
  } finally {
    try { Stop-TcMutexHold } catch { }
    Remove-Item -LiteralPath Env:TC_CHAIN_QUEUE_SELFTEST -ErrorAction SilentlyContinue
  }
  $who = if ($Runner) { 'runner ' + $Runner } else { 'the reference runner' }
  if ($cases -ne $expected) { Write-Output ("drill-chain-queue self-test FAIL: ran {0} case(s), the literal list holds {1}" -f $cases, $expected); exit 1 }
  if ($f) { Write-Output ("drill-chain-queue self-test FAIL: {0} of {1} check(s), driven by {2}" -f $f, $cases, $who); exit 1 }
  Write-Output ("drill-chain-queue self-test PASS: {0} cases driven by {1} - {2} must-fire led by three pushes stacking in ticket order, {3} must-not-fire led by a worktree that never held a refused ticket's commits, and {4} clean twins led by one rehearsal per landing" -f $cases, $who, $kinds[$kMF], $kinds[$kMNF], $kinds[$kCT])
  exit 0
}

Write-Output 'usage: drill-chain-queue.ps1 -Drill [-Rounds 3] | -SelfTest   [-Runner <script taking -RunnerConfig>]'
exit 2
