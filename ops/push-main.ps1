<#
  push-main.ps1 - push to main so that it LANDS: gate first, OUTSIDE the machine-wide push lock, then take the lock
  and do the fetch, the rebase and the push inside it.

  THAT SENTENCE USED TO SAY "take the lock first, then rebase, then gate, then push, all inside it" (fixed
  2026-09-12). It was true for one day. The gate moved out of the lock that morning in 4ae8376f4 - with a ~10-minute
  gate inside a machine-wide lock the box lands about six pushes an hour however many sessions are working - and this
  header was left describing the order it no longer ran. A header that describes the previous version of its own file
  is worse than no header, because the next reader takes it as the design and measures against it.

  Run:        powershell -File ops\push-main.ps1
              powershell -File ops\push-main.ps1 -DryRun        (do everything except the push)
  Self-test:  powershell -File ops\push-main.ps1 -SelfTest

  WHY THIS EXISTS AND `git push` IS NOT ENOUGH (2026-09-11, design\PLAN-push-livelock-2026-09-11.md).
  ops\hooks\pre-push takes the push lock too, and that alone removes the livelock: while one hook runs, no other push
  on this box can land. But the hook starts AFTER git has already fixed this push's refs, so a session that rebased,
  ran `git push`, and then queued behind somebody else's 20-minute hook comes out of the queue holding a base the
  remote has moved past. The gate then refuses it in seconds with "fetch, rebase and push again" - cheap, honest, and
  still a second attempt.

  THE ORDER IS THE WHOLE POINT. Take the lock BEFORE fetching, and the rebase cannot go stale: nothing else can land
  between the fetch and the ref update, so the push lands on its FIRST attempt. That is the only place the guarantee
  can be made, and it is outside git, which is why it is a wrapper and not a hook.

  IT DOES NOT WEAKEN OR SKIP ANYTHING. It runs a plain `git push`, so ops\hooks\pre-push runs, run-gates runs, the
  test-auditors check runs, and a red gate refuses this push exactly as it refuses any other. The hook's own attempt
  to take the lock INHERITS the one held here (lib\push-lock.ps1) rather than deadlocking against its own ancestor.
  `--no-verify` is not passed, not offered and not available here.

  WHAT IT REFUSES, and why each is a refusal rather than something clever:
    - a dirty working tree. Rebasing over uncommitted work is this estate's recorded trap: an autostash rebase
      restores CONTENT, not the index, and the ~07:00 bot has left a path unmerged that way.
    - a rebase that conflicts. It is aborted, the branch is left exactly where it was, and the conflict is yours.
    - a branch with nothing to push.
  Exit 0 = landed. 1 = refused, or the push failed. 3 = could not evaluate, which is never a pass.

  SCOPE OF A CLEAN REPORT: exit 0 means the remote accepted this push while this process held the lock. It says
  nothing about a pusher that does not take the lock - an older checkout, a plain `git push --no-verify`, or another
  machine - and nothing about whether main is healthy afterwards.
