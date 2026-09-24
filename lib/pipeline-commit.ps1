<#
  pipeline-commit.ps1 - a scheduled lane commits the paths it OWNS, and cannot commit source.

  WHY THIS EXISTS (2026-09-07). capture-run.ps1 was the only committer in the estate. check-ad-cycles
  does all the pricing work and commits nothing - it is called BY capture-run, which commits
  afterwards - so the commit was bound to the ENTRY POINT rather than to the work. Any other route into
  the same pipeline left its output uncommitted: on 2026-09-06 the work ran four times and the
  committer ran twice, and 153 files sat dirty for twenty hours, including a recost priced off a board
  that had since been corrected.

  WHAT THIS IS NOT, AND MUST NEVER BECOME. It is not a sweeper. ops\audit-git-sweepers.ps1 forbids
  `git add -A` without a `--` pathspec after four incidents of one shape, the most recent on
  2026-09-05: push-data.ps1 put 325 files on main, 192 of them .ps1 MID-EDIT, 27 of which threw at
  startup, and left them there for 59 minutes. A sweeper running at 21:30 on 2026-09-06 would have
  committed one session's half-finished agent prompts and another's in-progress gates. "Never
  uncommitted again" implemented that way is worse than the problem it solves.

  THE LOAD-BEARING PART IS Assert-NoSourcePaths. A data committer running unattended, in a tree that
  humans and agents are editing at the same time, must be structurally incapable of staging source. Not
  "careful not to" - incapable. That is what makes this safe where a sweeper is not, and it is the
  direct answer to 2026-09-05.

  IT REUSES capture-run's PRIVATE-INDEX PATTERN AND DOES NOT REFACTOR IT. `git commit` with no pathspec
  commits the whole INDEX, so a bot that adds exactly its own paths still ships whatever a session left
  staged in the same shared tree - that is 2026-08-25 (0c47012c), where an unrelated unit rode out under
  the pipeline's name. Seeding a temp index from HEAD makes the commit exactly its own add set and
  leaves the session's index untouched. capture-run's own stage is deliberately untouched: it works, and
  it carries the scar tissue of four incidents.

  WHAT ELSE IT HOLDS, shared with capture-run's own commit stage, which calls these functions. The FOREIGN-HELD
  snapshot: an owned file a session left dirty before a run started, MODIFIED or (since 2026-09-23, W0.2 of
  design/PLAN-bot-checkout-self-heal-2026-09-23.md) DELETED, and not rewritten by the run, stays out of the commit and
  is named. The PIPELINE WRITE JOURNAL: what a lane wrote, so the next committer can tell the pipeline's own bytes from
  a session's edit. Since W3.2 of the same plan, a -Built entry (a guards-blocked day's served outputs) vouches for its
  bytes without ever being committed, and Get-PipelineOwnBlobs hands the checkout sync every vouched blob. Since
  2026-09-24 a commit that lands resyncs the checkout's REAL index for exactly the paths it carried, deletions included
  (Sync-PipelineSharedIndex), so the private-index commit no longer reads back as a staged revert of itself.

  PUSH POLICY: TRY ONCE, NEVER BLOCK. Four schedulers can race. Each caller attempts a single push and,
  on failure, leaves the commit local and says so - the next capture-run pushes it. A commit that exists
  locally is already the whole of what "not uncommitted" means, and a retry loop between four
  schedulers is a worse failure than a late push.

  Dot-source:  . (Join-Path $repoRoot 'lib\pipeline-commit.ps1')
  Self-test:   powershell -File lib\pipeline-commit.ps1 -SelfTest

  THIS FILE DECLARES NO param() BLOCK, DELIBERATELY - the trap guard-contract.ps1 documents. In PS 5.1
  dot-sourcing runs a param() block in the CALLER's scope, so a param([switch]$SelfTest) here would
  reset every caller's own -SelfTest to $false on the line after it bound.
#>
# Its declared inputs (2026-09-23, lib\gate-input-key.ps1 rule 2): every Join-Path $Repo is a path its CALLER passes; its own loads are $PSScriptRoot libraries the walk follows.
# gate-inputs: lib\pipeline-commit.ps1
$__pcSelfTest = ($MyInvocation.InvocationName -ne '.') -and ($args -contains '-SelfTest')

# Invoke-GitCaptured / Format-GitRefusal (2026-09-09, queue 2026-09-09-a95022). The commit below piped
# STDOUT ONLY, and the pre-commit hook writes its entire diagnosis to STDERR, so a refusal here reported
# an exit code and nothing else - the identical blind spot capture-run.ps1:857 had, found the day both
# scheduled runs were refused over one file nobody could name. Sourced from THIS file's own directory so
# it resolves wherever the repo is checked out, worktree included.
. (Join-Path $PSScriptRoot 'git-blob-lib.ps1')
# The pipeline write journal below takes the ledger lock and replaces its file atomically (2026-09-23).
. (Join-Path $PSScriptRoot 'ledger-lock.ps1')
. (Join-Path $PSScriptRoot 'atomic-write.ps1')

# Anything that is CODE or CONFIG, in the broadest reading. Deliberately over-inclusive: the cost of a
# false refusal is that a human commits a data file by hand, and the cost of a false accept is
# 2026-09-05. Those are not remotely the same price.
$script:PC_SOURCE_RX = '(?i)(\.ps1|\.py|\.psm1|\.psd1|\.sh|\.yml|\.yaml|\.md|\.js|\.ts|\.html|\.css)$|^\.claude/|^ops/|^lib/|^\.github/|^docs/|^design/'

function Get-PipelinePaths {
  <# The paths each scheduled lane OWNS. One list per owner, and no path appears under two owners -
     two committers racing for the same file is a merge conflict on a schedule. #>
  param([Parameter(Mandatory=$true)][ValidateSet('pricing', 'graph', 'harvest')][string]$Kind)
  switch ($Kind) {
    'pricing' {
      return @(
        'grocery/out',
        'grocery/product-urls.json',
        'grocery/notify-known-ids.json',
        'grocery/sale-fallback-ownership.json',
        'meal-prep/db/costed.json',
        'meal-prep/db/costed.stamp.json',
        'meal-prep/db/recipes',
        'meal-prep/recipes-db.json',
        'meal-prep/ingredient-map.json',
        'meal-prep/free-rotation.json',
        'meal-prep/pipeline/v2-perserving.json',
        'meal-prep/pipeline/v2-perserving.prev.json'
        # public/** and site/tools/*.html are DELIBERATELY ABSENT. Committing public/board.json IS
        # the feed deploy - it is what readers get - and a scheduled data committer has no business
        # deploying. capture-run still ships those under its own publish decision, which is where a
        # ship belongs. The .html files would be refused by the source assertion anyway.
      )
    }
    'graph' {
      return @(
        'graph/identity',
        'graph/learning',
        'graph/provenance',
        'graph/state',
        'grocery/out/semantic-findings.json',
        'grocery/out/logs/graph-nightly-status.json'
      )
    }
    'harvest' {
      return @(
        'meal-prep/db/candidate-pool.json',
        'meal-prep/db/harvest-state.json',
        'meal-prep/db/source-domains.json',
        'meal-prep/db/considered-dishes.json'
      )
    }
  }
}

function Assert-NoSourcePaths {
  <# THE SAFETY INVARIANT. Returns the offending paths; empty means the list is data-only.

     A caller MUST refuse to commit when this returns anything. It is checked against the declared
     PATH LIST rather than against what git happened to stage, because the list is the thing a human
     reviews and the thing that can be tested without a repo. #>
  param([string[]]$Paths)
  $bad = @()
  foreach ($p in @($Paths)) {
    # Strip the literal './' PREFIX, repeatedly. Never TrimStart('./'): that takes a CHARACTER SET and
    # dropped every leading '.' and '/', so '.claude/settings.json' became 'claude/settings.json' and the
    # ^\.claude/ and ^\.github/ branches below could never match (backlog I205, 2026-09-19).
    $n = ([string]$p).Replace('\', '/')
    while ($n.StartsWith('./', [StringComparison]::Ordinal)) { $n = $n.Substring(2) }
    if ($n -match $script:PC_SOURCE_RX) { $bad += $p }
  }
  return $bad
}

# ---- FOREIGN-HELD FILES: a session's dirty file is not the run's to commit (2026-09-10, queue 2026-09-10-3a9de4) ----
# THE CLASS. Both committers stage their owned paths WHOLE - grocery/out is 1,342 tracked files and a run writes
# a few hundred of them - so any session's uncommitted edit under an owned path rode into the bot commit, and the
# pre-commit hook, judging the STAGED set, refused the ENTIRE commit. On 2026-09-09 one BOM-stripped
# json-readers-baseline.json refused both scheduled commits and the edge served a stale feed all day. a95022
# made the refusal NAME the file; it did not stop the refusal.
# THE RULE. Snapshot the owned files that are already dirty when the run STARTS; at commit time, a snapshot file
# whose LastWriteTime is still before the run started was not rewritten by the run, so it is unstaged and named.
# Everything the run wrote is committed, and the hook stays fail-closed over what remains staged.
# WHAT IT CANNOT DO, stated so nobody reads it as more: an edit a session makes DURING the run to a file the run
# never writes has an mtime after the start and cannot be attributed, so it is still staged. A snapshot that
# cannot be taken holds NOTHING back and says so - it never silently stages less.
# A DELETION PRESENT AT START IS HELD TOO (2026-09-23, design/PLAN-bot-checkout-self-heal-2026-09-23.md W0.2). Until
# then the snapshot kept only a worktree 'M', on the reading that a deletion was not a file the run could have been
# handed. It is: on 2026-09-23 graph/provenance/2026-09-22.jsonl was deleted from the main checkout before a forced
# run, nothing held the deletion back, and cec9779a3 carried it to origin/main as a rename into a quarantine directory.
# So a worktree 'D' of a path HEAD tracks is snapshotted as kind 'deleted', and at commit time it is held while the
# path is STILL absent: the unstage restores HEAD's entry in the private index, so the deletion is not committed. A
# path that exists again at commit time was rewritten by the run and is the run's own. WHAT WAS THE KNOWN RESIDUAL: a
# tracked file the pipeline itself deletes during a run whose commit is then refused is ' D' at the next start, and was
# held on every run after until a person acted (the lane's review proved it with browser-capture-due-2026-09-21.flag,
# ' D' in the main checkout from the refused 09-22 and 09-23 days). Since then a run RECORDS its own deletions in the
# write journal as tombstones (Get-PipelineRunDeletions, Register-PipelineWrites -Deleted), and the next run commits a
# held deletion a tombstone vouches for. A deletion nobody recorded is still held, exactly as W0.2 says.
function Get-DirtyEntryKind {
  <# PURE. A snapshot entry's kind: 'modified' or 'deleted' as Get-DirtyOwnedSnapshot writes it, and 'modified' for an
     entry with no kind, which is how every snapshot built before 2026-09-23 spelled one. A pscustomobject or a
     dictionary entry. Any other value is returned as it is, for the caller's refusing default to name. #>
  param($Entry)
  if ($null -eq $Entry) { return 'modified' }
  if ($Entry -is [System.Collections.IDictionary]) {
    if ($Entry.Contains('kind') -and $null -ne $Entry['kind']) { return [string]$Entry['kind'] }
    return 'modified'
  }
  if ($Entry.PSObject.Properties['kind'] -and $null -ne $Entry.kind) { return [string]$Entry.kind }
  return 'modified'
}

function Get-DirtyOwnedSnapshot {
  <# The tracked files under $Paths that are MODIFIED or DELETED in the working tree now.
     Returns [pscustomobject]@{ ok; files = [pscustomobject]@{ path; mtime; kind }[]; why }, where
       kind 'modified': the worktree column is M (' M', 'MM'), and mtime is the file's LastWriteTime;
       kind 'deleted' : the worktree column is D, HEAD tracks the path, and it is absent on disk; mtime is $null.
     HEAD TRACKS IT is git's own index column: with the worktree column D the index holds the path, so an index
     column of ' ', 'M' or 'T' means HEAD holds it too, and 'A' means only the index does (an add that was then
     deleted from disk, or an index a private-index commit left behind). Unmerged codes never reach either kind.
     EVERY GIVEN PATH GOES TO GIT, on disk or not, so a deleted single-file owned path, or an owned directory a
     session removed whole, is seen: git status answers rc 0 and nothing for a path it does not know (measured
     2026-09-23 on git 2.54.0.windows.1). The listing is -z with core.quotePath=false and --no-renames, split on
     NUL, so a path with a space or a non-ASCII letter arrives exactly as git names it, and a rename arrives as a
     deletion and an add. #>
  param([Parameter(Mandatory = $true)][string]$Repo, [Parameter(Mandatory = $true)][string[]]$Paths)
  $spec = @($Paths | Where-Object { $_ })
  if (-not $spec.Count) { return [pscustomobject]@{ ok = $true; files = @(); why = 'no owned path given' } }
  $g = Invoke-GitCaptured -Repo $Repo -GitArgs (@('-c', 'core.quotePath=false', 'status', '--porcelain', '-z', '--untracked-files=no', '--no-renames', '--') + $spec)
  if ($g.rc -ne 0) { return [pscustomobject]@{ ok = $false; files = @(); why = ('git status exited ' + $g.rc + ': ' + ([string]$g.stderr).Trim()) } }
  $files = New-Object System.Collections.Generic.List[object]
  $rows = ([string]$g.stdout).Split([char]0)
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $row = $rows[$i]
    if ($row.Length -lt 4) { continue }
    $x = [string]$row[0]; $y = [string]$row[1]; $rel = $row.Substring(3)
    # porcelain -z writes a rename's or copy's SOURCE as the next field. --no-renames means none should arrive;
    # stepping over one keeps every later row aligned if one ever does.
    if ($x -ceq 'R' -or $x -ceq 'C') { $i++ }
    $full = Join-Path $Repo $rel
    if ($y -ceq 'M') {
      if (-not (Test-Path -LiteralPath $full)) { continue }
      $files.Add([pscustomobject]@{ path = $rel; mtime = (Get-Item -LiteralPath $full).LastWriteTime; kind = 'modified' })
    } elseif ($y -ceq 'D') {
      if (@(' ', 'M', 'T') -cnotcontains $x) { continue }
      if (Test-Path -LiteralPath $full) { continue }
      $files.Add([pscustomobject]@{ path = $rel; mtime = $null; kind = 'deleted' })
    }
    # Any other worktree column (' ' for a staged-only change, 'T', an unmerged code) is not a file the run could
    # have been handed dirty and then hold back unchanged, which is the rule of the day before for everything but D.
  }
  return [pscustomobject]@{ ok = $true; files = $files.ToArray(); why = '' }
}

