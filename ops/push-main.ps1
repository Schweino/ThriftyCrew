<#
  push-main.ps1 - push to main so that it LANDS. THE ORDER (since 2026-09-23): fetch and rebase, gate, rehearse the
  chain - all OUTSIDE the machine-wide push lock - then take the lock for a final fetch, a rebase only if origin moved
  again, and the ref update.

  BEFORE 2026-09-23 the order was gate, rehearse, THEN lock, fetch, rebase, push, so the rehearsal judged the content
  from BEFORE the rebase. Its verdict is keyed on the manifest set of the exact commit pushed (ops\rehearse-chain.ps1,
  THE VERDICT KEY), so whenever origin had moved over a manifest script the hook found no verdict for the rebased
  content, refused, and the push needed a second 13-to-15-minute rehearsal. Several landings that day paid it.
  THE TRADE-OFF THAT REMAINS: if origin changes a chain-manifest script in the window between the rebase outside the
  lock and the fetch inside it, the rehearsal no longer covers the content, so the lock is handed back and the push
  gates and rehearses again (at most $script:PmMaxRehearsalRounds rounds, then refused-rehearsal-churn). A move over
  non-manifest files keeps the verdict and lands without a second rehearsal. The cap of 6 rehearsals at once and the
  three outcomes are ops\rehearse-chain.ps1's and are unchanged.

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

  THE ORDER IS THE WHOLE POINT. The FINAL fetch happens inside the lock, and the rebase cannot go stale: nothing else
  can land between that fetch and the ref update, so the push lands on its FIRST attempt. That is the only place the guarantee
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

  EVERY RUN WRITES ONE LEDGER ROW (lib\push-ledger.ps1), and since 2026-09-23 the row says what a refusal needs, which
  code wrote it, and how many rounds of the loop above the push took (design\PLAN-push-derived-conflicts-2026-09-23.md
  W0.1, rebuilt on this loop as W0.1R). Before that a row held no conflicted file, no phase, no leg time and no refusal
  line, so 16 of 22 conflicts were reconstructed from reflogs and transcripts. A round that hands the lock back writes
  NO row: the push's one row is written when it lands or refuses, and never inside the lock. The extra fields, passed to
  Write-TcPushRow as -Fields; a field this run could not read is null, never a zero:
    schema = 2; pm_blob = `git hash-object` of this script, taken at START, before the round-1 fetch and rebase. That
      rebase can rewrite this very file on disk, so a hash taken after it would name code that is not running. It maps a
      row to the push-main commit that wrote it (about 135 checkouts each run their own copy).
    session, session_var = the first of CLAUDE_CODE_HOST_SESSION_ID and CLAUDE_CODE_SESSION_ID that is set, and which
      one (Get-TcPushSession says why that order); null for the bot, a scheduled task or a person.
    change_id = `git diff <branch_base> HEAD | git patch-id --stable`, first field; subjects_sha = SHA-256 (lower-case
      hex) of the commit subjects of branch_base..HEAD, sorted Ordinal and joined with LF, null when that range holds no
      commit; branch_base, branch_base_ts = the merge-base with refs/remotes/<remote>/<branch> and its %cI. All four are
      taken at START, before any fetch. subject_shas = one 16-hex SHA-256 prefix per DISTINCT subject of that range, sorted
      Ordinal and cut at 50, and subject_count = how many commits the range held, so a reader can link attempts whose
      subject SET moved (an amended subject, an added fix commit) by overlap; head_ref = `git symbolic-ref -q --short HEAD`,
      null when detached. All three are taken at start too (review of W0.1R, 2026-09-23).
    phase = where a refusal stopped: 'preflight' is the round-1 fetch and rebase; 'catchup' is anything before the lock
      in rounds 2 and 3 (their fetch and rebase, their legs and their rehearsal); 'inlock' is the fetch and rebase under
      the lock, a rejected push, a throw under the lock, and refused-rehearsal-churn. Null for a landing, a dry run, and a
      refusal in ROUND 1's legs, whose outcome already names where it stopped. rebase_phases = the phase of every rebase
      this run attempted, one entry per rebase, in order. preflight_sha = FETCH_HEAD at the round-1 fetch.
    conflict_files, conflict_scope = `git diff --name-only --diff-filter=U` read INSIDE Invoke-TcSyncToRemote BEFORE its
      `git rebase --abort`, which clears them, scope 'first-stop' (the commit the rebase stopped on); conflict_files_all,
      scope 'none-unmerged' beside [] when the rebase failed without stopping on a commit (an index.lock, say);
      conflict_target = the FETCH_HEAD of the sync whose rebase conflicted, which for a catch-up conflict is NOT the grant;
      conflict_all_basis = `git merge-tree --write-tree --name-only --no-messages` over the whole range, labelled
      'merge-tree-approximate' because it is one squashed merge; sibling_same_subject = main commits any rebase of this run
      brought in whose subject is Ordinal-equal to one of the branch's, short shas, first seen first; [] when a rebase was
      needed and none matched, null when none was needed.
    rounds = leg sets run; rehearsals = rehearsal legs run; rehearsed = rounds whose rehearsal leg made a NEW verdict (the
      -ForPush child printed "rehearsing HEAD now"), never one that read a recorded verdict or needed none.
    leg_sec {rg, ta, rh} = integer seconds of ROUND 1's legs, 0 for a leg that REUSED a recorded verdict, null for one
      that did not run; catchup_sec = integer seconds of every leg of rounds 2 and 3, 0 when no second round ran.
      rg_reused, rg_selftests, rg_unkeyable (run-gates' "already passed ... could not be keyed" line), ta_rc
      (test-auditors' exit code outside the lock), ta_moved (its TA-KEY-MOVED line, W0.4, or null), chain_touching and
      rh_outcome (the -ForPush child's CHAIN-REHEARSAL-CHECK-COMPLETE outcome) are round 1's too, so the leg readings on
      a row always describe one leg set.
    lock_takes = Enter-TcPushLock calls, whatever each granted; `state` keeps its old meaning, what the LAST round got,
      so a round-2 refusal before the lock says not-taken beside lock_takes 1. waitMs keeps its old meaning too, the LAST
      take's wait, for old readers. lock_wait_ms_total = the waits of every take, summed and rounded to a whole ms, null
      when no take was made; lock_held_ms = the grant-to-Exit-TcPushLock stopwatch of every take that held the lock,
      summed the same way, null when none held it.
    inlock_check = the in-lock verdict check of the LAST take: covered, not-covered, could-not-decide (Code 3: it printed
      no completion marker), or not-run (that take ran no in-lock rebase or stopped before the check, or no take was
      made: lock_takes says which).
    hook_ta = what the in-lock hook's test-auditors lines say (reused, ran, not-needed or unknown), hook_ta_scope = 'full',
      'selective <n> of <m>' or null for a run that was not made, and reject_class, reject_lines = on push-rejected, the
      first rule of Get-TcPushRejectClass that matches git's output, and up to 3 matching lines of at most 300 characters;
      reject_rc = the refusing check's exit code read from the hook's own BLOCKED line (1 a red, 3 could-not-evaluate,
      null unreadable), because the fixed PRE-PUSH-REFUSED line carries none. All are read only on the take that pushed.
    A THROW OUTSIDE THE LOCK now writes the run's one row too (outcome unknown, the phase it had reached) before it goes on
      to the caller, and every reader outside the lock runs through Invoke-TcRowReader, so a defect in one costs its field.
  The run-gates leg now runs through the call operator and a pipeline rather than Start-Process, so its lines reach the
  console as it prints them AND reach the row; its exit code is $LASTEXITCODE, which the Start-Process handle trap
  ([[ps-start-process-exitcode-needs-handle]]) does not touch.

  SCOPE OF A CLEAN REPORT: exit 0 means the remote accepted this push while this process held the lock. It says
  nothing about a pusher that does not take the lock - an older checkout, a plain `git push --no-verify`, or another
  machine - and nothing about whether main is healthy afterwards.
#>
# Declared inputs of its -SelfTest (2026-09-23, lib\gate-input-key.ps1): read off the self-test block, which works in a temp sandbox and reads nothing else of this repo. Verify with: powershell -File lib\gate-input-key.ps1 -VerifyDeclared <this file>
# gate-inputs: ops\push-main.ps1, lib\push-lock.ps1, lib\git-repo-env.ps1, lib\push-ledger.ps1, lib\seed-hint.ps1, ops\seed-worktree.ps1, ops\probe-push-convergence.ps1
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
# THE FILE THAT IS RUNNING, for the row's pm_blob: the copy in THIS checkout, never the one in the -Dir being pushed.
$script:TcPushMainPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
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
     PowerShell stream, so it cannot join anything.

     $script:TcSayPrefix IS FOR THE SELF-TEST ONLY, and goes on EVERY line of a multi-line text (2026-09-23). This file
     echoes what its children print, and the self-test's children print fixture refusals on purpose: a stub run-gates'
     `  FAIL  fixture-gate` line and a stub hook's `  FAIL  <gate>` line. run-gates reads any stdout line matching
     ^\s*FAIL\b from a suite that exited 0 as the suite failing (lib\selftest-verdict.ps1), and it scored this suite red
     over exactly those echoes the first time they existed. The prefix keeps them visible and keeps them from reading as
     this suite's own verdict. Empty in production, where every line prints exactly as before. #>
  param([string]$Text)
  if (-not $script:TcSayPrefix) { [Console]::Out.WriteLine($Text); return }
  foreach ($l in ([string]$Text -split "`r?`n")) { [Console]::Out.WriteLine($script:TcSayPrefix + $l) }
}
$script:TcSayPrefix = ''

function Invoke-TcWarmGate {
  <# Run the gate OUTSIDE the push lock, so the expensive half of a push is not serialised behind every other
     session on this box. Returns Ran / Code / Why; it decides nothing, so its caller can degrade on a 3.

     Start-Process's ExitCode is empty under PS 5.1 unless .Handle is touched while the process is alive
     ([[ps-start-process-exitcode-needs-handle]]), and reading an empty ExitCode as 0 would turn a red gate into a
     pass here - the one outcome this must never produce. That was why this ran through Start-Process with the handle
     taken before the wait.

     IT NOW RUNS THROUGH THE CALL OPERATOR AND A PIPELINE (2026-09-23, W0.1), because the row needs run-gates' own
     words (the "already passed ... could not be keyed" line, and whether the whole verdict was replayed) and a
     Start-Process child that shares the console hands back none of them. Each line is printed as it arrives, so the
     console sees the gate exactly as before, and collected. The exit code is $LASTEXITCODE, which the handle trap does
     not touch; a code that still cannot be read is could-not-evaluate, never a pass. The working directory is $Dir, as
     -WorkingDirectory made it before. Returns Ran / Code / Why, and Sec (integer seconds) and Lines for the row. #>
  param([string]$Dir)
  $gate = Join-Path $Dir 'ops\run-gates.ps1'
  if (-not (Test-Path -LiteralPath $gate)) {
    return [pscustomobject]@{ Ran = $false; Code = 3; Why = 'this checkout has no ops\run-gates.ps1'; Sec = $null; Lines = @() }
  }
  $lines = [Collections.Generic.List[string]]::new()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $code = $null
  $pushed = $false
  try {
    Push-Location -LiteralPath $Dir
    $pushed = $true
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gate | ForEach-Object { $s = [string]$_; $lines.Add($s); Say $s }
    $code = $LASTEXITCODE
  } catch {
    return [pscustomobject]@{ Ran = $false; Code = 3; Why = ('the gate could not be started: ' + $_.Exception.Message); Sec = $null; Lines = $lines.ToArray() }
  } finally {
    $sw.Stop()
    if ($pushed) { Pop-Location }
  }
  $sec = [int][math]::Round($sw.Elapsed.TotalSeconds)
  if ($null -eq $code) { return [pscustomobject]@{ Ran = $true; Code = 3; Why = 'the gate ran but its exit code could not be read'; Sec = $sec; Lines = $lines.ToArray() } }
  return [pscustomobject]@{ Ran = $true; Code = [int]$code; Why = ''; Sec = $sec; Lines = $lines.ToArray() }
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
     self-test drives a fixture through.
     For the row (W0.1, W0.4) it also returns Sec (integer seconds), Exit (the process's own exit code, null when it
     never started or could not be read, which Code is not: Code folds a missing marker into 3), and Lines (its stdout),
     which is where the TA-KEY-MOVED line W0.4 prints before a run is read from. #>
  param([string]$Dir, [string]$RefLine, [string]$Script = '')
  if (-not $Script) { $Script = Join-Path $Dir 'ops\prepush-test-auditors.ps1' }
  if (-not (Test-Path -LiteralPath $Script)) {
    return [pscustomobject]@{ Ran = $false; Code = 3; Why = 'this checkout has no ops\prepush-test-auditors.ps1'; Sec = $null; Exit = $null; Lines = @() }
  }
  if (-not $RefLine) { return [pscustomobject]@{ Ran = $false; Code = 3; Why = 'the ref line for the test-auditors check could not be formed'; Sec = $null; Exit = $null; Lines = @() } }
  $stem = Join-Path $env:TEMP ('tc-pm-ta-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $inF = $stem + '.in'; $outF = $stem + '.out'; $errF = $stem + '.err'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    [IO.File]::WriteAllText($inF, ($RefLine + "`n"), (New-Object Text.UTF8Encoding($false)))
    $p = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Dir -NoNewWindow -PassThru -ErrorAction Stop `
      -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-RefsFromStdin')
    $null = $p.Handle
    $p.WaitForExit()
    $sw.Stop()
    $sec = [int][math]::Round($sw.Elapsed.TotalSeconds)
    $code = $p.ExitCode
    $lines = @()
    if (Test-Path -LiteralPath $outF) { $lines = @([IO.File]::ReadAllLines($outF) | Where-Object { $_.Trim() }) }
    foreach ($l in $lines) { if ($l -notmatch '^PREPUSH-TEST-AUDITORS-COMPLETE') { Say ('  ' + $l) } }
    if ($null -eq $code) { return [pscustomobject]@{ Ran = $true; Code = 3; Why = 'the test-auditors check ran but its exit code could not be read'; Sec = $sec; Exit = $null; Lines = [string[]]$lines } }
    $complete = ($lines.Count -gt 0) -and ([string]$lines[$lines.Count - 1] -match '^PREPUSH-TEST-AUDITORS-COMPLETE')
    if ([int]$code -eq 0 -and -not $complete) { return [pscustomobject]@{ Ran = $true; Code = 3; Why = 'the test-auditors check exited 0 without its completion marker, so it decided nothing'; Sec = $sec; Exit = 0; Lines = [string[]]$lines } }
    $why = $(if ([int]$code -eq 1) { 'the test-auditors check refused this push' } else { '' })
    return [pscustomobject]@{ Ran = $true; Code = [int]$code; Why = $why; Sec = $sec; Exit = [int]$code; Lines = [string[]]$lines }
  } catch {
    return [pscustomobject]@{ Ran = $false; Code = 3; Why = ('the test-auditors check could not be started: ' + $_.Exception.Message); Sec = $null; Exit = $null; Lines = @() }
  } finally {
    foreach ($x in @($inF, $outF, $errF)) { if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue } }
  }
}

function Invoke-TcRehearsalForPush {
  <# ops\rehearse-chain.ps1 -ForPush, outside the push lock: Code 0 allow, 1 refuse, 3 could not rehearse. A checkout older
     than the harness has none and is not asked, as an older checkout without hold-push-lock pushes unlocked. An exit 0
     without the completion marker as the last line decided nothing and is 3. Ran and Lines are for the row (W0.1):
     Ran is $false when nothing was asked, so the leg reads null rather than a time. #>
  param([string]$Dir, [string]$Remote, [string]$Branch)
  $rh = Join-Path $Dir 'ops\rehearse-chain.ps1'
  if (-not (Test-Path -LiteralPath $rh)) { return [pscustomobject]@{ Code = 0; Why = 'this checkout has no ops\rehearse-chain.ps1, so no rehearsal is asked'; Ran = $false; Lines = @() } }
  $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $rh -ForPush -Remote $Remote -Branch $Branch)
  $code = $LASTEXITCODE
  foreach ($l in $out) { Say ([string]$l) }
  $last = [string]($out | Select-Object -Last 1)
  if ($code -eq 0 -and $last -notmatch '^CHAIN-REHEARSAL-CHECK-COMPLETE') { $code = 3 }
  return [pscustomobject]@{ Code = $code; Why = $last; Ran = $true; Lines = [string[]]@($out | ForEach-Object { [string]$_ }) }
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

# HOW MANY TIMES ONE PUSH MAY GATE AND REHEARSE BEFORE IT GIVES UP (2026-09-23). A round ends early, lock handed back,
# only when origin moved while the push waited AND that move changed what the rehearsal covered. 3 is the first plausible
# number, not the survivor of a sweep: each extra round costs a full rehearsal (about 14 minutes), so a third means origin
# changed a chain-manifest script twice inside half an hour, and looping on past that is the livelock this file exists to
# end. Past it the push is refused (exit 1, outcome refused-rehearsal-churn) with the branch rebased and nothing pushed.
# What it does when the producer stops: nothing moves origin, every push finishes in round 1.
$script:PmMaxRehearsalRounds = 3

function Invoke-TcSyncToRemote {
  <# Fetch <Remote>/<Branch>, decide from git alone (Get-TcPushPlan), and rebase when the remote moved. Called TWICE per
     round: OUTSIDE the lock, so the gate and the rehearsal judge the content that will actually land, and again INSIDE
     it, where a remote that moved in between is rebased over once more. Code 0 ready, 1 refused, 3 could not evaluate;
     Outcome is the ledger's word for a refusal and Message the line to print.

     FOR THE ROW (2026-09-23, W0.1R step 3) every answer also says whether a rebase was ATTEMPTED (RebaseTried), and which
     main commits it brings in carry one of this branch's subjects (Siblings: short shas, [] for none, $null when no
     rebase was needed or git could not list them). When the rebase CONFLICTS it also hands back what git left unmerged:
     those paths exist only until `git rebase --abort` clears them, so they are read HERE, inside the failure branch and
     before the abort, as ConflictFiles (scope 'first-stop', the commit the rebase stopped on), and ConflictFilesAll is one
     squashed merge-tree over the whole range, read after the abort from the restored HEAD ('merge-tree-approximate').
     W0.1 read them in the lock only; this function is called in every phase, so every phase's conflict is recorded the
     same way. Which phase a call belongs to is the caller's to say. #>
  param([string]$Dir, [string]$Remote, [string]$Branch)
  $f = Invoke-TcGit -Dir $Dir -Arguments @('fetch', '--quiet', $Remote, $Branch)
  if ($f.Code -ne 0) {
    return (New-TcSyncResult -Code 3 -Outcome 'blind-fetch-failed' -Message ("push-main: COULD NOT EVALUATE - `git fetch {0} {1}` exited {2}, so what this push would land on is unknown. That is not a pass.`n{3}" -f $Remote, $Branch, $f.Code, $f.Text))
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
    return (New-TcSyncResult -Code 1 -Outcome 'refused-not-ready' -Head $head -Rem $rem -Ahead $ahead -Message ("push-main: REFUSED - {0}" -f $plan.Reason))
  }
  Say ("push-main: {0} commit(s) to land on {1}/{2}; {3}." -f $ahead, $Remote, $Branch, $plan.Reason)
  $siblings = $null
  if ($plan.NeedsRebase) {
    # WHAT THE REBASE BRINGS IN, read before it moves HEAD: any main commit whose subject is one of this branch's.
    $siblings = Get-TcSameSubjectSiblings -Dir $Dir -MergeBase $mb -Target $rem
    $rb = Invoke-TcGit -Dir $Dir -Arguments @('rebase', $rem)
    if ($rb.Code -ne 0) {
      # RECORD THE CASE AT THE MOMENT IT FAILS (measurement.md): the unmerged paths exist only until the abort below
      # clears them, so they are read first. The squashed whole-range list is read after, from the restored HEAD.
      $unmerged = Get-TcUnmergedFiles -Dir $Dir
      # THE BRANCH IS LEFT EXACTLY WHERE IT WAS. A half-finished rebase is the worst thing this could hand back,
      # because the next session to push inherits it.
      $null = Invoke-TcGit -Dir $Dir -Arguments @('rebase', '--abort')
      $whole = Get-TcMergeTreeConflicts -Dir $Dir -Head 'HEAD' -Target $rem
      # THE SCOPE SAYS WHETHER THE REBASE STOPPED AT ALL (review of W0.1R, 2026-09-23). A rebase that fails with nothing
      # unmerged - an index.lock another process holds, say - never stopped on a commit, so 'first-stop' would name a stop
      # that did not happen: it is 'none-unmerged', beside an empty list. A git that could not be asked leaves both null.
      $scope = $(if ($null -eq $unmerged) { '' } elseif (@($unmerged).Count) { 'first-stop' } else { 'none-unmerged' })
      return (New-TcSyncResult -Code 1 -Outcome 'refused-rebase-conflict' -Head $head -Rem $rem -Ahead $ahead -RebaseTried $true -Siblings $siblings `
        -ConflictFiles $unmerged -ConflictScope $scope -ConflictFilesAll $whole -ConflictAllBasis 'merge-tree-approximate' `
        -Message ("push-main: REFUSED - the rebase onto {0}/{1} conflicts, so it was aborted and this branch is exactly where it was. Resolve it and run this again.`n{2}" -f $Remote, $Branch, $rb.Text))
    }
    $head = ([string](Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'HEAD')).Out[0]).Trim()
    Say ("push-main: rebased onto {0}; HEAD is now {1}." -f $rem.Substring(0, 9), $head.Substring(0, 9))
  }
  return (New-TcSyncResult -Code 0 -Rebased ([bool]$plan.NeedsRebase) -Head $head -Rem $rem -Ahead $ahead -RebaseTried ([bool]$plan.NeedsRebase) -Siblings $siblings)
}

function New-TcSyncResult {
  <# One Invoke-TcSyncToRemote answer, with every field present on every path, so no reader has to ask whether a field
     exists before it reads one. The array fields are passed through untouched: a caller hands in $null, an empty array
     or the list itself, and a PARAMETER keeps each as it came, which a function's return value would not (PowerShell
     unrolls an array returned from a function, so an empty one arrives as $null). #>
  param([int]$Code, [string]$Outcome = '', [bool]$Rebased = $false, [string]$Head = '', [string]$Rem = '', [int]$Ahead = 0,
    [string]$Message = '', [bool]$RebaseTried = $false, $Siblings = $null, $ConflictFiles = $null, [string]$ConflictScope = '',
    $ConflictFilesAll = $null, [string]$ConflictAllBasis = '')
  return [pscustomobject]@{
    Code = $Code; Outcome = $Outcome; Rebased = $Rebased; Head = $Head; Rem = $Rem; Ahead = $Ahead; Message = $Message
    RebaseTried = $RebaseTried; Siblings = $Siblings; ConflictFiles = $ConflictFiles; ConflictScope = $ConflictScope
    ConflictFilesAll = $ConflictFilesAll; ConflictAllBasis = $ConflictAllBasis
  }
}

