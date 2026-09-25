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
              powershell -File ops\push-main.ps1 -Prepare       (start the commit-time chain rehearsal and return; W9.1,
                                                                 run by ops/hooks/post-commit, D19)
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

  THE PRE-FLIGHT (2026-09-23, W2.1R with W8.1 of design\PLAN-push-derived-conflicts-2026-09-23.md). EVERY ROUND STARTS BY
  REBASING OUTSIDE THE LOCK, and a later red LEAVES THE BRANCH REBASED: the session then fixes its change on current main,
  which is where it has to land anyway. Round 1's fetch and rebase are the pre-flight, and around them:
    - ONE PUSH-MAIN PER CHECKOUT. A per-checkout guard (a mutex named from SHA-256 of the lower-cased worktree path, taken
      with ZERO wait) refuses a second push-main in the same checkout at once, naming the holder's pid and start time,
      because every round rewrites HEAD outside the push lock and a retry started while the first run is gating would
      rebase under its legs. It never waits, so it forms no wait-for edge with any other lock. A guard that cannot be
      created is said and the push goes on, as the day before.
    - THE FETCH RETRIES ONCE on git's `cannot lock ref` (another fetch or push updating the shared remote-tracking ref).
      Outside the lock a fetch that still fails DEGRADES: the round goes on without a rebase, the row says
      degraded=fetch, and the fetch inside the lock decides, as the day before. Inside the lock it is blind-fetch-failed.
    - A CONFLICT IS NOT A COULD-NOT-REBASE. A failed rebase with unmerged files or a rebase directory left is a conflict:
      the files are read, the rebase is aborted, and the ABORT IS CHECKED (a failed abort is exit 3,
      blind=rebase-abort-failed, and says the branch may be mid-rebase). No unmerged file and no rebase directory (an
      index.lock stopped it from starting) is could-not-rebase: outside the lock it degrades (degraded=rebase), inside it
      is exit 3, blind-rebase-failed.
    - A BRANCH ALREADY ON MAIN IS REFUSED. A rebase that drops every commit as already applied leaves nothing to push, and
      `git push` then says "Everything up-to-date" and exits 0: that is refused-already-on-main, never a landing.
    - THE DIRT IS NAMED (W8.1): a dirty tree lists its paths (dirty_paths, at most 20) and when they appeared
      (dirty_since: start, or during-legs when the pre-flight was clean and something in this checkout wrote them while
      the legs ran).
    - THE SEED RUNS AFTER THE PRE-FLIGHT, and only when it passed, so a seconds-long refusal waits for no seed.
    - -DryRun NEVER REBASES: it says whether a rebase is needed and the approximate conflict list, and runs one round.
    - A REBASE THAT BRINGS IN A NEW COPY OF THIS SCRIPT RE-EXECUTES IT ONCE: the guard is released, the new copy runs as a
      child with the same arguments and TC_PUSH_MAIN_REEXEC=1, its exit code is this run's, and the child writes the one
      row. A run with TC_PUSH_MAIN_REEXEC set never re-executes; -NoReexec skips it on purpose.

  THE CATCH-UP (2026-09-23, W2.2R). After a round's legs pass, ONE unlocked fetch asks whether origin moved while they ran.
  Unmoved, the lock is taken. Moved, the branch is rebased HERE, outside the lock (a conflict refuses, phase catchup), and
  the next round's legs run, each reusing what its own keys allow; at most $script:PmMaxCatchUpRounds (3) such rounds, then
  the lock, where the in-lock sync and verdict check decide as the day before. A leg that could not evaluate, a fetch that
  failed and a rebase that could not start each go to the lock instead (degraded on the row). The rehearsal budget
  ($script:PmMaxRehearsalRounds, 3) counts only rounds whose rehearsal REHEARSED, so cheap catch-up rounds never spend it;
  at the budget a round that would rehearse again is refused-rehearsal-churn when the verdict check says the content is
  not covered (D11a). The in-lock verdict check is retried once when it cannot decide, and then no longer hands the lock
  back: the hook decides. What remains for the lock's hand-back is a move in the seconds between the catch-up fetch and
  the fetch inside the lock.

  LOCK ONLY THE SWAP (2026-09-23, W9.4). Inside the lock the fetch only ASKS whether origin moved since the last outside
  round. Unmoved, the push goes, and the hook replays the recorded run-gates verdict and test-auditors pass (about 25 s).
  Moved, the lock is HANDED BACK without a rebase under it: the next round rebases outside (a conflict refuses, phase
  catchup; rebase_phases says handback), re-runs the legs warm, and takes the lock again, at most $script:PmMaxHandBacks
  (3) times. At the cap the rebase runs inside the lock as 5841e96b1 did, with the verdict check as the backstop, so the
  rule degrades and never refuses. A hand-back never spends the rehearsal budget unless its rehearsal leg REHEARSED.

  THE LEGS RUN SIDE BY SIDE (2026-09-23, W9.3, which absorbs W2.3). Each round starts ops\rehearse-chain.ps1 -ForPush as a
  CHILD first, runs run-gates and then test-auditors in this process, and only then waits for the child (D1, decided on
  W9.3 step 0's measurement; $script:PmRehearsalBesideGate). A red leg writes the child's per-run stop file and waits for
  it to exit (it stops itself within its 5 s poll and is never killed), then refuses refused-gate-red. The wait is 3 for
  an empty exit code, a missing completion marker, or a marker whose code disagrees with the exit code. Every catch-up and
  hand-back round runs the same start, run, wait. Row fields rh_stopped and rh_secs_list (0 for a reused verdict).

  THE CHAIN QUEUE (2026-09-23, W9.2; lib\chain-queue.ps1, the queue lane's). A push that changes the daily chain (the
  seconds-long rehearse-chain -CheckPush read, before its rehearsal starts; a -NoRehearsal push counts) takes a TICKET.
  Until it is at the head its rehearsal judges HEAD STACKED on the tickets ahead (a stack file; only the rehearsal's own
  clone applies them, never this worktree). After its legs it waits for every ticket ahead to land, leave or die,
  holding nothing but the ticket; a ticket ahead that left, died or changed its key is a RESTACK, one more rehearsal. A
  stack conflict keeps its place. It records its rh_key, updates its range after every rebase, says swapping before the
  lock, and leaves landed (before the push lock goes) or left on every other exit. -ChainQueue off is the rollback. A
  queue that fails is queue=error, a head that never moves is queue=timeout, and both proceed unqueued. The drill that
  proves this path against this very file is ops\drill-chain-queue.ps1 -Drill -Runner ops\drill-push-main-runner.ps1.

  THE PRE-FLIGHT'S COUNTS (2026-09-23, W3.2 with W3.4a step 3), WARN ONLY: commits that edit
  design/BACKLOG-course-findings.md directly (neither deleting nor moving out an inbox file, which a merge does), inbox
  files the push adds that ops\merge-backlog-inbox.ps1 -ValidateFile says the merge would quarantine, and commits that
  MODIFY an existing updates/ file. Each warns and lands on the row (backlog_direct, inbox_invalid,
  inbox_updates_modified); none refuses, which is D3's to decide from a dated cutoff. W4.1 step 7 adds a fourth: commits
  that add a "Re-read at" line to a top-level design/*.md file, where a design/reread-ledger.tsv row written by
  ops\add-reread.ps1 is the road that union-merges and cannot conflict (reread_doc_lines).

  SCOPE OF A CLEAN REPORT: exit 0 means the remote accepted this push while this process held the lock. It says
  nothing about a pusher that does not take the lock - an older checkout, a plain `git push --no-verify`, or another
  machine - and nothing about whether main is healthy afterwards.
#>
# Declared inputs of its -SelfTest (2026-09-23, lib\gate-input-key.ps1): read off the self-test block, which works in a temp sandbox and reads nothing else of this repo. Verify with: powershell -File lib\gate-input-key.ps1 -VerifyDeclared <this file>
# gate-inputs: ops\push-main.ps1, lib\push-lock.ps1, lib\git-repo-env.ps1, lib\push-ledger.ps1, lib\seed-hint.ps1, ops\seed-worktree.ps1, ops\probe-push-convergence.ps1, lib\mutex-hold.ps1, ops\merge-backlog-inbox.ps1, lib\concurrency-probe.ps1, lib\chain-queue.ps1
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
  # SKIP THE RE-EXEC ON SELF-CHANGE (W2.1R step 8) for this one push: the copy already running is used even when the
  # pre-flight rebase brought in a new one. The rollback for a broken re-exec, never a habit.
  [switch]$NoReexec,
  # START THE COMMIT-TIME CHAIN REHEARSAL AND RETURN (W9.1, D19): fetch, start ops\rehearse-chain.ps1 -Early -Onto <origin
  # sha> detached, print what it decided. No HEAD moves, no leg runs, no lock is taken. ops/hooks/post-commit runs it.
  [switch]$Prepare,
  # THE CHAIN QUEUE (W9.2): live by default, from its first commit (D8's condition, carried to W9.2). off never opens
  # the queue and records queue=off: that is the ROLLBACK, a one-line default flip or -ChainQueue off on one push.
  [ValidateSet('live', 'off')][string]$ChainQueue = 'live',
  # THE MAIN CHECKOUT LANDS THROUGH A THROWAWAY WORKTREE (W8.2): automatic when this runs from the main checkout (its git
  # dir IS the common dir), or asked for with -ViaWorktree. -NoViaWorktree runs in place anyway: the rollback.
  [switch]$ViaWorktree,
  [switch]$NoViaWorktree,
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
. (Join-Path $repo 'lib\chain-queue.ps1')    # W9.2: the chain queue (also loads lib\gate-slots.ps1 and lib\atomic-write.ps1)

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

function Invoke-TcSeedBeforeGate {
  <# SEED BEFORE THE GATE, AS THE HOOK DOES (2026-09-18, backlog I237). ops\hooks\pre-push seeds a checkout with no
     built cards once, before its gate, because meal-prep\db\built is gitignored and a worktree has none until
     ops\seed-worktree.ps1 copies it. push-main's gate runs OUTSIDE the lock and BEFORE git push, so it ran unseeded:
     feed-covers-published reported BLIND, test-auditors' reading of that child printed FAIL, and the warm
     test-auditors leg refused most first pushes from a fresh worktree for a reason unrelated to the change. The same
     seeder and the same best effort as the hook: a seed that cannot run is SAID and never refuses, because seeding
     supplies inputs and decides nothing. WHAT "UNSEEDED" MEANS IS READ FROM THE SEEDER, never restated here: a directory
     its $SEED_DIRS names (lib\seed-hint.ps1 Get-TcSeedDirs) that is absent or holds no file. That keeps this file from
     spelling another module's internals path, which ops\audit-cross-module-reach.ps1 ratchets, and a directory that
     joins or leaves that list moves this check the same day. Returns Ran / Code / Why. -Seeder is the self-test's seam.
     A SEEDED CHECKOUT IS RE-SEEDED TOO (2026-09-23). This used to return 'already seeded' once a seed directory held a
     file, so a REUSED worktree kept whatever it was first given: recursing-edison-169e3b's push was refused by
     stamp-live-price-fallback, 2 of 11, over a built card copied on 2026-09-03 while the main checkout's was rebuilt on
     2026-09-21 after the live-price template changed. The seeder now refreshes a file inside a directory seed whose
     source is newer, as it already did for file seeds, and a re-seed of a current checkout copies nothing and took 5.7 s
     on 2026-09-23 against a gate measured in minutes. The hook still seeds only an unseeded checkout, because its seed
     runs inside the push lock when push-main holds it, and this one runs before the lock is taken. #>
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
  if ($empty.Count -eq 0) {
    Say 'push-main: re-seeding before the gate, so a seeded file the main checkout has rewritten since it was copied is refreshed.'
  } else {
    Say ("push-main: this checkout has nothing in {0}, so gates that read it would be BLIND - seeding before the gate, as the hook does." -f ($empty -join ', '))
  }
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

# ======================================================================================================================
# THE REHEARSAL LEG RUNS BESIDE THE OTHER TWO (2026-09-23, W9.3, which absorbs W2.3). ops\rehearse-chain.ps1 -ForPush is
# started as a CHILD PROCESS before run-gates, run-gates and test-auditors run in this process, and only then is the
# child waited for. A red leg writes the child's per-run stop file at once; the child (never killed by anyone, memory
# powershell-exiting-event-does-not-fire) sees it within its 5 s poll, ends blind=stopped and records nothing, and this
# process waits for it to exit before refusing refused-gate-red, so a red push no longer waits out a whole rehearsal.
# SLOTS: the child takes a rehearsal slot in its own process, run-gates takes gate slots in its own pool, test-auditors
# takes none, and this process holds none of them while it waits, so no process here holds one pool while waiting on the
# other: no nested acquisition.
# THE WAIT DECIDES AS W2.3 STEP 3 SAYS. Start-Process with .Handle touched at once, so the PS 5.1 empty-ExitCode trap
# (memory ps-start-process-exitcode-needs-handle) cannot read a red as 0; and still, an empty or unreadable ExitCode is 3,
# and the last line must be `CHAIN-REHEARSAL-CHECK-COMPLETE code=<n> ...` with <n> equal to the exit code, or it is 3.
# ======================================================================================================================
# D1, DECIDED ON W9.3 STEP 0'S MEASUREMENT: $true starts the rehearsal beside run-gates (W9.3); $false is W2.3's shape,
# run-gates first, then test-auditors beside the rehearsal, which is what stands if the bar failed and Brad has not ruled.
# THE BAR MET, measured 2026-09-24 (harness blob 8ce8478c, a scratch harness; bar written before the run): 6 runs in one
# worktree, alone and overlapped alternating, one row per leg per run. Bar: 0 test-auditors timeouts over the 3
# overlapped runs, and each overlapped leg's wall at most 1.25x the median of the same leg alone. run-gates alone 323,
# 320, 328 s (median 323), overlapped 336, 334, 342 (worst 1.06x); test-auditors alone 626, 609, 616 s (median 616),
# overlapped 639, 665, 652 (worst 1.08x); every leg exit 0, test-auditors failed=0 in all 6; the rehearsal beside them
# 975, 1000, 994 s, peak working set 2.7 GB. One variant tried (this one). My own other load fell mostly on the
# overlapped arm, which can only have widened the gap it did not show. At every sample no other run-gates, rehearsal or
# test-auditors process was running (box cpu 4 to 28%).
$script:PmRehearsalBesideGate = $true

function Resolve-TcRehearsalExit {
  <# The rehearsal leg's decision from its exit code and its lines (pure): Code, Why. An empty exit code, a missing
     completion marker, or a marker whose code disagrees with the exit code decided nothing, and each is 3. #>
  param($ExitCode, $Lines)
  $all = @(@($Lines) | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
  $last = $(if ($all.Count) { $all[$all.Count - 1] } else { '' })
  if ($null -eq $ExitCode -or [string]$ExitCode -notmatch '^-?\d+$') { return [pscustomobject]@{ Code = 3; Why = 'the rehearsal child''s exit code could not be read, so it decided nothing' } }
  $m = [regex]::Match($last, '^CHAIN-REHEARSAL-CHECK-COMPLETE code=(\d+)\b')
  if (-not $m.Success) { return [pscustomobject]@{ Code = 3; Why = 'the rehearsal child printed no completion marker as its last line, so it decided nothing' } }
  if ([int]$m.Groups[1].Value -ne [int]$ExitCode) { return [pscustomobject]@{ Code = 3; Why = ('the rehearsal child exited {0} but its marker says code={1}; that disagreement decided nothing' -f $ExitCode, $m.Groups[1].Value) } }
  return [pscustomobject]@{ Code = [int]$ExitCode; Why = $last }
}

function New-TcRehearsalJob {
  <# A started (or already finished) rehearsal leg: Wait() returns Code, Why, Ran, Lines, Sec and Stopped, once, and the
     same object on every later call. A job with -Done is finished before it starts (nothing to ask, or a runner seam). #>
  param($Proc = $null, [string]$Out = '', [string]$Err = '', $Done = $null, [scriptblock]$Deferred = $null, $DeferredArg = $null)
  $job = [pscustomobject]@{ Proc = $Proc; Out = $Out; Err = $Err; Result = $Done; Deferred = $Deferred; DeferredArg = $DeferredArg; Sw = [Diagnostics.Stopwatch]::StartNew() }
  $job | Add-Member -MemberType ScriptMethod -Name Wait -Value {
    if ($null -ne $this.Result) { return $this.Result }
    if ($this.Deferred) {
      # A RUNNER SEAM (the fixtures' synchronous models): it runs at the wait, in this process.
      $r = & $this.Deferred $this.DeferredArg
      $this.Sw.Stop()
      if ($null -eq $r.PSObject.Properties['Sec']) { $r | Add-Member -NotePropertyName Sec -NotePropertyValue ([int][math]::Round($this.Sw.Elapsed.TotalSeconds)) -Force }
      if ($null -eq $r.PSObject.Properties['Stopped']) { $r | Add-Member -NotePropertyName Stopped -NotePropertyValue $false -Force }
      $this.Result = $r
      return $r
    }
    $this.Proc.WaitForExit()
    $this.Sw.Stop()
    $code = $null
    try { $code = $this.Proc.ExitCode } catch { $code = $null }
    $lines = @()
    if ($this.Out -and (Test-Path -LiteralPath $this.Out)) { $lines = @([IO.File]::ReadAllLines($this.Out) | Where-Object { $_.Trim() }) }
    foreach ($l in $lines) { Say ([string]$l) }
    $dec = Resolve-TcRehearsalExit -ExitCode $code -Lines $lines
    $stopped = [bool](@($lines | Where-Object { [string]$_ -match '^CHAIN-REHEARSAL-CHECK-COMPLETE .*\bblind=stopped\b' }).Count)
    foreach ($x in @($this.Out, $this.Err)) { if ($x -and (Test-Path -LiteralPath $x)) { Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue } }
    # THE CHILD'S OWN RUN TIME (M1 of design\PLAN-faster-pushes-no-accuracy-loss-2026-09-25.md): exit minus start, never
    # this stopwatch, which runs until push-main COLLECTS the child and so charged a "not needed" answer with the whole
    # gate leg (266 s median over 2026-09-22..25). The stopwatch is the fallback when the process times cannot be read.
    $sec = [int][math]::Round($this.Sw.Elapsed.TotalSeconds)
    try { $own = ($this.Proc.ExitTime - $this.Proc.StartTime).TotalSeconds; if ($own -ge 0) { $sec = [int][math]::Round($own) } } catch { }
    $this.Result = [pscustomobject]@{ Code = $dec.Code; Why = $dec.Why; Ran = $true; Lines = [string[]]$lines; Sec = $sec; Stopped = $stopped }
    return $this.Result
  }
  return $job
}

function Start-TcRehearsalChild {
  <# THE DEFAULT STARTER: ops\rehearse-chain.ps1 -ForPush as a child process, with -StackFile (W9.2) and a per-run
     -StopFile when the checkout's rehearse-chain declares them (an older one is asked without them). A checkout with no
     rehearse-chain is not asked, as before (Ran $false). -Script and -ExtraArgs are the self-test's seams. #>
  param([string]$Dir, [string]$Remote, [string]$Branch, [string]$StackFile = '', [string]$StopFile = '', [string]$Script = '', [string[]]$ExtraArgs = @())
  $rh = $(if ($Script) { $Script } else { Join-Path $Dir 'ops\rehearse-chain.ps1' })
  if (-not (Test-Path -LiteralPath $rh)) { return (New-TcRehearsalJob -Done ([pscustomobject]@{ Code = 0; Why = 'this checkout has no ops\rehearse-chain.ps1, so no rehearsal is asked'; Ran = $false; Lines = [string[]]@(); Sec = 0; Stopped = $false })) }
  $src = ''
  try { $src = [IO.File]::ReadAllText($rh) } catch { }
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $rh + '"'), '-ForPush', '-Remote', $Remote, '-Branch', $Branch)
  if ($StackFile -and $src -match '\$StackFile\b') { $argv += @('-StackFile', ('"' + $StackFile + '"')) }
  if ($StopFile -and $src -match '\$StopFile\b') { $argv += @('-StopFile', ('"' + $StopFile + '"')) }
  $argv += @($ExtraArgs)
  $stem = Join-Path $env:TEMP ('tc-pm-rh-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  try {
    $p = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Dir -NoNewWindow -PassThru -ErrorAction Stop `
      -RedirectStandardOutput ($stem + '.out') -RedirectStandardError ($stem + '.err') -ArgumentList $argv
    $null = $p.Handle   # touched at once: PS 5.1 hands back an empty ExitCode otherwise
    return (New-TcRehearsalJob -Proc $p -Out ($stem + '.out') -Err ($stem + '.err'))
  } catch {
    return (New-TcRehearsalJob -Done ([pscustomobject]@{ Code = 3; Why = ('the rehearsal child could not be started: ' + $_.Exception.Message); Ran = $false; Lines = [string[]]@(); Sec = 0; Stopped = $false }))
  }
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
# SINCE W2.2R (2026-09-23) THAT CAP COUNTS ONLY ROUNDS WHOSE REHEARSAL LEG REHEARSED (made a new verdict), never a round
# whose rehearsal read a recorded verdict or needed none, so cheap catch-up rounds cannot spend it.

# HOW MANY CATCH-UP ROUNDS (W2.2R step 1): after a round's legs pass, one unlocked fetch; if origin moved, rebase outside
# the lock and run the legs again, at most this many times. 3 is the first plausible value, not swept: each round is warm
# (every leg reuses what its keys allow), and a main that moves after three leg sets in a row is moving faster than any
# number would catch. Past it the push goes to the lock, where the in-lock sync and the verdict check decide as the day
# before (D11): degrade, never refuse. What it does when the producer stops: when main stops moving, no catch-up round runs.
$script:PmMaxCatchUpRounds = 3

# LOCK ONLY THE SWAP (2026-09-23, W9.4): how many times the lock is HANDED BACK when origin moved between the last outside
# round and the fetch inside the lock. Each hand-back releases the lock, rebases outside it, re-runs the legs warm on their
# own keys, and takes the lock again, so no rebase and no verdict check runs while the lock is held and the hook replays
# its recorded verdicts in about 25 s. 3 is the first plausible value, not swept; at 18 landings an hour and a 30 s window
# about 14% of pushes are handed back once, and 3 in a row is about 0.3% (0.14 cubed, the review's model). AT THE CAP the
# push rebases INSIDE the lock as 5841e96b1 did, and the in-lock verdict check is the backstop: never a refusal, so the rule
# cannot livelock. When main stops moving, no hand-back runs.
$script:PmMaxHandBacks = 3
# A HARD BOUND ON LEG SETS, so no combination of catch-ups and hand-backs can loop: round 1, every catch-up round, every
# lock hand-back, and every rehearsal round. Reached only when the verdict check and the rehearsal disagree, and then refused.
$script:PmMaxLegSets =1 + $script:PmMaxCatchUpRounds + $script:PmMaxRehearsalRounds + $script:PmMaxHandBacks

function Invoke-TcCheckWithRetry {
  <# The verdict check (the -RehearsalCheck seam, Invoke-TcRehearsalCheck by default), RETRIED ONCE when it cannot decide
     (Code 3, or no Code at all). Returns Check (the last answer), Word (covered, not-covered or could-not-decide, as
     Get-TcInlockCheckWord reads it) and Tries. #>
  param([scriptblock]$Checker, [string]$Dir, [string]$Head, [string]$Rem)
  $c = & $Checker $Dir $Head $Rem
  $w = Get-TcInlockCheckWord -Check $c
  $tries = 1
  if ($w -ceq 'could-not-decide') {
    Say 'push-main: the verdict check could not decide; asking it once more.'
    $c = & $Checker $Dir $Head $Rem
    $w = Get-TcInlockCheckWord -Check $c
    $tries = 2
  }
  return [pscustomobject]@{ Check = $c; Word = $w; Tries = $tries }
}

function Get-TcChurnCause {
  <# Which cause a churn refusal saw (W2.2R step 4): a crashed check (it decided nothing), a stale verdict (its words say
     stale), or a manifest move (the rebase moved the verdict key, the usual case). Pure over the check's answer. #>
  param($Check)
  if ((Get-TcInlockCheckWord -Check $Check) -ceq 'could-not-decide') { return 'a crashed check' }
  if ([string](Get-TcOptionalProp $Check 'Why') -match 'stale') { return 'a stale verdict' }
  return 'a manifest move'
}

# ======================================================================================================================
# THE PER-CHECKOUT GUARD (2026-09-23, W2.1R step 1). Every round now rebases HEAD OUTSIDE the push lock, so two push-main
# runs in one checkout (a retry an agent started because its first run passed a 9.5-minute deadline, say) would rewrite
# HEAD under each other's legs, and gate-verdict could record a pass for content no run wholly judged. The guard is a
# mutex named from SHA-256 of the lower-cased worktree path, built the way lib\ledger-lock.ps1 names a ledger, taken with
# ZERO wait: a second run is refused at once and never waits, so the guard forms no wait-for edge with any other lock (it
# sits at 0a in the declared lock order, outside the push lock). An abandoned mutex (a killed holder) reads free. A guard
# that cannot be created is SAID and the push goes on exactly as the day before, because a guard must never be the reason
# a push cannot land. Who holds it is in a small info file beside it, since a mutex cannot say; the refusal prints that
# file's pid and start time, or says it could not read one.
# The prefix and the info root are script variables so the self-test can point every case at a private name: no case
# opens the production guard (plan section 5).
# ======================================================================================================================
$script:TcPmGuardPrefix = 'Global\tc-push-main-checkout-'
$script:TcPmGuardInfoRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ThriftyCrew\push-main-guard'

function Get-TcCheckoutGuardKey {
  <# The guard's key for a checkout: the first 12 bytes of SHA-256 over the lower-cased full path of its worktree top
     (`git rev-parse --show-toplevel`, or $Dir itself when git cannot say), as lower-case hex. #>
  param([string]$Dir)
  $top = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', '--show-toplevel'))
  if (-not $top) { $top = $Dir }
  $full = [IO.Path]::GetFullPath(($top -replace '/', '\')).TrimEnd([char[]]@('\', '/')).ToLowerInvariant()
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full)) } finally { $sha.Dispose() }
  return (-join @($bytes[0..11] | ForEach-Object { $_.ToString('x2') }))
}

function Enter-TcCheckoutGuard {
  <# Takes the per-checkout guard with ZERO wait. Held (this run owns it), Refused (another live run owns it: Holder says
     who, from the info file), or neither (the mutex could not be created: Reason says why, and the push goes on). #>
  param([string]$Dir)
  $key = ''
  try { $key = Get-TcCheckoutGuardKey -Dir $Dir } catch { return [pscustomobject]@{ Held = $false; Refused = $false; Mutex = $null; Name = ''; Info = ''; Holder = ''; Reason = ('the guard key could not be formed: ' + $_.Exception.Message) } }
  $name = $script:TcPmGuardPrefix + $key
  $info = Join-Path $script:TcPmGuardInfoRoot ($key + '.json')
  $m = $null
  try { $m = New-Object System.Threading.Mutex($false, $name) }
  catch { return [pscustomobject]@{ Held = $false; Refused = $false; Mutex = $null; Name = $name; Info = $info; Holder = ''; Reason = ('the guard mutex could not be created: ' + $_.Exception.Message) } }
  $got = $false
  try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }   # a killed holder's guard reads free
  if (-not $got) {
    $holder = 'a holder whose pid this run could not read'
    try {
      if (Test-Path -LiteralPath $info) {
        $o = [IO.File]::ReadAllText($info) | ConvertFrom-Json
        $holder = ('pid {0}, started {1}' -f $o.pid, $o.start_utc)
      }
    } catch { }
    $m.Dispose()
    return [pscustomobject]@{ Held = $false; Refused = $true; Mutex = $null; Name = $name; Info = $info; Holder = $holder; Reason = '' }
  }
  try {
    if (-not (Test-Path -LiteralPath $script:TcPmGuardInfoRoot)) { $null = New-Item -ItemType Directory -Force -ErrorAction Stop $script:TcPmGuardInfoRoot }
    $body = ('{{"pid":{0},"start_utc":"{1}","checkout":{2}}}' -f $PID, [DateTime]::UtcNow.ToString('o'), (ConvertTo-Json -Compress -InputObject ([string]$Dir)))
    [IO.File]::WriteAllText($info, $body, (New-Object Text.UTF8Encoding($false)))
  } catch { Say ('push-main: the guard is held, but who holds it could not be written (' + $_.Exception.Message + '); a second run here will be refused without a pid.') }
  return [pscustomobject]@{ Held = $true; Refused = $false; Mutex = $m; Name = $name; Info = $info; Holder = ''; Reason = '' }
}

function Exit-TcCheckoutGuard {
  <# Releases a guard Enter-TcCheckoutGuard granted, removing its info file first when the file still names this pid. #>
  param($Guard)
  if ($null -eq $Guard -or -not $Guard.Held -or $null -eq $Guard.Mutex) { return }
  try {
    if ($Guard.Info -and (Test-Path -LiteralPath $Guard.Info)) {
      $o = $null
      try { $o = [IO.File]::ReadAllText($Guard.Info) | ConvertFrom-Json } catch { }
      if ($null -ne $o -and [int]$o.pid -eq $PID) { Remove-Item -LiteralPath $Guard.Info -Force -ErrorAction SilentlyContinue }
    }
  } catch { }
  try { $Guard.Mutex.ReleaseMutex() } catch { }
  try { $Guard.Mutex.Dispose() } catch { }
  $Guard.Held = $false
}

# ======================================================================================================================
# THE SYNC'S SEAMS AND CONSTANTS (W2.1R steps 2 to 4).
# ======================================================================================================================
# ONE RETRY on `cannot lock ref`, after this pause. The race it answers is another fetch or push updating the shared
# refs/remotes/<remote>/<branch> at the same moment (one seen in production: a fetch 1 s after a landing read "is at
# 38357202c but expected 4fa9f1a7b"). 1 s is the first plausible value, not swept: a ref update takes milliseconds.
$script:TcPmFetchRetryPauseMs = 1000
# SELF-TEST SEAMS, $null in production: run between the failed fetch and its retry, and in place of `git rebase --abort`.
$script:TcPmBeforeFetchRetry = $null
$script:TcPmRebaseAbort = { param($d) Invoke-TcGit -Dir $d -Arguments @('rebase', '--abort') }
# AT MOST THIS MANY DIRTY PATHS ON A ROW (W8.1): the first plausible number, enough to name a board sweep without
# carrying the whole tree into the ledger.
$script:TcPmDirtyCap = 20

function Invoke-TcFetchWithRetry {
  <# `git fetch --quiet <remote> <branch>`, retried ONCE on git's own words for a ref another process is updating at this
     moment, "cannot lock ref" (W2.1R step 2). The Invoke-TcGit result of the last try. #>
  param([string]$Dir, [string]$Remote, [string]$Branch)
  $fetchArgs = @('fetch', '--quiet', $Remote, $Branch)
  $f = Invoke-TcGit -Dir $Dir -Arguments $fetchArgs
  if ($f.Code -ne 0 -and $f.Text -match 'cannot lock ref') {
    Say ("push-main: `git fetch` could not lock the remote-tracking ref (another fetch or push was updating it); retrying once.")
    if ($script:TcPmBeforeFetchRetry) { & $script:TcPmBeforeFetchRetry $Dir }
    Start-Sleep -Milliseconds $script:TcPmFetchRetryPauseMs
    $f = Invoke-TcGit -Dir $Dir -Arguments $fetchArgs
  }
  return $f
}

function Test-TcRebaseInProgress {
  <# Whether git left a rebase directory (rebase-merge or rebase-apply) under this checkout's own git dir. #>
  param([string]$Dir)
  $gd = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', '--absolute-git-dir'))
  if (-not $gd) { return $false }
  return ((Test-Path -LiteralPath (Join-Path $gd 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gd 'rebase-apply')))
}

function Test-TcMainCheckout {
  <# True when $Dir is the repository's MAIN checkout (its git dir IS the common dir), where W8.2's route applies. #>
  param([string]$Dir)
  $gd = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', '--absolute-git-dir'))
  $cd = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', '--path-format=absolute', '--git-common-dir'))
  if (-not $gd -or -not $cd) { return $false }
  return [string]::Equals(([IO.Path]::GetFullPath(($gd -replace '/', '\')).TrimEnd('\')), ([IO.Path]::GetFullPath(($cd -replace '/', '\')).TrimEnd('\')), [StringComparison]::OrdinalIgnoreCase)
}

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
     same way. Which phase a call belongs to is the caller's to say.

     THE PHASE DECIDES WHAT A FAILURE MEANS (2026-09-23, W2.1R). -Phase is preflight or catchup (OUTSIDE the lock) or
     inlock. Outside the lock a fetch that fails after its one retry, and a rebase that could not start, DEGRADE: Code 0,
     Degraded 'fetch' or 'rebase', no rebase, and the fetch inside the lock decides, as the day before. Inside the lock
     each is Code 3. A conflict refuses in every phase; an abort that fails is Code 3 in every phase. -NoRebase (a dry
     run) never rebases: it says whether one is needed and the approximate conflict list. A rebase that leaves nothing to
     push is refused-already-on-main. A dirty tree hands back its paths (DirtyPaths, sorted Ordinal, at most
     $script:TcPmDirtyCap), and its message says whether the dirt was there at the start or appeared while the legs ran,
     and names the main-checkout route when this is the main checkout. #>
  param([string]$Dir, [string]$Remote, [string]$Branch, [string]$Phase = 'inlock', [bool]$NoRebase = $false, [bool]$ProbeOnly = $false)
  $outside = -not [string]::Equals($Phase, 'inlock', [StringComparison]::Ordinal)
  $f = Invoke-TcFetchWithRetry -Dir $Dir -Remote $Remote -Branch $Branch
  $degraded = ''
  $head = ([string](Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'HEAD')).Out[0]).Trim()
  if ($f.Code -ne 0) {
    if (-not $outside) {
      return (New-TcSyncResult -Code 3 -Outcome 'blind-fetch-failed' -Message ("push-main: COULD NOT EVALUATE - `git fetch {0} {1}` exited {2}, so what this push would land on is unknown. That is not a pass.`n{3}" -f $Remote, $Branch, $f.Code, $f.Text))
    }
    # OUTSIDE THE LOCK A FAILED FETCH DEGRADES (EVERY LOCK PATH DEGRADES TO THE DAY BEFORE): the last-fetched ref stands in
    # for the remote, so a dirty tree and an empty push are still refused in seconds, and no rebase runs on a base nobody
    # has just read. The fetch inside the lock decides, as it always did.
    Say ("push-main: `git fetch {0} {1}` failed outside the lock (exit {2}), so this round goes on WITHOUT a rebase; the fetch inside the lock decides, as before.`n{3}" -f $Remote, $Branch, $f.Code, $f.Text)
    $degraded = 'fetch'
    $NoRebase = $true
    $rem = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', ('refs/remotes/' + $Remote + '/' + $Branch)))
  } else {
    $rem = ([string](Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'FETCH_HEAD')).Out[0]).Trim()
  }
  $mbR = Invoke-TcGit -Dir $Dir -Arguments @('merge-base', 'HEAD', $rem)
  $mb = $(if ($mbR.Code -eq 0 -and $mbR.Out.Count) { ([string]$mbR.Out[0]).Trim() } else { '' })
  $cntR = Invoke-TcGit -Dir $Dir -Arguments @('rev-list', '--count', ($rem + '..HEAD'))
  $ahead = $(if ($cntR.Code -eq 0 -and $cntR.Out.Count) { [int]([string]$cntR.Out[0]).Trim() } else { 0 })
  # --no-optional-locks IS A GLOBAL OPTION and must come BEFORE the subcommand, so taking a status never takes the
  # index lock a session's own commit needs. After `status` git rejects it as unknown - which this file did until
  # the streams were separated, when the rejection stopped counting as a changed path and a dirty checkout was
  # pushed. Two bugs that had been cancelling each other out.
  $st = Invoke-TcGit -Dir $Dir -Arguments @('--no-optional-locks', 'status', '--porcelain')
  $dirtyLines = [string[]]@(@($st.Out) | Where-Object { ([string]$_).Trim() } | ForEach-Object { ([string]$_).TrimEnd() })
  $dirty = [bool]$dirtyLines.Count
  $plan = Get-TcPushPlan -Head $head -RemoteSha $rem -MergeBase $mb -Ahead $ahead -Dirty $dirty
  if (-not $plan.Ready) {
    $dirtyPaths = $null
    $msg = ("push-main: REFUSED - {0}" -f $plan.Reason)
    if ($dirty) {
      # THE DIRT IS NAMED (W8.1): which paths, and whether they were there at the start or appeared while the legs ran.
      [Array]::Sort($dirtyLines, [StringComparer]::Ordinal)
      $dirtyPaths = [string[]]@($dirtyLines | Select-Object -First $script:TcPmDirtyCap)
      $more = $(if ($dirtyLines.Count -gt $script:TcPmDirtyCap) { "`n  ... and {0} more" -f ($dirtyLines.Count - $script:TcPmDirtyCap) } else { '' })
      $listed = (@($dirtyPaths | ForEach-Object { '  ' + $_ }) -join "`n") + $more
      if ($Phase -ceq 'preflight') {
        $msg = ("push-main: REFUSED - the working tree has uncommitted changes, before anything ran:`n{0}`nCommit them or set them aside: rebasing over them restores content but not the index, which is how this estate has left a path unmerged before." -f $listed)
      } else {
        $msg = ("push-main: REFUSED - the working tree was clean at the pre-flight, and while the legs ran something in THIS checkout wrote:`n{0}`nA leg, a board step or a reconciler run here writes into the checkout being landed; run it in a scratch clone instead, then run this again." -f $listed)
      }
      if (Test-TcMainCheckout -Dir $Dir) {
        $msg += "`nThis is the MAIN checkout, which other sessions and the bots keep dirty: ops\push-main.ps1 run here lands through a throwaway worktree by itself (-ViaWorktree, the default from the main checkout), so this refusal means it was run with -NoViaWorktree or inside that worktree."
      }
    }
    return (New-TcSyncResult -Code 1 -Outcome 'refused-not-ready' -Head $head -Rem $rem -Ahead $ahead -Message $msg -DirtyPaths $dirtyPaths -Degraded $degraded)
  }
  Say ("push-main: {0} commit(s) to land on {1}/{2}; {3}." -f $ahead, $Remote, $Branch, $plan.Reason)
  $siblings = $null
  if ($plan.NeedsRebase -and $ProbeOnly) {
    # THE HAND-BACK PROBE (W9.4): inside the lock, only WHETHER origin moved is asked; the rebase happens outside, after
    # the lock is handed back. Nothing is printed or merged here, because this runs while the lock is held.
    return (New-TcSyncResult -Code 0 -Head $head -Rem $rem -Ahead $ahead -Degraded $degraded -RebaseNeeded $true)
  }
  if ($plan.NeedsRebase -and $NoRebase) {
    # A DRY RUN (or a round whose fetch failed) NEVER REBASES (W2.1R step 7): it says what a rebase would meet, from one
    # squashed merge-tree, which is approximate by construction and labelled so.
    $approx = Get-TcMergeTreeConflicts -Dir $Dir -Head 'HEAD' -Target $rem
    $cl = $(if ($null -eq $approx) { 'could not be computed' } elseif ($approx.Count) { 'would conflict on ' + ($approx -join ', ') } else { 'would not conflict' })
    Say ("push-main: a rebase onto {0} is needed and was NOT run (approximate, from one squashed merge-tree: it {1})." -f $rem.Substring(0, [Math]::Min(9, $rem.Length)), $cl)
    return (New-TcSyncResult -Code 0 -Head $head -Rem $rem -Ahead $ahead -Degraded $degraded -RebaseNeeded $true)
  }
  if ($plan.NeedsRebase) {
    # WHAT THE REBASE BRINGS IN, read before it moves HEAD: any main commit whose subject is one of this branch's.
    $siblings = Get-TcSameSubjectSiblings -Dir $Dir -MergeBase $mb -Target $rem
    $origHead = $head
    $rb = Invoke-TcGit -Dir $Dir -Arguments @('rebase', $rem)
    if ($rb.Code -ne 0) {
      # RECORD THE CASE AT THE MOMENT IT FAILS (measurement.md): the unmerged paths exist only until the abort below
      # clears them, so they are read first. The squashed whole-range list is read after, from the restored HEAD.
      $unmerged = Get-TcUnmergedFiles -Dir $Dir
      $nothingUnmerged = ($null -eq $unmerged) -or ($unmerged.Length -eq 0)
      if ($nothingUnmerged -and -not (Test-TcRebaseInProgress -Dir $Dir)) {
        # COULD-NOT-REBASE, NOT A CONFLICT (W2.1R step 3): nothing unmerged and no rebase directory, so the rebase never
        # started (an index.lock another process holds, say) and nothing moved. Outside the lock that degrades; inside it
        # is could-not-evaluate. Never a refusal of the change, which conflicted with nothing.
        if ($outside) {
          Say ("push-main: the rebase onto {0} could not START (nothing unmerged, no rebase directory: {1}). Nothing was changed; this round goes on and the rebase inside the lock decides, as before." -f $rem.Substring(0, 9), (($rb.Text -split "`n") | Select-Object -First 1))
          return (New-TcSyncResult -Code 0 -Head $head -Rem $rem -Ahead $ahead -RebaseTried $true -Siblings $siblings -Degraded $(if ($degraded) { $degraded + ',rebase' } else { 'rebase' }))
        }
        return (New-TcSyncResult -Code 3 -Outcome 'blind-rebase-failed' -Head $head -Rem $rem -Ahead $ahead -RebaseTried $true -Siblings $siblings `
          -Message ("push-main: COULD NOT EVALUATE - blind=rebase-could-not-start: the rebase onto {0}/{1} inside the lock could not start (nothing unmerged, no rebase directory), so nothing was pushed. That is not a pass.`n{2}" -f $Remote, $Branch, $rb.Text))
      }
      # THE ABORT IS CHECKED (W2.1R step 4). A half-finished rebase is the worst thing this could hand back, because the
      # next session to push inherits it, so an abort that exits non-zero or leaves a rebase directory is exit 3 and says
      # the branch MAY be mid-rebase - never that it is where it was.
      $ab = & $script:TcPmRebaseAbort $Dir
      $still = Test-TcRebaseInProgress -Dir $Dir
      $scope = $(if ($null -eq $unmerged) { '' } elseif ($unmerged.Length) { 'first-stop' } else { 'none-unmerged' })
      if ($ab.Code -ne 0 -or $still) {
        return (New-TcSyncResult -Code 3 -Outcome 'blind-rebase-abort-failed' -Head $head -Rem $rem -Ahead $ahead -RebaseTried $true -Siblings $siblings `
          -ConflictFiles $unmerged -ConflictScope $scope `
          -Message ("push-main: COULD NOT EVALUATE - blind=rebase-abort-failed: the rebase onto {0}/{1} conflicted and `git rebase --abort` exited {2}{3}. This branch MAY BE MID-REBASE: run `git status` here before anything else, and `git rebase --abort` by hand if it says a rebase is in progress. Nothing was pushed.`n{4}" -f $Remote, $Branch, $ab.Code, $(if ($still) { ' and left a rebase directory' } else { '' }), $rb.Text))
      }
      $whole = Get-TcMergeTreeConflicts -Dir $Dir -Head 'HEAD' -Target $rem
      $filesSaid = $(if ($null -ne $unmerged -and $unmerged.Length) { "`n  conflicted: " + ($unmerged -join ', ') } else { '' })
      $sibSaid = $(if ($null -ne $siblings -and @($siblings).Count) { "`n  main already holds a commit with this branch's subject: " + (@($siblings) -join ', ') + ' - another session may have landed this change' } else { '' })
      return (New-TcSyncResult -Code 1 -Outcome 'refused-rebase-conflict' -Head $head -Rem $rem -Ahead $ahead -RebaseTried $true -Siblings $siblings `
        -ConflictFiles $unmerged -ConflictScope $scope -ConflictFilesAll $whole -ConflictAllBasis 'merge-tree-approximate' `
        -Message ("push-main: REFUSED - the rebase onto {0}/{1} conflicts, so it was aborted and this branch is exactly where it was. Resolve it and run this again.{2}{3}`n{4}" -f $Remote, $Branch, $filesSaid, $sibSaid, $rb.Text))
    }
    $head = ([string](Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'HEAD')).Out[0]).Trim()
    # ALREADY ON MAIN (W2.1R step 5): a rebase that skipped every commit as already applied exits 0 and leaves nothing to
    # push, and `git push` would then say "Everything up-to-date" and exit 0, which the day before recorded as a landing.
    $leftR = Invoke-TcGit -Dir $Dir -Arguments @('rev-list', '--count', ($rem + '..HEAD'))
    if ($leftR.Code -eq 0 -and $leftR.Out.Count -and [int]([string]$leftR.Out[0]).Trim() -eq 0) {
      $dropped = Invoke-TcGit -Dir $Dir -Arguments @('log', '--format=%h %s', ($mb + '..' + $origHead))
      $dl = (@($dropped.Out) | ForEach-Object { '  ' + $_ }) -join "`n"
      $sibSaid = $(if ($null -ne $siblings -and @($siblings).Count) { (@($siblings) -join ', ') } else { 'none found by subject' })
      return (New-TcSyncResult -Code 1 -Outcome 'refused-already-on-main' -Head $head -Rem $rem -Ahead 0 -RebaseTried $true -Siblings $siblings `
        -Message ("push-main: REFUSED - every commit of this branch is already on {0}/{1} as an identical patch, so the rebase dropped them all and there is nothing to push. Nothing was run and nothing landed. The dropped commits (the branch was at {2}):`n{3}`nThe main commits carrying their subjects: {4}" -f $Remote, $Branch, $origHead.Substring(0, 9), $dl, $sibSaid))
    }
    Say ("push-main: rebased onto {0}; HEAD is now {1}." -f $rem.Substring(0, 9), $head.Substring(0, 9))
  }
  return (New-TcSyncResult -Code 0 -Rebased ([bool]$plan.NeedsRebase) -Head $head -Rem $rem -Ahead $ahead -RebaseTried ([bool]$plan.NeedsRebase) -Siblings $siblings -Degraded $degraded)
}

function New-TcSyncResult {
  <# One Invoke-TcSyncToRemote answer, with every field present on every path, so no reader has to ask whether a field
     exists before it reads one. The array fields are passed through untouched: a caller hands in $null, an empty array
     or the list itself, and a PARAMETER keeps each as it came, which a function's return value would not (PowerShell
     unrolls an array returned from a function, so an empty one arrives as $null). Degraded is '' or a comma list of
     what this sync could not do outside the lock (fetch, rebase); DirtyPaths is $null unless the tree was dirty;
     RebaseNeeded says origin moved past this branch and the rebase was NOT run (a dry run, or the hand-back probe). #>
  param([int]$Code, [string]$Outcome = '', [bool]$Rebased = $false, [string]$Head = '', [string]$Rem = '', [int]$Ahead = 0,
    [string]$Message = '', [bool]$RebaseTried = $false, $Siblings = $null, $ConflictFiles = $null, [string]$ConflictScope = '',
    $ConflictFilesAll = $null, [string]$ConflictAllBasis = '', $DirtyPaths = $null, [string]$Degraded = '', [bool]$RebaseNeeded = $false)
  return [pscustomobject]@{
    Code = $Code; Outcome = $Outcome; Rebased = $Rebased; Head = $Head; Rem = $Rem; Ahead = $Ahead; Message = $Message
    RebaseTried = $RebaseTried; Siblings = $Siblings; ConflictFiles = $ConflictFiles; ConflictScope = $ConflictScope
    ConflictFilesAll = $ConflictFilesAll; ConflictAllBasis = $ConflictAllBasis; DirtyPaths = $DirtyPaths; Degraded = $Degraded
    RebaseNeeded = $RebaseNeeded
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
  param([string]$Dir, [string]$Remote, [string]$Branch, [scriptblock]$BeforeTestAuditors = $null)
  $wg = Invoke-TcWarmGate -Dir $Dir
  $res = [pscustomobject]@{ Ran = $wg.Ran; Code = $wg.Code; Why = $wg.Why; RgSec = $wg.Sec; RgLines = $wg.Lines; TaSec = $null; TaExit = $null; TaLines = $null }
  if (-not ($wg.Ran -and $wg.Code -eq 0)) { return $res }
  # W2.3's SHAPE (W9.3 step 3): the rehearsal starts once run-gates has passed, beside test-auditors. A no-op when it
  # has already started beside run-gates.
  if ($BeforeTestAuditors) { & $BeforeTestAuditors }
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
  # WHAT THIS SYNC COULD NOT DO OUTSIDE THE LOCK (W2.1R): degraded is a comma list of distinct words, in first-seen order.
  if ($props['Degraded'] -and $props['Degraded'].Value) { Add-TcDegraded -Row $Row -Words ([string]$props['Degraded'].Value) }
  # THE DIRT AND WHEN IT APPEARED (W8.1): at the pre-flight it was there at the start; any later sync found a tree the
  # pre-flight had found clean, so it appeared while the legs ran.
  if ($props['DirtyPaths'] -and $null -ne $props['DirtyPaths'].Value) {
    $Row['dirty_paths'] = [string[]]@($props['DirtyPaths'].Value)
    $Row['dirty_since'] = $(if ($Phase -ceq 'preflight') { 'start' } else { 'during-legs' })
  }
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

function Add-TcDegraded {
  <# Adds each comma-separated word of -Words to the row's `degraded` (a comma list, distinct, first seen first; null
     until something degraded). The probe reads it as text (B1(b) leaves out rows whose degraded mentions fetch). #>
  param([System.Collections.IDictionary]$Row, [string]$Words)
  $have = [Collections.Generic.List[string]]::new()
  foreach ($w in @(([string]$Row['degraded']) -split ',')) { if ($w.Trim()) { $have.Add($w.Trim()) } }
  foreach ($w in @($Words -split ',')) { $t = $w.Trim(); if ($t -and -not $have.Contains($t)) { $have.Add($t) } }
  $Row['degraded'] = $(if ($have.Count) { $have -join ',' } else { $null })
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

# ======================================================================================================================
# THE PRE-FLIGHT'S COUNTS (2026-09-23, W3.2 with W3.4a step 3). WARN ONLY: nothing here refuses a push (D3 decides any
# refusal, from a literal cutoff). They exist because design/BACKLOG-course-findings.md overlapped in 12 of 19 recent
# rebase conflicts, and because an inbox file the scheduled merge would quarantine is otherwise found hours later,
# unattended. The validator script is a seam: '' means this checkout's own ops\merge-backlog-inbox.ps1.
# ======================================================================================================================
$script:TcPmBacklogPath = 'design/BACKLOG-course-findings.md'
$script:TcPmInboxPrefix = 'design/backlog-inbox/'
$script:TcPmInboxValidatorScript = ''

function Get-TcRangeNameStatus {
  <# The commits of <Base>..HEAD, oldest first, each with its name-status lines, from `git log --no-renames
     --name-status` (so a move is a D plus an A, and a move OUT of the inbox shows as the D it is). $null when git fails. #>
  param([string]$Dir, [string]$Base)
  $r = Invoke-TcGit -Dir $Dir -Arguments @('-c', 'core.quotepath=off', 'log', '--reverse', '--no-renames', '--name-status', '--format=TC-COMMIT %H', ($Base + '..HEAD'))
  if ($r.Code -ne 0) { return $null }
  $commits = [Collections.Generic.List[object]]::new()
  $cur = $null
  foreach ($l in @($r.Out)) {
    $s = [string]$l
    if ($s.StartsWith('TC-COMMIT ')) { $cur = [pscustomobject]@{ Sha = $s.Substring(10).Trim(); Files = [Collections.Generic.List[object]]::new() }; $commits.Add($cur); continue }
    if ($null -eq $cur) { continue }
    $parts = $s -split "`t", 2
    if ($parts.Count -eq 2) { $cur.Files.Add([pscustomobject]@{ Status = $parts[0].Trim(); Path = $parts[1].Trim() }) }
  }
  return , ($commits.ToArray())
}

function Get-TcBacklogCounts {
  <# W3.2 and W3.4a step 3 over the range's name-status (pure): BacklogDirect = commits that change the backlog file and
     neither delete nor move out any file under the inbox (a merge does one or the other); UpdatesModified = commits that
     MODIFY a file already under the inbox's updates/ (a lane appending to a day file the merge may already have consumed,
     which rebases into a modify/delete conflict); Added = the inbox .md files the range adds and HEAD still holds
     (README.md, _*.md and quarantine/ excluded, since the merge never reads them), distinct, in order. #>
  param($Commits)
  $direct = 0; $modUpd = 0
  $added = [Collections.Generic.List[string]]::new()
  $deleted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($c in @($Commits)) {
    if ($null -eq $c) { continue }
    $touchesBacklog = $false; $leavesInbox = $false; $modifiesUpd = $false
    foreach ($f in @($c.Files)) {
      $st = [string]$f.Status; $pa = [string]$f.Path
      if ([string]::Equals($pa, $script:TcPmBacklogPath, [StringComparison]::Ordinal)) { $touchesBacklog = $true }
      $inInbox = $pa.StartsWith($script:TcPmInboxPrefix, [StringComparison]::Ordinal)
      if ($inInbox -and $st.StartsWith('D')) { $leavesInbox = $true; [void]$deleted.Add($pa); [void]$added.Remove($pa) }
      if ($inInbox -and $st.StartsWith('M') -and $pa.StartsWith($script:TcPmInboxPrefix + 'updates/', [StringComparison]::Ordinal)) { $modifiesUpd = $true }
      if ($inInbox -and $st.StartsWith('A')) {
        $rel = $pa.Substring($script:TcPmInboxPrefix.Length)
        $leaf = [IO.Path]::GetFileName($rel)
        if ($leaf -like '*.md' -and $leaf -cne 'README.md' -and -not $leaf.StartsWith('_') -and -not $rel.StartsWith('quarantine/', [StringComparison]::Ordinal) -and -not $added.Contains($pa)) {
          $added.Add($pa); [void]$deleted.Remove($pa)
        }
      }
    }
    if ($touchesBacklog -and -not $leavesInbox) { $direct++ }
    if ($modifiesUpd) { $modUpd++ }
  }
  return [pscustomobject]@{ BacklogDirect = $direct; UpdatesModified = $modUpd; Added = [string[]]$added.ToArray() }
}

function Invoke-TcInboxValidate {
  <# ops\merge-backlog-inbox.ps1 -ValidateFile over one added inbox file, against THIS checkout's backlog. Code is the
     validator's (0 would merge, 2 would be quarantined, 3 could not evaluate), Reason the first line under its
     WOULD BE QUARANTINED heading. A validator that is missing or cannot start is 3. #>
  param([string]$Dir, [string]$File)
  $v = $(if ($script:TcPmInboxValidatorScript) { $script:TcPmInboxValidatorScript } else { Join-Path $Dir 'ops\merge-backlog-inbox.ps1' })
  if (-not (Test-Path -LiteralPath $v)) { return [pscustomobject]@{ Code = 3; Reason = 'no ops\merge-backlog-inbox.ps1 in this checkout' } }
  try {
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $v -ValidateFile $File -Backlog (Join-Path $Dir ($script:TcPmBacklogPath -replace '/', '\')))
    $code = $LASTEXITCODE
  } catch { return [pscustomobject]@{ Code = 3; Reason = ('the validator could not be started: ' + $_.Exception.Message) } }
  $reason = ''
  $seen = $false
  foreach ($l in $out) {
    $s = [string]$l
    if ($s -match '^WOULD BE QUARANTINED') { $seen = $true; continue }
    if ($seen -and $s.Trim()) { $reason = $s.Trim(); break }
  }
  if ($null -eq $code) { $code = 3 }
  return [pscustomobject]@{ Code = [int]$code; Reason = $reason }
}

function Invoke-TcBacklogPreflight {
  <# THE WARNINGS (W3.2 steps 2 and 3, W3.4a step 3) and the row's backlog_direct, inbox_invalid and
     inbox_updates_modified. Never refuses; a count git could not give is null and said. #>
  param([string]$Dir, [string]$Base, [System.Collections.IDictionary]$Row)
  if (-not $Base) { Say 'push-main: the branch base could not be read, so the backlog and inbox counts are not taken.'; return }
  $commits = Get-TcRangeNameStatus -Dir $Dir -Base $Base
  if ($null -eq $commits) { Say 'push-main: git could not list this branch''s commits, so the backlog and inbox counts are not taken.'; return }
  $bc = Get-TcBacklogCounts -Commits $commits
  $Row['backlog_direct'] = $bc.BacklogDirect
  $Row['inbox_updates_modified'] = $bc.UpdatesModified
  if ($bc.BacklogDirect -gt 0) {
    Say ("push-main: WARN - {0} commit(s) here edit design/BACKLOG-course-findings.md directly. That file overlapped in 12 of 19 recent rebase conflicts. Record progress as '## UPDATE <id>' in design/backlog-inbox/updates/ (see its README)." -f $bc.BacklogDirect)
  }
  if ($bc.UpdatesModified -gt 0) {
    Say ("push-main: WARN - {0} commit(s) here MODIFY an existing file under design/backlog-inbox/updates/. The merge may already have consumed and deleted that file, and the rebase then conflicts modify/delete; write a new file per batch, <lane>-<YYYY-MM-DD>-<HHmmss>.md (see its README)." -f $bc.UpdatesModified)
  }
  $invalid = 0
  foreach ($a in $bc.Added) {
    $full = Join-Path $Dir ($a -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $vr = Invoke-TcInboxValidate -Dir $Dir -File $full
    if ($vr.Code -eq 2) {
      $invalid++
      Say ("push-main: WARN - {0} would be QUARANTINED by the scheduled merge, not merged: {1}" -f $a, $(if ($vr.Reason) { $vr.Reason } else { 'the validator gave no reason line' }))
    } elseif ($vr.Code -ne 0) {
      Say ("push-main: {0} could not be validated (exit {1}): {2}. Not counted either way." -f $a, $vr.Code, $vr.Reason)
    }
  }
  $Row['inbox_invalid'] = $invalid
}

function Get-TcRereadDocLineCount {
  <# W4.1 step 7 (pure over `git log -p -U0` text): how many commits ADD a line carrying "Re-read at" to a top-level
     design/*.md file. The patch's own "+++" header is not an added line, and a removed re-read line is not counted. #>
  param($Lines)
  $n = 0; $cur = $false
  foreach ($l in @($Lines)) {
    $s = [string]$l
    if ($s.StartsWith('TC-COMMIT ')) { if ($cur) { $n++ }; $cur = $false; continue }
    if ($s.StartsWith('+++')) { continue }
    if ($s.StartsWith('+') -and $s -cmatch '\bRe-read at\b') { $cur = $true }
  }
  if ($cur) { $n++ }
  return $n
}

function Invoke-TcRereadPreflight {
  <# THE WARNING (W4.1 step 7) and the row's reread_doc_lines: commits of the branch that add a re-read as a doc line,
     where design/reread-ledger.tsv (ops\add-reread.ps1) is the road that cannot conflict. Never refuses; D3 decides. #>
  param([string]$Dir, [string]$Base, [System.Collections.IDictionary]$Row)
  if (-not $Base) { return }
  $r = Invoke-TcGit -Dir $Dir -Arguments @('-c', 'core.quotepath=off', 'log', '--reverse', '--no-renames', '--no-color', '-p', '-U0', '--format=TC-COMMIT %H', ($Base + '..HEAD'), '--', ':(glob)design/*.md')
  if ($r.Code -ne 0) { Say 'push-main: git could not list this branch''s design/*.md changes, so the re-read count is not taken.'; return }
  $n = Get-TcRereadDocLineCount -Lines $r.Out
  $Row['reread_doc_lines'] = $n
  if ($n -gt 0) { Say ("push-main: WARN - {0} commit(s) here add a re-read as a doc line; record it with ops\add-reread.ps1 instead" -f $n) }
}

# ======================================================================================================================
# -PREPARE: START THE COMMIT-TIME CHAIN REHEARSAL (2026-09-23, W9.1 step 3, push-main's half; D19 ruled yes, so the
# trigger is ops/hooks/post-commit, which runs this detached). It fetches, starts `ops\rehearse-chain.ps1 -Early -Onto
# <origin sha>` DETACHED, and reports what that child decided. It moves no HEAD, runs no leg and takes no lock; the
# per-checkout guard is not taken either, since a fetch that only updates the remote-tracking ref cannot rewrite a
# running push's HEAD. Every judgement that costs a read (does the content touch a manifest member, is there already a
# verdict for the rebased key, is another checkout's early run holding it, does this commit supersede an older run) is
# rehearse-chain's, whose Get-RhManifestSet is the one implementation of the key.
# DETACHED MEANS OUTSIDE THIS PROCESS TREE: the rehearsal takes about 14 minutes and the hook's shell exits in seconds,
# so the child is created by Win32_Process.Create (its parent is WmiPrvSE, measured 2026-09-23), which no job object or
# tree-kill of the caller reaches; it inherits the user's own environment, not this process's, so GIT_DIR and the rest of
# a hook's repository variables never reach it. When CIM is unavailable, Start-Process is the fallback, said.
# The child's output goes to %LOCALAPPDATA%\ThriftyCrew\push-main-prepare\<key16>.log (one file per checkout, outside it,
# overwritten per start). -Prepare waits up to $script:TcPmPrepareDecideSec for the child's first decision line and prints
# it; a hang guard, not a speed bar.
# ======================================================================================================================
$script:TcPmPrepareLogRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ThriftyCrew\push-main-prepare'
$script:TcPmPrepareDecideSec = 90
$script:TcPmPrepareStarter = $null   # a self-test seam: { param($Exe, $Args, $Log, $WorkDir) } returning the child's pid

function Start-TcDetachedProcess {
  <# Starts `powershell.exe <-File script args>` with its stdout and stderr in $Log, outside this process tree
     (Win32_Process.Create), or with Start-Process when CIM cannot. Returns Pid (0 when nothing started), How and Why. #>
  param([string]$Script, [string[]]$ScriptArgs, [string]$Log, [string]$WorkDir)
  $ps = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
  if (-not $ps) { $ps = 'powershell.exe' }
  $quoted = @($ScriptArgs | ForEach-Object { $a = [string]$_; if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }) -join ' '
  $line = 'cmd.exe /d /s /c ""' + $ps + '" -NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" ' + $quoted + ' > "' + $Log + '" 2>&1"'
  try {
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $line; CurrentDirectory = $WorkDir } -ErrorAction Stop
    if ([int]$r.ReturnValue -eq 0 -and [int]$r.ProcessId -gt 0) { return [pscustomobject]@{ Pid = [int]$r.ProcessId; How = 'cim'; Why = '' } }
    $why = 'Win32_Process.Create returned ' + $r.ReturnValue
  } catch { $why = 'CIM could not start it: ' + $_.Exception.Message }
  try {
    $p = Start-Process -FilePath $ps -WorkingDirectory $WorkDir -WindowStyle Hidden -PassThru -ErrorAction Stop `
      -RedirectStandardOutput $Log -RedirectStandardError ($Log + '.err') `
      -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $Script + '"')) + @($ScriptArgs))
    return [pscustomobject]@{ Pid = [int]$p.Id; How = 'start-process'; Why = $why }
  } catch {
    return [pscustomobject]@{ Pid = 0; How = 'none'; Why = ($why + '; Start-Process could not start it either: ' + $_.Exception.Message) }
  }
}

function Read-TcSharedText {
  <# A file another process is still writing, read with FileShare.ReadWrite; '' when it cannot be read yet. #>
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  try {
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try { $sr = New-Object IO.StreamReader($fs); return $sr.ReadToEnd() } finally { $fs.Dispose() }
  } catch { return '' }
}

function Invoke-TcPushMainPrepare {
  <# -Prepare (see the block above). Returns 0 when the early rehearsal was started or rehearse-chain decided to start
     nothing, 3 when no child could be started at all or origin could not be named (never a pass, and never a refusal
     of anything: the hook ignores it). -RehearseScript and -LogRoot are the self-test's seams. #>
  param([string]$Dir, [string]$Remote, [string]$Branch, [string]$RehearseScript = '', [string]$LogRoot = '')
  # A HOOK'S REPOSITORY VARIABLES NEVER REACH THIS RUN'S git OR ITS CHILD (.claude/rules/ops-and-gates.md, "A git hook in
  # a LINKED worktree exports GIT_DIR"): post-commit clears them too, and this is the second line of that defence.
  Clear-TcGitRepoEnv
  $rh = $(if ($RehearseScript) { $RehearseScript } else { Join-Path $Dir 'ops\rehearse-chain.ps1' })
  if (-not (Test-Path -LiteralPath $rh)) { Say 'push-main -Prepare: this checkout has no ops\rehearse-chain.ps1, so there is no early rehearsal to start.'; return 0 }
  if ([IO.File]::ReadAllText($rh) -notmatch '\[switch\]\$Early\b') { Say 'push-main -Prepare: this checkout''s ops\rehearse-chain.ps1 has no -Early mode (it is older than W9.1), so no early rehearsal is started.'; return 0 }
  $f = Invoke-TcFetchWithRetry -Dir $Dir -Remote $Remote -Branch $Branch
  $onto = ''
  if ($f.Code -eq 0) { $onto = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'FETCH_HEAD')) }
  if (-not $onto) {
    $onto = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', ('refs/remotes/' + $Remote + '/' + $Branch)))
    if ($onto) { Say ("push-main -Prepare: `git fetch` failed (exit {0}), so the early rehearsal is based on the last-fetched {1}/{2}, {3}." -f $f.Code, $Remote, $Branch, $onto.Substring(0, 9)) }
  }
  if ($onto -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') { Say ("push-main -Prepare: COULD NOT EVALUATE - {0}/{1} could not be named, so nothing was started." -f $Remote, $Branch); return 3 }
  $root = $(if ($LogRoot) { $LogRoot } else { $script:TcPmPrepareLogRoot })
  try { if (-not (Test-Path -LiteralPath $root)) { $null = New-Item -ItemType Directory -Force -ErrorAction Stop $root } } catch { Say ('push-main -Prepare: the log directory could not be made (' + $_.Exception.Message + '); nothing was started.'); return 3 }
  $log = Join-Path $root ((Get-TcCheckoutGuardKey -Dir $Dir).Substring(0, 16) + '.log')
  Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
  $childArgs = [string[]]@('-Early', '-Onto', $onto, '-Remote', $Remote, '-Branch', $Branch)
  $st = $(if ($script:TcPmPrepareStarter) { & $script:TcPmPrepareStarter $rh $childArgs $log $Dir } else { Start-TcDetachedProcess -Script $rh -ScriptArgs $childArgs -Log $log -WorkDir $Dir })
  if ($null -eq $st -or [int]$st.Pid -le 0) { Say ('push-main -Prepare: COULD NOT start the early rehearsal (' + $(if ($st) { $st.Why } else { 'no answer from the starter' }) + ').'); return 3 }
  if ($st.Why) { Say ('push-main -Prepare: ' + $st.Why + '; started it with Start-Process instead, inside this process tree.') }
  Say ("push-main -Prepare: started the early chain rehearsal of HEAD onto {0} as pid {1}; its output is {2}." -f $onto.Substring(0, 9), $st.Pid, $log)
  # ITS FIRST DECISION, read as it is written: "rehearsing ... (key K), in-flight file F" when it started, or its
  # completion line when it decided to start nothing. A hang guard only; past it, the log is where the answer will be.
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $said = ''
  while ($sw.Elapsed.TotalSeconds -lt $script:TcPmPrepareDecideSec) {
    $txt = Read-TcSharedText -Path $log
    $dec = @(($txt -split "`r?`n") | Where-Object { $_ -match '^chain-rehearsal: EARLY - rehearsing ' -or $_ -match '^CHAIN-REHEARSAL-EARLY-COMPLETE ' })
    if ($dec.Count) { $said = [string]$dec[0]; break }
    Start-Sleep -Milliseconds 250
  }
  if ($said) {
    Say ('push-main -Prepare: ' + $said)
    $mk = [regex]::Match($said, '\(key ([0-9a-f]+)\), in-flight file (.+)$')
    if ($mk.Success) { Say ("push-main -Prepare: key {0}, in-flight file {1}" -f $mk.Groups[1].Value, $mk.Groups[2].Value.Trim()) }
  } else {
    Say ("push-main -Prepare: the child had not decided within {0} s; it is still running, and its answer will be in {1}." -f $script:TcPmPrepareDecideSec, $log)
  }
  return 0
}

function Get-TcEarlyHit {
  <# The row's early_hit (W9.1 step 7), from what the round-1 -ForPush child said: not-chain when the push touched no
     member; yes when its covering verdict's record says early (an early=yes token on its CHAIN-REHEARSAL-CHECK-COMPLETE
     line, or a PASSED line naming an early rehearsal); no when it rehearsed now, found no verdict, or its marker says
     early=no; unknown when a chain push's child did not say (a rehearse-chain older than the token). Pure. #>
  param($ChainTouching, $Lines)
  if ($ChainTouching -eq $false -and $null -ne $ChainTouching) { return 'not-chain' }
  $all = @(@($Lines) | ForEach-Object { [string]$_ })
  $mark = @($all | Where-Object { $_ -match '^CHAIN-REHEARSAL-CHECK-COMPLETE ' })
  $last = $(if ($mark.Count) { $mark[$mark.Count - 1] } else { '' })
  $tok = [regex]::Match($last, '\bearly=(\S+)')
  if ($tok.Success) { if ($tok.Groups[1].Value -match '^(yes|1|true)$') { return 'yes' } else { return 'no' } }
  if (@($all | Where-Object { $_ -match '^chain-rehearsal: PASSED\b.*\bearly\b' }).Count) { return 'yes' }
  if (@($all | Where-Object { $_ -cmatch 'rehearsing HEAD now' }).Count) { return 'no' }
  if ($last -match '\boutcome=(no-verdict|stale|rehearsed-fail)\b') { return 'no' }
  if ($null -eq $ChainTouching) { return $null }
  return 'unknown'
}

# ======================================================================================================================
# THE CHAIN QUEUE (2026-09-23, W9.2, replacing W6.1's lease; lib\chain-queue.ps1 is the queue lane's, and its contract is
# design\backlog-inbox\pd-queue-interface-2026-09-23.md). A chain-touching push takes a TICKET; its rehearsal judges HEAD
# STACKED on the tickets ahead (a stack file of their ranges; only the rehearsal's own clone applies them, never this
# worktree); after its legs it waits until every ticket ahead has landed, left or died, holding NOTHING but the ticket
# (no gate slot, no rehearsal slot, no push lock); then it swaps. The ticket is not a lock held across a leg: it excludes
# nobody from running one, and defers only the next member's SWAP, which refs/heads/main serialises already (16.6, 0b).
# THE BOUND: the queue orders chain landings and adds no rehearsal capacity. Its ceiling is 6 rehearsal slots over 800 to
# 1,240 s, about 17 to 27 chain landings an hour (review), against about 4.2 an hour offered at the 09-19 peak (plan). Its
# cost is head-of-line: a member ready first waits for the one ahead, up to that one's remaining rehearsal (about 21
# minutes, review). It never livelocks: the only re-rehearsal is a restack after a ticket ahead failed or left.
# EVERY PATH DEGRADES TO W2.2R: a queue that cannot be joined, read or written records queue=error, a head that never moves
# for $script:TcPmChainQueueStallSec records queue=timeout, and either way the push leaves the queue and proceeds.
# ======================================================================================================================
$script:TcPmChainQueuePrefix = $script:TcChainQueuePrefix
$script:TcPmChainQueueRoot = $script:TcChainQueueRoot
$script:TcPmChainQueueStallSec = $script:TcChainQueueStallSec
# HOW OFTEN A WAITING MEMBER REPORTS ITS POSITION (the library's 300 s), and a self-test seam run at each report, which is
# how a fixture learns FROM THE MECHANISM that a member is really waiting for the head (never from a clock).
$script:TcPmChainQueueReportSec = $script:TcChainQueueReportSec
$script:TcPmOnQueueReport = $null
function Get-TcChainTouchingNow {
  <# Is this push chain-touching, asked BEFORE its rehearsal starts (the queue must be joined first, so the rehearsal can
     be stacked): ops\rehearse-chain.ps1 -CheckPush over the ref line git will hand the hook, which reads verdicts and never
     rehearses (seconds), with W6.0's union trigger. Touching $true, $false, or $null (it could not say); Outcome is its
     word. A checkout with no rehearse-chain is not chain-touching, as it is asked for no rehearsal. #>
  param([string]$Dir, [string]$Branch, [string]$Head, [string]$Rem)
  if (-not (Test-Path -LiteralPath (Join-Path $Dir 'ops\rehearse-chain.ps1'))) { return [pscustomobject]@{ Touching = $false; Outcome = 'no-harness'; Why = 'this checkout has no ops\rehearse-chain.ps1' } }
  $ck = Invoke-TcRehearsalCheck -Dir $Dir -Branch $Branch -Head $Head -RemoteSha $Rem
  $m = [regex]::Match([string]$ck.Why, '\boutcome=(\S+)')
  if (-not $m.Success) { return [pscustomobject]@{ Touching = $null; Outcome = ''; Why = [string]$ck.Why } }
  $t = $null
  try { $t = Get-TcChainTouching -Outcome $m.Groups[1].Value } catch { $t = $null }
  return [pscustomobject]@{ Touching = $t; Outcome = $m.Groups[1].Value; Why = [string]$ck.Why }
}

function Get-TcRangeShas {
  <# `git rev-list --reverse <Base>..HEAD`, oldest first, as a string array (empty on any failure). #>
  param([string]$Dir, [string]$Base)
  if (-not $Base) { return , ([string[]]@()) }
  $r = Invoke-TcGit -Dir $Dir -Arguments @('rev-list', '--reverse', ($Base + '..HEAD'))
  if ($r.Code -ne 0) { return , ([string[]]@()) }
  return , ([string[]]@(@($r.Out) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match '^[0-9a-f]{40}([0-9a-f]{24})?$' }))
}

function Get-TcStackConflict {
  <# What a rehearsal child said about a stack conflict (W9.2 step 7): its "chain-rehearsal: STACK CONFLICT - applying
     <sha9> onto the stack conflicts in: <files>" line, as Sha9 and Files, or $null when it said none. Pure. #>
  param($Lines)
  foreach ($l in @($Lines)) {
    $m = [regex]::Match([string]$l, 'STACK CONFLICT - applying ([0-9a-f]+) onto the stack conflicts in: (.+)$')
    if ($m.Success) { return [pscustomobject]@{ Sha9 = $m.Groups[1].Value; Files = [string[]]@(($m.Groups[2].Value -split ',\s*') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } }
  }
  if (@(@($Lines) | Where-Object { [string]$_ -match '\bblind=stack-conflict\b' }).Count) { return [pscustomobject]@{ Sha9 = ''; Files = [string[]]@() } }
  return $null
}

function Get-TcRehearsalKey {
  <# The verdict key a rehearsal child printed when it REHEARSED: the key= token of its CHAIN-REHEARSAL-COMPLETE line
     (ops\rehearse-chain.ps1's Format-RhComplete, the stacked tip's key when it was stacked), or '' when it rehearsed
     nothing (a reuse prints no key). A member records it as its rh_key, so a rebase that keeps the key does not make
     the members behind it restack (the interface's restack rule). Pure. #>
  param($Lines)
  $k = ''
  foreach ($l in @($Lines)) { $m = [regex]::Match([string]$l, '^CHAIN-REHEARSAL-COMPLETE\b.*\bkey=([0-9a-f]{12,64})\b'); if ($m.Success) { $k = $m.Groups[1].Value } }
  return $k
}

function Resolve-TcStackConflictTicket {
  <# The ticket ahead whose range touched the conflicting files (the interface's rule for a stop on the member's OWN
     commit): `git diff-tree --name-only -r` over each ahead range, first match in ticket order; '' when none. #>
  param([string]$Dir, $Stack, [string[]]$Files)
  if (-not $Stack -or -not @($Files).Count) { return '' }
  foreach ($a in @($Stack.Ahead)) {
    foreach ($s in @($a.Range)) {
      $ch = Invoke-TcGit -Dir $Dir -Arguments @('diff-tree', '--no-commit-id', '--name-only', '-r', [string]$s)
      if (@(@($ch.Out) | Where-Object { $Files -contains ([string]$_).Trim() }).Count) { return [string]$a.Name }
    }
  }
  return ''
}

function Update-TcChainQueueRange {
  <# After ANY rebase of this worktree (catch-up, hand-back, in-lock), the member's record carries its new base and range,
     so a member behind sees the new range with the same rh_key and does not restack (interface step 7). #>
  param($Member, [string]$Dir, [string]$Rem)
  if (-not $Member -or $Member.Queue -cne 'joined' -or -not $Rem) { return }
  $base = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('merge-base', 'HEAD', $Rem))
  if (-not $base) { return }
  $rng = Get-TcRangeShas -Dir $Dir -Base $base
  $null = Set-TcChainQueueState -Member $Member -Base $base -Range $rng
}

# ======================================================================================================================
# THE MAIN CHECKOUT LANDS THROUGH A THROWAWAY WORKTREE (2026-09-23, W8.2). The main checkout is always dirty (other
# sessions, the bots, board steps), so push-main from it was refused-not-ready 16 of 16 times since 09-16 and it landed
# only by plain push, which races the whole hook (a CAS whose critical section is the hook). Here it lands like any other
# checkout: a detached worktree of HEAD under %TEMP%, seeded by push-main's own seed after the pre-flight, runs the WHOLE
# sequence (guard, pre-flight, legs, queue, lock); the main checkout is never rebased, and its dirt never matters. After a
# landing, when the main checkout's HEAD is still the sha the run started from, `git reset --keep <landed tip>` brings
# local main to the landed tip, so nothing is left for the bot's `-X theirs` replay. Step 0, measured 2026-09-23 on git
# 2.54 in a scratch repo carrying this repo's .gitattributes: dirty tracked files the landing does not touch and untracked
# files stay byte-identical; another session's staged entry is unstaged with its content kept (git's --keep table); a
# local edit to a file the landing changes makes --keep refuse (exit 128) and change nothing. When HEAD moved or --keep
# refuses, nothing is changed: the landed tip and the one command to run are printed, main_sync=manual, exit 0.
# LIKE A PLAIN PUSH IT LANDS THE WHOLE BRANCH (UNPUSHED IS NOT PRIVATE), so every commit it will land is printed first.
# It adds no lock. Its cost is one seed of a fresh worktree per run, and only from the main checkout.
# ======================================================================================================================
function Invoke-TcPushMainViaWorktree {
  param([string]$MainDir, [string]$Remote, [string]$Branch, [int]$LockWaitSec, [bool]$DryRun, [string]$WorktreeRoot = '', [System.Collections.IDictionary]$PushArgs = $null, [string]$LedgerRoot = '')
  $f = Invoke-TcFetchWithRetry -Dir $MainDir -Remote $Remote -Branch $Branch
  $rem = $(if ($f.Code -eq 0) { Get-TcFirstLine (Invoke-TcGit -Dir $MainDir -Arguments @('rev-parse', 'FETCH_HEAD')) } else { Get-TcFirstLine (Invoke-TcGit -Dir $MainDir -Arguments @('rev-parse', ('refs/remotes/' + $Remote + '/' + $Branch))) })
  $startHead = Get-TcFirstLine (Invoke-TcGit -Dir $MainDir -Arguments @('rev-parse', 'HEAD'))
  $aheadR = Invoke-TcGit -Dir $MainDir -Arguments @('log', '--format=%h %s', ($rem + '..HEAD'))
  $ahead = @(@($aheadR.Out) | Where-Object { ([string]$_).Trim() })
  if (-not $rem -or -not $startHead -or $aheadR.Code -ne 0 -or $ahead.Count -eq 0) {
    Say ("push-main: REFUSED - the main checkout has no commit that {0}/{1} does not already hold, so there is nothing to land and no throwaway worktree was made." -f $Remote, $Branch)
    $wr = Write-TcPushRow -Event 'push-main' -WaitMs -1 -State 'not-taken' -BaseSha $rem -GrantSha '' -Outcome 'refused-not-ready' -Checkout $MainDir -Root $LedgerRoot -Fields ([ordered]@{ schema = 2; via_worktree = $true; phase = 'preflight' })
    if (-not $wr.Written) { Say ('push-main: the push ledger row was NOT written (' + $wr.Reason + ').') }
    return 1
  }
  Say ("push-main: from the MAIN checkout, so this lands through a throwaway worktree. Like any push it lands the WHOLE branch, these {0} commit(s):" -f $ahead.Count)
  foreach ($c in $ahead) { Say ('  ' + $c) }
  $root = $(if ($WorktreeRoot) { $WorktreeRoot } else { $env:TEMP })
  $wtDir = Join-Path $root ('tc-pm-via-' + $PID + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $add = Invoke-TcGit -Dir $MainDir -Arguments @('worktree', 'add', '--detach', $wtDir, $startHead)
  if ($add.Code -ne 0) { Say ('push-main: COULD NOT EVALUATE - the throwaway worktree could not be made (git exited ' + $add.Code + '): ' + $add.Text); return 3 }
  try {
    $vwMainDir = $MainDir; $vwStartHead = $startHead
    $landedSync = {
      param($wd)
      $landed = Get-TcFirstLine (Invoke-TcGit -Dir $wd -Arguments @('rev-parse', 'HEAD'))
      $now = Get-TcFirstLine (Invoke-TcGit -Dir $vwMainDir -Arguments @('rev-parse', 'HEAD'))
      if (-not [string]::Equals($now, $vwStartHead, [StringComparison]::Ordinal)) {
        Say ("push-main: LANDED from the throwaway worktree at {0}, but the main checkout's HEAD moved while it ran ({1} -> {2}), so it is left exactly as it is. To bring local main to what landed, when it is safe: git -C `"{3}`" reset --keep {0}" -f $landed.Substring(0, 9), $vwStartHead.Substring(0, 9), $now.Substring(0, [Math]::Min(9, $now.Length)), $vwMainDir)
        return 'manual'
      }
      $rk = Invoke-TcGit -Dir $vwMainDir -Arguments @('reset', '--keep', $landed)
      if ($rk.Code -ne 0) {
        Say ("push-main: LANDED at {0}, but `git reset --keep` refused in the main checkout (a local change to a file the landing touched), so nothing there was changed. When it is safe: git -C `"{1}`" reset --keep {0}`n{2}" -f $landed.Substring(0, 9), $vwMainDir, $rk.Text)
        return 'manual'
      }
      Say ("push-main: the main checkout's local main now carries the landed tip {0} (git reset --keep: its uncommitted files are untouched, and a staged entry keeps its content, unstaged)." -f $landed.Substring(0, 9))
      return 'reset-keep'
    }
    $call = @{ Dir = $wtDir; Remote = $Remote; Branch = $Branch; LockWaitSec = $LockWaitSec; DryRun = $DryRun; ExtraRowFields = ([ordered]@{ via_worktree = $true }); AfterLanded = $landedSync }
    if ($LedgerRoot) { $call['LedgerRoot'] = $LedgerRoot }
    if ($PushArgs) { foreach ($k in @($PushArgs.Keys)) { $call[$k] = $PushArgs[$k] } }
    return (Invoke-TcPushMain @call)
  } finally {
    # THE THROWAWAY GOES ON EVERY PATH, and the main checkout is left exactly as it was on every refusal.
    $null = Invoke-TcGit -Dir $MainDir -Arguments @('worktree', 'remove', '--force', $wtDir)
    $null = Invoke-TcGit -Dir $MainDir -Arguments @('worktree', 'prune')
    if (Test-Path -LiteralPath $wtDir) { Remove-Item -LiteralPath $wtDir -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-TcPushMainReexec {
  <# RUN THE NEW COPY ONCE (W2.1R step 8): the script at -Path as a child, with -Arguments and TC_PUSH_MAIN_REEXEC=1, its
     lines echoed as they arrive. Returns its exit code, or $null when it could not be started, in which case the caller
     goes on with the copy already running (the day before). A child whose exit code cannot be read is 3. #>
  param([string]$Path, [string[]]$Arguments)
  $was = $env:TC_PUSH_MAIN_REEXEC
  $env:TC_PUSH_MAIN_REEXEC = '1'
  $code = $null
  try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments | ForEach-Object { Say ([string]$_) }
    $code = $LASTEXITCODE
  } catch {
    Say ('push-main: the new copy could not be started (' + $_.Exception.Message + '); going on with the copy already running.')
    return $null
  } finally {
    if ($null -eq $was) { Remove-Item -LiteralPath Env:TC_PUSH_MAIN_REEXEC -ErrorAction SilentlyContinue } else { $env:TC_PUSH_MAIN_REEXEC = $was }
  }
  if ($null -eq $code) { return 3 }
  return [int]$code
}
# EXTRA ARGUMENTS A RE-EXEC PASSES ON (the -NoRehearsal pair), set by the script body below; empty in the self-test.
$script:TcPmReexecExtra = @()

function Invoke-TcPushMain {
  param([string]$Dir, [string]$Remote, [string]$Branch, [int]$LockWaitSec, [bool]$DryRun, [string]$LockPrefix = '', [string]$LockQueueRoot = '', [scriptblock]$GateRunner = $null, [string]$LedgerRoot = '', [string]$SeedScript = '', [scriptblock]$RehearsalRunner = $null, [scriptblock]$RehearsalCheck = $null, [bool]$NoReexec = $false, [scriptblock]$RehearsalStarter = $null, [string]$ChainQueue = 'live', [scriptblock]$ChainTouchingProbe = $null, [System.Collections.IDictionary]$ExtraRowFields = $null, [scriptblock]$AfterLanded = $null)
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
    # W2.1R and W8.1: what a sync could not do outside the lock, the dirt and when it appeared, who held the guard on a
    # guard refusal, and whether this run is the re-executed new copy.
    degraded             = $null
    dirty_paths          = $null
    dirty_since          = $null
    guard_holder         = $null
    reexec               = [bool]$env:TC_PUSH_MAIN_REEXEC
    # W2.2R: catch-up rounds run (origin moved after a round's legs and was rebased onto outside the lock), and catch-up
    # fetches made (one after every round's legs while the cap allows).
    catchups             = 0
    catchup_fetches      = 0
    # W9.4: lock hand-backs (origin moved between the last outside round and the fetch inside the lock), and the integer
    # seconds spent outside from each hand-back to the next lock take.
    hand_backs           = 0
    handback_sec         = 0
    # W3.2 and W3.4a step 3 (warn only): commits editing the backlog directly, added inbox files the merge would
    # quarantine, and commits modifying an existing updates/ file. Null when the pre-flight could not count them.
    backlog_direct       = $null
    inbox_invalid        = $null
    inbox_updates_modified = $null
    # W4.1 step 7 (warn only): commits adding a re-read as a doc line instead of a design/reread-ledger.tsv row.
    reread_doc_lines     = $null
    # W9.1 step 7 (B22): yes, no, not-chain or unknown, from the first -ForPush of the run; null when no child said.
    # W8.2: whether this push ran in a throwaway worktree for the main checkout, and what became of the main checkout's
    # local main after it landed (reset-keep, or manual when its HEAD had moved or --keep refused); null otherwise.
    via_worktree         = $false
    main_sync            = $null
    early_hit            = $null
    # W9.3: whether the rehearsal child ended blind=stopped (a red leg wrote its stop file), and each round's rehearsal
    # seconds, 0 for a leg that reused or found a verdict (B21).
    rh_stopped           = $false
    rh_secs_list         = [int[]]@()
  }
  # ONE ROW PER RUN, and at most one (review of W0.1R, 2026-09-23): the guard below writes a row for a throw that no path
  # wrote one for, so every path now ends here, and a path that already wrote one is never written twice.
  $rowState = @{ Written = $false }
  $curPhase = $null
  if ($ExtraRowFields) { foreach ($xk in @($ExtraRowFields.Keys)) { $pmRow[$xk] = $ExtraRowFields[$xk] } }
  $cq = $null
  $cqState = @{ Decided = $false; AtHead = $false; Stack = $null }
  $writeRow = {
    if ($rowState.Written) { return }
    $rowState.Written = $true
    if ($cqState.Decided) {
      try { $qr = Get-TcChainQueueRow -Member $cq; foreach ($qk in @($qr.Keys)) { $pmRow[$qk] = $qr[$qk] } } catch { Say ('push-main: the queue row fields could not be read (' + $_.Exception.Message + '); they are recorded as unknown.') }
    }

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
  $guard = $null

  try {
    # ---- 0. ONE PUSH-MAIN PER CHECKOUT (W2.1R step 1): zero wait, so it serialises nothing across checkouts ----
    $guard = Enter-TcCheckoutGuard -Dir $Dir
    if ($guard.Refused) {
      Say ("push-main: REFUSED - another push-main is already landing this checkout ({0}): wait for it, do not relaunch. Every round rebases this checkout outside the push lock, so a second run here would rewrite HEAD under the first one's legs." -f $guard.Holder)
      $outcome = 'refused-not-ready'; $ledgerState = 'not-taken'; $pmRow['phase'] = 'preflight'; $pmRow['guard_holder'] = $guard.Holder
      & $writeRow
      return 1
    }
    if (-not $guard.Held) { Say ('push-main: the per-checkout guard was NOT taken (' + $guard.Reason + '); going on without it, as before it existed.') }
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
    # The default runner takes the rehearsal's starter as its second argument and calls it between run-gates and
    # test-auditors, which is W2.3's shape; in W9.3's shape the rehearsal has already started, and the call is a no-op.
    $runner = $(if ($GateRunner) { $GateRunner } else { { param($d, $bta) Invoke-TcDefaultLegs -Dir $d -Remote $Remote -Branch $Branch -BeforeTestAuditors $bta } })
    # THE STACK FILE the rehearsal is started with (W9.2 writes it for a queue member; empty otherwise).
    $stackFile = ''
    # THE SEED RUNS AFTER THE PRE-FLIGHT (W2.1R step 6), inside round 1 below: a seconds-long refusal should not wait for a
    # fresh worktree's 47 MB seed, and the rebase needs no seeded input (the seeded paths are gitignored).
    $checker = $(if ($RehearsalCheck) { $RehearsalCheck } else { { param($d, $h, $r) Invoke-TcRehearsalCheck -Dir $d -Branch $Branch -Head $h -RemoteSha $r } })
    $rebasedAny = $false
    $rehearsals = 0
    # THE ROW'S SUMS OVER ROUNDS (W0.1R step 5). Kept as doubles and written rounded after every change, so whichever path
    # writes the row carries every take and every catch-up leg so far.
    $lockWaitTotal = 0.0
    $lockHeldTotal = 0.0
    $catchupTotal = 0.0
    # THE LOOP'S THREE COUNTERS (W2.2R). `rounds` counts LEG SETS. A round starts after round 1 for one of two reasons: the
    # catch-up fetch after a round's legs found origin moved and rebased outside the lock ($catchUps, at most
    # $script:PmMaxCatchUpRounds), or the in-lock verdict check handed the lock back. The rehearsal budget
    # ($script:PmMaxRehearsalRounds) counts only rounds whose rehearsal leg REHEARSED, so cheap catch-up rounds over
    # non-chain moves never spend it. $script:PmMaxLegSets bounds the whole loop so no combination can run unbounded.
    $round = 0
    $catchUps = 0
    $rehearsedRounds = 0
    $syncFirst = $true
    $lastSync = $null
    # W9.4: lock hand-backs so far, the phase the next round's own sync carries (handback after a hand-back), and the
    # outside time spent from each hand-back to the next lock take.
    $handBacks = 0
    $nextSyncPhase = 'catchup'
    $handBackSw = $null
    $handBackTotal = 0.0
    while ($true) {
      $round++
      if ($round -gt $script:PmMaxLegSets) {
        # NEVER REACHED WHEN THE CHECK AND THE REHEARSAL AGREE: every extra round either rehearses (and spends the budget) or
        # follows a catch-up (at most 3). A check that keeps saying not-covered over a verdict the rehearsal keeps reusing is
        # a disagreement, and it is refused rather than looped on.
        Say ("push-main: REFUSED - {0} leg sets ran and the in-lock verdict check still did not cover the content the rehearsal said it covered; the two disagree, so this is refused rather than looped on. The branch is rebased and nothing was pushed." -f $script:PmMaxLegSets)
        $outcome = 'refused-rehearsal-churn'; $ledgerState = 'not-taken'; $pmRow['phase'] = 'catchup'
        & $writeRow
        return 1
      }
      # WHICH PHASE A REFUSAL BEFORE THE LOCK BELONGS TO (W0.1R step 4): round 1's fetch and rebase are the pre-flight, and
      # everything before the lock in a later round is the catch-up. Round 1's LEGS carry no phase: their outcome already
      # names where the push stopped, and a row from before this loop existed reads the same way.
      $syncPhase = $(if ($round -eq 1) { 'preflight' } else { $nextSyncPhase })
      $nextSyncPhase = 'catchup'
      # A REFUSAL IN A HAND-BACK ROUND'S SYNC IS A CATCH-UP REFUSAL (W9.4 step 2): rebase_phases says handback, phase catchup.
      $syncRefusePhase = $(if ($syncPhase -ceq 'handback') { 'catchup' } else { $syncPhase })
      $legPhase = $(if ($round -eq 1) { $null } else { 'catchup' })
      $legsDegraded = $false

      # ---- 1. FETCH AND REBASE, OUTSIDE THE LOCK (2026-09-23, ops lane) ----
      # Until this change the fetch and the rebase happened only INSIDE the lock, AFTER the gate and the rehearsal, so both
      # judged the content from BEFORE the rebase. The gate's per-input keys absorbed that; the rehearsal could not, because
      # its verdict is keyed on the manifest set of the exact commit pushed, and a rebase over any commit touching a
      # manifest script moves the key. The hook then found no verdict for the rebased content, refused, and the push paid
      # a second 13-to-15-minute rehearsal (several landings on 2026-09-23). Rebasing FIRST makes the rehearsed content the
      # content that lands whenever origin holds still for the length of the rehearsal.
      # A ROUND THAT FOLLOWS A CATCH-UP STARTS SYNCED: the catch-up fetch after the last legs already rebased outside the
      # lock, so fetching again here would only repeat it. A round after a hand-back (or round 1) starts with its own sync.
      if ($syncFirst) {
      $curPhase = $syncPhase
      $s = Invoke-TcSyncToRemote -Dir $Dir -Remote $Remote -Branch $Branch -Phase $syncPhase -NoRebase $DryRun
      $lastSync = $s
      $null = Invoke-TcRowReader 'sync' { Add-TcSyncReadings -Row $pmRow -Sync $s -Phase $syncPhase }
      # ROUND 1 ONLY: a later round's fetch is catch-up, and preflight_sha is what every B1 ancestry verdict is read against.
      if ($round -eq 1 -and $s.Rem) { $pmRow['preflight_sha'] = $s.Rem }
      if ($s.Code -ne 0) {
        Say $s.Message
        $outcome = $s.Outcome; $ledgerState = 'not-taken'; $pmRow['phase'] = $syncRefusePhase
        & $writeRow
        return $s.Code
      }
      if ($s.Rebased) { $rebasedAny = $true; Update-TcChainQueueRange -Member $cq -Dir $Dir -Rem $s.Rem }
      if ($round -eq 1) {
        # ---- RE-EXEC ON SELF-CHANGE (W2.1R step 8) ----
        # When the pre-flight rebase brought in a different ops\push-main.ps1, the copy running is not the copy that will
        # land, and a stale checkout's first push after a push-main change would run the old rules (3 of 5 knowable rows
        # after 5841e96b1 landed ran an older copy). So the guard is released and the new copy runs ONCE as a child with
        # the same arguments; its exit code is this run's and it writes the one row. A child never re-execs again
        # (TC_PUSH_MAIN_REEXEC), -NoReexec skips it on purpose, and a copy that cannot start leaves this one running.
        if ($s.Rebased -and $pmBlob -and -not $NoReexec -and -not $env:TC_PUSH_MAIN_REEXEC) {
          $nowBlob = Invoke-TcRowReader 'reexec-blob' { Get-TcScriptBlob -Path $script:TcPushMainPath } ''
          if ($nowBlob -and -not [string]::Equals($nowBlob, $pmBlob, [StringComparison]::Ordinal)) {
            Say ("push-main: the pre-flight rebase brought in a new ops\push-main.ps1 (blob {0} -> {1}), so the NEW copy runs this push once; this run writes no row of its own." -f $pmBlob.Substring(0, 9), $nowBlob.Substring(0, 9))
            Exit-TcCheckoutGuard $guard
            $reArgs = [string[]](@('-Remote', $Remote, '-Branch', $Branch, '-LockWaitSec', [string]$LockWaitSec) + @($(if ($DryRun) { '-DryRun' })) + @($(if ($ChainQueue -ceq 'off') { '-ChainQueue'; 'off' })) + @($script:TcPmReexecExtra) | Where-Object { $null -ne $_ -and $_ -ne '' })
            $childRc = Invoke-TcPushMainReexec -Path $script:TcPushMainPath -Arguments $reArgs
            if ($null -ne $childRc) {
              $rowState.Written = $true   # the child wrote this push's one row
              return $childRc
            }
            $guard = Enter-TcCheckoutGuard -Dir $Dir
          }
        }
        # THE PRE-FLIGHT'S COUNTS (W3.2, W3.4a step 3): warnings and row fields, never a refusal. The range is the branch's
        # own commits over what the pre-flight just fetched, so a sibling's commits on main are never counted as this one's.
        $bcBase = $(if ($s.Rem) { Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('merge-base', 'HEAD', $s.Rem)) } else { '' })
        $null = Invoke-TcRowReader 'backlog' { Invoke-TcBacklogPreflight -Dir $Dir -Base $bcBase -Row $pmRow }
        $null = Invoke-TcRowReader 'reread' { Invoke-TcRereadPreflight -Dir $Dir -Base $bcBase -Row $pmRow }
        # SEEDED AFTER THE PRE-FLIGHT, so neither leg judges a checkout that has no built cards (backlog I237).
        $null = Invoke-TcSeedBeforeGate -Dir $Dir -Seeder $SeedScript
        # ---- THE CHAIN QUEUE (W9.2 steps 1 to 4): joined once, before the rehearsal starts, by a chain-touching push ----
        # INCLUDING a -NoRehearsal push (rehearse-chain calls it bypassed, which is chain-touching): skipping the rehearsal
        # does not stop it voiding the tickets behind it.
        $cqState.Decided = $true
        if ($ChainQueue -ceq 'off') {
          $cq = Join-TcChainQueue -Mode off -Checkout $Dir -Prefix $script:TcPmChainQueuePrefix -QueueRoot $script:TcPmChainQueueRoot
          Say 'push-main: -ChainQueue off, so the chain queue is not opened (queue=off).'
        } else {
          $ctp = $(if ($ChainTouchingProbe) { & $ChainTouchingProbe $Dir $s.Head $s.Rem } else { Get-TcChainTouchingNow -Dir $Dir -Branch $Branch -Head $s.Head -Rem $s.Rem })
          if ($ctp.Touching -eq $true) {
            $cqBase = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('merge-base', 'HEAD', $s.Rem))
            $cq = Join-TcChainQueue -Mode live -Checkout $Dir -Base $cqBase -Range (Get-TcRangeShas -Dir $Dir -Base $cqBase) -Prefix $script:TcPmChainQueuePrefix -QueueRoot $script:TcPmChainQueueRoot
            if ($cq.Queue -ceq 'joined') {
              $cqState.Stack = New-TcChainStackFile -Member $cq -Origin $cqBase -Path (Join-Path $env:TEMP ('tc-pm-stack-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.txt'))
              if (-not $cqState.Stack.Ok) {
                Say ('push-main: the chain queue stack could not be read (' + $cqState.Stack.Reason + '); leaving the queue, and this push proceeds unqueued.')
                Exit-TcChainQueue -Member $cq -State left; $cq.Queue = 'error'; $cq.Reason = [string]$cqState.Stack.Reason; $cqState.Stack = $null
              } else {
                Say ("push-main: this push changes the daily chain, so it joined the chain queue (ticket {0}, {1} ahead); its rehearsal judges HEAD stacked on {2} ahead range(s), and it swaps only after they land or leave." -f $cq.Name, $cq.Position, @($cqState.Stack.Ahead).Count)
              }
            } else {
              Say ('push-main: the chain queue could not be joined (' + $cq.Reason + '); this push proceeds unqueued, as before (queue=error).')
            }
          } elseif ($ctp.Touching -eq $false) {
            $cq = $null
          } else {
            $cq = New-TcChainMember -Prefix $script:TcPmChainQueuePrefix -QueueRoot $script:TcPmChainQueueRoot -Checkout $Dir
            $cq.Reason = ('whether this push is chain-touching could not be read (' + $ctp.Why + ')')
            Say ('push-main: ' + $cq.Reason + '; it proceeds unqueued (queue=error).')
          }
        }
      }
      }
      $syncFirst = $true

      # ---- THE REHEARSAL BUDGET, BEFORE A ROUND THAT COULD REHEARSE AGAIN (W2.2R step 3, D11a) ----
      # When $script:PmMaxRehearsalRounds rounds have already made a new verdict and a catch-up has moved the content once
      # more, a fourth rehearsal is not started blind: the verdict check (seconds, it never rehearses) says whether a
      # recorded verdict still covers the rebased content. Covered, the round runs and its rehearsal leg reuses it. Not
      # covered, the push is refused-rehearsal-churn with the branch rebased. A check that cannot decide twice goes to the
      # lock without new legs, where the hook decides, as the day before.
      $skipLegs = $false
      if ($round -gt 1 -and $rehearsedRounds -ge $script:PmMaxRehearsalRounds) {
        $bh = $(if ($lastSync -and $lastSync.Head) { $lastSync.Head } else { Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'HEAD')) })
        $br = $(if ($lastSync -and $lastSync.Rem) { $lastSync.Rem } else { Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', ('refs/remotes/' + $Remote + '/' + $Branch))) })
        $bc = Invoke-TcCheckWithRetry -Checker $checker -Dir $Dir -Head $bh -Rem $br
        if ($bc.Word -ceq 'not-covered') {
          Say ("push-main: REFUSED - {0} rehearsal round(s) have already run, and the content the catch-up rebased onto is still not covered ({1}: {2}). No fourth rehearsal is started. The branch is rebased and nothing was pushed; run this again when main is quieter." -f $rehearsedRounds, (Get-TcChurnCause -Check $bc.Check), $bc.Check.Why)
          $outcome = 'refused-rehearsal-churn'; $ledgerState = 'not-taken'; $pmRow['phase'] = 'catchup'
          & $writeRow
          return 1
        }
        if ($bc.Word -ceq 'could-not-decide') {
          Say 'push-main: at the rehearsal budget the verdict check could not decide, twice; no new legs run, and the hook inside the lock decides, as before.'
          Add-TcDegraded -Row $pmRow -Words 'check'
          $skipLegs = $true
        }
      }
      if (-not $skipLegs) {

      # ---- 2 AND 3. THE LEGS, BEFORE THE LOCK, SIDE BY SIDE (W9.3; the gate's account is above $runner) ----
      # A red gate never queues, and a 3 is neither a refusal nor a pass: it leaves the gate to the hook inside the lock.
      # The chain rehearsal (2026-09-22 RCA F2) runs here too, unlocked: a push that changes a script in
      # ops\chain-manifest.json must carry a rehearsal over recent real data, the hook inside the lock only reads the
      # recorded verdict, and 1 (rehearsed and failed) and 3 (could not rehearse) both refuse before the queue.
      # SINCE W9.3 the rehearsal child is STARTED FIRST ($script:PmRehearsalBesideGate) and waited for after run-gates and
      # test-auditors have run in this process, so the three legs overlap; in W2.3's shape it starts after run-gates
      # passes, beside test-auditors. A red leg writes the child's stop file and waits for it to exit before refusing.
      # A LEG SET STARTS HERE, so this is what `rounds` counts. Round 1's legs are the row's leg readings (leg_sec and the
      # rest); a later round's legs are catch-up time, summed into catchup_sec.
      $pmRow['rounds'] = $round
      $curPhase = $legPhase
      $rehearsals++
      $pmRow['rehearsals'] = $rehearsals
      $stopFile = Join-Path $env:TEMP ('tc-pm-rhstop-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.flag')
      $rhBox = @{ Job = $null }
      # A QUEUE MEMBER NOT YET AT THE HEAD rehearses HEAD STACKED on the tickets ahead (W9.2 step 4); at the head, and for
      # every other push, the rehearsal judges HEAD on origin alone.
      $rhStack = $(if ($cq -and $cq.Queue -ceq 'joined' -and -not $cqState.AtHead -and $cqState.Stack -and $cqState.Stack.Ok) { [string]$cqState.Stack.Path } else { $stackFile })
      $rhDir = $Dir; $rhRunnerSeam = $RehearsalRunner; $rhStarterSeam = $RehearsalStarter; $rhStop = $stopFile
      $startRh = {
        if ($null -ne $rhBox.Job) { return }
        if ($rhStarterSeam) { $rhBox.Job = & $rhStarterSeam $rhDir $rhStack $rhStop }
        elseif ($rhRunnerSeam) { $rhBox.Job = New-TcRehearsalJob -Deferred $rhRunnerSeam -DeferredArg $rhDir }
        else { $rhBox.Job = Start-TcRehearsalChild -Dir $rhDir -Remote $Remote -Branch $Branch -StackFile $rhStack -StopFile $rhStop }
      }
      if ($script:PmRehearsalBesideGate) { & $startRh }
      $gateSw = [Diagnostics.Stopwatch]::StartNew()
      $g = & $runner $Dir $startRh
      $gateSw.Stop()
      if ($round -eq 1) {
        $null = Invoke-TcRowReader 'runner' { Add-TcRunnerReadings -Row $pmRow -Result $g }
      } else {
        $catchupTotal += $gateSw.Elapsed.TotalSeconds; $pmRow['catchup_sec'] = [int][math]::Round($catchupTotal)
      }
      if ($g.Ran -and $g.Code -eq 1) {
        $redWhy = $(if ($g.Why) { [string]$g.Why } else { 'run-gates exited 1' })
        # A RED LEG STOPS THE REHEARSAL (W9.3 step 4): its stop file is written at once, and this process waits for the
        # child to exit (it is never killed: a killed run leaves its scratch clone), then refuses refused-gate-red. A
        # runner seam's model has not started, so there is nothing to stop.
        if ($null -ne $rhBox.Job -and -not $rhBox.Job.Deferred -and $null -eq $rhBox.Job.Result) {
          try { [IO.File]::WriteAllText($stopFile, ('stopped by push-main pid ' + $PID + ': ' + $redWhy)) } catch { Say ('push-main: the rehearsal''s stop file could not be written (' + $_.Exception.Message + '); it will run to its end.') }
          Say 'push-main: a leg is red, so the chain rehearsal beside it was told to stop; waiting for it to exit (it stops itself within about 5 s and is never killed).'
          $rhRed = $rhBox.Job.Wait()
          $pmRow['rh_stopped'] = [bool]$rhRed.Stopped
          $pmRow['rh_secs_list'] = [int[]](@($pmRow['rh_secs_list']) + [int]$rhRed.Sec)
        }
        Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
        Say ("push-main: REFUSED - {0} before the lock was taken, so this push never entered the queue and nothing else on this box was held up. Fix the cause and run this again." -f $redWhy)
        $outcome = 'refused-gate-red'; $ledgerState = 'not-taken'; $pmRow['phase'] = $legPhase
        & $writeRow
        return 1
      }
      if ($g.Code -ne 0) {
        Say ("push-main: the gate did not settle outside the lock ({0}), so it is left to the hook inside the lock, gated exactly as before.{1}" -f $g.Code, $(if ($g.Why) { ' ' + $g.Why } else { '' }))
        # A LEG THAT COULD NOT EVALUATE ENDS THE CATCH-UP (W2.2R step 2.4): no further round is started over it, the push
        # goes to the lock, and the hook gates that leg there. The row names the leg.
        $legsDegraded = $true
        $taRan = ($null -ne (Get-TcOptionalProp $g 'TaExit')) -or ($null -ne (Get-TcOptionalProp $g 'TaSec'))
        Add-TcDegraded -Row $pmRow -Words $(if ($taRan) { 'test-auditors' } else { 'run-gates' })
      } else {
        Say 'push-main: gate PASSED outside the lock, so the lock is taken only for the fetch, the rebase and the ref update.'
      }

      # ---- 3. THE REHEARSAL'S ANSWER: started above (or now, when a runner never asked for it), waited for here ----
      & $startRh
      $rh = $rhBox.Job.Wait()
      Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
      $rhSec = [int](Get-TcOptionalProp $rh 'Sec')
      $pmRow['rh_stopped'] = [bool](Get-TcOptionalProp $rh 'Stopped')
      $rhNew = [bool](Invoke-TcRowReader 'rehearsed' { Test-TcRehearsedNew -Result $rh } $false)
      # EACH ROUND'S REHEARSAL SECONDS (W9.3 step 7, B21): 0 for a leg that reused or found a verdict.
      $pmRow['rh_secs_list'] = [int[]](@($pmRow['rh_secs_list']) + $(if ($rhNew) { $rhSec } else { 0 }))
      if ($round -eq 1) {
        $null = Invoke-TcRowReader 'rehearsal' { Add-TcRehearsalReadings -Row $pmRow -Result $rh -Sec $rhSec }
        # WAS THIS PUSH COVERED BY A COMMIT-TIME REHEARSAL (W9.1 step 7, B22)? Read off the FIRST -ForPush of the run.
        $pmRow['early_hit'] = Invoke-TcRowReader 'early_hit' { Get-TcEarlyHit -ChainTouching $pmRow['chain_touching'] -Lines (Get-TcOptionalProp $rh 'Lines') } $null
      } else {
        $catchupTotal += [double]$rhSec; $pmRow['catchup_sec'] = [int][math]::Round($catchupTotal)
      }
      if ($rhNew) {
        $pmRow['rehearsed'] = [int]$pmRow['rehearsed'] + 1
        # THE REHEARSAL BUDGET COUNTS ONLY THIS (W2.2R step 2): a round that made a new verdict. With one counter for every
        # round, cheap catch-up rounds over non-chain moves would spend it, and a chain push at a busy hour would reach the
        # cap on rounds that needed no rehearsal.
        $rehearsedRounds++
      }
      # A STACK CONFLICT IS A WARNING, NOT A REFUSAL (W9.2 step 7): the member keeps its place. If the ticket it conflicts
      # with lands, the catch-up rebase refuses it with phase catchup, which is the correct refusal; if it leaves, a restack.
      $sc = $(if ($rh.Code -eq 3 -and $cq -and $cq.Queue -ceq 'joined') { Get-TcStackConflict -Lines (Get-TcOptionalProp $rh 'Lines') } else { $null })
      if ($null -ne $sc) {
        $scSha = ''; foreach ($a in @($cqState.Stack.Ahead)) { foreach ($x in @($a.Range)) { if ($sc.Sha9 -and ([string]$x).StartsWith($sc.Sha9)) { $scSha = [string]$x } } }
        $cw = Set-TcChainStackConflict -Member $cq -Stack $cqState.Stack -Sha $scSha -Files $sc.Files -Ticket (Resolve-TcStackConflictTicket -Dir $Dir -Stack $cqState.Stack -Files $sc.Files)
        Say ("push-main: WARN - this push conflicts with the chain queue ticket ahead ({0}, pid {1}) in: {2}. It keeps its place: if that ticket lands, the catch-up rebase refuses this push; if it leaves, this push restacks." -f $(if ($cw -and $cw.Checkout) { $cw.Checkout } else { 'unknown' }), $(if ($cw) { $cw.Pid } else { 0 }), (@($sc.Files) -join ', '))
      } elseif ($rh.Code -ne 0) {
        Say ("push-main: REFUSED before the lock - {0}. The rehearsal lines above say which stage or cause. Rehearse again, or push with -NoRehearsal -NoRehearsalReason '<why>' to bypass loudly." -f $(if ($rh.Code -eq 3) { 'the chain rehearsal COULD NOT EVALUATE (exit 3), which is never a pass' } else { 'this push changes the daily chain and has no passing rehearsal (exit ' + $rh.Code + ')' }))
        $outcome = $(if ($rh.Code -eq 3) { 'refused-rehearsal-blind' } else { 'refused-rehearsal' }); $ledgerState = 'not-taken'; $pmRow['phase'] = $legPhase
        & $writeRow
        return $rh.Code
      }

      # ---- 3a. THE CHAIN QUEUE: WAIT FOR THE HEAD (W9.2 steps 5 and 6) ----
      # After its legs pass, a member waits until every ticket ahead has landed, left or died, holding NOTHING but its
      # ticket. A ticket ahead that left or died, or that rewrote what it stacks, is a RESTACK: a new stack file and ONE
      # more rehearsal (the worktree did not move, so the other legs are not run again). A queue that stalls for
      # $script:TcPmChainQueueStallSec, or cannot be read, is left, and the push proceeds as the W2.2R path does.
      # THE KEY THIS ROUND'S REHEARSAL RECORDED, as the member's rh_key (interface step 4); a reuse keeps the one it had.
      $rhKeyNow = Get-TcRehearsalKey -Lines (Get-TcOptionalProp $rh 'Lines')
      if ($rhKeyNow -and $cq -and $cq.Queue -ceq 'joined') { $null = Set-TcChainQueueState -Member $cq -RhKey $rhKeyNow }
      if ($cq -and $cq.Queue -ceq 'joined' -and -not $cqState.AtHead) {
        $null = Set-TcChainQueueState -Member $cq -State ready
        while ($cq.Queue -ceq 'joined') {
          $w = Wait-TcChainQueueHead -Member $cq -Stack $cqState.Stack -StallSec $script:TcPmChainQueueStallSec -ReportEverySec $script:TcPmChainQueueReportSec -OnReport { param($qpos, $qdepth, $qsec) Say ("push-main: waiting for the chain queue head: {0} ticket(s) ahead, waited {1}s; holding nothing but the ticket." -f $qpos, $qsec); if ($script:TcPmOnQueueReport) { & $script:TcPmOnQueueReport $qpos $qsec } }
          if ($w.Outcome -ceq 'head') { $cqState.AtHead = $true; Say 'push-main: every chain queue ticket ahead has landed or left; this push is at the head.'; break }
          if ($w.Outcome -ceq 'restack') {
            $rsF = Invoke-TcFetchWithRetry -Dir $Dir -Remote $Remote -Branch $Branch
            $rsO = $(if ($rsF.Code -eq 0) { Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'FETCH_HEAD')) } else { '' })
            if (-not $rsO) { $rsO = Get-TcFirstLine (Invoke-TcGit -Dir $Dir -Arguments @('merge-base', 'HEAD', ('refs/remotes/' + $Remote + '/' + $Branch))) }
            $cqState.Stack = New-TcChainStackFile -Member $cq -Origin $rsO -Path (Join-Path $env:TEMP ('tc-pm-stack-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.txt'))
            if (-not $cqState.Stack.Ok) { Say ('push-main: the chain queue stack could not be rebuilt (' + $cqState.Stack.Reason + '); leaving the queue, and this push proceeds unqueued.'); Exit-TcChainQueue -Member $cq -State left; $cq.Queue = 'error'; $cqState.Stack = $null; break }
            Say ("push-main: RESTACK - {0}; this push rehearses once more over {1} ahead range(s)." -f $w.Reason, @($cqState.Stack.Ahead).Count)
            $rsStop = Join-Path $env:TEMP ('tc-pm-rhstop-' + [guid]::NewGuid().ToString('N').Substring(0, 10) + '.flag')
            $rsJob = $(if ($RehearsalStarter) { & $RehearsalStarter $Dir $cqState.Stack.Path $rsStop } elseif ($RehearsalRunner) { New-TcRehearsalJob -Deferred $RehearsalRunner -DeferredArg $Dir } else { Start-TcRehearsalChild -Dir $Dir -Remote $Remote -Branch $Branch -StackFile $cqState.Stack.Path -StopFile $rsStop })
            $rsRes = $rsJob.Wait()
            Remove-Item -LiteralPath $rsStop -Force -ErrorAction SilentlyContinue
            $rsNew = [bool](Invoke-TcRowReader 'rehearsed' { Test-TcRehearsedNew -Result $rsRes } $false)
            $pmRow['rh_secs_list'] = [int[]](@($pmRow['rh_secs_list']) + $(if ($rsNew) { [int](Get-TcOptionalProp $rsRes 'Sec') } else { 0 }))
            if ($rsNew) { $pmRow['rehearsed'] = [int]$pmRow['rehearsed'] + 1 }
            $rsKey = Get-TcRehearsalKey -Lines (Get-TcOptionalProp $rsRes 'Lines')
            if ($rsKey) { $null = Set-TcChainQueueState -Member $cq -RhKey $rsKey }
            $rsSc = $(if ($rsRes.Code -eq 3) { Get-TcStackConflict -Lines (Get-TcOptionalProp $rsRes 'Lines') } else { $null })
            if ($null -ne $rsSc) {
              $null = Set-TcChainStackConflict -Member $cq -Stack $cqState.Stack -Sha '' -Files $rsSc.Files -Ticket (Resolve-TcStackConflictTicket -Dir $Dir -Stack $cqState.Stack -Files $rsSc.Files)
              Say 'push-main: WARN - the restacked rehearsal conflicts with a ticket ahead; this push keeps its place.'
            } elseif ($rsRes.Code -ne 0) {
              Say ('push-main: REFUSED before the lock - the restacked chain rehearsal did not pass (exit ' + $rsRes.Code + '). The rehearsal lines above say why.')
              $outcome = $(if ($rsRes.Code -eq 3) { 'refused-rehearsal-blind' } else { 'refused-rehearsal' }); $ledgerState = 'not-taken'; $pmRow['phase'] = 'catchup'
              & $writeRow
              return $rsRes.Code
            }
            continue
          }
          # timeout or error: the library set .Queue; leaving is what makes it never a refusal.
          Say ('push-main: the chain queue ' + $w.Outcome + ' (' + $w.Reason + '); leaving the queue, and this push proceeds unqueued, as before.')
          Exit-TcChainQueue -Member $cq -State left
          break
        }
      }

      # ---- 3b. CATCH-UP: RE-CHECK WHAT MOVED, OUTSIDE THE LOCK (W2.2R step 1) ----
      # The legs above took minutes, and origin may have moved while they ran. One unlocked fetch finds out before the lock
      # is taken. Unmoved (the usual case): take the lock. Moved: rebase HERE, outside the lock (a conflict refuses with
      # phase catchup), and start the next round, whose legs each reuse what their own keys allow (run-gates its
      # per-self-test keys, test-auditors its keyed pass, the rehearsal its verdict key), so nothing new decides "still
      # holds". A fetch that fails or a rebase that could not start degrades to the lock, where the in-lock sync and the
      # verdict check decide exactly as before (D11). At most $script:PmMaxCatchUpRounds catch-up rounds; past that the
      # push goes to the lock unchecked here. What it does when the producer stops: when main stops moving, no catch-up
      # round runs, and a push that never saw main move makes exactly one catch-up fetch.
      if ($legsDegraded) {
        Say 'push-main: a leg could not evaluate, so there is no catch-up round; the hook gates that leg inside the lock, as before.'
      } elseif ($catchUps -ge $script:PmMaxCatchUpRounds) {
        Say ("push-main: catch-up did not settle in {0} rounds; the hook gates the rest inside the lock, as before." -f $script:PmMaxCatchUpRounds)
      } else {
        $curPhase = 'catchup'
        $pmRow['catchup_fetches'] = [int]$pmRow['catchup_fetches'] + 1
        $cu = Invoke-TcSyncToRemote -Dir $Dir -Remote $Remote -Branch $Branch -Phase 'catchup' -NoRebase $DryRun
        $null = Invoke-TcRowReader 'sync' { Add-TcSyncReadings -Row $pmRow -Sync $cu -Phase 'catchup' }
        if ($cu.Code -ne 0) {
          Say $cu.Message
          $outcome = $cu.Outcome; $ledgerState = 'not-taken'; $pmRow['phase'] = 'catchup'
          & $writeRow
          return $cu.Code
        }
        if ($cu.Rebased) {
          $rebasedAny = $true
          Update-TcChainQueueRange -Member $cq -Dir $Dir -Rem $cu.Rem
          $catchUps++

          $pmRow['catchups'] = $catchUps
          $lastSync = $cu
          $syncFirst = $false
          Say ("push-main: origin moved while the legs ran, so this push was rebased OUTSIDE the lock; catch-up round {0} of at most {1} re-runs the legs, each reusing what its own keys allow." -f $catchUps, $script:PmMaxCatchUpRounds)
          continue
        }
      }
      }

      # ---- 4. THE LOCK: a final fetch, a rebase only if origin moved again, and the ref update ----
      # THE SWAP (W9.2 step 5): a member at the head says so before it takes the push lock.
      if ($cq -and $cq.Queue -ceq 'joined') { $null = Set-TcChainQueueState -Member $cq -State swapping }
      $lock = Enter-TcPushLock @enter
      $curPhase = 'inlock'

      if ($handBackSw) { $handBackSw.Stop(); $handBackTotal += $handBackSw.Elapsed.TotalSeconds; $pmRow['handback_sec'] = [int][math]::Round($handBackTotal); $handBackSw = $null }
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
        # LOCK ONLY THE SWAP (W9.4): below the hand-back cap, the fetch inside the lock only ASKS whether origin moved.
        $handBackNow = (-not $DryRun) -and ($handBacks -lt $script:PmMaxHandBacks)
        $s2 = Invoke-TcSyncToRemote -Dir $Dir -Remote $Remote -Branch $Branch -Phase 'inlock' -NoRebase $DryRun -ProbeOnly $handBackNow
        $null = Invoke-TcRowReader 'sync' { Add-TcSyncReadings -Row $pmRow -Sync $s2 -Phase 'inlock' }
        # WHAT THE REMOTE HOLDS NOW, read under the lock. Against $ledgerBase it says whether the remote moved while this
        # push queued - recorded whatever happens next, including on the paths that refuse.
        $ledgerGrant = $s2.Rem
        if ($s2.Code -ne 0) {
          Say $s2.Message
          $outcome = $s2.Outcome
          return $s2.Code
        }
        if ($handBackNow -and $s2.RebaseNeeded) {
          # THE HAND-BACK (W9.4 step 2): origin moved since the last outside round judged this content, so the lock is
          # released WITHOUT a rebase under it; the next round rebases outside (a conflict refuses, phase catchup), re-runs
          # the legs warm on their own keys, and takes the lock again. A hand-back counts here, never in the rehearsal
          # budget, unless its rehearsal leg REHEARSED.
          $handBacks++
          $pmRow['hand_backs'] = $handBacks
          $again = $true
          $nextSyncPhase = 'handback'
          Say ("push-main: origin moved since the last outside round, so the lock is handed back without a rebase under it (hand-back {0} of at most {1}); the rebase and the legs run outside it." -f $handBacks, $script:PmMaxHandBacks)
        } elseif ($s2.Rebased) {
          $rebasedAny = $true
          Update-TcChainQueueRange -Member $cq -Dir $Dir -Rem $s2.Rem
          # AT THE HAND-BACK CAP (W9.4 step 3) the rebase runs inside the lock, as 5841e96b1 did, and the verdict check is
          # the backstop. THE TRADE-OFF, SAID PLAINLY: origin moved AGAIN between the rebase outside the lock and this one. When that
          # move touched no chain-manifest script the verdict key is unchanged and the rehearsal above still covers the
          # content, so this push lands now. When it did touch one, no verdict covers the new content and the hook would
          # refuse, so the lock is handed back and this push gates and rehearses again OUTSIDE it - a push can still
          # re-rehearse, but only when origin changed a manifest script inside that window.
          # A CHECK THAT CANNOT DECIDE IS RETRIED ONCE, AND THEN THE HOOK DECIDES (W2.2R step 4): it takes about a second,
          # so a crash costs one more second, where handing the lock back over it cost a whole round of about 14 minutes.
          # Since W1.1 the hook's own record check runs first and refuses in seconds, so a wrong guess here costs seconds.
          $ckr = Invoke-TcCheckWithRetry -Checker $checker -Dir $Dir -Head $s2.Head -Rem $s2.Rem
          $ck = $ckr.Check
          $pmRow['inlock_check'] = $ckr.Word
          if ($ckr.Word -ceq 'not-covered') {
            if ($rehearsedRounds -ge $script:PmMaxRehearsalRounds) {
              # AT THE REHEARSAL BUDGET, WITH NO COVERING VERDICT: refused (D11a). The hook never rehearses, so pushing in
              # would be a certain refusal inside the lock.
              Say ("push-main: REFUSED - origin changed what the rehearsal covers while this push waited ({0}: {1}), and {2} rehearsal round(s) have already run, so no rehearsal could keep up with it. The branch is rebased and nothing was pushed; run this again when main is quieter." -f (Get-TcChurnCause -Check $ck), $ck.Why, $rehearsedRounds)
              $outcome = 'refused-rehearsal-churn'
              return 1
            }
            $again = $true
            Say ("push-main: origin moved again while this push waited, and the rebase inside the lock changed what the rehearsal covered ({0}). The lock is handed back; the next round gates and rehearses the rebased content OUTSIDE it ({1} of at most {2} rehearsal rounds used)." -f $ck.Why, $rehearsedRounds, $script:PmMaxRehearsalRounds)
          } elseif ($ckr.Word -ceq 'could-not-decide') {
            Say ("push-main: the in-lock verdict check could not decide, twice ({0}); the lock is NOT handed back over it, and the hook's own record check decides, as the day before." -f $ck.Why)
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
          # LANDED, THEN THE LOCK (W9.2 step 8): the ticket says landed before the push lock is released, so no member
          # behind can read this ticket as anything but landed once it could swap.
          if ($cq) { Exit-TcChainQueue -Member $cq -State landed }
          $outcome = $(if ($rebasedAny) { 'landed-after-rebase' } else { 'landed' })
          return 0
        }
      } finally {
        # THE LOCK GOES BACK FIRST, then the row is written: a ledger write must never sit inside the critical section
        # this whole file exists to keep short, and nothing reads the row to decide anything. A round that hands the lock
        # back to rehearse again writes no row; the push's one row is written when it finally lands or refuses.
        if ($lockSw) { $lockSw.Stop(); $lockHeldTotal += $lockSw.Elapsed.TotalMilliseconds; $pmRow['lock_held_ms'] = [long][math]::Round($lockHeldTotal) }
        # A REFUSAL INSIDE THE LOCK LEAVES THE QUEUE BEFORE THE LOCK GOES (W9.2 step 3); a hand-back keeps its ticket and
        # its place (W9.4). A landing already wrote landed, and a second exit is a no-op.
        if (-not $again -and $cq) { Exit-TcChainQueue -Member $cq -State left }
        Exit-TcPushLock $lock
        if ($again -and $nextSyncPhase -ceq 'handback') { $handBackSw = [Diagnostics.Stopwatch]::StartNew() }
        if (-not $again) {
          # EVERYTHING THAT ENDS IN HERE WITHOUT LANDING STOPPED IN THE LOCK: a refusal, a rejected push, a fetch that
          # failed, or a throw that left the outcome unknown. A landing and a dry run carry no phase.
          if (-not ($outcome -ceq 'landed' -or $outcome -ceq 'landed-after-rebase' -or $outcome -ceq 'dry-run')) { $pmRow['phase'] = 'inlock' }
          # AFTER A LANDING, OUTSIDE THE LOCK (W8.2): the via-worktree caller brings the main checkout's local main to the
          # landed tip, and its answer goes on this row. A throw costs the field, never the landing.
          if ($AfterLanded -and ($outcome -ceq 'landed' -or $outcome -ceq 'landed-after-rebase')) {
            try { $pmRow['main_sync'] = [string](& $AfterLanded $Dir) } catch { $pmRow['main_sync'] = 'manual'; Say ('push-main: bringing the main checkout to the landed tip threw (' + $_.Exception.Message + '); do it by hand.') }
          }
          & $writeRow
        }
      }
    }
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
  } finally {
    # THE TICKET GOES BACK ON EVERY PATH (W9.2 step 9), before the guard; a no-op after a landed exit.
    if ($cq) { try { Exit-TcChainQueue -Member $cq -State left } catch { Say ('push-main: leaving the chain queue threw (' + $_.Exception.Message + ').') } }
    if ($cqState.Stack -and $cqState.Stack.Path) { Remove-Item -LiteralPath ([string]$cqState.Stack.Path) -Force -ErrorAction SilentlyContinue }
    # THE GUARD GOES BACK ON EVERY PATH, a throw included; a guard this run never held is left alone.
    Exit-TcCheckoutGuard $guard
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
  # NO CASE OPENS THE PRODUCTION PER-CHECKOUT GUARD (plan section 5): every Invoke-TcPushMain below takes a private
  # Local\ name, and its holder files go under this run's root. Put back in the finally.
  $guardPrefixWas = $script:TcPmGuardPrefix
  $guardInfoWas = $script:TcPmGuardInfoRoot
  $script:TcPmGuardPrefix = 'Local\tc-pm-guard-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '-'
  $script:TcPmGuardInfoRoot = Join-Path $tmp 'guard'
  # AND NO CASE OPENS THE PRODUCTION CHAIN QUEUE (W9.2, interface step 11): a private Local\ prefix and a root under this
  # run's directory, with TC_CHAIN_QUEUE_SELFTEST set suite-wide, so a case that forgot the seam THROWS instead of
  # queueing real pushes behind it.
  $cqPrefixWas = $script:TcPmChainQueuePrefix; $cqRootWas = $script:TcPmChainQueueRoot; $cqSelfTestWas = $env:TC_CHAIN_QUEUE_SELFTEST
  $script:TcPmChainQueuePrefix = 'Local\tc-pm-cq-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '-'
  $script:TcPmChainQueueRoot = Join-Path $tmp 'cq'
  $env:TC_CHAIN_QUEUE_SELFTEST = '1'
  $reexecWas = $env:TC_PUSH_MAIN_REEXEC
  Remove-Item -LiteralPath Env:TC_PUSH_MAIN_REEXEC -ErrorAction SilentlyContinue
  . (Join-Path $repo 'lib\mutex-hold.ps1')   # Start-TcMutexHold: a guard held from ANOTHER process
  # CONSOLE CAPTURE, for the cases that read what push-main SAID: Say writes to [Console]::Out, which a StringWriter can
  # stand in for while one call runs. Children echoed through Say are captured too.
  function Invoke-StCapture([scriptblock]$CapBody) {
    $capOld = [Console]::Out
    $capSw = New-Object IO.StringWriter
    [Console]::SetOut($capSw)
    $capRes = $null
    try { $capRes = & $CapBody } finally { [Console]::SetOut($capOld) }
    return [pscustomobject]@{ Result = $capRes; Text = $capSw.ToString() }
  }
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
    # A SEEDED CHECKOUT IS RE-SEEDED (2026-09-23): the founding case was a reused worktree whose built card was copied
    # 2026-09-03 and never refreshed, because this returned 'already seeded' and never called the seeder again.
    $rS2 = Invoke-TcSeedBeforeGate -Dir $s1 -Seeder $sdStub
    $sFor2 = if (Test-Path -LiteralPath (Join-Path $s1 'seeded-for.txt')) { ([IO.File]::ReadAllText((Join-Path $s1 'seeded-for.txt'))).Trim() } else { '<not seeded>' }
    T ($kMF + '  a checkout whose seed directories already hold files is RE-SEEDED, so a stale seeded file can be refreshed') `
      ($rS2.Ran -and $rS2.Code -eq 0 -and [string]::Equals($sFor2, $s1, [StringComparison]::OrdinalIgnoreCase)) ("ran={0} code={1} why={2} seededFor={3}" -f $rS2.Ran, $rS2.Code, $rS2.Why, $sFor2)
    Remove-Item -LiteralPath (Join-Path $s1 'seeded-for.txt') -Force -ErrorAction SilentlyContinue
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
    $rR4 = (Start-TcRehearsalChild -Dir $s3 -Remote 'origin' -Branch 'main').Wait()
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
    # THE MODEL SAYS WHEN IT REUSED A VERDICT (W2.2R). It records every call in rhSeen, and it REHEARSES (records a new
    # verdict, and says Rehearsed) only for a chain.ps1 blob with no verdict yet; a blob it already covers is a reuse, as a
    # real -ForPush reads a recorded verdict in seconds. Each case clears rhVerdicts first, so its own first round rehearses.
    $rhModel = { param($d)
      [void]$script:rhSeen.Add(([string](@(& git -C $d rev-parse HEAD 2>$null))[0]).Trim())
      $pr = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -Name ($prefix + '0'))
      $script:rhLockFree = [bool](@($pr | Where-Object { "$_".Trim() -eq 'FREE' }).Count)
      $rk = & $blobOf $d
      $isNew = -not $script:rhVerdicts.ContainsKey($rk)
      $script:rhVerdicts[$rk] = $true
      if ($script:rhMoves.Count) { $mf = $script:rhMoves[0]; $script:rhMoves = @($script:rhMoves | Select-Object -Skip 1); & $moveOrigin $mf }
      return [pscustomobject]@{ Code = 0; Why = $(if ($isNew) { 'fixture: rehearsed-pass' } else { 'fixture: reused a recorded verdict' }); Rehearsed = $isNew }
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

    # THE LOCK-ENTRY MOVER (W2.2R). Since the catch-up fetch after every round's legs, a move made DURING the legs is caught
    # outside the lock, so the in-lock hand-back is reached only by a move in the window between that fetch and the fetch
    # inside the lock. Invoke-WithLockMover reaches it: for one run, Enter-TcPushLock is wrapped so that, immediately
    # before each real take, it applies the next entry of $script:lockMoves (a file name moved on origin, or a scriptblock),
    # and records the take's WaitedMs as the lock reported it. The real function is put back in finally.
    # W9.4: -LmCap is the lock hand-back cap for the run. The cases written before W9.4 pass 0 (the default): they are about
    # what happens AT the cap, where the lock rebases inside and the verdict check decides, which 0 reaches at the first
    # take. The W9.4 cases pass -1, which keeps the production cap. -LmDir names the checkout whose HEAD is recorded at
    # every take (after the grant) and every release, so a case can prove no rebase ran while the lock was held.
    $script:lockMoves = @()
    $script:lockWaitsSeen = [Collections.Generic.List[double]]::new()
    $script:lockHeads = [Collections.Generic.List[string]]::new()
    $script:lmDir = ''
    $script:enterTcPushLockReal = ${function:Enter-TcPushLock}
    $script:exitTcPushLockReal = ${function:Exit-TcPushLock}
    $script:handBackCapReal = $script:PmMaxHandBacks
    function Invoke-WithLockMover([scriptblock]$LmBody, [int]$LmCap = 0, [string]$LmDir = '') {
      $script:lockWaitsSeen.Clear(); $script:lockHeads.Clear(); $script:lmDir = $LmDir
      try {
        if ($LmCap -ge 0) { $script:PmMaxHandBacks = $LmCap }
        function script:Enter-TcPushLock {
          param([int]$WaitSec, [int]$PollMs, [string]$Prefix, [string]$QueueRoot, [scriptblock]$OnWait, [switch]$NoInherit)
          if ($script:lockMoves.Count) {
            $lmv = $script:lockMoves[0]; $script:lockMoves = @($script:lockMoves | Select-Object -Skip 1)
            if ($lmv -is [scriptblock]) { & $lmv } else { & $moveOrigin ([string]$lmv) }
          }
          $lk = & $script:enterTcPushLockReal @PSBoundParameters
          [void]$script:lockWaitsSeen.Add([double]$lk.WaitedMs)
          if ($script:lmDir) { [void]$script:lockHeads.Add('take ' + ([string](@(& git -C $script:lmDir rev-parse HEAD 2>$null))[0]).Trim()) }
          return $lk
        }
        function script:Exit-TcPushLock {
          param($Lock)
          if ($script:lmDir) { [void]$script:lockHeads.Add('release ' + ([string](@(& git -C $script:lmDir rev-parse HEAD 2>$null))[0]).Trim()) }
          & $script:exitTcPushLockReal $Lock
        }
        return (& $LmBody)
      } finally {
        $script:PmMaxHandBacks = $script:handBackCapReal
        Set-Item -LiteralPath 'function:script:Enter-TcPushLock' -Value $script:enterTcPushLockReal
        Set-Item -LiteralPath 'function:script:Exit-TcPushLock' -Value $script:exitTcPushLockReal
      }
    }

    # MUST FIRE, the founding order: origin moved over chain.ps1 BEFORE this push started. The one rehearsal must see a
    # HEAD already rebased on top of that move, with the push lock free while it runs, and the push lands on it.
    $q1 = & $newPusher 'q1'
    & $moveOrigin 'chain.ps1'
    $moved1 = & $tipOf
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}
    $tokenWas2 = $env:TC_PUSH_LOCK_HOLDER; $env:TC_PUSH_LOCK_HOLDER = $null
    $rQ1 = Invoke-TcPushMain -Dir $q1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck
    $env:TC_PUSH_LOCK_HOLDER = $tokenWas2
    $seen1 = $(if ($script:rhSeen.Count) { [string]$script:rhSeen[0] } else { '' })
    T ($kMF + '  the rehearsal judges the REBASED content: origin moved over a manifest script before the push, and the one rehearsal saw a HEAD already on top of it, outside the lock') `
      ($rQ1 -eq 0 -and $script:rhSeen.Count -eq 1 -and $seen1 -and (& $isAnc $q1 $moved1 $seen1) -and $script:rhLockFree -eq $true -and (& $tipOf) -eq $seen1) `
      ("rc={0} rehearsals={1} sawRebased={2} lockFree={3} landedWhatWasRehearsed={4}" -f $rQ1, $script:rhSeen.Count, $(if ($seen1) { & $isAnc $q1 $moved1 $seen1 } else { $false }), $script:rhLockFree, ((& $tipOf) -eq $seen1))

    # MUST FIRE, the trade-off: origin changes a manifest script in the window AFTER the catch-up fetch and before the fetch
    # inside the lock (the lock-entry mover). The rebase inside the lock moves the key, so the push hands the lock back and
    # rehearses the rebased content again before it pushes.
    $q2 = & $newPusher 'q2'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $rQ2 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $q2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck }
    $moved2 = ([string](@(& git -C $mover rev-parse HEAD 2>$null))[0]).Trim()
    $seen2 = $(if ($script:rhSeen.Count -ge 2) { [string]$script:rhSeen[1] } else { '' })
    T ($kMF + '  a rebase inside the lock that changes a manifest script re-rehearses before the push: two rehearsals, the second over the moved content, and it lands') `
      ($rQ2 -eq 0 -and $script:rhSeen.Count -eq 2 -and $seen2 -and (& $isAnc $q2 $moved2 $seen2) -and (& $tipOf) -eq $seen2) `
      ("rc={0} rehearsals={1} secondSawMove={2}" -f $rQ2, $script:rhSeen.Count, $(if ($seen2) { & $isAnc $q2 $moved2 $seen2 } else { $false }))

    # CLEAN TWIN: origin moves in that same window over a file no rehearsal covers. The rebase inside the lock keeps the
    # key, the recorded verdict is reused, and the push lands after ONE rehearsal carrying the moved commit.
    $q3 = & $newPusher 'q3'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('notes.txt')
    $rQ3 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $q3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck }
    $moved3 = ([string](@(& git -C $mover rev-parse HEAD 2>$null))[0]).Trim()
    $head3 = ([string](@(& git -C $q3 rev-parse HEAD 2>$null))[0]).Trim()
    T ($kCT + '  a rebase inside the lock over non-manifest commits reuses the verdict: one rehearsal, and the landed HEAD carries the moved commit') `
      ($rQ3 -eq 0 -and $script:rhSeen.Count -eq 1 -and (& $isAnc $q3 $moved3 $head3) -and (& $tipOf) -eq $head3) `
      ("rc={0} rehearsals={1} carriesMove={2} landed={3}" -f $rQ3, $script:rhSeen.Count, (& $isAnc $q3 $moved3 $head3), ((& $tipOf) -eq $head3))

    # THE REHEARSAL CAP (3), AT it and one PAST it, over in-lock hand-backs. At the bar: origin changes chain.ps1 at the
    # lock entry of rounds 1 and 2, and round 3 lands. Past it: at all three, and the push is refused rather than looping.
    $q4 = & $newPusher 'q4'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1', 'chain.ps1')
    $ledRoot4 = Join-Path $tmp 'led4'
    $rQ4 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $q4 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledRoot4 }
    T ($kMNF + '  at the 3-round cap (origin changes a manifest script in rounds 1 and 2) the push still lands, after exactly 3 rehearsals') `
      ($rQ4 -eq 0 -and $script:rhSeen.Count -eq 3) ("rc={0} rehearsals={1}" -f $rQ4, $script:rhSeen.Count)
    $q5 = & $newPusher 'q5'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1', 'chain.ps1', 'chain.ps1')
    $ledRoot5 = Join-Path $tmp 'led5'
    $rQ5 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $q5 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledRoot5 }
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

    # MUST FIRE: a push that hands the lock back ONCE and then lands. Round 1: origin changes chain.ps1 at the lock entry,
    # so the in-lock check does not cover the rebased content and the lock goes back. Round 2: origin moves again at the
    # lock entry, over a file no rehearsal covers, so the in-lock rebase keeps the key, the check says covered, and it lands.
    # THE WAITS ARE READ AT THEIR SOURCE: the lock-entry mover keeps each take's WaitedMs exactly as the lock reported it,
    # and the row's sum is checked against the takes rather than against itself.
    $hb = & $newPusher 'hb'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1', 'notes.txt')
    $ledHb = Join-Path $tmp 'ledhb'
    $rHb = Invoke-WithLockMover { Invoke-TcPushMain -Dir $hb -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledHb }
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
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $script:twoGateRuns = 0
    $twoGate = { param($d)
      $script:twoGateRuns++
      if ($script:twoGateRuns -ge 2) { Start-Sleep -Seconds 2; return [pscustomobject]@{ Ran = $true; Code = 1; Why = 'fixture: run-gates red in round 2' } }
      return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' }
    }
    $ledR2c = Join-Path $tmp 'ledr2c'
    $rR2c = Invoke-WithLockMover { Invoke-TcPushMain -Dir $r2c -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $twoGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledR2c }
    $r2cRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledR2c)
    $r2cRows = @($r2cRaw)
    $r2cRow = $(if ($r2cRows.Count) { $r2cRows[$r2cRows.Count - 1] } else { $null })
    T ($kMF + '  a round-2 refusal before the lock records lock_takes 1, phase catchup, rounds 2, outcome refused-gate-red and at least the 2 s of its round-2 gate in catchup_sec, beside state not-taken') `
      ($rR2c -eq 1 -and $script:twoGateRuns -eq 2 -and $r2cRows.Count -eq 1 -and [string]$r2cRow.outcome -ceq 'refused-gate-red' -and [int]$r2cRow.lock_takes -eq 1 -and `
        [string]$r2cRow.phase -ceq 'catchup' -and [int]$r2cRow.rounds -eq 2 -and [string]$r2cRow.state -ceq 'not-taken' -and [string]$r2cRow.inlock_check -ceq 'not-covered' -and [int]$r2cRow.catchup_sec -ge 2) `
      ("rc={0} gateRuns={1} rows={2} outcome={3} takes={4} phase={5} rounds={6} state={7} check={8} catchup={9}" -f $rR2c, $script:twoGateRuns, $r2cRows.Count, $(if ($r2cRow) { $r2cRow.outcome }), $(if ($r2cRow) { $r2cRow.lock_takes }), $(if ($r2cRow) { $r2cRow.phase }), $(if ($r2cRow) { $r2cRow.rounds }), $(if ($r2cRow) { $r2cRow.state }), $(if ($r2cRow) { $r2cRow.inlock_check }), $(if ($r2cRow) { $r2cRow.catchup_sec }))

    # ---- THE REVIEW OF W0.1R (2026-09-23): the catch-up sync, the check word and the row a throw leaves ----
    # $ckMoves is what the check pushes from the mover the moment it refuses to cover the rebased content, so the NEXT
    # round's own sync meets a move nothing else could have made.
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

    # MUST FIRE: a round-2 sync (after a hand-back) that REBASES. Round 1's lock entry moves chain.ps1, so the in-lock check
    # does not cover the rebased content, and while it says so origin moves again over a file nothing covers. Round 2's
    # fetch and rebase meet that move before the lock: rebase_phases must say inlock then CATCHUP, and preflight_sha must
    # still be the tip origin held when the push started, never the round-2 fetch.
    $cu = & $newPusher 'cu'
    $cuStartTip = & $tipOf
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $script:ckMoves = @([pscustomobject]@{ File = 'notes.txt'; Text = ('catch-up ' + [guid]::NewGuid().ToString('N')) })
    $ledCu = Join-Path $tmp 'ledcu'
    $rCu = Invoke-WithLockMover { Invoke-TcPushMain -Dir $cu -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $ckMover -LedgerRoot $ledCu }
    $cuMoveTip = ([string](@(& git -C $mover rev-parse HEAD 2>$null))[0]).Trim()
    $cuRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCu)
    $cuRows = @($cuRaw)
    $cuRow = $(if ($cuRows.Count) { $cuRows[$cuRows.Count - 1] } else { $null })
    T ($kMF + '  a round-2 sync that rebases is recorded as catchup (rebase_phases inlock,catchup), and preflight_sha stays the tip origin held at the start, not the round-2 fetch') `
      ($rCu -eq 0 -and $cuRows.Count -eq 1 -and [string]$cuRow.outcome -ceq 'landed-after-rebase' -and [int]$cuRow.rounds -eq 2 -and (@($cuRow.rebase_phases) -join ',') -ceq 'inlock,catchup' -and `
        [string]$cuRow.preflight_sha -ceq $cuStartTip -and [string]$cuRow.preflight_sha -cne $cuMoveTip -and $script:ckMoves.Count -eq 0) `
      ("rc={0} rows={1} outcome={2} rounds={3} phases={4} preflight={5} start={6} round2fetch={7} movesLeft={8}" -f $rCu, $cuRows.Count, $(if ($cuRow) { $cuRow.outcome }), $(if ($cuRow) { $cuRow.rounds }), $(if ($cuRow) { @($cuRow.rebase_phases) -join ',' }), $(if ($cuRow) { $cuRow.preflight_sha }), $cuStartTip, $cuMoveTip, $script:ckMoves.Count)

    # MUST FIRE: a round-2 sync that CONFLICTS. F.txt has ten lines; the branch edits line 10. Before the push starts
    # origin edits line 1 (X), so the pre-flight rebase is clean and preflight_sha is X. Round 1's lock entry moves
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
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $script:ckMoves = @([pscustomobject]@{ File = 'F.txt'; Text = (& $tenLines 'x1' 'theirs10') })
    $ledCc = Join-Path $tmp 'ledcc'
    $rCc = Invoke-WithLockMover { Invoke-TcPushMain -Dir $cc -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $ckMover -LedgerRoot $ledCc }
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

    # W2.2R step 4, MUST NOT FIRE: an in-lock check that DECIDED NOTHING (Code 3) twice no longer hands the lock back. It is
    # called exactly twice (once, then its one retry), and the push is attempted with inlock_check could-not-decide; the
    # hook's record check decides, as the day before. (Until W2.2R a Code 3 handed the lock back for a whole round.)
    $cn = & $newPusher 'cn'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $script:cnChecks = 0
    $cnCheck = { param($d, $h, $r) $script:cnChecks++; [pscustomobject]@{ Code = 3; Why = 'fixture: the verdict check printed no completion marker' } }
    $ledCn = Join-Path $tmp 'ledcn'
    $rCn = Invoke-WithLockMover { Invoke-TcPushMain -Dir $cn -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $cnCheck -LedgerRoot $ledCn }
    $cnRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCn)
    $cnRows = @($cnRaw)
    $cnRow = $(if ($cnRows.Count) { $cnRows[$cnRows.Count - 1] } else { $null })
    T ($kMNF + '  an in-lock check that exits 3 twice does not hand the lock back: called exactly twice, one lock take, and the push is attempted with inlock_check could-not-decide') `
      ($rCn -eq 0 -and $script:cnChecks -eq 2 -and $cnRows.Count -eq 1 -and [string]$cnRow.inlock_check -ceq 'could-not-decide' -and [int]$cnRow.lock_takes -eq 1 -and [int]$cnRow.rounds -eq 1 -and ([string]$cnRow.outcome).StartsWith('landed')) `
      ("rc={0} checks={1} rows={2} check={3} takes={4} rounds={5} outcome={6}" -f $rCn, $script:cnChecks, $cnRows.Count, $(if ($cnRow) { $cnRow.inlock_check }), $(if ($cnRow) { $cnRow.lock_takes }), $(if ($cnRow) { $cnRow.rounds }), $(if ($cnRow) { $cnRow.outcome }))
    # CLEAN TWIN: a check that exits 3 once and then 0 lands with inlock_check covered, on one take.
    $c30 = & $newPusher 'c30'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('notes.txt')
    $script:c30Checks = 0
    $c30Check = { param($d, $h, $r) $script:c30Checks++; if ($script:c30Checks -eq 1) { return [pscustomobject]@{ Code = 3; Why = 'fixture: crashed once' } }; return [pscustomobject]@{ Code = 0; Why = 'covered' } }
    $ledC30 = Join-Path $tmp 'ledc30'
    $rC30 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $c30 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $c30Check -LedgerRoot $ledC30 }
    $c30Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledC30)
    $c30Rows = @($c30Raw)
    $c30Row = $(if ($c30Rows.Count) { $c30Rows[0] } else { $null })
    T ($kCT + '  a check that exits 3 once and then 0 lands with inlock_check covered, on one lock take, after exactly two checks') `
      ($rC30 -eq 0 -and $script:c30Checks -eq 2 -and $c30Rows.Count -eq 1 -and [string]$c30Row.inlock_check -ceq 'covered' -and [int]$c30Row.lock_takes -eq 1 -and ([string]$c30Row.outcome).StartsWith('landed')) `
      ("rc={0} checks={1} rows={2} check={3} takes={4} outcome={5}" -f $rC30, $script:c30Checks, $c30Rows.Count, $(if ($c30Row) { $c30Row.inlock_check }), $(if ($c30Row) { $c30Row.lock_takes }), $(if ($c30Row) { $c30Row.outcome }))

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
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $throwCheck = { param($d, $h, $r) throw 'fixture: the in-lock check threw' }
    $ledTi = Join-Path $tmp 'ledti'
    $tiCaught = ''
    try { $null = Invoke-WithLockMover { Invoke-StUnderStop { Invoke-TcPushMain -Dir $ti -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $throwCheck -LedgerRoot $ledTi } } }
    catch { $tiCaught = [string]$_.Exception.Message }
    $tiRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTi)
    $tiRows = @($tiRaw)
    $tiRow = $(if ($tiRows.Count) { $tiRows[0] } else { $null })
    $tiFree = Enter-TcPushLock -Prefix $prefix -QueueRoot $qroot -WaitSec 5 -PollMs 50 -NoInherit
    T ($kCT + '  a throw inside the lock still writes exactly one row (outcome unknown, phase inlock), reaches the caller, and hands the lock back') `
      ($tiCaught -match 'the in-lock check threw' -and $tiRows.Count -eq 1 -and [string]$tiRow.outcome -ceq 'unknown' -and [string]$tiRow.phase -ceq 'inlock' -and $tiFree.Held) `
      ("caught={0} rows={1} outcome={2} phase={3} lockFree={4}" -f $tiCaught, $tiRows.Count, $(if ($tiRow) { $tiRow.outcome }), $(if ($tiRow) { $tiRow.phase }), $tiFree.Held)
    Exit-TcPushLock $tiFree

    # ---- W2.2R: THE CATCH-UP ROUND, OUTSIDE THE LOCK (2026-09-23) ----
    # Founding case: origin moves WHILE the legs run, and until W2.2R that move was found only by the fetch inside the
    # lock, where a rebase over a manifest script handed the lock back for a whole round. Every move below is made during
    # the legs, by a gate or rehearsal stub, so the catch-up fetch after them is what meets it.
    # CLEAN TWIN: origin moves once during round 1's legs over a non-chain file. It settles in round 2 outside the lock:
    # each stub is called twice, the rehearsal stub reports a reused verdict, and the in-lock sync rebases nothing.
    $ct1 = & $newPusher 'ct1'
    $script:rhSeen.Clear(); $script:rhMoves = @('notes.txt'); $script:rhVerdicts = @{}
    $script:ct1Gates = 0
    $ct1Gate = { param($d) $script:ct1Gates++; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledCt1 = Join-Path $tmp 'ledct1'
    $rCt1 = Invoke-TcPushMain -Dir $ct1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $ct1Gate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledCt1
    $ct1Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCt1)
    $ct1Rows = @($ct1Raw)
    $ct1Row = $(if ($ct1Rows.Count) { $ct1Rows[0] } else { $null })
    T ($kCT + '  a move during round 1''s legs over a non-chain file settles in round 2 outside the lock: both stubs called twice, the second rehearsal a reuse, the in-lock sync rebases nothing, and it lands on one take') `
      ($rCt1 -eq 0 -and $script:ct1Gates -eq 2 -and $script:rhSeen.Count -eq 2 -and $ct1Rows.Count -eq 1 -and [int]$ct1Row.rounds -eq 2 -and [int]$ct1Row.rehearsed -eq 1 -and [int]$ct1Row.catchups -eq 1 -and `
        [int]$ct1Row.lock_takes -eq 1 -and (@($ct1Row.rebase_phases) -join ',') -ceq 'catchup' -and [string]$ct1Row.inlock_check -ceq 'not-run' -and [string]$ct1Row.outcome -ceq 'landed-after-rebase') `
      ("rc={0} gates={1} rehearsalCalls={2} rows={3} rounds={4} rehearsed={5} catchups={6} takes={7} phases={8} check={9} outcome={10}" -f $rCt1, $script:ct1Gates, $script:rhSeen.Count, $ct1Rows.Count, $(if ($ct1Row) { $ct1Row.rounds }), $(if ($ct1Row) { $ct1Row.rehearsed }), $(if ($ct1Row) { $ct1Row.catchups }), $(if ($ct1Row) { $ct1Row.lock_takes }), $(if ($ct1Row) { @($ct1Row.rebase_phases) -join ',' }), $(if ($ct1Row) { $ct1Row.inlock_check }), $(if ($ct1Row) { $ct1Row.outcome }))

    # MUST FIRE, AT THE BAR (3 catch-up rounds): a gate stub that moves origin (non-chain) on EVERY call. Round 1 and exactly
    # 3 catch-up rounds run their legs (4 gate calls); the 4th catch-up never starts; the push reaches the lock, whose sync
    # takes the last move, and lands. One past the bar would be a 5th gate call.
    $cb = & $newPusher 'cb'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}
    $script:cbGates = 0
    $cbGate = { param($d) $script:cbGates++; & $moveOrigin 'notes.txt'; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledCb = Join-Path $tmp 'ledcb'
    # At hand-back cap 0 (Invoke-WithLockMover's default), so the lock rebases the last move inside, as this bar is about the catch-up.
    $cbCap = Invoke-StCapture { Invoke-WithLockMover { Invoke-TcPushMain -Dir $cb -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $cbGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledCb } }
    $cbRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCb)
    $cbRows = @($cbRaw)
    $cbRow = $(if ($cbRows.Count) { $cbRows[0] } else { $null })
    T ($kMF + '  a remote that moves after every round''s legs stops after exactly 3 catch-up rounds (the bar): 4 leg sets, catchups 3, the 4th catch-up never starts, and the push reaches the lock and lands') `
      ($cbCap.Result -eq 0 -and $script:cbGates -eq 4 -and $cbRows.Count -eq 1 -and [int]$cbRow.rounds -eq 4 -and [int]$cbRow.catchups -eq 3 -and [int]$cbRow.catchup_fetches -eq 3 -and `
        (@($cbRow.rebase_phases) -join ',') -ceq 'catchup,catchup,catchup,inlock' -and [int]$cbRow.lock_takes -eq 1 -and $cbCap.Text -match 'did not settle in 3 rounds') `
      ("rc={0} gates={1} rows={2} rounds={3} catchups={4} fetches={5} phases={6} takes={7}" -f $cbCap.Result, $script:cbGates, $cbRows.Count, $(if ($cbRow) { $cbRow.rounds }), $(if ($cbRow) { $cbRow.catchups }), $(if ($cbRow) { $cbRow.catchup_fetches }), $(if ($cbRow) { @($cbRow.rebase_phases) -join ',' }), $(if ($cbRow) { $cbRow.lock_takes }))

    # MUST FIRE: a conflict the catch-up fetch finds is refused with phase catchup, before the lock: lock_takes 0, and a probe
    # from ANOTHER process finds the lock free the moment the push returns.
    $cq = New-Clone 'cq'
    [IO.File]::WriteAllText((Join-Path $cq 'clashQ.txt'), 'mine')
    $null = & git -C $cq add -- clashQ.txt 2>$null; $null = & git -C $cq commit -q -m 'cq mine' 2>$null
    $cqGate = { param($d) & $moveOriginText 'clashQ.txt' 'theirs'; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledCq = Join-Path $tmp 'ledcq'
    $rCq = Invoke-TcPushMain -Dir $cq -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $cqGate -RehearsalRunner $rhGreen -LedgerRoot $ledCq
    $cqProbe = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -Name ($prefix + '0'))
    $cqRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCq)
    $cqRows = @($cqRaw)
    $cqRow = $(if ($cqRows.Count) { $cqRows[0] } else { $null })
    T ($kMF + '  a conflict found by the catch-up fetch is refused with phase catchup before the lock: lock_takes 0, the conflicted file named, and another process finds the lock free') `
      ($rCq -eq 1 -and $cqRows.Count -eq 1 -and [string]$cqRow.outcome -ceq 'refused-rebase-conflict' -and [string]$cqRow.phase -ceq 'catchup' -and [int]$cqRow.lock_takes -eq 0 -and `
        (@($cqRow.conflict_files) -join ',') -ceq 'clashQ.txt' -and @($cqProbe | Where-Object { "$_".Trim() -eq 'FREE' }).Count -eq 1) `
      ("rc={0} rows={1} outcome={2} phase={3} takes={4} files={5} probe={6}" -f $rCq, $cqRows.Count, $(if ($cqRow) { $cqRow.outcome }), $(if ($cqRow) { $cqRow.phase }), $(if ($cqRow) { $cqRow.lock_takes }), $(if ($cqRow) { @($cqRow.conflict_files) -join ',' }), ($cqProbe -join ','))

    # MUST FIRE: a runner stub exiting 1 in round 2 (a catch-up round) refuses refused-gate-red, phase catchup.
    $g2 = & $newPusher 'g2'
    $script:g2Gates = 0
    $g2Gate = { param($d) $script:g2Gates++; if ($script:g2Gates -eq 1) { & $moveOrigin 'notes.txt'; return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }; return [pscustomobject]@{ Ran = $true; Code = 1; Why = 'fixture: red in the catch-up round' } }
    $ledG2 = Join-Path $tmp 'ledg2'
    $rG2 = Invoke-TcPushMain -Dir $g2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $g2Gate -RehearsalRunner $rhGreen -LedgerRoot $ledG2
    $g2Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledG2)
    $g2Rows = @($g2Raw)
    $g2Row = $(if ($g2Rows.Count) { $g2Rows[0] } else { $null })
    T ($kMF + '  a runner stub exiting 1 in the catch-up round refuses refused-gate-red with phase catchup, and the lock is never taken') `
      ($rG2 -eq 1 -and $script:g2Gates -eq 2 -and $g2Rows.Count -eq 1 -and [string]$g2Row.outcome -ceq 'refused-gate-red' -and [string]$g2Row.phase -ceq 'catchup' -and [int]$g2Row.lock_takes -eq 0) `
      ("rc={0} gates={1} rows={2} outcome={3} phase={4} takes={5}" -f $rG2, $script:g2Gates, $g2Rows.Count, $(if ($g2Row) { $g2Row.outcome }), $(if ($g2Row) { $g2Row.phase }), $(if ($g2Row) { $g2Row.lock_takes }))

    # MUST FIRE (M17's case): three non-chain catch-up rounds do NOT spend the rehearsal budget. The rehearsal moves notes.txt
    # during rounds 1 to 3 (round 1 rehearses; rounds 2 to 4 reuse), so the catch-up cap is reached, and then the lock
    # entry moves chain.ps1: the in-lock check does not cover it, and because only ONE round rehearsed, the push still gets
    # its hand-back round and lands. Counting every round against the budget would refuse it as churn.
    $bud = & $newPusher 'bud'
    $script:rhSeen.Clear(); $script:rhMoves = @('notes.txt', 'notes.txt', 'notes.txt'); $script:rhVerdicts = @{}; $script:lockMoves = @('chain.ps1')
    $ledBud = Join-Path $tmp 'ledbud'
    $rBud = Invoke-WithLockMover { Invoke-TcPushMain -Dir $bud -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledBud }
    $budRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledBud)
    $budRows = @($budRaw)
    $budRow = $(if ($budRows.Count) { $budRows[0] } else { $null })
    T ($kMF + '  three non-chain catch-up rounds do not spend the rehearsal budget: a chain move found in the lock after them still gets its hand-back round, and the push lands with rehearsed 2') `
      ($rBud -eq 0 -and $budRows.Count -eq 1 -and [int]$budRow.catchups -eq 3 -and [int]$budRow.rehearsed -eq 2 -and [int]$budRow.lock_takes -eq 2 -and [int]$budRow.rounds -eq 5 -and ([string]$budRow.outcome).StartsWith('landed')) `
      ("rc={0} rows={1} catchups={2} rehearsed={3} takes={4} rounds={5} outcome={6}" -f $rBud, $budRows.Count, $(if ($budRow) { $budRow.catchups }), $(if ($budRow) { $budRow.rehearsed }), $(if ($budRow) { $budRow.lock_takes }), $(if ($budRow) { $budRow.rounds }), $(if ($budRow) { $budRow.outcome }))

    # MUST NOT FIRE: a stub exiting 3 in round 2 does not refuse. The push reaches the lock with degraded naming the leg,
    # and no third leg set runs.
    $g3 = & $newPusher 'g3'
    $script:g3Gates = 0
    $g3Gate = { param($d) $script:g3Gates++; if ($script:g3Gates -eq 1) { & $moveOrigin 'notes.txt'; return [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }; return [pscustomobject]@{ Ran = $true; Code = 3; Why = 'fixture: no gate worker slot' } }
    $ledG3 = Join-Path $tmp 'ledg3'
    $rG3 = Invoke-TcPushMain -Dir $g3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $g3Gate -RehearsalRunner $rhGreen -LedgerRoot $ledG3
    $g3Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledG3)
    $g3Rows = @($g3Raw)
    $g3Row = $(if ($g3Rows.Count) { $g3Rows[0] } else { $null })
    T ($kMNF + '  a stub exiting 3 in the catch-up round does not refuse: two leg sets, degraded names run-gates, and the push reaches the lock and lands') `
      ($rG3 -eq 0 -and $script:g3Gates -eq 2 -and $g3Rows.Count -eq 1 -and [string]$g3Row.degraded -ceq 'run-gates' -and [int]$g3Row.lock_takes -eq 1 -and [int]$g3Row.rounds -eq 2 -and ([string]$g3Row.outcome).StartsWith('landed')) `
      ("rc={0} gates={1} rows={2} degraded={3} takes={4} rounds={5} outcome={6}" -f $rG3, $script:g3Gates, $g3Rows.Count, $(if ($g3Row) { $g3Row.degraded }), $(if ($g3Row) { $g3Row.lock_takes }), $(if ($g3Row) { $g3Row.rounds }), $(if ($g3Row) { $g3Row.outcome }))

    # MUST NOT FIRE: a failed catch-up fetch does not refuse. The rehearsal stub points the clone's remote nowhere, so the
    # catch-up fetch fails; the lock-entry mover puts it back, and the fetch inside the lock lands the push.
    $cf = & $newPusher 'cf'
    $cfBreak = { param($d) $null = & git -C $d remote set-url origin (Join-Path $tmp 'no-such-remote') 2>$null; [pscustomobject]@{ Code = 0; Why = 'fixture: rehearsed-pass' } }
    $script:lockMoves = @({ $null = & git -C $cf remote set-url origin $origin 2>$null })
    $ledCf = Join-Path $tmp 'ledcf'
    $rCf = Invoke-WithLockMover { Invoke-TcPushMain -Dir $cf -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $cfBreak -LedgerRoot $ledCf }
    $cfRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCf)
    $cfRows = @($cfRaw)
    $cfRow = $(if ($cfRows.Count) { $cfRows[0] } else { $null })
    T ($kMNF + '  a failed catch-up fetch does not refuse: the row says degraded fetch, one catch-up fetch was made, and the push lands through the fetch inside the lock') `
      ($rCf -eq 0 -and $cfRows.Count -eq 1 -and [string]$cfRow.degraded -ceq 'fetch' -and [int]$cfRow.catchup_fetches -eq 1 -and ([string]$cfRow.outcome).StartsWith('landed')) `
      ("rc={0} rows={1} degraded={2} fetches={3} outcome={4}" -f $rCf, $cfRows.Count, $(if ($cfRow) { $cfRow.degraded }), $(if ($cfRow) { $cfRow.catchup_fetches }), $(if ($cfRow) { $cfRow.outcome }))

    # MUST NOT FIRE: a remote that never moves gives exactly ONE catch-up fetch and no second leg run.
    $nm = & $newPusher 'nm'
    $script:nmGates = 0
    $nmGate = { param($d) $script:nmGates++; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledNm = Join-Path $tmp 'lednm'
    $rNm = Invoke-TcPushMain -Dir $nm -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $nmGate -RehearsalRunner $rhGreen -LedgerRoot $ledNm
    $nmRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledNm)
    $nmRows = @($nmRaw)
    $nmRow = $(if ($nmRows.Count) { $nmRows[0] } else { $null })
    T ($kMNF + '  a remote that never moves gives exactly one catch-up fetch, no catch-up round and no second leg run') `
      ($rNm -eq 0 -and $script:nmGates -eq 1 -and $nmRows.Count -eq 1 -and [int]$nmRow.catchup_fetches -eq 1 -and [int]$nmRow.catchups -eq 0 -and [int]$nmRow.rounds -eq 1) `
      ("rc={0} gates={1} rows={2} fetches={3} catchups={4} rounds={5}" -f $rNm, $script:nmGates, $nmRows.Count, $(if ($nmRow) { $nmRow.catchup_fetches }), $(if ($nmRow) { $nmRow.catchups }), $(if ($nmRow) { $nmRow.rounds }))

    # MUST FIRE (D11a, the catch-up road to the cap): the rehearsal moves chain.ps1 in rounds 1, 2 and 3, each a new verdict,
    # and the third move is met by a catch-up. With 3 rehearsals spent, the check says the rebased content is not covered,
    # so no fourth rehearsal starts: refused-rehearsal-churn with phase catchup, the lock never taken.
    $cc3 = & $newPusher 'cc3'
    $script:rhSeen.Clear(); $script:rhMoves = @('chain.ps1', 'chain.ps1', 'chain.ps1'); $script:rhVerdicts = @{}
    $ledCc3 = Join-Path $tmp 'ledcc3'
    $cc3Cap = Invoke-StCapture { Invoke-TcPushMain -Dir $cc3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledCc3 }
    $cc3Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCc3)
    $cc3Rows = @($cc3Raw)
    $cc3Row = $(if ($cc3Rows.Count) { $cc3Rows[0] } else { $null })
    T ($kMF + '  after 3 rehearsals a catch-up that moves the key again is refused-rehearsal-churn before the lock (phase catchup, no fourth rehearsal, lock_takes 0), naming a manifest move') `
      ($cc3Cap.Result -eq 1 -and $script:rhSeen.Count -eq 3 -and $cc3Rows.Count -eq 1 -and [string]$cc3Row.outcome -ceq 'refused-rehearsal-churn' -and [string]$cc3Row.phase -ceq 'catchup' -and [int]$cc3Row.lock_takes -eq 0 -and [int]$cc3Row.rehearsed -eq 3 -and $cc3Cap.Text -match 'a manifest move') `
      ("rc={0} rehearsals={1} rows={2} outcome={3} phase={4} takes={5} rehearsed={6}" -f $cc3Cap.Result, $script:rhSeen.Count, $cc3Rows.Count, $(if ($cc3Row) { $cc3Row.outcome }), $(if ($cc3Row) { $cc3Row.phase }), $(if ($cc3Row) { $cc3Row.lock_takes }), $(if ($cc3Row) { $cc3Row.rehearsed }))

    # ---- W9.4: LOCK ONLY THE SWAP (2026-09-23) ----
    # Founding figure (the review's model, from the plan's holds): a rebased in-lock hold of about 128 s against a 25 s
    # replay, lock utilisation 0.64 at 18 landings an hour. Every move below is made by the lock-entry mover immediately
    # before a real take, at the PRODUCTION hand-back cap (-LmCap -1), with HEAD recorded at every take and release.
    # MUST FIRE: a remote that moves just before the in-lock fetch hands the lock back ONCE. No rebase ran while the lock
    # was held (HEAD at each release equals HEAD at that take), the rebase ran outside (rebase_phases handback), and it lands.
    $hk1 = & $newPusher 'hk1'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('notes.txt')
    $ledHk1 = Join-Path $tmp 'ledhbk1'
    $rHk1 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $hk1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledHk1 } -LmCap -1 -LmDir $hk1
    $hk1Heads = $script:lockHeads.ToArray()
    $hk1Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledHk1)
    $hk1Rows = @($hk1Raw)
    $hk1Row = $(if ($hk1Rows.Count) { $hk1Rows[0] } else { $null })
    $hk1Held = ($hk1Heads.Count -eq 4 -and ($hk1Heads[0] -replace '^take ', '') -ceq ($hk1Heads[1] -replace '^release ', ''))
    T ($kMF + '  a remote that moves just before the in-lock fetch hands the lock back once: HEAD at the release equals HEAD at the take, the rebase ran outside (handback), hand_backs 1, lock_takes 2, and it lands') `
      ($rHk1 -eq 0 -and $hk1Held -and $hk1Rows.Count -eq 1 -and [int]$hk1Row.hand_backs -eq 1 -and [int]$hk1Row.lock_takes -eq 2 -and (@($hk1Row.rebase_phases) -join ',') -ceq 'handback' -and ([string]$hk1Row.outcome).StartsWith('landed') -and $hk1Row.handback_sec -is [int]) `
      ("rc={0} heads={1} rows={2} handBacks={3} takes={4} phases={5} outcome={6} hbSec={7}" -f $rHk1, ($hk1Heads -join '|'), $hk1Rows.Count, $(if ($hk1Row) { $hk1Row.hand_backs }), $(if ($hk1Row) { $hk1Row.lock_takes }), $(if ($hk1Row) { @($hk1Row.rebase_phases) -join ',' }), $(if ($hk1Row) { $hk1Row.outcome }), $(if ($hk1Row) { $hk1Row.handback_sec }))

    # MUST FIRE, AT THE BAR (3 hand-backs): a remote that moves before EVERY in-lock fetch hands back exactly 3 times; the
    # 4th take rebases INSIDE the lock (rebase_phases ends inlock) and the push lands. Never refused.
    # CLEAN TWIN: after the cap's in-lock rebase, the sibling's in-lock verdict check still runs.
    $hk3 = & $newPusher 'hk3'
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @('notes.txt', 'notes.txt', 'notes.txt', 'notes.txt')
    $ledHk3 = Join-Path $tmp 'ledhbk3'
    $rHk3 = Invoke-WithLockMover { Invoke-TcPushMain -Dir $hk3 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhModel -RehearsalCheck $rhCheck -LedgerRoot $ledHk3 } -LmCap -1 -LmDir $hk3
    $hk3Heads = $script:lockHeads.ToArray()
    $hk3Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledHk3)
    $hk3Rows = @($hk3Raw)
    $hk3Row = $(if ($hk3Rows.Count) { $hk3Rows[0] } else { $null })
    $hk3HeldSame = $true
    for ($hi = 0; $hi -lt 6 -and ($hi + 1) -lt $hk3Heads.Count; $hi += 2) { if (($hk3Heads[$hi] -replace '^take ', '') -cne ($hk3Heads[$hi + 1] -replace '^release ', '')) { $hk3HeldSame = $false } }
    T ($kMF + '  a remote that moves before every in-lock fetch hands back exactly 3 times (the bar), with no rebase under any of those takes; the 4th take rebases inside the lock, rebase_phases ends inlock, and it lands') `
      ($rHk3 -eq 0 -and $hk3Rows.Count -eq 1 -and [int]$hk3Row.hand_backs -eq 3 -and [int]$hk3Row.lock_takes -eq 4 -and $hk3HeldSame -and $hk3Heads.Count -eq 8 -and `
        (@($hk3Row.rebase_phases) -join ',') -ceq 'handback,handback,handback,inlock' -and ([string]$hk3Row.outcome).StartsWith('landed')) `
      ("rc={0} rows={1} handBacks={2} takes={3} heldSame={4} heads={5} phases={6} outcome={7}" -f $rHk3, $hk3Rows.Count, $(if ($hk3Row) { $hk3Row.hand_backs }), $(if ($hk3Row) { $hk3Row.lock_takes }), $hk3HeldSame, $hk3Heads.Count, $(if ($hk3Row) { @($hk3Row.rebase_phases) -join ',' }), $(if ($hk3Row) { $hk3Row.outcome }))
    T ($kCT + '  after the cap''s in-lock rebase the in-lock verdict check still runs (inlock_check covered, not not-run)') `
      ($null -ne $hk3Row -and [string]$hk3Row.inlock_check -ceq 'covered') ("check={0}" -f $(if ($hk3Row) { $hk3Row.inlock_check }))

    # MUST FIRE: a hand-back rebase that CONFLICTS refuses with phase catchup, and at the moment it conflicts (the abort
    # seam runs the probe) another process finds the push lock FREE: the rebase ran outside it.
    $hkc = New-Clone 'hkc'
    [IO.File]::WriteAllText((Join-Path $hkc 'clashH.txt'), 'mine')
    $null = & git -C $hkc add -- clashH.txt 2>$null; $null = & git -C $hkc commit -q -m 'hkc mine' 2>$null
    $script:rhSeen.Clear(); $script:rhMoves = @(); $script:rhVerdicts = @{}; $script:lockMoves = @({ & $moveOriginText 'clashH.txt' 'theirs' })
    $script:hkcProbe = ''
    $script:TcPmRebaseAbort = { param($d) $script:hkcProbe = (@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -Name ($prefix + '0')) -join ','); Invoke-TcGit -Dir $d -Arguments @('rebase', '--abort') }
    $ledHkc = Join-Path $tmp 'ledhbkc'
    try {
      $rHkc = Invoke-WithLockMover { Invoke-TcPushMain -Dir $hkc -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhGreen -LedgerRoot $ledHkc } -LmCap -1
    } finally { $script:TcPmRebaseAbort = { param($d) Invoke-TcGit -Dir $d -Arguments @('rebase', '--abort') } }
    $hkcRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledHkc)
    $hkcRows = @($hkcRaw)
    $hkcRow = $(if ($hkcRows.Count) { $hkcRows[0] } else { $null })
    T ($kMF + '  a hand-back rebase that conflicts refuses with phase catchup (rebase_phases handback), and another process found the lock free at the moment it conflicted') `
      ($rHkc -eq 1 -and $hkcRows.Count -eq 1 -and [string]$hkcRow.outcome -ceq 'refused-rebase-conflict' -and [string]$hkcRow.phase -ceq 'catchup' -and (@($hkcRow.rebase_phases) -join ',') -ceq 'handback' -and `
        [int]$hkcRow.hand_backs -eq 1 -and [int]$hkcRow.lock_takes -eq 1 -and $script:hkcProbe -ceq 'FREE') `
      ("rc={0} rows={1} outcome={2} phase={3} phases={4} handBacks={5} takes={6} probe={7}" -f $rHkc, $hkcRows.Count, $(if ($hkcRow) { $hkcRow.outcome }), $(if ($hkcRow) { $hkcRow.phase }), $(if ($hkcRow) { @($hkcRow.rebase_phases) -join ',' }), $(if ($hkcRow) { $hkcRow.hand_backs }), $(if ($hkcRow) { $hkcRow.lock_takes }), $script:hkcProbe)

    # MUST NOT FIRE: an origin that has not moved at the in-lock fetch gives hand_backs 0 and one take (the unmoving
    # remote of the catch-up case above, read for W9.4's fields).
    T ($kMNF + '  an unmoved origin at the in-lock fetch gives hand_backs 0, handback_sec 0 and one lock take') `
      ($null -ne $nmRow -and [int]$nmRow.hand_backs -eq 0 -and [int]$nmRow.handback_sec -eq 0 -and [int]$nmRow.lock_takes -eq 1) `
      ("handBacks={0} hbSec={1} takes={2}" -f $(if ($nmRow) { $nmRow.hand_backs }), $(if ($nmRow) { $nmRow.handback_sec }), $(if ($nmRow) { $nmRow.lock_takes }))

    # ---- W3.2 WITH W3.4a STEP 3: THE PRE-FLIGHT'S BACKLOG AND INBOX COUNTS (2026-09-23), warn only ----
    # Founding figure: design/BACKLOG-course-findings.md overlapped in 12 of 19 recent rebase conflicts. The fixture origin
    # carries a backlog with one item, a findings file in the inbox and one UPDATE file; each clone makes one kind of
    # commit and runs a -DryRun, so origin never moves under the next. The validator is this repo's real one, pointed at
    # the clone's own backlog.
    $bkRel = 'design/BACKLOG-course-' + 'findings.md'
    $ibRel = 'design/backlog-inbox/lane-x-2026-09-23.md'
    $upRel = 'design/backlog-inbox/updates/lane-u-2026-09-23-100000.md'
    $null = & git -C $mover pull -q --rebase origin main 2>$null
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $mover 'design\backlog-inbox\updates')
    [IO.File]::WriteAllText((Join-Path $mover $bkRel), "# Backlog`n`n### I1 - a fixture item ``OPEN`` ``queue-1```n`nbody one`n")
    [IO.File]::WriteAllText((Join-Path $mover $ibRel), "# a lane's findings`n`nnothing yet`n")
    [IO.File]::WriteAllText((Join-Path $mover $upRel), "## UPDATE I1`n``DONE`` ``queue-1```nfinished`n")
    $null = & git -C $mover add -- $bkRel $ibRel $upRel 2>$null; $null = & git -C $mover commit -q -m 'backlog fixture' 2>$null
    $null = & git -C $mover push -q origin HEAD:main 2>$null
    $script:TcPmInboxValidatorScript = Join-Path $repo ('ops\merge-backlog-' + 'inbox.ps1')
    $script:bkRun = 0
    function Invoke-StBacklogCase([string]$Name, [scriptblock]$Change) {
      $script:bkRun++
      $bd = New-Clone $Name
      & $Change $bd
      $null = & git -C $bd commit -q -m ($Name + ' change') 2>$null
      $root = Join-Path $tmp ('ledbk' + $script:bkRun)
      $cap = Invoke-StCapture { Invoke-TcPushMain -Dir $bd -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $rhGreen -LedgerRoot $root }
      $raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $root)
      $rows = @($raw)
      return [pscustomobject]@{ Rc = $cap.Result; Text = $cap.Text; Row = $(if ($rows.Count) { $rows[0] } else { $null }); Rows = $rows.Count }
    }
    $editBacklog = { param($d) Add-Content -LiteralPath (Join-Path $d $bkRel) -Value 'a direct edit' -Encoding ascii; $null = & git -C $d add -- $bkRel 2>$null }
    $warnBk = 'WARN - 1 commit\(s\) here edit design/BACKLOG-course-findings\.md directly'
    try {
      $b1 = Invoke-StBacklogCase 'bk1' $editBacklog
      T ($kMF + '  a commit that edits the backlog and touches no inbox file warns, with backlog_direct 1, and the push is not refused') `
        ($b1.Rc -eq 0 -and $b1.Rows -eq 1 -and [int]$b1.Row.backlog_direct -eq 1 -and $b1.Text -match $warnBk) ("rc={0} rows={1} direct={2} warned={3}" -f $b1.Rc, $b1.Rows, $(if ($b1.Row) { $b1.Row.backlog_direct }), ($b1.Text -match $warnBk))
      $b2 = Invoke-StBacklogCase 'bk2' { param($d) & $editBacklog $d; $null = & git -C $d rm -q -- $ibRel 2>$null }
      T ($kMNF + '  a commit that edits the backlog and deletes an inbox file (a merge) does not warn: backlog_direct 0') `
        ($b2.Rc -eq 0 -and $null -ne $b2.Row -and [int]$b2.Row.backlog_direct -eq 0 -and $b2.Text -notmatch 'edit design/BACKLOG') ("rc={0} direct={1}" -f $b2.Rc, $(if ($b2.Row) { $b2.Row.backlog_direct }))
      $b3 = Invoke-StBacklogCase 'bk3' { param($d) & $editBacklog $d; $null = New-Item -ItemType Directory -Force (Join-Path $d 'design\backlog-inbox\quarantine'); $null = & git -C $d mv -- $ibRel 'design/backlog-inbox/quarantine/lane-x-2026-09-23.md' 2>$null }
      T ($kMNF + '  a commit that edits the backlog and moves an inbox file into quarantine/ (a merge) does not warn: backlog_direct 0') `
        ($b3.Rc -eq 0 -and $null -ne $b3.Row -and [int]$b3.Row.backlog_direct -eq 0 -and $b3.Text -notmatch 'edit design/BACKLOG') ("rc={0} direct={1}" -f $b3.Rc, $(if ($b3.Row) { $b3.Row.backlog_direct }))
      $b4 = Invoke-StBacklogCase 'bk4' { param($d) [IO.File]::WriteAllText((Join-Path $d 'bk4.txt'), 'x'); $null = & git -C $d add -- bk4.txt 2>$null }
      T ($kMNF + '  a branch that does not touch the backlog does not warn: backlog_direct 0, inbox_invalid 0, inbox_updates_modified 0') `
        ($b4.Rc -eq 0 -and $null -ne $b4.Row -and [int]$b4.Row.backlog_direct -eq 0 -and [int]$b4.Row.inbox_invalid -eq 0 -and [int]$b4.Row.inbox_updates_modified -eq 0 -and $b4.Text -notmatch 'WARN') `
        ("rc={0} direct={1} invalid={2} modified={3}" -f $b4.Rc, $(if ($b4.Row) { $b4.Row.backlog_direct }), $(if ($b4.Row) { $b4.Row.inbox_invalid }), $(if ($b4.Row) { $b4.Row.inbox_updates_modified }))
      $b5 = Invoke-StBacklogCase 'bk5' { param($d) $f = Join-Path $d 'design\backlog-inbox\updates\lane-n-2026-09-23-110000.md'; [IO.File]::WriteAllText($f, "## UPDATE I999`n``DONE`` ``queue-1```nprogress on an item the backlog does not hold`n"); $null = & git -C $d add -- 'design/backlog-inbox/updates/lane-n-2026-09-23-110000.md' 2>$null }
      T ($kMF + '  an added UPDATE file naming a missing id warns that the merge would quarantine it, with inbox_invalid 1, and the push is not refused') `
        ($b5.Rc -eq 0 -and $null -ne $b5.Row -and [int]$b5.Row.inbox_invalid -eq 1 -and $b5.Text -match 'lane-n-2026-09-23-110000\.md would be QUARANTINED') ("rc={0} invalid={1}" -f $b5.Rc, $(if ($b5.Row) { $b5.Row.inbox_invalid }))
      T ($kMNF + '  (W3.4a step 3) a commit that ADDS a new updates/ file does not warn as a modification: inbox_updates_modified 0') `
        ($b5.Rc -eq 0 -and $null -ne $b5.Row -and [int]$b5.Row.inbox_updates_modified -eq 0 -and $b5.Text -notmatch 'MODIFY an existing file') ("modified={0}" -f $(if ($b5.Row) { $b5.Row.inbox_updates_modified }))
      $b6 = Invoke-StBacklogCase 'bk6' { param($d) Add-Content -LiteralPath (Join-Path $d $upRel) -Value 'more on the same day file' -Encoding ascii; $null = & git -C $d add -- $upRel 2>$null }
      T ($kMF + '  (W3.4a step 3) a commit that MODIFIES an existing updates/ file warns with a count of 1') `
        ($b6.Rc -eq 0 -and $null -ne $b6.Row -and [int]$b6.Row.inbox_updates_modified -eq 1 -and $b6.Text -match 'WARN - 1 commit\(s\) here MODIFY an existing file under design/backlog-inbox/updates/') ("rc={0} modified={1}" -f $b6.Rc, $(if ($b6.Row) { $b6.Row.inbox_updates_modified }))
    } finally { $script:TcPmInboxValidatorScript = '' }

    # ---- W4.1 STEP 7: A RE-READ ADDED AS A DOC LINE WARNS (2026-09-23), warn only ----
    # Founding case: row 40 of the case list conflicted on re-read lines in one MEASURE doc; the ledger row is the road
    # that union-merges. MUST FIRE: a commit adding a "Re-read at" line to a design doc warns, reread_doc_lines 1.
    $rrDoc = 'design/MEASURE-fixture-2026-09-23.md'
    $rrLine = 'Re-read at harness blob ' + ('a' * 40) + ' (ops/x.ps1): the conclusion holds'
    $rr1 = Invoke-StBacklogCase 'rr1' { param($d) $null = New-Item -ItemType Directory -Force (Join-Path $d 'design'); [IO.File]::WriteAllText((Join-Path $d $rrDoc), ("# A measurement`n`n" + $rrLine + "`n")); $null = & git -C $d add -- $rrDoc 2>$null }
    T ($kMF + '  a commit that adds a Re-read at line to a design doc warns to use ops\add-reread.ps1, with reread_doc_lines 1, and the push is not refused') `
      ($rr1.Rc -eq 0 -and $null -ne $rr1.Row -and [int]$rr1.Row.reread_doc_lines -eq 1 -and $rr1.Text -match 'WARN - 1 commit\(s\) here add a re-read as a doc line') ("rc={0} count={1}" -f $rr1.Rc, $(if ($rr1.Row) { $rr1.Row.reread_doc_lines }))
    # MUST NOT FIRE: the same line in a file outside design/*.md, and a design doc edit with no re-read line, count 0.
    $rr2 = Invoke-StBacklogCase 'rr2' { param($d) [IO.File]::WriteAllText((Join-Path $d 'notes-rr.md'), ($rrLine + "`n")); $null = New-Item -ItemType Directory -Force (Join-Path $d 'design'); [IO.File]::WriteAllText((Join-Path $d 'design\PLAN-fixture.md'), "# a plan`n`nno re-read here`n"); $null = & git -C $d add -- notes-rr.md design/PLAN-fixture.md 2>$null }
    T ($kMNF + '  a Re-read at line outside design/*.md, and a design doc edit with none, count 0 and do not warn') `
      ($rr2.Rc -eq 0 -and $null -ne $rr2.Row -and [int]$rr2.Row.reread_doc_lines -eq 0 -and $rr2.Text -notmatch 'add a re-read as a doc line') ("rc={0} count={1}" -f $rr2.Rc, $(if ($rr2.Row) { $rr2.Row.reread_doc_lines }))
    # MUST NOT FIRE (pure): a patch that REMOVES a re-read line, or carries one only in its +++ header, counts 0.
    $rrPure = Get-TcRereadDocLineCount -Lines @('TC-COMMIT 1111', ('--- a/design/MEASURE-x.md'), ('+++ b/design/MEASURE-x.md Re-read at'), ('-' + $rrLine), 'TC-COMMIT 2222', ('+' + 'an unrelated line'))
    $rrPure2 = Get-TcRereadDocLineCount -Lines @('TC-COMMIT 1111', ('+' + $rrLine), ('+' + $rrLine), 'TC-COMMIT 2222', ('+' + $rrLine))
    T ($kMNF + '  a removed re-read line or one only in the +++ header counts 0, and two added lines in one commit count that commit once (2 commits, 2)') `
      ($rrPure -eq 0 -and $rrPure2 -eq 2) ("removed={0} twoCommits={1}" -f $rrPure, $rrPure2)

    # ---- W9.1, PUSH-MAIN'S HALF: -Prepare AND early_hit (2026-09-23) ----
    # Founding figure (plan 16.1, SCRATCH): a rehearsal started at commit time, of HEAD rebased onto origin as it stood
    # then, would have been ready and valid before the push for 10 of 23 chain landings (43%, bar 30%). -Prepare is the
    # start; rehearse-chain -Early decides. The stub below stands in for rehearse-chain: it declares -Early, records how it
    # was called in a file beside itself, and prints the decision line and the completion line the real one prints. It is
    # started through the REAL detached starter (Win32_Process.Create), so the fixture proves the child outlives the call.
    $pr = & $newPusher 'pr'
    & $moveOrigin 'notes.txt'
    $prTip = & $tipOf
    $prHead0 = ([string](@(& git -C $pr rev-parse HEAD 2>$null))[0]).Trim()
    $prDir = Join-Path $tmp 'prstub'
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop $prDir
    $prStub = Join-Path $prDir 'rehearse-stub.ps1'
    $prSaw = Join-Path $prDir 'saw.txt'
    [IO.File]::WriteAllText($prStub, ("param([switch]`$Early, [string]`$Onto, [string]`$Remote, [string]`$Branch)`n" +
      "[IO.File]::WriteAllText('" + $prSaw + "', ('early=' + [bool]`$Early + ' onto=' + `$Onto + ' remote=' + `$Remote + ' branch=' + `$Branch + ' cwd=' + (Get-Location).Path + ' gitdir=' + `$env:GIT_DIR))`n" +
      "Write-Output ('chain-rehearsal: EARLY - rehearsing 111111111 rebased onto ' + `$Onto.Substring(0, 9) + ' (key abcdef012345), in-flight file C:\fixture\early\x.json')`n" +
      "Write-Output 'CHAIN-REHEARSAL-EARLY-COMPLETE started=yes reason=rehearsed verdict=pass key=abcdef012345'`n" +
      "exit 0`n"))
    $prLogs = Join-Path $tmp 'prlogs'
    $gitDirWas = $env:GIT_DIR
    $env:GIT_DIR = Join-Path $tmp 'a-hook-git-dir-that-must-not-reach-the-child'
    try {
      $prCap = Invoke-StCapture { Invoke-TcPushMainPrepare -Dir $pr -Remote 'origin' -Branch 'main' -RehearseScript $prStub -LogRoot $prLogs }
    } finally { if ($null -eq $gitDirWas) { Remove-Item -LiteralPath Env:GIT_DIR -ErrorAction SilentlyContinue } else { $env:GIT_DIR = $gitDirWas } }
    $prSaid = $(if (Test-Path -LiteralPath $prSaw) { ([IO.File]::ReadAllText($prSaw)).Trim() } else { '<the stub never ran>' })
    $prHead1 = ([string](@(& git -C $pr rev-parse HEAD 2>$null))[0]).Trim()
    T ($kMF + '  -Prepare fetches and starts rehearse-chain -Early -Onto the fetched origin tip, detached and outside this process''s environment, prints the key and the in-flight file, and returns 0') `
      ($prCap.Result -eq 0 -and $prSaid -match ('^early=True onto=' + $prTip + ' remote=origin branch=main cwd=') -and $prSaid -match 'gitdir=$' -and $prCap.Text -match 'key abcdef012345, in-flight file C:\\fixture\\early\\x\.json') `
      ("rc={0} saw={1}" -f $prCap.Result, $prSaid)
    T ($kMNF + '  -Prepare moves no HEAD (origin had moved, and HEAD is where it was), runs no leg and writes no push row') `
      ($prHead0 -eq $prHead1 -and $prHead1 -ne $prTip) ("before={0} after={1} origin={2}" -f $prHead0, $prHead1, $prTip)
    # MUST NOT FIRE: a rehearse-chain with no -Early mode (a checkout older than W9.1) is not started at all.
    $prOld = Join-Path $prDir 'rehearse-old.ps1'
    $prOldSaw = Join-Path $prDir 'saw-old.txt'
    [IO.File]::WriteAllText($prOld, ("param([switch]`$ForPush)`n[IO.File]::WriteAllText('" + $prOldSaw + "', 'ran')`nexit 0`n"))
    $prOldCap = Invoke-StCapture { Invoke-TcPushMainPrepare -Dir $pr -Remote 'origin' -Branch 'main' -RehearseScript $prOld -LogRoot $prLogs }
    T ($kMNF + '  -Prepare in a checkout whose rehearse-chain has no -Early mode starts nothing, says so, and returns 0') `
      ($prOldCap.Result -eq 0 -and -not (Test-Path -LiteralPath $prOldSaw) -and $prOldCap.Text -match 'no -Early mode') ("rc={0} ran={1}" -f $prOldCap.Result, (Test-Path -LiteralPath $prOldSaw))
    # early_hit, pure over what the round-1 -ForPush child printed.
    $ehYes = Get-TcEarlyHit -ChainTouching $true -Lines @('chain-rehearsal: PASSED - 1 chain script(s) changed', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass early=yes')
    $ehNow = Get-TcEarlyHit -ChainTouching $true -Lines @('chain-rehearsal: this push changes the chain and has no usable rehearsal verdict - rehearsing HEAD now, OUTSIDE the push lock.', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass')
    $ehNc = Get-TcEarlyHit -ChainTouching $false -Lines @('CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=not-needed')
    $ehOld = Get-TcEarlyHit -ChainTouching $true -Lines @('chain-rehearsal: PASSED - 1 chain script(s) changed', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass')
    T ($kMF + '  early_hit reads yes from an early=yes token, no for a push that rehearsed now, not-chain for a push touching no member, and unknown when a chain push''s child says neither') `
      ($ehYes -ceq 'yes' -and $ehNow -ceq 'no' -and $ehNc -ceq 'not-chain' -and $ehOld -ceq 'unknown') ("yes={0} now={1} notChain={2} old={3}" -f $ehYes, $ehNow, $ehNc, $ehOld)
    # CLEAN TWIN: the row of a push whose -ForPush found the early verdict carries early_hit yes, through the real row path.
    $eh = & $newPusher 'eh'
    $ehRunner = { param($d) [pscustomobject]@{ Code = 0; Why = 'fixture'; Ran = $true; Lines = [string[]]@('chain-rehearsal: PASSED - 1 chain script(s) changed and this content was rehearsed over data from 2026-09-23 (0 day(s) old)', 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass early=yes') } }
    $ledEh = Join-Path $tmp 'ledeh'
    $rEh = Invoke-TcPushMain -Dir $eh -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $greenGate -RehearsalRunner $ehRunner -LedgerRoot $ledEh
    $ehRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledEh)
    $ehRows = @($ehRaw)
    $ehRow = $(if ($ehRows.Count) { $ehRows[0] } else { $null })
    T ($kCT + '  a push whose -ForPush read the early verdict lands with early_hit yes and chain_touching true on its row, and its rehearsal leg is 0 s (a reuse)') `
      ($rEh -eq 0 -and $ehRows.Count -eq 1 -and [string]$ehRow.early_hit -ceq 'yes' -and $ehRow.chain_touching -eq $true -and [int]$ehRow.leg_sec.rh -eq 0) `
      ("rc={0} rows={1} early_hit={2} chain={3} rh={4}" -f $rEh, $ehRows.Count, $(if ($ehRow) { $ehRow.early_hit }), $(if ($ehRow) { $ehRow.chain_touching }), $(if ($ehRow) { $ehRow.leg_sec.rh }))

    # ---- W9.3: THE LEGS RUN BESIDE THE REHEARSAL (2026-09-23; W2.3's fixtures, widened) ----
    # Founding cost: a chain push runs run-gates, test-auditors and a 13 to 15 minute rehearsal one after another, and
    # a red leg used to wait for nothing but still paid its whole order. The rehearsal stub below is a REAL child process
    # started through Start-TcRehearsalChild (its -Script seam): it can rendezvous with a leg through
    # lib\concurrency-probe.ps1, wait on its stop file, and print the markers rehearse-chain prints.
    . (Join-Path $repo 'lib\concurrency-probe.ps1')
    $w3Dir = Join-Path $tmp 'w93'
    $null = New-Item -ItemType Directory -Force -ErrorAction Stop $w3Dir
    $w3Stub = Join-Path $w3Dir 'rehearse-stub.ps1'
    [IO.File]::WriteAllText($w3Stub, @'
param([switch]$ForPush, [string]$Remote, [string]$Branch, [string]$StackFile, [string]$StopFile, [string]$Mode = 'pass', [string]$Rendezvous = '', [string]$Started = '', [string]$Ended = '')
if ($Started) { [IO.File]::WriteAllText($Started, [string]$PID) }
try {
  if ($Rendezvous) { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Rendezvous | Out-Null }
  if ($Mode -eq 'stopwait') {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 120) {
      if ($StopFile -and (Test-Path -LiteralPath $StopFile)) {
        Write-Output 'chain-rehearsal: STOPPED - fixture'
        Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=3 outcome=could-not-rehearse blind=stopped'
        exit 3
      }
      Start-Sleep -Milliseconds 100
    }
    Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=rehearsed-pass'
    exit 0
  }
  if ($Mode -eq 'fail') { Write-Output 'chain-rehearsal: REFUSED - fixture'; Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=1 outcome=rehearsed-fail'; exit 1 }
  if ($Mode -eq 'badmarker') { Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=1 outcome=rehearsed-fail'; exit 0 }
  Write-Output 'chain-rehearsal: no chain-manifest script changed in this push; no rehearsal needed'
  Write-Output 'CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=not-needed'
  exit 0
} finally { if ($Ended) { [IO.File]::WriteAllText($Ended, [string]$PID) } }
'@)
    # THE STARTER'S CONFIGURATION IS SCRIPT STATE, never a closure: a GetNewClosure scriptblock is bound to a dynamic
    # module that cannot see this script's functions. One configuration per case, set by New-StW3Starter.
    $script:w3Cfg = @{ Mode = 'pass'; Probes = @(); Started = ''; Ended = ''; Starts = 0 }
    function New-StW3Starter([string]$Mode, $Probes = @(), [string]$Started = '', [string]$Ended = '') {
      $script:w3Cfg = @{ Mode = $Mode; Probes = @($Probes); Started = $Started; Ended = $Ended; Starts = 0 }
      return {
        param($d, $stack, $stop)
        $script:w3Cfg.Starts++
        $xa = @('-Mode', $script:w3Cfg.Mode)
        if (@($script:w3Cfg.Probes).Count -ge $script:w3Cfg.Starts) { $xa += @('-Rendezvous', ('"' + @($script:w3Cfg.Probes)[$script:w3Cfg.Starts - 1].Script + '"')) }
        if ($script:w3Cfg.Started) { $xa += @('-Started', ('"' + $script:w3Cfg.Started + '"')) }
        if ($script:w3Cfg.Ended) { $xa += @('-Ended', ('"' + $script:w3Cfg.Ended + '"')) }
        Start-TcRehearsalChild -Dir $d -Remote 'origin' -Branch 'main' -StackFile $stack -StopFile $stop -Script $w3Stub -ExtraArgs $xa
      }
    }
    # MUST FIRE (M1, PLAN-faster-pushes-no-accuracy-loss-2026-09-25): a rehearsal leg's Sec is the CHILD'S own run time,
    # never the time push-main took to collect it. The child finishes, collection is held 5 s past its end (a LOWER bar,
    # which load can only lengthen), and Sec must fall short of the collection time by at least 4 s. The collector's
    # stopwatch, the founding bug, charges the whole hold and fails the second half.
    $m1Ended = Join-Path $w3Dir 'm1-ended.txt'
    $m1Sw = [Diagnostics.Stopwatch]::StartNew()
    $m1Job = Start-TcRehearsalChild -Dir $w3Dir -Remote 'origin' -Branch 'main' -Script $w3Stub -ExtraArgs @('-Mode', 'pass', '-Ended', ('"' + $m1Ended + '"'))
    while (-not (Test-Path -LiteralPath $m1Ended) -and $m1Sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 100 }
    $m1Proc = $m1Job.Proc
    if ($m1Proc) { $null = $m1Proc.WaitForExit(120000) }
    $m1EndAt = $m1Sw.Elapsed.TotalSeconds
    Start-Sleep -Seconds 5
    $m1R = $m1Job.Wait()
    $m1Collect = $m1Sw.Elapsed.TotalSeconds
    T ($kMF + '  a rehearsal leg collected 5 s after its child exited records the child''s own run time, not the collection time (Sec at most the time to exit plus 1, and at least 4 s under the collection time)') `
      ((Test-Path -LiteralPath $m1Ended) -and [int]$m1R.Sec -le ([math]::Ceiling($m1EndAt) + 1) -and ($m1Collect - [int]$m1R.Sec) -ge 4) `
      ("sec={0} exited_by={1:N1} collected_at={2:N1}" -f $m1R.Sec, $m1EndAt, $m1Collect)
    # MUST FIRE, overlap: the run-gates stub and the rehearsal stub each wait, through lib\concurrency-probe.ps1, until
    # BOTH have started. A pipeline that starts the rehearsal after run-gates cannot satisfy it (the 120 s deadline is a
    # hang guard). CLEAN TWIN from the same run: all three legs pass and the lock is taken, with rh_stopped false.
    $ov = & $newPusher 'ov'
    $ovProbe = New-TcRendezvousProbe -Count 2 -DeadlineSec 120
    $ovGate = { param($d) $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ovProbe.Script; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledOv = Join-Path $tmp 'ledov'
    $rOv = Invoke-TcPushMain -Dir $ov -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $ovGate -RehearsalStarter (New-StW3Starter 'pass' @($ovProbe)) -LedgerRoot $ledOv
    $ovV = Get-TcRendezvousVerdict -Probe $ovProbe
    $ovRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledOv)
    $ovRows = @($ovRaw)
    $ovRow = $(if ($ovRows.Count) { $ovRows[0] } else { $null })
    T ($kMF + '  the rehearsal runs BESIDE run-gates: the run-gates stub and the rehearsal child were alive at the same instant (a rendezvous of 2, never a clock)') `
      ($ovV.Ok -and $rOv -eq 0) ("rc={0} {1}" -f $rOv, $ovV.Detail)
    T ($kCT + '  all three legs pass and the lock is taken: one take, landed, rh_stopped false, and one entry in rh_secs_list (0: the stub needed no rehearsal)') `
      ($rOv -eq 0 -and $ovRows.Count -eq 1 -and [int]$ovRow.lock_takes -eq 1 -and ([string]$ovRow.outcome).StartsWith('landed') -and $ovRow.rh_stopped -eq $false -and (@($ovRow.rh_secs_list) -join ',') -ceq '0') `
      ("rc={0} rows={1} takes={2} outcome={3} stopped={4} secs={5}" -f $rOv, $ovRows.Count, $(if ($ovRow) { $ovRow.lock_takes }), $(if ($ovRow) { $ovRow.outcome }), $(if ($ovRow) { $ovRow.rh_stopped }), $(if ($ovRow) { @($ovRow.rh_secs_list) -join ',' }))
    # MUST FIRE, the stop: a red run-gates stub (it waits until the rehearsal child has started, on its started file, so
    # the stop meets a running child) makes push-main write the stop file; the child, polling it, ends blind=stopped
    # and has EXITED before push-main returns. MUST NOT FIRE: that refusal is refused-gate-red, never refused-rehearsal.
    $sp1 = & $newPusher 'sp1'
    $spStarted = Join-Path $w3Dir 'sp-started.txt'; $spEnded = Join-Path $w3Dir 'sp-ended.txt'
    $spGate = { param($d) $w = [Diagnostics.Stopwatch]::StartNew(); while (-not (Test-Path -LiteralPath $spStarted) -and $w.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 50 }; [pscustomobject]@{ Ran = $true; Code = 1; Why = 'fixture: run-gates red' } }
    $ledSp = Join-Path $tmp 'ledsp'
    $rSp = Invoke-TcPushMain -Dir $sp1 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $spGate -RehearsalStarter (New-StW3Starter 'stopwait' @() $spStarted $spEnded) -LedgerRoot $ledSp
    $spExitedBefore = Test-Path -LiteralPath $spEnded
    $spRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledSp)
    $spRows = @($spRaw)
    $spRow = $(if ($spRows.Count) { $spRows[0] } else { $null })
    T ($kMF + '  a red run-gates writes the stop file, the rehearsal child ends blind=stopped (rh_stopped true) and has exited before push-main returns, and the push is refused') `
      ($rSp -eq 1 -and $spExitedBefore -and $spRows.Count -eq 1 -and $spRow.rh_stopped -eq $true) ("rc={0} childExitedFirst={1} rows={2} stopped={3}" -f $rSp, $spExitedBefore, $spRows.Count, $(if ($spRow) { $spRow.rh_stopped }))
    T ($kMNF + '  a stopped rehearsal''s refusal is refused-gate-red, never refused-rehearsal or refused-rehearsal-blind') `
      ($null -ne $spRow -and [string]$spRow.outcome -ceq 'refused-gate-red') ("outcome={0}" -f $(if ($spRow) { $spRow.outcome }))
    # CLEAN TWIN: a catch-up round uses the same start, run and wait sequence, so its legs overlap too. Round 1's gate
    # moves origin (a non-chain file) and rendezvouses on probe A; round 2's gate rendezvouses on probe B; the starter hands
    # each rehearsal child the probe of its own round.
    $cr2 = & $newPusher 'cr2'
    $crA = New-TcRendezvousProbe -Count 2 -DeadlineSec 120; $crB = New-TcRendezvousProbe -Count 2 -DeadlineSec 120
    $script:crGates = 0
    $crGate = { param($d) $script:crGates++; $pp = $(if ($script:crGates -eq 1) { $crA } else { $crB }); $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pp.Script; if ($script:crGates -eq 1) { & $moveOrigin 'notes.txt' }; [pscustomobject]@{ Ran = $true; Code = 0; Why = '' } }
    $ledCr2 = Join-Path $tmp 'ledcr2'
    $rCr2 = Invoke-TcPushMain -Dir $cr2 -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -GateRunner $crGate -RehearsalStarter (New-StW3Starter 'pass' @($crA, $crB)) -LedgerRoot $ledCr2
    $crVA = Get-TcRendezvousVerdict -Probe $crA; $crVB = Get-TcRendezvousVerdict -Probe $crB
    $cr2Raw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledCr2)
    $cr2Rows = @($cr2Raw)
    $cr2Row = $(if ($cr2Rows.Count) { $cr2Rows[0] } else { $null })
    T ($kCT + '  a catch-up round overlaps its legs too: both rounds'' run-gates stubs met their rehearsal children, the row says rounds 2 and catchups 1, and it lands') `
      ($rCr2 -eq 0 -and $crVA.Ok -and $crVB.Ok -and $null -ne $cr2Row -and [int]$cr2Row.rounds -eq 2 -and [int]$cr2Row.catchups -eq 1) ("rc={0} A={1} B={2} rounds={3} catchups={4}" -f $rCr2, $crVA.Detail, $crVB.Detail, $(if ($cr2Row) { $cr2Row.rounds }), $(if ($cr2Row) { $cr2Row.catchups }))

    # W2.3's cases, through the DEFAULT legs (stub run-gates and stub test-auditors in the clone's own ops\, excluded
    # from git as the seeded paths are in the real repo) and the rehearsal stub child.
    $mkLegs = { param([string]$Name, [string]$TaBody)
      $cd = New-Clone $Name
      Add-Content -LiteralPath (Join-Path $cd '.git\info\exclude') -Value @('ops/') -Encoding ascii
      $null = New-Item -ItemType Directory -Force -ErrorAction Stop (Join-Path $cd 'ops')
      [IO.File]::WriteAllText((Join-Path $cd 'ops\run-gates.ps1'), "Write-Output 'RUN-GATES-COMPLETE pass=1 fail=0'`nexit 0`n")
      [IO.File]::WriteAllText((Join-Path $cd 'ops\prepush-test-auditors.ps1'), ("param([switch]`$RefsFromStdin)`n`$null = [Console]::In.ReadToEnd()`n" + $TaBody))
      [IO.File]::WriteAllText((Join-Path $cd ($Name + '.txt')), $Name)
      $null = & git -C $cd add -- ($Name + '.txt') 2>$null; $null = & git -C $cd commit -q -m $Name 2>$null
      return $cd
    }
    # MUST FIRE, overlap (W2.3's, kept): the test-auditors stub and the rehearsal child each wait on one rendezvous.
    $taProbe = New-TcRendezvousProbe -Count 2 -DeadlineSec 120
    $tov = & $mkLegs 'tov' ("`$null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File '" + $taProbe.Script + "'`nWrite-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n")
    $rTov = Invoke-TcPushMain -Dir $tov -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $true -LockPrefix $prefix -LockQueueRoot $qroot -RehearsalStarter (New-StW3Starter 'pass' @($taProbe))
    $taV = Get-TcRendezvousVerdict -Probe $taProbe
    T ($kMF + '  test-auditors runs beside the rehearsal: the default legs'' test-auditors stub and the rehearsal child were alive at the same instant') ($taV.Ok -and $rTov -eq 0) ("rc={0} {1}" -f $rTov, $taV.Detail)
    # MUST FIRE: a red rehearsal refuses refused-rehearsal when both gate legs passed.
    $trr = & $mkLegs 'trr' "Write-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n"
    $ledTrr = Join-Path $tmp 'ledtrr'
    $rTrr = Invoke-TcPushMain -Dir $trr -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -RehearsalStarter (New-StW3Starter 'fail') -LedgerRoot $ledTrr
    $trrRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTrr)
    $trrRows = @($trrRaw)
    T ($kMF + '  a red rehearsal with both gate legs green refuses refused-rehearsal') ($rTrr -eq 1 -and $trrRows.Count -eq 1 -and [string]$trrRows[0].outcome -ceq 'refused-rehearsal' -and $trrRows[0].ta_rc -eq 0) ("rc={0} outcome={1}" -f $rTrr, $(if ($trrRows.Count) { $trrRows[0].outcome }))
    # MUST FIRE: a red test-auditors refuses refused-gate-red, and the rehearsal child (told to stop) has exited first.
    $tred = & $mkLegs 'tred' "Write-Output 'prepush-test-auditors: REFUSED - fixture'`nWrite-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=1'`nexit 1`n"
    $tredEnded = Join-Path $w3Dir 'tred-ended.txt'
    $ledTred = Join-Path $tmp 'ledtred'
    $rTred = Invoke-TcPushMain -Dir $tred -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -RehearsalStarter (New-StW3Starter 'stopwait' @() '' $tredEnded) -LedgerRoot $ledTred
    $tredFirst = Test-Path -LiteralPath $tredEnded
    $tredRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTred)
    $tredRows = @($tredRaw)
    T ($kMF + '  a red test-auditors refuses refused-gate-red, and the rehearsal child has exited, stopped, before push-main returns') `
      ($rTred -eq 1 -and $tredFirst -and $tredRows.Count -eq 1 -and [string]$tredRows[0].outcome -ceq 'refused-gate-red' -and $tredRows[0].rh_stopped -eq $true -and $tredRows[0].ta_rc -eq 1) `
      ("rc={0} childExitedFirst={1} outcome={2} stopped={3} ta_rc={4}" -f $rTred, $tredFirst, $(if ($tredRows.Count) { $tredRows[0].outcome }), $(if ($tredRows.Count) { $tredRows[0].rh_stopped }), $(if ($tredRows.Count) { $tredRows[0].ta_rc }))
    # MUST FIRE (pure, the Wait rule): an empty exit code with a code=0 marker is 3; a 0 with a code=1 marker is 3; a 0 with
    # no marker is 3; and a CLEAN TWIN 0 with code=0 is 0.
    $wx1 = Resolve-TcRehearsalExit -ExitCode $null -Lines @('CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=not-needed')
    $wx2 = Resolve-TcRehearsalExit -ExitCode 0 -Lines @('CHAIN-REHEARSAL-CHECK-COMPLETE code=1 outcome=rehearsed-fail')
    $wx3 = Resolve-TcRehearsalExit -ExitCode 0 -Lines @('chain-rehearsal: something')
    $wx4 = Resolve-TcRehearsalExit -ExitCode 0 -Lines @('CHAIN-REHEARSAL-CHECK-COMPLETE code=0 outcome=not-needed')
    T ($kMF + '  the wait scores 3 for an empty exit code under a code=0 marker, a 0 under a code=1 marker and a 0 with no marker, and 0 only when both agree on 0') `
      ($wx1.Code -eq 3 -and $wx2.Code -eq 3 -and $wx3.Code -eq 3 -and $wx4.Code -eq 0) ("empty={0} disagree={1} none={2} agree={3}" -f $wx1.Code, $wx2.Code, $wx3.Code, $wx4.Code)
    # MUST FIRE, through a real child: a stub that exits 0 with a code=1 marker is scored 3, so the push is refused blind.
    $tbm = & $mkLegs 'tbm' "Write-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n"
    $ledTbm = Join-Path $tmp 'ledtbm'
    $rTbm = Invoke-TcPushMain -Dir $tbm -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -RehearsalStarter (New-StW3Starter 'badmarker') -LedgerRoot $ledTbm
    $tbmRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTbm)
    $tbmRows = @($tbmRaw)
    T ($kMF + '  a rehearsal child that exits 0 under a code=1 marker is scored 3: refused-rehearsal-blind, never a pass') ($rTbm -eq 3 -and $tbmRows.Count -eq 1 -and [string]$tbmRows[0].outcome -ceq 'refused-rehearsal-blind') ("rc={0} outcome={1}" -f $rTbm, $(if ($tbmRows.Count) { $tbmRows[0].outcome }))
    # MUST NOT FIRE: a push that needs no rehearsal gets the child's not-needed answer, and test-auditors' result alone
    # decides: it lands, chain_touching false.
    $tnn = & $mkLegs 'tnn' "Write-Output 'PREPUSH-TEST-AUDITORS-COMPLETE rc=0'`nexit 0`n"
    $ledTnn = Join-Path $tmp 'ledtnn'
    $rTnn = Invoke-TcPushMain -Dir $tnn -Remote 'origin' -Branch 'main' -LockWaitSec 30 -DryRun $false -LockPrefix $prefix -LockQueueRoot $qroot -RehearsalStarter (New-StW3Starter 'pass') -LedgerRoot $ledTnn
    $tnnRaw = Read-TcPushRows -Path (Get-TcPushLedgerPath -Root $ledTnn)
    $tnnRows = @($tnnRaw)
    T ($kMNF + '  a push needing no rehearsal lands on the child''s not-needed answer and test-auditors'' pass: chain_touching false, rh_outcome not-needed') `
      ($rTnn -eq 0 -and $tnnRows.Count -eq 1 -and $tnnRows[0].chain_touching -eq $false -and [string]$tnnRows[0].rh_outcome -ceq 'not-needed' -and $tnnRows[0].ta_rc -eq 0) ("rc={0} chain={1} rh={2}" -f $rTnn, $(if ($tnnRows.Count) { $tnnRows[0].chain_touching }), $(if ($tnnRows.Count) { $tnnRows[0].rh_outcome }))
    Remove-TcRendezvousProbe

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
    $epAst = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$null, [ref]$epErrs)
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
  } finally {
    $ErrorActionPreference = $prev
    $script:TcPmGuardPrefix = $guardPrefixWas
    $script:TcPmChainQueuePrefix = $cqPrefixWas; $script:TcPmChainQueueRoot = $cqRootWas
    if ($null -eq $cqSelfTestWas) { Remove-Item -LiteralPath Env:TC_CHAIN_QUEUE_SELFTEST -ErrorAction SilentlyContinue } else { $env:TC_CHAIN_QUEUE_SELFTEST = $cqSelfTestWas }
    $script:TcPmGuardInfoRoot = $guardInfoWas
    $script:TcPmRebaseAbort = { param($d) Invoke-TcGit -Dir $d -Arguments @('rebase', '--abort') }
    $script:TcPmBeforeFetchRetry = $null
    Stop-TcMutexHold
    if ($null -eq $reexecWas) { Remove-Item -LiteralPath Env:TC_PUSH_MAIN_REEXEC -ErrorAction SilentlyContinue } else { $env:TC_PUSH_MAIN_REEXEC = $reexecWas }
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
  # throw, a comment or a glued line would otherwise leave the rest green (ops-and-gates.md). 117 = the 38 of the
  # fetch-and-rebase-first loop, W0.1's 32, W0.1R's 8, the 15 its review added, W2.1R with W8.1's 14 (the index.lock
  # case was rewritten in place, not added), and W2.2R's 10 (9 catch-up cases, and the could-not-decide case split into a
  # MUST NOT FIRE and a CLEAN TWIN), W9.4's 5 (the queue member's hand-back case lands with W9.2), and W3.2 with W3.4a
  # step 3's 7, W4.1 step 7's 3, W9.1's push-main half's 5, W9.3's 11, and W9.2's 14 (W9.4's queue-member hand-back among
  # them) and the rh_key reader's 1; read off this file, not added up.
  $expectedCases = 172
  if ($cases -ne $expectedCases) { Write-Output ("FAIL  the suite ran {0} case(s) where this file holds {1}, so a case was skipped or lost" -f $cases, $expectedCases); $f++ }
  if ($f) { Write-Output ("push-main self-test FAIL: {0} of {1} check(s)" -f $f, $cases); exit 1 }
  Write-Output ("push-main self-test PASS: {0} cases - led by a branch whose base the remote moved past landing on its FIRST attempt, and by a conflicting rebase being aborted rather than left half-finished under the lock" -f $cases)
  exit 0
}

# LIBRARY MODE: dot-sourced (ops\drill-push-main-runner.ps1 drives the chain-queue drill through Invoke-TcPushMain), this file
# defines its functions and returns here, before its main body.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($NoRehearsal) {
  $env:TC_NO_REHEARSAL = $(if ($NoRehearsalReason) { $NoRehearsalReason } else { 'push-main -NoRehearsal, no reason given' })
  Say ('push-main: *** -NoRehearsal *** this push skips the chain rehearsal; the hook will print it and the bypass is logged. Reason: ' + $env:TC_NO_REHEARSAL)
  $script:TcPmReexecExtra = @('-NoRehearsal', '-NoRehearsalReason', $env:TC_NO_REHEARSAL)
}
if ($Prepare) {
  $rcP = Invoke-TcPushMainPrepare -Dir $repo -Remote $Remote -Branch $Branch
  exit $rcP
}
# FROM THE MAIN CHECKOUT, THROUGH A THROWAWAY WORKTREE (W8.2), unless -NoViaWorktree says otherwise. A re-executed child
# is already the new copy of a run that chose its road.
if ($ViaWorktree -or (-not $NoViaWorktree -and -not $env:TC_PUSH_MAIN_REEXEC -and (Test-TcMainCheckout -Dir $repo))) {
  $rcV = Invoke-TcPushMainViaWorktree -MainDir $repo -Remote $Remote -Branch $Branch -LockWaitSec $LockWaitSec -DryRun ([bool]$DryRun) -PushArgs ([ordered]@{ NoReexec = [bool]$NoReexec; ChainQueue = $ChainQueue })
  exit $rcV
}
$rc = Invoke-TcPushMain -Dir $repo -Remote $Remote -Branch $Branch -LockWaitSec $LockWaitSec -DryRun ([bool]$DryRun) -NoReexec ([bool]$NoReexec) -ChainQueue $ChainQueue
exit $rc
