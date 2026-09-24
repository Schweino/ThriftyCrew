<#
  run-backlog-merge.ps1 - the backlog's one allocator, on a clock: merge design\backlog-inbox in a dedicated worktree at
  origin/main, land the merge through push-main, and page what needs a person.

  Scheduled:  TC Backlog Merge (ops\scheduled-tasks\tc-backlog-merge.xml), 11:00 and 17:00, under the headless wrapper
  By hand:    powershell -File ops\run-backlog-merge.ps1           (prints what it WOULD page; pages nothing, and leaves
                                                                   the lease scan's position where the task left it)
              powershell -File ops\run-backlog-merge.ps1 -Alert    (what the task runs)
  On demand:  Start-ScheduledTask -TaskName 'TC Backlog Merge'     (a session that needs an id now, Brad's ruling D17)
  Self-test:  powershell -File ops\run-backlog-merge.ps1 -SelfTest

  WHY (2026-09-23, W3.4 and W3.4a of design\PLAN-push-derived-conflicts-2026-09-23.md, Brad's rulings D2 and D17).
  Lanes record findings and progress as files under design\backlog-inbox\ and never edit the backlog, because that file
  overlapped in 12 of 19 recent rebase conflicts. A drop box only works if something empties it, and "the orchestrator
  will merge it" is an intention with no exit code: on 2026-09-08 nine findings from three lanes sat unmerged for hours.
  This task is the something. It is also the ONE ALLOCATOR: ops\merge-backlog-inbox.ps1's lock is named from the path
  of the backlog it guards, so two checkouts' merges take different locks, mint the same next id from their own copies
  and collide on the next rebase. Only one writer fixes that, so this task's worktree is marked as the allocator and a
  merge anywhere else is refused unless it passes -AllowHandMerge "<reason>" (that file's header has the rule).

  WHAT A RUN DOES, IN ORDER
    1. takes its RUN LOCK with ZERO wait. A second run (a hand run beside the task) finds it held, prints SKIPPED and
       exits 0 having touched nothing: the run that holds it is doing the work.
    2. inside the ~07:00 bot's window (06:30 to 08:00 local) it DEFERS the merge and the push, says so, and still runs
       the read-only watches (4 to 6). The two scheduled times sit well clear of it; this guards an on-demand start.
    3. otherwise: fetches origin, REFRESHES its own linked worktree (.claude\worktrees\tc-backlog-merge under the main
       checkout) to origin/main - created when missing; a leftover rebase aborted, `reset --hard`, a detached checkout of
       the fetched sha, `clean -fd`, which removes untracked files and keeps the IGNORED seeded boards - and requires
       `git status` empty afterwards. It writes the allocator marker into that worktree's git admin directory, then
       runs THAT worktree's ops\merge-backlog-inbox.ps1 (the copy at origin/main). When the merge ran to its marker with
       exit 0 or 2 and changed anything, it commits exactly the changed paths - which must all be the backlog or under
       design\backlog-inbox\, or nothing is committed - with the merge's `Backlog-Merged-From:` line as a trailer, seeds
       the worktree (ops\seed-worktree.ps1, which refreshes a board rebuilt since the last copy), and lands it through
       that worktree's ops\push-main.ps1.
    4. runs ops\probe-push-convergence.ps1 -Due (W0.3): a bar past its read-out date with no result line is exit 2.
    5. reads the push ledger for rows with lease=timeout or lease=error since its last paging run (W6.1 step 10).
    6. the ABSENCE FLOOR: every inbox file still pending on origin/main is aged from the commit that ADDED it, and one
       older than 24 hours pages.
    7. pages every condition through grocery\alert-lib.ps1's Send-AlertConditions, one alert type per condition.
  Every git call names its repository with -C, and the repository environment is cleared first, because a hook in a
  linked worktree exports GIT_DIR and everything it spawns inherits it (.claude\rules\ops-and-gates.md).

  NEVER THE MAIN CHECKOUT. Every destructive step (reset, clean, checkout) runs only after Test-TcBmLinkedWorktree has
  proved the directory is a LINKED worktree of the same repository, with a `.git` FILE, and is not the main checkout.
  The main checkout carries other sessions' uncommitted work and the bot's data all day; a reset there would destroy it.

  WHAT IT PAGES, one condition each (alert type 'Ops backlog merge: <LABEL>'):
    QUARANTINED        the merge exited 2: an inbox file was malformed or two updates conflict, and a person decides
    PUSH REFUSED       push-main exited 1 (its tail is the body); the next run redoes the merge from origin/main
    READ-OUT DUE       -Due exited 2
    LEASE TIMEOUT / LEASE ERROR   a ledger row since the last paging run: a wedged holder, or a lease that errored
    STALE INBOX        a file pending on origin/main more than 24 hours after the commit that added it
    and the could-not-evaluate ones: RUN BLIND (no worktree, a failed fetch or commit, a stray path, a watch that
    could not run), MERGE BLIND (the merge exited 1 or 3, or died before its marker), PUSH BLIND (push-main exited 3 or
    was killed), READ-OUT BLIND, LEASE BLIND, STALE INBOX BLIND.

  THE ABSENCE FLOOR, AND WHY IT READS GIT RATHER THAN MTIME. Every other threshold here is an upper bound, so none can
  fire on nothing happening (reliability-craft/applies-here.md section 3). This one watches the CONSUMER: the task runs
  twice a day, so a working task leaves nothing pending longer than about 18 hours, and 24 hours means the merge or
  its landing stopped working. $script:StaleInboxSec = 86400 is the first plausible value above that 18, not swept. The
  plan's fixture said mtime; in a worktree reset to origin/main a file's mtime is when THIS checkout wrote it, which
  understates its age by up to a refresh interval, so the age is taken from the committer time of the newest commit on
  origin/main that ADDED the path (--no-renames, so a file moved back out of quarantine counts from its move). It
  covers new-finding files as well as UPDATE files: since D17 both wait on this task alone. A file whose add time
  cannot be found is STALE INBOX BLIND, never young. A task that stops RUNNING is health-heartbeat's to page (its row
  in grocery\expected-automations.json), and the two floors are deliberately separate.

  LEASE ROWS BEFORE W6.1. The chain lease (W6.1) writes `lease`, `lease_wait_ms` and `lease_holder` into push-main's
  ledger rows. Until it lands no row carries a `lease` field, so there is nothing to read: the run says so, naming
  whether origin/main holds lib\chain-lease.ps1, and pages nothing. It never fails for that. "Since its last run" is a
  position kept OUTSIDE every checkout (%LOCALAPPDATA%\ThriftyCrew\backlog-merge\state.json) and moved only by a paging
  run whose page went out, so a hand run or a failed send never skips a row. With no position yet it reads 24 hours.

  THE RUN LOCK (Global\tc-backlog-merge-run) is taken with zero wait and held for the whole run, across the merge's
  ledger lock and push-main's push lock. It never WAITS, so it adds no edge to any wait-for graph and cannot be part of
  a deadlock; like push-main's planned per-checkout guard (W2.1) it only refuses a second copy of itself. It is not one
  of the four ordered mechanisms in .claude\rules\ops-and-gates.md, and this header is where it is named.

  EXIT CODES (lib\guard-contract.ps1 vocabulary, and grocery\expected-automations.json declares them for the heartbeat):
  0 nothing needed a person (or SKIPPED behind another run); 2 at least one finding, paged by this run (or printed as
  WOULD PAGE without -Alert); 3 could not evaluate - any BLIND condition, or a page that did not go out. A proven
  finding beside a blind reason is 3, because the blind half is what the heartbeat must also see. A crash exits 1 from
  PowerShell with no stamp, which the heartbeat pages as TASK FAILED. The stamp, ops\out\logs\backlog-merge-stamp.json,
  is written by an -Alert run that reached its verdict.

  SCOPE OF A CLEAN REPORT: exit 0 means the merge ran in the allocator's worktree at the origin/main it fetched, what
  it changed landed (or nothing changed), no bar was due without a result, no lease row since the last paging run
  timed out or errored, and nothing waited in the inbox past 24 hours. It says nothing about a hand merge made with
  -AllowHandMerge, about a push that did not go through push-main (the lease rows are push-main's only), or about
  a finding a lane never wrote down.
#>
# Declared inputs of its -SelfTest (2026-09-23, lib\gate-input-key.ps1): every case works in a per-run temp directory -
# a bare origin, a clone standing in for the main checkout, and a worktree - into which it copies the real merge, the
# gate that merge runs and the whole lib\ they load. It reads nothing else of this repo.
# Since 2026-09-24 it also reads the alert registry, to prove every condition it pages is registered.
# gate-inputs: ops\run-backlog-merge.ps1, ops\merge-backlog-inbox.ps1, ops\audit-backlog-status.ps1, lib\*.ps1, grocery\run-log-lib.ps1, .gitattributes, grocery\alert-registry.json, grocery\alert-registry-lib.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param(
  [switch]$Alert,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\git-repo-env.ps1')
Clear-TcGitRepoEnv
. (Join-Path $repo 'lib\guard-contract.ps1')     # Exit-Guard: the marker travels with the exit
. (Join-Path $repo 'lib\push-ledger.ps1')        # Read-TcPushRows, Get-TcPushLedgerPath: the rows the lease scan reads
. (Join-Path $repo 'lib\main-checkout.ps1')      # Get-TcMainCheckout: which checkout is main, and is a directory linked
. (Join-Path $repo 'lib\atomic-write.ps1')       # Write-TcAtomicFile: the allocator marker and the state are replaced whole
. (Join-Path $repo 'grocery\run-log-lib.ps1')    # Start-RunLog / Stop-RunLog: a hidden task leaves a transcript

$script:TaskName = 'TC Backlog Merge'
$script:WorktreeLeaf = 'tc-backlog-merge'
# The marker ops\merge-backlog-inbox.ps1 reads. Spelled here AND there on purpose (neither file may load the other);
# this file's self-test runs that merge against a marker this file wrote, in both directions, so they cannot drift.
$script:MarkerName = 'tc-backlog-allocator'
$script:SubjectPrefix = 'Ops backlog merge'
# THE ABSENCE FLOOR (header). First plausible value above the task's 18-hour longest gap, NOT a sweep.
$script:StaleInboxSec = 86400
# THE BOT WINDOW, local minutes after midnight, start inclusive and end exclusive. First plausible values bracketing
# the ~07:00 bot (CLAUDE.md), NOT a sweep; the schedule (11:00, 17:00) never enters it.
$script:BotWindowStartMin = 390
$script:BotWindowEndMin = 480
# A FIRST RUN reads this far back in the push ledger. First plausible value: one day, the ledger's own file unit.
$script:FirstRunLookbackSec = 86400
# HANG GUARDS, not tuned numbers: each is several times the slowest run of its child seen or implied. push-main's own
# worst case is a 1,200 s lock wait plus two rounds of legs (about 36 min serial each), so 5,400 s leaves a real hang
# killed inside the task's 2 h ExecutionTimeLimit.
$script:MergeGuardSec = 900
$script:LandGuardSec = 5400
$script:WatchGuardSec = 900
$script:GitGuardSec = 600
$script:RunLockName = 'Global\tc-backlog-merge-run'
$script:StateDirDefault = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ThriftyCrew\backlog-merge'
$script:StampPath = Join-Path $repo 'ops\out\logs\backlog-merge-stamp.json'
$script:PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:BacklogRel = 'design/BACKLOG-course-findings.md'
$script:InboxRel = 'design/backlog-inbox/'

# ------------------------------------------------------------------------------------------------------ processes

function Stop-TcBmTree {
  <# taskkill /T /F: push-main starts powershell.exe and git children, and killing the parent alone leaves them. #>
  param([int]$Id)
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
  $psi.Arguments = '/T /F /PID ' + $Id
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $k = [Diagnostics.Process]::Start($psi)
  $null = $k.StandardOutput.ReadToEndAsync(); $null = $k.StandardError.ReadToEndAsync()
  [void]$k.WaitForExit(30000)
  $k.Dispose()
}

function Invoke-TcBmProcess {
  <# One child, both pipes drained while it runs (the reads start BEFORE the wait, or a child that fills a pipe blocks
     while this blocks on it), under a hang guard that kills its whole tree. The process API is used rather than a
     PowerShell redirect of a native exe, so no error preference decides what a stderr line means. Returns ExitCode,
     Raw (stdout as written), Lines (stdout lines, empty ones dropped), Err and TimedOut. Never throws: a child that
     could not start is ExitCode 127. #>
  param([string]$Exe, [string]$ArgLine, [string]$WorkDir = '', [int]$GuardSec = 300, [hashtable]$Env = @{})
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  $psi.Arguments = $ArgLine
  if ($WorkDir) { $psi.WorkingDirectory = $WorkDir }
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
  foreach ($k in @($Env.Keys)) { $psi.EnvironmentVariables[[string]$k] = [string]$Env[$k] }
  $p = $null
  try { $p = [Diagnostics.Process]::Start($psi) } catch {
    return [pscustomobject]@{ ExitCode = 127; Raw = ''; Lines = @(); Err = ('could not start ' + $Exe + ': ' + $_.Exception.Message); TimedOut = $false }
  }
  $tOut = $p.StandardOutput.ReadToEndAsync()
  $tErr = $p.StandardError.ReadToEndAsync()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $killed = $false
  while (-not $p.WaitForExit(250)) {
    if ($sw.Elapsed.TotalSeconds -ge $GuardSec) {
      $killed = $true
      Stop-TcBmTree -Id $p.Id
      [void]$p.WaitForExit(30000)
      break
    }
  }
  $out = ''; $err = ''
  if ($tOut.Wait(60000)) { $out = [string]$tOut.Result }
  if ($tErr.Wait(60000)) { $err = [string]$tErr.Result }
  $rc = if ($p.HasExited) { $p.ExitCode } else { -1 }
  $p.Dispose()
  $lines = @(($out -split "`r?`n") | Where-Object { $_ -ne '' })
  return [pscustomobject]@{ ExitCode = $rc; Raw = $out; Lines = $lines; Err = $err.Trim(); TimedOut = $killed }
}

function ConvertTo-TcBmArgLine {
  <# An argument vector as one Windows command line: a value with a space or a quote is quoted, an inner quote escaped.
     Paths reach here without a trailing backslash, which is the one case this simple rule would get wrong. #>
  param([string[]]$Argv)
  return ((@($Argv | ForEach-Object {
    $s = [string]$_
    if ($s -eq '') { '""' } elseif ($s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' } else { $s }
  })) -join ' ')
}

function Invoke-TcBmGit {
  <# git -C <Dir> <args>: Code, Out (lines), Raw, Err, Text. #>
  param([string]$Dir, [string[]]$GitArgs, [hashtable]$Env = @{})
  $r = Invoke-TcBmProcess -Exe 'git' -ArgLine (ConvertTo-TcBmArgLine (@('-C', $Dir) + @($GitArgs))) -GuardSec $script:GitGuardSec -Env $Env
  return [pscustomobject]@{ Code = $r.ExitCode; Out = $r.Lines; Raw = $r.Raw; Err = $r.Err; Text = ((@($r.Lines) + @($r.Err)) -join "`n").Trim() }
}

function Invoke-TcBmPsChild {
  <# A PowerShell script as a child: -NoProfile -ExecutionPolicy Bypass -File <script> <args>. #>
  param([string]$Script, [string[]]$ScriptArgs = @(), [string]$WorkDir = '', [int]$GuardSec = 300)
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + @($ScriptArgs)
  return (Invoke-TcBmProcess -Exe $script:PsExe -ArgLine (ConvertTo-TcBmArgLine $argv) -WorkDir $WorkDir -GuardSec $GuardSec)
}

function Get-TcBmFullPath {
  param([string]$Path)
  return ([IO.Path]::GetFullPath(([string]$Path).Replace('/', '\'))).TrimEnd('\')
}

function ConvertTo-TcBmEpoch {
  <# UTC epoch seconds, from ticks. $When must be a UTC [datetime] (Kind Utc); a local one is converted first. #>
  param([datetime]$When)
  $u = if ($When.Kind -eq [DateTimeKind]::Local) { $When.ToUniversalTime() } else { $When }
  return [int64][Math]::Floor(($u.Ticks - 621355968000000000) / 10000000)
}

function Test-TcBmSamePath {
  param([string]$A, [string]$B)
  return [string]::Equals((Get-TcBmFullPath $A), (Get-TcBmFullPath $B), [StringComparison]::OrdinalIgnoreCase)
}

# ------------------------------------------------------------------------------------------------ pure judgements

function Test-TcBmBotWindow {
  <# Is $LocalNow inside [start, end) local minutes after midnight? Pure; compared in whole seconds. #>
  param([datetime]$LocalNow, [int]$StartMin = $script:BotWindowStartMin, [int]$EndMin = $script:BotWindowEndMin)
  $sec = [int][Math]::Floor($LocalNow.TimeOfDay.TotalSeconds)
  return (($sec -ge ($StartMin * 60)) -and ($sec -lt ($EndMin * 60)))
}

function Test-TcBmOwnedPath {
  <# The only paths a merge may change: the backlog itself and anything under the inbox. Ordinal, git's own case. #>
  param([string]$Path)
  if ([string]::Equals($Path, $script:BacklogRel, [StringComparison]::Ordinal)) { return $true }
  return ([string]$Path).StartsWith($script:InboxRel, [StringComparison]::Ordinal)
}

function ConvertFrom-TcBmPorcelainZ {
  <# `git status --porcelain=v1 -z` (renames off), as Code and Path per entry. Pure over the raw text. #>
  param([string]$Raw)
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($e in @(([string]$Raw) -split [char]0)) {
    if ($e.Length -lt 4) { continue }
    [void]$out.Add([pscustomobject]@{ Code = $e.Substring(0, 2); Path = $e.Substring(3) })
  }
  return , ($out.ToArray())
}

function Read-TcBmMergeOutput {
  <# What the merge printed: Complete (its marker is the last line), Trailer (the Backlog-Merged-From line or ''),
     Verdict (the VERDICT line or ''), Quarantine (the QUARANTINED block: its header and the indented lines under it). #>
  param([string[]]$Lines)
  $ls = @($Lines | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
  $r = [pscustomobject]@{ Complete = $false; Trailer = ''; Verdict = ''; Quarantine = @() }
  if ($ls.Count -and ($ls[$ls.Count - 1].Trim() -ceq 'MERGE-BACKLOG-INBOX-COMPLETE')) { $r.Complete = $true }
  $q = New-Object System.Collections.Generic.List[string]
  $inQ = $false
  foreach ($l in $ls) {
    if ($l -match '^Backlog-Merged-From: ') { $r.Trailer = $l.Trim(); $inQ = $false; continue }
    if ($l -match '^VERDICT: ') { $r.Verdict = $l.Trim(); $inQ = $false; continue }
    if ($l -match '^(WOULD BE )?QUARANTINED \(') { [void]$q.Add($l.Trim()); $inQ = $true; continue }
    if ($inQ -and $l -match '^\s+\S') { [void]$q.Add($l.Trim()); continue }
    $inQ = $false
  }
  $r.Quarantine = $q.ToArray()
  return $r
}

function New-TcBmCommitMessage {
  <# The merge commit's message. Pure. The trailers are the LAST paragraph, which is where git reads trailers: the
     merge's own Backlog-Merged-From line (when it printed one) and a Plan-not-applicable line, because the backlog is
     named by an under-way plan and a routine merge is not that plan's work. #>
  param([string]$Verdict, [string]$Trailer, [string[]]$Body, [string]$Stamp)
  $v = if ($Verdict) { $Verdict -replace '^VERDICT:\s*', '' -replace '\s*Exit \d+\.\s*$', '' } else { 'the merge printed no verdict line' }
  $subject = ('Backlog merge by {0} ({1}): {2}' -f $script:TaskName, $Stamp, $v.TrimEnd('.'))
  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add($subject)
  [void]$lines.Add('')
  [void]$lines.Add('Written by ops/run-backlog-merge.ps1 in its own worktree at origin/main. The merge ran as the one')
  [void]$lines.Add('allocator of backlog ids (Brad''s ruling D17), and this commit carries exactly the paths it changed.')
  if (@($Body).Count) {
    [void]$lines.Add('')
    foreach ($b in @($Body | Select-Object -First 60)) { [void]$lines.Add([string]$b) }
  }
  [void]$lines.Add('')
  if ($Trailer) { [void]$lines.Add($Trailer) }
  [void]$lines.Add('Plan-not-applicable: a scheduled backlog merge (ops/run-backlog-merge.ps1)')
  return (($lines.ToArray()) -join "`n") + "`n"
}

function Get-TcBmStaleInbox {
  <# The absence floor, PURE over rows (Path, Kind, AddedEpoch or $null): Stale is every row strictly older than
     $BarSec at $NowEpoch, oldest first, each with AgeSec; Unknown is every row whose add time was not found. #>
  param($Pending, [int64]$NowEpoch, [int64]$BarSec = $script:StaleInboxSec)
  $stale = New-Object System.Collections.Generic.List[object]
  $unknown = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($Pending)) {
    if ($null -eq $p) { continue }
    if ($null -eq $p.AddedEpoch) { [void]$unknown.Add($p); continue }
    $age = $NowEpoch - [int64]$p.AddedEpoch
    if ($age -gt $BarSec) { [void]$stale.Add([pscustomobject]@{ Path = $p.Path; Kind = $p.Kind; AgeSec = $age }) }
  }
  $sorted = @($stale.ToArray() | Sort-Object -Property AgeSec -Descending)
  return [pscustomobject]@{ Stale = $sorted; Unknown = $unknown.ToArray() }
}

function Get-TcBmInboxKind {
  <# Which inbox files are PENDING, read the way the merge reads its box: a .md at the top of the inbox is a finding
     file, a .md directly under updates\ is an UPDATE file, and README.md and _*.md are skipped (case-insensitive, as the
     merge compares them). Anything else - quarantine\, a .reason.txt - is not pending. Returns 'finding', 'update' or ''. #>
  param([string]$Path)
  if (-not ([string]$Path).StartsWith($script:InboxRel, [StringComparison]::Ordinal)) { return '' }
  $rel = $Path.Substring($script:InboxRel.Length)
  $kind = 'finding'
  if ($rel.StartsWith('updates/', [StringComparison]::Ordinal)) { $kind = 'update'; $rel = $rel.Substring(8) }
  if ($rel.Contains('/')) { return '' }
  if (-not $rel.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase)) { return '' }
  if ([string]::Equals($rel, 'README.md', [StringComparison]::OrdinalIgnoreCase) -or $rel.StartsWith('_')) { return '' }
  return $kind
}

# ------------------------------------------------------------------------------------------------------ git steps

function Invoke-TcBmFetch {
  <# One fetch, retried ONCE when the shared remote-tracking ref was locked by a concurrent update (W2.1R step 2 saw
     that race in production). #>
  param([string]$Dir, [string]$Remote)
  $f = Invoke-TcBmGit -Dir $Dir -GitArgs @('fetch', '-q', $Remote)
  if (($f.Code -ne 0) -and ($f.Text -match 'cannot lock ref')) { $f = Invoke-TcBmGit -Dir $Dir -GitArgs @('fetch', '-q', $Remote) }
  return $f
}

function Test-TcBmLinkedWorktree {
  <# The guard in front of every destructive step: $Dir is a LINKED worktree (a `.git` FILE) of the repository whose
     main checkout is $MainRoot, git names $Dir itself as its top level, and it is not the main checkout. #>
  param([string]$Dir, [string]$MainRoot)
  if (Test-TcBmSamePath $Dir $MainRoot) { return [pscustomobject]@{ Ok = $false; Why = ($Dir + ' IS the main checkout, which carries other sessions'' work and is never reset') } }
  if (-not (Test-Path -LiteralPath (Join-Path $Dir '.git') -PathType Leaf)) { return [pscustomobject]@{ Ok = $false; Why = ($Dir + ' has no .git FILE, so it is not a linked worktree and is never reset') } }
  $mc = Get-TcMainCheckout -Dir $Dir
  if (-not $mc.ok -or -not $mc.linked) { return [pscustomobject]@{ Ok = $false; Why = ('git does not read ' + $Dir + ' as a linked worktree (' + $mc.note + ')') } }
  if (-not (Test-TcBmSamePath $mc.top $Dir)) { return [pscustomobject]@{ Ok = $false; Why = ('git names ' + $mc.top + ' as the checkout at ' + $Dir) } }
  if (-not $mc.main -or -not (Test-TcBmSamePath $mc.main $MainRoot)) { return [pscustomobject]@{ Ok = $false; Why = ($Dir + ' belongs to the repository of ' + $mc.main + ', not ' + $MainRoot) } }
  return [pscustomobject]@{ Ok = $true; Why = '' }
}

function Update-TcBmWorktree {
  <# Bring the dedicated worktree to exactly $Sha, creating it when missing. Returns Ok, Why and Created. #>
  param([string]$MainRoot, [string]$Dir, [string]$Sha)
  $r = [pscustomobject]@{ Ok = $false; Why = ''; Created = $false }
  if (-not (Test-Path -LiteralPath $Dir)) {
    $null = Invoke-TcBmGit -Dir $MainRoot -GitArgs @('worktree', 'prune')
    $parent = Split-Path -Parent $Dir
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
    $add = Invoke-TcBmGit -Dir $MainRoot -GitArgs @('worktree', 'add', '-q', '--detach', $Dir, $Sha)
    if ($add.Code -ne 0) { $r.Why = ('git worktree add exited ' + $add.Code + ': ' + $add.Text); return $r }
    $r.Created = $true
  }
  $lt = Test-TcBmLinkedWorktree -Dir $Dir -MainRoot $MainRoot
  if (-not $lt.Ok) { $r.Why = ('refusing to reset it: ' + $lt.Why); return $r }
  $gd = Invoke-TcBmGit -Dir $Dir -GitArgs @('rev-parse', '--absolute-git-dir')
  if ($gd.Code -ne 0 -or -not @($gd.Out).Count) { $r.Why = ('git could not name the worktree''s git dir: ' + $gd.Text); return $r }
  $gdPath = Get-TcBmFullPath ([string]@($gd.Out)[0])
  if ((Test-Path -LiteralPath (Join-Path $gdPath 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gdPath 'rebase-apply'))) {
    $ab = Invoke-TcBmGit -Dir $Dir -GitArgs @('rebase', '--abort')
    if ($ab.Code -ne 0) { $r.Why = ('a rebase left in the worktree could not be aborted: ' + $ab.Text); return $r }
  }
  foreach ($step in @(@('reset', '-q', '--hard'), @('checkout', '-q', '--detach', $Sha), @('clean', '-q', '-fd'))) {
    $g = Invoke-TcBmGit -Dir $Dir -GitArgs $step
    if ($g.Code -ne 0) { $r.Why = ('git ' + ($step -join ' ') + ' exited ' + $g.Code + ': ' + $g.Text); return $r }
  }
  $st = Invoke-TcBmGit -Dir $Dir -GitArgs @('--no-optional-locks', 'status', '--porcelain', '--untracked-files=all')
  if ($st.Code -ne 0 -or @($st.Out).Count) { $r.Why = ('the refreshed worktree is not clean (status exit ' + $st.Code + '): ' + ((@($st.Out) | Select-Object -First 5) -join ' | ')); return $r }
  $hd = Invoke-TcBmGit -Dir $Dir -GitArgs @('rev-parse', 'HEAD')
  if ($hd.Code -ne 0 -or -not [string]::Equals(([string]@($hd.Out)[0]).Trim(), $Sha, [StringComparison]::OrdinalIgnoreCase)) { $r.Why = ('the worktree HEAD is not ' + $Sha + ' after the refresh: ' + $hd.Text); return $r }
  $r.Ok = $true
  return $r
}

function Write-TcBmAllocatorMarker {
  <# The allocator marker, in the worktree's git ADMIN directory (outside the working tree, so it never dirties it),
     naming the worktree's root. Rewritten only when absent or naming anything else. Returns Ok, Why and Path. #>
  param([string]$Dir, [datetime]$NowUtc)
  $gd = Invoke-TcBmGit -Dir $Dir -GitArgs @('rev-parse', '--absolute-git-dir')
  if ($gd.Code -ne 0 -or -not @($gd.Out).Count) { return [pscustomobject]@{ Ok = $false; Why = ('git could not name the git dir: ' + $gd.Text); Path = '' } }
  $path = Join-Path (Get-TcBmFullPath ([string]@($gd.Out)[0])) $script:MarkerName
  $root = Get-TcBmFullPath $Dir
  try {
    if (Test-Path -LiteralPath $path) {
      $old = [IO.File]::ReadAllText($path) | ConvertFrom-Json
      if ($old -and $old.PSObject.Properties['checkout'] -and (Test-TcBmSamePath ([string]$old.checkout) $root)) { return [pscustomobject]@{ Ok = $true; Why = ''; Path = $path } }
    }
  } catch { }
  $body = ([ordered]@{ task = $script:TaskName; checkout = $root; written_utc = $NowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'); writer = 'ops\run-backlog-merge.ps1' } | ConvertTo-Json -Compress)
  try { $null = Write-TcAtomicFile -Path $path -Text $body -NoBom -NoNewline } catch { return [pscustomobject]@{ Ok = $false; Why = ('the marker could not be written: ' + $_.Exception.Message); Path = $path } }
  return [pscustomobject]@{ Ok = $true; Why = ''; Path = $path }
}

function Invoke-TcBmCommit {
  <# Stage exactly $Paths and commit exactly them, with the message in a per-run file. Returns Ok, Why and Sha. The
     commit's own name list is read back and must equal $Paths. #>
  param([string]$Dir, [string[]]$Paths, [string]$Message, [string]$TempRoot)
  $msgDir = Join-Path $TempRoot ('tcbm-msg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path $msgDir -ErrorAction Stop | Out-Null
    $msg = Join-Path $msgDir 'msg.txt'
    [IO.File]::WriteAllText($msg, $Message, (New-Object Text.UTF8Encoding($false)))
    $add = Invoke-TcBmGit -Dir $Dir -GitArgs (@('add', '--') + @($Paths))
    if ($add.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Why = ('git add exited ' + $add.Code + ': ' + $add.Text); Sha = '' } }
    $cm = Invoke-TcBmGit -Dir $Dir -GitArgs (@('commit', '-q', '-F', $msg, '--') + @($Paths))
    if ($cm.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Why = ('git commit exited ' + $cm.Code + ': ' + $cm.Text); Sha = '' } }
    $sh = Invoke-TcBmGit -Dir $Dir -GitArgs @('show', '--no-renames', '--name-only', '--format=', 'HEAD')
    $got = @($sh.Out | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Sort-Object)
    $want = @($Paths | Sort-Object)
    if ($sh.Code -ne 0 -or (($got -join "`n") -cne ($want -join "`n"))) { return [pscustomobject]@{ Ok = $false; Why = ('the commit holds [' + ($got -join ', ') + '], not the ' + $want.Count + ' path(s) staged'); Sha = '' } }
    $hd = Invoke-TcBmGit -Dir $Dir -GitArgs @('rev-parse', 'HEAD')
    return [pscustomobject]@{ Ok = $true; Why = ''; Sha = ([string]@($hd.Out)[0]).Trim() }
  } finally {
    Remove-Item -LiteralPath $msgDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Get-TcBmPendingInbox {
  <# Every pending inbox file at $Ref, with the committer time (epoch s) of the newest commit on $Ref that ADDED it.
     Returns Ok, Why and Rows (Path, Kind, AddedEpoch or $null). #>
  param([string]$Dir, [string]$Ref)
  $ls = Invoke-TcBmGit -Dir $Dir -GitArgs @('-c', 'core.quotePath=false', 'ls-tree', '-r', '--name-only', $Ref, '--', 'design/backlog-inbox')
  if ($ls.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Why = ('git ls-tree ' + $Ref + ' exited ' + $ls.Code + ': ' + $ls.Text); Rows = @() } }
  $pending = @($ls.Out | ForEach-Object { [string]$_ } | Where-Object { Get-TcBmInboxKind $_ })
  $rows = New-Object System.Collections.Generic.List[object]
  if ($pending.Count -eq 0) { return [pscustomobject]@{ Ok = $true; Why = ''; Rows = $rows.ToArray() } }
  $lg = Invoke-TcBmGit -Dir $Dir -GitArgs @('-c', 'core.quotePath=false', 'log', $Ref, '--no-renames', '--diff-filter=A', '--format=tcbm-ct %ct', '--name-only', '--', 'design/backlog-inbox')
  if ($lg.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Why = ('git log ' + $Ref + ' exited ' + $lg.Code + ': ' + $lg.Text); Rows = @() } }
  $added = New-Object 'System.Collections.Generic.Dictionary[string,int64]' ([StringComparer]::Ordinal)
  $ct = $null
  foreach ($l in @($lg.Out)) {
    $s = [string]$l
    $m = [regex]::Match($s, '^tcbm-ct (\d+)$')
    if ($m.Success) { $ct = [int64]$m.Groups[1].Value; continue }
    if ($null -ne $ct -and $s.Trim() -and -not $added.ContainsKey($s)) { $added[$s] = $ct }   # newest first: the first seen is the newest add
  }
  foreach ($p in $pending) {
    $e = $null
    if ($added.ContainsKey($p)) { $e = $added[$p] }
    [void]$rows.Add([pscustomobject]@{ Path = $p; Kind = (Get-TcBmInboxKind $p); AddedEpoch = $e })
  }
  return [pscustomobject]@{ Ok = $true; Why = ''; Rows = $rows.ToArray() }
}

function Get-TcBmLeaseScan {
  <# Push-ledger rows in (SinceUtc, NowUtc] that carry a `lease` field, and the ones whose lease is timeout or error.
     The ledger is one file per day and the day in its name is not UTC, so files a day either side are read and each
     row is windowed by its own UTC `ts`. A missing ledger directory is no pushes recorded, not an error. #>
  param([string]$LedgerRoot, [datetime]$SinceUtc, [datetime]$NowUtc)
  $r = [pscustomobject]@{ Ok = $true; Why = ''; Files = 0; InWindow = 0; WithLease = 0; Undated = 0; Malformed = 0; Timeout = @(); Error = @() }
  if (-not (Test-Path -LiteralPath $LedgerRoot -PathType Container)) { return $r }
  $inv = [Globalization.CultureInfo]::InvariantCulture
  $utc = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
  $to = New-Object System.Collections.Generic.List[object]
  $te = New-Object System.Collections.Generic.List[object]
  try {
    $lo = $SinceUtc.Date.AddDays(-1); $hi = $NowUtc.Date.AddDays(1)
    foreach ($f in @(Get-ChildItem -LiteralPath $LedgerRoot -Filter 'pushes-*.jsonl' -File -ErrorAction Stop)) {
      $m = [regex]::Match($f.Name, '^pushes-(\d{4}-\d{2}-\d{2})\.jsonl$')
      if (-not $m.Success) { continue }
      $day = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd', $inv)
      if ($day -lt $lo -or $day -gt $hi) { continue }
      $r.Files++
      $rows = Read-TcPushRows -Path $f.FullName
      foreach ($row in @($rows)) {
        if ($null -eq $row) { continue }
        if ($row.PSObject.Properties['malformed']) { $r.Malformed++; continue }
        $ts = $null
        if ($row.PSObject.Properties['ts']) {
          $tv = $row.ts
          if ($tv -is [datetime]) { $ts = $tv.ToUniversalTime() }
          else { try { $ts = [datetime]::ParseExact([string]$tv, "yyyy-MM-dd'T'HH:mm:ss'Z'", $inv, $utc) } catch { $ts = $null } }
        }
        if ($null -eq $ts) { $r.Undated++; continue }
        if ($ts -le $SinceUtc -or $ts -gt $NowUtc) { continue }
        $r.InWindow++
        $lp = $row.PSObject.Properties['lease']
        if ($null -eq $lp) { continue }
        $r.WithLease++
        $holder = if ($row.PSObject.Properties['lease_holder']) { [string]$row.lease_holder } else { '' }
        $wait = if ($row.PSObject.Properties['lease_wait_ms']) { [string]$row.lease_wait_ms } else { '' }
        $co = if ($row.PSObject.Properties['checkout']) { [string]$row.checkout } else { '' }
        $text = ('{0} checkout={1} lease_holder={2} lease_wait_ms={3}' -f $ts.ToString('yyyy-MM-ddTHH:mm:ssZ'), $co, $holder, $wait)
        switch -CaseSensitive ([string]$lp.Value) {
          'timeout' { [void]$to.Add($text) }
          'error'   { [void]$te.Add($text) }
          # A DELIBERATE FALLBACK: held, off and every other value W6.1 records are a lease that did its job or was
          # switched off on purpose, which is nothing a person must act on. Only the two outcomes above page.
          default   { }
        }
      }
    }
  } catch { $r.Ok = $false; $r.Why = $_.Exception.Message }
  $r.Timeout = $to.ToArray(); $r.Error = $te.ToArray()
  return $r
}

function Read-TcBmState {
  param([string]$Dir)
  $p = Join-Path $Dir 'state.json'
  try { if (Test-Path -LiteralPath $p) { return ([IO.File]::ReadAllText($p) | ConvertFrom-Json) } } catch { }
  return $null
}

function Write-TcBmState {
  param([string]$Dir, [datetime]$ScannedToUtc)
  if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null }
  $body = ([ordered]@{ lease_scanned_to_utc = $ScannedToUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'); writer = 'ops\run-backlog-merge.ps1' } | ConvertTo-Json -Compress)
  $null = Write-TcAtomicFile -Path (Join-Path $Dir 'state.json') -Text $body -NoBom -NoNewline
}

function Enter-TcBmRunLock {
  <# ZERO wait. The handle, or $null when another run holds it. An abandoned mutex (a killed run) is taken. #>
  param([string]$Name)
  $m = New-Object System.Threading.Mutex($false, $Name)
  $got = $false
  try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) { $m.Dispose(); return $null }
  return $m
}

function Exit-TcBmRunLock {
  param($Handle)
  if ($null -eq $Handle) { return }
  try { $Handle.ReleaseMutex() } catch { }
  $Handle.Dispose()
}

# ---------------------------------------------------------------------------------------------------------- a run

function Invoke-TcBacklogMergeRun {
  <# Everything between the transcript and the stamp, with every external a parameter so the self-test drives this
     against a temp origin, a temp main checkout and stubs. Runners take the directory to run in and return an object
     with ExitCode and Lines. -Pager takes the conditions and a report pointer and returns 0 when the page went out;
     $null means print WOULD PAGE and page nothing. Returns Code, Report, Conditions, Skipped, Deferred, MergeCode,
     Committed, Landed, LanderCalls, MergeCalls, Stale, Lease, PagerRc and StateAdvanced. #>
  param(
    [Parameter(Mandatory = $true)][string]$MainDir,
    [string]$WorktreeDir = '',
    [string]$Remote = 'origin',
    [string]$Branch = 'main',
    [scriptblock]$MergeRunner = $null,
    [scriptblock]$Lander = $null,
    [scriptblock]$DueRunner = $null,
    [scriptblock]$Seeder = $null,
    [scriptblock]$Pager = $null,
    [string]$ReportPointer = '',
    [string]$LedgerRoot = '',
    [string]$StateDir = '',
    [datetime]$NowUtc = [datetime]::UtcNow,
    [datetime]$LocalNow = [datetime]::Now,
    [string]$RunLockName = $script:RunLockName,
    [string]$TempRoot = $env:TEMP
  )
  $res = [pscustomobject]@{
    Code = 3; Report = (New-Object System.Collections.Generic.List[string]); Conditions = (New-Object System.Collections.Generic.List[object])
    Skipped = $false; Deferred = $false; MergeCode = $null; Committed = ''; Landed = $false; LanderCalls = 0; MergeCalls = 0
    Stale = @(); Lease = $null; PagerRc = $null; StateAdvanced = $false; Worktree = ''
  }
  $say = { param([string]$t) [void]$res.Report.Add($t) }
  $cond = { param([string]$Label, [string[]]$Texts, [bool]$Blind) foreach ($t in @($Texts)) { if (([string]$t).Trim()) { [void]$res.Conditions.Add([pscustomobject]@{ Label = $Label; Text = ([string]$t).Trim(); Blind = $Blind }) } } }
  if (-not $LedgerRoot) { $LedgerRoot = Split-Path -Parent (Get-TcPushLedgerPath) }
  if (-not $StateDir) { $StateDir = $script:StateDirDefault }
  if (-not $MergeRunner) { $MergeRunner = { param($d) Invoke-TcBmPsChild -Script (Join-Path $d 'ops\merge-backlog-inbox.ps1') -WorkDir $d -GuardSec $script:MergeGuardSec } }
  if (-not $Lander) { $Lander = { param($d) Invoke-TcBmPsChild -Script (Join-Path $d 'ops\push-main.ps1') -WorkDir $d -GuardSec $script:LandGuardSec } }
  if (-not $DueRunner) { $DueRunner = { param($d) Invoke-TcBmPsChild -Script (Join-Path $d 'ops\probe-push-convergence.ps1') -ScriptArgs @('-Due') -WorkDir $d -GuardSec $script:WatchGuardSec } }
  if (-not $Seeder) { $Seeder = { param($d) Invoke-TcBmPsChild -Script (Join-Path $d 'ops\seed-worktree.ps1') -ScriptArgs @('-Target', $d) -WorkDir $d -GuardSec $script:WatchGuardSec } }

  $lock = Enter-TcBmRunLock -Name $RunLockName
  if (-not $lock) {
    & $say ('backlog-merge: SKIPPED - another run holds {0}, and it is doing this work; this run touched nothing.' -f $RunLockName)
    $res.Skipped = $true; $res.Code = 0
    return $res
  }
  try {
    $mc = Get-TcMainCheckout -Dir $MainDir
    if (-not $mc.ok -or -not $mc.main) {
      & $cond 'RUN BLIND' @(('the main checkout of ' + $MainDir + ' could not be named (' + $mc.note + '), so no worktree could be refreshed and no watch could run')) $true
    } else {
      $main = $mc.main
      $wt = if ($WorktreeDir) { Get-TcBmFullPath $WorktreeDir } else { Join-Path $main ('.claude\worktrees\' + $script:WorktreeLeaf) }
      $res.Worktree = $wt
      $ref = 'refs/remotes/' + $Remote + '/' + $Branch
      & $say ('backlog-merge: main checkout {0}; worktree {1}; {2}/{3}; now {4} UTC' -f $main, $wt, $Remote, $Branch, $NowUtc.ToString('yyyy-MM-ddTHH:mm:ss'))
      $fetched = $false
      $watchDir = $main
      $f = Invoke-TcBmFetch -Dir $main -Remote $Remote
      if ($f.Code -eq 0) { $fetched = $true } else { & $cond 'RUN BLIND' @(('git fetch ' + $Remote + ' exited ' + $f.Code + ': ' + $f.Text + ' - nothing was merged, and the inbox floor was not judged against a ref that may be stale')) $true }
      $sha = ''
      if ($fetched) {
        $rv = Invoke-TcBmGit -Dir $main -GitArgs @('rev-parse', '--verify', '-q', ($ref + '^{commit}'))
        if ($rv.Code -eq 0 -and @($rv.Out).Count) { $sha = ([string]@($rv.Out)[0]).Trim() } else { & $cond 'RUN BLIND' @(($ref + ' does not resolve to a commit in ' + $main)) $true; $fetched = $false }
      }

      if (Test-TcBmBotWindow -LocalNow $LocalNow) {
        $res.Deferred = $true
        & $say ('backlog-merge: DEFERRED - {0} local is inside the ~07:00 bot window ({1:D2}:{2:D2} to {3:D2}:{4:D2}), so nothing is merged or pushed this run; the watches still run. The next scheduled run merges.' -f $LocalNow.ToString('HH:mm:ss'), [int][Math]::Floor($script:BotWindowStartMin / 60), ($script:BotWindowStartMin % 60), [int][Math]::Floor($script:BotWindowEndMin / 60), ($script:BotWindowEndMin % 60))
      } elseif ($sha) {
        $up = Update-TcBmWorktree -MainRoot $main -Dir $wt -Sha $sha
        if (-not $up.Ok) {
          & $cond 'RUN BLIND' @(('the worktree ' + $wt + ' could not be refreshed to ' + $sha + ': ' + $up.Why)) $true
        } else {
          $watchDir = $wt
          & $say ('backlog-merge: worktree {0} at {1}{2}' -f $wt, $sha.Substring(0, 12), $(if ($up.Created) { ' (created)' } else { '' }))
          $mk = Write-TcBmAllocatorMarker -Dir $wt -NowUtc $NowUtc
          if (-not $mk.Ok) {
            & $cond 'RUN BLIND' @(('the allocator marker could not be written, so the merge would not run as the allocator: ' + $mk.Why)) $true
          } else {
            $res.MergeCalls++
            $mr = & $MergeRunner $wt
            $res.MergeCode = [int]$mr.ExitCode
            $mo = Read-TcBmMergeOutput -Lines @($mr.Lines)
            & $say ('backlog-merge: merge exit {0}; {1}' -f $mr.ExitCode, $(if ($mo.Verdict) { $mo.Verdict } else { 'no VERDICT line' }))
            foreach ($l in @($mr.Lines | Select-Object -Last 40)) { & $say ('    merge> ' + $l) }
            $ranThrough = $mo.Complete -and (@(0, 2) -contains [int]$mr.ExitCode) -and -not $mr.TimedOut
            if (-not $ranThrough) {
              $why = if ($mr.TimedOut) { 'the merge was killed by its hang guard' } elseif (-not $mo.Complete) { ('the merge exited ' + $mr.ExitCode + ' without MERGE-BACKLOG-INBOX-COMPLETE as its last line') } else { ('the merge exited ' + $mr.ExitCode + ', which is refused or could-not-evaluate') }
              $tail = @($mr.Lines | Select-Object -Last 8)
              & $cond 'MERGE BLIND' (@($why + '; nothing was committed.') + @($tail | ForEach-Object { 'merge> ' + $_ })) $true
            } else {
              if ([int]$mr.ExitCode -eq 2) { & $cond 'QUARANTINED' (@($mo.Quarantine) + @('Each file is under design\backlog-inbox\quarantine\ or updates\quarantine\ beside a .reason.txt; fix it, move it back and the next run merges it.')) $false }
              $st = Invoke-TcBmGit -Dir $wt -GitArgs @('-c', 'status.renames=false', '--no-optional-locks', 'status', '--porcelain=v1', '-z', '--untracked-files=all')
              if ($st.Code -ne 0) {
                & $cond 'RUN BLIND' @(('git status in the worktree exited ' + $st.Code + ' after the merge: ' + $st.Text + '; nothing was committed')) $true
              } else {
                $changes = ConvertFrom-TcBmPorcelainZ -Raw $st.Raw
                $stray = @(@($changes) | Where-Object { -not (Test-TcBmOwnedPath $_.Path) } | ForEach-Object { $_.Path })
                $paths = @(@($changes) | ForEach-Object { $_.Path } | Sort-Object -Unique)
                if ($stray.Count) {
                  & $cond 'RUN BLIND' @(('the merge left ' + $stray.Count + ' changed path(s) outside the backlog and the inbox, so nothing was committed: ' + ($stray -join ', '))) $true
                } elseif ($paths.Count -eq 0) {
                  & $say 'backlog-merge: the merge changed nothing, so there is nothing to commit or land.'
                } else {
                  $msg = New-TcBmCommitMessage -Verdict $mo.Verdict -Trailer $mo.Trailer -Body @($mr.Lines | Where-Object { ([string]$_) -match '^(MERGING|APPLYING|QUARANTINED|  I\d|  UPDATE|  [^ ].*: )' }) -Stamp $LocalNow.ToString('yyyy-MM-dd HH:mm')
                  $cm = Invoke-TcBmCommit -Dir $wt -Paths $paths -Message $msg -TempRoot $TempRoot
                  if (-not $cm.Ok) {
                    & $cond 'RUN BLIND' @(('the merge could not be committed: ' + $cm.Why)) $true
                  } else {
                    $res.Committed = $cm.Sha
                    & $say ('backlog-merge: committed {0} ({1} path(s)); {2}' -f $cm.Sha.Substring(0, 12), $paths.Count, $(if ($mo.Trailer) { $mo.Trailer } else { 'no trailer: the backlog itself did not change' }))
                    $sd = & $Seeder $wt
                    if ([int]$sd.ExitCode -ne 0) { & $say ('backlog-merge: WARN - seeding the worktree exited {0}; push-main seeds a checkout with no cards itself, and a gate that cannot look says BLIND. {1}' -f $sd.ExitCode, ((@($sd.Lines) | Select-Object -Last 1) -join '')) }
                    $res.LanderCalls++
                    $ld = & $Lander $wt
                    $ldTail = @($ld.Lines | Select-Object -Last 15)
                    foreach ($l in $ldTail) { & $say ('    push-main> ' + $l) }
                    if ([int]$ld.ExitCode -eq 0 -and -not $ld.TimedOut) {
                      $res.Landed = $true
                      & $say 'backlog-merge: LANDED through push-main.'
                    } elseif ([int]$ld.ExitCode -eq 1 -and -not $ld.TimedOut) {
                      & $cond 'PUSH REFUSED' (@('push-main refused the merge commit (exit 1); the next run redoes the merge from origin/main. Its last lines:') + @($ldTail | ForEach-Object { 'push-main> ' + $_ })) $false
                    } else {
                      $why = if ($ld.TimedOut) { 'push-main was killed by its hang guard' } else { ('push-main exited ' + $ld.ExitCode + ', which is could-not-evaluate') }
                      & $cond 'PUSH BLIND' (@($why + '; the next run redoes the merge from origin/main.') + @($ldTail | ForEach-Object { 'push-main> ' + $_ })) $true
                    }
                  }
                }
              }
            }
          }
        }
      }

      # ---- THE WATCHES: read-only, on every path that has a readable ref ----------------------------------------
      $probe = Join-Path $watchDir 'ops\probe-push-convergence.ps1'
      if (-not (Test-Path -LiteralPath $probe)) {
        & $cond 'READ-OUT BLIND' @(('no ops\probe-push-convergence.ps1 in ' + $watchDir + ', so no bar''s read-out date could be checked')) $true
      } else {
        $dr = & $DueRunner $watchDir
        $dl = @($dr.Lines | ForEach-Object { [string]$_ })
        $dDone = ($dl.Count -gt 0) -and ($dl[$dl.Count - 1] -match '^PUSH-CONVERGENCE-DUE-COMPLETE\b')
        & $say ('backlog-merge: -Due exit {0}; {1}' -f $dr.ExitCode, $(if ($dl.Count) { $dl[$dl.Count - 1] } else { 'no output' }))
        if ($dDone -and [int]$dr.ExitCode -eq 0) { }
        elseif ($dDone -and [int]$dr.ExitCode -eq 2) {
          $dueLines = @($dl | Where-Object { $_ -match '^\s+B\d' -and $_ -notmatch 'never due|not due yet' })
          & $cond 'READ-OUT DUE' (@('a bar of design\PLAN-push-derived-conflicts-2026-09-23.md is past its read-out date with no result line in section 13:') + $dueLines) $false
        } else {
          & $cond 'READ-OUT BLIND' (@(('ops\probe-push-convergence.ps1 -Due exited ' + $dr.ExitCode + ' without a verdict it could stand behind')) + @($dl | Select-Object -Last 5)) $true
        }
      }

      $state = Read-TcBmState -Dir $StateDir
      $since = $NowUtc.AddSeconds(-$script:FirstRunLookbackSec)
      $sinceWhy = 'no earlier paging run recorded on this box, so the last 24 hours'
      if ($state -and $state.PSObject.Properties['lease_scanned_to_utc']) {
        try {
          $since = [datetime]::ParseExact([string]$state.lease_scanned_to_utc, "yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
          $sinceWhy = 'since the last paging run'
        } catch { }
      }
      $ls = Get-TcBmLeaseScan -LedgerRoot $LedgerRoot -SinceUtc $since -NowUtc $NowUtc
      $res.Lease = $ls
      if (-not $ls.Ok) {
        & $cond 'LEASE BLIND' @(('the push ledger under ' + $LedgerRoot + ' could not be read: ' + $ls.Why)) $true
      } else {
        $w61 = Invoke-TcBmGit -Dir $watchDir -GitArgs @('cat-file', '-e', ($ref + ':lib/chain-lease.ps1'))
        $landedWord = if ($w61.Code -eq 0) { 'W6.1 has landed (origin/main holds lib\chain-lease.ps1)' } else { 'W6.1 has not landed (origin/main holds no lib\chain-lease.ps1)' }
        if ($ls.WithLease -eq 0) {
          & $say ('backlog-merge: lease: {0} row(s) in {1} ledger file(s) {2} ({3}), and none carries a lease field, so there is nothing to read: {4}. {5} malformed, {6} undated.' -f $ls.InWindow, $ls.Files, $sinceWhy, $since.ToString('yyyy-MM-ddTHH:mm:ssZ'), $landedWord, $ls.Malformed, $ls.Undated)
        } else {
          & $say ('backlog-merge: lease: {0} of {1} row(s) {2} carry a lease field; {3} timeout, {4} error. {5}. {6} malformed, {7} undated.' -f $ls.WithLease, $ls.InWindow, $sinceWhy, @($ls.Timeout).Count, @($ls.Error).Count, $landedWord, $ls.Malformed, $ls.Undated)
        }
        if (@($ls.Timeout).Count) { & $cond 'LEASE TIMEOUT' (@('a chain-lease waiter timed out, which means a wedged or frozen holder (W6.1 step 5):') + @($ls.Timeout)) $false }
        if (@($ls.Error).Count) { & $cond 'LEASE ERROR' (@('a chain lease could not be taken and the push went ahead without it (W6.1 step 4):') + @($ls.Error)) $false }
      }

      if (-not $fetched) {
        & $cond 'STALE INBOX BLIND' @(('the inbox floor was not judged: origin/main could not be fetched this run, and a ref that may be stale would read consumed files as pending')) $true
      } else {
        $f2 = Invoke-TcBmFetch -Dir $main -Remote $Remote
        if ($f2.Code -ne 0) { & $say ('backlog-merge: WARN - the second fetch exited {0}; the floor reads {1} as this run last saw it.' -f $f2.Code, $ref) }
        $pi = Get-TcBmPendingInbox -Dir $watchDir -Ref $ref
        if (-not $pi.Ok) {
          & $cond 'STALE INBOX BLIND' @(('the pending inbox could not be read: ' + $pi.Why)) $true
        } else {
          # Epoch seconds from TICKS: a [datetime]'1970-01-01T00:00:00Z' literal is converted to LOCAL time under PS 5.1.
          $nowEpoch = ConvertTo-TcBmEpoch $NowUtc
          $sv = Get-TcBmStaleInbox -Pending $pi.Rows -NowEpoch $nowEpoch
          $res.Stale = @($sv.Stale)
          & $say ('backlog-merge: inbox: {0} file(s) pending on {1}; {2} older than {3} s, {4} with no add time found.' -f @($pi.Rows).Count, $ref, @($sv.Stale).Count, $script:StaleInboxSec, @($sv.Unknown).Count)
          if (@($sv.Stale).Count) {
            & $cond 'STALE INBOX' (@(('{0} inbox file(s) have waited on origin/main more than 24 hours since the commit that added them, so the scheduled merge or its landing has stopped working:' -f @($sv.Stale).Count)) + @($sv.Stale | ForEach-Object { '{0} ({1}) pending {2:N1} h' -f $_.Path, $_.Kind, ($_.AgeSec / 3600.0) })) $false
          }
          if (@($sv.Unknown).Count) {
            & $cond 'STALE INBOX BLIND' @(('no commit on ' + $ref + ' adds ' + ((@($sv.Unknown | ForEach-Object { $_.Path })) -join ', ') + ', so its age is unknown, and unknown is never young')) $true
          }
        }
      }
    }

    # ---- VERDICT AND PAGES -----------------------------------------------------------------------------------------
    $conds = @($res.Conditions.ToArray())
    $blindN = @($conds | Where-Object { $_.Blind }).Count
    $findN = @($conds | Where-Object { -not $_.Blind }).Count
    $labels = @($conds | ForEach-Object { $_.Label } | Select-Object -Unique)
    foreach ($c in $conds) { & $say ('  {0,-6} {1}: {2}' -f $(if ($c.Blind) { 'BLIND' } else { 'PAGE' }), $c.Label, $c.Text) }
    $pageOk = $true
    if ($null -eq $Pager) {
      if ($conds.Count) { & $say ('backlog-merge: WOULD PAGE {0} condition(s) ({1}); run with -Alert to page, which is what the task does.' -f $labels.Count, ($labels -join ', ')) }
    } elseif ($conds.Count) {
      $rc = 9
      # The LAST value the pager emits is its exit: anything it lets fall into the pipeline before that is ignored.
      try { $po = @(& $Pager $conds $ReportPointer); if ($po.Count) { $rc = [int]$po[$po.Count - 1] } } catch { $rc = 9; & $say ('backlog-merge: the pager threw: ' + $_.Exception.Message) }
      $res.PagerRc = $rc
      if ($rc -ne 0) { $pageOk = $false; & $say ('backlog-merge: THE PAGE DID NOT GO OUT (pager exit {0}). The conditions above are real and unpaged.' -f $rc) }
      else { & $say ('backlog-merge: paged {0} condition(s): {1}' -f $labels.Count, ($labels -join ', ')) }
    } else {
      $res.PagerRc = 0
    }
    if ($null -ne $Pager -and $pageOk -and $null -ne $res.Lease -and $res.Lease.Ok) {
      Write-TcBmState -Dir $StateDir -ScannedToUtc $NowUtc
      $res.StateAdvanced = $true
    }
    $res.Code = if ($blindN -gt 0 -or -not $pageOk) { 3 } elseif ($findN -gt 0) { 2 } else { 0 }
    return $res
  } finally {
    Exit-TcBmRunLock $lock
  }
}

function Write-TcBmStamp {
  <# The heartbeat's `proves` output: written by an -Alert run that reached its verdict, so a run that crashed before
     one leaves no fresh stamp and pages as TASK FAILED. It is gitignored (ops\out\logs\). #>
  param([string]$Path, $Res, [int]$Code, [datetime]$NowUtc)
  $d = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }
  $labels = @()
  if ($null -ne $Res) { $labels = @($Res.Conditions.ToArray() | ForEach-Object { $_.Label } | Select-Object -Unique) }
  $body = [ordered]@{
    finished_utc = $NowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'); exit = $Code; conditions = $labels
    skipped = [bool]($Res -and $Res.Skipped); deferred = [bool]($Res -and $Res.Deferred)
    merge_exit = $(if ($Res) { $Res.MergeCode } else { $null }); committed = $(if ($Res) { $Res.Committed } else { '' })
    landed = [bool]($Res -and $Res.Landed); runner = 'ops\run-backlog-merge.ps1'
  }
  [IO.File]::WriteAllText($Path, ($body | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}

# ======================================================================================================== self-test
if ($SelfTest) {
  $script:stRan = 0
  $script:stFails = New-Object System.Collections.Generic.List[string]
  function _T([string]$Name, [bool]$Ok, $Got = '') {
    $script:stRan++
    if ($Ok) { Write-Output ('  ok    ' + $Name) } else { Write-Output ('  FAIL  ' + $Name + '   got: ' + $Got); [void]$script:stFails.Add($Name) }
  }
  function _Show($R) {
    if ($null -eq $R) { return 'no result' }
    return ('code={0} skipped={1} deferred={2} merge={3} merge_calls={4} committed={5} landed={6} lander_calls={7} conditions=[{8}] :: {9}' -f $R.Code, $R.Skipped, $R.Deferred, $R.MergeCode, $R.MergeCalls, $R.Committed, $R.Landed, $R.LanderCalls,
      ((@($R.Conditions.ToArray() | ForEach-Object { $_.Label + ': ' + $_.Text })) -join ' | '), ((@($R.Report.ToArray()) | Select-Object -Last 12) -join ' / '))
  }
  function _Labels($R) { return @($R.Conditions.ToArray() | ForEach-Object { $_.Label } | Select-Object -Unique) }
  function _Texts($R, [string]$Label) { return ((@($R.Conditions.ToArray() | Where-Object { $_.Label -ceq $Label } | ForEach-Object { $_.Text })) -join "`n") }
  Clear-TcGitRepoEnv
  . (Join-Path $repo 'lib\mutex-hold.ps1')
  $u8 = New-Object Text.UTF8Encoding($false)
  # PER-RUN SCRATCH, removed in the finally (ops-and-gates.md): run-gates runs this from concurrent pushes in one %TEMP%.
  $st = Join-Path $env:TEMP ('tcbm-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $prevBus = $env:TC_EVENT_BUS
  # A PRIVATE run-lock name for every case: no case ever opens Global\tc-backlog-merge-run.
  $lockName = New-TcFixtureMutexName -Prefix 'tcbm-st-run'
  try {
    New-Item -ItemType Directory -Path $st -ErrorAction Stop | Out-Null
    $env:TC_EVENT_BUS = Join-Path $st 'bus.jsonl'

    # ---- THE ABSENCE FLOOR, pure, at the bar and a second past it (binary-exact integer seconds) ------------------
    $pend = @(
      [pscustomobject]@{ Path = 'design/backlog-inbox/updates/a.md'; Kind = 'update'; AddedEpoch = [int64](1000000 - 82800) }
      [pscustomobject]@{ Path = 'design/backlog-inbox/updates/b.md'; Kind = 'update'; AddedEpoch = [int64](1000000 - 86400) }
      [pscustomobject]@{ Path = 'design/backlog-inbox/c.md'; Kind = 'finding'; AddedEpoch = [int64](1000000 - 86401) }
      [pscustomobject]@{ Path = 'design/backlog-inbox/updates/d.md'; Kind = 'update'; AddedEpoch = [int64](1000000 - 90000) }
      [pscustomobject]@{ Path = 'design/backlog-inbox/e.md'; Kind = 'finding'; AddedEpoch = $null }
    )
    $sv = Get-TcBmStaleInbox -Pending $pend -NowEpoch 1000000 -BarSec 86400
    $svPaths = @($sv.Stale | ForEach-Object { $_.Path })
    _T 'MUST NOT FIRE  an UPDATE file 23 h (82,800 s) old is not stale' ($svPaths -notcontains 'design/backlog-inbox/updates/a.md') ($svPaths -join ',')
    _T 'MUST NOT FIRE  at the bar: exactly 24 h (86,400 s) old is not stale, the bar is strictly older' ($svPaths -notcontains 'design/backlog-inbox/updates/b.md') ($svPaths -join ',')
    _T 'MUST FIRE      one second past the bar (86,401 s) is stale' ($svPaths -contains 'design/backlog-inbox/c.md') ($svPaths -join ',')
    _T 'MUST FIRE      an UPDATE file 25 h (90,000 s) old is stale, and the oldest is listed first' (($svPaths.Count -eq 2) -and ($svPaths[0] -eq 'design/backlog-inbox/updates/d.md')) ($svPaths -join ',')
    _T 'MUST FIRE      a pending file with no add time is UNKNOWN, never young' ((@($sv.Unknown).Count -eq 1) -and (@($sv.Unknown)[0].Path -eq 'design/backlog-inbox/e.md')) (@($sv.Unknown).Count)
    _T 'CLEAN TWIN     the production bar is 24 h, 86,400 s' ($script:StaleInboxSec -eq 86400) $script:StaleInboxSec

    # ---- THE BOT WINDOW, pure, at both edges ------------------------------------------------------------------------
    $day = [datetime]'2026-09-24T00:00:00'
    _T 'MUST NOT FIRE  06:29:59 local is outside the bot window' (-not (Test-TcBmBotWindow -LocalNow $day.AddSeconds(23399))) ''
    _T 'MUST FIRE      06:30:00 local, the window''s first second, defers' (Test-TcBmBotWindow -LocalNow $day.AddSeconds(23400)) ''
    _T 'MUST FIRE      07:59:59 local, its last second, defers' (Test-TcBmBotWindow -LocalNow $day.AddSeconds(28799)) ''
    _T 'MUST NOT FIRE  08:00:00 local is outside it again (the end is exclusive)' (-not (Test-TcBmBotWindow -LocalNow $day.AddSeconds(28800))) ''
    _T 'MUST NOT FIRE  the scheduled 11:00 and 17:00 are both outside it' (-not (Test-TcBmBotWindow -LocalNow $day.AddHours(11)) -and -not (Test-TcBmBotWindow -LocalNow $day.AddHours(17))) ''

    # ---- WHAT A MERGE MAY CHANGE, and which inbox files are pending --------------------------------------------------
    _T 'CLEAN TWIN     the backlog and any path under the inbox are the merge''s own' `
      ((Test-TcBmOwnedPath 'design/BACKLOG-course-findings.md') -and (Test-TcBmOwnedPath 'design/backlog-inbox/updates/quarantine/x.md.reason.txt')) ''
    $notOwned = @('design/BACKLOG-course-findings.md.bak', 'design/backlog-inboxes/x.md', 'ops/stray.txt', 'Design/BACKLOG-course-findings.md') | Where-Object { Test-TcBmOwnedPath $_ }
    _T 'MUST FIRE      a sibling name, a prefix trap, another tree and a case variant are NOT the merge''s own' (@($notOwned).Count -eq 0) (@($notOwned) -join ',')
    $kinds = @('design/backlog-inbox/lane.md', 'design/backlog-inbox/updates/u.md', 'design/backlog-inbox/README.md', 'design/backlog-inbox/updates/readme.md',
               'design/backlog-inbox/quarantine/q.md', 'design/backlog-inbox/updates/quarantine/q.md', 'design/backlog-inbox/_parked.md',
               'design/backlog-inbox/quarantine/q.md.reason.txt', 'design/other/x.md') | ForEach-Object { Get-TcBmInboxKind $_ }
    _T 'CLEAN TWIN     pending means a top-level finding file or an UPDATE file, read the way the merge reads its box' `
      ((($kinds[0] -eq 'finding') -and ($kinds[1] -eq 'update') -and (@($kinds | Where-Object { $_ }).Count -eq 2))) ($kinds -join ',')
    $pz = ConvertFrom-TcBmPorcelainZ -Raw ("D  design/backlog-inbox/a.md" + [char]0 + "?? design/backlog-inbox/quarantine/a.md" + [char]0 + " M design/BACKLOG-course-findings.md" + [char]0)
    _T 'CLEAN TWIN     a -z status reads as one code and one path per entry' `
      ((@($pz).Count -eq 3) -and ($pz[0].Path -eq 'design/backlog-inbox/a.md') -and ($pz[1].Code -eq '??') -and ($pz[2].Path -eq 'design/BACKLOG-course-findings.md')) (@($pz | ForEach-Object { $_.Code + '|' + $_.Path }) -join ',')

    # ---- WHAT THE MERGE PRINTED, and the commit message built from it -------------------------------------------------
    $mOut = @('MERGING 1 finding(s) from 1 inbox file(s), ids I41 onward:', '  I41   a finding  <- lane-a.md',
              'QUARANTINED (1 inbox file(s)) - NOT merged, kept on disk, and this run exits non-zero:', '  lane-d.md: in lane-d.md: an invented state',
              '', 'Backlog-Merged-From: lane-a.md', 'VERDICT: merged 1 finding(s) from 1 file(s), applied 0 update(s) from 0 file(s), quarantined 1 file(s). Exit 2.',
              'MERGE-BACKLOG-INBOX-COMPLETE')
    $mo = Read-TcBmMergeOutput -Lines $mOut
    _T 'CLEAN TWIN     the merge''s marker, trailer, verdict and quarantine block are read off its output' `
      ($mo.Complete -and ($mo.Trailer -eq 'Backlog-Merged-From: lane-a.md') -and ($mo.Verdict -like 'VERDICT: merged 1*') -and (@($mo.Quarantine).Count -eq 2)) ("complete={0} trailer={1} q={2}" -f $mo.Complete, $mo.Trailer, @($mo.Quarantine).Count)
    $mo2 = Read-TcBmMergeOutput -Lines @($mOut | Select-Object -First 7)
    _T 'MUST FIRE      output whose last line is not MERGE-BACKLOG-INBOX-COMPLETE is not complete' (-not $mo2.Complete) ''
    $msg = New-TcBmCommitMessage -Verdict $mo.Verdict -Trailer $mo.Trailer -Body @('  I41   a finding  <- lane-a.md') -Stamp '2026-09-23 11:00'
    $paras = @($msg.TrimEnd("`n") -split "`n`n")
    $lastPara = @($paras[$paras.Count - 1] -split "`n")
    _T 'CLEAN TWIN     the commit''s last paragraph is the trailers: the merge''s own line, then Plan-not-applicable' `
      (($lastPara.Count -eq 2) -and ($lastPara[0] -ceq 'Backlog-Merged-From: lane-a.md') -and ($lastPara[1] -like 'Plan-not-applicable: *') -and ($msg -notmatch "`r") -and
       (($msg -split "`n")[0] -like 'Backlog merge by TC Backlog Merge (2026-09-23 11:00): merged 1 finding(s)*quarantined 1 file(s)') -and (($msg -split "`n")[0] -notmatch 'Exit')) $msg

    # ---- THE LEASE ROWS, windowed at the bar, from a frozen ledger file ------------------------------------------------
    $ldg = Join-Path $st 'ledger'
    New-Item -ItemType Directory -Path $ldg -ErrorAction Stop | Out-Null
    $since = [datetime]::SpecifyKind([datetime]'2026-09-23T10:00:00', [DateTimeKind]::Utc)
    $nowL = [datetime]::SpecifyKind([datetime]'2026-09-23T12:00:00', [DateTimeKind]::Utc)
    $rowsL = @(
      '{"ts":"2026-09-23T10:00:00Z","event":"push-main","checkout":"C:\\a","lease":"timeout","lease_holder":"pid 1"}',
      '{"ts":"2026-09-23T10:00:01Z","event":"push-main","checkout":"C:\\b","lease":"timeout","lease_holder":"pid 2","lease_wait_ms":3600000}',
      '{"ts":"2026-09-23T11:00:00Z","event":"push-main","checkout":"C:\\c","lease":"held"}',
      '{"ts":"2026-09-23T11:30:00Z","event":"push-main","checkout":"C:\\d"}',
      'this line is not json',
      '{"ts":"2026-09-23T12:00:01Z","event":"push-main","checkout":"C:\\e","lease":"error"}'
    )
    [IO.File]::WriteAllText((Join-Path $ldg 'pushes-2026-09-23.jsonl'), (($rowsL -join "`n") + "`n"), $u8)
    $lsc = Get-TcBmLeaseScan -LedgerRoot $ldg -SinceUtc $since -NowUtc $nowL
    _T 'MUST FIRE      a lease=timeout row one second past the last run is read, and names its holder' ((@($lsc.Timeout).Count -eq 1) -and (@($lsc.Timeout)[0] -like '*pid 2*')) (@($lsc.Timeout) -join ' | ')
    _T 'MUST NOT FIRE  a row AT the last run''s position was read by that run, and a row after now is not yet in the window' ((@($lsc.Timeout) -join ' ') -notlike '*pid 1*' -and @($lsc.Error).Count -eq 0) ((@($lsc.Timeout) + @($lsc.Error)) -join ' | ')
    _T 'CLEAN TWIN     the window counts: 3 rows in it, 2 carrying a lease field, 1 malformed line' `
      (($lsc.InWindow -eq 3) -and ($lsc.WithLease -eq 2) -and ($lsc.Malformed -eq 1) -and $lsc.Ok) ("in={0} lease={1} malformed={2}" -f $lsc.InWindow, $lsc.WithLease, $lsc.Malformed)
    $lsNone = Get-TcBmLeaseScan -LedgerRoot (Join-Path $st 'no-ledger-here') -SinceUtc $since -NowUtc $nowL
    _T 'MUST NOT FIRE  no ledger directory is no pushes recorded, not a failure' ($lsNone.Ok -and ($lsNone.Files -eq 0) -and ($lsNone.InWindow -eq 0)) $lsNone.Why

    # ---- END TO END: a bare origin, a clone standing in for the main checkout, and the task's own worktree ------------
    $origin = Join-Path $st 'o.git'
    $mainD = Join-Path $st 'm'
    $wtD = Join-Path $st 'w'
    $g1 = Invoke-TcBmGit -Dir $st -GitArgs @('init', '-q', '--bare', $origin)
    $g2 = Invoke-TcBmGit -Dir $origin -GitArgs @('symbolic-ref', 'HEAD', 'refs/heads/main')
    $g3 = Invoke-TcBmGit -Dir $st -GitArgs @('init', '-q', $mainD)
    if (($g1.Code -ne 0) -or ($g2.Code -ne 0) -or ($g3.Code -ne 0)) { throw ('the fixture repositories could not be built: ' + $g1.Text + ' ' + $g2.Text + ' ' + $g3.Text) }
    foreach ($cfg in @(@('user.name', 'tcbm-selftest'), @('user.email', 'tcbm@selftest.invalid'), @('commit.gpgsign', 'false'))) {
      $null = Invoke-TcBmGit -Dir $mainD -GitArgs @('config', $cfg[0], $cfg[1])
    }
    $null = Invoke-TcBmGit -Dir $mainD -GitArgs @('symbolic-ref', 'HEAD', 'refs/heads/main')
    $null = Invoke-TcBmGit -Dir $mainD -GitArgs @('remote', 'add', 'origin', $origin)
    # THE REAL MERGE, the gate it runs and every library they load, copied in: the task drives the merge as it ships.
    foreach ($sub in @('ops', 'lib', 'design\backlog-inbox')) { New-Item -ItemType Directory -Path (Join-Path $mainD $sub) -Force -ErrorAction Stop | Out-Null }
    Copy-Item -LiteralPath (Join-Path $repo 'ops\merge-backlog-inbox.ps1') -Destination (Join-Path $mainD 'ops') -ErrorAction Stop
    Copy-Item -LiteralPath (Join-Path $repo 'ops\audit-backlog-status.ps1') -Destination (Join-Path $mainD 'ops') -ErrorAction Stop
    # lib\chain-lease.ps1 is left out on purpose, so the fixture is always a tree W6.1 has not landed in.
    foreach ($lf in @(Get-ChildItem -LiteralPath (Join-Path $repo 'lib') -Filter '*.ps1' -File | Where-Object { $_.Name -ne 'chain-lease.ps1' })) { Copy-Item -LiteralPath $lf.FullName -Destination (Join-Path $mainD 'lib') -ErrorAction Stop }
    Copy-Item -LiteralPath (Join-Path $repo '.gitattributes') -Destination $mainD -ErrorAction Stop
    [IO.File]::WriteAllText((Join-Path $mainD 'ops\probe-push-convergence.ps1'), "# a placeholder: every case passes its own -Due runner`n", $u8)
    [IO.File]::WriteAllText((Join-Path $mainD 'design\backlog-inbox\README.md'), "# backlog-inbox`n`nfixture.`n", $u8)
    $seedB = "# Backlog`n`n### I40 - an old one ``DONE```n`nI40 body.`n"
    [IO.File]::WriteAllText((Join-Path $mainD 'design\BACKLOG-course-findings.md'), $seedB, $u8)
    $null = Invoke-TcBmGit -Dir $mainD -GitArgs @('add', '--', '.gitattributes', 'ops', 'lib', 'design')
    $gc = Invoke-TcBmGit -Dir $mainD -GitArgs @('commit', '-q', '-m', 'fixture base')
    $gp = Invoke-TcBmGit -Dir $mainD -GitArgs @('push', '-q', 'origin', 'HEAD:refs/heads/main')
    $gf = Invoke-TcBmGit -Dir $mainD -GitArgs @('fetch', '-q', 'origin')
    if (($gc.Code -ne 0) -or ($gp.Code -ne 0) -or ($gf.Code -ne 0)) { throw ('the fixture base could not be committed and pushed: ' + $gc.Text + ' ' + $gp.Text + ' ' + $gf.Text) }

    function _Land([hashtable]$Files, [string]$Message, [int64]$CommitterEpoch = 0) {
      # A lane landing inbox files on origin: the fixture main checkout brought to origin/main, the files written, committed
      # (at a given committer time when one is asked for) and pushed. It is the fixture's main checkout, so resetting it is fine.
      $null = Invoke-TcBmGit -Dir $script:mainD -GitArgs @('fetch', '-q', 'origin')
      $null = Invoke-TcBmGit -Dir $script:mainD -GitArgs @('reset', '-q', '--hard', 'origin/main')
      $rels = @()
      foreach ($k in @($Files.Keys)) {
        $full = Join-Path $script:mainD ([string]$k).Replace('/', '\')
        $pd = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $pd)) { New-Item -ItemType Directory -Path $pd -Force | Out-Null }
        [IO.File]::WriteAllText($full, [string]$Files[$k], $script:u8)
        $rels += [string]$k
      }
      $envC = @{}
      if ($CommitterEpoch -gt 0) { $envC = @{ GIT_COMMITTER_DATE = ('@' + $CommitterEpoch + ' +0000'); GIT_AUTHOR_DATE = ('@' + $CommitterEpoch + ' +0000') } }
      $a = Invoke-TcBmGit -Dir $script:mainD -GitArgs (@('add', '--') + $rels)
      $c = Invoke-TcBmGit -Dir $script:mainD -GitArgs @('commit', '-q', '-m', $Message) -Env $envC
      $p = Invoke-TcBmGit -Dir $script:mainD -GitArgs @('push', '-q', 'origin', 'HEAD:refs/heads/main')
      if (($a.Code -ne 0) -or ($c.Code -ne 0) -or ($p.Code -ne 0)) { throw ('a fixture landing failed: ' + $a.Text + ' ' + $c.Text + ' ' + $p.Text) }
      $null = Invoke-TcBmGit -Dir $script:mainD -GitArgs @('fetch', '-q', 'origin')
    }
    function _OriginShow([string]$What) { return (Invoke-TcBmGit -Dir $script:mainD -GitArgs @('show', ('refs/remotes/origin/main' + $What))) }
    function _OriginTip() { $t = Invoke-TcBmGit -Dir $script:mainD -GitArgs @('rev-parse', 'refs/remotes/origin/main'); return ([string]@($t.Out)[0]).Trim() }

    $script:pagedCalls = 0; $script:pagerRc = 0
    $script:paged = New-Object System.Collections.Generic.List[object]
    $pager = { param($c, $ptr) $script:pagedCalls++; foreach ($x in @($c)) { [void]$script:paged.Add($x) }; return $script:pagerRc }
    $landOk = { param($d)
      $g = Invoke-TcBmGit -Dir $d -GitArgs @('push', '-q', 'origin', 'HEAD:refs/heads/main')
      return [pscustomobject]@{ ExitCode = $(if ($g.Code -eq 0) { 0 } else { 1 }); Lines = @('stub lander: git push exited ' + $g.Code + ' ' + $g.Text); TimedOut = $false } }
    $landNo = { param($d) return [pscustomobject]@{ ExitCode = 1; Lines = @('push-main: REFUSED - a stub refusal'); TimedOut = $false } }
    $dueOk = { param($d) return [pscustomobject]@{ ExitCode = 0; Lines = @('PUSH-CONVERGENCE-DUE-COMPLETE bars=0 landed=0 due=0 missing=0') } }
    $dueTwo = { param($d) return [pscustomobject]@{ ExitCode = 2; Lines = @('push convergence bars at now', '  B4   W3.1: landed x at y; read-out 2026-09-30; DUE and has no result line', '  B6   W6.1: NOT LANDED (no Plan line), so never due', 'PUSH-CONVERGENCE-DUE-COMPLETE bars=2 landed=1 due=1 missing=1') } }
    $seedOk = { param($d) return [pscustomobject]@{ ExitCode = 0; Lines = @('SEED-WORKTREE-COMPLETE stub') } }
    $stateD = Join-Path $st 'state'
    $emptyLedger = Join-Path $st 'ledger-empty'
    New-Item -ItemType Directory -Path $emptyLedger -ErrorAction Stop | Out-Null
    $noon = [datetime]::Today.AddHours(12)
    $script:common = @{ MainDir = $mainD; WorktreeDir = $wtD; DueRunner = $dueOk; Seeder = $seedOk; LedgerRoot = $emptyLedger; StateDir = $stateD; LocalNow = $noon; RunLockName = $lockName; TempRoot = $st; Lander = $landOk; Pager = $pager }
    # One run with the common seams, each case overriding only what it is about (a splat and a named argument for the
    # same parameter would not bind).
    function _Run([hashtable]$Over = @{}) { $h = $script:common.Clone(); foreach ($k in @($Over.Keys)) { $h[$k] = $Over[$k] }; return (Invoke-TcBacklogMergeRun @h) }

    # CLEAN TWIN: an empty inbox. The worktree is created at origin/main and marked, the real merge finds nothing,
    # nothing lands, and the run exits 0.
    $e1 = _Run
    $wtHead = ([string]@((Invoke-TcBmGit -Dir $wtD -GitArgs @('rev-parse', 'HEAD')).Out)[0]).Trim()
    $wtGd = Get-TcBmFullPath ([string]@((Invoke-TcBmGit -Dir $wtD -GitArgs @('rev-parse', '--absolute-git-dir')).Out)[0])
    $mkPath = Join-Path $wtGd ('tc-backlog-' + 'allocator')
    $mkOk = (Test-Path -LiteralPath $mkPath) -and ((([IO.File]::ReadAllText($mkPath)) | ConvertFrom-Json).checkout -eq (Get-TcBmFullPath $wtD))
    _T 'CLEAN TWIN     an empty inbox: exit 0, the worktree created at origin/main and marked as the allocator, the merge ran, nothing landed' `
      (($e1.Code -eq 0) -and ($e1.MergeCode -eq 0) -and ($e1.LanderCalls -eq 0) -and ($wtHead -eq (_OriginTip)) -and $mkOk -and ($script:pagedCalls -eq 0) -and
       (($e1.Report -join "`n") -match 'W6\.1 has not landed')) ((_Show $e1) + ' marker=' + $mkOk)

    # CLEAN TWIN: a finding lands on origin. The REAL merge in the worktree mints I41 as the allocator, the commit holds
    # exactly the two paths it changed with the merge's trailer, and the lander lands it.
    _Land @{ 'design/backlog-inbox/lane-e2.md' = "## e2 finding`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`ne2 body.`n" } 'lane e2 files a finding'
    $e2 = _Run
    $msgE2 = [string]((Invoke-TcBmGit -Dir $mainD -GitArgs @('log', '-1', '--format=%B', 'refs/remotes/origin/main')).Raw)
    $namesE2 = @((Invoke-TcBmGit -Dir $mainD -GitArgs @('show', '--no-renames', '--name-only', '--format=', 'refs/remotes/origin/main')).Out | Sort-Object)
    $blE2 = [string]((_OriginShow ':design/BACKLOG-course-findings.md').Raw)
    _T 'CLEAN TWIN     a landed finding is merged by the allocator, committed with its trailer as exactly the two paths it changed, and landed' `
      (($e2.Code -eq 0) -and $e2.Landed -and ($e2.LanderCalls -eq 1) -and ($msgE2 -match '(?m)^Backlog-Merged-From: lane-e2\.md\s*$') -and ($msgE2 -match '(?m)^Plan-not-applicable: ') -and
       (($namesE2 -join ',') -ceq 'design/BACKLOG-course-findings.md,design/backlog-inbox/lane-e2.md') -and ($blE2 -match '(?m)^### I41 - e2 finding `OPEN`')) ((_Show $e2) + ' names=' + ($namesE2 -join ','))

    # MUST FIRE, the other direction of the marker: while this task's marker is live, the fixture MAIN checkout's own copy of
    # the merge refuses a hand merge. The task and the merge agree on the marker, both ways.
    $null = Invoke-TcBmGit -Dir $mainD -GitArgs @('reset', '-q', '--hard', 'refs/remotes/origin/main')
    [IO.File]::WriteAllText((Join-Path $mainD 'design\backlog-inbox\lane-hand.md'), "## a hand merge`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody.`n", $u8)
    $blBefore = [IO.File]::ReadAllText((Join-Path $mainD 'design\BACKLOG-course-findings.md'))
    $hm = Invoke-TcBmPsChild -Script (Join-Path $mainD 'ops\merge-backlog-inbox.ps1') -WorkDir $mainD -GuardSec 300
    $hmOut = @($hm.Lines) -join "`n"
    _T 'MUST FIRE      with the task''s marker live, a merge in the main checkout is REFUSED (exit 1) naming the task''s worktree, nothing written' `
      (($hm.ExitCode -eq 1) -and ($hmOut -match 'REFUSED') -and ($hmOut -match [regex]::Escape((Get-TcBmFullPath $wtD))) -and
       ([string]::Equals([IO.File]::ReadAllText((Join-Path $mainD 'design\BACKLOG-course-findings.md')), $blBefore, [StringComparison]::Ordinal)) -and
       (Test-Path -LiteralPath (Join-Path $mainD 'design\backlog-inbox\lane-hand.md'))) ("exit {0} :: {1}" -f $hm.ExitCode, $hmOut)
    Remove-Item -LiteralPath (Join-Path $mainD 'design\backlog-inbox\lane-hand.md') -Force

    # MUST FIRE: a merge exit 2 pages. A malformed file is quarantined by the real merge, the move is committed and landed,
    # and QUARANTINED is paged naming the file.
    _Land @{ 'design/backlog-inbox/lane-bad.md' = "## a bad one`n``SHIPPED`` ``queue-7```n`nbody.`n" } 'lane bad files a malformed finding'
    $script:pagedCalls = 0; $script:paged.Clear()
    $e3 = _Run
    $namesE3 = @((Invoke-TcBmGit -Dir $mainD -GitArgs @('show', '--no-renames', '--name-only', '--format=', 'refs/remotes/origin/main')).Out | Sort-Object)
    _T 'MUST FIRE      a merge exit 2 pages QUARANTINED naming the file, and the move into quarantine is committed and landed' `
      (($e3.Code -eq 2) -and ($e3.MergeCode -eq 2) -and ($script:pagedCalls -eq 1) -and (@($script:paged | Where-Object { $_.Label -ceq 'QUARANTINED' -and $_.Text -match 'lane-bad\.md' }).Count -ge 1) -and
       $e3.Landed -and ($namesE3 -contains 'design/backlog-inbox/lane-bad.md') -and ($namesE3 -contains 'design/backlog-inbox/quarantine/lane-bad.md') -and
       ($namesE3 -contains 'design/backlog-inbox/quarantine/lane-bad.md.reason.txt')) ((_Show $e3) + ' names=' + ($namesE3 -join ','))

    # MUST FIRE: a refused push pages PUSH REFUSED; the commit stays local and origin still holds the file.
    _Land @{ 'design/backlog-inbox/lane-e4.md' = "## e4 finding`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`ne4 body.`n" } 'lane e4 files a finding'
    $script:pagedCalls = 0; $script:paged.Clear()
    $e4 = _Run @{ Lander = $landNo }
    $e4Pending = @((Invoke-TcBmGit -Dir $mainD -GitArgs @('ls-tree', '-r', '--name-only', 'refs/remotes/origin/main', '--', 'design/backlog-inbox')).Out)
    _T 'MUST FIRE      a push-main refusal pages PUSH REFUSED, the merge commit stays local, and origin still holds the drop file' `
      (($e4.Code -eq 2) -and $e4.Committed -and -not $e4.Landed -and (@($script:paged | Where-Object { $_.Label -ceq 'PUSH REFUSED' }).Count -ge 1) -and
       ($e4Pending -contains 'design/backlog-inbox/lane-e4.md')) ((_Show $e4) + ' pending=' + ($e4Pending -join ','))

    # CLEAN TWIN: the next run throws the refused commit away with the refresh, re-merges from origin/main and lands it,
    # and the finding is in the backlog exactly once.
    $e4b = _Run
    $blE4 = [string]((_OriginShow ':design/BACKLOG-course-findings.md').Raw)
    $e4Count = ([regex]::Matches($blE4, '(?m)^### I\d+ - e4 finding ')).Count
    _T 'CLEAN TWIN     after a refused push the next run redoes the merge from origin/main and lands it, the finding in the backlog exactly once' `
      (($e4b.Code -eq 0) -and $e4b.Landed -and ($e4Count -eq 1)) ((_Show $e4b) + (' e4 headings={0}' -f $e4Count))

    # MUST FIRE: a -Due exit 2 is READ-OUT DUE. CLEAN TWIN: with no pager (a hand run) it is printed WOULD PAGE, nothing is
    # paged and the lease position does not move.
    $script:pagedCalls = 0
    $e6 = _Run @{ Pager = $null; DueRunner = $dueTwo }
    _T 'MUST FIRE      a -Due exit 2 is READ-OUT DUE, naming the bar that is due and not the ones never due' `
      (($e6.Code -eq 2) -and ((_Texts $e6 'READ-OUT DUE') -match 'B4 ') -and ((_Texts $e6 'READ-OUT DUE') -notmatch 'B6 ')) (_Show $e6)
    _T 'CLEAN TWIN     a run with no pager prints WOULD PAGE, pages nothing, and leaves the lease position where it was' `
      ((($e6.Report -join "`n") -match 'WOULD PAGE 1 condition') -and ($script:pagedCalls -eq 0) -and -not $e6.StateAdvanced) (_Show $e6)

    # MUST FIRE: lease rows since the last paging run page, and that run's position moves to now.
    $ldgE = Join-Path $st 'ledger-e2e'
    New-Item -ItemType Directory -Path $ldgE -ErrorAction Stop | Out-Null
    $nowE = [datetime]::UtcNow
    $fmt = 'yyyy-MM-ddTHH:mm:ssZ'
    $rowsE = @(
      ('{"ts":"' + $nowE.AddMinutes(-30).ToString($fmt) + '","event":"push-main","checkout":"C:\\x","lease":"timeout","lease_holder":"pid 30"}'),
      ('{"ts":"' + $nowE.AddHours(-5).ToString($fmt) + '","event":"push-main","checkout":"C:\\y","lease":"timeout","lease_holder":"pid 300"}'),
      ('{"ts":"' + $nowE.AddMinutes(-10).ToString($fmt) + '","event":"push-main","checkout":"C:\\z","lease":"error"}')
    )
    [IO.File]::WriteAllText((Join-Path $ldgE ('pushes-' + $nowE.ToString('yyyy-MM-dd') + '.jsonl')), (($rowsE -join "`n") + "`n"), $u8)
    Write-TcBmState -Dir $stateD -ScannedToUtc $nowE.AddHours(-2)
    $stateBefore = [IO.File]::ReadAllText((Join-Path $stateD 'state.json'))
    $script:pagedCalls = 0; $script:paged.Clear(); $script:pagerRc = 9
    $e7b = _Run @{ LedgerRoot = $ldgE; NowUtc = $nowE }
    _T 'MUST FIRE      a page that did not go out is exit 3, and the lease position is NOT moved, so the next run pages the rows again' `
      (($e7b.Code -eq 3) -and ($e7b.PagerRc -eq 9) -and -not $e7b.StateAdvanced -and ([IO.File]::ReadAllText((Join-Path $stateD 'state.json')) -ceq $stateBefore)) (_Show $e7b)
    $script:pagedCalls = 0; $script:paged.Clear(); $script:pagerRc = 0
    $e7 = _Run @{ LedgerRoot = $ldgE; NowUtc = $nowE }
    $toText = _Texts $e7 'LEASE TIMEOUT'
    $lb7 = _Labels $e7
    $st7 = Read-TcBmState -Dir $stateD
    _T 'MUST FIRE      a lease=timeout and a lease=error row since the last paging run page LEASE TIMEOUT and LEASE ERROR' `
      (($e7.Code -eq 2) -and ($toText -match 'pid 30\b') -and (@($lb7) -contains 'LEASE ERROR') -and ($script:pagedCalls -eq 1)) (_Show $e7)
    _T 'MUST NOT FIRE  a lease=timeout row from before the last paging run is not paged again' ($toText -notmatch 'pid 300') $toText
    _T 'CLEAN TWIN     a page that went out moves the lease position to this run''s now' `
      ($e7.StateAdvanced -and ([string]$st7.lease_scanned_to_utc -eq $nowE.ToString($fmt))) ([string]$st7.lease_scanned_to_utc)

    # MUST FIRE, the one this file most needs: never the main checkout. Pointed at it, the run refuses before any reset,
    # and a dirty tracked file and an untracked file there survive byte for byte.
    $null = Invoke-TcBmGit -Dir $mainD -GitArgs @('reset', '-q', '--hard', 'refs/remotes/origin/main')
    $dirtyP = Join-Path $mainD 'design\BACKLOG-course-findings.md'
    $dirtyT = [IO.File]::ReadAllText($dirtyP) + "another session's uncommitted line`n"
    [IO.File]::WriteAllText($dirtyP, $dirtyT, $u8)
    [IO.File]::WriteAllText((Join-Path $mainD 'untracked-work.txt'), "somebody's work`n", $u8)
    $e8 = _Run @{ WorktreeDir = $mainD }
    _T 'MUST FIRE      pointed at the MAIN checkout it refuses before any reset: RUN BLIND, exit 3, the merge never ran, dirty work intact' `
      (($e8.Code -eq 3) -and ($e8.MergeCalls -eq 0) -and ((_Texts $e8 'RUN BLIND') -match 'IS the main checkout') -and
       ([IO.File]::ReadAllText($dirtyP) -ceq $dirtyT) -and (Test-Path -LiteralPath (Join-Path $mainD 'untracked-work.txt'))) (_Show $e8)
    $null = Invoke-TcBmGit -Dir $mainD -GitArgs @('reset', '-q', '--hard', 'refs/remotes/origin/main')
    Remove-Item -LiteralPath (Join-Path $mainD 'untracked-work.txt') -Force -ErrorAction SilentlyContinue   # tolerant BY RULE: a red case above must not cost the cases after it

    # MUST FIRE: the run lock, held by ANOTHER PROCESS (lib\mutex-hold.ps1, a fixture name). The run SKIPS, touches nothing
    # (a worktree path that does not exist is not created) and exits 0.
    $holdName = New-TcFixtureMutexName -Prefix 'tcbm-st-hold'
    $hold = Start-TcMutexHold -Name $holdName
    $freshWt = Join-Path $st 'w-never'
    $e9 = _Run @{ WorktreeDir = $freshWt; RunLockName = $holdName }
    Stop-TcMutexHold -Hold $hold
    _T 'MUST FIRE      while another process holds the run lock the run SKIPS: exit 0, the merge never ran, no worktree created' `
      ($hold.Held -and $e9.Skipped -and ($e9.Code -eq 0) -and ($e9.MergeCalls -eq 0) -and -not (Test-Path -LiteralPath $freshWt)) ((_Show $e9) + ' held=' + $hold.Held + ' ' + $hold.Detail)

    # MUST FIRE: a merge that changes a path outside the backlog and the inbox commits NOTHING. It runs under the lock name
    # the holder above just let go, so this case is also the CLEAN TWIN that a released lock is taken.
    $strayMerge = { param($d)
      [IO.File]::WriteAllText((Join-Path $d 'ops\stray.txt'), "written by a merge that should not`n", (New-Object Text.UTF8Encoding($false)))
      return [pscustomobject]@{ ExitCode = 0; Lines = @('VERDICT: merged 0 finding(s) from 0 file(s), applied 0 update(s) from 0 file(s), quarantined 0 file(s). Exit 0.', 'MERGE-BACKLOG-INBOX-COMPLETE'); TimedOut = $false } }
    $tipBefore = _OriginTip
    $e10 = _Run @{ MergeRunner = $strayMerge; RunLockName = $holdName }
    _T 'MUST FIRE      a merge that wrote outside the backlog and the inbox: RUN BLIND naming the path, nothing committed or landed, lock taken once released' `
      (($e10.Code -eq 3) -and -not $e10.Skipped -and -not $e10.Committed -and ($e10.LanderCalls -eq 0) -and ((_Texts $e10 'RUN BLIND') -match 'ops/stray\.txt') -and ((_OriginTip) -eq $tipBefore)) (_Show $e10)

    # MUST FIRE: a merge that exits 3 is MERGE BLIND and nothing is committed. CLEAN TWIN: the refresh first removed the
    # untracked file the case above left in the worktree.
    $blindMerge = { param($d) return [pscustomobject]@{ ExitCode = 3; Lines = @('COULD NOT EVALUATE - a stub', 'MERGE-BACKLOG-INBOX-COMPLETE'); TimedOut = $false } }
    $e11 = _Run @{ MergeRunner = $blindMerge }
    $lb11 = _Labels $e11
    _T 'MUST FIRE      a merge exit 3 is MERGE BLIND, exit 3, and nothing is committed or landed' `
      (($e11.Code -eq 3) -and (@($lb11) -contains 'MERGE BLIND') -and -not $e11.Committed -and ($e11.LanderCalls -eq 0)) (_Show $e11)
    _T 'CLEAN TWIN     the refresh removed the untracked leftover of the previous run before the merge ran' `
      ((-not (Test-Path -LiteralPath (Join-Path $wtD 'ops\stray.txt'))) -and ($e11.MergeCalls -eq 1)) (_Show $e11)

    # THE ABSENCE FLOOR END TO END, inside the bot window so nothing merges them: an UPDATE file added 25 h before "now"
    # pages STALE INBOX and one added 23 h before does not, each aged from its own commit on origin/main.
    $nowS = [datetime]::UtcNow
    $epS = ConvertTo-TcBmEpoch $nowS
    _Land @{ 'design/backlog-inbox/updates/lane-old.md' = "## UPDATE I40`n``DONE`` ``queue-7```n`nold.`n" } 'lane old files an update' ($epS - 90000)
    _Land @{ 'design/backlog-inbox/updates/lane-new.md' = "## UPDATE I40`n``DONE`` ``queue-7```n`nnew.`n" } 'lane new files an update' ($epS - 82800)
    # An edit to the old file an hour ago does not restart its clock: it is aged from the commit that ADDED it.
    _Land @{ 'design/backlog-inbox/updates/lane-old.md' = "## UPDATE I40`n``DONE`` ``queue-7```n`nold, edited.`n" } 'lane old edits its update' ($epS - 3600)
    $script:pagedCalls = 0; $script:paged.Clear()
    $e5 = _Run @{ NowUtc = $nowS; LocalNow = ([datetime]::Today.AddHours(7)) }
    $staleT = _Texts $e5 'STALE INBOX'
    _T 'MUST FIRE      an UPDATE file added 25 h before now (and edited 1 h ago) pages STALE INBOX by name; inside the bot window nothing merged' `
      ($e5.Deferred -and ($e5.MergeCalls -eq 0) -and ($e5.LanderCalls -eq 0) -and ($staleT -match 'updates/lane-old\.md \(update\) pending 25\.0 h') -and ($e5.Code -eq 2)) (_Show $e5)
    _T 'MUST NOT FIRE  an UPDATE file added 23 h before now does not' ($staleT -notmatch 'lane-new') $staleT

    # ---- EVERY CONDITION THIS TASK PAGES IS REGISTERED (2026-09-24, design\backlog-inbox\pd-backlog2-2026-09-23.md) ----
    # Its twelve alert types and its digest had no entry, so the first page would have arrived as UNREGISTERED ALERT TYPE
    # and the daily alert-registry lane gone red, and audit-alert-registry's source half does not follow
    # Send-AlertConditions, so no push gate could see it. The labels are read off this file's parse tree (every call of
    # the condition collector with a literal first argument), then resolved through the real registry and matcher.
    . (Join-Path $repo 'grocery\alert-registry-lib.ps1')
    $regRead = Read-AlertRegistry (Join-Path $repo 'grocery\alert-registry.json')
    $bmTok = $null; $bmErr = $null
    $bmAst = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$bmTok, [ref]$bmErr)
    $bmCondVar = 'co' + 'nd'
    $bmCalls = $bmAst.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and $n.InvocationOperator -eq 'Ampersand' -and
        ($n.CommandElements[0] -is [System.Management.Automation.Language.VariableExpressionAst]) -and [string]::Equals($n.CommandElements[0].VariablePath.UserPath, $bmCondVar, [StringComparison]::Ordinal) -and
        $n.CommandElements.Count -ge 2 -and ($n.CommandElements[1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) }.GetNewClosure(), $true)
    $bmLabels = @($bmCalls | ForEach-Object { [string]$_.CommandElements[1].Value } | Sort-Object -Unique)
    $bmWant = @('LEASE BLIND', 'LEASE ERROR', 'LEASE TIMEOUT', 'MERGE BLIND', 'PUSH BLIND', 'PUSH REFUSED', 'QUARANTINED', 'READ-OUT BLIND', 'READ-OUT DUE', 'RUN BLIND', 'STALE INBOX', 'STALE INBOX BLIND')
    _T 'CLEAN TWIN     the conditions read off this file are exactly the twelve its header names' ($regRead.ok -and ((@($bmLabels) -join '|') -ceq (@($bmWant) -join '|'))) ((@($bmLabels) -join '|') + ' registry=' + $regRead.why)
    $bmBad = @()
    foreach ($lb in $bmLabels) {
      $rc0 = Resolve-AlertClass $regRead.registry (Get-AlertTypeKey ($script:SubjectPrefix + ': ' + $lb))
      if (-not $rc0.registered -or $rc0.ambiguous -or $rc0.class -ne 'page' -or [string]$rc0.entry.match -ne 'exact' -or (Get-AlertResolverKind (Get-AlertEntryResolver $rc0.entry)) -ne 'lane') { $bmBad += ($lb + '=' + $rc0.why + '/' + $rc0.class) }
    }
    $rcD = Resolve-AlertClass $regRead.registry (Get-AlertTypeKey ($script:SubjectPrefix + ': 3 condition(s) need action'))
    _T 'MUST FIRE      every condition this task pages resolves to exactly one registered page entry with a lane resolver, and its digest to a digest entry' `
      ($bmLabels.Count -eq 12 -and $bmBad.Count -eq 0 -and $rcD.registered -and -not $rcD.ambiguous -and $rcD.class -eq 'digest') ('bad=' + ($bmBad -join ', ') + ' digest=' + $rcD.why + '/' + $rcD.class)
    $rcX = Resolve-AlertClass $regRead.registry (Get-AlertTypeKey ($script:SubjectPrefix + ': NOT A CONDITION IT SENDS'))
    _T 'MUST NOT FIRE  a label this task never sends still resolves unregistered, so the entries are exact and match nothing else' ($rcX.why -ceq 'unregistered') ($rcX.why + '/' + $rcX.class)

    # The heartbeat's proof: a stamp written with the verdict's exit and conditions.
    $stampP = Join-Path $st 'stamp\backlog-merge-stamp.json'
    Write-TcBmStamp -Path $stampP -Res $e5 -Code $e5.Code -NowUtc $nowS
    $stampJ = [IO.File]::ReadAllText($stampP) | ConvertFrom-Json
    _T 'CLEAN TWIN     the stamp records the exit and the conditions paged' (([int]$stampJ.exit -eq 2) -and (@($stampJ.conditions) -contains 'STALE INBOX') -and $stampJ.deferred) ([IO.File]::ReadAllText($stampP))
  } catch {
    [void]$script:stFails.Add('HARNESS')
    Write-Output ('  FAIL  the self-test threw at line {0}: {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message)
  } finally {
    $env:TC_EVENT_BUS = $prevBus
    Stop-TcMutexHold
    for ($try = 0; $try -lt 3; $try++) {
      if (-not (Test-Path -LiteralPath $st)) { break }
      Remove-Item -LiteralPath $st -Recurse -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $st) { Start-Sleep -Milliseconds 200 }
    }
  }
  # A LITERAL-CASE SUITE ASSERTS HOW MANY RAN (ops-and-gates.md): a case lost to a throw is a shortfall, never a smaller green.
  $EXPECTED_CASES = 45
  Write-Output ''
  if ($script:stFails.Count -or ($script:stRan -ne $EXPECTED_CASES)) {
    Write-Output ('run-backlog-merge SELF-TEST FAIL: {0} case(s) failed, {1} of {2} case(s) ran' -f $script:stFails.Count, $script:stRan, $EXPECTED_CASES)
    exit 1
  }
  Write-Output ('run-backlog-merge self-test PASS: {0} of {0} cases' -f $script:stRan)
  exit 0
}

# ============================================================================================================ a run
$script:RunLog = Start-RunLog -Name 'backlog-merge' -OutDir (Join-Path $repo 'ops\out')
$code = 3   # what the transcript records if anything below throws before a verdict: a crash is never a pass
$summary = 'blind=threw'
$res = $null
$nowRun = [datetime]::UtcNow
try {
  $pagerFn = $null
  if ($Alert) {
    . (Join-Path $repo 'grocery\alert-lib.ps1')   # Send-AlertConditions: one alert type per condition
    $pagerFn = {
      param($Conditions, [string]$Pointer)
      $objs = @($Conditions | ForEach-Object { [pscustomobject]@{ Label = [string]$_.Label; Text = [string]$_.Text } })
      $ptr = if ($Pointer) { 'The full run: ' + $Pointer } else { 'The full run is in ops\out\logs\backlog-merge-<date>.log in the main checkout.' }
      $sr = Send-AlertConditions -SubjectPrefix $script:SubjectPrefix -Conditions $objs -ReportPointer $ptr
      return [int]$sr.rc
    }
  }
  $res = Invoke-TcBacklogMergeRun -MainDir $repo -Pager $pagerFn -ReportPointer ([string]$script:RunLog) -NowUtc $nowRun
  foreach ($l in @($res.Report.ToArray())) { Write-Output $l }
  $code = [int]$res.Code
  $labels = @($res.Conditions.ToArray() | ForEach-Object { $_.Label } | Select-Object -Unique)
  $summary = ('exit={0} skipped={1} deferred={2} merge={3} committed={4} landed={5} conditions={6}' -f $code, $res.Skipped, $res.Deferred, $res.MergeCode, $(if ($res.Committed) { $res.Committed.Substring(0, 12) } else { 'none' }), $res.Landed, ($(if ($labels.Count) { $labels -join '|' } else { 'none' }) -replace ' ', '_'))
  $word = switch ($code) { 0 { 'CLEAN' } 2 { 'FINDINGS' } 3 { 'COULD NOT EVALUATE' } default { throw ('unknown run code: ' + $code) } }
  Write-Output ('BACKLOG MERGE {0}: {1}' -f $word, $summary)
  if ($Alert) {
    try { Write-TcBmStamp -Path $script:StampPath -Res $res -Code $code -NowUtc $nowRun } catch { Write-Output ('  WARN   the stamp could not be written ({0}); the exit code still stands' -f $_.Exception.Message) }
  }
} catch {
  Write-Output ('BACKLOG MERGE COULD NOT EVALUATE: the run threw at line {0}: {1}' -f $_.InvocationInfo.ScriptLineNumber, $_.Exception.Message)
  $code = 3
} finally {
  Stop-RunLog -ExitCode $code -Path $script:RunLog
}
Exit-Guard -Name 'BACKLOG-MERGE' -Code $code -Summary $summary