function Invoke-TcRehearsalCheck {
  <# THE HOOK'S OWN QUESTION, asked inside the lock only after a rebase there: does a recorded rehearsal verdict cover
     this exact content? ops\rehearse-chain.ps1 -CheckPush over the ref line git will hand the hook. It reads verdicts
     and never rehearses, so it takes seconds, as the hook's leg does. Code 0 covered (or no chain-manifest script
     changed, or a loud -NoRehearsal, or no harness in this checkout); anything else is not covered. #>
  param([string]$Dir, [string]$Branch, [string]$Head, [string]$RemoteSha)
  $rh = Join-Path $Dir 'ops\rehearse-chain.ps1'
  if (-not (Test-Path -LiteralPath $rh)) { return [pscustomobject]@{ Code = 0; Why = 'this checkout has no ops\rehearse-chain.ps1' } }
  $rf = Join-Path $env:TEMP ('tc-pm-rc-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.txt')
  try {
    [IO.File]::WriteAllText($rf, ('HEAD ' + $Head + ' refs/heads/' + $Branch + ' ' + $RemoteSha + "`n"), (New-Object Text.UTF8Encoding($false)))
    $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $rh -CheckPush -Branch $Branch -RefsFile $rf)
    $code = $LASTEXITCODE
    $last = [string]($out | Select-Object -Last 1)
    if ($last -notmatch '^CHAIN-REHEARSAL-CHECK-COMPLETE') { return [pscustomobject]@{ Code = 3; Why = 'the verdict check printed no completion marker, so it decided nothing' } }
    return [pscustomobject]@{ Code = [int]$code; Why = $last }
  } finally {
    if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-TcDefaultLegs {
  <# THE DEFAULT RUNNER: the hook's two legs, outside the lock. run-gates, then (only on a pass) the test-auditors check
     with this push's own ref line, so its keyed pass is recorded before the lock and the in-lock leg can reuse it (queue
     2026-09-18-1139a0). The decision is the one the inline runner made before 2026-09-23: a run-gates that did not pass
     is the answer, else a test-auditors Code that is not 0 is, else run-gates' pass is. What is new is that it also hands
     back what each leg SAID, for the row: RgSec and RgLines, and TaSec, TaExit and TaLines (null when test-auditors did
     not run). #>
  param([string]$Dir, [string]$Remote, [string]$Branch)
  $wg = Invoke-TcWarmGate -Dir $Dir
  $res = [pscustomobject]@{ Ran = $wg.Ran; Code = $wg.Code; Why = $wg.Why; RgSec = $wg.Sec; RgLines = $wg.Lines; TaSec = $null; TaExit = $null; TaLines = $null }
  if (-not ($wg.Ran -and $wg.Code -eq 0)) { return $res }
  $wt = Invoke-TcWarmTestAuditors -Dir $Dir -RefLine (Get-TcWarmRefLine -Dir $Dir -Remote $Remote -Branch $Branch)
  $res.TaSec = $wt.Sec; $res.TaExit = $wt.Exit; $res.TaLines = $wt.Lines
  if ($wt.Code -ne 0) { $res.Ran = $wt.Ran; $res.Code = $wt.Code; $res.Why = $wt.Why }
  return $res
}

# ======================================================================================================================
# WHAT THE ROW RECORDS (2026-09-23, design\PLAN-push-derived-conflicts-2026-09-23.md W0.1). Every reader below is PURE over
# text git or a leg already printed, or a small git read that returns null on any failure: the row is a measurement, and
# nothing here may refuse or slow a push beyond a few git calls.
# ======================================================================================================================

# WHICH SESSION PUSHED, in order. Read with `Get-ChildItem env:` from a spawned build lane on 2026-09-23: it carried
# CLAUDE_CODE_CHILD_SESSION=1, CLAUDE_CODE_HOST_SESSION_ID=local_<guid> and CLAUDE_CODE_SESSION_ID=<guid>, and no
# orchestrator exported a run id of its own. The HOST id names the desktop session the lane was spawned from, so it is
# the closest thing to an orchestrator run id the environment holds, and it comes first; the lane's own id is second.
$script:TcPushSessionVars = @('CLAUDE_CODE_HOST_SESSION_ID', 'CLAUDE_CODE_SESSION_ID')

function Get-TcPushSession {
  <# The row's `session` and `session_var`: the first variable of $script:TcPushSessionVars that is set, and its name.
     A worktree name is never used: one session makes many worktrees, which is exactly what a parallel run is.
     THAT LANES OF ONE RUN SHARE THE HOST ID IS AN ASSUMPTION read from one lane, not compared across two; session_var
     says which variable a row's value came from, so a reader can check it. Neither set (the ~07:00 bot, a scheduled
     task, a person at a terminal) is null. -Environment is the self-test's seam, a dictionary standing in for the
     process environment. #>
  param([System.Collections.IDictionary]$Environment = $null)
  foreach ($v in $script:TcPushSessionVars) {
    $val = $(if ($null -ne $Environment) { [string]$Environment[$v] } else { [string][Environment]::GetEnvironmentVariable($v) })
    if ($val.Trim()) { return [pscustomobject]@{ Value = $val.Trim(); Var = $v } }
  }
  return [pscustomobject]@{ Value = $null; Var = $null }
}

function Get-TcFirstLine {
  <# The first stdout line of an Invoke-TcGit result, trimmed, or '' when git failed or said nothing. #>
  param($Result)
  if ($null -eq $Result -or $Result.Code -ne 0 -or -not @($Result.Out).Count) { return '' }
  return ([string]@($Result.Out)[0]).Trim()
}

function Get-TcScriptBlob {
  <# `git hash-object` of the running push-main (the row's pm_blob), run from the script's own folder so this checkout's
     line-ending rules apply and the id is the blob origin/main stores for these bytes. '' when it cannot be read. #>
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
  $h = Get-TcFirstLine (Invoke-TcGit -Dir (Split-Path -Parent $Path) -Arguments @('hash-object', $Path))
  if ($h -match '^[0-9a-f]{40}([0-9a-f]{24})?$') { return $h }
  return ''
}

function Get-TcBranchBase {
  <# Where this branch left the remote, read at push-main START before any fetch: `git merge-base HEAD
     refs/remotes/<remote>/<branch>` and that commit's committer date (%cI). Sha and Ts are '' when unreadable, which is
     UNKNOWN, never a base. #>
  param([string]$Dir, [string]$Remote, [string]$Branch)
  $sha = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('merge-base', 'HEAD', ('refs/remotes/' + $Remote + '/' + $Branch)))
  if ($sha -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') { return [pscustomobject]@{ Sha = ''; Ts = '' } }
  $ts = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('show', '-s', '--format=%cI', $sha))
  return [pscustomobject]@{ Sha = $sha; Ts = $ts }
}

function Get-TcChangeId {
  <# The row's change_id: `git diff <Base> HEAD | git patch-id --stable`, first field. It names the CHANGE rather than the
     commit, so it survives a rebase that brings in no conflict, which is how W0.3 groups a change's attempts.
     THE PIPE IS cmd.exe's, NOT .NET's (found by this file's own self-test, 2026-09-23). The first version copied git
     diff's stdout into patch-id's Process.StandardInput, and patch-id printed NOTHING for a diff bash hashes at once:
     that StandardInput is a StreamWriter in [Console]::InputEncoding, which on this box is utf-8 (code page 65001) with a
     3-byte preamble, and a child fed four bytes through its BaseStream read EF-BB-BF before them (measured the same day).
     So patch-id's first line began with a BOM, it never saw a line starting `diff --git`, and it found no patch. cmd.exe joins the two processes
     with an anonymous pipe and adds no byte. A $Dir holding a character cmd would read as syntax is refused rather than
     quoted. '' when anything fails, times out (120 s, a hang guard and nothing else) or the diff is empty. #>
  param([string]$Dir, [string]$Base)
  if ($Base -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') { return '' }
  if (-not $Dir -or $Dir -match '["%&^|<>!]') { return '' }
  $p = $null
  try {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $(if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' })
    # /s strips only the outermost pair of quotes, so the inner quotes around the directory survive as written.
    $psi.Arguments = ('/d /s /c "git -C "' + $Dir + '" diff --no-color --no-ext-diff ' + $Base + ' HEAD | git patch-id --stable"')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $p = [Diagnostics.Process]::Start($psi)
    $pOut = $p.StandardOutput.ReadToEndAsync()
    $pErr = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(120000)) { try { $p.Kill() } catch { }; return '' }
    $null = $pErr.Result
    $first = (([string]$pOut.Result).Trim() -split '\s+')[0]
    if ($first -match '^[0-9a-f]{40}([0-9a-f]{24})?$') { return $first }
    return ''
  } catch {
    return ''
  } finally {
    if ($p) { $p.Dispose() }
  }
}

function Get-TcUnmergedFiles {
  <# The paths git left unmerged where a rebase STOPPED (the row's conflict_files, scope 'first-stop': the commit the
     rebase stopped on, never the whole range). READ BEFORE `git rebase --abort`, which clears them. An empty array is a
     rebase that failed with nothing unmerged; $null is a git that could not be asked. #>
  param([string]$Dir)
  $u = Invoke-TcGit -Dir $Dir -Arguments @('-c', 'core.quotepath=off', 'diff', '--name-only', '--diff-filter=U')
  if ($u.Code -ne 0) { return $null }
  return , ([string[]]@(@($u.Out) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }))
}

function Get-TcMergeTreeConflicts {
  <# The files ONE squashed merge of the whole range would conflict on (conflict_files_all), from `git merge-tree
     --write-tree --name-only --no-messages <Head> <Target>`: exit 1 is conflicts, a tree id then one path per line;
     exit 0 is clean. APPROXIMATE by construction, and the row says so in conflict_all_basis: a rebase replays commit by
     commit and can stop on a file one merge resolves, or pass one it would conflict on. Anything else is $null. #>
  param([string]$Dir, [string]$Head, [string]$Target)
  $m = Invoke-TcGit -Dir $Dir -Arguments @('-c', 'core.quotepath=off', 'merge-tree', '--write-tree', '--name-only', '--no-messages', $Head, $Target)
  if ($m.Code -eq 0) { return , ([string[]]@()) }
  if ($m.Code -ne 1) { return $null }
  $o = @($m.Out)
  if ($o.Count -lt 1 -or [string]$o[0] -notmatch '^[0-9a-f]{40}') { return $null }
  return , ([string[]]@($o | Select-Object -Skip 1 | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }))
}

function Get-TcSameSubjectSiblings {
  <# Main commits in <MergeBase>..<Target> whose subject is ORDINAL-equal to a subject in <MergeBase>..HEAD (the row's
     sibling_same_subject): the shape of two sessions landing the same fix, which on 2026-09-11 was seven branches of one
     two-line change. Short shas in git log order; an empty array is none; $null is a list git could not give. #>
  param([string]$Dir, [string]$MergeBase, [string]$Target)
  if (-not $MergeBase -or -not $Target) { return $null }
  $mine = Invoke-TcGit -Dir $Dir -Arguments @('log', '--format=%s', ($MergeBase + '..HEAD'))
  $theirs = Invoke-TcGit -Dir $Dir -Arguments @('log', '--format=%h%x09%s', ($MergeBase + '..' + $Target))
  if ($mine.Code -ne 0 -or $theirs.Code -ne 0) { return $null }
  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($s in @($mine.Out)) { [void]$set.Add([string]$s) }
  $hits = [Collections.Generic.List[string]]::new()
  foreach ($l in @($theirs.Out)) {
    $parts = ([string]$l) -split "`t", 2
    if ($parts.Count -eq 2 -and $set.Contains($parts[1])) { $hits.Add($parts[0]) }
  }
  return , ($hits.ToArray())
}

function Get-TcRejectLinesCapped {
  <# Up to 3 lines of at most 300 characters each, in order: what a row keeps of a refusal. #>
  param($Lines)
  $out = [Collections.Generic.List[string]]::new()
  foreach ($l in @($Lines)) {
    if ($out.Count -ge 3) { break }
    $s = [string]$l
    if ($s.Length -gt 300) { $s = $s.Substring(0, 300) }
    $out.Add($s)
  }
  return , ($out.ToArray())
}