#>
[CmdletBinding()]
param(
  [string]$Remote = 'origin',
  [string]$Branch = 'main',
  [int]$LockWaitSec = 1200,
  [switch]$DryRun,
  # THE LOUD BYPASS OF THE CHAIN REHEARSAL (2026-09-22, plan-2026-09-22-7): sets TC_NO_REHEARSAL for this push, which the
  # pre-push hook prints and ops\rehearse-chain.ps1 logs with the reason. Use it for an emergency, never as a habit.
  [switch]$NoRehearsal,
  [string]$NoRehearsalReason = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\push-lock.ps1')
. (Join-Path $repo 'lib\git-repo-env.ps1')
. (Join-Path $repo 'lib\push-ledger.ps1')
. (Join-Path $repo 'lib\seed-hint.ps1')     # Get-TcSeedDirs: which directories ops\seed-worktree.ps1 seeds, read off its own source

function Invoke-TcGit {
  <# git, with its exit code and its TWO STREAMS KEPT APART: Out is stdout and is the only thing any caller parses,
     Err is stderr, Text is both for a human to read.

     WHY NOT `& git ... 2>&1` (found by this file's own self-test, 2026-09-11). Merging them made every case that
     should have pushed read REFUSED - the working tree has uncommitted changes - in a checkout with nothing
     uncommitted at all. core.autocrlf is on here, so `git status` writes "LF will be replaced by CRLF" warnings to
     stderr, the merge folded them into the porcelain output, and the dirty check counted a warning as a changed
     path. It is the same family as the estate's rule against redirecting a native child's stderr under 'Stop': the
     redirect that throws away git's answer there hands you somebody else's answer here. Using the process API
     directly avoids the PowerShell redirect operator on a native exe altogether, so no preference has to be lowered.

     BOTH STREAMS ARE READ BEFORE THE WAIT, or a child that fills a pipe blocks while this blocks on its exit. #>
  param([string]$Dir, [string[]]$Arguments)
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $argv = @('-C', $Dir) + @($Arguments)
  $psi.Arguments = (@($argv | ForEach-Object { if ([string]$_ -match '[\s"]') { '"' + ([string]$_ -replace '"', '\"') + '"' } else { [string]$_ } }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
  $p = $null
  try {
    $p = [Diagnostics.Process]::Start($psi)
    $oTask = $p.StandardOutput.ReadToEndAsync()
    $eTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $out = @(([string]$oTask.Result) -split "`r?`n" | Where-Object { $_.Trim() })
    $err = @(([string]$eTask.Result) -split "`r?`n" | Where-Object { $_.Trim() })
    return [pscustomobject]@{ Code = $p.ExitCode; Out = $out; Err = $err; Text = ((@($out) + @($err)) -join "`n") }
  } catch {
    return [pscustomobject]@{ Code = 127; Out = @(); Err = @([string]$_.Exception.Message); Text = [string]$_.Exception.Message }
  } finally {
    if ($p) { $p.Dispose() }
  }
}

function Get-TcPushPlan {
  <# What this push would do, decided from git and from nothing else. Kept apart from the doing so its fixtures can
     drive every branch without a remote: Ready, Reason, Head, RemoteSha, NeedsRebase, Dirty, Ahead. #>
  param([string]$Head, [string]$RemoteSha, [string]$MergeBase, [int]$Ahead, [bool]$Dirty)
  if ($Dirty) { return [pscustomobject]@{ Ready = $false; NeedsRebase = $false; Reason = 'the working tree has uncommitted changes. Commit them or set them aside: rebasing over them restores content but not the index, which is how this estate has left a path unmerged before.' } }
  if (-not $Head) { return [pscustomobject]@{ Ready = $false; NeedsRebase = $false; Reason = 'git could not name HEAD in this checkout' } }
  if (-not $RemoteSha) { return [pscustomobject]@{ Ready = $false; NeedsRebase = $false; Reason = 'the remote branch could not be read, so what this push would land on is unknown' } }
  if ($Head -eq $RemoteSha) { return [pscustomobject]@{ Ready = $false; NeedsRebase = $false; Reason = 'this checkout holds exactly what the remote holds - there is nothing to push' } }
  if ($Ahead -le 0) { return [pscustomobject]@{ Ready = $false; NeedsRebase = $false; Reason = 'this branch has no commits the remote does not already have' } }
  # AN EMPTY MERGE-BASE IS UNRELATED HISTORIES, NOT A STALE BASE (found by this file's own self-test, 2026-09-11).
  # `git merge-base` exits 1 and prints nothing when two commits share no ancestor at all, and the first version of
  # this function read that empty string as "different from the remote sha" and therefore as a rebase. It would have
  # replayed an unrelated history onto main and pushed it. The fixture hit it because a bare origin whose HEAD names
  # a branch it does not have clones EMPTY, so every commit made in that clone is a root commit - but a real checkout
  # reaches the same state after a reclone against the wrong remote, and the outcome there is somebody else's tree
  # landing on main. A could-not-relate is a refusal, never a rebase.
  if (-not $MergeBase) { return [pscustomobject]@{ Ready = $false; NeedsRebase = $false; Reason = 'this branch and the remote branch share no common ancestor, so there is no rebase that could make this a fast-forward. Check you are pushing the branch and the remote you meant to.' } }
  # THE REBASE HAPPENS ONLY WHEN THE REMOTE ACTUALLY MOVED. Rebasing when it did not is the habit CLAUDE.md names:
  # it rewrites the tree for nothing and an autostash restores content, not the index.
  $needs = ($MergeBase -ne $RemoteSha)
  return [pscustomobject]@{ Ready = $true; NeedsRebase = $needs; Reason = $(if ($needs) { 'the remote moved since this branch left it, so it is rebased onto what the remote holds now' } else { 'this branch already sits on what the remote holds' }) }
}

function Say {
  <# Progress goes to the CONSOLE, never to the success stream (the estate's ps-callback-output-joins-the-return
     memory). Anything Write-Output writes inside a function JOINS that function's return value, so
     `$rc = Invoke-TcPushMain ...` came back as an Object[] of the messages plus the code, and three self-test cases
     read `rc=System.Object[]`. Console.Out is real stdout - a `>` redirect still captures it - and is not a
     PowerShell stream, so it cannot join anything. #>
  param([string]$Text)
  [Console]::Out.WriteLine($Text)
}

function Invoke-TcWarmGate {
  <# Run the gate OUTSIDE the push lock, so the expensive half of a push is not serialised behind every other
     session on this box. Returns Ran / Code / Why; it decides nothing, so its caller can degrade on a 3.

     Start-Process's ExitCode is empty under PS 5.1 unless .Handle is touched while the process is alive
     ([[ps-start-process-exitcode-needs-handle]]), and reading an empty ExitCode as 0 would turn a red gate into a
     pass here - the one outcome this must never produce. So the handle is taken before the wait, and a code that
     still cannot be read is reported as could-not-evaluate rather than as a pass. #>
  param([string]$Dir)
  $gate = Join-Path $Dir 'ops\run-gates.ps1'
  if (-not (Test-Path -LiteralPath $gate)) {
    return [pscustomobject]@{ Ran = $false; Code = 3; Why = 'this checkout has no ops\run-gates.ps1' }
  }
  try {
    $p = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Dir -NoNewWindow -PassThru -ErrorAction Stop `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gate)
    $null = $p.Handle
    $p.WaitForExit()
    $code = $p.ExitCode
    if ($null -eq $code) { return [pscustomobject]@{ Ran = $true; Code = 3; Why = 'the gate ran but its exit code could not be read' } }
    return [pscustomobject]@{ Ran = $true; Code = [int]$code; Why = '' }
  } catch {
    return [pscustomobject]@{ Ran = $false; Code = 3; Why = ('the gate could not be started: ' + $_.Exception.Message) }
  }
}

function Invoke-TcSeedIfUnseeded {
  <# SEED BEFORE THE GATE, AS THE HOOK DOES (2026-09-18, backlog I237). ops\hooks\pre-push seeds a checkout with no
     built cards once, before its gate, because meal-prep\db\built is gitignored and a worktree has none until
     ops\seed-worktree.ps1 copies it. push-main's gate runs OUTSIDE the lock and BEFORE git push, so it ran unseeded:
     feed-covers-published reported BLIND, test-auditors' reading of that child printed FAIL, and the warm
     test-auditors leg refused most first pushes from a fresh worktree for a reason unrelated to the change. The same
     seeder and the same best effort as the hook: a seed that cannot run is SAID and never refuses, because seeding
     supplies inputs and decides nothing. WHAT "UNSEEDED" MEANS IS READ FROM THE SEEDER, never restated here: a directory
     its $SEED_DIRS names (lib\seed-hint.ps1 Get-TcSeedDirs) that is absent or holds no file. That keeps this file from
     spelling another module's internals path, which ops\audit-cross-module-reach.ps1 ratchets, and a directory that
     joins or leaves that list moves this check the same day. Returns Ran / Code / Why. -Seeder is the self-test's seam. #>
  param([string]$Dir, [string]$Seeder = '')
  if (-not $Seeder) { $Seeder = Join-Path $Dir 'ops\seed-worktree.ps1' }
  if (-not (Test-Path -LiteralPath $Seeder)) { return [pscustomobject]@{ Ran = $false; Code = 3; Why = 'no ops\seed-worktree.ps1 in this checkout' } }
  $seedDirsRaw = Get-TcSeedDirs -Text ([IO.File]::ReadAllText($Seeder))   # comma-returned: assign, then wrap
  $seedDirs = @($seedDirsRaw | Where-Object { $_ })
  if ($seedDirs.Count -eq 0) {
    Say 'push-main: the seeder''s directory list could not be read, so whether this checkout is seeded is unknown; the gates will say BLIND where it matters.'
    return [pscustomobject]@{ Ran = $false; Code = 3; Why = 'seed list unreadable' }
  }
  $empty = @($seedDirs | Where-Object {
    $sd = Join-Path $Dir $_
    -not ((Test-Path -LiteralPath $sd -PathType Container) -and [IO.Directory]::EnumerateFiles($sd).GetEnumerator().MoveNext())
  })
  if ($empty.Count -eq 0) { return [pscustomobject]@{ Ran = $false; Code = 0; Why = 'already seeded' } }
  Say ("push-main: this checkout has nothing in {0}, so gates that read it would be BLIND - seeding once before the gate, as the hook does." -f ($empty -join ', '))
  try {
    $p = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Dir -NoNewWindow -PassThru -ErrorAction Stop `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Seeder + '"'), '-Target', ('"' + $Dir + '"'))
    $null = $p.Handle
    $p.WaitForExit()
    $code = $p.ExitCode
    if ($null -eq $code) { $code = 3 }
    if ([int]$code -ne 0) { Say ("push-main: seeding did not complete (exit {0}); the gates will report BLIND rather than fail." -f $code) }
    return [pscustomobject]@{ Ran = $true; Code = [int]$code; Why = '' }
  } catch {
    Say ('push-main: seeding could not be started (' + $_.Exception.Message + '); the gates will report BLIND rather than fail.')
    return [pscustomobject]@{ Ran = $false; Code = 3; Why = $_.Exception.Message }
  }
}

function Invoke-TcWarmTestAuditors {
  <# The hook's SECOND leg, run outside the lock too (2026-09-18, queue 2026-09-18-1139a0). The pre-push hook runs
     ops\prepush-test-auditors.ps1 after run-gates, and when push-main holds the lock that leg ran INSIDE it: measured
     2026-09-18 on the landing of the money lane's commits, a full test-auditors leg took 389 s under the lock (f0d65b0d8),
     holding every other push on the box, because nothing had recorded a pass before the lock was taken.
     prepush-test-auditors records a PASS keyed on the content of its inputs and reuses it across a rebase that moved
     none (Get-TaInputKey), so running it here, with the same ref line the hook will hand it, makes the in-lock run a
     REUSED line whenever the in-lock rebase brought in no test-auditors input. It weakens nothing: the hook still runs
     the leg inside the lock, and a key that moved runs the whole suite there exactly as before.
     Same contract as Invoke-TcWarmGate: Ran / Code / Why, 1 refuses before the lock, 3 degrades to the hook.
     An exit 0 counts only with PREPUSH-TEST-AUDITORS-COMPLETE as the last line, as in the hook. -Script is the seam the
     self-test drives a fixture through. #>
  param([string]$Dir, [string]$RefLine, [string]$Script = '')
  if (-not $Script) { $Script = Join-Path $Dir 'ops\prepush-test-auditors.ps1' }
  if (-not (Test-Path -LiteralPath $Script)) {
    return [pscustomobject]@{ Ran = $false; Code = 3; Why = 'this checkout has no ops\prepush-test-auditors.ps1' }
  }
  if (-not $RefLine) { return [pscustomobject]@{ Ran = $false; Code = 3; Why = 'the ref line for the test-auditors check could not be formed' } }
  $stem = Join-Path $env:TEMP ('tc-pm-ta-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $inF = $stem + '.in'; $outF = $stem + '.out'; $errF = $stem + '.err'
  try {
    [IO.File]::WriteAllText($inF, ($RefLine + "`n"), (New-Object Text.UTF8Encoding($false)))
    $p = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Dir -NoNewWindow -PassThru -ErrorAction Stop `
      -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-RefsFromStdin')
    $null = $p.Handle
    $p.WaitForExit()
    $code = $p.ExitCode
    $lines = @()
    if (Test-Path -LiteralPath $outF) { $lines = @([IO.File]::ReadAllLines($outF) | Where-Object { $_.Trim() }) }
    foreach ($l in $lines) { if ($l -notmatch '^PREPUSH-TEST-AUDITORS-COMPLETE') { Say ('  ' + $l) } }
    if ($null -eq $code) { return [pscustomobject]@{ Ran = $true; Code = 3; Why = 'the test-auditors check ran but its exit code could not be read' } }
    $complete = ($lines.Count -gt 0) -and ([string]$lines[$lines.Count - 1] -match '^PREPUSH-TEST-AUDITORS-COMPLETE')
    if ([int]$code -eq 0 -and -not $complete) { return [pscustomobject]@{ Ran = $true; Code = 3; Why = 'the test-auditors check exited 0 without its completion marker, so it decided nothing' } }
    $why = $(if ([int]$code -eq 1) { 'the test-auditors check refused this push' } else { '' })
    return [pscustomobject]@{ Ran = $true; Code = [int]$code; Why = $why }
  } catch {
    return [pscustomobject]@{ Ran = $false; Code = 3; Why = ('the test-auditors check could not be started: ' + $_.Exception.Message) }
  } finally {
    foreach ($x in @($inF, $outF, $errF)) { if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue } }
  }
}

function Invoke-TcRehearsalForPush {
  <# ops\rehearse-chain.ps1 -ForPush, outside the push lock: Code 0 allow, 1 refuse, 3 could not rehearse. A checkout older
     than the harness has none and is not asked, as an older checkout without hold-push-lock pushes unlocked. An exit 0
     without the completion marker as the last line decided nothing and is 3. #>
  param([string]$Dir, [string]$Remote, [string]$Branch)
  $rh = Join-Path $Dir 'ops\rehearse-chain.ps1'
  if (-not (Test-Path -LiteralPath $rh)) { return [pscustomobject]@{ Code = 0; Why = 'this checkout has no ops\rehearse-chain.ps1, so no rehearsal is asked' } }
  $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $rh -ForPush -Remote $Remote -Branch $Branch)
  $code = $LASTEXITCODE
  foreach ($l in $out) { Say ([string]$l) }
  $last = [string]($out | Select-Object -Last 1)
  if ($code -eq 0 -and $last -notmatch '^CHAIN-REHEARSAL-CHECK-COMPLETE') { $code = 3 }
  return [pscustomobject]@{ Code = $code; Why = $last }
}

function Get-TcWarmRefLine {
  <# The ref line git hands pre-push for this push, as push-main will make it: the local HEAD over the remote ref's
     last-fetched sha. '' when either cannot be read, which the caller treats as could-not-evaluate. #>
  param([string]$Dir, [string]$Remote, [string]$Branch)
  $h = Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'HEAD')
  $b = Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', ('refs/remotes/' + $Remote + '/' + $Branch))
  if ($h.Code -ne 0 -or $b.Code -ne 0) { return '' }
  $hs = ([string]@($h.Out)[0]).Trim(); $bs = ([string]@($b.Out)[0]).Trim()
  if (-not $hs -or -not $bs) { return '' }
  return ('HEAD ' + $hs + ' refs/heads/' + $Branch + ' ' + $bs)
}

function Invoke-TcPushMain {
  param([string]$Dir, [string]$Remote, [string]$Branch, [int]$LockWaitSec, [bool]$DryRun, [string]$LockPrefix = '', [string]$LockQueueRoot = '', [scriptblock]$GateRunner = $null, [string]$LedgerRoot = '', [string]$SeedScript = '', [scriptblock]$RehearsalRunner = $null)
  # WHAT THE REMOTE HELD BEFORE THIS PUSH QUEUED. Read here and compared with what the fetch inside the lock returns,
  # it is this wrapper's own answer to "did the remote move while I waited" - the quantity that decides whether a
  # retry can ever converge, recorded per push in lib\push-ledger.ps1 rather than re-derived from %TEMP% afterwards.
  # An unreadable ref is '' and is recorded UNKNOWN, never as a ref that stood still.
  $ledgerBase = Get-TcPushLedgerRefSha -Dir $Dir -Ref ('refs/remotes/' + $Remote + '/' + $Branch)
  $ledgerGrant = ''
  $ledgerWaitMs = -1
  $ledgerState = ''
  $outcome = 'unknown'
  $writeRow = {
    $null = Write-TcPushRow -Event 'push-main' -WaitMs $ledgerWaitMs -State $ledgerState -BaseSha $ledgerBase `
      -GrantSha $ledgerGrant -Outcome $outcome -Checkout $Dir -Root $LedgerRoot
  }
  $enter = @{ WaitSec = $LockWaitSec; PollMs = 500 }
  if ($LockPrefix) { $enter['Prefix'] = $LockPrefix }
  if ($LockQueueRoot) { $enter['QueueRoot'] = $LockQueueRoot }
  $enter['OnWait'] = { param($ahead) Say ("push-main: {0} push(es) are ahead of this one on this box, and the lock is served in arrival order - waiting." -f $ahead) }

  # ---- THE GATE RUNS BEFORE THE LOCK IS TAKEN (Brad, 2026-09-12) ----
  # The lock serialises pushes machine-wide, and until now the ~10-minute gate ran INSIDE it, so the box could land
  # about six pushes an hour however many sessions were working: measured that morning at 9 pushes queued, the oldest
  # 47 minutes, while only 2 gates ran on a 32-core box and the ref update itself took 2 seconds. Serialising the PUSH
  # costs nothing, because refs/heads/main is serialised already; serialising the GATE costs everything, because
  # gating is the part that can run in parallel and has its own 10-slot budget to bound it.
  # Running it here is not a second gate and weakens nothing: the hook still gates inside the lock, and a red gate
  # there still refuses. What this buys is that the hook's run is WARM - lib\gate-verdict.ps1 replays the whole
  # verdict when the rebase changed nothing, and the per-gate input keys re-run only the gates whose own inputs the
  # rebase brought in - so the lock is held for seconds rather than minutes.
  # A RED GATE NEVER QUEUES. Before this, a push that was going to fail took the lock, held it for its whole run and
  # blocked every other session on the box before refusing. It now refuses without ever entering the queue.
  # A 3 IS NOT A REFUSAL AND NOT A PASS. Exit 3 is could-not-evaluate, which on this box is usually slot contention,
  # so this degrades to exactly the behaviour of the day before: take the lock and let the hook be the gate.
  # The default runner is BOTH hook legs: run-gates, then (only on a pass) the test-auditors check with this push's own
  # ref line, so its keyed pass is recorded before the lock and the in-lock leg can reuse it (queue 2026-09-18-1139a0).
  $runner = $(if ($GateRunner) { $GateRunner } else { {
    param($d)
    $wg = Invoke-TcWarmGate -Dir $d
    if (-not ($wg.Ran -and $wg.Code -eq 0)) { return $wg }
    $wt = Invoke-TcWarmTestAuditors -Dir $d -RefLine (Get-TcWarmRefLine -Dir $d -Remote $Remote -Branch $Branch)
    if ($wt.Code -ne 0) { return $wt }
    return $wg
  } })
  # SEEDED FIRST, so neither leg of the gate below judges a checkout that has no built cards (backlog I237).
  $null = Invoke-TcSeedIfUnseeded -Dir $Dir -Seeder $SeedScript
  $g = & $runner $Dir
  if ($g.Ran -and $g.Code -eq 1) {
    $redWhy = $(if ($g.Why) { [string]$g.Why } else { 'run-gates exited 1' })
    Say ("push-main: REFUSED - {0} before the lock was taken, so this push never entered the queue and nothing else on this box was held up. Fix the cause and run this again." -f $redWhy)
    $outcome = 'refused-gate-red'; $ledgerState = 'not-taken'
    & $writeRow
    return 1
  }
  if ($g.Code -ne 0) {
    Say ("push-main: the gate did not settle outside the lock ({0}), so it is left to the hook inside the lock, gated exactly as before.{1}" -f $g.Code, $(if ($g.Why) { ' ' + $g.Why } else { '' }))
  } else {
    Say 'push-main: gate PASSED outside the lock, so the lock is taken only for the fetch, the rebase and the ref update.'
  }

  # ---- THE CHAIN REHEARSAL, ALSO BEFORE THE LOCK (2026-09-22, RCA F2, plan-2026-09-22-7) ----
  # A push that changes a script in ops\chain-manifest.json must carry a rehearsal over recent real data, and the rehearsal
  # takes the chain's own time (about 14 minutes), so it runs HERE, unlocked, for the reason the gate does. The hook inside
  # the lock only reads the recorded verdict. 1 = rehearsed and failed (or no verdict could be made to pass), 3 = could not
  # rehearse with its blind= cause; both refuse before the queue, and neither is ever read as a pass.
  $rh = $(if ($RehearsalRunner) { & $RehearsalRunner $Dir } else { Invoke-TcRehearsalForPush -Dir $Dir -Remote $Remote -Branch $Branch })
  if ($rh.Code -ne 0) {
    Say ("push-main: REFUSED before the lock - {0}. The rehearsal lines above say which stage or cause. Rehearse again, or push with -NoRehearsal -NoRehearsalReason '<why>' to bypass loudly." -f $(if ($rh.Code -eq 3) { 'the chain rehearsal COULD NOT EVALUATE (exit 3), which is never a pass' } else { 'this push changes the daily chain and has no passing rehearsal (exit ' + $rh.Code + ')' }))
    $outcome = $(if ($rh.Code -eq 3) { 'refused-rehearsal-blind' } else { 'refused-rehearsal' }); $ledgerState = 'not-taken'
    & $writeRow
    return $rh.Code
  }

  $lock = Enter-TcPushLock @enter
  $ledgerWaitMs = [double]$lock.WaitedMs
  $ledgerState = $(if (-not $lock.Held) { 'unlocked' } elseif ($lock.Inherited) { 'inherited' } else { 'held' })
  if (-not $lock.Held) {
    # STILL NOT A REFUSAL. The lock is a fairness device; without it this push is exactly as gated as it ever was and
    # merely races for the ref, which is what every push did before the lock existed.
    Say ("push-main: the push lock was NOT taken - {0}. Pushing anyway: this push is gated identically, it just races for the ref." -f $lock.Reason)
  } elseif ($lock.Inherited) {
    Say 'push-main: an ancestor already holds the push lock, so it was not taken again.'
  } else {
    Say ("push-main: holding the machine-wide push lock after {0:N0}s - nothing else on this box can land until this push is done." -f ($lock.WaitedMs / 1000))
  }
  try {
    # INSIDE THE LOCK: fetch, decide, rebase. Nothing else can land between here and the ref update.
    $f = Invoke-TcGit -Dir $Dir -Arguments @('fetch', '--quiet', $Remote, $Branch)
    if ($f.Code -ne 0) {
      Say ("push-main: COULD NOT EVALUATE - `git fetch {0} {1}` exited {2}, so what this push would land on is unknown. That is not a pass.`n{3}" -f $Remote, $Branch, $f.Code, $f.Text)
      $outcome = 'blind-fetch-failed'
      return 3
    }
    $head = ([string](Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'HEAD')).Out[0]).Trim()
    $rem = ([string](Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'FETCH_HEAD')).Out[0]).Trim()
    # WHAT THE REMOTE HOLDS NOW, read under the lock. Against $ledgerBase above it says whether the remote moved
    # while this push queued - recorded whatever happens next, including on the paths that refuse.
    $ledgerGrant = $rem
    $mbR = Invoke-TcGit -Dir $Dir -Arguments @('merge-base', 'HEAD', $rem)
    $mb = $(if ($mbR.Code -eq 0 -and $mbR.Out.Count) { ([string]$mbR.Out[0]).Trim() } else { '' })
    $cntR = Invoke-TcGit -Dir $Dir -Arguments @('rev-list', '--count', ($rem + '..HEAD'))
    $ahead = $(if ($cntR.Code -eq 0 -and $cntR.Out.Count) { [int]([string]$cntR.Out[0]).Trim() } else { 0 })
    # --no-optional-locks IS A GLOBAL OPTION and must come BEFORE the subcommand, so taking a status never takes the
    # index lock a session's own commit needs. After `status` git rejects it as unknown - which this file did until
    # the streams were separated, when the rejection stopped counting as a changed path and a dirty checkout was
    # pushed. Two bugs that had been cancelling each other out.
    $st = Invoke-TcGit -Dir $Dir -Arguments @('--no-optional-locks', 'status', '--porcelain')
    $dirty = [bool](@($st.Out | Where-Object { $_.Trim() }).Count)
    $plan = Get-TcPushPlan -Head $head -RemoteSha $rem -MergeBase $mb -Ahead $ahead -Dirty $dirty
    if (-not $plan.Ready) {
      Say ("push-main: REFUSED - {0}" -f $plan.Reason)
      $outcome = 'refused-not-ready'
      return 1
    }
    Say ("push-main: {0} commit(s) to land on {1}/{2}; {3}." -f $ahead, $Remote, $Branch, $plan.Reason)
    if ($plan.NeedsRebase) {
      $rb = Invoke-TcGit -Dir $Dir -Arguments @('rebase', $rem)
      if ($rb.Code -ne 0) {
        # THE BRANCH IS LEFT EXACTLY WHERE IT WAS. A half-finished rebase under a lock is the worst thing this could
        # hand back, because the next session to push inherits it.
        $null = Invoke-TcGit -Dir $Dir -Arguments @('rebase', '--abort')
        Say ("push-main: REFUSED - the rebase onto {0}/{1} conflicts, so it was aborted and this branch is exactly where it was. Resolve it and run this again.`n{2}" -f $Remote, $Branch, $rb.Text)
        $outcome = 'refused-rebase-conflict'
        return 1
      }
      $head = ([string](Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'HEAD')).Out[0]).Trim()
      Say ("push-main: rebased onto {0}; HEAD is now {1}." -f $rem.Substring(0, 9), $head.Substring(0, 9))
    }
    if ($DryRun) {
      Say 'push-main: -DryRun, so nothing was pushed. Everything up to the push was done under the lock.'
      $outcome = 'dry-run'
      return 0
    }
    # A PLAIN PUSH: the pre-push hook runs, the gate runs, and a red gate refuses this exactly as it refuses any other
    # push. --no-verify is not passed and is not an option here.
    $p = Invoke-TcGit -Dir $Dir -Arguments @('push', $Remote, ('HEAD:refs/heads/' + $Branch))
    Say $p.Text
    if ($p.Code -ne 0) {
      Say ("push-main: the push did NOT land (git exited {0}). Nothing here overrides that; read the reason above." -f $p.Code)
      $outcome = 'push-rejected'
      return 1
    }
    Say ("push-main: LANDED on {0}/{1} at {2}, on the first attempt." -f $Remote, $Branch, $head.Substring(0, 9))
    $outcome = $(if ($plan.NeedsRebase) { 'landed-after-rebase' } else { 'landed' })
    return 0
  } finally {
    # THE LOCK GOES BACK FIRST, then the row is written: a ledger write must never sit inside the critical section
    # this whole file exists to keep short, and nothing reads the row to decide anything.
    Exit-TcPushLock $lock
    & $writeRow
  }
}

