<#
  audit-prompt-backup.ps1 - the agent prompts and scheduled-task SKILLs are CODE. Back them up, and prove
  the backup is current.

  SCOPE OF A CLEAN REPORT: SOUND about currency, silent about content, the same split as
    audit-memory-backup.ps1. It proves the backup is current. Whether the prompts in it are the
    right prompts is not a question it asks. Outside the main checkout a clean report proves THIS
    checkout's mirror matches THIS checkout's prompts, not that the main checkout's live prompts are
    backed up, and it says nothing about SCOPE DRIFT, which only the main checkout can judge.
    THE DEFAULT RUN IS THE PUSH-TIME RUN (2026-09-23, see PUSH SCOPE below), and a clean report from it
    proves only that nothing THIS PUSH changed disagrees with its counterpart: drift in a file the push did
    not touch is printed REVIEW and does not fail it. Whole-mirror currency moved to -Daily, which
    grocery\check-ad-cycles.ps1 runs once a day and pages on; a clean -Daily report proves the mirror AS
    COMMITTED ON origin/main matches every shared live copy, or has disagreed for 24 hours or less. -Full
    is the old whole check over this checkout's working tree.

  WHY (2026-07-31): everything the triage agents depend on is versioned, self-tested and gated - and the
  agents' own instructions were not in git at all. They live in C:\Codex\ThriftyCrew\.claude\agents (project scope),
  C:\Users\Owner\.claude\agents (user scope) and C:\Users\Owner\.claude\scheduled-tasks\<task>\SKILL.md,
  none of which is a repository. A machine failure, or one bad overwrite, and the reasoning is gone.

  It also found the drift it was built to prevent, on its first run: SIX of the eight agent prompts already
  differed between project scope and user scope. Same name, two files, quietly disagreeing - and which one
  runs depends on where the session's working directory is. That is the same two-copies-of-one-truth trap
  this estate has paid for in pu-lib and in the category-exclude bake.

  Three checks:
    1. BACKUP CURRENCY  - repo copy matches the live project-scope file
    2. SCOPE AGREEMENT  - the user-scope copy matches the project-scope copy (where both exist)
    3. COVERAGE         - every live agent + SKILL has a backup at all
  Three ways to JUDGE them (2026-09-23): the default judges what this push changed, -Full judges every
  finding, -Daily judges the mirror as committed on origin/main and fails only on a finding over 24 hours old.
  Exit 0 clean (by the mode's own rule: REVIEW and FRESH lines do not fail), 2 drift/missing, 3 BLIND
  (nothing found to check - a pass that proves nothing) or -Full and -Daily passed together.
  -SelfTest runs frozen fixtures.

  THE WRITE MODES (2026-09-05, queue 2026-09-05-5650ce). -Sync used to be ONE button doing three things
  with three different risk profiles, and because the riskiest of them writes into a PUBLIC repository the
  whole button could not be automated. So this audit printed the same seven findings every morning for 13
  days and nothing moved: the recipe writer ran Opus-pinned at high effort in two of the three copies, the
  dedup selector carried no precedents contract, and the recipe-hunter SKILL was missing Brad's 09-04
  browser-pricing ruling - for every session whose working directory sits outside the repo. An alarm whose
  only follower is a human typing a command is an alarm with no repair lane.
    -SyncScopes  project scope -> user scope. LOCAL ONLY: nothing is published, and this is the half that
                 decides WHICH PROMPT ACTUALLY RUNS. Safe to automate, and run daily from capture-run.ps1.
    -SyncMirror  live -> ops\prompt-backup, but ONLY where a mirror ALREADY EXISTS. Refreshing a copy of a
                 file that is already public publishes nothing new. Safe to automate.
    -Adopt       live -> ops\prompt-backup for a file that has NO mirror yet. This is the only mode that
                 turns a private file into a public one, so it stays a deliberate act with a name attached:
                 -Adopt recipe-writer.md, or -Adopt skill|recipe-hunter. -Adopt * means all of them.
    -Sync        = -SyncScopes -SyncMirror -Adopt *. Kept verbatim: every design doc and every habit in
                 this estate says "run -Sync", and that must keep meaning exactly what it always meant.
  NO BACKUP therefore stays the one finding that still needs a person, which is the point.

  WHICH TREE IS LIVE (2026-09-11). $PROJ and $SKILLS were the MAIN checkout's .claude paths, hard-coded,
  while $backup is ops\prompt-backup in whichever tree this runs from. So an agent-prompt edit committed
  WITH its refreshed mirror, gated from a .claude\worktrees\ checkout or a detached tc-gatecheck checkout,
  read STALE BACKUP: the main checkout cannot hold an edit that has not reached main yet. run-gates runs
  this audit live, so the pre-push hook refused that push on this gate alone and the only way through was
  --no-verify. Measured 2026-09-10 on the Hy-Vee Omaha #02 pricer fix: exactly one issue, the file changed.
  The project-scope prompts are now read from THIS checkout, so outside main the question is "does this
  commit's mirror match this commit's prompts", which is the one a push can answer. Two things stay tied
  to the main checkout, because they are about what RUNS rather than what is committed: SCOPE DRIFT (user
  scope follows main, daily) is judged only there, and -SyncScopes is skipped anywhere else, out loud,
  because from a worktree it would push a prompt that has not reached main into the scope sessions read.
  Scheduled-task SKILLs are unchanged: their live copy is shared by every tree, so they already compared
  like with like.

  PUSH SCOPE (2026-09-23, design\PLAN-push-derived-conflicts-2026-09-23.md W8.4, Brad's ruling D15). "Shared by
  every tree" was the defect one step on. The live scheduled-task SKILLs and user-scope agents sit in no
  repository and every checkout on this box reads the same ones, so one session's live edit made this audit red
  for EVERY other checkout's push until that session's mirror commit landed, and none of those pushes could fix
  it. The plan counts 5 of 19 kept in-hook run-gates red logs dated 09-20 to 09-23 naming this audit, and 8 of 44
  cause-naming gate refusals over 7 days (both SCRATCH, the plan's section 15.5). A refusal a push cannot repair
  teaches retry, not repair. So the DEFAULT run, which run-gates makes on every push, judges what the push changed:
    * the range is HEAD's commits since its merge-base with origin/main (git diff --name-only --no-renames), which
      is what push-main and a plain push of HEAD send;
    * a finding FAILS when a repo file it compares is in that range: a mirror under ops\prompt-backup, or a
      project-scope prompt under .claude\agents or .claude\skills. Every refusal of a push that changes a prompt
      or its mirror is kept, a deleted mirror included (its path is in the range);
    * a push that changes this audit or ops\prompt-backup-exempt.json is judged on EVERY finding, because either
      can move any verdict ($script:PbSelfPaths);
    * any other finding prints REVIEW with the files it names, and passes;
    * a range that cannot be read (no origin/main, a shallow clone, git failing) judges every finding, as the day
      before did. It never passes a finding it could not scope.
  -Full judges every finding over this checkout, which is what the default did until this change, and the report
  after any write mode (-Sync, -SyncScopes, -SyncMirror, -Adopt) uses it, so capture-run's prompt-sync reads as before.

  -Daily IS THE FLOOR THE PUSH MODE GAVE UP, run once a day by grocery\check-ad-cycles.ps1, which pages on a
  non-zero exit. It compares the shared live copies with the mirror AS COMMITTED ON origin/main, and the
  project-scope prompts as committed there too, materialised into a per-run temp folder. Why committed and not
  the files on disk: capture-run's daily prompt-sync (-SyncMirror) refreshes the MAIN checkout's mirror on disk,
  and nothing stages ops\prompt-backup (kept off the bot's staging list on purpose), so a check over the main
  checkout's working tree reads clean from the day after a live edit while every other checkout's committed
  mirror is stale. That is the mirror nobody committed, which this floor exists to catch. (Read from
  grocery\capture-run.ps1, where the chain runs before prompt-sync; not measured.) SCOPE DRIFT is about what RUNS
  rather than what is committed, so it is still judged over the main checkout's working tree, and only there.
  It FAILS (exit 2) only on a finding more than 24 hours old ($script:PbDailyBarSec), and prints a younger one
  FRESH: a mirror commit in flight is not a page, and a finding that still stands on a later run is. The age is a
  LOWER BOUND: now minus the newest change time of the sides it compares, where a committed side's time is the
  committer time of the last commit on origin/main that touched it and a file on disk uses its LastWriteTimeUtc.
  Anything that rewrites a file without changing it makes a mismatch read YOUNGER, so this errs toward a late page
  and never an early one. The one such rewriter known here is the bot's autoStash, which rewrites a file left
  dirty in the main checkout every morning, and it reaches only SCOPE DRIFT, the one comparison still read from
  disk there. When origin/main cannot be read it compares this checkout's working tree instead, as the weekly
  check did, and says so. The 24 hours is the plan's first plausible value (15.5 step 2), not a swept one.
#>
# [CmdletBinding()] IS LOAD-BEARING HERE. Without it PS 5.1 drops an unrecognised -Arg into $args and runs
# on: a typo'd -SyncMirrors would have made a read-only report look like a completed sync, and the daily
# hook would have "run" every morning writing nothing. See the [[arg-silently-ignored]] class - a scoping
# flag that falls into $args exits 0 having done the unscoped thing, or nothing at all.
# Its self-test builds every repo, folder and file it judges under %TEMP%, and loads these two libraries. It reads
# nothing else of this checkout, and says so rather than being guessed at (lib\gate-input-key.ps1).
# gate-inputs: lib\guard-contract.ps1, lib\git-repo-env.ps1
[CmdletBinding()]
param([switch]$Sync, [switch]$SyncScopes, [switch]$SyncMirror, [string[]]$Adopt, [switch]$Full, [switch]$Daily, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
$root   = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$backup = Join-Path $root 'prompt-backup'
# The checkout whose prompts RUN. $PROJ and $SKILLS are no longer this path: they are resolved from the
# checkout this script sits in, by Resolve-PromptRoots below. See WHICH TREE IS LIVE in the header.
$MAIN   = 'C:\Codex\ThriftyCrew'
$USER   = 'C:\Users\Owner\.claude\agents'
$TASKS  = 'C:\Users\Owner\.claude\scheduled-tasks'
# PROJECT-SCOPE SKILLS, added 2026-08-15. This was a whole class the audit could not see: recipe-hunter,
# lesson and meal-macro live here, and recipe-hunter\SKILL.md alone is 12KB of the flow's operating rules -
# which stages stream, why the price lane is a singleton, which gate must never be weakened. None of it was
# in git. It was found while looking for that file to edit it, not by this guard, which is the tell that a
# coverage check enumerating three known directories can only ever be as complete as that list.
# $SKILLS is resolved from this checkout alongside $PROJ, by Resolve-PromptRoots below.

# ---- HASH WHAT GIT HASHES (2026-09-06, queue 2026-09-06-fdc73a) ---------------------------------------
# This hashed RAW ON-DISK BYTES to compare two paths that git deliberately holds identical only AFTER
# line-ending normalization. core.autocrlf is true here and .gitattributes carries '* text=auto', so the
# same committed content legitimately sits on disk as LF in one path and CRLF in another - and it did:
# on 2026-09-06 all six STALE BACKUP findings were line-ending noise, with the live/mirror MD5 EQUAL for
# every one of them after stripping CR (triage-developer.md was 11261 bytes live and 11413 in the mirror,
# a delta of exactly 152 bytes over exactly 152 lines, one CR per line). The two pairs that read CLEAN
# were the ones whose line endings already agreed, which is the discriminator that names the cause.
#
# WHY IT COULD NEVER CONVERGE, which is what makes it worse than a false positive: -SyncMirror's
# Copy-Item makes the two byte-equal for a moment and the next checkout or stash-restore re-splits them.
# A check that cannot be satisfied reports daily on a mirror that is already correct, and a daily finding
# nobody can clear is how a reader learns to skip the whole report.
#
# The normalization is CRLF -> LF specifically, not "strip every CR": git rewrites the pair, and a lone CR
# is content. A file holding a NUL byte is treated as genuinely binary and compared raw, because dropping
# a 0x0D out of binary content would be a change, not a normalization.
function FileHash1([string]$p) {
  if (-not (Test-Path $p)) { return $null }
  $bytes = [IO.File]::ReadAllBytes($p)
  if (-not ($bytes -contains [byte]0)) {
    $n = $bytes.Length
    $buf = New-Object byte[] $n
    $j = 0
    for ($i = 0; $i -lt $n; $i++) {
      if ($bytes[$i] -eq 13 -and ($i + 1) -lt $n -and $bytes[$i + 1] -eq 10) { continue }
      $buf[$j] = $bytes[$i]; $j++
    }
    if ($j -ne $n) { $trim = New-Object byte[] $j; if ($j -gt 0) { [Array]::Copy($buf, 0, $trim, 0, $j) }; $bytes = $trim }
  }
  $md5 = [Security.Cryptography.MD5]::Create()
  try { return (([BitConverter]::ToString($md5.ComputeHash($bytes))) -replace '-', '') }
  finally { $md5.Dispose() }
}

# ---- THE EXEMPTION LIST (2026-09-04, queue 2026-09-04-0b63d3) -------------------------------------------
# ops\prompt-backup is TRACKED IN A PUBLIC REPOSITORY. "NO BACKUP" is therefore not always a defect to fix
# by copying: some live prompts must never be mirrored there. On 2026-09-04 this audit reported NO BACKUP on
# a personal flight-price watch (travel dates, alert recipients) and the remedy it printed - -Sync - would
# have committed it to github.com/Schweino/ThriftyCrew. An exemption says "deliberately not mirrored", and
# -Sync honours it, so the exemption cannot be undone by the command the finding recommends.
# MISSING FILE = NO EXEMPTIONS (the audit behaves exactly as it did before this existed).
# UNREADABLE OR MALFORMED FILE = THROW, and the caller exits 3 BLIND. A typo in this file must never read as
# "nothing is exempt" and must never read as "everything is exempt": it must read as "I cannot judge".
function Get-PromptExemptions([string]$Path) {
  $map = @{}
  if (-not $Path -or -not (Test-Path $Path)) { return $map }
  $raw = [IO.File]::ReadAllText($Path)     # let an IO error throw: unreadable is not empty
  $doc = ConvertFrom-Json $raw             # let a parse error throw: malformed is not empty
  foreach ($e in @($doc.exempt)) {
    $n = ([string]$e.name).Trim()
    if (-not $n) { throw ('prompt-backup-exempt.json holds an entry with no name - refusing to guess what it exempts') }
    $k = (([string]$e.kind).Trim().ToLower()) + '|' + $n.ToLower()
    $map[$k] = ([string]$e.reason)
  }
  return $map
}

# ---- WHICH TREE IS LIVE (2026-09-11) - see the header -------------------------------------------------
# Pure path arithmetic, no git, so -SelfTest can drive it over temp folders. The project-scope prompts are
# read from the checkout this script sits in; is_main says whether that checkout is the one whose prompts run.
# Ordinal, case-insensitive: Windows paths, and a culture-sensitive compare is the wrong default for data.
function Resolve-PromptRoots {
  param([string]$RepoRoot, [string]$MainRoot)
  $full = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
  $main = [IO.Path]::GetFullPath($MainRoot).TrimEnd('\')
  return @{
    root    = $full
    proj    = (Join-Path $full '.claude\agents')
    skills  = (Join-Path $full '.claude\skills')
    is_main = [string]::Equals($full, $main, [StringComparison]::OrdinalIgnoreCase)
  }
}

# -SyncScopes writes the USER scope, which every session outside the repo reads, so it follows only the
# main checkout. Anywhere else it is SKIPPED and the skip is spoken: a sync that quietly declined reads
# exactly like a sync with nothing to do. -SyncMirror and -Adopt write this checkout's own mirror and run.
function Get-PromptSyncModes {
  param([bool]$IsMain, [bool]$Scopes, [bool]$Mirror, [string]$Here = '', [string]$Main = '')
  $note = ''
  if ($Scopes -and -not $IsMain) {
    $Scopes = $false
    $note = ('SKIPPED -SyncScopes: this is not the main checkout (' + $Here + '). Project -> user scope from here would put a prompt that has not reached main into the scope every session reads. Run it from ' + $Main + ' once the change is on main.')
  }
  return @{ scopes = $Scopes; mirror = $Mirror; note = $note }
}

# ---- EVERY FINDING NAMES THE FILES IT COMPARES (2026-09-23, W8.4) -------------------------------------
# The push mode below asks one question of a finding - did this push change a repo file it compares? - so a finding
# carries its SIDES (the full paths it compared, a mirror that does not exist included, because a deleted mirror
# is a path the push changed) and the repo-relative spelling of each side inside $RepoRoot, forward slashes, the
# way git names a changed file. `issues` stays the list of strings every reader already takes, word for word.
function ConvertTo-PbRepoRel {
  param([string]$RepoRoot, [string]$Path)
  if (-not $RepoRoot -or -not $Path) { return $null }
  $r = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
  $p = [IO.Path]::GetFullPath($Path)
  if (-not $p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
  return ($p.Substring($r.Length + 1) -replace '\\', '/')
}

function Add-PbFinding {
  param($Issues, $Findings, [string]$Kind, [string]$Text, [string[]]$Sides, [string]$RepoRoot = '')
  $Issues.Add($Text)
  $rel = [System.Collections.Generic.List[string]]::new()
  foreach ($s in @($Sides)) { $x = ConvertTo-PbRepoRel $RepoRoot $s; if ($x) { $rel.Add($x) } }
  $Findings.Add([pscustomobject]@{ Kind = $Kind; Text = $Text; Sides = @($Sides); Repo = $rel.ToArray() })
}

function Compare-Prompts {
  param([string]$Proj, [string]$UserDir, [string]$Tasks, [string]$Backup, [string]$Skills = '', [hashtable]$Exempt = $null, [switch]$SkipScopeDrift, [string]$RepoRoot = '')
  $issues = New-Object System.Collections.Generic.List[string]
  $notes  = New-Object System.Collections.Generic.List[string]
  $findings = [System.Collections.Generic.List[object]]::new()
  if ($null -eq $Exempt) { $Exempt = @{} }
  $checked = 0
  $agentBk = Join-Path $Backup 'agents'
  $taskBk  = Join-Path $Backup 'scheduled-tasks'

  foreach ($f in @(Get-ChildItem (Join-Path $Proj '*.md') -ErrorAction SilentlyContinue)) {
    $checked++
    $b = Join-Path $agentBk $f.Name
    if (-not (Test-Path $b)) { Add-PbFinding $issues $findings 'NO BACKUP' "NO BACKUP  agents\$($f.Name) - the live prompt exists only on this machine" @($f.FullName, $b) $RepoRoot }
    elseif ((FileHash1 $f.FullName) -ne (FileHash1 $b)) { Add-PbFinding $issues $findings 'STALE BACKUP' "STALE BACKUP  agents\$($f.Name) - repo copy differs from the live project-scope file" @($f.FullName, $b) $RepoRoot }
    # Outside the main checkout the user scope still follows MAIN, so comparing it to this checkout's prompts
    # would report every unmerged edit as drift. That question belongs to the main checkout's run.
    if (-not $SkipScopeDrift) {
      $u = Join-Path $UserDir $f.Name
      if (Test-Path $u) {
        if ((FileHash1 $f.FullName) -ne (FileHash1 $u)) { Add-PbFinding $issues $findings 'SCOPE DRIFT' "SCOPE DRIFT  $($f.Name) - the user-scope copy differs from the project-scope copy, so which prompt runs depends on the session's working directory" @($f.FullName, $u) $RepoRoot }
      }
    }
  }
  # a user-scope agent with no project twin is still live and still needs a backup
  foreach ($f in @(Get-ChildItem (Join-Path $UserDir '*.md') -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $Proj $f.Name)) { continue }
    $checked++
    $b = Join-Path $agentBk $f.Name
    if (-not (Test-Path $b)) { Add-PbFinding $issues $findings 'NO BACKUP' "NO BACKUP  agents\$($f.Name) (user scope only)" @($f.FullName, $b) $RepoRoot }
  }
  foreach ($d in @(Get-ChildItem $Tasks -Directory -ErrorAction SilentlyContinue)) {
    $s = Join-Path $d.FullName 'SKILL.md'
    if (-not (Test-Path $s)) { continue }
    # AN EXEMPTED TASK STILL COUNTS IN `checked`. It was examined and a decision was reached about it; the
    # coverage tally is what stops this audit reporting clean over a directory it never opened, and dropping
    # an exempted task out of it would shrink the very number that proves the audit looked.
    $checked++
    $ekey = 'scheduled-task|' + $d.Name.ToLower()
    if ($Exempt.ContainsKey($ekey)) {
      $notes.Add("EXEMPT  scheduled-tasks\$($d.Name)\SKILL.md - " + $Exempt[$ekey])
      continue
    }
    $b = Join-Path (Join-Path $taskBk $d.Name) 'SKILL.md'
    if (-not (Test-Path $b)) { Add-PbFinding $issues $findings 'NO BACKUP' "NO BACKUP  scheduled-tasks\$($d.Name)\SKILL.md" @($s, $b) $RepoRoot }
    elseif ((FileHash1 $s) -ne (FileHash1 $b)) { Add-PbFinding $issues $findings 'STALE BACKUP' "STALE BACKUP  scheduled-tasks\$($d.Name)\SKILL.md" @($s, $b) $RepoRoot }
  }
  # project-scope skills: <skills>\<name>\SKILL.md, same shape as scheduled tasks
  if ($Skills) {
    $skillBk = Join-Path $Backup 'skills'
    foreach ($d in @(Get-ChildItem $Skills -Directory -ErrorAction SilentlyContinue)) {
      $s = Join-Path $d.FullName 'SKILL.md'
      if (-not (Test-Path $s)) { continue }
      $checked++
      $b = Join-Path (Join-Path $skillBk $d.Name) 'SKILL.md'
      if (-not (Test-Path $b)) { Add-PbFinding $issues $findings 'NO BACKUP' "NO BACKUP  skills\$($d.Name)\SKILL.md - the live skill exists only on this machine" @($s, $b) $RepoRoot }
      elseif ((FileHash1 $s) -ne (FileHash1 $b)) { Add-PbFinding $issues $findings 'STALE BACKUP' "STALE BACKUP  skills\$($d.Name)\SKILL.md - repo copy differs from the live skill" @($s, $b) $RepoRoot }
    }
  }
  return @{ issues = $issues; checked = $checked; notes = $notes; findings = $findings }
}

# ---- GIT, WITHOUT A POWERSHELL REDIRECT (2026-09-23, W8.4) -------------------------------------------------
# This script runs under EAP=Stop, where redirecting a native child's stderr turns its first line into a throw
# (.claude\rules\ops-and-gates.md). The push scope needs git's exit code and its stderr text for the reason it
# prints, so git runs through .NET Process, which PowerShell never wraps. The child inherits this process's
# environment: run-gates and pre-push clear GIT_DIR and its siblings before this runs, and the self-test clears
# them itself before it builds a repo.
function ConvertTo-PbArgString {
  param([string[]]$List)
  $parts = [System.Collections.Generic.List[string]]::new()
  foreach ($a in @($List)) {
    $s = [string]$a
    if ($s.Length -gt 0 -and $s -notmatch '[\s"]') { $parts.Add($s); continue }
    # Windows command-line quoting: backslashes are literal except before a quote, where they are doubled.
    $q = [regex]::Replace($s, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    $q = [regex]::Replace($q, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    $parts.Add('"' + $q + '"')
  }
  return ($parts.ToArray() -join ' ')
}

function Invoke-PbGit {
  param([string]$RepoRoot, [string[]]$GitArgs)
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = ConvertTo-PbArgString (@('-C', $RepoRoot) + @($GitArgs))
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $psi.StandardOutputEncoding = $utf8
  $psi.StandardErrorEncoding = $utf8
  $p = $null
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
    # stderr is drained on its own task so a chatty stderr cannot fill its pipe while stdout is being read.
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ Code = [int]$p.ExitCode; Out = [string]$out; Err = [string]$errTask.Result }
  } catch {
    return [pscustomobject]@{ Code = -1; Out = ''; Err = ('git could not be run: ' + $_.Exception.Message) }
  } finally { if ($p) { $p.Dispose() } }
}

function Get-PbFirstLine([string]$Text) {
  $l = @(([string]$Text) -split "`r?`n" | Where-Object { $_.Trim() })
  if ($l.Count) { return $l[0].Trim() }
  return ''
}

# ONE temp allocator for everything this script writes under %TEMP%: a per-run name, created with
# -ErrorAction Stop so a clash refuses rather than shares, and every caller removes it in a finally. It REMEMBERS
# what it made, so the self-test can prove each one is gone by name rather than by scanning a %TEMP% that
# concurrent runs of this same suite share (memory test-suites-leak-temp-dirs: the allocator must remember).
$script:PbTempMade = [System.Collections.Generic.List[string]]::new()
function New-PbTempDir([string]$Stem) {
  $d = Join-Path ([IO.Path]::GetTempPath()) ($Stem + [guid]::NewGuid().ToString('N').Substring(0, 12))
  $null = New-Item -ItemType Directory -Path $d -ErrorAction Stop
  $script:PbTempMade.Add($d)
  return $d
}

# ---- WHAT THIS PUSH CHANGED (2026-09-23, W8.4, D15) - see PUSH SCOPE in the header -------------------------
# A change to either of these can move ANY verdict, so a push that carries one is judged on every finding.
$script:PbSelfPaths = @('ops/audit-prompt-backup.ps1', 'ops/prompt-backup-exempt.json')
$script:PbPushRef = 'refs/remotes/origin/main'

function New-PbPathSet([string[]]$Paths) {
  $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($p in @($Paths)) { if ($p) { [void]$set.Add((([string]$p).Trim() -replace '\\', '/')) } }
  return , $set
}

# Returns Ok, Why, Base, Changed (a set of repo-relative paths). Ok=$false is never a pass: the caller judges every
# finding when it cannot scope them.
function Get-PbPushScope {
  param([string]$RepoRoot, [string]$Ref = $script:PbPushRef)
  $none = [pscustomobject]@{ Ok = $false; Why = ''; Base = ''; Changed = $null }
  $mb = Invoke-PbGit -RepoRoot $RepoRoot -GitArgs @('merge-base', 'HEAD', $Ref)
  $base = ([string]$mb.Out).Trim()
  if ($mb.Code -ne 0 -or $base -notmatch '^[0-9a-f]{40,64}$') {
    $none.Why = ('git merge-base HEAD ' + $Ref + ' exited ' + $mb.Code + ': ' + (Get-PbFirstLine $mb.Err))
    return $none
  }
  # --no-renames so a renamed or deleted mirror names BOTH paths; -z so no path is quoted or split.
  $d = Invoke-PbGit -RepoRoot $RepoRoot -GitArgs @('diff', '--name-only', '--no-renames', '-z', $base, 'HEAD', '--')
  if ($d.Code -ne 0) {
    $none.Why = ('git diff --name-only ' + $base.Substring(0, 12) + '..HEAD exited ' + $d.Code + ': ' + (Get-PbFirstLine $d.Err))
    return $none
  }
  $names = @(([string]$d.Out) -split [char]0 | Where-Object { $_.Trim() })
  return [pscustomobject]@{ Ok = $true; Why = ''; Base = $base; Changed = (New-PbPathSet $names) }
}

# A finding is this push's when the push changed a repo file it compares, or changed the audit itself.
function Split-PbFindingsByPush {
  param($Findings, $Changed, [string[]]$SelfPaths = $script:PbSelfPaths)
  $own = [System.Collections.Generic.List[object]]::new()
  $amb = [System.Collections.Generic.List[object]]::new()
  $selfHit = [System.Collections.Generic.List[string]]::new()
  foreach ($s in @($SelfPaths)) { if ($Changed.Contains($s)) { $selfHit.Add($s) } }
  $whole = ($selfHit.Count -gt 0)
  foreach ($f in @($Findings)) {
    $hit = $whole
    if (-not $hit) { foreach ($r in @($f.Repo)) { if ($r -and $Changed.Contains([string]$r)) { $hit = $true; break } } }
    if ($hit) { $own.Add($f) } else { $amb.Add($f) }
  }
  return [pscustomobject]@{ Own = $own.ToArray(); Ambient = $amb.ToArray(); Whole = $whole; SelfHit = $selfHit.ToArray() }
}

# ---- HOW OLD A MISMATCH IS, AT LEAST (2026-09-23, W8.4) - see -Daily in the header -------------------------
# Strictly MORE than this pages. First plausible value, from the plan (15.5 step 2): not swept, not tuned.
$script:PbDailyBarSec = 86400

# The age in TICKS, a lower bound: now minus the newest LastWriteTimeUtc among the sides that exist. $null when no
# side exists, which the caller pages: an age it cannot read is never waved through as fresh.
function Get-PbFindingAgeTicks {
  param($Finding, [datetime]$NowUtc)
  $newest = $null
  foreach ($s in @($Finding.Sides)) {
    if (-not $s -or -not (Test-Path -LiteralPath $s -PathType Leaf)) { continue }
    $t = [IO.File]::GetLastWriteTimeUtc($s)
    if ($null -eq $newest -or $t -gt $newest) { $newest = $t }
  }
  if ($null -eq $newest) { return $null }
  return ([long]$NowUtc.Ticks - [long]$newest.Ticks)
}

function Split-PbFindingsByAge {
  param($Findings, [datetime]$NowUtc, [long]$BarSec = $script:PbDailyBarSec)
  $bar = [long]$BarSec * [TimeSpan]::TicksPerSecond
  $paged = [System.Collections.Generic.List[object]]::new()
  $fresh = [System.Collections.Generic.List[object]]::new()
  foreach ($f in @($Findings)) {
    $a = Get-PbFindingAgeTicks -Finding $f -NowUtc $NowUtc
    $h = if ($null -eq $a) { 'age unknown' } else { ('at least {0:0.0} h old' -f ($a / [double][TimeSpan]::TicksPerHour)) }
    $row = [pscustomobject]@{ Kind = $f.Kind; Text = $f.Text; Sides = $f.Sides; Repo = $f.Repo; Age = $h }
    if ($null -eq $a -or $a -gt $bar) { $paged.Add($row) } else { $fresh.Add($row) }
  }
  return [pscustomobject]@{ Paged = $paged.ToArray(); Fresh = $fresh.ToArray() }
}

# ---- THE MIRROR AS COMMITTED (2026-09-23, W8.4) - see -Daily in the header ---------------------------------
# Materialises the prompt trees as committed on $Ref into a per-run temp folder the CALLER removes, each file
# stamped with the committer time of the last commit on $Ref that touched it, so the age rule above reads a
# committed side by when it LANDED rather than by when this copy was written. git archive writes the zip itself,
# so no byte passes through a PowerShell pipeline. Returns Ok, Why, Root (remove it), Tree, Sha, Files.
function Export-PbCommittedTree {
  param([string]$RepoRoot, [string]$Ref = $script:PbPushRef, [string[]]$Prefixes = @('.claude/agents', '.claude/skills', 'ops/prompt-backup'))
  $res = [pscustomobject]@{ Ok = $false; Why = ''; Root = ''; Tree = ''; Sha = ''; Files = 0 }
  $rv = Invoke-PbGit -RepoRoot $RepoRoot -GitArgs @('rev-parse', '--verify', '--quiet', ($Ref + '^{commit}'))
  $sha = ([string]$rv.Out).Trim()
  if ($rv.Code -ne 0 -or $sha -notmatch '^[0-9a-f]{40,64}$') { $res.Why = ('git rev-parse ' + $Ref + ' exited ' + $rv.Code); return $res }
  $ls = Invoke-PbGit -RepoRoot $RepoRoot -GitArgs (@('ls-tree', '-r', '-z', '--name-only', $sha, '--') + $Prefixes)
  if ($ls.Code -ne 0) { $res.Why = ('git ls-tree exited ' + $ls.Code + ': ' + (Get-PbFirstLine $ls.Err)); return $res }
  $files = @(([string]$ls.Out) -split [char]0 | Where-Object { $_.Trim() })
  $root = New-PbTempDir 'tc-pbk-'
  try {
    $tree = Join-Path $root 'tree'
    $null = New-Item -ItemType Directory -Path $tree -ErrorAction Stop
    if ($files.Count) {
      # git archive refuses a pathspec that matches nothing, so it is handed only the prefixes that hold a file.
      $present = @($Prefixes | Where-Object { $pre = $_ + '/'; @($files | Where-Object { $_.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase) }).Count })
      $zip = Join-Path $root 'committed.zip'
      $ar = Invoke-PbGit -RepoRoot $RepoRoot -GitArgs (@('archive', '--format=zip', '-o', $zip, $sha, '--') + $present)
      if ($ar.Code -ne 0 -or -not (Test-Path -LiteralPath $zip)) { throw ('git archive exited ' + $ar.Code + ': ' + (Get-PbFirstLine $ar.Err)) }
      Add-Type -AssemblyName System.IO.Compression.FileSystem
      [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tree)
      $lg = Invoke-PbGit -RepoRoot $RepoRoot -GitArgs (@('log', '--format=%x01%ct', '--name-only', '--no-renames', $sha, '--') + $present)
      if ($lg.Code -ne 0) { throw ('git log exited ' + $lg.Code + ': ' + (Get-PbFirstLine $lg.Err)) }
      # newest commit first, so the FIRST time a path appears is its last change
      $when = New-Object Collections.Hashtable ([StringComparer]::OrdinalIgnoreCase)
      $ct = $null
      foreach ($line in (([string]$lg.Out) -split "`n")) {
        $l = $line.TrimEnd("`r")
        if ($l.StartsWith([string][char]1)) { $ct = [long]$l.Substring(1); continue }
        if ($l -and $null -ne $ct -and -not $when.ContainsKey($l)) { $when[$l] = $ct }
      }
      foreach ($f in $files) {
        $full = Join-Path $tree ($f -replace '/', '\')
        if ($when.ContainsKey($f) -and [IO.File]::Exists($full)) {
          [IO.File]::SetLastWriteTimeUtc($full, [DateTimeOffset]::FromUnixTimeSeconds([long]$when[$f]).UtcDateTime)
        }
      }
    }
    $res.Ok = $true; $res.Root = $root; $res.Tree = $tree; $res.Sha = $sha; $res.Files = $files.Count
    return $res
  } catch {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    $res.Why = $_.Exception.Message
    return $res
  }
}

# ---- THE WRITE SIDE, SPLIT BY RISK (2026-09-05, queue 2026-09-05-5650ce) -------------------------------
# The whole point of the split is the line drawn inside Copy-PromptToMirror: REFRESHING a mirror that
# already exists publishes nothing that is not already public, while CREATING one publishes a file for the
# first time. Those were one command, so the safe half could not be automated and the drift lived 13 days.
# The write side is a function taking explicit roots (not the module-scope $PROJ/$USER/...) for one reason:
# a fix nobody can test is a fix nobody can trust, and -SelfTest below drives these exact code paths over a
# temp fixture. See [[fix-needs-reachable-selftest]].

# -Adopt matches a bare name ('recipe-writer.md', 'recipe-hunter') or the kind|name form ('skill|recipe-hunter'),
# so the name a person reads in a NO BACKUP line is a name they can paste straight back in. '*' means all.
function Test-AdoptName {
  param([string[]]$AdoptNames, [string]$Kind, [string]$Name)
  foreach ($a in @($AdoptNames)) {
    $t = ([string]$a).Trim()
    if (-not $t) { continue }
    if ($t -eq '*') { return $true }
    if ($t -ieq $Name) { return $true }
    if ($t -ieq ($Kind + '|' + $Name)) { return $true }
  }
  return $false
}

# Returns 'refreshed' | 'adopted' | 'held' | '' (nothing to do).
# 'held' is the deliberate outcome, not a failure: the file has no mirror, nothing named it for adoption,
# so it stays local and the report keeps saying NO BACKUP until a person decides.
function Copy-PromptToMirror {
  param([string]$Src, [string]$Dst, [switch]$DoMirror, [string[]]$AdoptNames, [string]$Kind, [string]$Name)
  if (Test-Path $Dst) {
    if (-not $DoMirror) { return '' }
    if ((FileHash1 $Src) -eq (FileHash1 $Dst)) { return '' }
    Copy-Item $Src $Dst -Force
    return 'refreshed'
  }
  # NO MIRROR YET. -SyncMirror must never reach past this line: ops\prompt-backup is tracked in a repository
  # that loads without a login, and "the mirror is stale" and "this file has never been published" are not
  # the same decision. Only -Adopt crosses it.
  if (-not (Test-AdoptName $AdoptNames $Kind $Name)) { return 'held' }
  $d = Split-Path $Dst -Parent
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  Copy-Item $Src $Dst -Force
  return 'adopted'
}

function Invoke-PromptSync {
  param(
    [string]$Proj, [string]$UserDir, [string]$Tasks, [string]$Backup, [string]$Skills = '',
    [hashtable]$Exempt = $null,
    [switch]$DoScopes, [switch]$DoMirror, [string[]]$AdoptNames = @()
  )
  if ($null -eq $Exempt) { $Exempt = @{} }
  $log = New-Object System.Collections.Generic.List[string]
  $mirrored = 0; $adopted = 0; $scoped = 0; $held = 0; $scopeHeld = 0
  $agentBk = Join-Path $Backup 'agents'
  $taskBk  = Join-Path $Backup 'scheduled-tasks'
  $skillBk = Join-Path $Backup 'skills'
  # Only ever create the mirror ROOTS. The per-file directories are created by Copy-PromptToMirror, and only
  # on the adopt path - so a -SyncMirror run cannot leave an empty scheduled-tasks\<private-task>\ behind it
  # naming a task it was never allowed to publish.
  if ($DoMirror -or (@($AdoptNames).Count)) {
    New-Item -ItemType Directory -Force $agentBk | Out-Null
    New-Item -ItemType Directory -Force $taskBk | Out-Null
  }

  foreach ($f in @(Get-ChildItem (Join-Path $Proj '*.md') -ErrorAction SilentlyContinue)) {
    $r = Copy-PromptToMirror $f.FullName (Join-Path $agentBk $f.Name) -DoMirror:$DoMirror -AdoptNames $AdoptNames -Kind 'agent' -Name $f.Name
    if ($r -eq 'refreshed') { $mirrored++; $log.Add("  mirror refreshed  agents\$($f.Name)") }
    elseif ($r -eq 'adopted') { $adopted++; $log.Add("  ADOPTED into the public mirror  agents\$($f.Name)") }
    elseif ($r -eq 'held') { $held++ }
    # project scope is canonical (it is what wins when the session sits in the project); make user match.
    # A user-scope file that does not exist is NOT created here: this mode exists to end a disagreement
    # between two live copies, not to mint a second copy of a prompt that only has one.
    if ($DoScopes) {
      $u = Join-Path $UserDir $f.Name
      if ((Test-Path $u) -and ((FileHash1 $f.FullName) -ne (FileHash1 $u))) {
        # NEWER AT USER SCOPE MEANS A HUMAN EDITED THE WRONG COPY. Do not overwrite it (2026-09-05).
        # This sync runs unattended every morning and there is no backup of what it clobbers, so a blind
        # project -> user copy turns "you edited the file whose scope your session does not use" into
        # SILENT DATA LOSS. Canonicality decides which copy WINS a tie, not whose work may be destroyed.
        # Report it and leave both alone: a visible finding costs a minute, a lost prompt edit costs the
        # edit plus the trust in the sync. The finding clears itself the moment the edit is carried into
        # project scope, which is where it belonged.
        if ((Get-Item $u).LastWriteTimeUtc -gt (Get-Item $f.FullName).LastWriteTimeUtc) {
          $scopeHeld++
          $log.Add("  HELD  $($f.Name) - the USER-scope copy is NEWER than project scope, so someone edited the copy this sync would overwrite. Not touched. Carry the edit into .claude\agents\$($f.Name) (project scope is canonical) and this clears itself.")
        } else {
          Copy-Item $f.FullName $u -Force; $scoped++
          $log.Add("  scope-synced user copy of $($f.Name) from project scope")
        }
      }
    }
  }
  foreach ($f in @(Get-ChildItem (Join-Path $UserDir '*.md') -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $Proj $f.Name)) { continue }
    $r = Copy-PromptToMirror $f.FullName (Join-Path $agentBk $f.Name) -DoMirror:$DoMirror -AdoptNames $AdoptNames -Kind 'agent' -Name $f.Name
    if ($r -eq 'refreshed') { $mirrored++; $log.Add("  mirror refreshed  agents\$($f.Name) (user scope only)") }
    elseif ($r -eq 'adopted') { $adopted++; $log.Add("  ADOPTED into the public mirror  agents\$($f.Name) (user scope only)") }
    elseif ($r -eq 'held') { $held++ }
  }
  foreach ($d in @(Get-ChildItem $Tasks -Directory -ErrorAction SilentlyContinue)) {
    $s = Join-Path $d.FullName 'SKILL.md'
    if (-not (Test-Path $s)) { continue }
    # THE EXEMPTION IS ENFORCED HERE, NOT ONLY REPORTED, AND IN EVERY MODE. Without this line the finding
    # would say "deliberately not mirrored" and the very next sync would mirror it anyway - into a public
    # repo. This loop is the only thing that can mint that leak, so this is where it is refused.
    if ($Exempt.ContainsKey('scheduled-task|' + $d.Name.ToLower())) {
      $log.Add('  skipped scheduled-tasks\' + $d.Name + '\SKILL.md - EXEMPT (' + $Exempt['scheduled-task|' + $d.Name.ToLower()] + ')')
      continue
    }
    $dst = Join-Path (Join-Path $taskBk $d.Name) 'SKILL.md'
    $r = Copy-PromptToMirror $s $dst -DoMirror:$DoMirror -AdoptNames $AdoptNames -Kind 'scheduled-task' -Name $d.Name
    if ($r -eq 'refreshed') { $mirrored++; $log.Add("  mirror refreshed  scheduled-tasks\$($d.Name)\SKILL.md") }
    elseif ($r -eq 'adopted') { $adopted++; $log.Add("  ADOPTED into the public mirror  scheduled-tasks\$($d.Name)\SKILL.md") }
    elseif ($r -eq 'held') { $held++ }
    # e.g. SKILL.monolith-fallback.md - same file, same rules, one per file
    foreach ($extra in @(Get-ChildItem (Join-Path $d.FullName '*.md') -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'SKILL.md' })) {
      $r = Copy-PromptToMirror $extra.FullName (Join-Path (Join-Path $taskBk $d.Name) $extra.Name) -DoMirror:$DoMirror -AdoptNames $AdoptNames -Kind 'scheduled-task' -Name $d.Name
      if ($r -eq 'refreshed') { $mirrored++ } elseif ($r -eq 'adopted') { $adopted++ } elseif ($r -eq 'held') { $held++ }
    }
  }
  if ($Skills) {
    foreach ($d in @(Get-ChildItem $Skills -Directory -ErrorAction SilentlyContinue)) {
      $s = Join-Path $d.FullName 'SKILL.md'
      if (-not (Test-Path $s)) { continue }
      $dst = Join-Path (Join-Path $skillBk $d.Name) 'SKILL.md'
      $r = Copy-PromptToMirror $s $dst -DoMirror:$DoMirror -AdoptNames $AdoptNames -Kind 'skill' -Name $d.Name
      if ($r -eq 'refreshed') { $mirrored++; $log.Add("  mirror refreshed  skills\$($d.Name)\SKILL.md") }
      elseif ($r -eq 'adopted') { $adopted++; $log.Add("  ADOPTED into the public mirror  skills\$($d.Name)\SKILL.md") }
      elseif ($r -eq 'held') { $held++ }
      foreach ($extra in @(Get-ChildItem (Join-Path $d.FullName '*.md') -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'SKILL.md' })) {
        $r = Copy-PromptToMirror $extra.FullName (Join-Path (Join-Path $skillBk $d.Name) $extra.Name) -DoMirror:$DoMirror -AdoptNames $AdoptNames -Kind 'skill' -Name $d.Name
        if ($r -eq 'refreshed') { $mirrored++ } elseif ($r -eq 'adopted') { $adopted++ } elseif ($r -eq 'held') { $held++ }
      }
    }
  }
  return @{ mirrored = $mirrored; adopted = $adopted; scoped = $scoped; held = $held; scope_held = $scopeHeld; log = $log }
}

# WHICH QUESTION A RUN ANSWERS (2026-09-23, W8.4). The default is the push-time question, because the default is
# what run-gates runs on every push. A write mode's report stays the whole check it always was, so capture-run's
# prompt-sync line reads exactly as before. -Full with -Daily is refused: they are different questions.
function Get-PbJudgeMode {
  param([bool]$Full, [bool]$Daily, [bool]$Writing)
  if ($Full -and $Daily) { return 'refused' }
  if ($Daily) { return 'daily' }
  if ($Full -or $Writing) { return 'full' }
  return 'push'
}

# ---- THE VERDICT, IN THREE MODES (2026-09-23, W8.4, D15) - see PUSH SCOPE and -Daily in the header ---------
# One function decides and prints for every mode, and returns Code, Lines and Summary instead of exiting, so the
# self-test drives the exact path a real run takes over a temp repo. The caller prints the lines, then leaves
# through the guard contract: 3 with no marker (BLIND, as before), 0 through Write-GuardComplete, 2 through Exit-Guard.
# `failed` in the summary is what exit 2 stands on; REVIEW (push) and FRESH (daily) are what it printed and passed.
function Invoke-PromptAudit {
  param(
    [ValidateSet('push', 'full', 'daily')][string]$Mode,
    [string]$RepoRoot, [string]$Proj, [string]$UserDir, [string]$Tasks, [string]$Backup, [string]$Skills = '',
    [hashtable]$Exempt = $null, [bool]$IsMain = $false, [string]$MainRoot = '',
    [string]$Ref = $script:PbPushRef, [datetime]$NowUtc = [DateTime]::UtcNow
  )
  if ($null -eq $Exempt) { $Exempt = @{} }
  $lines = [System.Collections.Generic.List[string]]::new()
  $modeLines = [System.Collections.Generic.List[string]]::new()
  $own = @(); $soft = @(); $softTag = ''; $all = @(); $tail = ''
  $selfHit = @()
  $readFrom = if ($IsMain) { ('  agent prompts and project skills read from ' + $RepoRoot + ' (the main checkout)') }
              else { ('  agent prompts and project skills read from ' + $RepoRoot + ' - NOT the main checkout: this compares this checkout''s prompts with its own mirror, and SCOPE DRIFT is judged only in ' + $MainRoot) }
  $tmpRoot = ''
  try {
    switch ($Mode) {
      'push' {
        $res = Compare-Prompts $Proj $UserDir $Tasks $Backup $Skills $Exempt -SkipScopeDrift:(-not $IsMain) -RepoRoot $RepoRoot
        $all = @($res.findings)
        $scope = Get-PbPushScope -RepoRoot $RepoRoot -Ref $Ref
        if ($scope.Ok) {
          $sp = Split-PbFindingsByPush -Findings $all -Changed $scope.Changed
          $own = @($sp.Own); $soft = @($sp.Ambient); $selfHit = @($sp.SelfHit)
          $modeLines.Add('  push scope: ' + $scope.Changed.Count + ' file(s) changed since the merge-base ' + $scope.Base.Substring(0, 12) + ' with ' + $Ref + '; a finding fails only when it compares one of them')
          if ($selfHit.Count) { $modeLines.Add('  push scope: this push changes ' + ($selfHit -join ', ') + ', so EVERY finding is judged, as -Full would') }
          $tail = ('changed=' + $scope.Changed.Count)
        } else {
          $own = $all
          $modeLines.Add('  push scope: could not read what this push changed (' + $scope.Why + ') - judging every finding, as this audit did before 2026-09-23')
          $tail = 'scope=unread'
        }
        $softTag = 'review'
      }
      'full' {
        $res = Compare-Prompts $Proj $UserDir $Tasks $Backup $Skills $Exempt -SkipScopeDrift:(-not $IsMain) -RepoRoot $RepoRoot
        $all = @($res.findings); $own = $all
        $tail = 'source=working-tree'
      }
      'daily' {
        $exp = Export-PbCommittedTree -RepoRoot $RepoRoot -Ref $Ref
        if ($exp.Ok) {
          $tmpRoot = $exp.Root
          $res = Compare-Prompts (Join-Path $exp.Tree '.claude\agents') $UserDir $Tasks (Join-Path $exp.Tree 'ops\prompt-backup') (Join-Path $exp.Tree '.claude\skills') $Exempt -SkipScopeDrift
          $readFrom = ('  daily: the mirror and the project-scope prompts are read AS COMMITTED on ' + $Ref + ' at ' + $exp.Sha.Substring(0, 12) + ' (' + $exp.Files + ' file(s)), against the scheduled-task SKILLs and user-scope agents every checkout shares')
          $tail = ('source=' + $exp.Sha.Substring(0, 12))
        } else {
          $res = Compare-Prompts $Proj $UserDir $Tasks $Backup $Skills $Exempt -SkipScopeDrift
          $modeLines.Add('  daily: could not read ' + $Ref + ' (' + $exp.Why + ') - comparing this checkout''s working tree instead, as the weekly check did; a mirror refreshed on disk and never committed reads clean here')
          $tail = 'source=working-tree'
        }
        $allList = [System.Collections.Generic.List[object]]::new()
        foreach ($f in @($res.findings)) { $allList.Add($f) }
        if ($IsMain) {
          # SCOPE DRIFT is about what RUNS, so it is read from the main checkout's own files, and only there.
          $sd = Compare-Prompts $Proj $UserDir $Tasks $Backup $Skills $Exempt -RepoRoot $RepoRoot
          foreach ($f in @($sd.findings)) { if ($f.Kind -eq 'SCOPE DRIFT') { $allList.Add($f) } }
        } else {
          $modeLines.Add('  daily: scope agreement is not judged outside the main checkout (' + $MainRoot + ')')
        }
        $all = $allList.ToArray()
        $ag = Split-PbFindingsByAge -Findings $all -NowUtc $NowUtc
        $own = @($ag.Paged); $soft = @($ag.Fresh); $softTag = 'fresh'
        $modeLines.Add('  daily: a finding fails only when it is more than ' + $script:PbDailyBarSec + ' s (24 h) old; a younger one prints FRESH')
      }
      default { throw ('unknown prompt-backup mode: ' + $Mode) }
    }
  } finally {
    if ($tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
  }

  $lines.Add('prompt-backup: checked ' + $res.checked + ' live prompt(s) against ops\prompt-backup')
  $lines.Add($readFrom)
  if ($res.checked -eq 0) {
    $lines.Add('PROMPT-BACKUP BLIND: found ZERO live prompts to check. Either the .claude paths moved or this ran somewhere without them - a clean result here would mean nothing.')
    return [pscustomobject]@{ Code = 3; Lines = $lines.ToArray(); Summary = '' }
  }
  foreach ($m in $modeLines) { $lines.Add($m) }
  # The EXEMPT lines print on every run, clean or not. A deliberate non-mirror that nobody can see turns back
  # into an accident the first time someone new reads this output and "fixes" it.
  foreach ($n in $res.notes) { $lines.Add('  ' + $n) }
  foreach ($f in @($soft)) {
    if ($softTag -eq 'review') {
      $names = if (@($f.Repo).Count) { (@($f.Repo) -join ', ') } else { 'no file in this repo' }
      $lines.Add('  REVIEW  ' + $f.Text + ' - not this push''s: it compares ' + $names + ', none of which this push changed. -Daily pages it once it is over a day old.')
    } else {
      $lines.Add('  FRESH   ' + $f.Text + ' - ' + $f.Age + ', inside the 24 h bar, so not paged; it fails a later -Daily run if it still stands')
    }
  }
  $summary = ('mode=' + $Mode + ' scanned=' + $res.checked + ' findings=' + @($all).Count + ' failed=' + @($own).Count)
  if ($softTag) { $summary += (' ' + $softTag + '=' + @($soft).Count) }
  if ($tail) { $summary += (' ' + $tail) }

  if (@($own).Count -eq 0) {
    if (@($soft).Count -gt 0 -and $softTag -eq 'review') {
      $lines.Add('  ok for this push - nothing it changed disagrees with its counterpart; the ' + @($soft).Count + ' REVIEW finding(s) above are not this push''s to fix')
    } elseif (@($soft).Count -gt 0) {
      $lines.Add('  ok - nothing on the mirror has disagreed with its live copy for over 24 hours; the ' + @($soft).Count + ' FRESH finding(s) above are younger than that')
    } elseif ($Mode -eq 'daily') {
      $lines.Add('  ok - the mirror as committed matches every live agent prompt, scheduled-task SKILL and project-scope skill' + $(if ($IsMain) { ', and the scopes agree' } else { '' }))
    } elseif ($IsMain) {
      $lines.Add('  ok - every live agent prompt, scheduled-task SKILL and project-scope skill is backed up, current, and identical across scopes')
    } else {
      $lines.Add('  ok - this checkout''s agent prompts and project skills match its mirror, and every scheduled-task SKILL is backed up and current (scope agreement not judged outside the main checkout)')
    }
    return [pscustomobject]@{ Code = 0; Lines = $lines.ToArray(); Summary = $summary }
  }
  $lines.Add('  ' + @($own).Count + ' issue(s):')
  foreach ($i in @($own)) {
    if ($Mode -eq 'daily') { $lines.Add('    ' + $i.Text + '  (' + $i.Age + ')') } else { $lines.Add('    ' + $i.Text) }
  }
  if ($Mode -eq 'push' -and -not $selfHit.Count -and $softTag -eq 'review' -and $tail -ne 'scope=unread') {
    $lines.Add('  Each finding above compares a file this push changed, so it is this push''s to fix before it lands.')
  }
  # THE REMEDY IS PRINTED BY RISK, NOT AS ONE BUTTON (2026-09-05). The old line said "-Sync", and -Sync also
  # mirrors files into a PUBLIC repo - so test-auditors had to counter-print "do NOT reflexively -Sync" and the
  # real repair went unmade for 13 days. STALE BACKUP and SCOPE DRIFT have a safe, automated lane now.
  # NO BACKUP is the one finding that still needs a person, and it says so.
  $lines.Add('  Fix: -SyncScopes (project -> user, local only) and -SyncMirror (refresh mirrors that already exist) are safe and run daily from capture-run.ps1; then commit ops\prompt-backup.')
  if ((@($own | ForEach-Object { $_.Text }) -join ' ') -match 'NO BACKUP') {
    $lines.Add('       A NO BACKUP line is a DECISION, not a chore: adopting publishes that file into a repo that loads without a login. Adopt it deliberately (-Adopt <name>, e.g. -Adopt recipe-writer.md or -Adopt skill|recipe-hunter) or exempt it in ops\prompt-backup-exempt.json.')
  }
  return [pscustomobject]@{ Code = 2; Lines = $lines.ToArray(); Summary = $summary }
}

if ($SelfTest) {
  # Clear-TcGitRepoEnv, called before the end-to-end cases build their temp repo (ops\audit-git-fixture-env.ps1).
  . (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\git-repo-env.ps1')
  $fail = 0
  # THE CASE COUNT IS COUNTED, NOT TYPED (2026-09-05). The closing line read "20 prompt-backup cases" over a
  # body holding 19: a hand-maintained tally is one more copy of a fact, and the copy that nobody re-derives
  # is the one that goes stale. Same lesson as [[same-fact-published-twice]], applied to the suite's own size.
  # AND THE COUNT IS ASSERTED AGAINST THE LITERAL LIST (2026-09-23, W8.4). The printed number is still counted,
  # never typed; what is typed is how many cases this file HOLDS, and a run that reaches fewer (a case that threw
  # its way past the rest, a helper that shadowed _C) is a failure rather than a smaller PASS. A case added
  # without moving this number goes red on its first run, which is the loud direction.
  $expectedCases = 81
  $cases = 0
  function _C($label, $cond) { $script:cases++; if ($cond) { Write-Output "ok    $label" } else { Write-Output "FAIL  $label"; $script:fail++ } }
  $tmp = New-PbTempDir 'promptbk-'
  $p = Join-Path $tmp 'proj'; $u = Join-Path $tmp 'user'; $t = Join-Path $tmp 'tasks'; $b = Join-Path $tmp 'backup'
  foreach ($d in @($p,$u,(Join-Path $t 'demo-task'),(Join-Path $b 'agents'),(Join-Path $b 'scheduled-tasks\demo-task'))) { New-Item -ItemType Directory -Force $d | Out-Null }
  try {
    Set-Content (Join-Path $p 'a.md') "prompt v1" -Encoding UTF8
    Set-Content (Join-Path $u 'a.md') "prompt v1" -Encoding UTF8
    Set-Content (Join-Path $b 'agents\a.md') "prompt v1" -Encoding UTF8
    Set-Content (Join-Path $t 'demo-task\SKILL.md') "skill v1" -Encoding UTF8
    Set-Content (Join-Path $b 'scheduled-tasks\demo-task\SKILL.md') "skill v1" -Encoding UTF8
    # CLEAN TWIN: everything in sync stays silent
    $r = Compare-Prompts $p $u $t $b
    _C 'clean twin: matching live/backup/scope reports no issue' ($r.issues.Count -eq 0 -and $r.checked -eq 2)
    # MUST-FIRE 1: the live prompt is edited and the backup is not
    Set-Content (Join-Path $p 'a.md') "prompt v2 - edited live" -Encoding UTF8
    Set-Content (Join-Path $u 'a.md') "prompt v2 - edited live" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b
    _C 'must-fire: an edited live prompt with a stale repo copy is caught' (($r.issues -join ' ') -match 'STALE BACKUP  agents\\a\.md')
    # MUST-FIRE 2: the two scopes disagree (the drift this found on its first real run)
    Set-Content (Join-Path $b 'agents\a.md') "prompt v2 - edited live" -Encoding UTF8
    Set-Content (Join-Path $u 'a.md') "prompt v1" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b
    _C 'must-fire: project and user scope disagreeing is caught' (($r.issues -join ' ') -match 'SCOPE DRIFT')
    # MUST-FIRE 3: a live prompt with no backup at all
    Set-Content (Join-Path $u 'a.md') "prompt v2 - edited live" -Encoding UTF8
    Set-Content (Join-Path $p 'b.md') "new prompt nobody backed up" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b
    _C 'must-fire: a live prompt with no backup is caught' (($r.issues -join ' ') -match 'NO BACKUP  agents\\b\.md')
    # MUST-FIRE 4: a SKILL edited without its backup
    Remove-Item (Join-Path $p 'b.md') -Force
    Set-Content (Join-Path $t 'demo-task\SKILL.md') "skill v2" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b
    _C 'must-fire: an edited scheduled-task SKILL with a stale backup is caught' (($r.issues -join ' ') -match 'STALE BACKUP  scheduled-tasks')
    # MUST-FIRE 5: a project-scope SKILL with no backup. THE FOUNDING CASE of this class, frozen: on
    # 2026-08-15 C:\Codex\ThriftyCrew\.claude\skills held three live skills (recipe-hunter, lesson, meal-macro) and
    # this audit reported "every live agent prompt and scheduled-task SKILL is backed up" - true, and
    # blind, because the sentence enumerated only what the guard knew to look at.
    Set-Content (Join-Path $t 'demo-task\SKILL.md') "skill v1" -Encoding UTF8
    $sk = Join-Path $tmp 'skills'; New-Item -ItemType Directory -Force (Join-Path $sk 'demo-skill') | Out-Null
    Set-Content (Join-Path $sk 'demo-skill\SKILL.md') "project skill v1" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b $sk
    _C 'must-fire: a project-scope SKILL with no backup is caught' (($r.issues -join ' ') -match 'NO BACKUP  skills\\demo-skill')
    # ...and once backed up it goes quiet, then fires again when the live copy is edited
    New-Item -ItemType Directory -Force (Join-Path $b 'skills\demo-skill') | Out-Null
    Set-Content (Join-Path $b 'skills\demo-skill\SKILL.md') "project skill v1" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b $sk
    _C 'clean twin: a backed-up project-scope SKILL reports no issue' (($r.issues -join ' ') -notmatch 'skills\\demo-skill')

    # ---- LINE-ENDING NOISE (2026-09-06, queue 2026-09-06-fdc73a) --------------------------------------
    # FROZEN from the real founding pair. On 2026-09-06 six agent prompts reported STALE BACKUP with the
    # live file LF and its mirror CRLF and the content IDENTICAL - the delta on triage-developer.md was
    # exactly 152 bytes over exactly 152 lines. The bytes below are written here, never read from the
    # live tree: regenerating this fixture from .claude\agents would let the bug vanish under it and the
    # test would then pass by finding nothing.
    $lfBytes  = [Text.Encoding]::UTF8.GetBytes("- - - `nname: frozen-fixture`ndescription: the 2026-09-06 pair`n- - - `n`nBody line one.`nBody line two.`n")
    $crlfSame = [Text.Encoding]::UTF8.GetBytes("- - - `r`nname: frozen-fixture`r`ndescription: the 2026-09-06 pair`r`n- - - `r`n`r`nBody line one.`r`nBody line two.`r`n")
    $crlfDiff = [Text.Encoding]::UTF8.GetBytes("- - - `r`nname: frozen-fixture`r`ndescription: the 2026-09-06 pair`r`n- - - `r`n`r`nBody line one.`r`nBody line two, GENUINELY EDITED.`r`n")
    # the fixture must really be the shape it claims: one CR per line, and equal only after normalization
    _C 'line-endings: the frozen pair really differs by exactly one CR per line (7 lines, 7 bytes)' (($crlfSame.Length - $lfBytes.Length) -eq 7)
    [IO.File]::WriteAllBytes((Join-Path $p 'crlf.md'), $lfBytes)
    [IO.File]::WriteAllBytes((Join-Path $u 'crlf.md'), $lfBytes)
    [IO.File]::WriteAllBytes((Join-Path $b 'agents\crlf.md'), $crlfSame)
    $r = Compare-Prompts $p $u $t $b $sk
    # CLEAN TWIN: this is the case that must go SILENT, and if it does not the fix did not land
    _C 'line-endings CLEAN TWIN: an LF live prompt and a CRLF mirror with identical text report CLEAN' (($r.issues -join ' ') -notmatch 'agents\\crlf\.md')
    # MUST-FIRE: normalization must not swallow a REAL edit that also happens to arrive CRLF
    [IO.File]::WriteAllBytes((Join-Path $b 'agents\crlf.md'), $crlfDiff)
    $r = Compare-Prompts $p $u $t $b $sk
    _C 'line-endings MUST-FIRE: a CRLF mirror whose TEXT differs is still STALE BACKUP' (($r.issues -join ' ') -match 'STALE BACKUP  agents\\crlf\.md')
    # MUST-FIRE: a NUL byte means binary, and binary is still compared raw - a 0x0D there is content
    $binA = [byte[]](0x00,0x0D,0x0A,0x41)
    $binB = [byte[]](0x00,0x0A,0x41)
    [IO.File]::WriteAllBytes((Join-Path $p 'bin.md'), $binA)
    [IO.File]::WriteAllBytes((Join-Path $u 'bin.md'), $binA)
    [IO.File]::WriteAllBytes((Join-Path $b 'agents\bin.md'), $binB)
    $r = Compare-Prompts $p $u $t $b $sk
    _C 'line-endings MUST-FIRE: a file carrying a NUL byte is compared raw, so a dropped CR still fires' (($r.issues -join ' ') -match 'STALE BACKUP  agents\\bin\.md')
    Remove-Item (Join-Path $p 'crlf.md'),(Join-Path $u 'crlf.md'),(Join-Path $b 'agents\crlf.md') -Force
    Remove-Item (Join-Path $p 'bin.md'),(Join-Path $u 'bin.md'),(Join-Path $b 'agents\bin.md') -Force
    Set-Content (Join-Path $sk 'demo-skill\SKILL.md') "project skill v2 - edited live" -Encoding UTF8
    $r = Compare-Prompts $p $u $t $b $sk
    _C 'must-fire: an edited project-scope SKILL with a stale backup is caught' (($r.issues -join ' ') -match 'STALE BACKUP  skills\\demo-skill')
    # and the skills dir counts toward `checked`, or a skills-only machine would report BLIND as clean
    _C 'project-scope skills count toward the coverage tally' ($r.checked -ge 3)

    # ---- THE EXEMPTION LIST (2026-09-04, queue 2026-09-04-0b63d3) --------------------------------------
    # Founding case, frozen: a PERSONAL scheduled task (a flight-price watch carrying travel dates and alert
    # recipients) was reported NO BACKUP, and the remedy this audit prints - -Sync - would have copied it
    # into ops\prompt-backup, which is tracked in a repository that loads without a login.
    # MUST FIRE: a live task with no mirror and NO exemption is still a finding. The whole exemption
    # mechanism is worthless if it can be reached accidentally, so the unexempted twin is asserted first.
    $t2 = Join-Path $tmp 'tasks2'
    New-Item -ItemType Directory -Force (Join-Path $t2 'personal-watch') | Out-Null
    Set-Content (Join-Path $t2 'personal-watch\SKILL.md') "private task v1" -Encoding UTF8
    $r = Compare-Prompts $p $u $t2 $b
    _C 'must-fire: a live scheduled-task SKILL with no backup and NO exemption still reports NO BACKUP' `
      (($r.issues -join ' ') -match 'NO BACKUP  scheduled-tasks\\personal-watch')
    # CLEAN TWIN: the same task, exempted. EXEMPT is a note, not an issue - and it still COUNTS as checked,
    # because dropping it out of the tally would shrink the number that proves this audit looked at all.
    $exMap = @{ 'scheduled-task|personal-watch' = 'personal, carries travel dates; the mirror is public' }
    $r = Compare-Prompts $p $u $t2 $b '' $exMap
    _C 'clean twin: an EXEMPT scheduled task is not an issue' (($r.issues -join ' ') -notmatch 'personal-watch')
    _C '  ...and it prints an EXEMPT line naming its reason' (($r.notes -join ' ') -match 'EXEMPT  scheduled-tasks\\personal-watch\\SKILL\.md - personal, carries travel dates')
    _C '  ...and it still counts toward the coverage tally' ($r.checked -ge 1)
    # The exemption is keyed on KIND as well as name: an agent prompt of the same name is NOT exempted by a
    # scheduled-task entry, or one line in this file could quietly cover files nobody meant it to.
    $exWrongKind = @{ 'skill|personal-watch' = 'wrong kind' }
    $r = Compare-Prompts $p $u $t2 $b '' $exWrongKind
    _C 'must-fire: an exemption of a DIFFERENT kind does not exempt the task' (($r.issues -join ' ') -match 'NO BACKUP  scheduled-tasks\\personal-watch')
    # MUST FIRE: the LIST ITSELF. A missing list is "nothing exempt"; an unreadable or malformed one is a
    # question this audit cannot answer, and it must say so rather than default either way.
    $exDir = Join-Path $tmp 'exempt'; New-Item -ItemType Directory -Force $exDir | Out-Null
    $exOk = Join-Path $exDir 'good.json'
    Set-Content $exOk '{ "exempt": [ { "kind": "scheduled-task", "name": "personal-watch", "reason": "personal" } ] }' -Encoding UTF8
    $exBad = Join-Path $exDir 'bad.json'
    Set-Content $exBad '{ "exempt": [ { "kind": "scheduled-task", ' -Encoding UTF8      # truncated on purpose
    $exNoName = Join-Path $exDir 'noname.json'
    Set-Content $exNoName '{ "exempt": [ { "kind": "scheduled-task", "reason": "oops" } ] }' -Encoding UTF8
    _C 'clean twin: a MISSING exemption list means nothing is exempt, not everything' ((Get-PromptExemptions (Join-Path $exDir 'does-not-exist.json')).Count -eq 0)
    _C 'clean twin: a well-formed list parses to exactly its entries, keyed kind|name' `
      ((Get-PromptExemptions $exOk).ContainsKey('scheduled-task|personal-watch'))
    $threw = $false; try { $null = Get-PromptExemptions $exBad } catch { $threw = $true }
    _C 'must-fire: a MALFORMED exemption list throws (the caller exits 3 BLIND, never clean)' $threw
    $threw = $false; try { $null = Get-PromptExemptions $exNoName } catch { $threw = $true }
    _C 'must-fire: an entry with no name throws rather than exempting nothing silently' $threw

    # ---- THE WRITE MODES, SPLIT BY RISK (2026-09-05, queue 2026-09-05-5650ce) --------------------------
    # Founding case, frozen: this audit printed the same seven findings every morning for 13 days and
    # nothing moved, because its only remedy - -Sync - ALSO publishes files into a repository that loads
    # without a login, so no automation was allowed anywhere near it. The split makes the safe half
    # automatable, and these cases pin exactly where the line falls: refreshing a mirror that already
    # exists publishes nothing new, CREATING one publishes a file for the first time, and the scope follow
    # touches nothing public at all. Every mode is driven here over a temp fixture, because a repair lane
    # nobody can test is a repair lane nobody will let run unattended.
    $s2 = Join-Path $tmp 'sync'
    $sp = Join-Path $s2 'proj'; $su = Join-Path $s2 'user'; $st = Join-Path $s2 'tasks'; $sb = Join-Path $s2 'backup'
    foreach ($d in @($sp, $su, (Join-Path $st 'mirrored-task'), (Join-Path $st 'private-task'),
                     (Join-Path $sb 'agents'), (Join-Path $sb 'scheduled-tasks\mirrored-task'))) {
      New-Item -ItemType Directory -Force $d | Out-Null
    }
    Set-Content (Join-Path $sp 'drifted.md') "project v2 - edited in the repo" -Encoding UTF8   # STALE BACKUP + SCOPE DRIFT
    Set-Content (Join-Path $su 'drifted.md') "project v1" -Encoding UTF8
    Set-Content (Join-Path $sb 'agents\drifted.md') "project v1" -Encoding UTF8
    # MTIME IS LOAD-BEARING FROM 2026-09-05 and the write order above made it lie. The fixture's own content
    # says which copy is newer - project is "v2 - edited in the repo", user is "v1" - but Set-Content ran
    # last on the user copy, so on disk the STALE one was the newer one. That is not what this fixture
    # asserts, and -SyncScopes now refuses to overwrite a newer user copy, so leaving the timestamps
    # backwards would have made the sync cases below pass or fail on an accident of setup order rather than
    # on the behaviour they name. Stamp it to agree with the content.
    (Get-Item (Join-Path $su 'drifted.md')).LastWriteTimeUtc = (Get-Item (Join-Path $sp 'drifted.md')).LastWriteTimeUtc.AddMinutes(-5)
    Set-Content (Join-Path $sp 'fresh.md') "a prompt that has never been mirrored" -Encoding UTF8  # NO BACKUP
    Set-Content (Join-Path $st 'mirrored-task\SKILL.md') "task v1" -Encoding UTF8
    Set-Content (Join-Path $sb 'scheduled-tasks\mirrored-task\SKILL.md') "task v1" -Encoding UTF8
    Set-Content (Join-Path $st 'private-task\SKILL.md') "private v1" -Encoding UTF8               # NO BACKUP
    $r = Compare-Prompts $sp $su $st $sb
    _C 'must-fire: before any sync the drifted agent is BOTH stale in the mirror and drifted across scopes' `
      ((($r.issues -join ' ') -match 'STALE BACKUP  agents\\drifted\.md') -and (($r.issues -join ' ') -match 'SCOPE DRIFT  drifted\.md'))
    # MUST-FIRE: -SyncMirror must never adopt. This is the line the whole split exists to draw.
    $null = Invoke-PromptSync $sp $su $st $sb '' @{} -DoMirror
    _C 'must-fire: -SyncMirror does NOT adopt a live scheduled-task SKILL that has no mirror' `
      (-not (Test-Path (Join-Path $sb 'scheduled-tasks\private-task\SKILL.md')))
    _C 'must-fire: -SyncMirror does NOT adopt a live agent prompt that has no mirror either' `
      (-not (Test-Path (Join-Path $sb 'agents\fresh.md')))
    $r = Compare-Prompts $sp $su $st $sb
    _C '  ...and both are still reported NO BACKUP afterwards, so the person still gets the decision' `
      ((($r.issues -join ' ') -match 'NO BACKUP  scheduled-tasks\\private-task') -and (($r.issues -join ' ') -match 'NO BACKUP  agents\\fresh\.md'))
    # CLEAN TWIN: the file that DOES have a mirror is refreshed by that same call, and only that half moved.
    _C 'clean twin: -SyncMirror DOES refresh a mirror that already exists (STALE BACKUP goes quiet)' `
      (($r.issues -join ' ') -notmatch 'STALE BACKUP  agents\\drifted\.md')
    _C '  ...and -SyncMirror alone leaves user scope alone (SCOPE DRIFT still reported)' `
      (($r.issues -join ' ') -match 'SCOPE DRIFT  drifted\.md')
    # MUST-FIRE then CLEAN: SCOPE DRIFT is reported before -SyncScopes and silent after - and the backup
    # directory is byte-for-byte unchanged across it, or "local only" is a claim rather than a property.
    $bkBefore = ((Get-ChildItem $sb -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName + '|' + (FileHash1 $_.FullName) }) -join "`n")
    $null = Invoke-PromptSync $sp $su $st $sb '' @{} -DoScopes
    $r = Compare-Prompts $sp $su $st $sb
    _C 'clean twin: SCOPE DRIFT reported before -SyncScopes is silent after it' (($r.issues -join ' ') -notmatch 'SCOPE DRIFT')
    $bkAfter = ((Get-ChildItem $sb -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName + '|' + (FileHash1 $_.FullName) }) -join "`n")
    _C '  ...and -SyncScopes wrote NOTHING into the public mirror (identical file set and hashes)' ($bkBefore -eq $bkAfter)
    # MUST-FIRE (2026-09-05): -SyncScopes runs UNATTENDED every morning and keeps no backup of what it
    # overwrites, so a user-scope file that is NEWER than project scope is someone's edit and must survive.
    # Canonicality decides which copy WINS A TIE; it does not license destroying work. Without this case the
    # sync silently ate the edit and nothing anywhere recorded that a file had ever been different.
    $heldName = Join-Path $sp 'heldback.md'
    Set-Content $heldName "project version`n" -Encoding UTF8
    $heldUser = Join-Path $su 'heldback.md'
    Set-Content $heldUser "a HUMAN edited this at user scope`n" -Encoding UTF8
    (Get-Item $heldUser).LastWriteTimeUtc = (Get-Item $heldName).LastWriteTimeUtc.AddMinutes(5)
    $sr2 = Invoke-PromptSync $sp $su $st $sb '' @{} -DoScopes
    _C 'must-fire: -SyncScopes REFUSES to overwrite a user-scope copy that is NEWER than project scope' `
      ((Get-Content $heldUser -Raw) -match 'a HUMAN edited this')
    _C '  ...and it says so, naming the file and where the edit belongs' `
      ((($sr2.log -join ' ') -match 'HELD  heldback\.md') -and (($sr2.log -join ' ') -match 'project scope is canonical'))
    _C '  ...and counts it separately from a mirror hold (scope_held is its own number, not folded into held)' `
      ([int]$sr2.scope_held -eq 1)
    # CLEAN TWIN: the same file with project scope NEWER is still synced. If this goes quiet the guard has
    # stopped syncing anything and the 13-day drift is simply back under a different name.
    (Get-Item $heldName).LastWriteTimeUtc = (Get-Item $heldUser).LastWriteTimeUtc.AddMinutes(5)
    $sr3 = Invoke-PromptSync $sp $su $st $sb '' @{} -DoScopes
    _C 'clean twin: when PROJECT scope is the newer copy, -SyncScopes still overwrites user scope as before' `
      (((Get-Content $heldUser -Raw) -match 'project version') -and ([int]$sr3.scoped -ge 1))
    Remove-Item $heldName, $heldUser -Force -ErrorAction SilentlyContinue
    # -Adopt is NAMED, so it adopts what was named and nothing else. A mode that quietly adopted its
    # neighbours would be -Sync again under a safer-sounding flag.
    $null = Invoke-PromptSync $sp $su $st $sb '' @{} -AdoptNames @('fresh.md')
    _C 'clean twin: -Adopt <name> publishes the file it names' (Test-Path (Join-Path $sb 'agents\fresh.md'))
    _C 'must-fire: -Adopt <name> publishes NOTHING ELSE (the unnamed private task stays local)' `
      (-not (Test-Path (Join-Path $sb 'scheduled-tasks\private-task\SKILL.md')))
    # CLEAN TWIN: the EXEMPT task is untouched by EVERY mode, -Sync's own -Adopt * included. The exemption
    # is the only thing standing between a personal scheduled task and a public repo, so it is asserted
    # against the mode that adopts everything, not only against the cautious ones.
    $exSync = @{ 'scheduled-task|private-task' = 'personal, carries travel dates; the mirror is public' }
    $null = Invoke-PromptSync $sp $su $st $sb '' $exSync -DoScopes -DoMirror -AdoptNames @('*')
    _C 'clean twin: an EXEMPT task is untouched by -SyncScopes, -SyncMirror AND -Adopt * (the -Sync alias)' `
      (-not (Test-Path (Join-Path $sb 'scheduled-tasks\private-task')))
    # ...and the identical call WITHOUT the exemption does publish it. Without this, the case above would
    # also pass for a mode that adopts nothing at all - a guard proving its own inaction.
    $null = Invoke-PromptSync $sp $su $st $sb '' @{} -AdoptNames @('*')
    _C '  ...and the same call with no exemption DOES adopt it, so the case above proves the exemption' `
      (Test-Path (Join-Path $sb 'scheduled-tasks\private-task\SKILL.md'))

    # ---- WHICH TREE IS LIVE (2026-09-11) ------------------------------------------------------------
    # FROZEN from the founding push: the Hy-Vee Omaha #02 pricer fix was committed WITH its refreshed mirror
    # in a worktree and read STALE BACKUP, because $PROJ was the main checkout, which had not pulled it yet.
    # The paths below are built here, never read from the live tree, so the fixture cannot drift with it.
    $wm     = Join-Path $tmp 'which-tree'
    $mainR  = Join-Path $wm 'ThriftyCrew'
    $wtR    = Join-Path $mainR '.claude\worktrees\wt1'
    $wUser  = Join-Path $wm 'user'
    $wTasks = Join-Path $wm 'tasks'
    $wBk    = Join-Path $wtR 'ops\prompt-backup'
    foreach ($d in @((Join-Path $mainR '.claude\agents'), (Join-Path $wtR '.claude\agents'), (Join-Path $wBk 'agents'), $wUser, $wTasks)) {
      New-Item -ItemType Directory -Force $d | Out-Null
    }
    Set-Content (Join-Path $mainR '.claude\agents\pricer.md') "pricer v1 - main has not pulled yet" -Encoding UTF8
    Set-Content (Join-Path $wUser 'pricer.md') "pricer v1 - main has not pulled yet" -Encoding UTF8
    Set-Content (Join-Path $wtR '.claude\agents\pricer.md') "pricer v2 - the commit being pushed" -Encoding UTF8
    Set-Content (Join-Path $wBk 'agents\pricer.md') "pricer v2 - the commit being pushed" -Encoding UTF8
    $wtRoots = Resolve-PromptRoots $wtR $mainR
    $mnRoots = Resolve-PromptRoots ($mainR.ToUpper() + '\') $mainR
    _C 'clean twin: the main checkout resolves as main whatever its case or trailing slash, reading its own .claude\agents' `
      ($mnRoots.is_main -and [string]::Equals($mnRoots.proj, (Join-Path $mainR '.claude\agents'), [StringComparison]::OrdinalIgnoreCase))
    _C 'must-fire: a worktree nested under the main checkout does NOT resolve as main' (-not $wtRoots.is_main)
    _C '  ...and reads its OWN .claude\agents, not the main checkout''s' `
      ([string]::Equals($wtRoots.proj, (Join-Path $wtR '.claude\agents'), [StringComparison]::OrdinalIgnoreCase))
    # The fixture must really be the founding shape, or the MUST NOT FIRE below proves nothing.
    $r = Compare-Prompts (Join-Path $mainR '.claude\agents') $wUser $wTasks $wBk
    _C 'founding shape reproduced: main checkout prompts against the worktree mirror is the STALE BACKUP the push hit' `
      (($r.issues -join ' ') -match 'STALE BACKUP  agents\\pricer\.md')
    $r = Compare-Prompts $wtRoots.proj $wUser $wTasks $wBk $wtRoots.skills @{} -SkipScopeDrift
    _C 'MUST NOT FIRE: a worktree commit whose prompt and mirror agree is clean while main still holds the older copy' `
      (($r.issues.Count -eq 0) -and ($r.checked -eq 1))
    $r = Compare-Prompts $wtRoots.proj $wUser $wTasks $wBk $wtRoots.skills @{}
    _C 'must-fire: the same comparison WITHOUT -SkipScopeDrift reports the older user copy as SCOPE DRIFT, so the skip is what silences it' `
      (($r.issues -join ' ') -match 'SCOPE DRIFT  pricer\.md')
    Set-Content (Join-Path $wtR '.claude\agents\pricer.md') "pricer v3 - edited again, mirror NOT refreshed" -Encoding UTF8
    $r = Compare-Prompts $wtRoots.proj $wUser $wTasks $wBk $wtRoots.skills @{} -SkipScopeDrift
    _C 'must-fire: in a worktree a prompt edited WITHOUT refreshing its mirror is still STALE BACKUP' `
      (($r.issues -join ' ') -match 'STALE BACKUP  agents\\pricer\.md')
    $m = Get-PromptSyncModes $false $true $true 'C:\wt' 'C:\main'
    _C 'must-fire: outside the main checkout -SyncScopes is SKIPPED, and the skip is spoken' `
      ((-not $m.scopes) -and ($m.note -match 'SKIPPED -SyncScopes'))
    _C '  ...while -SyncMirror still runs there, since it writes only that checkout''s own mirror' ([bool]$m.mirror)
    $m = Get-PromptSyncModes $true $true $true 'C:\main' 'C:\main'
    _C 'clean twin: in the main checkout -SyncScopes still runs, as the daily capture-run needs' (([bool]$m.scopes) -and (-not $m.note))

    # ---- PUSH SCOPE AND THE DAILY FLOOR (2026-09-23, W8.4, D15) ---------------------------------------
    # FOUNDING CASE, frozen from the plan's case list (15.3 row 46): a push was refused in the lock over a live
    # prompt edited outside git by another session, 12 s before that session's mirror commit landed. Nothing here
    # reads the live tree: every folder, repo and file below is built under $tmp.
    function _PbW([string]$Path, [string]$Text) {
      $dir = Split-Path $Path -Parent
      if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
      [IO.File]::WriteAllText($Path, ($Text + "`n"), (New-Object Text.UTF8Encoding($false)))
    }
    # (1) a finding names the repo files it compares, in git's spelling
    $sr = Join-Path $tmp 'scope\repo'; $sU = Join-Path $tmp 'scope\user'; $sT = Join-Path $tmp 'scope\tasks'
    $null = New-Item -ItemType Directory -Force -Path $sU
    _PbW (Join-Path $sr '.claude\agents\a.md') 'agent v2'
    _PbW (Join-Path $sr 'ops\prompt-backup\agents\a.md') 'agent v1'
    _PbW (Join-Path $sT 't1\SKILL.md') 'skill v2'
    _PbW (Join-Path $sr 'ops\prompt-backup\scheduled-tasks\t1\SKILL.md') 'skill v1'
    $r = Compare-Prompts (Join-Path $sr '.claude\agents') $sU $sT (Join-Path $sr 'ops\prompt-backup') '' @{} -SkipScopeDrift -RepoRoot $sr
    $fa = @($r.findings | Where-Object { $_.Text -match 'agents\\a\.md' })
    $ft = @($r.findings | Where-Object { $_.Text -match 'scheduled-tasks\\t1' })
    _C 'MUST FIRE  a stale project prompt''s finding names both repo files it compares, the prompt and its mirror' `
      (($fa.Count -eq 1) -and ((@($fa[0].Repo) -join '|') -eq '.claude/agents/a.md|ops/prompt-backup/agents/a.md'))
    _C 'MUST FIRE  a stale scheduled-task finding names its mirror, and no repo file for a live copy outside the repo' `
      (($ft.Count -eq 1) -and ((@($ft[0].Repo) -join '|') -eq 'ops/prompt-backup/scheduled-tasks/t1/SKILL.md'))
    # (2) whose finding is it
    $sp = Split-PbFindingsByPush -Findings $r.findings -Changed (New-PbPathSet @('ops/prompt-backup/scheduled-tasks/t1/SKILL.md'))
    _C 'MUST FIRE  a finding whose mirror this push changed is the push''s own' (@($sp.Own | Where-Object { $_.Text -match 'scheduled-tasks\\t1' }).Count -eq 1)
    _C 'MUST NOT FIRE  a finding comparing no file this push changed is REVIEW, not the push''s' `
      ((@($sp.Ambient | Where-Object { $_.Text -match 'agents\\a\.md' }).Count -eq 1) -and (@($sp.Own | Where-Object { $_.Text -match 'agents\\a\.md' }).Count -eq 0))
    $sp = Split-PbFindingsByPush -Findings $r.findings -Changed (New-PbPathSet @('.CLAUDE/Agents/A.md'))
    _C 'MUST FIRE  a push that edits a prompt and not its mirror owns the finding, whatever the path''s case' (@($sp.Own | Where-Object { $_.Text -match 'agents\\a\.md' }).Count -eq 1)
    $sp = Split-PbFindingsByPush -Findings $r.findings -Changed (New-PbPathSet @('ops/audit-prompt-backup.ps1'))
    _C 'MUST FIRE  a push that changes this audit owns EVERY finding' ($sp.Whole -and (@($sp.Own).Count -eq $r.findings.Count) -and (@($sp.Ambient).Count -eq 0))
    $sp = Split-PbFindingsByPush -Findings $r.findings -Changed (New-PbPathSet @('ops/prompt-backup-exempt.json'))
    _C 'MUST FIRE  a push that changes the exemption list owns EVERY finding' ($sp.Whole -and (@($sp.Own).Count -eq $r.findings.Count))
    $sp = Split-PbFindingsByPush -Findings $r.findings -Changed (New-PbPathSet @())
    _C 'MUST NOT FIRE  a push that changed nothing owns no finding, and still lists both as REVIEW' ((@($sp.Ambient).Count -eq 2) -and (@($sp.Own).Count -eq 0))
    # (3) THE 24-HOUR BAR, AT IT AND ONE SECOND PAST IT, in integer seconds so no double decides it
    $now0 = [DateTime]::new(2026, 9, 23, 12, 0, 0, [DateTimeKind]::Utc)
    $agL = Join-Path $tmp 'age\live.md'; $agM = Join-Path $tmp 'age\mirror.md'
    _PbW $agL 'live'; _PbW $agM 'mirror'
    $agF = [pscustomobject]@{ Kind = 'STALE BACKUP'; Text = 'STALE BACKUP  age fixture'; Sides = @($agL, $agM); Repo = @() }
    [IO.File]::SetLastWriteTimeUtc($agL, $now0.AddSeconds(-86400)); [IO.File]::SetLastWriteTimeUtc($agM, $now0.AddSeconds(-86400))
    $sa = Split-PbFindingsByAge -Findings @($agF) -NowUtc $now0 -BarSec 86400
    _C 'MUST NOT FIRE  AT THE BAR (86400 s = 24 h): a mismatch exactly 86400 s old is FRESH, not paged' ((@($sa.Paged).Count -eq 0) -and (@($sa.Fresh).Count -eq 1))
    [IO.File]::SetLastWriteTimeUtc($agL, $now0.AddSeconds(-86401)); [IO.File]::SetLastWriteTimeUtc($agM, $now0.AddSeconds(-86401))
    $sa = Split-PbFindingsByAge -Findings @($agF) -NowUtc $now0 -BarSec 86400
    _C 'MUST FIRE  ONE SECOND PAST THE BAR (86401 s): the same mismatch is paged' ((@($sa.Paged).Count -eq 1) -and (@($sa.Fresh).Count -eq 0))
    [IO.File]::SetLastWriteTimeUtc($agM, $now0.AddSeconds(-86400))
    $sa = Split-PbFindingsByAge -Findings @($agF) -NowUtc $now0 -BarSec 86400
    _C 'MUST NOT FIRE  the NEWER side decides: a live copy 86401 s old against a mirror changed 86400 s ago is FRESH' (@($sa.Fresh).Count -eq 1)
    $agGone = [pscustomobject]@{ Kind = 'NO BACKUP'; Text = 'NO BACKUP  age fixture'; Sides = @((Join-Path $tmp 'age\absent-1.md'), (Join-Path $tmp 'age\absent-2.md')); Repo = @() }
    $sa = Split-PbFindingsByAge -Findings @($agGone) -NowUtc $now0 -BarSec 86400
    _C 'MUST FIRE  a finding whose age cannot be read is paged, never waved through as FRESH' (@($sa.Paged).Count -eq 1)

    # (4) END TO END, through Invoke-PromptAudit over a temp repo whose refs/remotes/origin/main is the base: the
    # same git calls, the same materialised tree and the same lines a real run prints.
    Clear-TcGitRepoEnv
    $er = Join-Path $tmp 'e2e\repo'; $eU = Join-Path $tmp 'e2e\user'; $eT = Join-Path $tmp 'e2e\tasks'
    $eLive = Join-Path $eT 't1\SKILL.md'; $eMir = Join-Path $er 'ops\prompt-backup\scheduled-tasks\t1\SKILL.md'
    $null = New-Item -ItemType Directory -Force -Path $eU
    _PbW (Join-Path $er '.claude\agents\a.md') 'agent v1'
    _PbW (Join-Path $er 'ops\prompt-backup\agents\a.md') 'agent v1'
    _PbW $eMir 'skill v1'
    _PbW (Join-Path $er 'README.md') 'readme v1'
    _PbW $eLive 'skill v1'
    & git -C $er init -q -b main
    & git -C $er config core.autocrlf false
    & git -C $er config user.name 'pb-fixture'
    & git -C $er config user.email 'pb@fixture.invalid'
    & git -C $er add -A -- .claude ops README.md
    & git -C $er commit -q -m 'base'
    $eBase = ([string](& git -C $er rev-parse HEAD)).Trim()
    & git -C $er update-ref refs/remotes/origin/main $eBase
    function _PbReset { & git -C $er reset -q --hard $eBase; & git -C $er clean -q -f -d; _PbW $eLive 'skill v1' }
    function _PbCommit([string]$Msg, [string[]]$Paths) { & git -C $er add -A -- @Paths; & git -C $er commit -q -m $Msg }
    function _PbRun([string]$Mode, [datetime]$Now) {
      return (Invoke-PromptAudit -Mode $Mode -RepoRoot $er -Proj (Join-Path $er '.claude\agents') -UserDir $eU -Tasks $eT -Backup (Join-Path $er 'ops\prompt-backup') -Skills (Join-Path $er '.claude\skills') -Exempt @{} -IsMain $false -MainRoot (Join-Path $tmp 'e2e\elsewhere') -NowUtc $Now)
    }
    function _PbHas($Run, [string]$Rx) { return [bool](@($Run.Lines | Where-Object { $_ -match $Rx }).Count) }
    $rxT1Stale = 'STALE BACKUP  scheduled-tasks\\t1\\SKILL\.md'
    # a live SKILL edited outside git by another session, and a push that touches no mirror
    _PbReset; _PbW $eLive 'skill v2 - a live edit in another session'
    _PbW (Join-Path $er 'README.md') 'readme v2'; _PbCommit 'unrelated' @('README.md')
    $x = _PbRun 'push' ([DateTime]::UtcNow)
    _C 'MUST NOT FIRE  a push touching no mirror, over a drifted live copy, passes and prints REVIEW naming it' `
      (($x.Code -eq 0) -and (_PbHas $x ('^\s*REVIEW\s+' + $rxT1Stale)) -and ($x.Summary -match 'failed=0 review=1'))
    $x = _PbRun 'daily' ([DateTime]::UtcNow.AddDays(2))
    _C 'MUST FIRE  -Daily fails on that same drift once it is over a day old' (($x.Code -eq 2) -and (_PbHas $x ('^\s+' + $rxT1Stale)))
    $x = _PbRun 'daily' ([DateTime]::UtcNow)
    _C 'MUST NOT FIRE  -Daily prints that same drift FRESH, and passes, while it is under a day old' `
      (($x.Code -eq 0) -and (_PbHas $x ('^\s*FRESH\s+' + $rxT1Stale)))
    # the mirror refreshed on disk and never committed: what capture-run's -SyncMirror leaves in the main checkout
    _PbW $eMir 'skill v2 - a live edit in another session'
    $x = _PbRun 'daily' ([DateTime]::UtcNow.AddDays(2))
    _C 'MUST FIRE  -Daily reads the mirror AS COMMITTED, so one refreshed on disk and never committed still fails' `
      (($x.Code -eq 2) -and (_PbHas $x ('^\s+' + $rxT1Stale)) -and (_PbHas $x 'AS COMMITTED on refs/remotes/origin/main'))
    $x = _PbRun 'full' ([DateTime]::UtcNow)
    _C 'CLEAN TWIN  -Full over that same working tree reads the refreshed mirror and passes, so the red above is the committed read' `
      (($x.Code -eq 0) -and (_PbHas $x '^\s*ok - ') -and ($x.Summary -match 'mode=full scanned=2 findings=0'))
    # a push that edits a mirror away from its live copy
    _PbReset; _PbW $eLive 'skill v2'; _PbW $eMir 'skill v3'; _PbCommit 'mirror edit' @('ops')
    $x = _PbRun 'push' ([DateTime]::UtcNow)
    _C 'MUST FIRE  a push that edits a mirror so it no longer matches its live copy fails' (($x.Code -eq 2) -and (_PbHas $x ('^\s+' + $rxT1Stale)))
    _PbReset; _PbW $eLive 'skill v2'; _PbW $eMir 'skill v2'; _PbCommit 'mirror refresh' @('ops')
    $x = _PbRun 'push' ([DateTime]::UtcNow)
    _C 'CLEAN TWIN  a push whose changed mirror matches its live copy passes' `
      (($x.Code -eq 0) -and (_PbHas $x '^\s*ok - ') -and ($x.Summary -match 'mode=push scanned=2 findings=0 failed=0 review=0 changed=1'))
    # the refusals a push that changes a prompt or its mirror always had
    _PbReset; _PbW (Join-Path $er '.claude\agents\a.md') 'agent v2 - edited, mirror forgotten'; _PbCommit 'prompt edit' @('.claude')
    $x = _PbRun 'push' ([DateTime]::UtcNow)
    _C 'MUST FIRE  a push that edits a project prompt without refreshing its mirror still fails' (($x.Code -eq 2) -and (_PbHas $x '^\s+STALE BACKUP  agents\\a\.md'))
    _PbReset; & git -C $er rm -q -- ops/prompt-backup/scheduled-tasks/t1/SKILL.md; & git -C $er commit -q -m 'mirror deleted'
    $x = _PbRun 'push' ([DateTime]::UtcNow)
    _C 'MUST FIRE  a push that deletes a mirror owns the NO BACKUP it leaves' (($x.Code -eq 2) -and (_PbHas $x '^\s+NO BACKUP  scheduled-tasks\\t1\\SKILL\.md'))
    _PbReset; _PbW $eLive 'skill v2 - a live edit in another session'
    _PbW (Join-Path $er 'ops\audit-prompt-backup.ps1') '# a stand-in for this audit, changed by the push'; _PbCommit 'audit edit' @('ops')
    $x = _PbRun 'push' ([DateTime]::UtcNow)
    _C 'MUST FIRE  a push that changes this audit is judged on every finding, the drift it did not cause included' `
      (($x.Code -eq 2) -and (_PbHas $x ('^\s+' + $rxT1Stale)) -and (_PbHas $x 'so EVERY finding is judged'))
    # A COMMITTED SIDE IS AGED BY WHEN IT LANDED, not by when this run copied it, and not by origin/main's TIP either:
    # git archive stamps every entry with the tip's commit time, and on a busy main the tip is minutes old, so a
    # mirror left at that stamp would never read a day old. So the mirror lands three days ago and an unrelated
    # commit lands on top of it now, and the case is judged at the real clock.
    _PbReset; _PbW $eMir 'skill v5 - committed three days ago'; & git -C $er add -A -- ops
    $env:GIT_COMMITTER_DATE = ('@' + [DateTimeOffset]::UtcNow.AddDays(-3).ToUnixTimeSeconds() + ' +0000')
    try { & git -C $er commit -q -m 'old mirror' } finally { Remove-Item -LiteralPath Env:\GIT_COMMITTER_DATE -ErrorAction SilentlyContinue }
    _PbW (Join-Path $er 'README.md') 'readme v4 - the tip, landed now'; _PbCommit 'new tip' @('README.md')
    & git -C $er update-ref refs/remotes/origin/main ([string](& git -C $er rev-parse HEAD)).Trim()
    [IO.File]::SetLastWriteTimeUtc($eLive, [DateTime]::UtcNow.AddDays(-3))
    $x = _PbRun 'daily' ([DateTime]::UtcNow)
    _C 'MUST FIRE  a live copy and a committed mirror both three days old page NOW, at the real clock' (($x.Code -eq 2) -and (_PbHas $x ('^\s+' + $rxT1Stale)))
    & git -C $er update-ref refs/remotes/origin/main $eBase
    # in the main checkout -Daily still judges SCOPE DRIFT, from the files that RUN
    _PbReset; _PbW (Join-Path $eU 'a.md') 'agent v0 - an older user-scope copy'
    $x = Invoke-PromptAudit -Mode 'daily' -RepoRoot $er -Proj (Join-Path $er '.claude\agents') -UserDir $eU -Tasks $eT -Backup (Join-Path $er 'ops\prompt-backup') -Skills (Join-Path $er '.claude\skills') -Exempt @{} -IsMain $true -MainRoot $er -NowUtc ([DateTime]::UtcNow.AddDays(2))
    _C 'MUST FIRE  in the main checkout -Daily still judges SCOPE DRIFT, read from the working tree that runs' (($x.Code -eq 2) -and (_PbHas $x '^\s+SCOPE DRIFT  a\.md'))
    Remove-Item -LiteralPath (Join-Path $eU 'a.md') -Force
    # a push whose range cannot be read is judged as the day before, never passed
    _PbReset; _PbW $eLive 'skill v2 - a live edit in another session'
    _PbW (Join-Path $er 'README.md') 'readme v3'; _PbCommit 'unrelated' @('README.md')
    & git -C $er update-ref -d refs/remotes/origin/main
    $x = _PbRun 'push' ([DateTime]::UtcNow)
    _C 'MUST FIRE  when the push range cannot be read it judges every finding, as the day before, never passing what it could not scope' `
      (($x.Code -eq 2) -and (_PbHas $x 'could not read what this push changed') -and ($x.Summary -match 'scope=unread'))
    $x = _PbRun 'daily' ([DateTime]::UtcNow.AddDays(2))
    _C 'MUST FIRE  -Daily with no origin/main to read falls back to the working tree, says so, and still fails the old drift' `
      (($x.Code -eq 2) -and (_PbHas $x 'comparing this checkout''s working tree instead'))
    & git -C $er update-ref refs/remotes/origin/main $eBase
    # Five of the six -Daily runs above read origin/main; the sixth had none to read and made no folder.
    $pbMade = @($script:PbTempMade | Where-Object { (Split-Path $_ -Leaf) -like 'tc-pbk-*' })
    _C 'CLEAN TWIN  each of the 5 -Daily runs that read origin/main made its own temp tree, and removed it' `
      (($pbMade.Count -eq 5) -and (@($pbMade | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0))

    # (5) WHICH QUESTION A RUN ANSWERS. The chain's -Daily call is NOT read from here: parsing the chain would pull
    # its whole walk, boards included, into this suite's key (1,738 files, 4 s a push, measured 2026-09-23), so
    # that wiring belongs to the chain's own WIRING cases (design\backlog-inbox\pd-promptbackup-2026-09-23.md).
    _C 'MUST FIRE  a run with no switch answers the PUSH question, which is the run run-gates makes' ((Get-PbJudgeMode -Full $false -Daily $false -Writing $false) -eq 'push')
    _C 'CLEAN TWIN  a write mode''s report is still the whole check, so capture-run''s prompt-sync reads as before' ((Get-PbJudgeMode -Full $false -Daily $false -Writing $true) -eq 'full')
    _C 'CLEAN TWIN  -Daily answers the daily question, with or without a write mode' `
      (((Get-PbJudgeMode -Full $false -Daily $true -Writing $false) -eq 'daily') -and ((Get-PbJudgeMode -Full $false -Daily $true -Writing $true) -eq 'daily'))
    _C 'MUST FIRE  -Full with -Daily is refused rather than one silently winning' ((Get-PbJudgeMode -Full $true -Daily $true -Writing $false) -eq 'refused')

    # BLIND: nothing to check is not a pass
    $empty = Join-Path $tmp 'empty'; New-Item -ItemType Directory -Force $empty | Out-Null
    $r = Compare-Prompts $empty $empty $empty $b $empty
    _C 'blind: zero prompts found is reported as checked=0, not as clean' ($r.checked -eq 0)
    $x = Invoke-PromptAudit -Mode 'push' -RepoRoot $empty -Proj $empty -UserDir $empty -Tasks $empty -Backup $b -Skills $empty -Exempt @{}
    _C 'blind: the push mode over zero prompts exits 3 with the BLIND line, never a pass' (($x.Code -eq 3) -and (_PbHas $x '^PROMPT-BACKUP BLIND'))
  } catch {
    Write-Output ('FAIL  the suite threw after ' + $cases + ' case(s): ' + $_.Exception.Message)
    $fail++
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  Write-Output ''
  if ($cases -ne $expectedCases) { Write-Output ("FAIL  ran $cases case(s) of the $expectedCases this file holds"); $fail++ }
  if ($fail -gt 0) { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
  Write-Output "SELF-TEST PASS ($cases prompt-backup cases)"
  exit 0
}

# LOAD THE EXEMPTIONS BEFORE ANYTHING WRITES. -Sync consults the same map the report does, so the two can
# never disagree about what is exempt. An unreadable or malformed list is BLIND (exit 3), never clean and
# never "nothing exempt": this file is the only thing standing between a personal scheduled task and a
# public repo, and a check that cannot read it has not checked anything.
$script:PromptExempt = @{}
try { $script:PromptExempt = Get-PromptExemptions (Join-Path $root 'prompt-backup-exempt.json') }
catch {
  Write-Output ('PROMPT-BACKUP BLIND: ops\prompt-backup-exempt.json could not be read or parsed (' + $_.Exception.Message + '). Refusing to run: an unreadable exemption list cannot be treated as an empty one, and -Sync would mirror files this list exists to keep out of a public repo.')
  exit 3
}

# WHICH TREE IS LIVE (2026-09-11). Resolved once, before anything reads or writes, and printed below: a
# comparison whose target set depends on where it runs owes the reader what it resolved.
$roots  = Resolve-PromptRoots (Split-Path $root -Parent) $MAIN
$PROJ   = $roots.proj
$SKILLS = $roots.skills

# -Full AND -Daily ASK DIFFERENT QUESTIONS (2026-09-23): this checkout's working tree judged whole, against the
# mirror on origin/main judged by age. Refused before anything writes, rather than one silently winning.
if ((Get-PbJudgeMode -Full ([bool]$Full) -Daily ([bool]$Daily) -Writing $false) -eq 'refused') {
  Write-Output 'PROMPT-BACKUP REFUSED: -Full judges this checkout''s working tree and -Daily judges the mirror as committed on origin/main. Pass one of them.'
  exit 3
}

# -Sync KEEPS ITS OLD MEANING EXACTLY: all three halves, adopt everything. Expanded here rather than left as
# a fourth code path, so there is one implementation of each write and no chance of the compatibility alias
# drifting away from the thing it aliases.
if ($Sync) { $SyncScopes = $true; $SyncMirror = $true; if (-not $Adopt -or -not @($Adopt).Count) { $Adopt = @('*') } }
$adoptList = @($Adopt | Where-Object { $_ })
if ($SyncScopes -or $SyncMirror -or $adoptList.Count) {
  $modes = Get-PromptSyncModes $roots.is_main ([bool]$SyncScopes) ([bool]$SyncMirror) $roots.root $MAIN
  if ($modes.note) { Write-Output ('  ' + $modes.note) }
  $doScopes = [bool]$modes.scopes
  $doMirror = [bool]$modes.mirror
  $sr = Invoke-PromptSync $PROJ $USER $TASKS $backup $SKILLS $script:PromptExempt -DoScopes:$doScopes -DoMirror:$doMirror -AdoptNames $adoptList
  foreach ($l in $sr.log) { Write-Output $l }
  Write-Output ("prompt-backup: " + $sr.scoped + " user-scope copy/copies refreshed from project scope, " + $sr.mirrored + " mirror file(s) refreshed, " + $sr.adopted + " newly adopted into ops\prompt-backup")
  # ops\prompt-backup is a TRACKED path and the daily pipeline stages pipeline-owned data paths only, so a
  # mirror this run rewrote is sitting dirty in the working tree until a human commits it. Say so out loud:
  # a repair lane that leaves its repair uncommitted is the same silence this split was built to end.
  if ($sr.mirrored -or $sr.adopted) { Write-Output '  commit ops\prompt-backup - the mirror changed on disk and nothing else will stage it' }
}

# WHICH QUESTION THIS RUN ANSWERS: Get-PbJudgeMode, above.
$writing = [bool]($SyncScopes -or $SyncMirror -or $adoptList.Count)
$judge = Get-PbJudgeMode -Full ([bool]$Full) -Daily ([bool]$Daily) -Writing $writing
$ar = Invoke-PromptAudit -Mode $judge -RepoRoot $roots.root -Proj $PROJ -UserDir $USER -Tasks $TASKS -Backup $backup -Skills $SKILLS `
  -Exempt $script:PromptExempt -IsMain ([bool]$roots.is_main) -MainRoot $MAIN
foreach ($l in $ar.Lines) { Write-Output $l }
# BLIND leaves with no marker, as it always has: a marker says the work finished, and a BLIND run did no work.
if ($ar.Code -eq 3) { exit 3 }
if ($ar.Code -eq 0) { Write-GuardComplete -Name 'prompt-backup' -Summary $ar.Summary; exit 0 }
Exit-Guard -Name 'prompt-backup' -Code $ar.Code -Summary $ar.Summary