function Get-TcRejectRc {
  <# THE EXIT CODE OF THE CHECK THAT REFUSED (the row's reject_rc, review of W0.1R, 2026-09-23): 1 is a red, 3 is
     could-not-evaluate, which is NEVER a red and never a pass. The fixed PRE-PUSH-REFUSED line carries cause and gate but
     no code, so rule 1 of the classifier kept a contention 3 of run-gates or test-auditors exactly as it kept a red, and
     a reader scored both as the change's own red. Read, first match wins:
       1. an rc=<n> on a PRE-PUSH-REFUSED line (a later hook may print one)     n
       2. a ^pre-push: BLOCKED - line saying COULD NOT EVALUATE, or "without its completion marker" (decided nothing)  3
       3. a ^pre-push: BLOCKED - line carrying "(exit <n>)" or "exited <n>"      n
     $null when no line says, which is what a structure refusal, a remote rejection and an unknown text all are. Pure. #>
  param($Lines)
  $all = @(@($Lines) | ForEach-Object { [string]$_ })
  foreach ($l in $all) {
    $m = [regex]::Match($l, '^PRE-PUSH-REFUSED cause=\S+.*?\brc=(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
  }
  foreach ($l in $all) {
    if ($l -cnotmatch '^pre-push: BLOCKED - ') { continue }
    if ($l -cmatch 'COULD NOT EVALUATE' -or $l -cmatch 'without its completion marker') { return 3 }
    $m = [regex]::Match($l, '\(exit (\d+)\)')
    if (-not $m.Success) { $m = [regex]::Match($l, '\bexited (\d+)\b') }
    if ($m.Success) { return [int]$m.Groups[1].Value }
  }
  return $null
}

function Get-TcHookTestAuditorsScope {
  <# How much of test-auditors the IN-LOCK hook ran (the row's hook_ta_scope, review of W0.1R, 2026-09-23): 'full' for
     prepush-test-auditors' "running <suite> in full" line, 'selective <n> of <m>' for its "running <suite> on <n> of <m>
     unit(s)" line, $null when it did not run. hook_ta keeps its four words (the probe reads them); B11 counts FULL runs
     inside the lock, and 'ran' alone could not say which. Pure. #>
  param([string]$Text)
  foreach ($l in @(([string]$Text) -split "`r?`n")) {
    if ($l -cmatch '^\s*prepush-test-auditors: running .+? in full\b') { return 'full' }
    $m = [regex]::Match($l, '^\s*prepush-test-auditors: running .+? on (\d+) of (\d+) unit\(s\)')
    if ($m.Success) { return ('selective ' + $m.Groups[1].Value + ' of ' + $m.Groups[2].Value) }
  }
  return $null
}

function Get-TcPushRejectClass {
  <# WHY A PUSH WAS REJECTED, from git's output (the row's reject_class and reject_lines). The FIRST RULE THAT MATCHES
     ANY LINE wins, in this order, never the first line that matches any rule: a text carrying both the fixed line and an
     older wording is classified by the fixed line wherever it sits.
       1. ^PRE-PUSH-REFUSED cause=<c> [gate=<g>]      the fixed line the hook prints from W1.1: <c>, or <c>:<g>
       2. ^pre-push: BLOCKED - (the chain rehearsal|this push changes the daily chain), or
          ^chain-rehearsal: (REFUSED|COULD NOT)       rehearsal
       3. ^pre-push: BLOCKED - the test-auditors check  test-auditors
       4. ^pre-push: BLOCKED - run-gates              run-gates, or run-gates:<gate> naming the first ^\s+FAIL\s+(\S+) line;
                                                      the BLOCKED line, the FAIL lines and the run-gates: FAILED or COULD
                                                      NOT lines the hook echoes are kept, in that order
       5. ^pre-push: REFUSING                         structure
       6. ! [remote rejected], or cannot lock ref     remote
       7. none                                        unknown, keeping the first 3 non-empty lines
     THE WORDING BEFORE 2026-09-23 matched only rule 5's lines (^(pre-push: REFUS|chain-rehearsal: REFUSED) or RATCHET
     BROKEN): every gate refusal in the hook says BLOCKED, and RATCHET BROKEN never reaches git's stderr, because the hook
     echoes only FAIL and run-gates: lines from run-gates' log. Lines are matched case-sensitively, as the hook prints
     them. Rc is Get-TcRejectRc's reading of the same text (the row's reject_rc). Pure: it runs nothing and never throws on
     any text. #>
  param([string]$Text)
  $lines = @(([string]$Text) -split "`r?`n" | Where-Object { ([string]$_).Trim() })
  $rc = Get-TcRejectRc -Lines $lines
  $pp = @($lines | Where-Object { $_ -cmatch '^PRE-PUSH-REFUSED cause=\S+' })
  if ($pp.Count) {
    $m = [regex]::Match([string]$pp[0], '^PRE-PUSH-REFUSED cause=(\S+)(?:.*?\sgate=(\S+))?')
    $cls = $m.Groups[1].Value
    if ($m.Groups[2].Success -and $m.Groups[2].Value) { $cls = $cls + ':' + $m.Groups[2].Value }
    return [pscustomobject]@{ Rc = $rc; Class = $cls; Lines = (Get-TcRejectLinesCapped $pp) }
  }
  $rh = @($lines | Where-Object { $_ -cmatch '^pre-push: BLOCKED - (the chain rehearsal|this push changes the daily chain)' -or $_ -cmatch '^chain-rehearsal: (REFUSED|COULD NOT)' })
  if ($rh.Count) { return [pscustomobject]@{ Rc = $rc; Class = 'rehearsal'; Lines = (Get-TcRejectLinesCapped $rh) } }
  $ta = @($lines | Where-Object { $_ -cmatch '^pre-push: BLOCKED - the test-auditors check' })
  if ($ta.Count) { return [pscustomobject]@{ Rc = $rc; Class = 'test-auditors'; Lines = (Get-TcRejectLinesCapped $ta) } }
  $rg = @($lines | Where-Object { $_ -cmatch '^pre-push: BLOCKED - run-gates' })
  if ($rg.Count) {
    $fails = @($lines | Where-Object { $_ -cmatch '^\s+FAIL\s+\S+' })
    $said = @($lines | Where-Object { $_ -cmatch '^run-gates: (FAILED|COULD NOT)' })
    $cls = 'run-gates'
    if ($fails.Count) { $cls = 'run-gates:' + [regex]::Match([string]$fails[0], '^\s+FAIL\s+(\S+)').Groups[1].Value }
    return [pscustomobject]@{ Rc = $rc; Class = $cls; Lines = (Get-TcRejectLinesCapped (@($rg[0]) + $fails + $said)) }
  }
  $st = @($lines | Where-Object { $_ -cmatch '^pre-push: REFUSING' })
  if ($st.Count) { return [pscustomobject]@{ Rc = $rc; Class = 'structure'; Lines = (Get-TcRejectLinesCapped $st) } }
  $rm = @($lines | Where-Object { $_ -cmatch '! \[remote rejected\]' -or $_ -cmatch 'cannot lock ref' })
  if ($rm.Count) { return [pscustomobject]@{ Rc = $rc; Class = 'remote'; Lines = (Get-TcRejectLinesCapped $rm) } }
  return [pscustomobject]@{ Rc = $rc; Class = 'unknown'; Lines = (Get-TcRejectLinesCapped $lines) }
}

function Get-TcRunGatesReading {
  <# What run-gates said about reuse, from its own lines (rg_reused, rg_selftests, rg_unkeyable): its "<x> of <y>
     self-test(s) already passed over these exact inputs ...; <z> could not be keyed" line (ops\run-gates.ps1, printed
     on every run that dispatches), and WholeRun when it replayed a whole recorded verdict and dispatched nothing (its
     "PASSED - all <n> gate(s) passed at ... not one was run again" line, or a completion marker carrying reused=1), which
     is what makes the leg's time 0. Every number is null when its line is absent. #>
  param($Lines)
  $res = [pscustomobject]@{ Reused = $null; SelfTests = $null; Unkeyable = $null; WholeRun = $false }
  foreach ($l in @($Lines)) {
    $s = [string]$l
    $m = [regex]::Match($s, '^run-gates: (\d+) of (\d+) self-test\(s\) already passed over these exact inputs.*; (\d+) could not be keyed')
    if ($m.Success -and $null -eq $res.Reused) { $res.Reused = [int]$m.Groups[1].Value; $res.SelfTests = [int]$m.Groups[2].Value; $res.Unkeyable = [int]$m.Groups[3].Value }
    if ($s -cmatch '^run-gates: PASSED - all \d+ gate\(s\) passed at .*not one was run again' -or $s -cmatch '^RUN-GATES-COMPLETE\b.*\breused=1\b') { $res.WholeRun = $true }
  }
  return $res
}

function Test-TcTaReused {
  <# Did the test-auditors check replay a recorded pass instead of running (its "REUSED key=" line)? Then its leg is 0. #>
  param($Lines)
  return [bool](@(@($Lines) | Where-Object { [string]$_ -cmatch '^\s*prepush-test-auditors: REUSED key=' }).Count)
}

function Get-TcTaKeyMoved {
  <# The TA-KEY-MOVED line the test-auditors check prints before a run that could not reuse its pass (W0.4:
     `TA-KEY-MOVED kind=<content|mtime|lib|board> input=<repo path>`, or `TA-KEY-MOVED kind=no-record`), copied as the
     row's ta_moved: the first such line, trimmed, at most 300 characters. $null when there is none, which is what a
     reused pass and a checkout older than W0.4 both print. #>
  param($Lines)
  foreach ($l in @($Lines)) {
    $s = ([string]$l).Trim()
    if ($s -cmatch '^TA-KEY-MOVED kind=\S+') { if ($s.Length -gt 300) { $s = $s.Substring(0, 300) }; return $s }
  }
  return $null
}

function Get-TcHookTestAuditors {
  <# What the IN-LOCK hook's test-auditors leg did (hook_ta), from the lines ops\prepush-test-auditors.ps1 prints and the
     hook echoes to git's stderr: `running ...` (in full or selectively) is ran; `REUSED key=` is reused; `NOT NEEDED` is
     not-needed; anything else, including a hook that refused before test-auditors ran, is unknown. #>
  param([string]$Text)
  $lines = @(([string]$Text) -split "`r?`n")
  if (@($lines | Where-Object { $_ -cmatch '^\s*prepush-test-auditors: running ' }).Count) { return 'ran' }
  if (@($lines | Where-Object { $_ -cmatch '^\s*prepush-test-auditors: REUSED key=' }).Count) { return 'reused' }
  if (@($lines | Where-Object { $_ -cmatch '^\s*prepush-test-auditors: NOT NEEDED' }).Count) { return 'not-needed' }
  return 'unknown'
}

function Get-TcRehearsalOutcome {
  <# The outcome= word of the LAST `CHAIN-REHEARSAL-CHECK-COMPLETE code=<n> outcome=<o>` line the -ForPush child printed
     (ops\rehearse-chain.ps1), or '' when there is none. #>
  param($Lines)
  $o = ''
  foreach ($l in @($Lines)) {
    $m = [regex]::Match([string]$l, '^CHAIN-REHEARSAL-CHECK-COMPLETE code=\d+ outcome=(\S+)')
    if ($m.Success) { $o = $m.Groups[1].Value }
  }
  return $o
}

function Get-TcChainTouching {
  <# Did this push change the daily chain (chain_touching)? Mapped from ops\rehearse-chain.ps1's outcome vocabulary, read
     from Get-RhPushDecision: not-needed is false; rehearsed-pass, rehearsed-fail, no-verdict, stale and bypassed are
     each reached only after a chain-manifest script was found changed, so they are true; could-not-rehearse is reached
     both BEFORE the manifest is read (the diff or the manifest failed) and after (a blind verdict), so it is $null, not
     known. A word outside that vocabulary THROWS (a switch on data refuses loudly): its caller records null and says so. #>
  param([string]$Outcome)
  $t = $null
  switch -CaseSensitive ($Outcome) {
    'not-needed'         { $t = $false }
    'rehearsed-pass'     { $t = $true }
    'rehearsed-fail'     { $t = $true }
    'no-verdict'         { $t = $true }
    'stale'              { $t = $true }
    'bypassed'           { $t = $true }
    'could-not-rehearse' { $t = $null }
    default              { throw ('unknown rehearsal outcome: ' + $Outcome) }
  }
  return $t
}

function Get-TcOptionalProp {
  <# A property a runner MAY report (a self-test stub or an older seam reports fewer), or $null. #>
  param($Object, [string]$Name)
  if ($null -eq $Object) { return $null }
  $p = $Object.PSObject.Properties[$Name]
  if ($p) { return $p.Value }
  return $null
}

function Add-TcRunnerReadings {
  <# Copies what the runner's legs SAID into the row: leg_sec.rg and .ta, rg_reused, rg_selftests, rg_unkeyable, ta_rc and
     ta_moved. A runner that reports none of it leaves every one null, which is "not recorded", never a zero. #>
  param([System.Collections.IDictionary]$Row, $Result)
  $rgLines = Get-TcOptionalProp $Result 'RgLines'
  $rgSec = Get-TcOptionalProp $Result 'RgSec'
  if ($null -ne $rgLines) {
    $rgr = Get-TcRunGatesReading -Lines $rgLines
    $Row['rg_reused'] = $rgr.Reused; $Row['rg_selftests'] = $rgr.SelfTests; $Row['rg_unkeyable'] = $rgr.Unkeyable
    if ($rgr.WholeRun) { $Row['leg_sec']['rg'] = 0 } elseif ($null -ne $rgSec) { $Row['leg_sec']['rg'] = [int]$rgSec }
  } elseif ($null -ne $rgSec) { $Row['leg_sec']['rg'] = [int]$rgSec }
  $taExit = Get-TcOptionalProp $Result 'TaExit'
  if ($null -ne $taExit) { $Row['ta_rc'] = [int]$taExit }
  $taLines = Get-TcOptionalProp $Result 'TaLines'
  $taSec = Get-TcOptionalProp $Result 'TaSec'
  if ($null -ne $taLines) {
    $Row['ta_moved'] = Get-TcTaKeyMoved -Lines $taLines
    if (Test-TcTaReused -Lines $taLines) { $Row['leg_sec']['ta'] = 0 } elseif ($null -ne $taSec) { $Row['leg_sec']['ta'] = [int]$taSec }
  } elseif ($null -ne $taSec) { $Row['leg_sec']['ta'] = [int]$taSec }
}

function Add-TcRehearsalReadings {
  <# Copies what the rehearsal leg said into the row: leg_sec.rh, chain_touching and rh_outcome. The leg is null when
     nothing was asked (Ran $false), 0 when the child read a recorded verdict (a rehearsed-pass or rehearsed-fail outcome
     with no "rehearsing HEAD now" line), and its measured seconds otherwise. #>
  param([System.Collections.IDictionary]$Row, $Result, [int]$Sec)
  $ran = Get-TcOptionalProp $Result 'Ran'
  if ($ran -eq $false) { return }
  $lines = Get-TcOptionalProp $Result 'Lines'
  $oc = Get-TcRehearsalOutcome -Lines $lines
  if ($oc) {
    $Row['rh_outcome'] = $oc
    try { $Row['chain_touching'] = Get-TcChainTouching -Outcome $oc }
    catch { $Row['chain_touching'] = $null; Say ('push-main: ' + $_.Exception.Message + ' - recorded as chain_touching null; the word is kept in rh_outcome.') }
  }
  $rehearsedNow = [bool](@(@($lines) | Where-Object { [string]$_ -cmatch 'rehearsing HEAD now' }).Count)
  if (($oc -ceq 'rehearsed-pass' -or $oc -ceq 'rehearsed-fail') -and -not $rehearsedNow) { $Row['leg_sec']['rh'] = 0 } else { $Row['leg_sec']['rh'] = $Sec }
}

# ======================================================================================================================
# WHAT THE ROW RECORDS ABOUT THE LOOP (2026-09-23, W0.1R: W0.1 rebuilt on the fetch-and-rebase-first loop). The loop
# landed after W0.1 was written, so the row now also says which phase a rebase or a refusal happened in, how many rounds
# and lock takes the push needed, and what the in-lock verdict check said. Same rule as above: pure, or a few git reads
# that answer null on any failure.
# ======================================================================================================================

function Get-TcSubjectsSha {
  <# The row's subjects_sha: SHA-256, lower-case hex, of the commit subjects of <Base>..HEAD, sorted ORDINAL and joined
     with LF (no trailing LF), as UTF-8 bytes. It names the change by what its commits SAY, which survives a rebase that
     rewrites every sha and moves a patch-id whenever a conflict is resolved, so W0.3b can group one change's attempts on
     it. Read at START with the branch base. Null when the base is unreadable, git fails, or the range holds no commit
     (a branch with nothing to push has no subjects to be named by). The subjects are the lines Invoke-TcGit decodes
     from git's stdout, so one box hashes one subject one way. #>
  param([string]$Dir, [string]$Base)
  $subj = Get-TcRangeSubjects -Dir $Dir -Base $Base
  if ($null -eq $subj) { return $null }
  return (Get-TcSubjectsShaOf -Subjects $subj)
}

