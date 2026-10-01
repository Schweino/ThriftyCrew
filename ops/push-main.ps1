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
      row. A run with TC_PUSH_MAIN_REEXEC set never re-executes; -NoReexec skips it on purpose. "New copy" means the
      host OR any piece under ops\push-main\ (Get-TcScriptSetKey); the row's pm_blob stays the host's own blob.

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
# gate-inputs: ops\push-main.ps1, ops\push-main\readings.ps1, ops\push-main\selftest-1-setup.ps1, ops\push-main\selftest-2-cases.ps1, ops\push-main\selftest-3-cases.ps1, lib\push-lock.ps1, lib\git-repo-env.ps1, lib\push-ledger.ps1, lib\seed-hint.ps1, ops\seed-worktree.ps1, ops\probe-push-convergence.ps1, lib\mutex-hold.ps1, ops\merge-backlog-inbox.ps1, lib\concurrency-probe.ps1, lib\chain-queue.ps1
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
# Update-TcInstalledHooks (2026-09-27-78df57): loaded only when present, so a copy running beside an older lib\ lands
# exactly as before and only the hook refresh is skipped.
$__pmHookRefresh = Join-Path $repo 'lib\hook-refresh.ps1'
if (Test-Path -LiteralPath $__pmHookRefresh) { . $__pmHookRefresh }

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
  $h = Start-TcWarmTestAuditors -Dir $Dir -RefLine $RefLine -Script $Script
  return (Complete-TcWarmTestAuditors -Handle $h)
}

# THE TEST-AUDITORS LEG STARTS BESIDE RUN-GATES (2026-10-01, design\PLAN-push-speed-2026-10-01.md step 2, Brad: "20
# minutes for a push is not acceptable"). Invoke-TcWarmTestAuditors is now these two halves back to back, so its contract
# and its -Script seam are unchanged; Invoke-TcDefaultLegs starts the leg, runs run-gates, then completes it.
function Start-TcWarmTestAuditors {
  <# Starts ops\prepush-test-auditors.ps1 as a child over $RefLine and returns a handle; never waits. A leg that cannot
     start returns a handle whose Result is already filled in, which Complete-TcWarmTestAuditors hands straight back. #>
  param([string]$Dir, [string]$RefLine, [string]$Script = '')
  if (-not $Script) { $Script = Join-Path $Dir 'ops\prepush-test-auditors.ps1' }
  if (-not (Test-Path -LiteralPath $Script)) {
    return [pscustomobject]@{ Proc = $null; Result = [pscustomobject]@{ Ran = $false; Code = 3; Why = 'this checkout has no ops\prepush-test-auditors.ps1'; Sec = $null; Exit = $null; Lines = @() } }
  }
  if (-not $RefLine) { return [pscustomobject]@{ Proc = $null; Result = [pscustomobject]@{ Ran = $false; Code = 3; Why = 'the ref line for the test-auditors check could not be formed'; Sec = $null; Exit = $null; Lines = @() } } }
  $stem = Join-Path $env:TEMP ('tc-pm-ta-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $inF = $stem + '.in'; $outF = $stem + '.out'; $errF = $stem + '.err'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    [IO.File]::WriteAllText($inF, ($RefLine + "`n"), (New-Object Text.UTF8Encoding($false)))
    $p = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $Dir -NoNewWindow -PassThru -ErrorAction Stop `
      -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF `
      -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script, '-RefsFromStdin')
    $null = $p.Handle
    return [pscustomobject]@{ Proc = $p; Sw = $sw; InF = $inF; OutF = $outF; ErrF = $errF; Result = $null }
  } catch {
    foreach ($x in @($inF, $outF, $errF)) { if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue } }
    return [pscustomobject]@{ Proc = $null; Result = [pscustomobject]@{ Ran = $false; Code = 3; Why = ('the test-auditors check could not be started: ' + $_.Exception.Message); Sec = $null; Exit = $null; Lines = @() } }
  }
}