function Get-PathMtimes {
  <# path -> LastWriteTime for each path that still exists. A path missing from the map is not held. #>
  param([Parameter(Mandatory = $true)][string]$Repo, [string[]]$Paths)
  $map = @{}
  foreach ($p in @($Paths)) {
    if (-not $p) { continue }
    $full = Join-Path $Repo $p
    if (Test-Path -LiteralPath $full) { $map[[string]$p] = (Get-Item -LiteralPath $full).LastWriteTime }
  }
  return $map
}

function Get-ForeignHeldPaths {
  <# PURE. From a start-of-run snapshot, the files the run did NOT rewrite, which its commit must not carry:
       a 'modified' entry whose path still exists with an mtime before $RunStart (one at or after the start is the
       run's own write);
       a 'deleted' entry whose path is STILL absent, so the deletion was there before the run and the run did not
       bring the file back (one that exists again was rewritten by the run and is the run's own).
     $CurrentMtimes is Get-PathMtimes' map, which holds only the paths that exist now. An unusable snapshot holds
     nothing back. An entry of any other kind THROWS: it is a defect in whoever built the snapshot, and guessing it
     held or free would hide that. Comma-returned, so a caller assigns it and reads .Count. #>
  param($Snapshot, [datetime]$RunStart, $CurrentMtimes)
  $held = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Snapshot -or -not $Snapshot.ok -or $null -eq $CurrentMtimes) { return ,$held.ToArray() }
  foreach ($f in @($Snapshot.files)) {
    if ($null -eq $f) { continue }
    $p = [string]$f.path
    $kind = Get-DirtyEntryKind -Entry $f
    switch -CaseSensitive ($kind) {
      'modified' { if ($CurrentMtimes.ContainsKey($p) -and ([datetime]$CurrentMtimes[$p] -lt $RunStart)) { $held.Add($p) } }
      'deleted'  { if (-not $CurrentMtimes.ContainsKey($p)) { $held.Add($p) } }
      default    { throw ('Get-ForeignHeldPaths: unknown snapshot kind ''' + $kind + ''' for ' + $p) }
    }
  }
  return ,$held.ToArray()
}

function Format-ForeignHeldDeletionLines {
  <# PURE. For each HELD path the snapshot recorded as a deletion present at start, the line a commit stage prints and
     its status record carries: 'foreign-held: kept a deletion present at start: <path>', in the order $Held names
     them. A held modification gets no line here; the commit stage's own count line names it. Comma-returned. #>
  param($Snapshot, [string[]]$Held)
  $lines = New-Object System.Collections.Generic.List[string]
  if ($null -eq $Snapshot -or -not $Snapshot.ok) { return ,$lines.ToArray() }
  $deleted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($f in @($Snapshot.files)) {
    if ($null -eq $f) { continue }
    if ([string]::Equals((Get-DirtyEntryKind -Entry $f), 'deleted', [StringComparison]::Ordinal)) { [void]$deleted.Add([string]$f.path) }
  }
  foreach ($p in @($Held)) {
    if ($p -and $deleted.Contains([string]$p)) { $lines.Add('foreign-held: kept a deletion present at start: ' + $p) }
  }
  return ,$lines.ToArray()
}

function Get-PipelineRunDeletions {
  <# The tracked files under $Paths that THIS run deleted: HEAD holds them, the working tree does not, and the start
     snapshot did not already record them as deleted (those were handed to the run, and W0.2 holds them). Returns a
     string[] as git names the paths, comma-returned. With no usable snapshot there is no way to say which deletions are
     the run's, so it returns nothing. HEAD against the WORKING TREE, --no-renames and -z, so a deletion git would pair
     with an add still arrives as a deletion, and the answer does not depend on which index the caller holds. #>
  param([Parameter(Mandatory = $true)][string]$Repo, [string[]]$Paths, $DirtyAtStart)
  $out = New-Object System.Collections.Generic.List[string]
  $spec = @($Paths | Where-Object { $_ })
  if (-not $spec.Count -or $null -eq $DirtyAtStart -or -not $DirtyAtStart.ok) { return ,$out.ToArray() }
  $g = Invoke-GitCaptured -Repo $Repo -GitArgs (@('-c', 'core.quotePath=false', 'diff', '--no-renames', '--name-only', '-z', '--diff-filter=D', 'HEAD', '--') + $spec)
  if ($g.rc -ne 0) { return ,$out.ToArray() }
  $atStart = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($f in @($DirtyAtStart.files)) {
    if ($null -ne $f -and [string]::Equals((Get-DirtyEntryKind -Entry $f), 'deleted', [StringComparison]::Ordinal)) { [void]$atStart.Add([string]$f.path) }
  }
  foreach ($rel in @(([string]$g.stdout).Split([char]0))) {
    if (-not $rel) { continue }
    if ($atStart.Contains($rel)) { continue }
    if (Test-Path -LiteralPath (Join-Path $Repo $rel)) { continue }
    $out.Add($rel)
  }
  return ,$out.ToArray()
}

# ---- THE PIPELINE WRITE JOURNAL (2026-09-23, queue 2026-09-22-9bc4d2, reopened from 2026-09-10-a86b87) ----
# THE CLASS. The foreign-held rule above can say "dirty before this run started" and nothing about WHO dirtied it. A
# lane that writes owned paths and does not commit them - capture-watchdog's Family Fare shard window after the 08:00
# commit, check-ad-cycles run by hand (its pricing commit does not own graph/identity), any lane whose own commit was
# refused - left files the NEXT committer read as a session's edit and held back. A dated file is never rewritten, so it
# was held on every run after: family-fare-regular-2026-09-13.json was held on 09-14, 09-17 and 09-18. Data the pipeline
# wrote and never committed is data no reader gets (design/RCA-holistic-2026-09-22.md F2).
# THE RULE. The OUTPUTS are declared once already: lib\bot-paths.ps1, and Get-PipelinePaths above for the three lanes.
# What was missing is WHO wrote a file, so a lane now RECORDS what it wrote: every declared file that differs from HEAD
# with an mtime at or after the lane's start, as (checkout, path) -> the git blob id of its bytes, in ONE journal in the
# git common dir (never tracked, shared by every checkout, keyed by checkout so a worktree's run never vouches for the
# main tree's file). At commit time a held candidate whose CURRENT bytes are the bytes a lane recorded is the
# pipeline's own and is committed; a file a session edited after the lane wrote it has other bytes and stays held.
# WHAT IT CANNOT DO, stated so nobody reads it as more: a pipeline script run by hand OUTSIDE any lane (compare-deals on
# its own) records nothing, so its outputs are held exactly as before. A session edit made DURING a lane to a declared
# file is recorded as the lane's; that is the same file the foreign-held rule already stages today (its mtime is after
# the start), so nothing that was held before is newly committed by it. A journal that cannot be read or written
# degrades to the rule of the day before: every candidate stays held.
# BUILT ENTRIES VOUCH WITHOUT COMMITTING (2026-09-23, design/PLAN-bot-checkout-self-heal-2026-09-23.md W3.2). A day whose
# guards held the board still WROTE its served outputs, and the checkout sync that plan adds must be able to tell those
# pipeline bytes from a session's edit before it merges or sets one aside. `Register-PipelineWrites -Built` records them
# with commit = $false: Get-PipelineOwnHeld never commits such an entry (a blocked day's board is never shipped by the
# next run's foreign-held rule), and Get-PipelineOwnBlobs hands the entries of BOTH kinds to the mover. An entry with no
# commit field, which is every entry written before this, is committable, exactly as it was. A commit field that is not
# the JSON boolean true is NOT committable, so a damaged or hand-typed value fails closed. The newest registration of a
# (checkout, path) pair replaces the older one, whichever kind either is: capture-run registers a guards-blocked day's
# served paths -Built and keeps them out of its committable set, so the two never name one path in one run.
# One journal is shared by every checkout on the box, and a copy of this file older than W3.2 reads a built entry as
# committable. Each checkout reads only its own entries, and the bot lanes all run in the main checkout at one version.
$script:PC_JOURNAL_NAME = 'tc-pipeline-writes.json'
# 30 days, the first plausible number and not a sweep: a dated output held longer than that has a bigger problem than
# this journal, and the prune only bounds the file. What it does when a lane STOPS recording: entries age out and the
# held files go back to being held, which is the day-before behaviour.
$script:PC_JOURNAL_KEEP_DAYS = 30

function Get-PipelineWriteJournalPath {
  <# The journal's full path: <git common dir>\tc-pipeline-writes.json. $null when git cannot name the common dir. #>
  param([Parameter(Mandatory = $true)][string]$Repo)
  $g = Invoke-GitCaptured -Repo $Repo -GitArgs @('rev-parse', '--git-common-dir')
  if ($g.rc -ne 0) { return $null }
  $d = ([string]$g.stdout).Trim()
  if (-not $d) { return $null }
  if (-not [IO.Path]::IsPathRooted($d)) { $d = Join-Path $Repo $d }
  return (Join-Path ([IO.Path]::GetFullPath($d)) $script:PC_JOURNAL_NAME)
}

function Get-PipelineCheckoutKey {
  <# The checkout a journal entry belongs to: its toplevel, full, lower-cased, backslashed. #>
  param([Parameter(Mandatory = $true)][string]$Repo)
  $g = Invoke-GitCaptured -Repo $Repo -GitArgs @('rev-parse', '--show-toplevel')
  $t = if ($g.rc -eq 0) { ([string]$g.stdout).Trim() } else { $Repo }
  return ([IO.Path]::GetFullPath($t.Replace('/', '\'))).TrimEnd('\').ToLowerInvariant()
}

function Get-PipelineBlobIds {
  <# path -> the git blob id its CURRENT bytes would get (git hash-object, filters applied), in chunks of 50 so a long
     list never meets the command-line limit. A path git could not hash is absent from the map, never guessed.
     ONLY A FILE ON DISK IS HASHED (2026-09-23, W0.2). A held deletion now reaches this list, and git hash-object
     refuses a whole call over one missing path: `hash-object -- present missing` printed the first id and exited 128
     (measured in a temp repo that day), so the chunk was dropped and every file in it lost its journal vouch. #>
  param([Parameter(Mandatory = $true)][string]$Repo, [string[]]$Paths)
  $map = @{}
  $list = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $Repo $_) -PathType Leaf) })
  for ($i = 0; $i -lt $list.Count; $i += 50) {
    $chunk = @($list[$i..([Math]::Min($i + 49, $list.Count - 1))])
    $g = Invoke-GitCaptured -Repo $Repo -GitArgs (@('hash-object', '--') + $chunk)
    if ($g.rc -ne 0) { continue }
    $ids = @(([string]$g.stdout) -split "`r?`n" | Where-Object { $_.Trim() })
    if ($ids.Count -ne $chunk.Count) { continue }
    for ($k = 0; $k -lt $chunk.Count; $k++) { $map[[string]$chunk[$k]] = $ids[$k].Trim() }
  }
  return $map
}

function Read-PipelineWriteJournal {
  <# The journal as an ordinal hashtable key -> @{ blob; lane; ts; commit }. Empty when absent; THROWS when present and
     unreadable, so a caller degrades on purpose rather than reading a damaged journal as an empty one.
     commit (W3.2): $true when the field is absent (every entry written before -Built existed) or is the JSON boolean
     true; $false for anything else, so a -Built entry and a damaged value both read as not committable. #>
  param([Parameter(Mandatory = $true)][string]$JournalPath)
  $h = New-Object 'System.Collections.Hashtable' ([StringComparer]::Ordinal)
  if (-not (Test-Path -LiteralPath $JournalPath)) { return $h }
  $doc = [IO.File]::ReadAllText($JournalPath, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json
  if ($null -ne $doc -and $doc.PSObject.Properties['writes']) {
    foreach ($p in $doc.writes.PSObject.Properties) {
      $v = $p.Value
      $c = $true
      if ($null -ne $v -and $v.PSObject.Properties['commit']) { $c = (($v.commit -is [bool]) -and $v.commit) }
      # deleted (2026-09-23): a TOMBSTONE, a tracked file the lane deleted; only the JSON boolean true reads as one.
      $d = ($null -ne $v -and $v.PSObject.Properties['deleted'] -and ($v.deleted -is [bool]) -and $v.deleted)
      $h[$p.Name] = [pscustomobject]@{ blob = [string]$v.blob; lane = [string]$v.lane; ts = [string]$v.ts; commit = [bool]$c; deleted = [bool]$d }
    }
  }
  return $h
}

function Register-PipelineWrites {
  <# A LANE RECORDS WHAT IT WROTE. Every file under $Paths that differs from HEAD and was written at or after $Since is
     recorded as this checkout's (path -> blob id, lane, time, commit). Returns how many were recorded. Throws on a
     journal it cannot write; every caller swallows that, because a lane must never die of its bookkeeping, and an
     unrecorded write is simply held as before.
     -Built (W3.2) records the entries with commit = $false: pipeline bytes the mover may vouch for and no committer
     may commit, which is a guards-blocked day's served outputs. Without it every entry is committable, as before.
     -Deleted (2026-09-23) records TOMBSTONES: repo paths this lane deleted (Get-PipelineRunDeletions), each still
     absent on disk, as { blob = ''; deleted = $true }. The next run commits a held deletion a tombstone vouches for,
     so a refused day's deletions land with its other files. An empty blob means the mover never vouches bytes for one. #>
  param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$Lane,
    [Parameter(Mandatory = $true)][datetime]$Since,
    [string[]]$Paths,
    [switch]$Built,
    [string[]]$Deleted = @()
  )
  $present = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $Repo $_)) })
  $gone = @($Deleted | Where-Object { $_ -and -not (Test-Path -LiteralPath (Join-Path $Repo $_)) } | Sort-Object -Unique)
  $mine = New-Object System.Collections.Generic.List[string]
  if ($present.Count) {
    # AGAINST HEAD, NOT THE INDEX: capture-run calls this under its private index, where a staged file reads clean in the
    # worktree column, and after a private-index commit the session's index is stale. HEAD-to-worktree is the question.
    $g = Invoke-GitCaptured -Repo $Repo -GitArgs (@('-c', 'core.quotePath=false', 'diff', '--name-only', 'HEAD', '--') + $present)
    if ($g.rc -ne 0) { throw ('git diff exited ' + $g.rc + ': ' + ([string]$g.stderr).Trim()) }
    foreach ($rel in @(([string]$g.stdout) -split "`r?`n")) {
      $rel = $rel.Trim()
      if (-not $rel) { continue }
      $full = Join-Path $Repo $rel
      if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
      if ((Get-Item -LiteralPath $full).LastWriteTime -ge $Since) { $mine.Add($rel) }
    }
  }
  if (-not $mine.Count -and -not $gone.Count) { return 0 }
  $ids = if ($mine.Count) { Get-PipelineBlobIds -Repo $Repo -Paths $mine.ToArray() } else { @{} }
  $jp = Get-PipelineWriteJournalPath -Repo $Repo
  if (-not $jp) { throw 'git could not name the common dir, so there is nowhere to record' }
  $ck = Get-PipelineCheckoutKey -Repo $Repo
  $now = Get-Date
  $lock = Enter-TcLedgerLock -Path $jp
  try {
    $j = Read-PipelineWriteJournal -JournalPath $jp
    $keep = [ordered]@{}
    foreach ($k in @($j.Keys | Sort-Object)) {
      $e = $j[$k]; $t = [datetime]::MinValue
      if ([datetime]::TryParse([string]$e.ts, [ref]$t) -and ($now - $t).TotalDays -le $script:PC_JOURNAL_KEEP_DAYS) { $keep[$k] = $e }
    }
    $n = 0
    foreach ($rel in $mine) {
      if (-not $ids.ContainsKey($rel)) { continue }
      $keep[($ck + '|' + $rel)] = [pscustomobject]@{ blob = $ids[$rel]; lane = $Lane; ts = $now.ToString('s'); commit = (-not $Built.IsPresent) }
      $n++
    }
    foreach ($rel in $gone) {
      $keep[($ck + '|' + [string]$rel)] = [pscustomobject]@{ blob = ''; lane = $Lane; ts = $now.ToString('s'); commit = (-not $Built.IsPresent); deleted = $true }
      $n++
    }
    [void](Write-TcAtomicFile -Path $jp -Text ([pscustomobject]@{ writes = [pscustomobject]$keep } | ConvertTo-Json -Depth 4) -NoBom)
  } finally { Exit-TcLedgerLock -Lock $lock }
  return $n
}

function Get-PipelineOwnHeld {
  <# Of $Paths (the foreign-held candidates), the ones whose CURRENT bytes are exactly what a pipeline lane recorded
     for THIS checkout in a COMMITTABLE entry. A -Built entry (commit = $false, W3.2) is skipped, so its file stays
     held. Returns [pscustomobject]@{ path; lane }[], comma-returned. Throws when the journal is present and
     unreadable; the caller keeps every candidate held. #>
  param([Parameter(Mandatory = $true)][string]$Repo, [string[]]$Paths)
  $own = New-Object System.Collections.Generic.List[object]
  $cand = @($Paths | Where-Object { $_ })
  if (-not $cand.Count) { return ,$own.ToArray() }
  $jp = Get-PipelineWriteJournalPath -Repo $Repo
  if (-not $jp) { return ,$own.ToArray() }
  $j = Read-PipelineWriteJournal -JournalPath $jp
  if (-not $j.Count) { return ,$own.ToArray() }
  $ck = Get-PipelineCheckoutKey -Repo $Repo
  $ids = Get-PipelineBlobIds -Repo $Repo -Paths $cand
  foreach ($p in $cand) {
    $e = $j[($ck + '|' + [string]$p)]
    if ($null -eq $e -or -not $e.commit) { continue }
    # A TOMBSTONE vouches for a held DELETION: the lane recorded deleting this path, and it is still absent on disk.
    if ($e.deleted) {
      if (-not (Test-Path -LiteralPath (Join-Path $Repo ([string]$p)))) { $own.Add([pscustomobject]@{ path = [string]$p; lane = [string]$e.lane }) }
      continue
    }
    if (-not $ids.ContainsKey([string]$p)) { continue }
    if ([string]::Equals([string]$e.blob, [string]$ids[[string]$p], [StringComparison]::Ordinal)) {
      $own.Add([pscustomobject]@{ path = [string]$p; lane = [string]$e.lane })
    }
  }
  return ,$own.ToArray()
}

function Get-PipelineOwnBlobs {
  <# THE MOVER'S VOUCH (2026-09-23, design/PLAN-bot-checkout-self-heal-2026-09-23.md W3.2). Repo path (as git names it)
     -> the blob id a pipeline lane recorded for THIS checkout, from entries of EITHER kind, committable or -Built. The
     checkout sync merges into or sets aside an owned dirty file only when its current bytes are this blob; anything
     else is FOREIGN and never written.
     Returns an ORDINAL hashtable carrying a .note NoteProperty: '' when the journal was read or is absent. A journal
     git cannot place, or one that cannot be read, gives an EMPTY table and says why in .note, so the mover vouches for
     nothing and every owned edit is FOREIGN: the day before. Never throws. Entries are not aged here: a blob that
     still equals the file's bytes is still the pipeline's, however old its row, and Register-PipelineWrites prunes. #>
  param([Parameter(Mandatory = $true)][string]$Repo)
  $t = New-Object 'System.Collections.Hashtable' ([StringComparer]::Ordinal)
  $note = ''
  try {
    $jp = Get-PipelineWriteJournalPath -Repo $Repo
    if (-not $jp) {
      $note = 'pipeline-own-blobs: git could not name the common dir, so nothing is vouched and every owned edit is FOREIGN'
    } else {
      $j = Read-PipelineWriteJournal -JournalPath $jp
      $pre = (Get-PipelineCheckoutKey -Repo $Repo) + '|'
      foreach ($k in @($j.Keys)) {
        if (-not $k.StartsWith($pre, [StringComparison]::Ordinal)) { continue }
        $b = [string]$j[$k].blob
        if ($b) { $t[$k.Substring($pre.Length)] = $b }
      }
    }
  } catch {
    $t.Clear()
    $note = ('pipeline-own-blobs: the write journal could not be read (' + $_.Exception.Message + '), so nothing is vouched and every owned edit is FOREIGN')
  }
  Add-Member -InputObject $t -NotePropertyName note -NotePropertyValue $note
  return $t
}

function Split-PipelineOwnHeld {
  <# The one place a committer splits its foreign-held candidates: @{ foreign = string[]; own = @{path;lane}[]; note }.
     A journal that cannot be read keeps every candidate held and says so in .note. #>
  param([Parameter(Mandatory = $true)][string]$Repo, [string[]]$Held)
  $h = @($Held | Where-Object { $_ })
  $own = @(); $note = ''
  if ($h.Count) {
    try { $ownRaw = Get-PipelineOwnHeld -Repo $Repo -Paths $h; $own = @($ownRaw) }
    catch { $own = @(); $note = ('pipeline-own: the write journal could not be read (' + $_.Exception.Message + '), so every held file stays held') }
  }
  $ownPaths = @($own | ForEach-Object { [string]$_.path })
  $foreign = @($h | Where-Object { $ownPaths -notcontains $_ })
  if ($own.Count) {
    $lanes = @($own | ForEach-Object { [string]$_.lane } | Sort-Object -Unique)
    $note = ('pipeline-own: ' + $own.Count + ' file(s) dirty before this run were written by a pipeline lane (' + ($lanes -join ', ') + ') and are committed: ' + ($ownPaths -join ', '))
  }
  return [pscustomobject]@{ foreign = $foreign; own = $own; note = $note }
}

function Sync-PipelineSharedIndex {
  <# After a private-index commit LANDED, reset the checkout's real index for exactly the paths that commit carried.
     Returns '' when it did, or a '; index resync ...' note naming why it could not, which the verdict carries.

     WHY (2026-09-24, design/backlog-inbox/sh-pc-2026-09-23.md). The commit moves HEAD while the real index still holds
     the OLD blobs of every path it committed, so `git status` read the commit back as a staged REVERT (`MM` for a
     modification, `AD` for a deletion, `D ` for an addition), one plain `git commit` away from undoing the day's data,
     and a restore from that index brought the commit's deletions back on disk: the resurrection of cec9779a3.
     capture-run's own stage has done this since it began; this is the same rule for the three lanes that commit here.

     WHAT IT TOUCHES, AND ONLY THAT: `git reset -q` of the commit's own paths, read from the commit itself with
     --no-renames (a delete-plus-identical-add is a RENAME to git, which would list only the new name and leave the deleted
     path's stale entry behind), as LITERAL pathspecs from a NUL-separated file, so a path with a glob character matches
     only itself and no command line can overflow. Never the working tree, never a path outside the commit.
     IDEMPOTENT: it sets each entry to HEAD's, so running it twice is running it once.
     IT SKIPS rather than guesses when HEAD is no longer the commit this call made (its parent is not the HEAD the commit
     started from): another committer moved HEAD in between, and resetting that commit's paths is not this lane's call. #>
  param([Parameter(Mandatory=$true)][string]$Repo, [string]$Parent)
  $specFile = $null
  try {
    $h = Invoke-GitCaptured -Repo $Repo -GitArgs @('rev-parse', '--verify', '-q', 'HEAD')
    if ($h.rc -ne 0) { return '; index resync FAILED: HEAD could not be read, so the shared index may still hold a staged revert of this commit' }
    $sha = ([string]$h.stdout).Trim()
    $p = Invoke-GitCaptured -Repo $Repo -GitArgs @('rev-parse', '--verify', '-q', ($sha + '^'))
    $par = $(if ($p.rc -eq 0) { ([string]$p.stdout).Trim() } else { '' })
    if (-not [string]::Equals($par, [string]$Parent, [StringComparison]::Ordinal)) {
      return '; index resync SKIPPED: HEAD is no longer the commit this call made, so no index entry was reset'
    }
    $dtArgs = $(if ($par) { @('diff-tree', '-r', '--no-commit-id', '--name-only', '--no-renames', '-z', $par, $sha) }
                else { @('diff-tree', '-r', '--root', '--no-commit-id', '--name-only', '--no-renames', '-z', $sha) })
    $d = Invoke-GitCaptured -Repo $Repo -GitArgs (@('-c', 'core.quotePath=false') + $dtArgs)
    if ($d.rc -ne 0) { return ('; index resync FAILED: the commit''s paths could not be listed (git exit ' + $d.rc + '), so the shared index may still hold a staged revert of this commit') }
    $cPaths = @(([string]$d.stdout).Split([char]0) | Where-Object { $_ })
    if (-not $cPaths.Count) { return '' }
    $specFile = Join-Path $env:TEMP ('pipe-resync-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($specFile, (($cPaths -join [string][char]0) + [char]0), (New-Object Text.UTF8Encoding($false)))
    $r = Invoke-GitCaptured -Repo $Repo -GitArgs @('--literal-pathspecs', 'reset', '-q', ('--pathspec-from-file=' + $specFile), '--pathspec-file-nul')
    if ($r.rc -ne 0) {
      $why = @(([string]$r.stderr) -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
      return ('; index resync FAILED (git exit ' + $r.rc + '): ' + ($why -join '') + ' - the shared index still holds a staged revert of ' + $cPaths.Count + ' committed path(s); `git reset -q -- <path>` for each clears it')
    }
    return ''
  } catch {
    return ('; index resync FAILED: threw: ' + $_.Exception.Message)
  } finally {
    if ($specFile -and (Test-Path -LiteralPath $specFile)) { Remove-Item -LiteralPath $specFile -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-PipelineCommit {
  <# Commit exactly $Paths under a private index. Returns a verdict string.

     Guarded throughout: a lane that cannot commit is degraded, and a lane KILLED BY its committer has
     lost a night's work - the same rule run-log-lib states for logging. #>
  param(
    [Parameter(Mandatory=$true)][string]$Repo,
    [Parameter(Mandatory=$true)][string[]]$Paths,
    [Parameter(Mandatory=$true)][string]$Message,
    [Parameter(Mandatory=$true)][string]$Name,
    [switch]$Push,
    # THE CALLER'S START-OF-RUN SNAPSHOT (2026-09-10, queue 2026-09-10-3a9de4) - pass both or neither. With them,
    # an owned file that was already dirty when the caller's run started and has not been rewritten since is
    # unstaged and named instead of refusing the whole commit. Without them this behaves exactly as before.
    $DirtyAtStart = $null,
    [datetime]$RunStart = [datetime]::MinValue,
    # WHAT THIS LANE RECORDS AS ITS OWN WRITES (2026-09-23, queue 2026-09-22-9bc4d2). Defaults to $Paths. A lane that
    # writes declared paths it does not commit passes the wider declared set (check-ad-cycles: lib\bot-paths.ps1's
    # inputs, which carry graph/identity), so the committer that owns them takes them instead of holding them.
    [string[]]$JournalPaths = $null
  )
  $bad = Assert-NoSourcePaths $Paths
  if ($bad.Count) {
    return ("REFUSED: {0} would stage source or config, which a scheduled data committer must never do: {1}. This is the 2026-09-05 shape and the refusal is the feature." -f $Name, ($bad -join ', '))
  }

  $present = @($Paths | Where-Object { Test-Path (Join-Path $Repo $_) })
  if (-not $present.Count) { return ("{0}: nothing to commit - none of its owned paths exist" -f $Name) }

  $tmpIndex = $null; $prevIndex = $null; $held = $false
  # What HEAD was before this commit, and whether it landed: Sync-PipelineSharedIndex resyncs the real index only then.
  $landed = $false
  $hbRes = Invoke-GitCaptured -Repo $Repo -GitArgs @('rev-parse', '--verify', '-q', 'HEAD')
  $headBefore = $(if ($hbRes.rc -eq 0) { ([string]$hbRes.stdout).Trim() } else { '' })
  try {
    # A PRIVATE INDEX, for the reason capture-run.ps1 documents: `git commit` with no pathspec commits
    # the whole INDEX, so staging exactly our own paths is not enough while a session shares the tree.
    $tmpIndex = Join-Path $env:TEMP ('pipe-index-' + [guid]::NewGuid().ToString('N'))
    $prevIndex = $env:GIT_INDEX_FILE
    $env:GIT_INDEX_FILE = $tmpIndex
    $held = $true
    & git -C $Repo read-tree HEAD | Out-Null
    & git -C $Repo add -A -- $present | Out-Null
    $staged = @(& git -C $Repo diff --cached --name-only | Where-Object { $_ })
    # FOREIGN-HELD (2026-09-10, queue 2026-09-10-3a9de4): unstage what another session dirtied before this run
    # started and the run did not rewrite. See Get-ForeignHeldPaths above.
    $foreignHeld = @()
    $foreignNote = ''
    if (($null -ne $DirtyAtStart) -and ($RunStart -gt [datetime]::MinValue)) {
      if (-not $DirtyAtStart.ok) {
        $foreignNote = ('; foreign-held: the start-of-run snapshot is unavailable (' + [string]$DirtyAtStart.why + '), so nothing was held back')
      } else {
        $fhNow = Get-PathMtimes -Repo $Repo -Paths @($DirtyAtStart.files | ForEach-Object { [string]$_.path })
        $fhCand = Get-ForeignHeldPaths -Snapshot $DirtyAtStart -RunStart $RunStart -CurrentMtimes $fhNow
        # A candidate a pipeline lane wrote and recorded is the pipeline's own and stays staged (2026-09-23, 9bc4d2).
        $fhSplit = Split-PipelineOwnHeld -Repo $Repo -Held $fhCand
        $foreignHeld = @($fhSplit.foreign)
        foreach ($fh in $foreignHeld) { & git -C $Repo reset -q -- $fh | Out-Null }
        if ($foreignHeld.Count) {
          $foreignNote = ('; foreign-held: ' + $foreignHeld.Count + ' tracked owned file(s) another session dirtied before this run started, left uncommitted: ' + ($foreignHeld -join ', '))
          $staged = @(& git -C $Repo diff --cached --name-only | Where-Object { $_ })
        }
        # A HELD DELETION IS NAMED ON ITS OWN LINE (2026-09-23, W0.2): the reset above restored HEAD's entry, so the
        # commit keeps the file, and the file stays absent on disk for its owner to restore or commit.
        $fhDeleted = Format-ForeignHeldDeletionLines -Snapshot $DirtyAtStart -Held $foreignHeld
        foreach ($fhLine in @($fhDeleted)) { $foreignNote += ('; ' + $fhLine) }
        if ($fhSplit.note) { $foreignNote += ('; ' + $fhSplit.note) }
      }
    }
    if (-not $staged.Count) {
      return ("{0}: nothing changed under its owned paths{1}" -f $Name, $foreignNote)
    }
    # BELT AND BRACES. The list was asserted above; this asserts what git ACTUALLY staged, because a
    # directory path like grocery/out could in principle acquire a script.
    $badStaged = Assert-NoSourcePaths $staged
    if ($badStaged.Count) {
      return ("REFUSED: {0} staged source under a data path and will not commit it: {1}" -f $Name, (($badStaged | Select-Object -First 6) -join ', '))
    }
    # CAPTURE BOTH STREAMS (2026-09-09, queue 2026-09-09-a95022). `| Out-Null` discarded stdout and the
    # hook's stderr never entered this process at all, so this lane's refusal string could only ever say
    # "a hook rejected it" - which is the sentence that cost a full reproduction on 09-09. No `2>&1` and no
    # `2>$null`: under EAP=Stop a native child's redirected stderr becomes a terminating error.
    # WITH A FILE HELD BACK THE COMMIT TAKES THE INDEX, NOT THE PATHSPEC (2026-09-10, queue 2026-09-10-3a9de4):
    # `git commit -- <paths>` commits the WORKING TREE of everything under those paths, which would put the held
    # file straight back into the commit. With nothing held, the call is exactly what it was.
    $commitTail = if ($foreignHeld.Count) { @() } else { @('--') + @($present) }
    $cRes = Invoke-GitCaptured -Repo $Repo -GitArgs (@(
      '-c', 'user.name=smp-pipeline-bot', '-c', 'user.email=actions@users.noreply.github.com',
      'commit', '-m', $Message) + $commitTail)
    $rc = $cRes.rc
    if ($rc -ne 0) {
      $refusal = Format-GitRefusal -Rc $rc -Stderr $cRes.stderr
      return ("{0}: commit refused (git exit {1}) - a hook or git itself rejected it; the tree is untouched{4}. {2}`n{3}" -f `
              $Name, $rc, $refusal.summary, (($refusal.transcript) -join "`n"), $foreignNote)
    }
    $landed = $true
  } catch {
    return ("{0}: committer threw and was swallowed (the lane's work is not lost, only uncommitted): {1}" -f $Name, $_.Exception.Message)
  } finally {
    if ($held) { if ($null -eq $prevIndex) { Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue } else { $env:GIT_INDEX_FILE = $prevIndex } }
    if ($tmpIndex -and (Test-Path $tmpIndex)) { Remove-Item $tmpIndex -Force -ErrorAction SilentlyContinue }
    # RECORD WHAT THIS LANE WROTE AND DID NOT LAND (2026-09-23, 9bc4d2), on every path out: a refused commit, a held
    # file set, or a lane that owns less than it writes. What landed no longer differs from HEAD, so it is not recorded.
    # Only with a run start: without one there is no way to say which writes were this lane's.
    # Its own DELETIONS too (tombstones), which need the start snapshot to tell them from a deletion it was handed.
    if ($RunStart -gt [datetime]::MinValue) {
      try {
        $jpList = $(if ($JournalPaths) { $JournalPaths } else { $Paths })
        $jpDel = Get-PipelineRunDeletions -Repo $Repo -Paths $jpList -DirtyAtStart $DirtyAtStart
        [void](Register-PipelineWrites -Repo $Repo -Lane $Name -Since $RunStart -Paths $jpList -Deleted $jpDel)
      } catch { }
    }
  }

  # RESYNC THE SHARED INDEX FOR WHAT WAS JUST COMMITTED, AND ONLY THAT (2026-09-24). After the finally above, so the
  # reset reaches the real index and never the private one. See Sync-PipelineSharedIndex.
  $resyncNote = ''
  if ($landed) { $resyncNote = Sync-PipelineSharedIndex -Repo $Repo -Parent $headBefore }
  $msg = ("{0}: committed {1} file(s){2}{3}" -f $Name, $staged.Count, $foreignNote, $resyncNote)
  if ($Push) {
    try {
      & git -C $Repo push origin HEAD:main | Out-Null
      if ($LASTEXITCODE -eq 0) { $msg += ' and pushed' }
      else { $msg += ' - push failed, left local for the next capture-run to carry' }
    } catch { $msg += ' - push threw, left local for the next capture-run to carry' }
  }
  return $msg
}

function Get-PipelineCommitOutcome {
  <# PURE. What an Invoke-PipelineCommit verdict SAYS happened: committed, nothing, refused, threw, or unknown.

     WHY A CALLER NEEDS IT (2026-09-11). The verdict is a sentence, and every caller printed it and carried on, so a
     lane whose commit was refused exited exactly as a lane whose commit landed: graph-nightly's transcript of
     2026-09-09 reads "commit refused" and, two lines later, "rc=0". The classifier sits beside the sentences it
     reads, and the self-test drives it over verdicts this file really returns, so rewording one turns that suite
     red instead of turning every refusal into a success. A push that failed after the commit landed is still
     'committed': a local commit is the whole of this file's promise, and the next run carries it.

     ONE IMPLEMENTATION, AND WHERE THE OTHER COPY IS. This function is taken verbatim from a commit that was still
     unlanded on claude\serene-lichterman-3e9092 on 2026-09-12, so the rule is written once rather than twice. That
     commit rewrites graph\pipeline\nightly.ps1 as well and had not been able to apply to main for fourteen hours;
     this file's half does not depend on that half. Whoever lands second keeps one copy and drops the other.

     Its first caller is grocery\health-heartbeat.ps1's RUN-LOG-VERDICT block, which pages when a scheduled lane's
     run did not land its commit. #>
  param([string]$Verdict)
  $v = [string]$Verdict
  if ($v -match '^REFUSED: ') { return 'refused' }
  if ($v -match '^\S+: commit refused \(git exit ') { return 'refused' }
  if ($v -match '^\S+: committer threw') { return 'threw' }
  if ($v -match '^\S+: committed \d+ file') { return 'committed' }
  if ($v -match '^\S+: nothing (to commit|changed)') { return 'nothing' }
  return 'unknown'
}

function Test-PipelineCommitLanded {
  <# PURE. Did the commit do its job, going by Get-PipelineCommitOutcome's word? 'committed' did, a failed push after it
     included, and so did 'nothing'. 'refused', 'threw', 'unknown' and any word the classifier never returns did not. #>
  param([string]$CommitOutcome)
  return (@('committed', 'nothing') -contains [string]$CommitOutcome)
}

function Get-PipelineLaneExitCode {
  <# PURE. The exit code a lane EARNED: its own work's code, and 1 when that was clean but its commit did not land.

     WHY (2026-09-11). meal-prep\pipeline\harvest-crawl.ps1's commit was refused on every run from 2026-09-07 to 09-11
     and every run stamped rc=0; grocery\check-ad-cycles.ps1's was refused on 2026-09-10 and it left through a typed
     `exit 0`. Both printed the verdict, and nothing reads a printed sentence, so the exit code has to carry it. A lane
     already failing keeps its own code, which is the more specific one. graph\pipeline\nightly.ps1's
     Get-NightlyExitCode applies the same landing rule inside its own precedence (a held card outranks it there). #>
  param([int]$LaneRc, [string]$CommitOutcome)
  if ($LaneRc -ne 0) { return $LaneRc }
  if (Test-PipelineCommitLanded -CommitOutcome $CommitOutcome) { return 0 }
  return 1
}

if ($__pcSelfTest) {
  $fail = 0
  # A LITERAL-CASE SUITE ASSERTS HOW MANY RAN (2026-09-23): every T call counts, and the verdict compares the count with
  # $pcExpectedCases below, so a case lost to a throw, a skipped block or a joined line is a failure, not a smaller pass.
  $ran = 0
  function T($n, $c, $g = '') { $script:ran++; if ($c) { Write-Output ("ok    " + $n) } else { Write-Output ("FAIL  " + $n + "   got: " + $g); $script:fail++ } }

  T 'MUST NOT FIRE a data path list is accepted' ((Assert-NoSourcePaths @('grocery/out', 'meal-prep/db/costed.json')).Count -eq 0)

  # THE FOUNDING CASE, 2026-09-05: 192 .ps1 files on main, mid-edit.
  T 'MUST FIRE  a .ps1 path is refused' ((Assert-NoSourcePaths @('grocery/out', 'grocery/capture-run.ps1')).Count -eq 1)
  T 'MUST FIRE  a .py path is refused' ((Assert-NoSourcePaths @('meal-prep/pipeline/harvest.py')).Count -eq 1)
  T 'MUST FIRE  the agent prompts are refused' ((Assert-NoSourcePaths @('.claude/agents/recipe-writer.md')).Count -eq 1)
  # I205 (2026-09-19): the case above is satisfied by the .md EXTENSION branch, so it could not see that the
  # ^\.claude/ and ^\.github/ DIRECTORY branches were dead under TrimStart('./'). These two carry no listed
  # extension, so only the directory branch can refuse them.
  T 'MUST FIRE  .claude/settings.json is refused by the directory branch, not an extension' ((Assert-NoSourcePaths @('.claude/settings.json')).Count -eq 1)
  T 'MUST FIRE  .github/CODEOWNERS is refused by the directory branch, not an extension' ((Assert-NoSourcePaths @('.github/CODEOWNERS')).Count -eq 1)
  T 'CLEAN TWIN  a literal ./ prefix is still stripped, once or repeated, so ./ops and ././lib are still refused' ((Assert-NoSourcePaths @('./ops/hooks/pre-commit', '././lib/x')).Count -eq 2)
  T 'MUST NOT FIRE ./fixture/out/x.json normalises to a data path and is accepted' ((Assert-NoSourcePaths @('./fixture/out/x.json')).Count -eq 0)
  T 'MUST FIRE  ops/ is refused even with no extension' ((Assert-NoSourcePaths @('ops/hooks/pre-commit')).Count -eq 1)
  T 'MUST FIRE  lib/ is refused' ((Assert-NoSourcePaths @('lib/pipeline-commit.ps1')).Count -eq 1)
  T 'MUST FIRE  a backslash path is normalised before matching, not missed' ((Assert-NoSourcePaths @('ops\audit-write-seam.ps1')).Count -eq 1)
  T 'MUST FIRE  design/ notes are refused - they are a human''s to commit' ((Assert-NoSourcePaths @('design/PLAN-x.md')).Count -eq 1)
  T 'MUST FIRE  a site template is refused' ((Assert-NoSourcePaths @('site/tools/dinner-tonight-tool.html')).Count -eq 1)

  # EVERY REAL LIST MUST PASS ITS OWN ASSERTION, or a lane ships that cannot ever commit.
  foreach ($k in @('pricing', 'graph', 'harvest')) {
    $p = Get-PipelinePaths -Kind $k
    $bad = Assert-NoSourcePaths $p
    T ("the $k list is data-only and can actually commit") ($bad.Count -eq 0) ($bad -join ', ')
    T ("the $k list is not empty") (@($p).Count -gt 0) (@($p).Count)
  }

  # NO PATH MAY HAVE TWO OWNERS - two committers racing for one file is a scheduled merge conflict.
  $all = @()
  foreach ($k in @('pricing', 'graph', 'harvest')) { $all += (Get-PipelinePaths -Kind $k) }
  $dupes = @($all | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
  T 'MUST FIRE  no path is owned by two lanes' ($dupes.Count -eq 0) ($dupes -join ', ')

  $v = Invoke-PipelineCommit -Repo 'C:\nope' -Paths @('ops/audit-write-seam.ps1') -Message 'x' -Name 'probe'
  T 'MUST FIRE  the committer REFUSES a source path before touching git at all' ($v -like 'REFUSED:*') $v

  $v2 = Invoke-PipelineCommit -Repo 'C:\nope' -Paths @('grocery/out/definitely-not-here.json') -Message 'x' -Name 'probe'
  T 'a path that does not exist is nothing to commit, not an error' ($v2 -like '*nothing to commit*') $v2

  # ---- THE VERDICT CLASSIFIER (2026-09-12), driven over verdicts THIS FILE really returns, never retyped ones -----
  T 'MUST FIRE  a source-path refusal classifies as refused' ((Get-PipelineCommitOutcome -Verdict $v) -eq 'refused') $v
  T 'CLEAN TWIN  a lane with none of its paths present classifies as nothing' ((Get-PipelineCommitOutcome -Verdict $v2) -eq 'nothing') $v2
  T 'MUST FIRE  an empty verdict is unknown, never a success' ((Get-PipelineCommitOutcome -Verdict '') -eq 'unknown')
  # THE FOUNDING SHAPE, from grocery\out\logs\graph-nightly-2026-09-09.log: a pre-commit hook refused the commit and
  # the run still stamped rc=0. The file list the real line carries is cut here, because naming another module's
  # internals from lib\ is a cross-module reach and the prefix is all the classifier reads.
  T 'MUST FIRE  a hook refusal classifies as refused' ((Get-PipelineCommitOutcome -Verdict 'graph-nightly: commit refused (git exit 1) - a hook or git itself rejected it; the tree is untouched. files named by the hook: ...') -eq 'refused')
  T 'MUST FIRE  a committer that threw is not a success' ((Get-PipelineCommitOutcome -Verdict 'probe: committer threw and was swallowed (the lane''s work is not lost, only uncommitted): boom') -eq 'threw')
  # CLEAN TWIN, and a REAL line: this is what the 2026-09-11 night logged, the first graph-nightly commit to land.
  T 'CLEAN TWIN  a commit whose PUSH failed is still committed, which is the whole of this file''s promise' ((Get-PipelineCommitOutcome -Verdict 'graph-nightly: committed 20 file(s) - push failed, left local for the next capture-run to carry') -eq 'committed')

  # ---- THE LANE'S EARNED EXIT CODE (2026-09-12) ----------------------------------------------------------------------
  # What a lane does with the word above. The lanes' own suites freeze the refused lines their logs really carry.
  foreach ($oc in @('refused', 'threw', 'unknown', '')) {
    $x = Get-PipelineLaneExitCode -LaneRc 0 -CommitOutcome $oc
    T ("MUST FIRE  a clean lane whose commit outcome is '" + $oc + "' exits 1, never 0") ($x -eq 1) $x
  }
  T 'CLEAN TWIN  a clean lane whose commit landed still exits 0' ((Get-PipelineLaneExitCode -LaneRc 0 -CommitOutcome 'committed') -eq 0) (Get-PipelineLaneExitCode -LaneRc 0 -CommitOutcome 'committed')
  T 'CLEAN TWIN  a clean lane with nothing to commit still exits 0' ((Get-PipelineLaneExitCode -LaneRc 0 -CommitOutcome 'nothing') -eq 0) (Get-PipelineLaneExitCode -LaneRc 0 -CommitOutcome 'nothing')
  T 'CLEAN TWIN  a lane already exiting 2 keeps its 2 when its commit is also refused' ((Get-PipelineLaneExitCode -LaneRc 2 -CommitOutcome 'refused') -eq 2) (Get-PipelineLaneExitCode -LaneRc 2 -CommitOutcome 'refused')
  T 'CLEAN TWIN  a lane already exiting 1 keeps its 1 when its commit landed' ((Get-PipelineLaneExitCode -LaneRc 1 -CommitOutcome 'committed') -eq 1) (Get-PipelineLaneExitCode -LaneRc 1 -CommitOutcome 'committed')

  # ---- FOREIGN-HELD (2026-09-10, queue 2026-09-10-3a9de4) ----------------------------------------------------------
  # PURE: the rule itself, with frozen times.
  $t0 = [datetime]'2026-09-10T07:00:00'
  # A NEUTRAL fixture directory, lane/out. The rule is path-agnostic, and spelling another module's internals from lib\
  # is a cross-module reach (ops\audit-cross-module-reach.ps1 caught the first cut of these fixtures at 147 against 133).
  $snapOk = [pscustomobject]@{ ok = $true; why = ''; files = @(
    [pscustomobject]@{ path = 'lane/out/json-readers-baseline.json'; mtime = $t0.AddHours(-2) },
    [pscustomobject]@{ path = 'lane/out/capture-cursor.json'; mtime = $t0.AddHours(-2) }) }
  $now1 = @{ 'lane/out/json-readers-baseline.json' = $t0.AddHours(-2); 'lane/out/capture-cursor.json' = $t0.AddMinutes(5) }
  $h1 = Get-ForeignHeldPaths -Snapshot $snapOk -RunStart $t0 -CurrentMtimes $now1
  T 'MUST FIRE  a file dirty before the run and untouched since is held; the one the run rewrote is not' (($h1.Count -eq 1) -and ($h1[0] -eq 'lane/out/json-readers-baseline.json')) ($h1 -join ', ')
  $h2 = Get-ForeignHeldPaths -Snapshot ([pscustomobject]@{ ok = $false; files = @(); why = 'git status failed' }) -RunStart $t0 -CurrentMtimes $now1
  T 'MUST FIRE  a snapshot that could not be taken holds NOTHING back' ($h2.Count -eq 0) ($h2 -join ', ')
  $h3 = Get-ForeignHeldPaths -Snapshot $snapOk -RunStart $t0 -CurrentMtimes @{ 'lane/out/capture-cursor.json' = $t0.AddMinutes(5) }
  T 'MUST NOT FIRE a snapshot file that has since disappeared is not held' ($h3.Count -eq 0) ($h3 -join ', ')
  # THE BAR IS `mtime -lt RunStart`, and a [datetime] is a whole number of 100 ns ticks, so both cases are exact.
  $snapBar = [pscustomobject]@{ ok = $true; why = ''; files = @([pscustomobject]@{ path = 'lane/out/bar.json'; mtime = $t0; kind = 'modified' }) }
  $hAt = Get-ForeignHeldPaths -Snapshot $snapBar -RunStart $t0 -CurrentMtimes @{ 'lane/out/bar.json' = $t0 }
  T 'MUST NOT FIRE AT THE BAR an mtime exactly equal to RunStart is the run''s own write and is not held' ($hAt.Count -eq 0) ($hAt -join ', ')
  $hPast = Get-ForeignHeldPaths -Snapshot $snapBar -RunStart $t0 -CurrentMtimes @{ 'lane/out/bar.json' = $t0.AddTicks(-1) }
  T 'MUST FIRE  ONE TICK PAST THE BAR an mtime one 100 ns tick before RunStart is held' (($hPast.Count -eq 1) -and ($hPast[0] -eq 'lane/out/bar.json')) ($hPast -join ', ')

  # ---- A DELETION PRESENT AT START IS HELD (2026-09-23, design/PLAN-bot-checkout-self-heal-2026-09-23.md W0.2) --------
  # PURE, frozen times. The founding shape is graph/provenance/2026-09-22.jsonl, deleted before a forced run and carried
  # to origin/main; here it is a neutral lane/out/prov.jsonl.
  $snapDel = [pscustomobject]@{ ok = $true; why = ''; files = @(
    [pscustomobject]@{ path = 'lane/out/prov.jsonl'; mtime = $null; kind = 'deleted' },
    [pscustomobject]@{ path = 'lane/out/back.jsonl'; mtime = $null; kind = 'deleted' },
    [pscustomobject]@{ path = 'lane/out/json-readers-baseline.json'; mtime = $t0.AddHours(-2); kind = 'modified' }) }
  $nowDel = @{ 'lane/out/back.jsonl' = $t0.AddMinutes(5); 'lane/out/json-readers-baseline.json' = $t0.AddHours(-2) }
  $hD = Get-ForeignHeldPaths -Snapshot $snapDel -RunStart $t0 -CurrentMtimes $nowDel
  T 'MUST FIRE  a deletion present at start and still absent is held, beside a held modification, in snapshot order' (($hD -join ',') -eq 'lane/out/prov.jsonl,lane/out/json-readers-baseline.json') ($hD -join ',')
  T 'MUST NOT FIRE a deletion the run brought back (the path exists again) is the run''s own and is not held' (@($hD | Where-Object { $_ -eq 'lane/out/back.jsonl' }).Count -eq 0) ($hD -join ',')
  $dlD = Format-ForeignHeldDeletionLines -Snapshot $snapDel -Held $hD
  T 'MUST FIRE  the commit stage''s line names exactly the held deletion, and the held modification gets none' `
    (($dlD.Count -eq 1) -and ($dlD[0] -eq ('foreign-held: kept a deletion ' + 'present at start: lane/out/prov.jsonl'))) ($dlD -join ' | ')
  $snapOdd = [pscustomobject]@{ ok = $true; why = ''; files = @([pscustomobject]@{ path = 'lane/out/odd.json'; mtime = $null; kind = 'renamed' }) }
  $oddMsg = ''
  try { [void](Get-ForeignHeldPaths -Snapshot $snapOdd -RunStart $t0 -CurrentMtimes @{}) } catch { $oddMsg = $_.Exception.Message }
  T 'MUST FIRE  a snapshot entry of an unknown kind throws and names the kind, instead of being guessed held or free' ($oddMsg -match 'unknown snapshot kind ''renamed''') $oddMsg
  T 'CLEAN TWIN an entry with no kind (every snapshot built before 2026-09-23) reads as modified' `
    (((Get-DirtyEntryKind -Entry $snapOk.files[0]) -eq 'modified') -and ((Get-DirtyEntryKind -Entry @{ path = 'x'; kind = 'deleted' }) -eq 'deleted')) ((Get-DirtyEntryKind -Entry $snapOk.files[0]) + ' / ' + (Get-DirtyEntryKind -Entry @{ path = 'x'; kind = 'deleted' }))

  # END TO END in a throwaway repo, repository environment cleared first (ops rule: a fixture that builds a temp repo
  # must not inherit GIT_DIR or GIT_INDEX_FILE from a hook). FROZEN from the founding case: a session stripped the BOM
  # from a pipeline-written baseline (grocery's json-readers-baseline.json, 2026-09-09) before the run started, and the
  # run never rewrote it. Same neutral lane/out directory; the run's own output is a .txt, so the fixture writes no
  # out\*.json report family that nothing reads (ops\audit-write-only-reports.ps1).
  # lib\git-repo-env.ps1 since 2026-09-11: all eight variables rather than three, and nothing to restore, because
  # this branch runs only when the file is RUN with -SelfTest, in a process of its own.
  . (Join-Path $PSScriptRoot 'git-repo-env.ps1'); Clear-TcGitRepoEnv
  $tr = Join-Path $env:TEMP ('pc-fh-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path (Join-Path $tr 'lane\out') -Force | Out-Null
    & git -C $tr init -q . | Out-Null
    & git -C $tr config user.email t@t | Out-Null
    & git -C $tr config user.name t | Out-Null
    $fA = Join-Path $tr 'lane\out\json-readers-baseline.json'
    $fB = Join-Path $tr 'lane\out\run-output.txt'
    [IO.File]::WriteAllBytes($fA, ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('{"n":1}')))
    [IO.File]::WriteAllText($fB, 'v1')
    & git -C $tr add -A -- lane/out | Out-Null
    & git -C $tr commit -q -m seed | Out-Null
    [IO.File]::WriteAllBytes($fA, [Text.Encoding]::UTF8.GetBytes('{"n":1}'))
    (Get-Item $fA).LastWriteTime = (Get-Date).AddHours(-2)
    $snapE = Get-DirtyOwnedSnapshot -Repo $tr -Paths @('lane/out')
    T 'the start snapshot sees exactly the foreign dirty file' (($snapE.ok) -and (@($snapE.files).Count -eq 1)) ('' + @($snapE.files).Count)
    $rs = (Get-Date).AddMinutes(-30)
    [IO.File]::WriteAllText($fB, 'v2')
    $ve = Invoke-PipelineCommit -Repo $tr -Paths @('lane/out') -Message 'run' -Name 'probe' -DirtyAtStart $snapE -RunStart $rs
    $inHead = @(& git -C $tr show --name-only --pretty=format: HEAD | Where-Object { $_ })
    $stillDirty = @(& git -C $tr status --porcelain | Where-Object { $_ })
    T 'MUST FIRE  the commit carries only the run''s file, names the held one, and leaves it dirty in the worktree (today''s code refused the whole commit here)' `
      (($ve -match 'committed 1 file') -and ($ve -match 'foreign-held: 1 .*json-readers-baseline\.json') -and (($inHead -join ',') -eq 'lane/out/run-output.txt') -and (($stillDirty -join ',') -match 'json-readers-baseline\.json')) ($ve + ' | head=' + ($inHead -join ',') + ' | dirty=' + ($stillDirty -join ','))
    # CLEAN TWIN: the same foreign file, dirty at start AND rewritten by the run, is committed as the run's own.
    [IO.File]::WriteAllText($fB, 'v3')
    $snapT = Get-DirtyOwnedSnapshot -Repo $tr -Paths @('lane/out')
    $rs2 = (Get-Date).AddMinutes(-1)
    [IO.File]::WriteAllBytes($fA, ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('{"n":2}')))
    [IO.File]::WriteAllText($fB, 'v4')
    $vt = Invoke-PipelineCommit -Repo $tr -Paths @('lane/out') -Message 'run2' -Name 'probe' -DirtyAtStart $snapT -RunStart $rs2
    T 'CLEAN TWIN  a foreign file the run rewrote is committed as the run''s own (2 files, nothing held)' (($vt -match 'committed 2 file') -and ($vt -notmatch 'foreign-held')) $vt
    T 'CLEAN TWIN  both landed commits classify as committed, the foreign-held note included' (((Get-PipelineCommitOutcome -Verdict $ve) -eq 'committed') -and ((Get-PipelineCommitOutcome -Verdict $vt) -eq 'committed')) ($ve + ' | ' + $vt)

    # ---- THE PIPELINE WRITE JOURNAL (2026-09-23, queue 2026-09-22-9bc4d2) ------------------------------------------
    # FROZEN from the founding case: capture-watchdog's Family Fare shard window wrote family-fare-regular-2026-09-21.json
    # after the 08:00 commit and committed nothing, so the 2026-09-22 daily run held it as another session's edit. Here a
    # non-committing lane writes a dated file and records it; a session strips a BOM from another owned file; the next
    # run rewrites neither. The lane's file must land and the session's must stay held.
    $fW = Join-Path $tr 'lane\out\regular-2026-09-21.json'
    [IO.File]::WriteAllText($fW, '{"rows":1}')
    [IO.File]::WriteAllBytes($fA, ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('{"n":3}')))
    & git -C $tr add -A -- lane/out | Out-Null
    & git -C $tr commit -q -m seed2 | Out-Null
    $laneStart = (Get-Date).AddMinutes(-3)
    [IO.File]::WriteAllText($fW, '{"rows":2}')
    $nReg = Register-PipelineWrites -Repo $tr -Lane 'probe-watchdog' -Since $laneStart -Paths @('lane/out')
    T 'the non-committing lane records exactly the one file it wrote' ($nReg -eq 1) ('' + $nReg)
    [IO.File]::WriteAllBytes($fA, [Text.Encoding]::UTF8.GetBytes('{"n":3}'))
    (Get-Item $fA).LastWriteTime = (Get-Date).AddMinutes(-2)
    (Get-Item $fW).LastWriteTime = (Get-Date).AddMinutes(-2)
    $snapJ = Get-DirtyOwnedSnapshot -Repo $tr -Paths @('lane/out')
    $rsJ = (Get-Date).AddMinutes(-1)
    [IO.File]::WriteAllText($fB, 'v4j')
    $vj = Invoke-PipelineCommit -Repo $tr -Paths @('lane/out') -Message 'run-j' -Name 'probe' -DirtyAtStart $snapJ -RunStart $rsJ
    $inHeadJ = @(& git -C $tr show --name-only --pretty=format: HEAD | Where-Object { $_ })
    $dirtyJ = @(& git -C $tr status --porcelain | Where-Object { $_ })
    T 'MUST FIRE  a declared pipeline write (a non-committing lane''s, recorded) is committed, not held as a session''s edit' `
      ((($inHeadJ -join ',') -match 'regular-2026-09-21\.json') -and ($vj -match 'pipeline-own: 1 file.*probe-watchdog.*regular-2026-09-21\.json')) ($vj + ' | head=' + ($inHeadJ -join ','))
    T 'CLEAN TWIN  a genuinely foreign edit in the same run is still held back and left dirty' `
      ((($inHeadJ -join ',') -notmatch 'json-readers-baseline') -and ($vj -match 'foreign-held: 1 .*json-readers-baseline\.json') -and (($dirtyJ -join ',') -match 'json-readers-baseline\.json')) ($vj + ' | dirty=' + ($dirtyJ -join ','))
    # A session edit AFTER the lane recorded its write changes the bytes, so the record no longer vouches for the file.
    # The lane starts NOW, after the session's older edit to the baseline file, so only its own write is recorded.
    $rsK0 = Get-Date
    [IO.File]::WriteAllText($fW, '{"rows":3}')
    [void](Register-PipelineWrites -Repo $tr -Lane 'probe-watchdog' -Since $rsK0 -Paths @('lane/out'))
    [IO.File]::WriteAllText($fW, '{"rows":3,"hand":true}')
    (Get-Item $fW).LastWriteTime = (Get-Date).AddMinutes(-2)
    $snapK = Get-DirtyOwnedSnapshot -Repo $tr -Paths @('lane/out')
    $rsK = (Get-Date).AddMinutes(-1)
    [IO.File]::WriteAllText($fB, 'v4k')
    $vk = Invoke-PipelineCommit -Repo $tr -Paths @('lane/out') -Message 'run-k' -Name 'probe' -DirtyAtStart $snapK -RunStart $rsK
    T 'MUST FIRE  a pipeline write a session then edited is held: the recorded bytes are not the bytes on disk' `
      (($vk -match 'foreign-held: 2 .*regular-2026-09-21\.json') -and ($vk -notmatch 'pipeline-own')) $vk
    T 'CLEAN TWIN  the journal lives in the git common dir, not in the tree, so it can never ride a commit' `
      ((Test-Path -LiteralPath (Join-Path $tr ('.git\' + $script:PC_JOURNAL_NAME))) -and (@(& git -C $tr ls-files | Where-Object { $_ -match 'tc-pipeline-writes' }).Count -eq 0)) (Get-PipelineWriteJournalPath -Repo $tr)
    # A DAMAGED journal degrades to the day before: every candidate held, and the note says why.
    [IO.File]::WriteAllText((Get-PipelineWriteJournalPath -Repo $tr), '{not json')
    $sd = Split-PipelineOwnHeld -Repo $tr -Held @('lane/out/regular-2026-09-21.json')
    T 'MUST FIRE  an unreadable journal holds every candidate and says so' ((@($sd.foreign).Count -eq 1) -and ($sd.note -match 'could not be read')) ($sd.note)
    # Leave the fixture repo clean for the push case below, which counts exactly one file.
    & git -C $tr add -A -- lane/out | Out-Null
    & git -C $tr commit -q -m tidy | Out-Null
    # CLEAN TWIN (2026-09-12): the commit LANDS and the push FAILS, and a clean lane must still exit 0. Hooks pinned to
    # an EMPTY directory so no inherited core.hooksPath can refuse this commit instead, and this repo has no remote, so
    # -Push fails for real: the sentence scored is the one the committer builds for that case, not a retyped copy.
    $noHookDir = Join-Path $tr 'fixture-no-hooks'
    New-Item -ItemType Directory -Path $noHookDir -Force | Out-Null
    & git -C $tr config core.hooksPath ($noHookDir -replace '\\', '/') | Out-Null
    [IO.File]::WriteAllText($fB, 'v5')
    $vp = Invoke-PipelineCommit -Repo $tr -Paths @('lane/out') -Message 'run3' -Name 'probe' -Push
    $xp = Get-PipelineLaneExitCode -LaneRc 0 -CommitOutcome (Get-PipelineCommitOutcome -Verdict $vp)
    T 'CLEAN TWIN  a landed commit whose push failed classifies as committed and a clean lane still exits 0' (($vp -match 'committed 1 file') -and ($vp -match 'push (failed|threw)') -and ((Get-PipelineCommitOutcome -Verdict $vp) -eq 'committed') -and ($xp -eq 0)) ($vp + ' | exit=' + $xp)
  } catch {
    T 'the first end-to-end block ran to its end without throwing' $false $_.Exception.Message
  } finally {
    Remove-Item -LiteralPath $tr -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ---- W0.2 END TO END: a deletion present at start stays out of the commit (2026-09-23) --------------------------------
  # A second throwaway repo, its own per-run name, removed in finally, repository environment already cleared above.
  # FROZEN from the founding case: a session deleted a tracked owned file (graph/provenance/2026-09-22.jsonl) before a
  # forced run, the run never brought it back, and the bot commit carried the deletion. Beside it, the adjacent shapes a
  # snapshot change could break: a deletion made DURING the run, a deletion the run undoes, a deleted single-file owned
  # path, an index-only add, a session's modification, a pipeline lane's recorded write, and a path with a space and a
  # non-ASCII letter.
  $tr2 = Join-Path $env:TEMP ('pc-dl-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path (Join-Path $tr2 'lane\out') -Force | Out-Null
    & git -C $tr2 init -q . | Out-Null
    & git -C $tr2 config user.email t@t | Out-Null
    & git -C $tr2 config user.name t | Out-Null
    # Hooks pinned to an EMPTY directory, so no inherited core.hooksPath can refuse a commit this block judges.
    $noHook2 = Join-Path $tr2 'fixture-no-hooks'
    New-Item -ItemType Directory -Path $noHook2 -Force | Out-Null
    & git -C $tr2 config core.hooksPath ($noHook2 -replace '\\', '/') | Out-Null
    $odd = 'lane/out/caf' + [char]0x00E9 + ' x.json'
    $seed2 = [ordered]@{
      'lane/out/prov.jsonl' = '{"p":1}'; 'lane/out/back.jsonl' = '{"b":1}'; 'lane/out/during.json' = '{"d":1}'
      'lane/out/baseline.json' = '{"n":1}'; 'lane/out/written.json' = '{"w":1}'; 'lane/out/run-output.txt' = 'v1'
      'lane/single.json' = '{"s":1}' }
    $seed2[$odd] = '{"o":1}'
    foreach ($k in @($seed2.Keys)) { [IO.File]::WriteAllText((Join-Path $tr2 $k), [string]$seed2[$k]) }
    & git -C $tr2 add -A -- lane | Out-Null
    & git -C $tr2 commit -q -m seed | Out-Null
    $provBlob0 = ([string](& git -C $tr2 rev-parse 'HEAD:lane/out/prov.jsonl')).Trim()
    # BEFORE THE RUN. The session deletes three files and edits two; a pipeline lane writes one and records it; an index-
    # only add is deleted from disk (AD).
    Remove-Item -LiteralPath (Join-Path $tr2 'lane/out/prov.jsonl')
    Remove-Item -LiteralPath (Join-Path $tr2 'lane/out/back.jsonl')
    Remove-Item -LiteralPath (Join-Path $tr2 'lane/single.json')
    foreach ($k in @('lane/out/baseline.json', $odd)) {
      [IO.File]::WriteAllText((Join-Path $tr2 $k), '{"session":true}')
      (Get-Item -LiteralPath (Join-Path $tr2 $k)).LastWriteTime = (Get-Date).AddHours(-2)
    }
    $wLane = (Get-Date).AddMinutes(-3)
    [IO.File]::WriteAllText((Join-Path $tr2 'lane/out/written.json'), '{"w":2}')
    $nW = Register-PipelineWrites -Repo $tr2 -Lane 'probe-lane' -Since $wLane -Paths @('lane/out/written.json')
    (Get-Item -LiteralPath (Join-Path $tr2 'lane/out/written.json')).LastWriteTime = (Get-Date).AddMinutes(-2)
    [IO.File]::WriteAllText((Join-Path $tr2 'lane/out/idx-only.json'), '{"i":1}')
    & git -C $tr2 add -- lane/out/idx-only.json | Out-Null
    Remove-Item -LiteralPath (Join-Path $tr2 'lane/out/idx-only.json')
    $snapD = Get-DirtyOwnedSnapshot -Repo $tr2 -Paths @('lane/out', 'lane/single.json')
    $kinds = @{}
    foreach ($f in @($snapD.files)) { $kinds[[string]$f.path] = (Get-DirtyEntryKind -Entry $f) }
    $kindText = (@($kinds.Keys | Sort-Object) | ForEach-Object { $_ + '=' + $kinds[$_] }) -join ', '
    T 'MUST FIRE  the start snapshot keeps a worktree deletion of a HEAD-tracked file as kind deleted with no mtime' `
      (($snapD.ok) -and ($kinds['lane/out/prov.jsonl'] -eq 'deleted') -and ($kinds['lane/out/back.jsonl'] -eq 'deleted') -and ($nW -eq 1)) ($kindText + ' | registered=' + $nW)
    T 'MUST FIRE  a deleted SINGLE-FILE owned path is seen although it is not on disk to be listed' ($kinds['lane/single.json'] -eq 'deleted') $kindText
    T 'MUST NOT FIRE an index-only add deleted from disk (AD: HEAD does not track it) is no deletion the run was handed' (-not $kinds.ContainsKey('lane/out/idx-only.json')) $kindText
    T 'CLEAN TWIN the -z listing names a path with a space and a non-ASCII letter exactly, as modified' ($kinds[$odd] -eq 'modified') $kindText
    T 'CLEAN TWIN a session''s modification is still snapshotted as modified with its mtime' `
      (($kinds['lane/out/baseline.json'] -eq 'modified') -and (@($snapD.files | Where-Object { $_.path -eq 'lane/out/baseline.json' -and $_.mtime -is [datetime] }).Count -eq 1)) $kindText
    # THE RUN. It writes its own file, brings back.jsonl back with new bytes, and deletes during.json itself.
    $rsD = (Get-Date).AddMinutes(-1)
    [IO.File]::WriteAllText((Join-Path $tr2 'lane/out/run-output.txt'), 'v2')
    [IO.File]::WriteAllText((Join-Path $tr2 'lane/out/back.jsonl'), '{"b":2}')
    Remove-Item -LiteralPath (Join-Path $tr2 'lane/out/during.json')
    $vD = Invoke-PipelineCommit -Repo $tr2 -Paths @('lane/out', 'lane/single.json') -Message 'run-d' -Name 'probe' -DirtyAtStart $snapD -RunStart $rsD
    $treeD = @{}
    $lsD = Invoke-GitCaptured -Repo $tr2 -GitArgs @('-c', 'core.quotePath=false', 'ls-tree', '-r', '-z', 'HEAD', '--', 'lane')
    foreach ($row in @(([string]$lsD.stdout).Split([char]0) | Where-Object { $_ })) { $tab = $row.IndexOf("`t"); $treeD[$row.Substring($tab + 1)] = ($row.Substring(0, $tab) -split ' ')[2] }
    $statusD = @((Invoke-GitCaptured -Repo $tr2 -GitArgs @('-c', 'core.quotePath=false', 'status', '--porcelain', '-z', '--untracked-files=no')).stdout.Split([char]0) | Where-Object { $_ })
    T 'MUST FIRE  a deletion present at start and still absent is NOT committed: HEAD still lists the file at its blob, the line names it, and it stays deleted on disk' `
      (($treeD['lane/out/prov.jsonl'] -eq $provBlob0) -and ($vD -match [regex]::Escape('foreign-held: kept a deletion present at start: lane/out/prov.jsonl')) -and ($statusD -contains ' D lane/out/prov.jsonl')) ($vD + ' | head prov=' + $treeD['lane/out/prov.jsonl'] + ' | status=' + ($statusD -join ','))
    T 'MUST FIRE  a deleted single-file owned path is kept in HEAD and named on its own line' `
      (($treeD.ContainsKey('lane/single.json')) -and ($vD -match [regex]::Escape('kept a deletion present at start: lane/single.json'))) $vD
    T 'MUST NOT FIRE a tracked file the run itself deleted DURING the run is committed as a deletion, as before' `
      ((-not $treeD.ContainsKey('lane/out/during.json')) -and ($vD -notmatch 'during\.json')) ($vD + ' | head=' + (@($treeD.Keys | Sort-Object) -join ','))
    T 'MUST NOT FIRE a deletion the run brought back is committed with the run''s new bytes, never held' `
      (($treeD['lane/out/back.jsonl'] -eq ([string](& git -C $tr2 hash-object -- lane/out/back.jsonl)).Trim()) -and ($vD -notmatch 'back\.jsonl')) $vD
    T 'CLEAN TWIN a session''s modification present at start is still held at HEAD''s bytes and left dirty, as before' `
      (($vD -match 'foreign-held: 4 tracked owned file') -and ($statusD -contains ' M lane/out/baseline.json') -and ($statusD -contains (' M ' + $odd))) ($vD + ' | status=' + ($statusD -join ','))
    T 'CLEAN TWIN a recorded pipeline write beside held deletions is still committed as the pipeline''s own (a missing path never breaks the hash)' `
      (($vD -match 'pipeline-own: 1 file.*probe-lane.*written\.json') -and ($treeD['lane/out/written.json'] -eq ([string](& git -C $tr2 hash-object -- lane/out/written.json)).Trim())) $vD
    T 'CLEAN TWIN the landed commit still classifies as committed with its held-deletion lines' ((Get-PipelineCommitOutcome -Verdict $vD) -eq 'committed') $vD
  } catch {
    T 'the W0.2 end-to-end block ran to its end without throwing' $false $_.Exception.Message
  } finally {
    Remove-Item -LiteralPath $tr2 -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ---- W3.2: A -Built ENTRY VOUCHES WITHOUT COMMITTING, AND THE MOVER GETS ITS BLOBS (2026-09-23) -----------------------
  # A third throwaway repo, per-run name, removed in finally. FROZEN from the shape W3.2 exists for: a day whose guards
  # held the board still wrote its served outputs, and they must be vouched pipeline bytes for the checkout sync while no
  # committer ever ships them. lane/pub stands in for the served paths.
  $tr3 = Join-Path $env:TEMP ('pc-bu-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path (Join-Path $tr3 'lane\out') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tr3 'lane\pub') -Force | Out-Null
    & git -C $tr3 init -q . | Out-Null
    & git -C $tr3 config user.email t@t | Out-Null
    & git -C $tr3 config user.name t | Out-Null
    $noHook3 = Join-Path $tr3 'fixture-no-hooks'
    New-Item -ItemType Directory -Path $noHook3 -Force | Out-Null
    & git -C $tr3 config core.hooksPath ($noHook3 -replace '\\', '/') | Out-Null
    foreach ($k in @('lane/pub/served.json', 'lane/out/run-output.txt', 'lane/out/old.json', 'lane/out/str.json')) { [IO.File]::WriteAllText((Join-Path $tr3 $k), 'seed') }
    & git -C $tr3 add -A -- lane | Out-Null
    & git -C $tr3 commit -q -m seed | Out-Null
    $servedSeed = ([string](& git -C $tr3 rev-parse 'HEAD:lane/pub/served.json')).Trim()
    # THE BLOCKED DAY. The chain writes the served file, guards hold the board, and the run records it -Built.
    $bStart = (Get-Date).AddMinutes(-3)
    [IO.File]::WriteAllText((Join-Path $tr3 'lane/pub/served.json'), '{"served":2}')
    $nB = Register-PipelineWrites -Repo $tr3 -Lane 'probe-built' -Since $bStart -Paths @('lane/pub') -Built
    T 'the -Built registration records exactly the one served file it wrote' ($nB -eq 1) ('' + $nB)
    $servedNow = ([string](& git -C $tr3 hash-object -- lane/pub/served.json)).Trim()
    $ob = Get-PipelineOwnBlobs -Repo $tr3
    T 'MUST FIRE  Get-PipelineOwnBlobs returns a -Built entry with its blob, in a hashtable whose note is empty' `
      (($ob -is [hashtable]) -and ($ob['lane/pub/served.json'] -eq $servedNow) -and ([string]$ob.note -eq '')) ('blob=' + $ob['lane/pub/served.json'] + ' want=' + $servedNow + ' note=' + $ob.note)
    T 'MUST NOT FIRE the table is Ordinal: a path spelled in another case is not vouched' (-not $ob.ContainsKey('LANE/pub/served.json')) (@($ob.Keys) -join ',')
    $ohB = Get-PipelineOwnHeld -Repo $tr3 -Paths @('lane/pub/served.json')
    T 'MUST NOT FIRE a -Built entry is never committed by Get-PipelineOwnHeld, although its bytes match' ($ohB.Count -eq 0) (@($ohB | ForEach-Object { $_.path }) -join ',')
    # THE NEXT RUN. The served file is dirty at start and not rewritten; the run writes only its own file.
    (Get-Item -LiteralPath (Join-Path $tr3 'lane/pub/served.json')).LastWriteTime = (Get-Date).AddMinutes(-2)
    $snapB = Get-DirtyOwnedSnapshot -Repo $tr3 -Paths @('lane/out', 'lane/pub')
    $rsB = (Get-Date).AddMinutes(-1)
    [IO.File]::WriteAllText((Join-Path $tr3 'lane/out/run-output.txt'), 'v2')
    $vB = Invoke-PipelineCommit -Repo $tr3 -Paths @('lane/out', 'lane/pub') -Message 'run-b' -Name 'probe' -DirtyAtStart $snapB -RunStart $rsB
    $servedHead = ([string](& git -C $tr3 rev-parse 'HEAD:lane/pub/served.json')).Trim()
    T 'MUST NOT FIRE end to end, the next run holds a blocked day''s built file and commits only its own' `
      (($vB -match 'committed 1 file') -and ($vB -match 'foreign-held: 1 .*lane/pub/served\.json') -and ($vB -notmatch 'pipeline-own') -and ($servedHead -eq $servedSeed)) ($vB + ' | head served=' + $servedHead)
    # HAND-WRITTEN ROWS beside the built one: a row from before -Built existed (no commit field), a row whose commit
    # field is the STRING "false", and another checkout's row.
    [IO.File]::WriteAllText((Join-Path $tr3 'lane/out/old.json'), '{"old":2}')
    [IO.File]::WriteAllText((Join-Path $tr3 'lane/out/str.json'), '{"str":2}')
    $oldBlob = ([string](& git -C $tr3 hash-object -- lane/out/old.json)).Trim()
    $strBlob = ([string](& git -C $tr3 hash-object -- lane/out/str.json)).Trim()
    $jp3 = Get-PipelineWriteJournalPath -Repo $tr3
    $doc3 = [IO.File]::ReadAllText($jp3, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json
    $w3 = [ordered]@{}
    foreach ($pp in $doc3.writes.PSObject.Properties) { $w3[$pp.Name] = $pp.Value }
    $ck3 = Get-PipelineCheckoutKey -Repo $tr3
    $nowS = (Get-Date).ToString('s')
    $w3[($ck3 + '|lane/out/old.json')] = [pscustomobject]@{ blob = $oldBlob; lane = 'pre-w32-lane'; ts = $nowS }
    $w3[($ck3 + '|lane/out/str.json')] = [pscustomobject]@{ blob = $strBlob; lane = 'hand-typed'; ts = $nowS; commit = 'false' }
    $w3['c:\another\checkout|lane/out/other.json'] = [pscustomobject]@{ blob = $oldBlob; lane = 'elsewhere'; ts = $nowS; commit = $true }
    [IO.File]::WriteAllText($jp3, ([pscustomobject]@{ writes = [pscustomobject]$w3 } | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $ohH = Get-PipelineOwnHeld -Repo $tr3 -Paths @('lane/out/old.json', 'lane/pub/served.json', 'lane/out/str.json')
    $ohHPaths = @($ohH | ForEach-Object { [string]$_.path })
    T 'CLEAN TWIN an entry written before -Built existed (no commit field) is still committable' (($ohHPaths -join ',') -eq 'lane/out/old.json') ($ohHPaths -join ',')
    T 'MUST NOT FIRE a commit field that is not the JSON boolean true fails closed and is never committed' ($ohHPaths -notcontains 'lane/out/str.json') ($ohHPaths -join ',')
    $ob2 = Get-PipelineOwnBlobs -Repo $tr3
    T 'MUST FIRE  Get-PipelineOwnBlobs vouches entries of either kind: the built, the pre-W3.2 and the damaged-flag row' `
      (($ob2.Count -eq 3) -and ($ob2['lane/pub/served.json'] -eq $servedNow) -and ($ob2['lane/out/old.json'] -eq $oldBlob) -and ($ob2['lane/out/str.json'] -eq $strBlob)) (@($ob2.Keys | Sort-Object) -join ',')
    T 'MUST NOT FIRE Get-PipelineOwnBlobs holds only THIS checkout''s entries, never another checkout''s row' (-not $ob2.ContainsKey('lane/out/other.json')) (@($ob2.Keys | Sort-Object) -join ',')
    # THE NEWEST REGISTRATION OF A PATH WINS: a committing lane that records the same file later makes it committable.
    $rjSince = (Get-Date).AddMinutes(-1)
    (Get-Item -LiteralPath (Join-Path $tr3 'lane/pub/served.json')).LastWriteTime = Get-Date
    [void](Register-PipelineWrites -Repo $tr3 -Lane 'probe-ship' -Since $rjSince -Paths @('lane/pub'))
    $ohJ = Get-PipelineOwnHeld -Repo $tr3 -Paths @('lane/pub/served.json')
    T 'CLEAN TWIN a -Built path registered again by a committing lane is committable: the newest registration wins' `
      (($ohJ.Count -eq 1) -and ($ohJ[0].path -eq 'lane/pub/served.json') -and ($ohJ[0].lane -eq 'probe-ship')) (@($ohJ | ForEach-Object { $_.path + '@' + $_.lane }) -join ',')
    # AND IT DEGRADES TO THE DAY BEFORE: nothing vouched, and the note says why.
    [IO.File]::WriteAllText($jp3, '{not json')
    $ob3 = Get-PipelineOwnBlobs -Repo $tr3
    T 'MUST FIRE  an unreadable journal gives Get-PipelineOwnBlobs an EMPTY table with a note, and never throws' `
      (($ob3 -is [hashtable]) -and ($ob3.Count -eq 0) -and ([string]$ob3.note -match 'could not be read')) ('count=' + $ob3.Count + ' note=' + $ob3.note)
    Remove-Item -LiteralPath $jp3 -Force
    $ob4 = Get-PipelineOwnBlobs -Repo $tr3
    T 'MUST NOT FIRE an absent journal is an empty table with no note: no lane recorded anything, and nothing is wrong' (($ob4.Count -eq 0) -and ([string]$ob4.note -eq '')) ('count=' + $ob4.Count + ' note=' + $ob4.note)
    $ob5 = Get-PipelineOwnBlobs -Repo (Join-Path $tr3 'no-such-checkout')
    T 'MUST FIRE  a checkout git cannot place gives an empty table and says so' (($ob5.Count -eq 0) -and ([string]$ob5.note -match 'could not name the common dir')) ('count=' + $ob5.Count + ' note=' + $ob5.note)
  } catch {
    T 'the W3.2 end-to-end block ran to its end without throwing' $false $_.Exception.Message
  } finally {
    Remove-Item -LiteralPath $tr3 -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ---- A REFUSED RUN'S OWN DELETION LANDS WITH THE NEXT RUN (2026-09-23, the checkout-sync lane's review) ---------------
  # FROZEN from the review's proof: day 1 modifies a data file and deletes a tracked flag
  # (browser-capture-due-2026-09-21.flag on main, from the refused 09-22 and 09-23 days), and its commit is refused. The
  # write journal vouched for the data file and had nothing for the deletion, so day 2 held the deletion as a session's
  # and it never landed. A fourth throwaway repo, per-run name, removed in finally.
  $tr4 = Join-Path $env:TEMP ('pc-dc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path (Join-Path $tr4 'lane\out') -Force | Out-Null
    & git -C $tr4 init -q . | Out-Null
    & git -C $tr4 config user.email t@t | Out-Null
    & git -C $tr4 config user.name t | Out-Null
    $noHook4 = Join-Path $tr4 'fixture-no-hooks'
    New-Item -ItemType Directory -Path $noHook4 -Force | Out-Null
    & git -C $tr4 config core.hooksPath ($noHook4 -replace '\\', '/') | Out-Null
    foreach ($k in @('lane/out/due-2026-09-21.flag', 'lane/out/data.json', 'lane/out/sess.jsonl', 'lane/out/back.flag')) { [IO.File]::WriteAllText((Join-Path $tr4 $k), ('seed ' + $k)) }
    & git -C $tr4 add -A -- lane | Out-Null
    & git -C $tr4 commit -q -m seed | Out-Null
    # BEFORE DAY 1: a session deletes sess.jsonl. DAY 1: the run rewrites data.json and deletes the flag and back.flag.
    Remove-Item -LiteralPath (Join-Path $tr4 'lane/out/sess.jsonl')
    $snap41 = Get-DirtyOwnedSnapshot -Repo $tr4 -Paths @('lane/out')
    $rs41 = (Get-Date).AddMinutes(-3)
    [IO.File]::WriteAllText((Join-Path $tr4 'lane/out/data.json'), '{"day":1}')
    Remove-Item -LiteralPath (Join-Path $tr4 'lane/out/due-2026-09-21.flag')
    Remove-Item -LiteralPath (Join-Path $tr4 'lane/out/back.flag')
    $del41 = Get-PipelineRunDeletions -Repo $tr4 -Paths @('lane/out') -DirtyAtStart $snap41
    T 'MUST FIRE  a run''s own deletions are found, and a deletion present at its start is not one of them' `
      ((($del41 | Sort-Object) -join ',') -eq 'lane/out/back.flag,lane/out/due-2026-09-21.flag') (($del41 | Sort-Object) -join ',')
    # THE COMMIT IS REFUSED: nothing lands, and the run records what it wrote and what it deleted.
    $n41 = Register-PipelineWrites -Repo $tr4 -Lane 'probe-refused' -Since $rs41 -Paths @('lane/out') -Deleted $del41
    # A session brings back.flag back before day 2: a tombstone for a path that exists again vouches for nothing.
    [IO.File]::WriteAllText((Join-Path $tr4 'lane/out/back.flag'), 'restored by a session')
    $ohBack = Get-PipelineOwnHeld -Repo $tr4 -Paths @('lane/out/back.flag')
    $ob41 = Get-PipelineOwnBlobs -Repo $tr4
    T 'MUST NOT FIRE a tombstone is never a blob the mover vouches, and one whose path exists again commits nothing' `
      (($n41 -eq 3) -and (-not $ob41.ContainsKey('lane/out/due-2026-09-21.flag')) -and ($ohBack.Count -eq 0) -and ($ob41.ContainsKey('lane/out/data.json'))) ('registered=' + $n41 + ' vouched=' + (@($ob41.Keys | Sort-Object) -join ',') + ' back=' + $ohBack.Count)
    # DAY 2: everything day 1 left is dirty at start, and the run rewrites none of it.
    (Get-Item -LiteralPath (Join-Path $tr4 'lane/out/data.json')).LastWriteTime = (Get-Date).AddMinutes(-2)
    (Get-Item -LiteralPath (Join-Path $tr4 'lane/out/back.flag')).LastWriteTime = (Get-Date).AddMinutes(-2)
    $snap42 = Get-DirtyOwnedSnapshot -Repo $tr4 -Paths @('lane/out')
    $rs42 = (Get-Date).AddMinutes(-1)
    $v42 = Invoke-PipelineCommit -Repo $tr4 -Paths @('lane/out') -Message 'day-2' -Name 'probe' -DirtyAtStart $snap42 -RunStart $rs42
    $tree42 = @((Invoke-GitCaptured -Repo $tr4 -GitArgs @('ls-tree', '-r', '--name-only', 'HEAD', '--', 'lane')).stdout -split "`r?`n" | Where-Object { $_ })
    T 'MUST FIRE  the next run commits the deletion the refused run recorded, beside its vouched write' `
      (($tree42 -notcontains 'lane/out/due-2026-09-21.flag') -and ($tree42 -contains 'lane/out/data.json') -and ($v42 -match 'pipeline-own: 2 file') -and ($v42 -notmatch 'kept a deletion present at start: lane/out/due-2026-09-21\.flag')) ($v42 + ' | head=' + ($tree42 -join ','))
    T 'CLEAN TWIN a session''s deletion with no tombstone is still held and named, as W0.2 says' `
      (($tree42 -contains 'lane/out/sess.jsonl') -and ($v42 -match [regex]::Escape('kept a deletion present at start: lane/out/sess.jsonl'))) $v42
  } catch {
    T 'the deletion-carry end-to-end block ran to its end without throwing' $false $_.Exception.Message
  } finally {
    Remove-Item -LiteralPath $tr4 -Recurse -Force -ErrorAction SilentlyContinue
  }

  # ---- THE SHARED INDEX IS RESYNCED FOR EXACTLY WHAT THE COMMIT CARRIED (2026-09-24, design/backlog-inbox/sh-pc-2026-09-23.md) --
  # FROZEN from the finding's probe (lib blob e9a1d1aae281): a lane commit that modified a.json, deleted gone.json and
  # added new.json left the real index reading `MM a.json`, `AD gone.json` and `D  new.json`, a staged REVERT of the
  # lane's commit, and the AD row is the resurrection shape of cec9779a3 (deleted files back on disk from the index).
  # Beside them: a delete-plus-identical-add git would pair as a RENAME, a path with a space and a non-ASCII letter, and
  # another session's staged entry that must stay staged. A fifth throwaway repo, per-run name, removed in finally.
  $tr5 = Join-Path $env:TEMP ('pc-ix-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path (Join-Path $tr5 'lane\out') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tr5 'other') -Force | Out-Null
    & git -C $tr5 init -q . | Out-Null
    & git -C $tr5 config user.email t@t | Out-Null
    & git -C $tr5 config user.name t | Out-Null
    $noHook5 = Join-Path $tr5 'fixture-no-hooks'
    New-Item -ItemType Directory -Path $noHook5 -Force | Out-Null
    & git -C $tr5 config core.hooksPath ($noHook5 -replace '\\', '/') | Out-Null
    $odd5 = 'lane/out/caf' + [char]0x00E9 + ' y.json'
    $seed5 = [ordered]@{ 'lane/out/a.json' = '{"a":1}'; 'lane/out/gone.json' = '{"g":1}'; 'lane/out/moved-from.json' = '{"moved":"same bytes"}'; 'other/sess.json' = '{"s":1}' }
    foreach ($k in @($seed5.Keys)) { [IO.File]::WriteAllText((Join-Path $tr5 $k), [string]$seed5[$k]) }
    & git -C $tr5 add -A -- lane other | Out-Null
    & git -C $tr5 commit -q -m seed | Out-Null
    $seedSha5 = ([string](& git -C $tr5 rev-parse HEAD)).Trim()
    # ANOTHER SESSION, before the lane commits: it stages sess.json at s2 and then edits it again on disk (MM).
    [IO.File]::WriteAllText((Join-Path $tr5 'other/sess.json'), '{"s":2}')
    & git -C $tr5 add -- other/sess.json | Out-Null
    $sessStaged = ([string](& git -C $tr5 rev-parse ':other/sess.json')).Trim()
    [IO.File]::WriteAllText((Join-Path $tr5 'other/sess.json'), '{"s":3}')
    # THE LANE: modify, delete, add, delete-plus-identical-add, and an add with a space and a non-ASCII letter.
    [IO.File]::WriteAllText((Join-Path $tr5 'lane/out/a.json'), '{"a":2}')
    Remove-Item -LiteralPath (Join-Path $tr5 'lane/out/gone.json')
    [IO.File]::WriteAllText((Join-Path $tr5 'lane/out/new.json'), '{"n":1}')
    Remove-Item -LiteralPath (Join-Path $tr5 'lane/out/moved-from.json')
    [IO.File]::WriteAllText((Join-Path $tr5 'lane/out/moved-to.json'), '{"moved":"same bytes"}')
    [IO.File]::WriteAllText((Join-Path $tr5 $odd5), '{"o":1}')
    $v5 = Invoke-PipelineCommit -Repo $tr5 -Paths @('lane/out') -Message 'lane' -Name 'probe'
    $ns5 = @(([string](Invoke-GitCaptured -Repo $tr5 -GitArgs @('-c', 'core.quotePath=false', 'show', '--no-renames', '--name-status', '-z', '--pretty=format:', 'HEAD')).stdout).Split([char]0) | Where-Object { $_ -and $_.Trim() })
    $nsPairs = @(); for ($i = 0; $i + 1 -lt $ns5.Count; $i += 2) { $nsPairs += ($ns5[$i].Trim() + ' ' + $ns5[$i + 1]) }
    $nsText = (@($nsPairs | Sort-Object) -join ',')
    $wantNs = (@('A lane/out/moved-to.json', 'A lane/out/new.json', ('A ' + $odd5), 'D lane/out/gone.json', 'D lane/out/moved-from.json', 'M lane/out/a.json') | Sort-Object) -join ','
    $blobsOk = $true
    foreach ($k in @('lane/out/a.json', 'lane/out/new.json', 'lane/out/moved-to.json', $odd5)) {
      $hb = ([string](Invoke-GitCaptured -Repo $tr5 -GitArgs @('rev-parse', ('HEAD:' + $k))).stdout).Trim()
      $wb = ([string](Invoke-GitCaptured -Repo $tr5 -GitArgs @('hash-object', '--', $k)).stdout).Trim()
      if (-not $hb -or ($hb -ne $wb)) { $blobsOk = $false }
    }
    $parent5 = ([string](& git -C $tr5 rev-parse 'HEAD^')).Trim()
    # The verdict's count is 5 for six changes, as it was before the resync existed: it counts `diff --cached --name-only`,
    # which pairs the delete-plus-identical-add as ONE rename. That is also why the resync reads the commit --no-renames.
    T 'CLEAN TWIN  the commit itself is unchanged: one commit on the seed, exactly the lane''s six changes, each blob the bytes on disk' `
      (($v5 -match '^probe: committed 5 file\(s\)$') -and ($nsText -eq $wantNs) -and $blobsOk -and ($parent5 -eq $seedSha5)) ($v5 + ' | ns=' + $nsText + ' | blobs=' + $blobsOk + ' | parent ok=' + ($parent5 -eq $seedSha5))
    $st5 = @(([string](Invoke-GitCaptured -Repo $tr5 -GitArgs @('-c', 'core.quotePath=false', 'status', '--porcelain', '-z', '--untracked-files=all', '--', 'lane', 'other')).stdout).Split([char]0) | Where-Object { $_ })
    $laneRows = @($st5 | Where-Object { $_.Length -gt 3 -and $_.Substring(3).StartsWith('lane/') })
    T 'MUST FIRE  no committed path is left staged: the real index reads nothing under the lane''s path, not MM, AD, D or ??' ($laneRows.Count -eq 0) ($laneRows -join ' | ')
    $lsGone = @(& git -C $tr5 ls-files -- lane/out/gone.json lane/out/moved-from.json | Where-Object { $_ })
    & git -C $tr5 checkout-index -a -q | Out-Null
    $back5 = @(@('lane/out/gone.json', 'lane/out/moved-from.json') | Where-Object { Test-Path -LiteralPath (Join-Path $tr5 $_) })
    T 'MUST FIRE  the RESURRECTION: a deleted path (the rename-shaped one too) leaves the index, so a restore from it brings nothing back on disk' `
      (($lsGone.Count -eq 0) -and ($back5.Count -eq 0)) ('index=' + ($lsGone -join ',') + ' disk=' + ($back5 -join ','))
    $sessNow = ([string](& git -C $tr5 rev-parse ':other/sess.json')).Trim()
    T 'MUST NOT FIRE another session''s staged entry outside the commit is still staged at its own blob, and still MM against its later edit' `
      (($sessNow -eq $sessStaged) -and ($st5 -contains 'MM other/sess.json')) ('staged=' + $sessNow + ' want=' + $sessStaged + ' | status=' + ($st5 -join ' | '))
    $laneTree0 = ([string](& git -C $tr5 rev-parse 'HEAD:lane')).Trim()
    & git -C $tr5 commit -q -m careless | Out-Null
    $laneTree1 = ([string](& git -C $tr5 rev-parse 'HEAD:lane')).Trim()
    T 'MUST FIRE  a careless whole-index commit afterwards undoes none of the lane''s commit (the lane tree is unchanged)' ($laneTree1 -eq $laneTree0) ('before=' + $laneTree0 + ' after=' + $laneTree1)
    # HEAD IS NOT THIS CALL'S COMMIT: another committer moved it between the commit and the resync. Here HEAD is the
    # careless commit, whose one path is the session's; a resync handed a parent that is not HEAD^ must reset nothing.
    [IO.File]::WriteAllText((Join-Path $tr5 'other/sess.json'), '{"s":4}')
    & git -C $tr5 add -- other/sess.json | Out-Null
    $sess4 = ([string](& git -C $tr5 rev-parse ':other/sess.json')).Trim()
    $vS = Sync-PipelineSharedIndex -Repo $tr5 -Parent $seedSha5
    $sessAfter = ([string](& git -C $tr5 rev-parse ':other/sess.json')).Trim()
    T 'MUST NOT FIRE a resync whose commit is no longer HEAD resets nothing and says SKIPPED (the session''s staged entry stays)' `
      (($vS -match 'index resync SKIPPED') -and ($sessAfter -eq $sess4)) ($vS + ' | staged=' + $sessAfter + ' want=' + $sess4)
    # A RESYNC THAT CANNOT RUN IS SPOKEN, never fatal: another process holds the real index's lock. The private-index commit
    # still lands, and the verdict says the shared index was left stale rather than claiming it was synced.
    [IO.File]::WriteAllText((Join-Path $tr5 'lane/out/a.json'), '{"a":3}')
    $lock5 = Join-Path $tr5 '.git\index.lock'
    [IO.File]::WriteAllText($lock5, '')
    try { $vL = Invoke-PipelineCommit -Repo $tr5 -Paths @('lane/out') -Message 'lane-locked' -Name 'probe' } finally { Remove-Item -LiteralPath $lock5 -Force -ErrorAction SilentlyContinue }
    $aHead = ([string](& git -C $tr5 rev-parse 'HEAD:lane/out/a.json')).Trim()
    $aDisk = ([string](& git -C $tr5 hash-object -- lane/out/a.json)).Trim()
    T 'MUST FIRE  a resync that cannot take the index lock is named in the verdict, and the commit still lands and classifies committed' `
      (($vL -match '^probe: committed 1 file\(s\); index resync FAILED') -and ((Get-PipelineCommitOutcome -Verdict $vL) -eq 'committed') -and ($aHead -eq $aDisk)) ($vL + ' | head=' + $aHead + ' disk=' + $aDisk)
  } catch {
    T 'the index-resync end-to-end block ran to its end without throwing' $false $_.Exception.Message
  } finally {
    Remove-Item -LiteralPath $tr5 -Recurse -Force -ErrorAction SilentlyContinue
  }

  # The literal count: every T line in this block, with the two loops counted at their widths (3 lane kinds x 2, and 4
  # outcomes). Moving it is part of adding or removing a case.
  $pcExpectedCases = 93
  if ($ran -ne $pcExpectedCases) { Write-Output ("FAIL  the suite ran " + $ran + " case(s) against its literal count of " + $pcExpectedCases); $fail++ }
  if ($fail -gt 0) { Write-Output ("SELF-TEST FAIL: {0} case(s) of {1} run" -f $fail, $ran); exit 1 }
  Write-Output ('SELF-TEST PASS: ' + $ran + ' of ' + $pcExpectedCases + ' cases: the source-path refusal in eleven shapes, every real path list proved data-only and non-empty, no path owned twice, the committer refusing before it touches git, a lane''s exit code earned from its verdict (a refused commit exits 1, a landed one whose push failed exits 0), a deletion present at start held out of the commit, a -Built journal entry that vouches its blob to the mover and is never committed, and a refused run''s own deletion recorded as a tombstone that the next run commits, and a landed commit resyncing the shared index for exactly its own paths, deletions and renames included, never another session''s staged entry')
  exit 0
}