function Get-TcRangeSubjects {
  <# The commit subjects of <Base>..HEAD as git decodes them, one per commit, or $null when the base is unreadable, git
     fails, or the range holds no commit. #>
  param([string]$Dir, [string]$Base)
  if ($Base -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') { return $null }
  $r = Invoke-TcGit -Dir $Dir -Arguments @('log', '--format=%s', ($Base + '..HEAD'))
  if ($r.Code -ne 0) { return $null }
  $subj = [string[]]@(@($r.Out) | ForEach-Object { [string]$_ })
  if ($subj.Count -eq 0) { return $null }
  return , $subj
}

function Get-TcSha256Hex {
  <# SHA-256 of a string's UTF-8 bytes (no preamble), lower-case hex. #>
  param([string]$Text)
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $h = $sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($Text)) } finally { $sha.Dispose() }
  return (([BitConverter]::ToString($h) -replace '-', '').ToLowerInvariant())
}

function Get-TcSubjectsShaOf {
  <# subjects_sha over a subject list: sorted ORDINAL, joined with LF, hashed. Null for an empty or absent list. Pure. #>
  param([string[]]$Subjects)
  if ($null -eq $Subjects -or $Subjects.Count -eq 0) { return $null }
  $s = [string[]]$Subjects.Clone()
  [Array]::Sort($s, [StringComparer]::Ordinal)
  return (Get-TcSha256Hex -Text ($s -join "`n"))
}

# HOW MANY PER-SUBJECT HASHES A ROW KEEPS. The first plausible number (the W0.1R review's "around 50"), not the survivor
# of a sweep: a push-main range is a handful of commits, and a range longer than this is rare enough that keeping its
# first 50 sorted hashes still overlaps an earlier attempt's. subject_count says when the list was cut.
$script:TcSubjectShasCap = 50

function Get-TcSubjectShaList {
  <# The row's subject_shas (review of W0.1R, 2026-09-23): one short hash per DISTINCT subject of the range, the first 16
     hex of Get-TcSha256Hex, sorted ORDINAL and cut at $script:TcSubjectShasCap. subjects_sha is ONE hash over the whole
     set, so it moves whenever a lane amends one subject or adds a fix commit, and W0.3b split one change into several
     on exactly the housekeeping lane its key was founded on (three attempts, three subjects_sha values, measured from
     the 2026-09-23 production ledger by the review). Per-subject hashes let a reader link attempts by OVERLAP instead.
     Null for an empty or absent list. Pure. #>
  param([string[]]$Subjects)
  if ($null -eq $Subjects -or $Subjects.Count -eq 0) { return $null }
  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($x in $Subjects) { [void]$set.Add((Get-TcSha256Hex -Text ([string]$x)).Substring(0, 16)) }
  $list = [string[]]@($set)
  [Array]::Sort($list, [StringComparer]::Ordinal)
  if ($list.Count -gt $script:TcSubjectShasCap) { $list = [string[]]$list[0..($script:TcSubjectShasCap - 1)] }
  return , $list
}

function Get-TcHeadRef {
  <# The row's head_ref: `git symbolic-ref -q --short HEAD` at START, the branch the checkout pushes from, or $null for a
     detached HEAD or a git that could not be asked. A lane keeps one branch across its attempts however often it amends,
     so this is the second link W0.3b can group attempts on. #>
  param([string]$Dir)
  $r = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('symbolic-ref', '-q', '--short', 'HEAD'))
  if ($r) { return $r }
  return $null
}

function Invoke-TcRowReader {
  <# A ROW READER MAY COST ITS FIELD, NEVER THE PUSH (review of W0.1R, 2026-09-23). Every reader that fills the row
     outside the lock runs through this: a throw is said, the field keeps what it held (or $RrFallback), and the push goes
     on, the same guard the in-lock refusal classifier carries. The parameter names are prefixed so the reader's own
     variables, resolved through the caller's scope, are never shadowed. #>
  param([string]$RrName, [scriptblock]$RrRead, $RrFallback = $null)
  try { return (& $RrRead) }
  catch {
    Say ("push-main: the row reader '{0}' threw ({1}); its field is recorded as unknown and the push goes on." -f $RrName, $_.Exception.Message)
    return $RrFallback
  }
}

function Add-TcSyncReadings {
  <# Copies what ONE Invoke-TcSyncToRemote call found into the row, under the phase the caller names (W0.1R steps 3 and
     4): the phase of a rebase it attempted onto rebase_phases, one entry per rebase; any same-subject main commits onto
     sibling_same_subject, first seen first and never twice (each rebase brings in commits no earlier one did); and, when
     its rebase conflicted, the files it read before the abort. The arrays are read off the result's properties
     DIRECTLY, never through a function, because a function's return unrolls an array and an empty one would arrive as
     $null - which is "not asked", not "none". A result that carries none of it (an older seam) leaves the row as it was. #>
  param([System.Collections.IDictionary]$Row, $Sync, [string]$Phase)
  if ($null -eq $Sync) { return }
  $props = $Sync.PSObject.Properties
  if ($props['RebaseTried'] -and $props['RebaseTried'].Value -eq $true) { $Row['rebase_phases'] = [string[]](@($Row['rebase_phases']) + $Phase) }
  if ($props['Siblings'] -and $null -ne $props['Siblings'].Value) {
    $have = [Collections.Generic.List[string]]::new()
    foreach ($x in @($Row['sibling_same_subject'])) { if ($null -ne $x) { $have.Add([string]$x) } }
    foreach ($x in @($props['Siblings'].Value)) { if ($null -ne $x -and -not $have.Contains([string]$x)) { $have.Add([string]$x) } }
    $Row['sibling_same_subject'] = [string[]]$have.ToArray()
  }
  if ($props['Outcome'] -and [string]::Equals([string]$props['Outcome'].Value, 'refused-rebase-conflict', [StringComparison]::Ordinal)) {
    # Plain assignments, never $( ): a subexpression unrolls an array too, and a one-path list would land as a bare string.
    $Row['conflict_files'] = $null; $Row['conflict_files_all'] = $null; $Row['conflict_scope'] = $null; $Row['conflict_all_basis'] = $null
    $Row['conflict_target'] = $null
    # WHAT THIS REBASE CONFLICTED AGAINST (review of W0.1R, 2026-09-23): the FETCH_HEAD of THIS sync. The row's grant is
    # the in-lock remote of the last take, so for a catch-up conflict in round 2 or 3 it names a main the conflicting
    # rebase never saw, and a reader that took the grant as the collider's side named the wrong commit.
    if ($props['Rem'] -and $props['Rem'].Value) { $Row['conflict_target'] = [string]$props['Rem'].Value }
    if ($props['ConflictFiles']) { $Row['conflict_files'] = $props['ConflictFiles'].Value }
    if ($props['ConflictFilesAll']) { $Row['conflict_files_all'] = $props['ConflictFilesAll'].Value }
    if ($props['ConflictScope'] -and $props['ConflictScope'].Value) { $Row['conflict_scope'] = [string]$props['ConflictScope'].Value }
    if ($props['ConflictAllBasis'] -and $props['ConflictAllBasis'].Value) { $Row['conflict_all_basis'] = [string]$props['ConflictAllBasis'].Value }
  }
}

function Test-TcRehearsedNew {
  <# Did this round's rehearsal leg make a NEW verdict (the row's rehearsed)? ops\rehearse-chain.ps1 -ForPush prints
     "rehearsing HEAD now" exactly when it found no usable verdict and runs the rehearsal, so that line is the answer; a
     leg that read a recorded verdict, or needed none, never prints it. A runner seam may say so itself with a boolean
     Rehearsed, which wins. #>
  param($Result)
  if ($null -eq $Result) { return $false }
  $flag = Get-TcOptionalProp $Result 'Rehearsed'
  if ($null -ne $flag) { return [bool]$flag }
  $lines = Get-TcOptionalProp $Result 'Lines'
  return [bool](@(@($lines) | Where-Object { [string]$_ -cmatch 'rehearsing HEAD now' }).Count)
}

function Get-TcInlockCheckWord {
  <# The row's inlock_check for one in-lock verdict check (Invoke-TcRehearsalCheck, or its seam): Code 0 is covered, 3 is
     could-not-decide (the check printed no completion marker, so it decided nothing), anything else is not-covered. A
     check that returned no code at all decided nothing either. A take that ran no check keeps not-run. #>
  param($Check)
  $c = Get-TcOptionalProp $Check 'Code'
  if ($null -eq $c) { return 'could-not-decide' }
  if ([int]$c -eq 0) { return 'covered' }
  if ([int]$c -eq 3) { return 'could-not-decide' }
  return 'not-covered'
}