if ($SelfTest) {
  $f = 0; $cases = 0
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  function T($m, $cond, $got) {
    $script:cases++
    if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ }
  }
  # THE PLAN IS DRIVEN ON FIXED INPUTS, so every branch has a case without needing a remote to be in that state.
  $A = '1111111111111111111111111111111111111111'
  $B = '2222222222222222222222222222222222222222'
  $C = '3333333333333333333333333333333333333333'
  T ($kMF + '  a dirty working tree is refused, and the reason names the index rather than just saying dirty') `
    ((-not (Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase $B -Ahead 1 -Dirty $true).Ready) -and ((Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase $B -Ahead 1 -Dirty $true).Reason -match 'index')) 'a dirty tree was allowed'
  T ($kMF + '  a HEAD equal to the remote is refused as nothing to push') `
    (-not (Get-TcPushPlan -Head $A -RemoteSha $A -MergeBase $A -Ahead 0 -Dirty $false).Ready) 'an empty push was allowed'
  T ($kMF + '  a branch with no commits the remote lacks is refused') `
    (-not (Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase $B -Ahead 0 -Dirty $false).Ready) 'a push with nothing ahead was allowed'
  T ($kMF + '  a remote that could not be read is refused, never treated as an empty remote') `
    (-not (Get-TcPushPlan -Head $A -RemoteSha '' -MergeBase '' -Ahead 1 -Dirty $false).Ready) 'an unreadable remote was treated as readable'
  T ($kMNF + '  a branch sitting on exactly what the remote holds is ready and is NOT rebased') `
    ((Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase $B -Ahead 2 -Dirty $false).Ready -and -not (Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase $B -Ahead 2 -Dirty $false).NeedsRebase) 'a needless rebase was planned'
  T ($kMF + '  a branch whose base the remote has moved past is rebased') `
    ((Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase $C -Ahead 2 -Dirty $false).NeedsRebase) 'a stale base was not rebased'
  # THE EMPTY MERGE-BASE. `git merge-base` prints nothing and exits 1 for unrelated histories, and reading that as
  # "not equal to the remote sha" made it a REBASE - replaying an unrelated history onto main and pushing it.
  $unrel = Get-TcPushPlan -Head $A -RemoteSha $B -MergeBase '' -Ahead 2 -Dirty $false
  T ($kMF + '  a branch sharing no ancestor with the remote is refused, and is never rebased onto it') `
    ((-not $unrel.Ready) -and (-not $unrel.NeedsRebase) -and $unrel.Reason -match 'no common ancestor') ("ready={0} needsRebase={1} reason={2}" -f $unrel.Ready, $unrel.NeedsRebase, $unrel.Reason)

  # ---- the test-auditors leg outside the lock (queue 2026-09-18-1139a0), driven through fixture scripts ----
  # Founding case: 2026-09-18, a 389 s test-auditors run held the push lock because no pass was recorded before it.
  $taDir = Join-Path $env:TEMP ('tc-pm-ta-st-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $taDir
  try {
    $taSeen = Join-Path $taDir 'stdin-seen.txt'
    $taRed = Join-Path $taDir 'ta-red.ps1'
    $taGreen = Join-Path $taDir 'ta-green.ps1'
    $taBare = Join-Path $taDir 'ta-nomarker.ps1'
    [IO.File]::WriteAllText($taRed, "Write-Output 'prepush-test-auditors: REFUSED - a new failing case'`nWrite-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=1'`nexit 1`n")
    [IO.File]::WriteAllText($taGreen, ("`$in = [Console]::In.ReadToEnd()`n[IO.File]::WriteAllText('" + $taSeen + "', `$in)`nWrite-Output 'prepush-test-auditors: PASS'`nWrite-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n"))
    [IO.File]::WriteAllText($taBare, "Write-Output 'prepush-test-auditors: started'`nexit 0`n")
    $taLine = 'HEAD ' + $A + ' refs/heads/main ' + $B
    $tr = Invoke-TcWarmTestAuditors -Dir $taDir -RefLine $taLine -Script $taRed
    T ($kMF + '  a test-auditors check that refuses outside the lock refuses the push (Code 1), so it never queues') `
      ($tr.Ran -and $tr.Code -eq 1 -and $tr.Why -match 'test-auditors') ("ran={0} code={1} why={2}" -f $tr.Ran, $tr.Code, $tr.Why)
    $tg = Invoke-TcWarmTestAuditors -Dir $taDir -RefLine $taLine -Script $taGreen
    $seen = if (Test-Path -LiteralPath $taSeen) { ([IO.File]::ReadAllText($taSeen)).Trim() } else { '<no stdin recorded>' }
    T ($kCT + '  a passing check is Code 0 AND it was handed the exact ref line the hook will hand it, so its keyed pass is the one the in-lock run looks up') `
      ($tg.Ran -and $tg.Code -eq 0 -and [string]::Equals($seen, $taLine, [StringComparison]::Ordinal)) ("ran={0} code={1} stdin='{2}'" -f $tg.Ran, $tg.Code, $seen)
    $tb = Invoke-TcWarmTestAuditors -Dir $taDir -RefLine $taLine -Script $taBare
    T ($kMF + '  an exit 0 with no completion marker is could-not-evaluate (3), never a pass') `
      ($tb.Code -eq 3 -and $tb.Why -match 'marker') ("code={0} why={1}" -f $tb.Code, $tb.Why)
    $tn = Invoke-TcWarmTestAuditors -Dir $taDir -RefLine '' -Script $taGreen
    T ($kMF + '  a ref line that could not be formed is could-not-evaluate (3), and the check is not run on a guess') `
      ($tn.Code -eq 3 -and -not $tn.Ran) ("ran={0} code={1}" -f $tn.Ran, $tn.Code)
  } finally {
    Remove-Item -LiteralPath $taDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ---- the whole thing, against real repositories ----
  $tmp = Join-Path $env:TEMP ('tc-pm-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $tmp
  $prefix = 'Local\tc-push-main-selftest-' + [guid]::NewGuid().ToString('N') + '-'
  $qroot = Join-Path $tmp 'q'
  # EVERY CASE INJECTS ITS GATE. Without this each fixture below would launch the real ops\run-gates.ps1 - hundreds of
  # seconds, the 24 machine-wide slots, from a suite that run-gates itself runs. The seam is what makes the ORDER
  # assertable at all: $gateSawLock records whether the push lock was free at the moment the gate ran, which is the
  # mechanism this change is about and cannot be read from a clock.
  #
  # THE PROBE MUST RUN IN ANOTHER PROCESS, and the first version of this case did not - it SURVIVED the mutant that
  # hoists the lock back above the gate (2026-09-12, measured: mutant exit 0, the case still ok). A Windows mutex is
  # REENTRANT ON ITS OWNING THREAD, so a probe calling Enter-TcPushLock from inside this same process is handed the
  # lock the caller is already holding and reports it free either way. `-NoInherit` does not help: that governs the
  # token a descendant reads, not the kernel object's own thread affinity. This is the estate's insensitive-fixture
  # shape - a live case, a true assertion, and no ability to see which half was working.
  $probeScript = Join-Path $tmp 'lockprobe.ps1'
  [IO.File]::WriteAllText($probeScript, @'
param([string]$Name)
$m = $null
try { $m = [System.Threading.Mutex]::OpenExisting($Name) } catch { Write-Output 'FREE'; exit 0 }
$got = $m.WaitOne(0)
if ($got) { $m.ReleaseMutex(); Write-Output 'FREE' } else { Write-Output 'HELD' }
$m.Dispose()
'@)
  $script:gateSawLock = $null
  $script:gateRuns = 0
  $okGate = {
    param($d)
    $script:gateRuns++
    # NO `2>$null` HERE. Under EAP=Stop a native child's first stderr line becomes a terminating throw, which is what
    # grocery\test-native-stderr-eap.ps1 ratchets - and this probe's whole job is to report what it saw, so a redirect
    # that could swallow the reason it could not look is the last thing it should carry.
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -Name ($prefix + '0'))
    $script:gateSawLock = [bool](@($out | Where-Object { "$_".Trim() -eq 'FREE' }).Count)
    return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' }
  }
  $redGate = { param($d) $script:gateRuns++; return [pscustomobject]@{ Ran = $true; Code = 1; Why = '' } }
  $blindGate = { param($d) $script:gateRuns++; return [pscustomobject]@{ Ran = $true; Code = 3; Why = 'no gate worker slot' } }

  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  # EVERY CASE IN THIS SUITE WRITES ITS LEDGER ROWS TO SCRATCH (2026-09-12). The cases that do not pass -LedgerRoot
  # push temp CLONES, so before this redirect existed their rows - real shas, real waits, from repositories that
  # exist for a second - went into the production ledger and were counted by the first live convergence report.
  # A default that reaches a real path is redirected suite-wide, never per fixture.
  $prodLedger = Get-TcPushLedgerPath
  $ledgerRootWas = $env:TC_PUSH_LEDGER_ROOT
  $env:TC_PUSH_LEDGER_ROOT = Join-Path $tmp 'suite-ledger'
  # AND EVERY ROW IT WRITES CARRIES THIS RUN'S ID, which is what the production check below filters on - never this
  # process's pid, which Windows recycles within the day the production file covers (backlog I171). Exported, so a
  # row written by a child of these cases carries it too.
  $runWas = $env:TC_PUSH_LEDGER_RUN
  $suiteRun = New-TcPushLedgerRunId
  $env:TC_PUSH_LEDGER_RUN = $suiteRun
  try {
    Clear-TcGitRepoEnv
    $origin = Join-Path $tmp 'origin'
    $null = & git init -q --bare $origin 2>$null
    $script:cloneFails = 0
    function New-Clone([string]$Name) {
      $d = Join-Path $tmp $Name
      $null = & git clone -q $origin $d 2>$null
      $null = & git -C $d config user.name Probe 2>$null
      $null = & git -C $d config user.email p@p 2>$null
      # A CLONE THAT CAME UP EMPTY IS NAMED, NEVER USED. `git init --bare` points HEAD at the branch named by
      # init.defaultBranch, and this seed pushes `main`; when those differ, clone finds the remote HEAD pointing at a
      # ref that does not exist, checks nothing out, and leaves an unborn branch. Every commit made in it is then a
      # ROOT commit sharing no ancestor with main - which is exactly how five cases here passed or failed for reasons
      # that had nothing to do with the code. The fix is the symbolic-ref below; this is the assertion that the fix
      # held, so a fixture running against empty clones can never read as a result.
      $n = @(& git -C $d rev-list --count HEAD 2>$null)
      if (-not $n.Count -or [int]([string]$n[0]).Trim() -lt 1) { $script:cloneFails++ }
      return $d
    }
    $seed = Join-Path $tmp 'seed'
    $null = & git init -q $seed 2>$null
    $null = & git -C $seed config user.name Probe 2>$null
    $null = & git -C $seed config user.email p@p 2>$null
    [IO.File]::WriteAllText((Join-Path $seed 'seed.txt'), 'seed')
    $null = & git -C $seed add -- seed.txt 2>$null
    $null = & git -C $seed commit -q -m seed 2>$null
    $null = & git -C $seed branch -M main 2>$null
    $null = & git -C $seed remote add origin $origin 2>$null
    $null = & git -C $seed push -q origin main 2>$null
    # The bare repository's HEAD must name the branch it actually has, or every clone below comes up empty - see the
    # account in New-Clone.
    $null = & git -C $origin symbolic-ref HEAD refs/heads/main 2>$null

    # ---- SEEDED BEFORE THE GATE (backlog I237) ----
    # Founding case: 2026-09-18, a fresh worktree's first push-main was refused by the warm test-auditors leg over
    # feed-covers-published's BLIND verdict, because nothing seeded the checkout before the gate outside the lock.
    # The gate seam records whether the seed directory held a file when the gate ran: the ORDER, read from the
    # mechanism. The stub seeder declares its own one-directory list, which is what push-main reads to decide.
    $sdList = '$SEED' + '_DIRS = @( @{ p = ''seedfx\cards''; why = ''fixture'' } )'
    $sdStub = Join-Path $tmp 'seed-stub.ps1'
    $sdFail = Join-Path $tmp 'seed-fail.ps1'
    $sdBody = @(
      'Add-Content -LiteralPath (Join-Path $Target ''seeded-for.txt'') -Value $Target',
      '$d = Join-Path $Target ''seedfx\cards''',
      '$null = New-Item -ItemType Directory -Force $d',
      '[IO.File]::WriteAllText((Join-Path $d ''one.card''), ''card'')',
      'exit 0') -join "`n"
    [IO.File]::WriteAllText($sdStub, ("param([string]`$Target)`n" + $sdList + "`n" + $sdBody + "`n"))
    [IO.File]::WriteAllText($sdFail, ("param([string]`$Target)`n" + $sdList + "`nexit 1`n"))
    $script:cardAtGate = $null
    $cardGate = { param($d) $script:cardAtGate = Test-Path -LiteralPath (Join-Path $d 'seedfx\cards\one.card'); return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $s1 = New-Clone 's1'
    Add-Content -LiteralPath (Join-Path $s1 '.git\info\exclude') -Value @('seeded-for.txt', 'seedfx/') -Encoding ascii   # gitignored in the real repo
    [IO.File]::WriteAllText((Join-Path $s1 's1.txt'), 's1')
    $null = & git -C $s1 add -- s1.txt 2>$null; $null = & git -C $s1 commit -q -m s1 2>$null
    $rS1 = Invoke-TcPushMain -Dir $s1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $cardGate -SeedScript $sdStub
    $sFor = if (Test-Path -LiteralPath (Join-Path $s1 'seeded-for.txt')) { ([IO.File]::ReadAllText((Join-Path $s1 'seeded-for.txt'))).Trim() } else { '<not seeded>' }
    T ($kMF + '  a checkout with nothing in a directory the seeder seeds is seeded, with -Target naming it, BEFORE the gate runs') `
      ($rS1 -eq 0 -and $script:cardAtGate -eq $true -and [string]::Equals($sFor, $s1, [StringComparison]::OrdinalIgnoreCase)) ("rc={0} cardAtGate={1} seededFor={2}" -f $rS1, $script:cardAtGate, $sFor)
    Remove-Item -LiteralPath (Join-Path $s1 'seeded-for.txt') -Force -ErrorAction SilentlyContinue
    $rS2 = Invoke-TcSeedIfUnseeded -Dir $s1 -Seeder $sdStub
    T ($kMNF + '  a checkout whose seed directories already hold files is not seeded again') `
      ((-not $rS2.Ran) -and -not (Test-Path -LiteralPath (Join-Path $s1 'seeded-for.txt'))) ("ran={0} why={1}" -f $rS2.Ran, $rS2.Why)
    $s3 = New-Clone 's3'
    Add-Content -LiteralPath (Join-Path $s3 '.git\info\exclude') -Value @('seeded-for.txt', 'seedfx/') -Encoding ascii   # gitignored in the real repo
    [IO.File]::WriteAllText((Join-Path $s3 's3.txt'), 's3')
    $null = & git -C $s3 add -- s3.txt 2>$null; $null = & git -C $s3 commit -q -m s3 2>$null
    $script:gateRuns = 0
    $rS3 = Invoke-TcPushMain -Dir $s3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -SeedScript $sdFail
    T ($kCT + '  a seed that fails is best effort: the gate still runs and the push still proceeds') `
      ($rS3 -eq 0 -and $script:gateRuns -eq 1) ("rc={0} gateRuns={1}" -f $rS3, $script:gateRuns)
    # THE CHAIN REHEARSAL LEG (2026-09-22, plan-2026-09-22-7): it runs after a green gate and before the lock, and a
    # failed or could-not-run rehearsal refuses there with its own code; the runner is the seam, as the gate's is.
    $rhRed = { param($d) [pscustomobject]@{ Code = 1; Why = 'fixture: the rehearsal failed at stage commit' } }
    $rhBlind = { param($d) [pscustomobject]@{ Code = 3; Why = 'fixture: blind=no-seed-board' } }
    $rhGreen = { param($d) [pscustomobject]@{ Code = 0; Why = 'fixture: rehearsed-pass' } }
    $script:gateRuns = 0
    $rR1 = Invoke-TcPushMain -Dir $s3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -SeedScript $sdFail -RehearsalRunner $rhRed
    T ($kMF + '  a push whose chain rehearsal FAILED is refused (1) before the lock, after its gate ran once') `
      ($rR1 -eq 1 -and $script:gateRuns -eq 1) ("rc={0} gateRuns={1}" -f $rR1, $script:gateRuns)
    $rR2 = Invoke-TcPushMain -Dir $s3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -SeedScript $sdFail -RehearsalRunner $rhBlind
    T ($kMNF + '  a rehearsal that could not run is exit 3, never a pass and never read as a red') ($rR2 -eq 3) ("rc={0}" -f $rR2)
    $rR3 = Invoke-TcPushMain -Dir $s3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -SeedScript $sdFail -RehearsalRunner $rhGreen
    T ($kCT + '  a passing rehearsal lets the push go on to the lock exactly as before') ($rR3 -eq 0) ("rc={0}" -f $rR3)
    $rR4 = Invoke-TcRehearsalForPush -Dir $s3 -Remote 'origin' -Branch 'main'
    T ($kMNF + '  a checkout with no ops\rehearse-chain.ps1 is not asked for a rehearsal (the older-checkout rule)') ($rR4.Code -eq 0) ("code={0} why={1}" -f $rR4.Code, $rR4.Why)

    $a = New-Clone 'a'
    [IO.File]::WriteAllText((Join-Path $a 'a.txt'), 'a')
    $null = & git -C $a add -- a.txt 2>$null; $null = & git -C $a commit -q -m a 2>$null
    $r1 = Invoke-TcPushMain -Dir $a -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate
    $remA = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    $headA = ([string](@(& git -C $a rev-parse HEAD 2>$null))[0]).Trim()
    T ($kMNF + '  a clean branch on a current base lands on its first attempt') `
      ($r1 -eq 0 -and $remA -eq $headA) ("rc={0} remote={1} head={2}" -f $r1, $remA, $headA)

    # MAIN MOVES UNDER A SECOND CHECKOUT: the reported failure's exact shape.
    $b = New-Clone 'b'
    [IO.File]::WriteAllText((Join-Path $b 'b.txt'), 'b')
    $null = & git -C $b add -- b.txt 2>$null; $null = & git -C $b commit -q -m b 2>$null
    $c = New-Clone 'c'
    [IO.File]::WriteAllText((Join-Path $c 'c.txt'), 'c')
    $null = & git -C $c add -- c.txt 2>$null; $null = & git -C $c commit -q -m c 2>$null
    $null = & git -C $c push -q origin HEAD:main 2>$null      # c lands while b is still holding a stale base
    $r2 = Invoke-TcPushMain -Dir $b -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate
    $remB = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    $headB = ([string](@(& git -C $b rev-parse HEAD 2>$null))[0]).Trim()
    $hasC = @(& git -C $b log --oneline 2>$null) -match ' c$'
    T ($kMF + '  a branch whose base the remote moved past is rebased under the lock and still lands on its first attempt') `
      ($r2 -eq 0 -and $remB -eq $headB -and @($hasC).Count -ge 1) ("rc={0} remote={1} head={2} carriesC={3}" -f $r2, $remB, $headB, @($hasC).Count)

    # A DIRTY TREE IS REFUSED, and the branch is not touched.
    $d2 = New-Clone 'd'
    [IO.File]::WriteAllText((Join-Path $d2 'd.txt'), 'd')
    $null = & git -C $d2 add -- d.txt 2>$null; $null = & git -C $d2 commit -q -m d 2>$null
    [IO.File]::WriteAllText((Join-Path $d2 'dirty.txt'), 'uncommitted')
    $headD0 = ([string](@(& git -C $d2 rev-parse HEAD 2>$null))[0]).Trim()
    $r3 = Invoke-TcPushMain -Dir $d2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate
    $headD1 = ([string](@(& git -C $d2 rev-parse HEAD 2>$null))[0]).Trim()
    T ($kMF + '  a dirty checkout is refused and its branch is left exactly where it was') `
      ($r3 -eq 1 -and $headD0 -eq $headD1) ("rc={0} before={1} after={2}" -f $r3, $headD0, $headD1)

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
    [IO.File]::WriteAllText((Join-Path $n1 'clash2.txt'), 'mine')
    $null = & git -C $n1 add -- clash2.txt 2>$null; $null = & git -C $n1 commit -q -m mine2 2>$null
    $n2 = New-Clone 'n2'
    [IO.File]::WriteAllText((Join-Path $n2 'clash2.txt'), 'theirs')
    $null = & git -C $n2 add -- clash2.txt 2>$null; $null = & git -C $n2 commit -q -m theirs2 2>$null
    $null = & git -C $n2 push -q origin HEAD:main 2>$null
    $rRef = Invoke-TcPushMain -Dir $n1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $okGate -LedgerRoot $ledRoot2
    $refRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRoot2)
    $refRows = @($refRaw)
    T ($kMF + '  a push refused because its rebase conflicts records that refusal by name, so the ledger is not just the pushes that landed') `
      ($rRef -eq 1 -and $refRows.Count -eq 1 -and $refRows[0].outcome -eq 'refused-rebase-conflict') `
      ("rc={0} rows={1} outcome={2}" -f $rRef, $refRows.Count, $(if ($refRows.Count) { $refRows[0].outcome } else { '' }))

    T ($kMNF + '  every clone these cases ran against carried the seeded history, so none of them judged an empty repository') `
      ($script:cloneFails -eq 0) ("clonesThatCameUpEmpty={0}" -f $script:cloneFails)
    $freeNow = Enter-TcPushLock -Prefix $prefix -QueueRoot $qroot -WaitSec 5 -PollMs 50 -NoInherit
    T ($kCT + '  every one of those runs handed the push lock back, including the refusals') ($freeNow.Held) ("held={0}" -f $freeNow.Held)
    Exit-TcPushLock $freeNow

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
  } finally {
    $ErrorActionPreference = $prev
    if ($null -eq $runWas) {
      Remove-Item -LiteralPath Env:TC_PUSH_LEDGER_RUN -ErrorAction SilentlyContinue
    } else {
      $env:TC_PUSH_LEDGER_RUN = $runWas
    }
    if ($null -eq $ledgerRootWas) {
      Remove-Item -LiteralPath Env:TC_PUSH_LEDGER_ROOT -ErrorAction SilentlyContinue
    } else {
      $env:TC_PUSH_LEDGER_ROOT = $ledgerRootWas
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($f) { Write-Output ("push-main self-test FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("push-main self-test PASS: {0} cases - led by a branch whose base the remote moved past landing on its FIRST attempt, and by a conflicting rebase being aborted rather than left half-finished under the lock" -f $cases)
  exit 0
}

if ($NoRehearsal) {
  $env:TC_NO_REHEARSAL = $(if ($NoRehearsalReason) { $NoRehearsalReason } else { 'push-main -NoRehearsal, no reason given' })
  Say ('push-main: *** -NoRehearsal *** this push skips the chain rehearsal; the hook will print it and the bypass is logged. Reason: ' + $env:TC_NO_REHEARSAL)
}
$rc = Invoke-TcPushMain -Dir $repo -Remote $Remote -Branch $Branch -LockWaitSec $LockWaitSec -DryRun ([bool]$DryRun)
exit $rc