function Complete-TcWarmTestAuditors {
  <# Waits for a Start-TcWarmTestAuditors handle and reads it exactly as the single-step leg always did: Ran / Code / Why,
     Sec, Exit and Lines; exit 0 counts only with PREPUSH-TEST-AUDITORS-COMPLETE as the last line. #>
  param($Handle)
  if ($null -ne $Handle.Result) { return $Handle.Result }
  $p = $Handle.Proc; $sw = $Handle.Sw; $inF = $Handle.InF; $outF = $Handle.OutF; $errF = $Handle.ErrF
  try {
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
  # THE TWO LEGS RUN AT ONCE (2026-10-01, design\PLAN-push-speed-2026-10-01.md step 2; Brad: "20 minutes for a push is not
  # acceptable"). Until then run-gates ran first and test-auditors only after it passed, so a push paid the SUM (396 s +
  # 631 s on 2026-10-01's landings) and a red run-gates hid every test-auditors red until the next attempt. test-auditors
  # now starts first, in its OWN detached, seeded worktree of this HEAD, so neither leg's writes can trip the other's
  # gate-leftovers check; run-gates runs here meanwhile; then the leg is collected. A push pays the LONGER leg, and a red
  # run-gates still waits for test-auditors, so one refusal names both layers. The decision is unchanged: a run-gates that
  # did not pass is the answer, else a test-auditors Code that is not 0 is, else the pass. A leg worktree that cannot be
  # made falls back to the old order in this checkout, so this degrades to the day before and never to a refusal.
  $refLine = Get-TcWarmRefLine -Dir $Dir -Remote $Remote -Branch $Branch
  $legWt = New-TcLegWorktree -Dir $Dir
  $th = $null
  if ($legWt) { $th = Start-TcWarmTestAuditors -Dir $legWt -RefLine $refLine }
  try {
    $wg = Invoke-TcWarmGate -Dir $Dir
    $res = [pscustomobject]@{ Ran = $wg.Ran; Code = $wg.Code; Why = $wg.Why; RgSec = $wg.Sec; RgLines = $wg.Lines; TaSec = $null; TaExit = $null; TaLines = $null }
    $gatePassed = ($wg.Ran -and $wg.Code -eq 0)
    # W2.3's SHAPE (W9.3 step 3): the rehearsal starts once run-gates has passed. A no-op when it has already started
    # beside run-gates.
    if ($gatePassed -and $BeforeTestAuditors) { & $BeforeTestAuditors }
    if ($null -ne $th) {
      $wt = Complete-TcWarmTestAuditors -Handle $th
    } elseif ($gatePassed) {
      Say 'push-main: the test-auditors leg could not get its own worktree, so it runs after run-gates in this checkout, as before.'
      $wt = Invoke-TcWarmTestAuditors -Dir $Dir -RefLine $refLine
    } else { return $res }
    $res.TaSec = $wt.Sec; $res.TaExit = $wt.Exit; $res.TaLines = $wt.Lines
    if ($gatePassed -and $wt.Code -ne 0) { $res.Ran = $wt.Ran; $res.Code = $wt.Code; $res.Why = $wt.Why }
    elseif (-not $gatePassed -and $wt.Code -eq 1) { $res.Why = ([string]$res.Why + '; test-auditors refused too (its lines are above)').TrimStart('; ') }
    return $res
  } finally {
    if ($legWt) { Remove-TcLegWorktree -Dir $Dir -Path $legWt }
  }
}

function New-TcLegWorktree {
  <# A detached, seeded worktree of $Dir's HEAD for the test-auditors leg, or '' when one cannot be made (the caller then
     runs the leg the old way). Under %TEMP%, so it is never inside a checkout a gate walks. #>
  param([string]$Dir)
  $head = Invoke-TcGit -Dir $Dir -Arguments @('rev-parse', 'HEAD')
  if ($head.Code -ne 0 -or -not @($head.Out).Count) { return '' }
  $path = Join-Path $env:TEMP ('tc-pm-legwt-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
  $add = Invoke-TcGit -Dir $Dir -Arguments @('worktree', 'add', '--detach', $path, ([string]@($head.Out)[0]).Trim())
  if ($add.Code -ne 0) { Say ('push-main: could not add the test-auditors worktree (' + (([string]$add.Text) -replace '\s+', ' ').Trim() + ').'); return '' }
  $seed = Invoke-TcSeedBeforeGate -Dir $path
  if (-not $seed.Ran -or $seed.Code -ne 0) { Remove-TcLegWorktree -Dir $Dir -Path $path; return '' }
  return $path
}

function Remove-TcLegWorktree {
  <# Removes a leg worktree and never leaves a husk: a half-removed worktree resolves to the MAIN checkout for git. #>
  param([string]$Dir, [string]$Path)
  $null = Invoke-TcGit -Dir $Dir -Arguments @('worktree', 'remove', '--force', $Path)
  if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
  $null = Invoke-TcGit -Dir $Dir -Arguments @('worktree', 'prune')
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

function Get-TcScriptSetKey {
  <# WHICH CODE IS RUNNING, host AND pieces: the re-exec test's key (design\PLAN-split-giant-files-2026-09-27.md D3).
     push-main dot-sources pieces from the push-main folder beside it, so a change to a piece alone is new code as much as
     a change to the host, and a key over the host only would let a stale copy land a push. The key is the host's blob
     when that folder holds no .ps1 (so a checkout before the split keys exactly as pm_blob did), and otherwise the
     SHA-256 of the host blob plus every piece's relative path and blob, in ordinal order. '' when any file cannot be
     hashed, which skips the re-exec exactly as an unreadable pm_blob always has. The row's pm_blob stays the host blob:
     probe-push-convergence maps it onto ops/push-main.ps1's history. #>
  param([string]$Path)
  $hb = Get-TcScriptBlob -Path $Path
  if (-not $hb) { return '' }
  $pd = Join-Path (Split-Path -Parent $Path) ([IO.Path]::GetFileNameWithoutExtension($Path))
  if (-not (Test-Path -LiteralPath $pd -PathType Container)) { return $hb }
  $rels = New-Object 'System.Collections.Generic.List[string]'
  foreach ($f in @(Get-ChildItem -LiteralPath $pd -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue)) { $rels.Add($f.FullName.Substring($pd.Length).TrimStart('\', '/')) }
  if ($rels.Count -eq 0) { return $hb }
  $arr = $rels.ToArray(); [Array]::Sort($arr, [StringComparer]::Ordinal)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append($hb).Append("`n")
  foreach ($r in $arr) {
    $b = Get-TcFirstLine (Invoke-TcGit -Dir $pd -Arguments @('hash-object', (Join-Path $pd $r)))
    if ($b -notmatch '^[0-9a-f]{40}([0-9a-f]{24})?$') { return '' }
    [void]$sb.Append(($r -replace '\\', '/')).Append("`t").Append($b).Append("`n")
  }
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sb.ToString())) } finally { $sha.Dispose() }
  return ('set:' + (-join ($bytes | ForEach-Object { $_.ToString('x2') })))
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

. (Join-Path $PSScriptRoot 'push-main\readings.ps1')

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
      # A LANDED ops\hooks CHANGE IS INSTALLED NOW, not at the 10:30 watchdog repair (2026-09-27-78df57). Outside the
      # push lock (AfterLanded runs after Exit-TcPushLock). The result is assigned, never emitted, so this block still
      # returns exactly 'reset-keep'; a missing or throwing helper costs the refresh, never the landing.
      try {
        if (Get-Command Update-TcInstalledHooks -ErrorAction SilentlyContinue) {
          $hr = Update-TcInstalledHooks -Repo $vwMainDir -From $vwStartHead -To $landed
          if ($hr.line) { Say ('push-main: ' + $hr.line) }
        }
      } catch { Say ('push-main: hook-refresh threw (' + $_.Exception.Message + '); the 10:30 watchdog -Repair will retry.') }
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
  # ...and the key over the host AND its pieces, also at START, which is what the re-exec compares (D3 of the split plan).
  $pmKey = Invoke-TcRowReader 'pm_key' { Get-TcScriptSetKey -Path $script:TcPushMainPath } ''
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
        # The key covers the host AND every piece under ops\push-main\, so a piece-only change re-execs too.
        if ($s.Rebased -and $pmKey -and -not $NoReexec -and -not $env:TC_PUSH_MAIN_REEXEC) {
          $nowKey = Invoke-TcRowReader 'reexec-blob' { Get-TcScriptSetKey -Path $script:TcPushMainPath } ''
          if ($nowKey -and -not [string]::Equals($nowKey, $pmKey, [StringComparison]::Ordinal)) {
            Say ("push-main: the pre-flight rebase brought in a new ops\push-main.ps1 or piece of it (key {0} -> {1}), so the NEW copy runs this push once; this run writes no row of its own." -f $pmKey.Substring(0, 9), $nowKey.Substring(0, 9))
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
  . (Join-Path $PSScriptRoot 'push-main\selftest-1-setup.ps1')
  try {
    . (Join-Path $PSScriptRoot 'push-main\selftest-2-cases.ps1')
    . (Join-Path $PSScriptRoot 'push-main\selftest-3-cases.ps1')
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
  # them) and the rh_key reader's 1, and the split plan D3's 3 (the re-exec key over host and pieces); read off this file, not added up.
  $expectedCases = 177
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