function Invoke-TcPushMain {
  param([string]$Dir, [string]$Remote, [string]$Branch, [int]$LockWaitSec, [bool]$DryRun, [string]$LockPrefix = '', [string]$LockQueueRoot = '', [scriptblock]$GateRunner = $null, [string]$LedgerRoot = '', [string]$SeedScript = '', [scriptblock]$RehearsalRunner = $null, [scriptblock]$RehearsalCheck = $null)
  # WHICH CODE IS RUNNING, read FIRST (W0.1R step 2). The round-1 fetch and rebase below rewrite this checkout, and when
  # origin changed ops\push-main.ps1 they rewrite THIS script on disk: a hash taken after that names code this process is
  # not running, which is the one thing pm_blob exists to say.
  $pmBlob = Invoke-TcRowReader 'pm_blob' { Get-TcScriptBlob -Path $script:TcPushMainPath } ''
  # WHAT THE REMOTE HELD BEFORE THIS PUSH QUEUED. Read here and compared with what the fetch inside the lock returns,
  # it is this wrapper's own answer to "did the remote move while I waited" - the quantity that decides whether a
  # retry can ever converge, recorded per push in lib\push-ledger.ps1 rather than re-derived from %TEMP% afterwards.
  # An unreadable ref is '' and is recorded UNKNOWN, never as a ref that stood still.
  $ledgerBase = Get-TcPushLedgerRefSha -Dir $Dir -Ref ('refs/remotes/' + $Remote + '/' + $Branch)
  $ledgerGrant = ''
  $ledgerWaitMs = -1
  $ledgerState = ''
  $outcome = 'unknown'
  # THE ROW'S OTHER FIELDS (W0.1 and W0.1R; the header lists them). The branch base, the change and its subjects are taken
  # HERE, at start and before any fetch, so they describe the branch as the session handed it over. Every field starts
  # null, or at zero for a count, and is filled where it becomes known; later plan items add their own keys to this same
  # dictionary.
  # EACH READER IS GUARDED (Invoke-TcRowReader): a defect in one costs its field, never the push.
  $startBase = Invoke-TcRowReader 'branch_base' { Get-TcBranchBase -Dir $Dir -Remote $Remote -Branch $Branch } ([pscustomobject]@{ Sha = ''; Ts = '' })
  $sess = Invoke-TcRowReader 'session' { Get-TcPushSession } ([pscustomobject]@{ Value = $null; Var = $null })
  $changeId = Invoke-TcRowReader 'change_id' { Get-TcChangeId -Dir $Dir -Base $startBase.Sha } ''
  # The subject list comes back through the guard unrolled (a one-subject list as a bare string), so it is re-wrapped.
  $subjList = Invoke-TcRowReader 'subjects' { Get-TcRangeSubjects -Dir $Dir -Base $startBase.Sha } $null
  if ($null -ne $subjList) { $subjList = [string[]]@($subjList) }
  $subjectsSha = Invoke-TcRowReader 'subjects_sha' { Get-TcSubjectsShaOf -Subjects $subjList } $null
  $subjectShas = $null
  try { $subjectShas = Get-TcSubjectShaList -Subjects $subjList } catch { Say ('push-main: the row reader ''subject_shas'' threw (' + $_.Exception.Message + '); its field is recorded as unknown and the push goes on.') }
  $headRef = Invoke-TcRowReader 'head_ref' { Get-TcHeadRef -Dir $Dir } $null
  $pmRow = [ordered]@{
    schema               = 2
    pm_blob              = $(if ($pmBlob) { $pmBlob } else { $null })
    session              = $sess.Value
    session_var          = $sess.Var
    change_id            = $(if ($changeId) { $changeId } else { $null })
    subjects_sha         = $subjectsSha
    subject_shas         = $subjectShas
    subject_count        = $(if ($null -ne $subjList) { $subjList.Count } else { $null })
    head_ref             = $headRef
    branch_base          = $(if ($startBase.Sha) { $startBase.Sha } else { $null })
    branch_base_ts       = $(if ($startBase.Ts) { $startBase.Ts } else { $null })
    phase                = $null
    rebase_phases        = [string[]]@()
    preflight_sha        = $null
    conflict_files       = $null
    conflict_target      = $null
    conflict_scope       = $null
    conflict_files_all   = $null
    conflict_all_basis   = $null
    sibling_same_subject = $null
    rounds               = 0
    rehearsals           = 0
    rehearsed            = 0
    leg_sec              = [ordered]@{ rg = $null; ta = $null; rh = $null }
    catchup_sec          = 0
    rg_reused            = $null
    rg_selftests         = $null
    rg_unkeyable         = $null
    ta_rc                = $null
    ta_moved             = $null
    hook_ta              = $null
    hook_ta_scope        = $null
    chain_touching       = $null
    rh_outcome           = $null
    lock_takes           = 0
    lock_wait_ms_total   = $null
    lock_held_ms         = $null
    inlock_check         = 'not-run'
    reject_class         = $null
    reject_rc            = $null
    reject_lines         = $null
  }
  # ONE ROW PER RUN, and at most one (review of W0.1R, 2026-09-23): the guard below writes a row for a throw that no path
  # wrote one for, so every path now ends here, and a path that already wrote one is never written twice.
  $rowState = @{ Written = $false }
  $curPhase = $null
  $writeRow = {
    if ($rowState.Written) { return }
    $rowState.Written = $true
    $wr = Write-TcPushRow -Event 'push-main' -WaitMs $ledgerWaitMs -State $ledgerState -BaseSha $ledgerBase `
      -GrantSha $ledgerGrant -Outcome $outcome -Checkout $Dir -Root $LedgerRoot -Fields $pmRow
    # A ROW THAT WAS NOT WRITTEN IS SAID, never refused: the ledger must not be able to stop a push, and a silent miss is
    # the blind kind of fallback.
    if (-not $wr.Written) { Say ('push-main: the push ledger row was NOT written (' + $wr.Reason + '). The push itself is unaffected.') }
  }
  $enter = @{ WaitSec = $LockWaitSec; PollMs = 500 }
  if ($LockPrefix) { $enter['Prefix'] = $LockPrefix }
  if ($LockQueueRoot) { $enter['QueueRoot'] = $LockQueueRoot }
  $enter['OnWait'] = { param($ahead) Say ("push-main: {0} push(es) are ahead of this one on this box, and the lock is served in arrival order - waiting." -f $ahead) }

  try {
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
    # Invoke-TcDefaultLegs holds that decision and also hands back what each leg said, for the row.
    $runner = $(if ($GateRunner) { $GateRunner } else { { param($d) Invoke-TcDefaultLegs -Dir $d -Remote $Remote -Branch $Branch } })
    # SEEDED FIRST, so neither leg of the gate below judges a checkout that has no built cards (backlog I237).
    $null = Invoke-TcSeedIfUnseeded -Dir $Dir -Seeder $SeedScript
    $checker = $(if ($RehearsalCheck) { $RehearsalCheck } else { { param($d, $h, $r) Invoke-TcRehearsalCheck -Dir $d -Branch $Branch -Head $h -RemoteSha $r } })
    $rebasedAny = $false
    $rehearsals = 0
    # THE ROW'S SUMS OVER ROUNDS (W0.1R step 5). Kept as doubles and written rounded after every change, so whichever path
    # writes the row carries every take and every catch-up leg so far.
    $lockWaitTotal = 0.0
    $lockHeldTotal = 0.0
    $catchupTotal = 0.0
    for ($round = 1; $round -le $script:PmMaxRehearsalRounds; $round++) {
      # WHICH PHASE A REFUSAL BEFORE THE LOCK BELONGS TO (W0.1R step 4): round 1's fetch and rebase are the pre-flight, and
      # everything before the lock in a later round is the catch-up. Round 1's LEGS carry no phase: their outcome already
      # names where the push stopped, and a row from before this loop existed reads the same way.
      $syncPhase = $(if ($round -eq 1) { 'preflight' } else { 'catchup' })
      $legPhase = $(if ($round -eq 1) { $null } else { 'catchup' })

      # ---- 1. FETCH AND REBASE, OUTSIDE THE LOCK (2026-09-23, ops lane) ----
      # Until this change the fetch and the rebase happened only INSIDE the lock, AFTER the gate and the rehearsal, so both
      # judged the content from BEFORE the rebase. The gate's per-input keys absorbed that; the rehearsal could not, because
      # its verdict is keyed on the manifest set of the exact commit pushed, and a rebase over any commit touching a
      # manifest script moves the key. The hook then found no verdict for the rebased content, refused, and the push paid
      # a second 13-to-15-minute rehearsal (several landings on 2026-09-23). Rebasing FIRST makes the rehearsed content the
      # content that lands whenever origin holds still for the length of the rehearsal.
      $curPhase = $syncPhase
      $s = Invoke-TcSyncToRemote -Dir $Dir -Remote $Remote -Branch $Branch
      $null = Invoke-TcRowReader 'sync' { Add-TcSyncReadings -Row $pmRow -Sync $s -Phase $syncPhase }
      # ROUND 1 ONLY: a later round's fetch is catch-up, and preflight_sha is what every B1 ancestry verdict is read against.
      if ($round -eq 1 -and $s.Rem) { $pmRow['preflight_sha'] = $s.Rem }
      if ($s.Code -ne 0) {
        Say $s.Message
        $outcome = $s.Outcome; $ledgerState = 'not-taken'; $pmRow['phase'] = $syncPhase
        & $writeRow
        return $s.Code
      }
      if ($s.Rebased) { $rebasedAny = $true }

      # ---- 2. THE GATE, BEFORE THE LOCK (Brad, 2026-09-12; the account is above $runner): a red gate never queues, and a
      # 3 is neither a refusal nor a pass - it leaves the gate to the hook inside the lock, exactly as before.
      # A LEG SET STARTS HERE, so this is what `rounds` counts. Round 1's legs are the row's leg readings (leg_sec and the
      # rest); a later round's legs are catch-up time, summed into catchup_sec.
      $pmRow['rounds'] = $round
      $curPhase = $legPhase
      $gateSw = [Diagnostics.Stopwatch]::StartNew()
      $g = & $runner $Dir
      $gateSw.Stop()
      if ($round -eq 1) {
        $null = Invoke-TcRowReader 'runner' { Add-TcRunnerReadings -Row $pmRow -Result $g }
      } else {
        $catchupTotal += $gateSw.Elapsed.TotalSeconds; $pmRow['catchup_sec'] = [int][math]::Round($catchupTotal)
      }
      if ($g.Ran -and $g.Code -eq 1) {
        $redWhy = $(if ($g.Why) { [string]$g.Why } else { 'run-gates exited 1' })
        Say ("push-main: REFUSED - {0} before the lock was taken, so this push never entered the queue and nothing else on this box was held up. Fix the cause and run this again." -f $redWhy)
        $outcome = 'refused-gate-red'; $ledgerState = 'not-taken'; $pmRow['phase'] = $legPhase
        & $writeRow
        return 1
      }
      if ($g.Code -ne 0) {
        Say ("push-main: the gate did not settle outside the lock ({0}), so it is left to the hook inside the lock, gated exactly as before.{1}" -f $g.Code, $(if ($g.Why) { ' ' + $g.Why } else { '' }))
      } else {
        Say 'push-main: gate PASSED outside the lock, so the lock is taken only for the fetch, the rebase and the ref update.'
      }

      # ---- 3. THE CHAIN REHEARSAL, ALSO BEFORE THE LOCK, AND AFTER THE REBASE (2026-09-22 RCA F2; order 2026-09-23) ----
      # A push that changes a script in ops\chain-manifest.json must carry a rehearsal over recent real data, and the
      # rehearsal takes the chain's own time (about 14 minutes), so it runs HERE, unlocked. The hook inside the lock only
      # reads the recorded verdict. 1 = rehearsed and failed, 3 = could not rehearse with its blind= cause; both refuse
      # before the queue, and neither is ever read as a pass. The cap of 6 at once and the three outcomes are
      # ops\rehearse-chain.ps1's, unchanged.
      $rehearsals++
      $pmRow['rehearsals'] = $rehearsals
      $rhSw = [Diagnostics.Stopwatch]::StartNew()
      $rh = $(if ($RehearsalRunner) { & $RehearsalRunner $Dir } else { Invoke-TcRehearsalForPush -Dir $Dir -Remote $Remote -Branch $Branch })
      $rhSw.Stop()
      if ($round -eq 1) {
        $rhSec = [int][math]::Round($rhSw.Elapsed.TotalSeconds)
        $null = Invoke-TcRowReader 'rehearsal' { Add-TcRehearsalReadings -Row $pmRow -Result $rh -Sec $rhSec }
      } else {
        $catchupTotal += $rhSw.Elapsed.TotalSeconds; $pmRow['catchup_sec'] = [int][math]::Round($catchupTotal)
      }
      if (Invoke-TcRowReader 'rehearsed' { Test-TcRehearsedNew -Result $rh } $false) { $pmRow['rehearsed'] = [int]$pmRow['rehearsed'] + 1 }
      if ($rh.Code -ne 0) {
        Say ("push-main: REFUSED before the lock - {0}. The rehearsal lines above say which stage or cause. Rehearse again, or push with -NoRehearsal -NoRehearsalReason '<why>' to bypass loudly." -f $(if ($rh.Code -eq 3) { 'the chain rehearsal COULD NOT EVALUATE (exit 3), which is never a pass' } else { 'this push changes the daily chain and has no passing rehearsal (exit ' + $rh.Code + ')' }))
        $outcome = $(if ($rh.Code -eq 3) { 'refused-rehearsal-blind' } else { 'refused-rehearsal' }); $ledgerState = 'not-taken'; $pmRow['phase'] = $legPhase
        & $writeRow
        return $rh.Code
      }

      # ---- 4. THE LOCK: a final fetch, a rebase only if origin moved again, and the ref update ----
      $lock = Enter-TcPushLock @enter
      $curPhase = 'inlock'
      # HOW LONG THE LOCK IS HELD (lock_held_ms): from the grant to Exit-TcPushLock, on this process's own clock, summed over
      # every take. A take that did not hold the lock has no hold. Every take counts in lock_takes and lock_wait_ms_total,
      # and the check word starts at not-run, so the row keeps the LAST take's check.
      $lockSw = $(if ($lock.Held) { [Diagnostics.Stopwatch]::StartNew() } else { $null })
      $pmRow['lock_takes'] = [int]$pmRow['lock_takes'] + 1
      $lockWaitTotal += [double]$lock.WaitedMs
      $pmRow['lock_wait_ms_total'] = [long][math]::Round($lockWaitTotal)
      $pmRow['inlock_check'] = 'not-run'
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
      $again = $false
      try {
        $s2 = Invoke-TcSyncToRemote -Dir $Dir -Remote $Remote -Branch $Branch
        $null = Invoke-TcRowReader 'sync' { Add-TcSyncReadings -Row $pmRow -Sync $s2 -Phase 'inlock' }
        # WHAT THE REMOTE HOLDS NOW, read under the lock. Against $ledgerBase it says whether the remote moved while this
        # push queued - recorded whatever happens next, including on the paths that refuse.
        $ledgerGrant = $s2.Rem
        if ($s2.Code -ne 0) {
          Say $s2.Message
          $outcome = $s2.Outcome
          return $s2.Code
        }
        if ($s2.Rebased) {
          $rebasedAny = $true
          # THE TRADE-OFF, SAID PLAINLY: origin moved AGAIN between the rebase outside the lock and this one. When that
          # move touched no chain-manifest script the verdict key is unchanged and the rehearsal above still covers the
          # content, so this push lands now. When it did touch one, no verdict covers the new content and the hook would
          # refuse, so the lock is handed back and this push gates and rehearses again OUTSIDE it - a push can still
          # re-rehearse, but only when origin changed a manifest script inside that window.
          $ck = & $checker $Dir $s2.Head $s2.Rem
          $pmRow['inlock_check'] = Invoke-TcRowReader 'inlock_check' { Get-TcInlockCheckWord -Check $ck } 'could-not-decide'
          if ($ck.Code -ne 0) {
            $again = $true
            Say ("push-main: origin moved again while this push waited, and the rebase inside the lock changed what the rehearsal covered ({0}). The lock is handed back; round {1} of {2} gates and rehearses the rebased content OUTSIDE it." -f $ck.Why, ($round + 1), $script:PmMaxRehearsalRounds)
          } else {
            Say 'push-main: origin moved again while this push waited; the rebase inside the lock changed no chain-manifest script, so the recorded rehearsal still covers this content and it is not rehearsed again.'
          }
        }
        if (-not $again) {
          if ($DryRun) {
            Say 'push-main: -DryRun, so nothing was pushed. Everything up to the push was done under the lock.'
            $outcome = 'dry-run'
            return 0
          }
          # A PLAIN PUSH: the pre-push hook runs, the gate runs, and a red gate refuses this exactly as it refuses any other
          # push. --no-verify is not passed and is not an option here.
          $p = Invoke-TcGit -Dir $Dir -Arguments @('push', $Remote, ('HEAD:refs/heads/' + $Branch))
          Say $p.Text
          # WHAT THE IN-LOCK HOOK DID AND WHY IT REFUSED, read only on the take that pushed (W0.1R step 6).
          $pmRow['hook_ta'] = Invoke-TcRowReader 'hook_ta' { Get-TcHookTestAuditors -Text $p.Text } 'unknown'
          $pmRow['hook_ta_scope'] = Invoke-TcRowReader 'hook_ta_scope' { Get-TcHookTestAuditorsScope -Text $p.Text } $null
          if ($p.Code -ne 0) {
            Say ("push-main: the push did NOT land (git exited {0}). Nothing here overrides that; read the reason above." -f $p.Code)
            $outcome = 'push-rejected'
            # WHICH CHECK REFUSED IT, kept at the moment it is known. The classifier is pure over text and has a case for a
            # text it has never seen; the catch is so that a defect in it can only cost the row its class, never the push.
            try {
              $rj = Get-TcPushRejectClass -Text $p.Text
              $pmRow['reject_class'] = $rj.Class; $pmRow['reject_rc'] = $rj.Rc; $pmRow['reject_lines'] = $rj.Lines
            } catch {
              $pmRow['reject_class'] = 'unknown'; $pmRow['reject_lines'] = [string[]]@(('push-main: the refusal classifier threw: ' + $_.Exception.Message))
            }
            return 1
          }
          Say ("push-main: LANDED on {0}/{1} at {2}, on the first attempt, after {3} rehearsal round(s)." -f $Remote, $Branch, $s2.Head.Substring(0, 9), $rehearsals)
          $outcome = $(if ($rebasedAny) { 'landed-after-rebase' } else { 'landed' })
          return 0
        }
      } finally {
        # THE LOCK GOES BACK FIRST, then the row is written: a ledger write must never sit inside the critical section
        # this whole file exists to keep short, and nothing reads the row to decide anything. A round that hands the lock
        # back to rehearse again writes no row; the push's one row is written when it finally lands or refuses.
        if ($lockSw) { $lockSw.Stop(); $lockHeldTotal += $lockSw.Elapsed.TotalMilliseconds; $pmRow['lock_held_ms'] = [long][math]::Round($lockHeldTotal) }
        Exit-TcPushLock $lock
        if (-not $again) {
          # EVERYTHING THAT ENDS IN HERE WITHOUT LANDING STOPPED IN THE LOCK: a refusal, a rejected push, a fetch that
          # failed, or a throw that left the outcome unknown. A landing and a dry run carry no phase.
          if (-not ($outcome -ceq 'landed' -or $outcome -ceq 'landed-after-rebase' -or $outcome -ceq 'dry-run')) { $pmRow['phase'] = 'inlock' }
          & $writeRow
        }
      }
    }
    Say ("push-main: REFUSED - origin changed a chain-manifest script while this push waited in each of {0} rounds, so no rehearsal could keep up with it. The branch is rebased and nothing was pushed; run this again when main is quieter." -f $script:PmMaxRehearsalRounds)
    $outcome = 'refused-rehearsal-churn'
    # THE LAST THING THIS PUSH DID WAS HAND BACK THE LOCK over a check that did not cover it, so the refusal is in-lock.
    $pmRow['phase'] = 'inlock'
    & $writeRow
    return 1
  } catch {
    # A THROW THAT NO PATH WROTE A ROW FOR (review of W0.1R, 2026-09-23). Every return above writes one, and a throw
    # under the lock writes one in that finally; a throw OUTSIDE the lock (a leg runner, the seeder, a reader the guard
    # does not wrap) used to write none, so a crashed attempt was missing from every attempt count. It is written here,
    # outcome unknown at the phase the push had reached, and the throw goes on to the caller exactly as before.
    if (-not $rowState.Written) {
      # Only a throw OUTSIDE the lock reaches here unwritten, so this round took no lock: state says not-taken.
      $outcome = 'unknown'; $ledgerState = 'not-taken'
      $pmRow['phase'] = $curPhase
      & $writeRow
    }
    throw
  }
}

if ($SelfTest) {
  $f = 0; $cases = 0
  $kMF = 'MUST' + ' FIRE'; $kMNF = 'MUST' + ' NOT FIRE'; $kCT = 'CLEAN' + ' TWIN'
  # EVERY LINE THIS FILE ECHOES IS MARKED AS AN ECHO (see Say): the fixtures below make children print FAIL lines on
  # purpose, and one of those at the start of a stdout line would score this whole suite failed at exit 0.
  $script:TcSayPrefix = '  | '
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

  # ---- WHAT THE ROW RECORDS: the pure readers (2026-09-23, PLAN-push-derived-conflicts W0.1) ----
  # Each rule of the refusal classifier the end-to-end hook cases further down do not reach gets its own text here. A
  # repo path in these fixtures is split across a + so the gate-input walk does not read it as a file this suite loads.
  $gateX = 'ops\audit-' + 'fixture-x.ps1'
  $rjTa = Get-TcPushRejectClass -Text "pre-push: running the gate`npre-push: BLOCKED - the test-auditors check exited 1. This push leaves a watcher that cannot see its own bug.`n          full output kept at: /tmp/x.log"
  T ($kMF + '  a test-auditors refusal in the hook''s own wording is classed test-auditors, and its BLOCKED line is kept') `
    ($rjTa.Class -ceq 'test-auditors' -and @($rjTa.Lines).Count -eq 1 -and ([string]@($rjTa.Lines)[0]).StartsWith('pre-push: BLOCKED - the test-auditors')) ("class={0} lines={1}" -f $rjTa.Class, (@($rjTa.Lines) -join ' | '))
  $rjSt = Get-TcPushRejectClass -Text 'pre-push: REFUSING - git could not name a working tree for this push'
  T ($kMF + '  a structural REFUSING line is classed structure') ($rjSt.Class -ceq 'structure') ("class={0}" -f $rjSt.Class)
  $rjRm = Get-TcPushRejectClass -Text "To C:/fixture/origin`n ! [remote rejected] HEAD -> main (cannot lock ref 'refs/heads/main': is at 1111 but expected 2222)`nerror: failed to push some refs"
  T ($kMF + '  a remote that refused the ref update is classed remote') ($rjRm.Class -ceq 'remote' -and @($rjRm.Lines).Count -eq 1) ("class={0} lines={1}" -f $rjRm.Class, @($rjRm.Lines).Count)
  $rjPg = Get-TcPushRejectClass -Text ('PRE-PUSH-REFUSED cause=run-gates gate=' + $gateX)
  T ($kMF + '  the fixed PRE-PUSH-REFUSED line with a gate= names the class as cause:gate') ($rjPg.Class -ceq ('run-gates:' + $gateX)) ("class={0}" -f $rjPg.Class)
  $rjB3 = Get-TcPushRejectClass -Text "pre-push: BLOCKED - run-gates COULD NOT EVALUATE (exit 3). A 3 is NEVER a pass.`n          CAUSE: no gate worker slot.`nrun-gates: COULD NOT EVALUATE - waited 1200s for a gate worker slot"
  T ($kCT + '  a run-gates refusal with no FAIL line is classed run-gates alone, keeping the BLOCKED line and the gate''s own COULD NOT line') `
    ($rjB3.Class -ceq 'run-gates' -and @($rjB3.Lines).Count -eq 2 -and ([string]@($rjB3.Lines)[1]).StartsWith('run-gates: COULD NOT EVALUATE')) ("class={0} lines={1}" -f $rjB3.Class, (@($rjB3.Lines) -join ' | '))
  $longFail = '  FAIL  ' + $gateX + '  (exit 1) - ' + ('w' * 400)
  $rjCap = Get-TcPushRejectClass -Text ("pre-push: BLOCKED - run-gates exited 1.`n" + (@($longFail, $longFail, $longFail, $longFail, $longFail) -join "`n"))
  $capLens = @(@($rjCap.Lines) | ForEach-Object { ([string]$_).Length })
  T ($kCT + '  a refusal with many long lines keeps exactly 3, each cut to 300 characters, the BLOCKED line first') `
    ($rjCap.Class -ceq ('run-gates:' + $gateX) -and @($rjCap.Lines).Count -eq 3 -and ($capLens | Measure-Object -Maximum).Maximum -eq 300 -and ([string]@($rjCap.Lines)[0]).StartsWith('pre-push: BLOCKED - run-gates')) `
    ("class={0} count={1} lengths={2}" -f $rjCap.Class, @($rjCap.Lines).Count, ($capLens -join ','))

  $rgLine = 'run-gates: 3 of 7 self-test(s) already passed over these exact inputs and were not run again; 2 could not be keyed and always run'
  $rgr = Get-TcRunGatesReading -Lines @('run-gates: dispatching', $rgLine, 'RUN-GATES-COMPLETE pass=7 fail=0')
  T ($kMF + '  run-gates'' reuse line is read into its three numbers, and a run that dispatched is not a whole-run replay') `
    ($rgr.Reused -eq 3 -and $rgr.SelfTests -eq 7 -and $rgr.Unkeyable -eq 2 -and -not $rgr.WholeRun) ("reused={0} selftests={1} unkeyable={2} whole={3}" -f $rgr.Reused, $rgr.SelfTests, $rgr.Unkeyable, $rgr.WholeRun)
  $rgw = Get-TcRunGatesReading -Lines @('run-gates: PASSED - all 380 gate(s) passed at 2026-09-23T10:00:00Z over content byte-identical to this checkout now, so not one was run again (fixture). Pass -NoReuse to run them regardless.', 'RUN-GATES-COMPLETE pass=380 fail=0 reused=1')
  $rgn = Get-TcRunGatesReading -Lines @('nothing run-gates said')
  T ($kMF + '  a replayed whole verdict is read as WholeRun, so the leg records 0 seconds, and its numbers stay null') ($rgw.WholeRun -and $null -eq $rgw.Reused) ("whole={0} reused={1}" -f $rgw.WholeRun, $rgw.Reused)
  T ($kMNF + '  output with no reuse line leaves all three numbers null, never zero') ($null -eq $rgn.Reused -and $null -eq $rgn.SelfTests -and $null -eq $rgn.Unkeyable -and -not $rgn.WholeRun) ("reused={0} whole={1}" -f $rgn.Reused, $rgn.WholeRun)

  $htRan = Get-TcHookTestAuditors -Text "prepush-test-auditors: FULL RUN - fixture`nprepush-test-auditors: running the suite in full (measured 500s)"
  $htReu = Get-TcHookTestAuditors -Text 'prepush-test-auditors: REUSED key=0123456789abcdef - fixture'
  $htNn = Get-TcHookTestAuditors -Text 'prepush-test-auditors: NOT NEEDED - 2 pushed path(s) across 1 ref(s), none is a test-auditors input'
  $htUn = Get-TcHookTestAuditors -Text 'pre-push: BLOCKED - run-gates exited 1.'
  T ($kMF + '  the in-lock hook''s test-auditors lines read as ran, reused and not-needed, and a hook that never reached them as unknown') `
    ($htRan -ceq 'ran' -and $htReu -ceq 'reused' -and $htNn -ceq 'not-needed' -and $htUn -ceq 'unknown') ("ran={0} reused={1} notNeeded={2} unknown={3}" -f $htRan, $htReu, $htNn, $htUn)

  # ---- THE REVIEW OF W0.1R (2026-09-23): the readers it found blind ----
  # reject_rc: the fixed PRE-PUSH-REFUSED line carries no exit code, so a contention 3 and a red wrote the same class and
  # lines. The code is read off the hook's own BLOCKED line. Founding texts: the hook's exit-3 and exit-1 wordings.
  $rc3 = Get-TcPushRejectClass -Text "pre-push: BLOCKED - run-gates COULD NOT EVALUATE (exit 3). A 3 is NEVER a pass.`n          CAUSE: no gate worker slot.`nPRE-PUSH-REFUSED cause=run-gates"
  $rc3ta = Get-TcPushRejectClass -Text "pre-push: BLOCKED - the test-auditors check COULD NOT EVALUATE (exit 3). That is not a pass.`nPRE-PUSH-REFUSED cause=test-auditors"
  T ($kMF + '  a could-not-evaluate refusal under the fixed line records reject_rc 3, for run-gates and for test-auditors, beside its unchanged class') `
    ($rc3.Class -ceq 'run-gates' -and $rc3.Rc -eq 3 -and $rc3ta.Class -ceq 'test-auditors' -and $rc3ta.Rc -eq 3) ("rg={0}/{1} ta={2}/{3}" -f $rc3.Class, $rc3.Rc, $rc3ta.Class, $rc3ta.Rc)
  $rc1 = Get-TcPushRejectClass -Text "pre-push: BLOCKED - run-gates exited 1. This tree must not be pushed until it passes.`n  FAIL  fixture-gate  (exit 2) - x`nPRE-PUSH-REFUSED cause=run-gates gate=fixture-gate"
  $rc1ta = Get-TcPushRejectClass -Text "pre-push: BLOCKED - the test-auditors check exited 1. This push leaves a watcher that cannot see its own bug.`nPRE-PUSH-REFUSED cause=test-auditors"
  $rc1rh = Get-TcPushRejectClass -Text 'pre-push: BLOCKED - this push changes the daily chain and carries no passing rehearsal over recent data (exit 1).'
  $rcSt = Get-TcPushRejectClass -Text "pre-push: REFUSING - git could not name a working tree for this push`nPRE-PUSH-REFUSED cause=structure"
  $rcRm = Get-TcPushRejectClass -Text ' ! [remote rejected] HEAD -> main (cannot lock ref)'
  T ($kMNF + '  a red is still a red: exit 1 of run-gates, test-auditors and the rehearsal records reject_rc 1 (never the FAIL line''s own exit 2), and a structure or remote refusal records none') `
    ($rc1.Rc -eq 1 -and $rc1ta.Rc -eq 1 -and $rc1rh.Rc -eq 1 -and $null -eq $rcSt.Rc -and $null -eq $rcRm.Rc -and $rc1.Class -ceq 'run-gates:fixture-gate') `
    ("rg={0} ta={1} rh={2} structure={3} remote={4} class={5}" -f $rc1.Rc, $rc1ta.Rc, $rc1rh.Rc, $rcSt.Rc, $rcRm.Rc, $rc1.Class)

  # inlock_check: Code 3 (no completion marker) and a check that returned no Code decided nothing; only 0 is covered.
  $ckW0 = Get-TcInlockCheckWord -Check ([pscustomobject]@{ Code = 0 })
  $ckW1 = Get-TcInlockCheckWord -Check ([pscustomobject]@{ Code = 1 })
  $ckW3 = Get-TcInlockCheckWord -Check ([pscustomobject]@{ Code = 3 })
  $ckWn = Get-TcInlockCheckWord -Check ([pscustomobject]@{ Why = 'no code at all' })
  T ($kMF + '  the in-lock check word is covered for Code 0, not-covered for 1, and could-not-decide for 3 and for a check that returned no Code') `
    ($ckW0 -ceq 'covered' -and $ckW1 -ceq 'not-covered' -and $ckW3 -ceq 'could-not-decide' -and $ckWn -ceq 'could-not-decide') ("0={0} 1={1} 3={2} none={3}" -f $ckW0, $ckW1, $ckW3, $ckWn)

  # hook_ta_scope: B11 counts FULL test-auditors runs inside the lock, and hook_ta 'ran' says only that one ran.
  $hsFull = Get-TcHookTestAuditorsScope -Text 'prepush-test-auditors: running grocery\test-auditors.ps1 in full (measured 500s on 2026-09-10, bound 900s)'
  $hsSel = Get-TcHookTestAuditorsScope -Text 'prepush-test-auditors: running grocery\test-auditors.ps1 on 3 of 84 unit(s) (a full run measured 500s on 2026-09-10, bound 900s)'
  $hsNone = Get-TcHookTestAuditorsScope -Text 'prepush-test-auditors: REUSED key=0123456789abcdef - fixture'
  T ($kMF + '  hook_ta_scope tells a full in-lock test-auditors run from a selective one, with its unit counts, and is null when none ran') `
    ($hsFull -ceq 'full' -and $hsSel -ceq 'selective 3 of 84' -and $null -eq $hsNone) ("full={0} selective={1} none={2}" -f $hsFull, $hsSel, $hsNone)

  # subject_shas: the founding case is the housekeeping lane, three attempts of one change with three subjects_sha values
  # (an amended subject, then a dropped sibling commit). One hash over the set moves; per-subject hashes still OVERLAP.
  $sjA = [string[]]@('fix the widget', 'mustfire-census baseline retrained on a rise: 3,023 to 4,735')
  $sjAmend = [string[]]@('fix the widget', 'mustfire-census baseline retrained on a rise: 3,023 to 4,770')
  $sjAdded = [string[]]@('fix the widget', 'mustfire-census baseline retrained on a rise: 3,023 to 4,735', 'fix the red the gate found')
  $shA = Get-TcSubjectShaList -Subjects $sjA
  $shAm = Get-TcSubjectShaList -Subjects $sjAmend
  $shAd = Get-TcSubjectShaList -Subjects $sjAdded
  $ovAm = @($shA | Where-Object { $shAm -ccontains $_ }).Count
  $ovAd = @($shA | Where-Object { $shAd -ccontains $_ }).Count
  T ($kMF + '  an amended subject and an added fix commit each move subjects_sha, and subject_shas still overlaps the first attempt''s (1 and 2 shared of 2)') `
    ((Get-TcSubjectsShaOf -Subjects $sjA) -cne (Get-TcSubjectsShaOf -Subjects $sjAmend) -and (Get-TcSubjectsShaOf -Subjects $sjA) -cne (Get-TcSubjectsShaOf -Subjects $sjAdded) -and `
      $shA.Count -eq 2 -and $shAd.Count -eq 3 -and $ovAm -eq 1 -and $ovAd -eq 2 -and ([string]$shA[0]) -match '^[0-9a-f]{16}$' -and [string]::CompareOrdinal([string]$shA[0], [string]$shA[1]) -lt 0) `
    ("countA={0} countAdded={1} overlapAmend={2} overlapAdded={3} first={4}" -f $shA.Count, $shAd.Count, $ovAm, $ovAd, $(if ($shA) { $shA[0] }))
  # THE CAP (50), AT it and one PAST it, and a repeated subject counted once.
  $sj50 = [string[]]@(1..50 | ForEach-Object { 'subject ' + $_ })
  $sj51 = [string[]]@(1..51 | ForEach-Object { 'subject ' + $_ })
  $sh50 = Get-TcSubjectShaList -Subjects $sj50
  $sh51 = Get-TcSubjectShaList -Subjects $sj51
  $shDup = Get-TcSubjectShaList -Subjects ([string[]]@('same', 'same', 'other'))
  $shNone = Get-TcSubjectShaList -Subjects ([string[]]@())
  T ($kCT + '  subject_shas keeps all 50 hashes AT the cap of 50 and exactly 50 of 51 one past it, counts a repeated subject once, and is null for no subjects') `
    ($sh50.Count -eq 50 -and $sh51.Count -eq 50 -and $shDup.Count -eq 2 -and $null -eq $shNone) ("at={0} past={1} dup={2} none={3}" -f $sh50.Count, $sh51.Count, $shDup.Count, $(if ($null -eq $shNone) { 'null' } else { $shNone.Count }))

  $tmLine = 'TA-KEY-MOVED kind=board input=fixture/board.json'
  $tmA = Get-TcTaKeyMoved -Lines @('prepush-test-auditors: no pass reused (key=abc) - the inputs changed; running', $tmLine, 'prepush-test-auditors: running the suite in full')
  $tmN = Get-TcTaKeyMoved -Lines @('prepush-test-auditors: REUSED key=abc - fixture')
  $tmR = Get-TcTaKeyMoved -Lines @('  TA-KEY-MOVED kind=no-record')
  T ($kMF + '  the TA-KEY-MOVED line (W0.4) is copied as ta_moved exactly, and the no-record form with no input= is copied too') `
    ([string]::Equals([string]$tmA, $tmLine, [StringComparison]::Ordinal) -and [string]::Equals([string]$tmR, 'TA-KEY-MOVED kind=no-record', [StringComparison]::Ordinal)) ("moved={0} noRecord={1}" -f $tmA, $tmR)
  T ($kMNF + '  a test-auditors leg that printed no TA-KEY-MOVED line records ta_moved null') ($null -eq $tmN) ("got={0}" -f $tmN)

  $ctNn = Get-TcChainTouching -Outcome 'not-needed'
  $ctFail = Get-TcChainTouching -Outcome 'rehearsed-fail'
  $ctBlind = Get-TcChainTouching -Outcome 'could-not-rehearse'
  $ctErr = ''
  try { $null = Get-TcChainTouching -Outcome 'a-word-nobody-mapped' } catch { $ctErr = [string]$_.Exception.Message }
  T ($kCT + '  the rehearsal outcome maps to chain_touching: not-needed false, rehearsed-fail true, could-not-rehearse unknown (null)') `
    ($ctNn -eq $false -and $null -ne $ctNn -and $ctFail -eq $true -and $null -eq $ctBlind) ("notNeeded={0} fail={1} blind={2}" -f $ctNn, $ctFail, $ctBlind)
  T ($kMF + '  an outcome word outside rehearse-chain''s vocabulary THROWS, so a new word is loud rather than a silent null') ($ctErr -match 'a-word-nobody-mapped') ("err={0}" -f $ctErr)
  $rhOc = Get-TcRehearsalOutcome -Lines @('CHAIN-REHEARSAL-CHECK-COMPLETE code=1 outcome=no-verdict', 'chain-rehearsal: rehearsing HEAD now', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass')
  T ($kMF + '  the LAST CHAIN-REHEARSAL-CHECK-COMPLETE line decides the outcome, as -ForPush prints a second decision after rehearsing') ($rhOc -ceq 'rehearsed-pass') ("outcome={0}" -f $rhOc)

  $seBoth = Get-TcPushSession -Environment @{ CLAUDE_CODE_HOST_SESSION_ID = 'local_host-fixture'; CLAUDE_CODE_SESSION_ID = 'own-fixture' }
  $seOwn = Get-TcPushSession -Environment @{ CLAUDE_CODE_SESSION_ID = 'own-fixture' }
  $seNone = Get-TcPushSession -Environment @{ UNRELATED = 'x' }
  T ($kCT + '  the session is the host id when one is set, the session''s own id otherwise, and null for a push no Claude session made') `
    ($seBoth.Value -ceq 'local_host-fixture' -and $seBoth.Var -ceq 'CLAUDE_CODE_HOST_SESSION_ID' -and $seOwn.Value -ceq 'own-fixture' -and $seOwn.Var -ceq 'CLAUDE_CODE_SESSION_ID' -and $null -eq $seNone.Value -and $null -eq $seNone.Var) `
    ("both={0}/{1} own={2}/{3} none={4}" -f $seBoth.Value, $seBoth.Var, $seOwn.Value, $seOwn.Var, $seNone.Value)

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
    [IO.File]::WriteAllText($taGreen, ("`$in = [Console]::In.ReadToEnd()`n[IO.File]::WriteAllText('" + $taSeen + "', `$in)`nWrite-Output 'TA-KEY-MOVED kind=content input=fixture/suite.ps1'`nWrite-Output 'prepush-test-auditors: PASS'`nWrite-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n"))
    [IO.File]::WriteAllText($taBare, "Write-Output 'prepush-test-auditors: started'`nexit 0`n")
    $taLine = 'HEAD ' + $A + ' refs/heads/main ' + $B
    $tr = Invoke-TcWarmTestAuditors -Dir $taDir -RefLine $taLine -Script $taRed
    T ($kMF + '  a test-auditors check that refuses outside the lock refuses the push (Code 1), so it never queues') `
      ($tr.Ran -and $tr.Code -eq 1 -and $tr.Why -match 'test-auditors') ("ran={0} code={1} why={2}" -f $tr.Ran, $tr.Code, $tr.Why)
    $tg = Invoke-TcWarmTestAuditors -Dir $taDir -RefLine $taLine -Script $taGreen
    $seen = if (Test-Path -LiteralPath $taSeen) { ([IO.File]::ReadAllText($taSeen)).Trim() } else { '<no stdin recorded>' }
    T ($kCT + '  a passing check is Code 0 AND it was handed the exact ref line the hook will hand it, so its keyed pass is the one the in-lock run looks up') `
      ($tg.Ran -and $tg.Code -eq 0 -and [string]::Equals($seen, $taLine, [StringComparison]::Ordinal)) ("ran={0} code={1} stdin='{2}'" -f $tg.Ran, $tg.Code, $seen)
    # FOR THE ROW (W0.1, W0.4): the leg hands back its own exit code, an integer time and its lines, and the TA-KEY-MOVED
    # line it printed before running is what ta_moved copies.
    $tgMoved = Get-TcTaKeyMoved -Lines $tg.Lines
    T ($kCT + '  a passing check also returns its exit code, an integer time and its lines, and its TA-KEY-MOVED line reads back exactly') `
      ($tg.Exit -eq 0 -and $tg.Sec -is [int] -and $tg.Sec -ge 0 -and [string]::Equals([string]$tgMoved, 'TA-KEY-MOVED kind=content input=fixture/suite.ps1', [StringComparison]::Ordinal)) `
      ("exit={0} sec={1} moved={2}" -f $tg.Exit, $tg.Sec, $tgMoved)
    # THE RUN-GATES LEG NOW RUNS THROUGH A PIPELINE (W0.1), so the three things Start-Process gave it are asserted here:
    # the exit code survives (a red must stay red), the child runs in the checkout it judges, and its lines come back.
    $rgDir = Join-Path $taDir 'rgfx'
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $rgDir 'ops')
    $rgStub = Join-Path $rgDir 'ops\run-gates.ps1'
    $rgCwd = Join-Path $taDir 'rg-cwd.txt'
    [IO.File]::WriteAllText($rgStub, ("[IO.File]::WriteAllText('" + $rgCwd + "', (Get-Location).Path)`nWrite-Output '" + $rgLine + "'`nWrite-Output 'RUN-GATES-COMPLETE pass=7 fail=0'`nexit 0`n"))
    $wgOk = Invoke-TcWarmGate -Dir $rgDir
    $cwdSeen = if (Test-Path -LiteralPath $rgCwd) { ([IO.File]::ReadAllText($rgCwd)).Trim() } else { '<not written>' }
    $wgOkR = Get-TcRunGatesReading -Lines $wgOk.Lines
    T ($kCT + '  the run-gates leg run through the pipeline still returns its exit code 0, ran in the checkout it judges, and hands back its reuse line') `
      ($wgOk.Ran -and $wgOk.Code -eq 0 -and $wgOk.Sec -is [int] -and [string]::Equals($cwdSeen.TrimEnd('\'), $rgDir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -and $wgOkR.Reused -eq 3) `
      ("ran={0} code={1} sec={2} cwd={3} reused={4}" -f $wgOk.Ran, $wgOk.Code, $wgOk.Sec, $cwdSeen, $wgOkR.Reused)
    [IO.File]::WriteAllText($rgStub, "Write-Output '  FAIL  fixture-gate  (exit 1)'`nexit 1`n")
    $wgRed = Invoke-TcWarmGate -Dir $rgDir
    T ($kMF + '  a run-gates that exits 1 through the pipeline is Code 1, so a red gate outside the lock still refuses') `
      ($wgRed.Ran -and $wgRed.Code -eq 1) ("ran={0} code={1}" -f $wgRed.Ran, $wgRed.Code)
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

    # ---- THE REHEARSAL JUDGES THE REBASED CONTENT (2026-09-23) ----
    # Founding case: on 2026-09-23 several landings rehearsed the content from BEFORE push-main's in-lock rebase, the hook
    # found no verdict for the rebased content, and each push paid a second 13-to-15-minute rehearsal. The fixture models
    # ops\rehearse-chain.ps1's verdict key at small scale: a verdict covers one blob of chain.ps1 (the "manifest"), the
    # rehearsal runner records one for whatever HEAD it sees, and the in-lock check asks whether HEAD's blob has one. The
    # runner can also make origin MOVE while it runs, from a second clone, which is the window the trade-off is about.
    $script:rhVerdicts = @{}
    $script:rhSeen = New-Object Collections.ArrayList
    $script:rhMoves = @()
    $script:rhLockFree = $null
    $mover = New-Clone 'mover'
    $blobOf = { param($d) $bo = @(& git -C $d rev-parse 'HEAD:chain.ps1' 2>$null); if ($LASTEXITCODE -eq 0 -and $bo.Count) { ([string]$bo[0]).Trim() } else { 'no-chain' } }
    $moveOrigin = { param([string]$File)
      $null = & git -C $mover pull -q --rebase origin main 2>$null
      [IO.File]::WriteAllText((Join-Path $mover $File), ('moved ' + [guid]::NewGuid().ToString('N')))
      $null = & git -C $mover add -- $File 2>$null; $null = & git -C $mover commit -q -m ('move ' + $File) 2>$null
      $null = & git -C $mover push -q origin HEAD:main 2>$null
    }
    $rhModel = { param($d)
      [void]$script:rhSeen.Add(([string](@(& git -C $d rev-parse HEAD 2>$null))[0]).Trim())
      $pr = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -Name ($prefix + '0'))
      $script:rhLockFree = [bool](@($pr | Where-Object { "$_".Trim() -eq 'FREE' }).Count)
      $script:rhVerdicts[(& $blobOf $d)] = $true
      if ($script:rhMoves.Count) { $mf = $script:rhMoves[0]; $script:rhMoves = @($script:rhMoves | Select-Object -Skip 1); & $moveOrigin $mf }
      # Rehearsed: this model records a NEW verdict every time it runs, as a real rehearsal does (the row's rehearsed).
      return [pscustomobject]@{ Code = 0; Why = 'fixture: rehearsed-pass'; Rehearsed = $true }
    }
    $rhCheck = { param($d, $h, $r) if ($script:rhVerdicts.ContainsKey((& $blobOf $d))) { [pscustomobject]@{ Code = 0; Why = 'covered' } } else { [pscustomobject]@{ Code = 1; Why = 'fixture: no-verdict for the rebased chain.ps1' } } }
    $greenGate = { param($d) [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $newPusher = { param([string]$Name)
      $pd = New-Clone $Name
      [IO.File]::WriteAllText((Join-Path $pd ($Name + '.txt')), $Name)
      $null = & git -C $pd add -- ($Name + '.txt') 2>$null; $null = & git -C $pd commit -q -m $Name 2>$null
      return $pd
    }
    $tipOf = { ([string](@(& git -C $origin rev-parse main 2>$null))[0]).Trim() }
    $isAnc = { param($d, $anc, $desc) $null = & git -C $d merge-base --is-ancestor $anc $desc 2>$null; return ($LASTEXITCODE -eq 0) }

    # MUST FIRE, the founding order: origin moved over chain.ps1 BEFORE this push started. The one rehearsal must see a
    # HEAD already rebased on top of that move, with the push lock free while it runs, and the push lands on it.
    $q1 = & $newPusher 'q1'
    & $moveOrigin 'chain.ps1'
    $moved1 = & $tipOf
    $script:rhSeen.Clear(); $script:rhMoves = @()
    $tokenWas2 = $env:TC_PUSH_LOCK_HOLDER; $env:TC_PUSH_LOCK_HOLDER = $null
    $rQ1 = Invoke-TcPushMain -Dir $q1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck
    $env:TC_PUSH_LOCK_HOLDER = $tokenWas2
    $seen1 = $(if ($script:rhSeen.Count) { [string]$script:rhSeen[0] } else { '' })
    T ($kMF + '  the rehearsal judges the REBASED content: origin moved over a manifest script before the push, and the one rehearsal saw a HEAD already on top of it, outside the lock') `
      ($rQ1 -eq 0 -and $script:rhSeen.Count -eq 1 -and $seen1 -and (& $isAnc $q1 $moved1 $seen1) -and $script:rhLockFree -eq $true -and (& $tipOf) -eq $seen1) `
      ("rc={0} rehearsals={1} sawRebased={2} lockFree={3} landedWhatWasRehearsed={4}" -f $rQ1, $script:rhSeen.Count, $(if ($seen1) { & $isAnc $q1 $moved1 $seen1 } else { $false }), $script:rhLockFree, ((& $tipOf) -eq $seen1))

    # MUST FIRE, the trade-off: origin changes a manifest script WHILE the first rehearsal runs. The rebase inside the lock
    # moves the key, so the push hands the lock back and rehearses the rebased content again before it pushes.
    $q2 = & $newPusher 'q2'
    $script:rhSeen.Clear(); $script:rhMoves = @('chain.ps1')
    $rQ2 = Invoke-TcPushMain -Dir $q2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck
    $moved2 = ([string](@(& git -C $mover rev-parse HEAD 2>$null))[0]).Trim()
    $seen2 = $(if ($script:rhSeen.Count -ge 2) { [string]$script:rhSeen[1] } else { '' })
    T ($kMF + '  a rebase inside the lock that changes a manifest script re-rehearses before the push: two rehearsals, the second over the moved content, and it lands') `
      ($rQ2 -eq 0 -and $script:rhSeen.Count -eq 2 -and $seen2 -and (& $isAnc $q2 $moved2 $seen2) -and (& $tipOf) -eq $seen2) `
      ("rc={0} rehearsals={1} secondSawMove={2}" -f $rQ2, $script:rhSeen.Count, $(if ($seen2) { & $isAnc $q2 $moved2 $seen2 } else { $false }))

    # CLEAN TWIN: origin moves WHILE the rehearsal runs, over a file no rehearsal covers. The rebase inside the lock keeps
    # the key, the recorded verdict is reused, and the push lands after ONE rehearsal carrying the moved commit.
    $q3 = & $newPusher 'q3'
    $script:rhSeen.Clear(); $script:rhMoves = @('notes.txt')
    $rQ3 = Invoke-TcPushMain -Dir $q3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck
    $moved3 = ([string](@(& git -C $mover rev-parse HEAD 2>$null))[0]).Trim()
    $head3 = ([string](@(& git -C $q3 rev-parse HEAD 2>$null))[0]).Trim()
    T ($kCT + '  a rebase inside the lock over non-manifest commits reuses the verdict: one rehearsal, and the landed HEAD carries the moved commit') `
      ($rQ3 -eq 0 -and $script:rhSeen.Count -eq 1 -and (& $isAnc $q3 $moved3 $head3) -and (& $tipOf) -eq $head3) `
      ("rc={0} rehearsals={1} carriesMove={2} landed={3}" -f $rQ3, $script:rhSeen.Count, (& $isAnc $q3 $moved3 $head3), ((& $tipOf) -eq $head3))

    # THE ROUND CAP (3), AT it and one PAST it. At the bar: origin changes chain.ps1 during rounds 1 and 2, and round 3
    # lands. Past it: origin changes chain.ps1 in all three rounds, and the push is refused rather than looping on.
    $q4 = & $newPusher 'q4'
    $script:rhSeen.Clear(); $script:rhMoves = @('chain.ps1', 'chain.ps1')
    $ledRoot4 = Join-Path $tmp 'led4'
    $rQ4 = Invoke-TcPushMain -Dir $q4 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledRoot4
    T ($kMNF + '  at the 3-round cap (origin changes a manifest script in rounds 1 and 2) the push still lands, after exactly 3 rehearsals') `
      ($rQ4 -eq 0 -and $script:rhSeen.Count -eq 3) ("rc={0} rehearsals={1}" -f $rQ4, $script:rhSeen.Count)
    $q5 = & $newPusher 'q5'
    $script:rhSeen.Clear(); $script:rhMoves = @('chain.ps1', 'chain.ps1', 'chain.ps1')
    $ledRoot5 = Join-Path $tmp 'led5'
    $rQ5 = Invoke-TcPushMain -Dir $q5 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledRoot5
    $head5 = ([string](@(& git -C $q5 rev-parse HEAD 2>$null))[0]).Trim()
    $row5Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRoot5)
    $row5 = @($row5Raw)
    T ($kMF + '  one round past the cap (origin changes a manifest script in all 3 rounds) is refused, nothing is pushed, and ONE ledger row says refused-rehearsal-churn') `
      ($rQ5 -eq 1 -and $script:rhSeen.Count -eq 3 -and -not (& $isAnc $q5 $head5 (& $tipOf)) -and $row5.Count -eq 1 -and $row5[0].outcome -eq 'refused-rehearsal-churn') `
      ("rc={0} rehearsals={1} rows={2} outcome={3}" -f $rQ5, $script:rhSeen.Count, $row5.Count, $(if ($row5.Count) { $row5[0].outcome } else { '' }))

    # ---- W0.1R: THE ONE ROW DESCRIBES THE WHOLE LOOP (2026-09-23) ----
    # Founding case: W0.1 was written before this loop landed, so its row could not say that a push took two rounds,
    # entered the lock twice, or what the in-lock check found; and a round-2 refusal wrote state=not-taken with nothing
    # to say the lock had been taken in round 1. Each case below reads the ONE row its push wrote.
    $churnRow = $(if ($row5.Count) { $row5[0] } else { $null })
    T ($kMF + '  the churn refusal is in-lock: its row says phase inlock, rounds 3, lock_takes 3, rehearsals 3 and inlock_check not-covered (the last take''s check)') `
      ($null -ne $churnRow -and [string]$churnRow.phase -ceq 'inlock' -and [int]$churnRow.rounds -eq 3 -and [int]$churnRow.lock_takes -eq 3 -and [int]$churnRow.rehearsals -eq 3 -and [string]$churnRow.inlock_check -ceq 'not-covered') `
      ("phase={0} rounds={1} takes={2} rehearsals={3} check={4}" -f $(if ($churnRow) { $churnRow.phase }), $(if ($churnRow) { $churnRow.rounds }), $(if ($churnRow) { $churnRow.lock_takes }), $(if ($churnRow) { $churnRow.rehearsals }), $(if ($churnRow) { $churnRow.inlock_check }))
    # AT the cap it lands, and the check word is the LAST take's: takes 1 and 2 found the rebased content uncovered, and
    # take 3 ran no in-lock rebase at all, so it says not-run. A word carried over from an earlier take would say not-covered.
    $capRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledRoot4)
    $capRows = @($capRaw)
    $capRow = $(if ($capRows.Count) { $capRows[$capRows.Count - 1] } else { $null })
    T ($kCT + '  the landing AT the cap writes one row: rounds 3, lock_takes 3, and inlock_check not-run, because its last take ran no check') `
      ($rQ4 -eq 0 -and $capRows.Count -eq 1 -and [string]$capRow.outcome -ceq 'landed-after-rebase' -and [int]$capRow.rounds -eq 3 -and [int]$capRow.lock_takes -eq 3 -and [string]$capRow.inlock_check -ceq 'not-run' -and $null -eq $capRow.phase) `
      ("rc={0} rows={1} outcome={2} rounds={3} takes={4} check={5} phase={6}" -f $rQ4, $capRows.Count, $(if ($capRow) { $capRow.outcome }), $(if ($capRow) { $capRow.rounds }), $(if ($capRow) { $capRow.lock_takes }), $(if ($capRow) { $capRow.inlock_check }), $(if ($capRow) { $capRow.phase }))

    # MUST FIRE: a push that hands the lock back ONCE and then lands. Round 1: origin changes chain.ps1 while the rehearsal
    # runs, so the in-lock check does not cover the rebased content and the lock goes back. Round 2: origin moves again,
    # over a file no rehearsal covers, so the in-lock rebase keeps the key, the check says covered, and it lands.
    # THE WAITS ARE READ AT THEIR SOURCE: for this one run Enter-TcPushLock is wrapped, so each take's WaitedMs is kept
    # exactly as the lock reported it, and the row's sum is checked against the takes rather than against itself. The
    # real function is put back in finally, before any other case runs.
    $hb = & $newPusher 'hb'
    $script:rhSeen.Clear(); $script:rhMoves = @('chain.ps1', 'notes.txt')
    $ledHb = Join-Path $tmp 'ledhb'
    $script:lockWaitsSeen = [Collections.Generic.List[double]]::new()
    $script:enterTcPushLockReal = ${function:Enter-TcPushLock}
    $rHb = $null
    try {
      function script:Enter-TcPushLock {
        param([int]$WaitSec, [int]$PollMs, [string]$Prefix, [string]$QueueRoot, [scriptblock]$OnWait, [switch]$NoInherit)
        $lk = & $script:enterTcPushLockReal @PSBoundParameters
        [void]$script:lockWaitsSeen.Add([double]$lk.WaitedMs)
        return $lk
      }
      $rHb = Invoke-TcPushMain -Dir $hb -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledHb
    } finally {
      Set-Item -LiteralPath 'function:script:Enter-TcPushLock' -Value $script:enterTcPushLockReal
    }
    $hbRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledHb)
    $hbRows = @($hbRaw)
    $hbRow = $(if ($hbRows.Count) { $hbRows[$hbRows.Count - 1] } else { $null })
    $hbWaits = $script:lockWaitsSeen.ToArray()
    $hbSum = 0.0
    foreach ($w in $hbWaits) { $hbSum += $w }
    $hbLast = $(if ($hbWaits.Count) { [long][math]::Round($hbWaits[$hbWaits.Count - 1]) } else { -1 })
    T ($kMF + '  a push that hands the lock back once and then lands writes ONE row: rounds 2, lock_takes 2, inlock_check covered, lock_wait_ms_total the sum of both takes'' waits, and waitMs the last take''s') `
      ($rHb -eq 0 -and $hbRows.Count -eq 1 -and [int]$hbRow.rounds -eq 2 -and [int]$hbRow.lock_takes -eq 2 -and [string]$hbRow.inlock_check -ceq 'covered' -and $hbWaits.Count -eq 2 -and `
        [long]$hbRow.lock_wait_ms_total -eq [long][math]::Round($hbSum) -and [long]$hbRow.waitMs -eq $hbLast -and [int]$hbRow.rehearsals -eq 2 -and [int]$hbRow.rehearsed -eq 2 -and `
        [string]$hbRow.outcome -ceq 'landed-after-rebase' -and (@($hbRow.rebase_phases) -join ',') -ceq 'inlock,inlock' -and $null -eq $hbRow.phase) `
      ("rc={0} rows={1} rounds={2} takes={3} check={4} waits={5} total={6} waitMs={7} rehearsals={8} rehearsed={9} outcome={10} phases={11}" -f $rHb, $hbRows.Count, $(if ($hbRow) { $hbRow.rounds }), $(if ($hbRow) { $hbRow.lock_takes }), $(if ($hbRow) { $hbRow.inlock_check }), (@($hbWaits) -join '/'), $(if ($hbRow) { $hbRow.lock_wait_ms_total }), $(if ($hbRow) { $hbRow.waitMs }), $(if ($hbRow) { $hbRow.rehearsals }), $(if ($hbRow) { $hbRow.rehearsed }), $(if ($hbRow) { $hbRow.outcome }), $(if ($hbRow) { @($hbRow.rebase_phases) -join ',' }))
    $hbReal = ${function:Enter-TcPushLock}
    T ($kCT + '  after that case the real Enter-TcPushLock is back, so no later case runs through the wrapper') `
      ([object]::ReferenceEquals($hbReal, $script:enterTcPushLockReal) -or [string]::Equals([string]$hbReal, [string]$script:enterTcPushLockReal, [StringComparison]::Ordinal)) 'the wrapper was left in place'

    # MUST FIRE: a refusal BEFORE the lock in round 2 counts the one take round 1 handed back. `state` keeps its old
    # meaning, what the last round got, so the row says not-taken; lock_takes is what says the lock was entered at all.
    # The round-2 gate takes at least 2 s, so catchup_sec has a LOWER bar that load can only help (never an upper one).
    $r2c = & $newPusher 'r2c'
    $script:rhSeen.Clear(); $script:rhMoves = @('chain.ps1')
    $script:twoGateRuns = 0
    $twoGate = { param($d)
      $script:twoGateRuns++
      if ($script:twoGateRuns -ge 2) { Start-Sleep -Seconds 2; return [pscustomobject]@{ Ran = $true; Code = 1; Why = 'fixture: run-gates red in round 2' } }
      return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' }
    }
    $ledR2c = Join-Path $tmp 'ledr2c'
    $rR2c = Invoke-TcPushMain -Dir $r2c -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $twoGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledR2c
    $r2cRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledR2c)
    $r2cRows = @($r2cRaw)
    $r2cRow = $(if ($r2cRows.Count) { $r2cRows[$r2cRows.Count - 1] } else { $null })
    T ($kMF + '  a round-2 refusal before the lock records lock_takes 1, phase catchup, rounds 2, outcome refused-gate-red and at least the 2 s of its round-2 gate in catchup_sec, beside state not-taken') `
      ($rR2c -eq 1 -and $script:twoGateRuns -eq 2 -and $r2cRows.Count -eq 1 -and [string]$r2cRow.outcome -ceq 'refused-gate-red' -and [int]$r2cRow.lock_takes -eq 1 -and `
        [string]$r2cRow.phase -ceq 'catchup' -and [int]$r2cRow.rounds -eq 2 -and [string]$r2cRow.state -ceq 'not-taken' -and [string]$r2cRow.inlock_check -ceq 'not-covered' -and [int]$r2cRow.catchup_sec -ge 2) `
      ("rc={0} gateRuns={1} rows={2} outcome={3} takes={4} phase={5} rounds={6} state={7} check={8} catchup={9}" -f $rR2c, $script:twoGateRuns, $r2cRows.Count, $(if ($r2cRow) { $r2cRow.outcome }), $(if ($r2cRow) { $r2cRow.lock_takes }), $(if ($r2cRow) { $r2cRow.phase }), $(if ($r2cRow) { $r2cRow.rounds }), $(if ($r2cRow) { $r2cRow.state }), $(if ($r2cRow) { $r2cRow.inlock_check }), $(if ($r2cRow) { $r2cRow.catchup_sec }))

    # ---- THE REVIEW OF W0.1R (2026-09-23): the catch-up sync, the check word and the row a throw leaves ----
    # Founding case: every hand-back fixture above moved origin only DURING THE REHEARSAL, so the round-2 sync never
    # rebased and never conflicted, and three mutants survived the whole suite: every sync labelled preflight, preflight_sha
    # overwritten on every round, and a check that printed no marker read as not-covered. The review's harness moved origin
    # from INSIDE the in-lock check while it answered not-covered, which is the shape these cases copy: $ckMoves is what the
    # check pushes from the mover the moment it refuses to cover the rebased content.
    $script:ckMoves = @()
    $moveOriginText = { param([string]$File, [string]$Text)
      $null = & git -C $mover pull -q --rebase origin main 2>$null
      [IO.File]::WriteAllText((Join-Path $mover $File), $Text)
      $null = & git -C $mover add -- $File 2>$null; $null = & git -C $mover commit -q -m ('edit ' + $File) 2>$null
      $null = & git -C $mover push -q origin HEAD:main 2>$null
    }
    $ckMover = { param($d, $h, $r)
      $res = & $rhCheck $d $h $r
      if ($res.Code -ne 0 -and $script:ckMoves.Count) {
        $mv = $script:ckMoves[0]; $script:ckMoves = @($script:ckMoves | Select-Object -Skip 1)
        & $moveOriginText $mv.File $mv.Text
      }
      return $res
    }
    $tenLines = { param([string]$First, [string]$Tenth) ((@($First) + @(2..9 | ForEach-Object { 'l' + $_ }) + @($Tenth)) -join "`n") + "`n" }

    # MUST FIRE: a catch-up sync that REBASES. Round 1's rehearsal moves chain.ps1, so the in-lock check does not cover the
    # rebased content, and while it says so origin moves again over a file nothing covers. Round 2's fetch and rebase meet
    # that move before the lock: rebase_phases must say inlock then CATCHUP, and preflight_sha must still be the tip origin
    # held when the push started, never the round-2 fetch.
    $cu = & $newPusher 'cu'
    $cuStartTip = & $tipOf
    $script:rhSeen.Clear(); $script:rhMoves = @('chain.ps1')
    $script:ckMoves = @([pscustomobject]@{ File = 'notes.txt'; Text = ('catch-up ' + [guid]::NewGuid().ToString('N')) })
    $ledCu = Join-Path $tmp 'ledcu'
    $rCu = Invoke-TcPushMain -Dir $cu -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $ckMover -LedgerRoot $ledCu
    $cuMoveTip = ([string](@(& git -C $mover rev-parse HEAD 2>$null))[0]).Trim()
    $cuRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCu)
    $cuRows = @($cuRaw)
    $cuRow = $(if ($cuRows.Count) { $cuRows[$cuRows.Count - 1] } else { $null })
    T ($kMF + '  a round-2 sync that rebases is recorded as catchup (rebase_phases inlock,catchup), and preflight_sha stays the tip origin held at the start, not the round-2 fetch') `
      ($rCu -eq 0 -and $cuRows.Count -eq 1 -and [string]$cuRow.outcome -ceq 'landed-after-rebase' -and [int]$cuRow.rounds -eq 2 -and (@($cuRow.rebase_phases) -join ',') -ceq 'inlock,catchup' -and `
        [string]$cuRow.preflight_sha -ceq $cuStartTip -and [string]$cuRow.preflight_sha -cne $cuMoveTip -and $script:ckMoves.Count -eq 0) `
      ("rc={0} rows={1} outcome={2} rounds={3} phases={4} preflight={5} start={6} round2fetch={7} movesLeft={8}" -f $rCu, $cuRows.Count, $(if ($cuRow) { $cuRow.outcome }), $(if ($cuRow) { $cuRow.rounds }), $(if ($cuRow) { @($cuRow.rebase_phases) -join ',' }), $(if ($cuRow) { $cuRow.preflight_sha }), $cuStartTip, $cuMoveTip, $script:ckMoves.Count)

    # MUST FIRE: a catch-up sync that CONFLICTS. F.txt has ten lines; the branch edits line 10. Before the push starts
    # origin edits line 1 (X), so the pre-flight rebase is clean and preflight_sha is X. Round 1's rehearsal moves
    # chain.ps1 (M1), the in-lock rebase takes it and the grant is M1; the check refuses to cover it and, while it does,
    # origin edits line 10 (Y). Round 2's rebase conflicts on F.txt against Y. The row must say phase catchup, name F.txt,
    # and name Y as what it conflicted against - the grant says M1, which that rebase never saw.
    $null = & git -C $mover pull -q --rebase origin main 2>$null
    [IO.File]::WriteAllText((Join-Path $mover 'F.txt'), (& $tenLines 'l1' 'l10'))
    $null = & git -C $mover add -- F.txt 2>$null; $null = & git -C $mover commit -q -m 'F ten lines' 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    $cc = New-Clone 'cc'
    [IO.File]::WriteAllText((Join-Path $cc 'F.txt'), (& $tenLines 'l1' 'mine10'))
    $null = & git -C $cc add -- F.txt 2>$null; $null = & git -C $cc commit -q -m 'cc edits line 10' 2>$null
    & $moveOriginText 'F.txt' (& $tenLines 'x1' 'l10')
    $ccX = & $tipOf
    $script:rhSeen.Clear(); $script:rhMoves = @('chain.ps1')
    $script:ckMoves = @([pscustomobject]@{ File = 'F.txt'; Text = (& $tenLines 'x1' 'theirs10') })
    $ledCc = Join-Path $tmp 'ledcc'
    $rCc = Invoke-TcPushMain -Dir $cc -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $ckMover -LedgerRoot $ledCc
    $ccY = & $tipOf
    $ccRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCc)
    $ccRows = @($ccRaw)
    $ccRow = $(if ($ccRows.Count) { $ccRows[$ccRows.Count - 1] } else { $null })
    $ccFiles = @($(if ($ccRow) { $ccRow.conflict_files } else { @() }))
    $ccMid = (Test-Path -LiteralPath (Join-Path $cc '.git\rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $cc '.git\rebase-apply'))
    T ($kMF + '  a round-2 conflict before the lock records phase catchup, rebase_phases preflight,inlock,catchup, the one conflicted file, and conflict_target the round-2 fetch (Y), not the grant (M1)') `
      ($rCc -eq 1 -and $ccRows.Count -eq 1 -and [string]$ccRow.outcome -ceq 'refused-rebase-conflict' -and [string]$ccRow.phase -ceq 'catchup' -and (@($ccRow.rebase_phases) -join ',') -ceq 'preflight,inlock,catchup' -and `
        $ccFiles.Count -eq 1 -and [string]$ccFiles[0] -ceq 'F.txt' -and [string]$ccRow.conflict_scope -ceq 'first-stop' -and [string]$ccRow.conflict_target -ceq $ccY -and [string]$ccRow.grant -cne $ccY -and `
        [string]$ccRow.preflight_sha -ceq $ccX -and [int]$ccRow.rounds -eq 1 -and [int]$ccRow.lock_takes -eq 1 -and [string]$ccRow.state -ceq 'not-taken' -and -not $ccMid) `
      ("rc={0} rows={1} outcome={2} phase={3} phases={4} files={5} scope={6} target={7} Y={8} grant={9} preflight={10} X={11} rounds={12} takes={13} state={14} midRebase={15}" -f $rCc, $ccRows.Count, $(if ($ccRow) { $ccRow.outcome }), $(if ($ccRow) { $ccRow.phase }), $(if ($ccRow) { @($ccRow.rebase_phases) -join ',' }), ($ccFiles -join ','), $(if ($ccRow) { $ccRow.conflict_scope }), $(if ($ccRow) { $ccRow.conflict_target }), $ccY, $(if ($ccRow) { $ccRow.grant }), $(if ($ccRow) { $ccRow.preflight_sha }), $ccX, $(if ($ccRow) { $ccRow.rounds }), $(if ($ccRow) { $ccRow.lock_takes }), $(if ($ccRow) { $ccRow.state }), $ccMid)

    # MUST FIRE: an in-lock check that DECIDED NOTHING (Code 3, no completion marker) is could-not-decide on the row, never
    # not-covered. It still hands the lock back, as any check that does not cover does; round 2's gate is red, so the row
    # carries the last take's word.
    $cn = & $newPusher 'cn'
    $script:rhSeen.Clear(); $script:rhMoves = @('chain.ps1')
    $script:cnGateRuns = 0
    $cnGate = { param($d) $script:cnGateRuns++; if ($script:cnGateRuns -ge 2) { return [pscustomobject]@{ Ran = $true; Code = 1; Why = 'fixture: run-gates red in round 2' } }; return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $cnCheck = { param($d, $h, $r) [pscustomobject]@{ Code = 3; Why = 'fixture: the verdict check printed no completion marker' } }
    $ledCn = Join-Path $tmp 'ledcn'
    $rCn = Invoke-TcPushMain -Dir $cn -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $cnGate -RehearsalRunner $rhModel -RehearsalCheck $cnCheck -LedgerRoot $ledCn
    $cnRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCn)
    $cnRows = @($cnRaw)
    $cnRow = $(if ($cnRows.Count) { $cnRows[$cnRows.Count - 1] } else { $null })
    T ($kMF + '  an in-lock check that returned Code 3 is recorded could-not-decide, hands the lock back, and the round-2 refusal keeps that word') `
      ($rCn -eq 1 -and $script:cnGateRuns -eq 2 -and $cnRows.Count -eq 1 -and [string]$cnRow.inlock_check -ceq 'could-not-decide' -and [int]$cnRow.lock_takes -eq 1 -and [string]$cnRow.phase -ceq 'catchup' -and [string]$cnRow.outcome -ceq 'refused-gate-red') `
      ("rc={0} gateRuns={1} rows={2} check={3} takes={4} phase={5} outcome={6}" -f $rCn, $script:cnGateRuns, $cnRows.Count, $(if ($cnRow) { $cnRow.inlock_check }), $(if ($cnRow) { $cnRow.lock_takes }), $(if ($cnRow) { $cnRow.phase }), $(if ($cnRow) { $cnRow.outcome }))

    # MUST FIRE: a throw OUTSIDE the lock writes the run's one row, and the throw still reaches the caller. Run under the
    # production preference (Stop), because this block runs under Continue and a throw there is not the same path.
    # THE PREFERENCE IS SET INSIDE A FUNCTION, never by an assignment in this block: grocery\test-native-stderr-eap.ps1
    # reads the preference lexically, and a Stop assigned here would make every later `2>$null` in the block a site.
    function Invoke-StUnderStop([scriptblock]$StBody) { $ErrorActionPreference = 'Stop'; & $StBody }
    $tw = & $newPusher 'tw'
    $throwGate = { param($d) throw 'fixture: the gate runner threw' }
    $ledTw = Join-Path $tmp 'ledtw'
    $twCaught = ''
    try { $null = Invoke-StUnderStop { Invoke-TcPushMain -Dir $tw -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $throwGate -RehearsalRunner $rhGreen -LedgerRoot $ledTw } }
    catch { $twCaught = [string]$_.Exception.Message }
    $twRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTw)
    $twRows = @($twRaw)
    $twRow = $(if ($twRows.Count) { $twRows[0] } else { $null })
    T ($kMF + '  a leg runner that throws in round 1 writes ONE row (outcome unknown, state not-taken, no phase, lock_takes 0), and the throw still reaches the caller') `
      ($twCaught -match 'the gate runner threw' -and $twRows.Count -eq 1 -and [string]$twRow.outcome -ceq 'unknown' -and [string]$twRow.state -ceq 'not-taken' -and $null -eq $twRow.phase -and [int]$twRow.lock_takes -eq 0 -and [int]$twRow.rounds -eq 1) `
      ("caught={0} rows={1} outcome={2} state={3} phase={4} takes={5} rounds={6}" -f $twCaught, $twRows.Count, $(if ($twRow) { $twRow.outcome }), $(if ($twRow) { $twRow.state }), $(if ($twRow) { $twRow.phase }), $(if ($twRow) { $twRow.lock_takes }), $(if ($twRow) { $twRow.rounds }))
    # CLEAN TWIN: a throw INSIDE the lock still writes exactly one row (the in-lock finally writes it, and the guard must
    # not write a second), and the lock is handed back.
    $ti = & $newPusher 'ti'
    $script:rhSeen.Clear(); $script:rhMoves = @('chain.ps1')
    $throwCheck = { param($d, $h, $r) throw 'fixture: the in-lock check threw' }
    $ledTi = Join-Path $tmp 'ledti'
    $tiCaught = ''
    try { $null = Invoke-StUnderStop { Invoke-TcPushMain -Dir $ti -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $throwCheck -LedgerRoot $ledTi } }
    catch { $tiCaught = [string]$_.Exception.Message }
    $tiRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTi)
    $tiRows = @($tiRaw)
    $tiRow = $(if ($tiRows.Count) { $tiRows[0] } else { $null })
    $tiFree = Enter-TcPushLock -Prefix $prefix -QueueRoot $qroot -WaitSec 5 -PollMs 50 -NoInherit
    T ($kCT + '  a throw inside the lock still writes exactly one row (outcome unknown, phase inlock), reaches the caller, and hands the lock back') `
      ($tiCaught -match 'the in-lock check threw' -and $tiRows.Count -eq 1 -and [string]$tiRow.outcome -ceq 'unknown' -and [string]$tiRow.phase -ceq 'inlock' -and $tiFree.Held) `
      ("caught={0} rows={1} outcome={2} phase={3} lockFree={4}" -f $tiCaught, $tiRows.Count, $(if ($tiRow) { $tiRow.outcome }), $(if ($tiRow) { $tiRow.phase }), $tiFree.Held)
    Exit-TcPushLock $tiFree
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

    # MUST FIRE: a rebase that fails with NOTHING UNMERGED is not a stop. Origin moves before the push starts and the
    # checkout holds an index.lock, so the pre-flight rebase cannot even begin: the row keeps conflict_files [] and says
    # conflict_scope none-unmerged, never first-stop.
    $il = & $newPusher 'il'
    & $moveOrigin 'notes.txt'
    $ilLock = Join-Path $il '.git\index.lock'
    [IO.File]::WriteAllText($ilLock, '')
    $ledIl = Join-Path $tmp 'ledil'
    try {
      $rIl = Invoke-TcPushMain -Dir $il -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhGreen -LedgerRoot $ledIl
    } finally { Remove-Item -LiteralPath $ilLock -Force -ErrorAction SilentlyContinue }
    $ilRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledIl)
    $ilRows = @($ilRaw)
    $ilRow = $(if ($ilRows.Count) { $ilRows[0] } else { $null })
    # Plain assignments, never $( ): a subexpression unrolls the empty list this case exists to see into $null.
    $ilFiles = 'no row'
    if ($ilRow) { $ilFiles = $ilRow.conflict_files }
    T ($kMF + '  a rebase that fails with nothing unmerged records conflict_files [] and conflict_scope none-unmerged, never a first-stop that did not happen') `
      ($rIl -eq 1 -and $ilRows.Count -eq 1 -and [string]$ilRow.outcome -ceq 'refused-rebase-conflict' -and $null -ne $ilFiles -and @($ilFiles).Count -eq 0 -and [string]$ilRow.conflict_scope -ceq 'none-unmerged') `
      ("rc={0} rows={1} outcome={2} files={3} scope={4}" -f $rIl, $ilRows.Count, $(if ($ilRow) { $ilRow.outcome }), (ConvertTo-Json -Compress -InputObject $ilFiles), $(if ($ilRow) { $ilRow.conflict_scope }))

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
      $rPb = Invoke-TcPushMain -Dir $pb -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhGreen -LedgerRoot $ledPb
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
    # check, and Invoke-TcRehearsalForPush runs the stub rehearsal, so every reading below travels the production road.
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
    $blobWant = ([string](@(& git -C (Split-Path -Parent $PSCommandPath) hash-object $PSCommandPath 2>$null))[0]).Trim()
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
  # A LITERAL-CASE SUITE KNOWS ITS OWN NUMBER, so a shortfall is a defect rather than a smaller tree: a case lost to a
  # throw, a comment or a glued line would otherwise leave the rest green (ops-and-gates.md). 93 = the 38 of the
  # fetch-and-rebase-first loop, W0.1's 32, W0.1R's 8 and the 15 its review added; read off this file, not added up.
  $expectedCases = 93
  if ($cases -ne $expectedCases) { Write-Output ("FAIL  the suite ran {0} case(s) where this file holds {1}, so a case was skipped or lost" -f $cases, $expectedCases); $f++ }
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
