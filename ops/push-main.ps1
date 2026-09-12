<#
  push-main.ps1 - push to main so that it LANDS: take the machine-wide push lock first, then rebase, then gate, then
  push, all inside it.

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
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\push-lock.ps1')
. (Join-Path $repo 'lib\git-repo-env.ps1')

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

function Invoke-TcPushMain {
  param([string]$Dir, [string]$Remote, [string]$Branch, [int]$LockWaitSec, [bool]$DryRun, [string]$LockPrefix = '', [string]$LockQueueRoot = '')
  $enter = @{ WaitSec = $LockWaitSec; PollMs = 500 }
  if ($LockPrefix) { $enter['Prefix'] = $LockPrefix }
  if ($LockQueueRoot) { $enter['QueueRoot'] = $LockQueueRoot }
  $enter['OnWait'] = { param($ahead) Say ("push-main: {0} push(es) are ahead of this one on this box, and the lock is served in arrival order - waiting." -f $ahead) }
  $lock = Enter-TcPushLock @enter
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
      return 3
    }
    $head = ([string](Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'HEAD')).Out[0]).Trim()
    $rem = ([string](Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'FETCH_HEAD')).Out[0]).Trim()
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
        return 1
      }
      $head = ([string](Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'HEAD')).Out[0]).Trim()
      Say ("push-main: rebased onto {0}; HEAD is now {1}." -f $rem.Substring(0, 9), $head.Substring(0, 9))
    }
    if ($DryRun) {
      Say 'push-main: -DryRun, so nothing was pushed. Everything up to the push was done under the lock.'
      return 0
    }
    # A PLAIN PUSH: the pre-push hook runs, the gate runs, and a red gate refuses this exactly as it refuses any other
    # push. --no-verify is not passed and is not an option here.
    $p = Invoke-TcGit -Dir $Dir -Arguments @('push', $Remote, ('HEAD:refs/heads/' + $Branch))
    Say $p.Text
    if ($p.Code -ne 0) {
      Say ("push-main: the push did NOT land (git exited {0}). Nothing here overrides that; read the reason above." -f $p.Code)
      return 1
    }
    Say ("push-main: LANDED on {0}/{1} at {2}, on the first attempt." -f $Remote, $Branch, $head.Substring(0, 9))
    return 0
  } finally {
    Exit-TcPushLock $lock
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

  # ---- the whole thing, against real repositories ----
  $tmp = Join-Path $env:TEMP ('tc-pm-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $null = New-Item -ItemType Directory -Force -ErrorAction Stop $tmp
  $prefix = 'Local\tc-push-main-selftest-' + [guid]::NewGuid().ToString('N') + '-'
  $qroot = Join-Path $tmp 'q'
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
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

    $a = New-Clone 'a'
    [IO.File]::WriteAllText((Join-Path $a 'a.txt'), 'a')
    $null = & git -C $a add -- a.txt 2>$null; $null = & git -C $a commit -q -m a 2>$null
    $r1 = Invoke-TcPushMain -Dir $a -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot
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
    $r2 = Invoke-TcPushMain -Dir $b -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot
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
    $r3 = Invoke-TcPushMain -Dir $d2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot
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
    $r4 = Invoke-TcPushMain -Dir $e -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot
    $headE1 = ([string](@(& git -C $e rev-parse HEAD 2>$null))[0]).Trim()
    $midRebase = (Test-Path -LiteralPath (Join-Path $e '.git\rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $e '.git\rebase-apply'))
    T ($kMF + '  a conflicting rebase is aborted, refused, and leaves no half-finished rebase behind') `
      ($r4 -eq 1 -and $headE0 -eq $headE1 -and -not $midRebase) ("rc={0} before={1} after={2} midRebase={3}" -f $r4, $headE0, $headE1, $midRebase)

    # NOTHING TO PUSH IS A REFUSAL, not a claimed landing.
    $h = New-Clone 'h'
    $r5 = Invoke-TcPushMain -Dir $h -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot
    T ($kMF + '  a checkout with nothing to push is refused rather than reporting a landing') ($r5 -eq 1) ("rc={0}" -f $r5)

    # -DryRun DOES EVERYTHING BUT THE PUSH, and the remote is untouched.
    $i = New-Clone 'i'
    [IO.File]::WriteAllText((Join-Path $i 'i.txt'), 'i')
    $null = & git -C $i add -- i.txt 2>$null; $null = & git -C $i commit -q -m i 2>$null
    $remBefore = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    $r6 = Invoke-TcPushMain -Dir $i -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot
    $remAfter = ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim()
    T ($kCT + '  -DryRun leaves the remote exactly where it was and still reports success') `
      ($r6 -eq 0 -and $remBefore -eq $remAfter) ("rc={0} before={1} after={2}" -f $r6, $remBefore, $remAfter)
    T ($kMNF + '  every clone these cases ran against carried the seeded history, so none of them judged an empty repository') `
      ($script:cloneFails -eq 0) ("clonesThatCameUpEmpty={0}" -f $script:cloneFails)
    $freeNow = Enter-TcPushLock -Prefix $prefix -QueueRoot $qroot -WaitSec 5 -PollMs 50 -NoInherit
    T ($kCT + '  every one of those runs handed the push lock back, including the refusals') ($freeNow.Held) ("held={0}" -f $freeNow.Held)
    Exit-TcPushLock $freeNow
  } finally {
    $ErrorActionPreference = $prev
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($f) { Write-Output ("push-main self-test FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("push-main self-test PASS: {0} cases - led by a branch whose base the remote moved past landing on its FIRST attempt, and by a conflicting rebase being aborted rather than left half-finished under the lock" -f $cases)
  exit 0
}

$rc = Invoke-TcPushMain -Dir $repo -Remote $Remote -Branch $Branch -LockWaitSec $LockWaitSec -DryRun ([bool]$DryRun)
exit $rc
