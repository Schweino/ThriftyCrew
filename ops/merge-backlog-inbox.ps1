<#
  merge-backlog-inbox.ps1 - one writer, one allocator, nothing lost.

  THE FAILURE THIS EXISTS FOR, and it happened on 2026-09-08. Four course agents
  ran in parallel. Because `BACKLOG-course-findings.md` is a shared file with a
  shared id counter and no lock, every agent was told NOT to write it and to
  report its findings instead, with the orchestrator merging afterwards.

  **Nine findings from three lanes were still sitting in agent reports hours
  later.** "Report it and I will merge" is not a mechanism; it is an intention,
  and an intention has no exit code. The one lane that DID write anything got its
  items in only because it invented a safe convention unprompted: append with
  explicitly unallocated ids in a single atomic write.

  THE FIX IS BRAD'S AND IT IS BETTER THAN WHAT I DID. Each agent writes its OWN
  file under `design\backlog-inbox\`. No two writers touch one file, so there is
  no contention to design around and nothing depends on anyone remembering. When
  the parallel run ends, this merges every inbox file into the backlog in one
  pass, as ONE writer, allocating ids sequentially because only one process is
  doing it.

  WHY A MERGE PASS IS BETTER THAN AGENTS WRITING DIRECTLY, beyond the locking.
  It is a review point. Four lanes on one estate produce near-duplicate findings,
  and the merge is where a human sees them side by side before they become two
  items that drift apart.

  AN INBOX FILE IS A FINDING, NOT AN ITEM. It needs no id and must not invent
  one. Format, one per finding, `##` separated:

      ## <title, one line>
      `<STATE>` `<queue tag>`
      <body, any markdown>

  The state must be one from the closed vocabulary `audit-backlog-status.ps1`
  enforces, and this refuses the merge rather than writing a heading that gate
  would fail - the whole point is that the backlog stays green.

  ONE MALFORMED FILE IS QUARANTINED; IT NO LONGER REFUSES THE BATCH.
  `[CHANGED 2026-09-12. The all-or-nothing rule above was deliberate, so here is why it
  is going, argued from what it was actually buying.]`
  It was chosen for two reasons: the backlog must stay GREEN for audit-backlog-status.ps1,
  and an id allocator with several writers loses findings. QUARANTINE KEEPS BOTH. The bad
  file's findings are never appended, so no heading that gate would fail is ever written;
  and this is still the ONE writer and the ONE allocator, over a smaller accepted set, so
  no id is reused and none is lost - the quarantined lane's findings are allocated on the
  retry run instead. What the batch refusal bought beyond those two was nothing. What it
  COST was measured: three times on 2026-09-11 and 12 a lane ended its file with a closing
  section like `## Nothing else` and no state line under it, and each refusal blocked THREE
  innocent lanes until a human fixed the one file. A gate that reddens three lanes for a
  fourth lane's typo teaches people to ignore red, or to hand-edit somebody else's drop
  file under time pressure, which ops-and-gates.md warns about in as many words.
  So the bad file is MOVED to `<inbox>\quarantine\` with its bytes intact and a
  `.reason.txt` beside it, it is NAMED in the output, the rest of the batch merges, and the
  run EXITS NON-ZERO so the failure is loud and attributable. Quarantine is per FILE and
  never per finding: dropping one `##` block out of a file a lane meant to file whole would
  be the silent loss this tool exists to prevent.

  VALIDATION IS A STEP WITH AN EXIT CODE, NOT A SENTENCE:

      -ValidateFile <path>      one file, in ISOLATION, before it joins the drop box

  It copies that ONE file into a fresh per-run temp inbox and runs this same code path with
  -DryRun, which reads the real backlog and writes nothing. It never reads the real inbox,
  though, because siblings are
  writing there and their problems are not this lane's to report. Exit 0 = it would merge,
  2 = it would be quarantined, 3 = could not evaluate. This NAMES the existing -InboxDir
  plus -DryRun mechanism rather than adding a second one: one lane did exactly this by hand
  on 2026-09-12 and its files merged first time, and the lanes that broke the batch are the
  ones that skipped the same instruction when it was only prose in a spawn prompt. A file
  whose folder is named `updates` is validated as an UPDATE file (below), because that is
  how the merge will read it where it sits.

  PROGRESS ON AN EXISTING ITEM IS AN UPDATE, AND IT COMES THROUGH HERE TOO (2026-09-23, W3.1 of
  design\PLAN-push-derived-conflicts-2026-09-23.md, Brad's ruling D2). Lanes used to record progress by
  editing BACKLOG-course-findings.md directly, and that file overlapped in 12 of 19 recent rebase
  conflicts (the plan's section 2.3, A3). Brad's 2026-09-08 ruling for new findings, one file per writer and one merge, now covers
  updates as well. A lane writes its own file under a NEW subdirectory,
  `design\backlog-inbox\updates\<lane>-<YYYY-MM-DD>.md`:

      ## UPDATE I165
      `DONE` `queue-7`
      <body paragraphs, appended to that item>

  The heading is exactly `## UPDATE <id>`, the id letters then digits. The next non-empty line is the
  item's new tag spans, and its first span is the state. THE SUBDIRECTORY IS THE COMPATIBILITY: the merge
  before this change listed `$InboxDir\*.md` without -Recurse, so an older copy in some other checkout never
  sees an UPDATE file and cannot mint `## UPDATE I165` as a NEW item with a bogus id. For the same reason
  an UPDATE heading in an inbox-ROOT file is quarantined here rather than minted.

  WHAT AN UPDATE REPLACES, and nothing else. A heading is
  `### <id> - <title> <state span> [<tag spans>] [<prose>]`, a title can carry backticked code of its
  own (E7 `.worktreeinclude`), and some headings carry prose after their tags (I5). So an UPDATE replaces
  exactly the ONE backticked span that is a state in audit-backlog-status.ps1's closed vocabulary (tried
  longest first, as that file does), plus the backticked spans contiguous after it. The title before it
  and the prose after the last replaced span stay byte-identical. The body goes at the end of that item's
  section - before the next `#`, `##` or `###` heading outside a fenced block - after a blank line, and is
  followed by `**Merged from design\backlog-inbox\updates\<file> on <date>.**`. Updates apply in ORDINAL
  file-name order, then in-file order. A body line that is itself a heading is refused: appended to an
  item it would start a new section, or a new item.

  A CONFLICTING STATUS IS NEVER SETTLED BY ORDER. File names start with the lane, so "the later file wins"
  would mean alphabetical by lane, not by time. Two files giving one id DIFFERENT tag sets are BOTH
  quarantined into `updates\quarantine\`, each with a .reason.txt naming the other, nothing is merged for
  that id, and the run exits 2. Identical tag sets both merge, and the output says
  `I165 updated by 2 files: <a>, <b>`. One file giving one id two tag sets is quarantined the same way.

  THE GATE JUDGES EVERY UPDATE BEFORE IT LANDS. A file's updates are applied to a TEMP copy and
  `audit-backlog-status.ps1 -Backlog <that copy>` runs over it: the push gate's own rules, not a copy of
  them. A file whose update fails there (a missing reversibility or first-rung tag on a heading that is not
  closed, two state spans, an unknown state) is quarantined whole with the gate's finding in its
  .reason.txt, and so is an UPDATE naming an id the backlog does not have. The gate runs first over the
  backlog as it stands: if that is ALREADY red, no update can be judged by it, so every update file stays
  where it is, none of it lands, and the run exits 3. A could-not-evaluate is never a quarantine. Each file
  is judged ALONE, which is what lets a finding name the one file that caused it; the combined text needs no
  second run, because every rule the gate applies is per heading or per item and a difference between two
  files on one item never gets this far. NEW findings are still judged by this file's own parser, exactly as
  before: the gate run is for updates.

  ONE WRITER, AND NOW A LOCK THAT SAYS SO. The allocator was safe because only one merge ever ran, which
  was a habit. W3.4 adds a scheduled run beside the hand runs, so a real merge holds lib\ledger-lock.ps1's
  lock on the backlog's path across its inbox read, its id allocation, its write and its consume. A second
  merge waits for it and then finds an empty inbox. It is the only lock this takes, innermost in the
  declared order (.claude\rules\ops-and-gates.md), so nothing nests under it. A merge that cannot take it
  within -LockWaitSec (120 s, the library's own default, the first plausible value and not swept) writes,
  consumes and quarantines nothing and exits 3. -DryRun, and so -ValidateFile, takes NO lock: it writes
  nothing, and a push validating one file must never wait behind a merge. What the wait does when the
  producer stops: nothing - it runs only when a merge runs.

  A backlog changed by an UPDATE is rewritten whole through lib\atomic-write.ps1 (Write-TcAtomicFile, its
  BOM kept as it was, no newline added), because its readers - git, the gate, a person - take no lock, and
  only after its bytes are checked unchanged since the read. A run that only appends new findings still
  appends, byte for byte as before. THE WRITE COMES BEFORE THE CONSUME, so a crash between them loses
  nothing and re-applies on the next run instead: replacing a heading's tags is idempotent, appending a
  body is NOT, so that body (like a re-filed finding) would appear twice - a readable duplicate in one diff,
  never a lost update.

  ONE ALLOCATOR, NOT ONE LOCK PER CHECKOUT (2026-09-23, W3.4a of the same plan, Brad's ruling D17). The lock above is
  named from the FULL PATH of the backlog it guards (lib\ledger-lock.ps1 Get-TcLedgerLockName), so a merge in the
  scheduled task's worktree and a hand merge in any other checkout take DIFFERENT mutexes. Each reads its own copy at
  one base, each mints the same next id, and the second to land meets a rebase conflict on the backlog: the collision
  Row 3 exists to remove. No lock can fix that, because the two writers never share a file; only one writer can. So
  the scheduled merge (the TC Backlog Merge task, ops\run-backlog-merge.ps1, W3.4) is the one allocator, and a real merge of a
  checkout's backlog anywhere else is REFUSED, exit 1, writing and consuming nothing, unless it passes
  `-AllowHandMerge "<reason>"`. The reason is printed in its trailer, so a hand merge is visible in the commit that
  carries it. A session that needs an id now runs the task on demand (`Start-ScheduledTask -TaskName 'TC Backlog
  Merge'`), which uses the same worktree and the same push-main route.
    HOW A CHECKOUT KNOWS IT IS THE ALLOCATOR. The task writes a marker, `tc-backlog-allocator`, into its own linked
    worktree's GIT ADMIN directory (`<common .git>\worktrees\<name>\`), naming that checkout's root. A merge reads it
    by following the checkout's `.git` pointer and `commondir` file, never by running git, because a hook's inherited
    GIT_DIR would answer for another tree (.claude\rules\ops-and-gates.md). The marker is outside the working tree,
    so it can never dirty the tree push-main is about to judge.
    WHAT IS JUDGED. Only a backlog that IS a checkout's tracked file - `<root>\design\BACKLOG-course-findings.md` with
    a `.git` entry at `<root>` - because that is the file two checkouts can both copy. A backlog anywhere else (every
    fixture under %TEMP%) has no second copy to collide with and merges as before. -DryRun, and so -ValidateFile,
    writes nothing and is never refused: push-main validates every added inbox file in its pre-flight (W3.2).
    IT DEGRADES TO THE DAY BEFORE (.claude\rules\ops-and-gates.md, "EVERY LOCK PATH DEGRADES TO THE DAY BEFORE"). The
    refusal arms only while an allocator is LIVE on this box: some `<common .git>\worktrees\*\` holds a marker whose
    checkout still exists. With none - the task not yet installed, or its worktree deleted - a hand merge proceeds
    exactly as it did before D17, prints a WARN that says so, and records `hand-merge: no scheduled allocator was live
    on this box` in its trailer. Without that, landing this change before the task's first run would have stopped
    every merge on the box.

  THE COMMIT TRAILER. A merge that changed the backlog prints
  `Backlog-Merged-From: <file>[, <file>...]`, each entry a path below design\backlog-inbox\ in forward
  slashes, the way git names it (`lane-a-2026-09-23.md`, `updates/lane-b-2026-09-23.md`). Whoever commits
  the merge puts that line in the commit, so a later check tells a merge from a hand edit by the trailer
  rather than by a file deletion anyone could fake. A merge that did not run as the allocator ends the same line with
  `; hand-merge: <reason>`, the reason whitespace-collapsed onto the one line.

  Exit 0 = everything merged, or nothing to merge. Exit 1 = REFUSED: a real merge of a checkout's backlog outside the
  allocator's worktree while an allocator is live, with no -AllowHandMerge or a blank reason; nothing was read,
  written or consumed. Exit 2 = at least one inbox file was malformed or
  conflicting and QUARANTINED; every other file merged. Exit 3 = could not evaluate: no backlog, the lock
  not taken, the backlog already failing its gate while updates wait, a checkout whose `.git` pointer cannot be read,
  or a read, write or move that failed.
  Read the verdict LINE, not the number alone.

  Params: -InboxDir, -Backlog, -DryRun (print the plan, write nothing),
          -ValidateFile <path> (one file, isolated), -Today <yyyy-MM-dd> (the date written into merged-from
          lines, today when omitted; a seam for the fixtures), -LockWaitSec <n>,
          -AllowHandMerge "<reason>" (a deliberate merge outside the allocator's worktree), -SelfTest
#>
# Declared inputs of its -SelfTest (2026-09-23, lib\gate-input-key.ps1). Every backlog and drop box the suite judges is
# written into a per-run temp directory; beyond those it runs this file, the gate it validates updates with, the
# libraries both load, and one FROZEN blob read by id from git's object store, which cannot change under its id.
# gate-inputs: ops\merge-backlog-inbox.ps1, ops\audit-backlog-status.ps1, lib\ledger-lock.ps1, lib\atomic-write.ps1, lib\mutex-hold.ps1
[CmdletBinding()]
param(
  [string]$InboxDir = '',
  [string]$Backlog = '',
  [string]$ValidateFile = '',
  [string]$Today = '',
  [int]$LockWaitSec = 120,
  # A deliberate merge outside the allocator's worktree (D17). Its PRESENCE is read with ContainsKey, so a blank
  # reason is refused rather than read as "not passed".
  [string]$AllowHandMerge = '',
  [switch]$DryRun,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $root
. (Join-Path $repo 'lib\ledger-lock.ps1')     # Enter-TcLedgerLock: one merge at a time on one backlog
. (Join-Path $repo 'lib\atomic-write.ps1')    # Write-TcAtomicFile: an updated backlog is replaced whole, never half
if (-not $InboxDir) { $InboxDir = Join-Path $repo 'design\backlog-inbox' }
if (-not $Backlog) { $Backlog = Join-Path $repo 'design\BACKLOG-course-findings.md' }
if (-not $Today) { $Today = (Get-Date).ToString('yyyy-MM-dd') }
# The push gate's own rules, run over a temp copy before any UPDATE lands.
$AUDIT = Join-Path $root 'audit-backlog-status.ps1'

# The closed vocabulary, copied from the legend `audit-backlog-status.ps1` enforces.
# A state outside it turns that gate red, so this refuses rather than writes.
$STATES = @('DONE', 'PARKED', 'NEEDS A RULING', 'PARTLY DONE', 'OPEN')
# The first-rung types audit-backlog-status.ps1 accepts, kept here so this merge refuses an invented
# one rather than writing a heading that reddens the next push. `[ADDED 2026-09-12 after eight did.]`
$RUNG_TYPES = @('READ', 'MEASURE', 'DOC', 'BUILD', 'RULING', 'BLOCKED')

# An UPDATE heading, as it reads after the `## ` the block split removes (W3.1). Case-sensitive on purpose: a finding
# titled "update the ..." is a finding, and `UPDATE I165` is the one spelling that names an existing item.
$UPDATE_HEAD_RE = '^UPDATE[ \t]+([A-Z]+[0-9]+)[ \t]*$'
# The same shape at the START of a root-inbox title, which the merge would otherwise mint as a new item.
$UPDATE_TITLE_RE = '^UPDATE[ \t]+[A-Z]+[0-9]+\b'

# ONE ALLOCATOR (W3.4a, D17): the marker the scheduled task writes into its own worktree's git admin directory, and
# the task it names. ops\run-backlog-merge.ps1's self-test runs THIS file against a marker that script wrote, so the two
# copies of the name cannot drift apart unseen.
$ALLOCATOR_MARKER = 'tc-backlog-allocator'
$ALLOCATOR_TASK = 'TC Backlog Merge'
# What a merge that proceeded without an allocator live records as its hand-merge reason.
$NO_ALLOCATOR_REASON = 'no scheduled allocator was live on this box'

function Resolve-TcGitPointer {
  <# A checkout's git directories, read off its `.git` entry and never from git (a hook's GIT_DIR would answer for
     another tree). Returns Kind ('dir', 'file' or 'none'), GitDir, CommonDir and Why. A `.git` FILE is a linked
     worktree: its first `gitdir:` line names the admin directory, and that directory's `commondir` file names the
     shared .git, relative to it. Relative paths are resolved the way git resolves them. Kind 'file' with an empty
     GitDir is a pointer that could not be read, which the caller treats as could-not-evaluate. #>
  param([string]$Root)
  $r = [pscustomobject]@{ Kind = 'none'; GitDir = ''; CommonDir = ''; Why = '' }
  $dot = Join-Path $Root '.git'
  if (Test-Path -LiteralPath $dot -PathType Container) {
    $full = [IO.Path]::GetFullPath($dot).TrimEnd('\')
    $r.Kind = 'dir'; $r.GitDir = $full; $r.CommonDir = $full
    return $r
  }
  if (-not (Test-Path -LiteralPath $dot -PathType Leaf)) { return $r }
  $r.Kind = 'file'
  try {
    $first = @([IO.File]::ReadAllLines($dot) | Where-Object { $_ -match '^\s*gitdir:\s*\S' })
    if ($first.Count -eq 0) { $r.Why = ($dot + ' has no gitdir: line'); return $r }
    $p = ([regex]::Match([string]$first[0], '^\s*gitdir:\s*(.+?)\s*$')).Groups[1].Value.Replace('/', '\')
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $Root $p }
    $gd = [IO.Path]::GetFullPath($p).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $gd -PathType Container)) { $r.Why = ($dot + ' points at ' + $gd + ', which does not exist'); return $r }
    $cd = $gd
    $cdFile = Join-Path $gd 'commondir'
    if (Test-Path -LiteralPath $cdFile -PathType Leaf) {
      $c = ([IO.File]::ReadAllText($cdFile)).Trim().Replace('/', '\')
      if ($c) {
        if (-not [IO.Path]::IsPathRooted($c)) { $c = Join-Path $gd $c }
        $cd = [IO.Path]::GetFullPath($c).TrimEnd('\')
      }
    }
    $r.GitDir = $gd; $r.CommonDir = $cd
  } catch {
    $r.Why = ('the pointer ' + $dot + ' could not be read: ' + $_.Exception.Message)
  }
  return $r
}

function Read-TcAllocatorMarker {
  <# One marker file, parsed: Checkout (full path) and Task, or $null when it is absent or unreadable. #>
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($null -eq $j -or -not $j.PSObject.Properties['checkout'] -or -not [string]$j.checkout) { return $null }
    return [pscustomobject]@{ Checkout = ([IO.Path]::GetFullPath([string]$j.checkout)).TrimEnd('\'); Task = [string]$j.task; Path = $Path }
  } catch { return $null }
}

function Get-TcBacklogAllocator {
  <# Is the merge of $BacklogPath the allocator's? Returns IsCopy (the backlog is a checkout's tracked
     design\BACKLOG-course-findings.md), Root, Blind (the checkout's pointer could not be read), IsAllocator (this
     checkout's own admin directory holds a marker naming this root), Live (the checkouts every live marker in the
     shared .git names) and Why. A marker is LIVE when its checkout still has a `.git` entry. #>
  param([string]$BacklogPath)
  $r = [pscustomobject]@{ IsCopy = $false; Root = ''; Blind = $false; IsAllocator = $false; Live = @(); Why = '' }
  $full = [IO.Path]::GetFullPath($BacklogPath)
  $dir = Split-Path -Parent $full
  if (-not [string]::Equals([IO.Path]::GetFileName($full), 'BACKLOG-course-findings.md', [StringComparison]::OrdinalIgnoreCase)) { return $r }
  if (-not [string]::Equals([IO.Path]::GetFileName($dir), 'design', [StringComparison]::OrdinalIgnoreCase)) { return $r }
  $root = (Split-Path -Parent $dir).TrimEnd('\')
  $ptr = Resolve-TcGitPointer -Root $root
  if ($ptr.Kind -eq 'none') { return $r }
  $r.IsCopy = $true; $r.Root = $root
  if (-not $ptr.GitDir) { $r.Blind = $true; $r.Why = $ptr.Why; return $r }
  $live = New-Object System.Collections.Generic.List[string]
  $wtRoot = Join-Path $ptr.CommonDir 'worktrees'
  if (Test-Path -LiteralPath $wtRoot -PathType Container) {
    foreach ($d in @(Get-ChildItem -LiteralPath $wtRoot -Directory -ErrorAction SilentlyContinue)) {
      $m = Read-TcAllocatorMarker -Path (Join-Path $d.FullName $ALLOCATOR_MARKER)
      if ($m -and (Test-Path -LiteralPath (Join-Path $m.Checkout '.git'))) { if (-not $live.Contains($m.Checkout)) { [void]$live.Add($m.Checkout) } }
    }
  }
  $r.Live = $live.ToArray()
  # A LINKED worktree only: the task never marks a main checkout, so a marker there names no allocator.
  if ($ptr.Kind -eq 'file') {
    $mine = Read-TcAllocatorMarker -Path (Join-Path $ptr.GitDir $ALLOCATOR_MARKER)
    if ($mine -and [string]::Equals($mine.Checkout, $root, [StringComparison]::OrdinalIgnoreCase)) { $r.IsAllocator = $true }
  }
  return $r
}

function Test-State([string]$s) {
  foreach ($v in $STATES) { if ($s -match ('^' + [regex]::Escape($v) + '\b')) { return $true } }
  return $false
}

function Format-TcFindingHeading([int]$Id, $Finding) {
  <# The item heading a finding becomes, written in ONE place: the merge appends it and the per-file gate below judges
     exactly these bytes, so the two can never disagree about what the push gate will read. #>
  $tag = if ($Finding.Tag) { " ``$($Finding.Tag)``" } else { '' }
  return ("### I$Id - $($Finding.Title) ``$($Finding.State)``$tag")
}

function Test-TcFindingFileGate {
  <# THE PUSH GATE'S OWN STATE RULE over one inbox file's new findings (2026-09-24, design\backlog-inbox\
     pd-backlog-2026-09-23.md). Test-State accepts any tag that BEGINS with a state word (`DONE-ish`, `DONE:`, `OPEN.`),
     and audit-backlog-status.ps1 accepts only the bare state, `STATE - detail` or `STATE <date>`. A copy of the gate's
     rule here would drift the way this file's header warns, so the file's headings are written, by
     Format-TcFindingHeading, into a synthetic backlog that holds nothing else, and the gate itself judges them. The
     synthetic backlog is independent of the real one, so a red real backlog never blinds a finding file. Returns
     Invoke-TcBacklogGate's Code (0, 2, or 3 for could-not-evaluate) and Lines. #>
  param([object[]]$Findings)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append("# Backlog`n")
  $k = 1
  foreach ($f in @($Findings)) {
    [void]$sb.Append("`n" + (Format-TcFindingHeading $k $f) + "`n`nbody`n")
    $k++
  }
  return (Invoke-TcBacklogGate -Text $sb.ToString())
}

function Get-NextId([string]$text) {
  # The allocator. Only ever called by THIS script, and only one of it runs, which
  # is the entire reason the ids are safe here and were not safe in four agents.
  $ids = [regex]::Matches($text, '(?m)^### I(\d+)\b') | ForEach-Object { [int]$_.Groups[1].Value }
  if (-not $ids -or @($ids).Count -eq 0) { return 1 }
  return (($ids | Measure-Object -Maximum).Maximum + 1)
}

# A STATE LINE, DEFINED ONCE. `[2026-09-09.]` This pattern lived in two places - the finding parser
# and Test-MislevelledFinding - and widening one to carry the reversibility and first-rung axes left
# the other refusing to recognise its own fixture's input. A rule implemented twice diverges the
# moment one copy moves, which this estate has a memory about. One constant, two readers.
$STATE_LINE_RE = '^\s*(`[^`]+`\s*)+$'

function Test-MislevelledFinding([string]$preamble) {
  <# A `#` heading is a mis-levelled FINDING only when a STATE LINE follows it. With prose
     under it, it is a document title - which is what every lane writes and what this
     check used to refuse. Three of three lanes tripped it on 2026-09-08; a rule broken by
     everyone who meets it is the defect. The state line is what makes a heading a finding,
     which is already how `##` is judged, so this just applies the same test one level up. #>
  $lines = $preamble -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^#\s+\S') {
      $rest = @($lines | Select-Object -Skip ($i + 1) | Where-Object { $_.Trim() })
      if ($rest.Count -gt 0 -and $rest[0] -match $STATE_LINE_RE) { return $true }
    }
  }
  return $false
}

function Read-Inbox([string]$path) {
  <# [(title, state, body)] from one inbox file. Throws on a malformed finding. #>
  $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  if ($null -eq $raw) { $raw = '' }
  $raw = $raw -replace ('^' + [string][char]0xFEFF), ''
  $out = @()
  # Split on a heading at column 0 that is exactly two hashes. Element 0 is everything
  # BEFORE the first heading, which is NOT a finding - on 2026-09-08 a README's level-one
  # title was reported as a finding with a missing state line, which is a true refusal of
  # a thing that was never a finding.
  #
  # It is dropped rather than parsed, but NOT silently: a `#` heading in the preamble is
  # very likely a finding somebody wrote with one hash instead of two, and dropping that
  # quietly would trade a loud wrong refusal for a silent LOSS. In a tool whose entire
  # purpose is that nothing gets lost, refusing loudly is the correct direction.
  $parts = [regex]::Split($raw, '(?m)^##\s+')
  $preamble = [string]$parts[0]
  $hasFindings = (@($parts).Count -gt 1)

  # A lane that measured nothing has a RESULT, not an absence, and must be able to say so.
  # 2026-09-08: a course lane was blocked by a 403, reached the index and none of the
  # material, and correctly filed nothing - and the merge refused every other lane's
  # findings because of it. "Landed with nothing" and "never landed" are different facts.
  #
  # The declaration is EXPLICIT and never inferred. Zero findings with no marker is still
  # a refusal, because a file empty by accident and a file empty on purpose are otherwise
  # identical, and this tool exists so nothing is lost silently.
  if (-not $hasFindings) {
    if ($raw -match '(?m)^\s*NOTHING TO FILE\b') {
      return @([pscustomobject]@{
        Title = ''; State = ''; Tag = ''; Body = ''
        From = [IO.Path]::GetFileName($path); Empty = $true
      })
    }
    # The MORE SPECIFIC diagnosis first. A `#` heading here is almost always a finding
    # written with one hash, and saying so sends the reader to the right fix; the generic
    # message would send them to add a marker they do not want.
    if (Test-MislevelledFinding $preamble) {
      throw "in $([IO.Path]::GetFileName($path)): a '#' heading has a state line under it, so it is a finding written with ONE hash. A finding is a '##' heading - use two."
    }
    throw "in $([IO.Path]::GetFileName($path)): no findings, and no 'NOTHING TO FILE' line. If this lane measured nothing, say so on a line of its own - an empty file and a lost one look identical otherwise. If this is documentation, name it README.md."
  }

  # A TITLE above the findings is fine and is what every lane writes. Only a `#` heading
  # with a STATE LINE under it is a finding somebody mis-levelled, and that is still
  # refused, because a silently dropped finding is the failure this whole tool exists for.
  if (Test-MislevelledFinding $preamble) {
    throw "in $([IO.Path]::GetFileName($path)): a '#' heading above the first finding has a state line under it, so it is a finding written with ONE hash. A finding is a '##' heading - use two. A plain title with prose under it is fine and needs no change."
  }
  $parts = @($parts | Select-Object -Skip 1) | Where-Object { $_.Trim() }
  foreach ($p in $parts) {
    $lines = $p -split "`r?`n"
    $title = $lines[0].Trim()
    if (-not $title) { continue }
    # AN UPDATE IN THE ROOT WOULD BE MINTED AS A NEW ITEM (W3.1, 2026-09-23). Every `##` block here gets the next id,
    # so `## UPDATE I165` filed at the root would become I<next> - UPDATE I165, a bogus item beside the real one.
    if ($title -cmatch $UPDATE_TITLE_RE) {
      throw "in $([IO.Path]::GetFileName($path)): '## $title' is an UPDATE to an existing item, and it sits in the inbox ROOT, where every '##' heading is minted as a NEW item with a new id. Move this file into design\backlog-inbox\updates\, where the merge applies it to the item it names."
    }
    $stateLine = ($lines | Select-Object -Skip 1 | Where-Object { $_.Trim() } | Select-Object -First 1)
    # EVERY backticked tag on the line, not the first two. `[WIDENED 2026-09-09, measured.]` The old
    # pattern took a state and at most ONE tag, so an OPEN finding could not carry the reversibility
    # and first-rung type that audit-backlog-status REQUIRES of it - and the merge duly wrote
    # `### I101 - ... ``OPEN`` ``queue-reach``, which that gate failed on the next run. The header
    # above promises this script refuses rather than writing a heading the gate rejects; it checked
    # the state vocabulary and nothing else, so it kept the half of the promise it could parse.
    $tags = @([regex]::Matches([string]$stateLine, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value.Trim() })
    if (-not $tags.Count -or ([string]$stateLine) -notmatch $STATE_LINE_RE) {
      throw "in $([IO.Path]::GetFileName($path)): finding '$title' has no state line. Expected a line of the form ``OPEN`` ``queue-6``, and for an open state also ``2-WAY``/``1-WAY`` and ``RUNG1 <TYPE>``."
    }
    $state = $tags[0]
    $rest = @($tags | Select-Object -Skip 1)
    $tag = ($rest -join '` `')
    if (-not (Test-State $state)) {
      throw "in $([IO.Path]::GetFileName($path)): finding '$title' declares state '$state', which is not in the closed vocabulary ($($STATES -join ', ')). audit-backlog-status.ps1 would fail on it."
    }
    # AND THE AXES, for the same reason and from the same gate. An open item owes both; a closed one
    # owes neither. Refusing here is the whole point of a single writer: the alternative is a heading
    # that lands and turns run-gates red for whoever next touches the ledger.
    if (@('NEEDS A RULING', 'PARTLY DONE', 'OPEN') -contains $state) {
      $hasRev = @($rest | Where-Object { $_ -eq '2-WAY' -or $_ -eq '1-WAY' }).Count
      $hasRung = @($rest | Where-Object { $_ -match '^RUNG1\s+\S+$' }).Count
      if ($hasRev -ne 1 -or $hasRung -ne 1) {
        throw ("in $([IO.Path]::GetFileName($path)): finding '$title' is state '$state', so its state line owes exactly one of ``2-WAY``/``1-WAY`` (it has $hasRev) and exactly one ``RUNG1 <TYPE>`` (it has $hasRung). audit-backlog-status.ps1 fails the heading without them, which is what happened to I101 on 2026-09-09.")
      }
      # AND THE TYPE ITSELF IS A CLOSED VOCABULARY, which this check missed until 2026-09-12.
      # `RUNG1 <anything>` satisfied the count above, so eight findings landed carrying MEASUREMENT,
      # CENSUS and PROTOTYPE - all reasonable English, none of them a value the audit accepts. They
      # merged clean and turned run-gates red on the push instead, which is the late failure a single
      # writer exists to prevent: this merge is the last place that can refuse a heading cheaply.
      $rungRow = @($rest | Where-Object { $_ -match '^RUNG1\s+\S+$' })
      if ($rungRow.Count -eq 1) {
        $rtype = ($rungRow[0] -replace '^RUNG1\s+', '')
        if ($RUNG_TYPES -notcontains $rtype) {
          throw ("in $([IO.Path]::GetFileName($path)): finding '$title' declares ``RUNG1 $rtype``, which is not in the closed vocabulary ($($RUNG_TYPES -join ', ')). audit-backlog-status.ps1 would fail the heading. A census or a count is MEASURE; building a throwaway to learn from is BUILD.")
        }
      }
    }
    $bodyLines = @($lines | Select-Object -Skip 1) | Where-Object { $_ -ne $stateLine }
    $out += [pscustomobject]@{
      Title = $title; State = $state; Tag = $tag
      Body = (($bodyLines -join "`n").Trim())
      From = [IO.Path]::GetFileName($path)
    }
  }
  return $out
}

# ------------------------------------------------------------------------------------ UPDATE blocks (W3.1)

function Read-UpdateFile([string]$path) {
  <# [(Id, Tags, Key, Body, From, Order)] from one updates\ file, or one Empty record for a declared NOTHING TO FILE.
     Throws on a malformed block, so the whole file is quarantined: never one block out of a file a lane meant whole.
     What it does NOT decide is whether the update would pass: that is the gate's, over a temp copy, below. #>
  $name = [IO.Path]::GetFileName($path)
  $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
  if ($null -eq $raw) { $raw = '' }
  $raw = $raw -replace ('^' + [string][char]0xFEFF), ''
  $parts = [regex]::Split($raw, '(?m)^##[ \t]+')
  $preamble = [string]$parts[0]
  if (@($parts).Count -le 1) {
    if ($raw -match '(?m)^\s*NOTHING TO FILE\b') {
      return @([pscustomobject]@{ Id = ''; Tags = @(); Key = ''; Body = ''; From = $name; Order = 0; Empty = $true })
    }
    throw "in $name`: no '## UPDATE <id>' block, and no 'NOTHING TO FILE' line. An updates\ file carries one or more blocks of the form '## UPDATE I165', then a line of tag spans, then the body."
  }
  if (Test-MislevelledFinding $preamble) {
    throw "in $name`: a '#' heading above the first block has a tag line under it, so it is an UPDATE written with ONE hash. The heading is '## UPDATE <id>' - two hashes."
  }
  $out = @()
  $order = 0
  foreach ($p in @($parts | Select-Object -Skip 1)) {
    $lines = $p -split "`r?`n"
    $head = $lines[0].Trim()
    if ($head -cnotmatch $UPDATE_HEAD_RE) {
      throw "in $name`: '## $head' is not an UPDATE heading. Every '##' heading in updates\ is exactly '## UPDATE <id>', the id letters then digits (I165, E7). A NEW finding belongs in the inbox root, design\backlog-inbox\, where the merge gives it an id."
    }
    $id = $Matches[1]
    $rest = @($lines | Select-Object -Skip 1)
    $ti = -1
    for ($k = 0; $k -lt $rest.Count; $k++) { if ($rest[$k].Trim()) { $ti = $k; break } }
    $tagLine = if ($ti -ge 0) { [string]$rest[$ti] } else { '' }
    $tags = @([regex]::Matches($tagLine, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value.Trim() })
    if (-not $tags.Count -or $tagLine -notmatch $STATE_LINE_RE) {
      throw "in $name`: UPDATE $id has no tag line. The next non-empty line under the heading is the item's new tag spans, for example ``DONE`` ``queue-7``, and they REPLACE the state span and every span right after it, so restate the ones you mean to keep."
    }
    if (-not (Test-State $tags[0])) {
      throw "in $name`: UPDATE $id gives '$($tags[0])' as its first span, which is not a state in the closed vocabulary ($($STATES -join ', ')). The first span on the tag line is the state; audit-backlog-status.ps1 would fail the heading."
    }
    $bodyLines = if ($ti -ge 0) { @($rest | Select-Object -Skip ($ti + 1)) } else { @() }
    foreach ($bl in $bodyLines) {
      if ($bl -match '^#{1,3}[ \t]') {
        throw "in $name`: the body of UPDATE $id carries a heading line ('$($bl.Trim())'). Appended to the item, it would start a new section of the backlog, or a new item. Write it as bold text or a list instead."
      }
    }
    # Leading blank lines and trailing whitespace go; everything between is the lane's, byte for byte, in LF.
    $body = (($bodyLines -join "`n") -replace '^(\s*\n)+', '').TrimEnd()
    $order++
    $out += [pscustomobject]@{ Id = $id; Tags = $tags; Key = ($tags -join [string][char]31); Body = $body
      From = $name; Order = $order; Empty = $false }
  }
  return $out
}

function Get-TcHeadingTagRegion {
  <# Where an UPDATE writes inside ONE heading line: Start and End (exclusive) of the state span plus every backticked
     span contiguous after it, or a Problem. Pure. The state rule is audit-backlog-status.ps1's own: a span IS a state,
     or begins 'STATE - ' or 'STATE <date>', tried longest first, so PARTLY DONE is never read as DONE. #>
  param([string]$Line)
  $ms = @([regex]::Matches($Line, '`([^`]+)`'))
  $byLen = @($STATES | Sort-Object { - $_.Length })
  $stateIdx = @()
  for ($k = 0; $k -lt $ms.Count; $k++) {
    $tag = $ms[$k].Groups[1].Value
    foreach ($s in $byLen) {
      if ($tag -eq $s -or $tag -match ('^' + [regex]::Escape($s) + '(\s+-\s+|\s+\d{4}-)')) { $stateIdx += $k; break }
    }
  }
  if ($stateIdx.Count -ne 1) {
    return [pscustomobject]@{ Start = -1; End = -1; Problem = ("its heading carries {0} state spans, so which span an UPDATE replaces is ambiguous" -f $stateIdx.Count) }
  }
  $first = $stateIdx[0]
  $last = $first
  while ($last + 1 -lt $ms.Count) {
    $gapAt = $ms[$last].Index + $ms[$last].Length
    $gap = $Line.Substring($gapAt, $ms[$last + 1].Index - $gapAt)
    if ($gap -match '^[ \t]*$') { $last++ } else { break }
  }
  return [pscustomobject]@{ Start = $ms[$first].Index; End = ($ms[$last].Index + $ms[$last].Length); Problem = '' }
}

function Find-TcSectionEnd {
  <# The index where the item section that starts at $From ends: the start of the next `#`, `##` or `###` heading line
     outside a fenced block, or the end of the text. Pure. A `####` subheading belongs to the item. #>
  param([string]$Text, [int]$From)
  $pos = $From
  $inFence = $false
  while ($pos -lt $Text.Length) {
    $nl = $Text.IndexOf("`n", $pos)
    $lineEnd = if ($nl -lt 0) { $Text.Length } else { $nl }
    $line = $Text.Substring($pos, $lineEnd - $pos).TrimEnd("`r")
    if ($line -match '^[ \t]*(```|~~~)') { $inFence = -not $inFence }
    elseif ((-not $inFence) -and $line -match '^#{1,3}[ \t]') { return $pos }
    if ($nl -lt 0) { break }
    $pos = $nl + 1
  }
  return $Text.Length
}

function Set-TcItemUpdate {
  <# ONE UPDATE applied to the backlog TEXT. Pure. Returns Text (unchanged when it could not apply) and Problem. #>
  param([string]$Text, $Update, [string]$Date)
  # [^\r\n] keeps a CRLF file's CR out of the heading match, so it is never touched.
  $rx = '(?m)^###[ \t]+' + [regex]::Escape([string]$Update.Id) + '[ \t]+-[ \t][^\r\n]*'
  $hs = @([regex]::Matches($Text, $rx))
  if ($hs.Count -eq 0) {
    return [pscustomobject]@{ Text = $Text; Problem = ("names {0}, which is not an item heading in the backlog. An UPDATE only changes an item that exists; a new item is a finding in the inbox root." -f $Update.Id) }
  }
  if ($hs.Count -gt 1) {
    return [pscustomobject]@{ Text = $Text; Problem = ("names {0}, which has {1} item headings in the backlog, so which one to update is ambiguous." -f $Update.Id, $hs.Count) }
  }
  $h = $hs[0]
  $line = $h.Value
  $reg = Get-TcHeadingTagRegion -Line $line
  if ($reg.Problem) { return [pscustomobject]@{ Text = $Text; Problem = ("cannot update {0}: {1}." -f $Update.Id, $reg.Problem) } }
  $spans = (@($Update.Tags | ForEach-Object { '`' + $_ + '`' })) -join ' '
  $newLine = $line.Substring(0, $reg.Start) + $spans + $line.Substring($reg.End)
  $t2 = $Text.Substring(0, $h.Index) + $newLine + $Text.Substring($h.Index + $h.Length)
  $headEnd = $h.Index + $newLine.Length
  $nl = $t2.IndexOf("`n", $headEnd)
  $from = if ($nl -lt 0) { $t2.Length } else { $nl + 1 }
  $end = Find-TcSectionEnd -Text $t2 -From $from
  # Just after the section's last character that is not whitespace: the blank lines before the next heading stay after.
  $p = $end
  while ($p -gt $headEnd -and [char]::IsWhiteSpace($t2[$p - 1])) { $p-- }
  $merged = '**Merged from design\backlog-inbox\updates\' + $Update.From + ' on ' + $Date + '.**'
  $ins = "`n`n" + $(if ($Update.Body) { [string]$Update.Body + "`n`n" } else { '' }) + $merged
  return [pscustomobject]@{ Text = ($t2.Substring(0, $p) + $ins + $t2.Substring($p)); Problem = '' }
}

function Invoke-TcBacklogUpdates {
  <# Every UPDATE in $Updates applied to $Text in the order given. Pure. Returns Text and Problems, one per update that
     could not apply (that update is skipped, the rest still apply). #>
  param([string]$Text, [object[]]$Updates, [string]$Date)
  $t = $Text
  $probs = @()
  foreach ($u in @($Updates)) {
    $r = Set-TcItemUpdate -Text $t -Update $u -Date $Date
    if ($r.Problem) { $probs += [pscustomobject]@{ From = $u.From; Id = $u.Id; Why = $r.Problem } }
    else { $t = $r.Text }
  }
  return [pscustomobject]@{ Text = $t; Problems = $probs }
}

function Get-MbiScratch {
  <# The ONE per-run temp directory the gate copies go into, allocated on first use and removed by the finally around
     the merge. A fixed name here would have concurrent runs judging each other's copies. #>
  if (-not $script:MbiScratch) {
    $p = Join-Path $env:TEMP ('mbi-gate-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $p -ErrorAction Stop | Out-Null
    $script:MbiScratch = $p
  }
  return $script:MbiScratch
}

function Invoke-TcBacklogGate {
  <# audit-backlog-status.ps1's GATE MODE over $Text, written to a temp copy. Returns Code (0 passed, 2 a finding, 3
     could not evaluate) and Lines (what the gate printed, its marker left out). An exit 0 with no BACKLOG-STATUS-COMPLETE
     marker, a throw, or any other code reads as 3: a gate that could not finish never passes an update. It runs
     IN-PROCESS, the way this file's own fixtures re-enter it: the same rules, one powershell.exe fewer. #>
  param([string]$Text)
  $copy = Join-Path (Get-MbiScratch) ('gate-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.md')
  [IO.File]::WriteAllText($copy, $Text, (New-Object Text.UTF8Encoding($false)))
  $out = ''
  $code = 3
  try {
    $global:LASTEXITCODE = 3
    $out = & $AUDIT -Backlog $copy 2>&1 | Out-String
    $code = $LASTEXITCODE
  } catch {
    $out = 'the gate threw: ' + $_.Exception.Message
    $code = 3
  } finally {
    Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
  }
  if ($code -eq 0 -and $out -notmatch '(?m)^BACKLOG-STATUS-COMPLETE\b') { $code = 3 }
  if (@(0, 2) -notcontains $code) { $code = 3 }
  $lines = @(($out -split "`r?`n") | Where-Object { $_.Trim() -and $_ -notmatch '^BACKLOG-STATUS-COMPLETE\b' })
  return [pscustomobject]@{ Code = $code; Lines = $lines }
}

function Get-TcSha256Hex([byte[]]$Bytes) {
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '') } finally { $sha.Dispose() }
}

function Move-ToQuarantine {
  <# The bad files, AFTER the accepted ones have landed. They keep their bytes, because
     the lane's work is in them; they MOVE, so an empty inbox still means what it says and
     a re-run does not re-report them forever; and each lands beside a .reason.txt,
     because a reason printed to a console nobody kept is not a retry. A finding file goes to
     <inbox>\quarantine\, an UPDATE file to <inbox>\updates\quarantine\.
     Returns $true, or $false having said why. #>
  param($Bad)
  if (@($Bad).Count -eq 0) { return $true }
  try {
    foreach ($b in $Bad) {
      if (-not (Test-Path -LiteralPath $b.QDir)) { New-Item -ItemType Directory -Path $b.QDir -Force -ErrorAction Stop | Out-Null }
      $dest = Join-Path $b.QDir $b.Name
      Move-Item -LiteralPath $b.Path -Destination $dest -Force -ErrorAction Stop  # atomic-replace:allow the destination is a quarantine path nothing reads concurrently, and the source is a drop file its lane has finished with; losing this move to a reader is not a failure mode here
      # NOT $home: that is PowerShell's read-only automatic variable, and assigning it throws.
      $backTo = if ([string]$b.Rel -like 'updates/*') { 'design\backlog-inbox\updates\' } else { 'the inbox' }
      $note = "QUARANTINED $Today by merge-backlog-inbox.ps1`n`n" + $b.Reason +
              "`n`nThe file itself is UNCHANGED. Fix it, move it back into $backTo, and re-run the merge.`n" +
              "Check it first, in isolation:`n  ops\merge-backlog-inbox.ps1 -ValidateFile <path to the fixed file>`n"
      [IO.File]::WriteAllText(($dest + '.reason.txt'), ($note -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
    }
  } catch {
    Write-Output ("COULD NOT EVALUATE - the accepted lanes MERGED, but moving a bad file to quarantine failed: " + $_.Exception.Message)
    Write-Output "That bad file is still in the inbox and its contents have NOT landed. Move it out by hand before the next run."
    return $false
  }
  return $true
}

# ---- -ValidateFile: ONE inbox file, in ISOLATION, with an exit code. ----------------
# A NAME for -InboxDir plus -DryRun, not a second implementation: it copies the one file
# into a fresh per-run temp inbox and re-enters this same script. What that buys over
# doing it by hand, which is what the instruction used to ask for in prose: it cannot be
# pointed at the REAL inbox, so a sibling's malformed file is never reported as this
# lane's problem, and this lane's check never touches a sibling's bytes.
if ($ValidateFile) {
  if ($PSBoundParameters.ContainsKey('InboxDir')) {
    Write-Output "COULD NOT EVALUATE - -ValidateFile judges ONE file in its own temp inbox, so -InboxDir means nothing here. Drop one of the two."
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit 3
  }
  if (-not (Test-Path -LiteralPath $ValidateFile)) {
    Write-Output "COULD NOT EVALUATE - no file at $ValidateFile."
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit 3
  }
  $leaf = [IO.Path]::GetFileName($ValidateFile)
  if ($leaf -notlike '*.md') {
    Write-Output "COULD NOT EVALUATE - $leaf is not a .md file, so the merge would never read it and validating it would prove nothing."
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit 3
  }
  if ($leaf -eq 'README.md' -or $leaf -like '_*') {
    Write-Output "COULD NOT EVALUATE - the merge SKIPS README.md and _*.md, so validating a findings file under that name would report a clean pass over a file that is never read. Rename it."
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit 3
  }
  # A file in a folder named `updates` is read by the merge as UPDATE blocks, so it is validated as one: its copy goes
  # into the temp inbox's own updates\, which is the one place the merge applies updates from.
  $asUpdate = ([IO.Path]::GetFileName([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ValidateFile))) -eq 'updates')
  # Named per run under one directory removed in a finally: several sessions share one
  # %TEMP%, and a fixed name here would have lanes validating into each other.
  $valBox = Join-Path $env:TEMP ('mbi-val-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path $valBox -ErrorAction Stop | Out-Null
    $valDest = $valBox
    if ($asUpdate) {
      $valDest = Join-Path $valBox 'updates'
      New-Item -ItemType Directory -Path $valDest -ErrorAction Stop | Out-Null
    }
    Copy-Item -LiteralPath $ValidateFile -Destination (Join-Path $valDest $leaf) -ErrorAction Stop
    $valOut = & $PSCommandPath -InboxDir $valBox -Backlog $Backlog -DryRun 2>&1 | Out-String
    $valCode = $LASTEXITCODE
    foreach ($ln in ($valOut -split "`r?`n")) {
      if ($ln.Trim() -eq 'MERGE-BACKLOG-INBOX-COMPLETE') { continue }
      if (-not $ln.Trim()) { continue }
      Write-Output $ln
    }
    $kind = if ($asUpdate) { 'UPDATE file' } else { 'findings file' }
    if ($valCode -eq 0) {
      Write-Output ("VALIDATE OK - {0} ({1}) would merge. Nothing was written, and the real inbox was neither read nor touched." -f $leaf, $kind)
    } elseif ($valCode -eq 2) {
      Write-Output ("VALIDATE FAILED - {0} ({1}) would be QUARANTINED, not merged. Fix it before the merge runs; the reason is above." -f $leaf, $kind)
    } else {
      Write-Output ("VALIDATE COULD NOT EVALUATE - exit {0}. That is not a pass; the reason is above." -f $valCode)
    }
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit $valCode
  } finally {
    # RETRY THE REMOVAL. A single -ErrorAction SilentlyContinue delete left an empty temp
    # directory behind in 16 of about 90 validate calls on 2026-09-12: the child process
    # has only just exited and Windows can still hold a handle to the directory it copied
    # into. Three tries, then give up quietly - a leaked empty directory must never turn a
    # validation into a failure.
    for ($try = 0; $try -lt 3; $try++) {
      if (-not (Test-Path -LiteralPath $valBox)) { break }
      Remove-Item -LiteralPath $valBox -Recurse -Force -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $valBox) { Start-Sleep -Milliseconds 120 }
    }
  }
}

if ($SelfTest) {
  # FIXTURE RULE, learned twice on 2026-09-08: no case may depend on what an earlier case
  # left in the inbox. A case that needs a clean inbox clears it wholesale; a case that
  # needs a file writes that file; every removal by name is -ErrorAction SilentlyContinue.
  # Both times this was violated, the failure was reported against the CODE UNDER TEST
  # rather than the setup, and a suite that lies about which thing broke is worse than one
  # that fails.
  #
  # EVERY PATH IS BELOW ONE PER-RUN ROOT, removed in the finally (2026-09-23). Until then the rung cases wrote their
  # drop box to ops\inbox-rung beside this script, inside the checkout under test, and nothing removed the root if a
  # case threw. Refusals from the lock case go to a scratch event bus, never the live one.
  $tmp = Join-Path $env:TEMP ('mbi-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmp -ErrorAction Stop | Out-Null
  $inb = Join-Path $tmp 'inbox'
  New-Item -ItemType Directory -Path $inb -Force | Out-Null
  $bl = Join-Path $tmp 'backlog.md'
  $pass = 0; $ran = 0; $blind = 0; $fails = New-Object System.Collections.ArrayList
  function _C($label, $name, $ok, $detail) {
    $script:ran++
    if ($ok) { $script:pass++ } else { [void]$script:fails.Add("$label $name") }
    Write-Output ("  {0,-14} {1,-58} {2}" -f $label, $name, $(if ($ok) { 'ok' } else { "FAIL $detail" }))
  }
  $prevBus = $env:TC_EVENT_BUS
  $env:TC_EVENT_BUS = Join-Path $tmp 'bus.jsonl'
  try {
  Set-Content $bl "# Backlog`n`n### I40 - an old one ``DONE```n`nbody`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-a.md') "## first finding`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody one`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-b.md') "## second finding`n``PARTLY DONE`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody two`n" -Encoding UTF8

  # Byte length BEFORE the merge, so the line-ending assertion below can look at the
  # appended region alone. The seed above is written by Set-Content, which ends it with
  # [Environment]::NewLine, so asserting over the whole file would fail on the fixture's
  # own trailing CRLF and prove nothing about the writer under test.
  $seedLen = ([IO.File]::ReadAllBytes($bl)).Length

  $out = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $code = $LASTEXITCODE
  $after = Get-Content $bl -Raw -Encoding UTF8
  _C 'MUST FIRE' 'two findings from two lanes merge, exit 0' ($code -eq 0 -and $after -match 'I41' -and $after -match 'I42') $code
  _C 'MUST FIRE' 'ids are allocated sequentially from the existing maximum' ($after -match '### I41 - first finding' -and $after -match '### I42 - second finding') 'wrong ids'
  _C 'MUST FIRE' 'each item records which lane file it came from' ($after -match 'lane-a\.md' -and $after -match 'lane-b\.md') 'no provenance'
  _C 'MUST NOT FIRE' 'the inbox is emptied so a second run cannot double-file' (@(Get-ChildItem $inb -Filter *.md).Count -eq 0) 'inbox not cleared'

  # MUST FIRE - the founding bug, 2026-09-08. The first real merge appended 75 CRLF into a
  # 5,927-line LF file and all 22 cases here stayed green, because every one of them reads
  # the result with Get-Content -Raw, which cannot see a line ending. Git said it, not this
  # script - and git normalises on the way in, so the commit was clean and `git diff` showed
  # nothing. THE ASSERTION HAS TO BE ON BYTES or it is not testing the thing that broke.
  # Assign, THEN wrap - never @(expression) inline, per the estate's array-collapse rule.
  $allBytes = [IO.File]::ReadAllBytes($bl)
  $sliceRaw = $allBytes[$seedLen..($allBytes.Length - 1)]
  $addedBytes = @($sliceRaw)
  $crCount = @($addedBytes | Where-Object { $_ -eq 13 }).Count
  _C 'MUST FIRE' 'the appended block is LF: no CR byte anywhere in it' ($crCount -eq 0) "$crCount CR byte(s)"
  # CLEAN TWIN - the behaviour a line-ending change is most likely to break on its way past:
  # the block must still be separated from what was already there, so the first appended
  # byte is a newline and headings do not run onto the previous line.
  _C 'CLEAN TWIN' 'the appended block still starts on a fresh line' ($addedBytes.Count -gt 0 -and $addedBytes[0] -eq 10) "first byte $($addedBytes[0])"

  $out2 = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  _C 'MUST NOT FIRE' 'an empty inbox is exit 0 and writes nothing' ($LASTEXITCODE -eq 0 -and (Get-Content $bl -Raw -Encoding UTF8) -eq $after) $LASTEXITCODE

  # A bad file must reach the backlog with NOTHING, and must not take its siblings down
  # with it. `[CONTRACT CHANGED 2026-09-12.]` Two of these cases asserted the old
  # all-or-nothing refusal; what survives of it is the half that mattered, which is that
  # nothing the bad file says is ever appended.
  Set-Content (Join-Path $inb 'lane-c.md') "## good one`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-d.md') "## bad one`n``SHIPPED`` ``queue-6```n`nbody`n" -Encoding UTF8
  $before = Get-Content $bl -Raw -Encoding UTF8
  $out3 = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $c3 = $LASTEXITCODE
  $after3 = Get-Content $bl -Raw -Encoding UTF8
  $q = Join-Path $inb 'quarantine'
  _C 'MUST FIRE' 'an invented state refuses the merge with exit 2' ($c3 -eq 2 -and $out3 -match 'closed vocabulary') $c3
  _C 'MUST FIRE' 'and NOTHING the bad file said reaches the backlog' `
    (($after3 -notmatch 'SHIPPED') -and ($after3 -notmatch 'bad one') -and ($after3 -notmatch 'lane-d')) 'bad content was written'
  _C 'MUST FIRE' 'and the INNOCENT file merges and is consumed, not held hostage' `
    (($after3 -match 'good one') -and -not (Test-Path (Join-Path $inb 'lane-c.md'))) 'the good lane was blocked by its sibling'
  _C 'MUST FIRE' 'and the bad file keeps its bytes under inbox\quarantine, named in the output' `
    ((Test-Path (Join-Path $q 'lane-d.md')) -and ((Get-Content (Join-Path $q 'lane-d.md') -Raw -Encoding UTF8) -match 'SHIPPED') -and
     ($out3 -match 'QUARANTINED') -and ($out3 -match 'lane-d\.md') -and -not (Test-Path (Join-Path $inb 'lane-d.md'))) 'no retriable copy'
  _C 'MUST FIRE' 'and a .reason.txt beside it names the cause and the retry route' `
    ((Test-Path (Join-Path $q 'lane-d.md.reason.txt')) -and
     ((Get-Content (Join-Path $q 'lane-d.md.reason.txt') -Raw -Encoding UTF8) -match 'closed vocabulary') -and
     ((Get-Content (Join-Path $q 'lane-d.md.reason.txt') -Raw -Encoding UTF8) -match 'ValidateFile')) 'no reason on disk'
  _C 'MUST FIRE' 'and the VERDICT line states merged and quarantined counts' `
    ($out3 -match 'VERDICT: merged 1 finding\(s\) from 1 file\(s\), applied 0 update\(s\) from 0 file\(s\), quarantined 1 file\(s\). Exit 2.') 'no verdict line'
  Remove-Item $q -Recurse -Force -ErrorAction SilentlyContinue

  # MUST FIRE - AN INVENTED FIRST-RUNG TYPE, and this is a MEASURED escape rather than a hypothetical.
  # `[2026-09-12.]` The check above counted `RUNG1 <anything>`, so eight findings merged clean carrying
  # MEASUREMENT, CENSUS and PROTOTYPE. Every one is reasonable English and none is a value
  # audit-backlog-status.ps1 accepts, so they turned run-gates red on the push instead, which is the
  # late failure a single writer exists to prevent. The twin is the point: a LEGAL rung must still
  # merge, because a vocabulary check that refused everything would satisfy the must-fire by accident.
  $inbR = Join-Path $tmp 'inbox-rung'
  New-Item -ItemType Directory -Path $inbR -Force | Out-Null
  Set-Content (Join-Path $inbR 'lane-rung-bad.md')  "## a census is not a rung type`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 CENSUS```n`nbody`n" -Encoding UTF8
  Set-Content (Join-Path $inbR 'lane-rung-good.md') "## a legal rung lands`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  $outR = & $PSCommandPath -InboxDir $inbR -Backlog $bl 2>&1 | Out-String
  $cR = $LASTEXITCODE
  $afterR = Get-Content $bl -Raw -Encoding UTF8
  $qR = Join-Path $inbR 'quarantine'
  _C 'MUST FIRE' 'an invented RUNG1 type is quarantined and names the vocabulary' `
    ($cR -eq 2 -and $outR -match 'RUNG1 CENSUS' -and $outR -match 'closed vocabulary' -and (Test-Path (Join-Path $qR 'lane-rung-bad.md'))) "exit $cR :: $outR"
  _C 'MUST FIRE' 'and no heading carrying it reaches the backlog' `
    (($afterR -notmatch 'RUNG1 CENSUS') -and ($afterR -notmatch 'a census is not a rung type')) 'an unacceptable rung was written'
  _C 'CLEAN TWIN' 'a LEGAL rung type still merges beside it' `
    (($afterR -match 'a legal rung lands') -and -not (Test-Path (Join-Path $inbR 'lane-rung-good.md'))) 'the vocabulary check refused a legal value'
  Remove-Item $inbR -Recurse -Force -ErrorAction SilentlyContinue

  # MUST FIRE - THE MEASURED SHAPE, and the whole reason this changed. Three times on
  # 2026-09-11 and 12 a lane closed its file with a `## Nothing else` section carrying no
  # state line, and each refusal blocked THREE other lanes' findings until a human fixed
  # the one file. Four lanes, one typo: three must land.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-p.md') "## p finding`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody p`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-q.md') "## q finding`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody q`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-r.md') "## r finding`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody r`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-s.md') "## s finding`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody s`n`n## Nothing else`n" -Encoding UTF8
  $outT4 = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cT4 = $LASTEXITCODE
  $blT4 = Get-Content $bl -Raw -Encoding UTF8
  _C 'MUST FIRE' 'the 3x measured shape: one typo quarantines ONE file, three lanes land' `
    ($cT4 -eq 2 -and $blT4 -match 'body p' -and $blT4 -match 'body q' -and $blT4 -match 'body r' -and
     $blT4 -notmatch 'body s' -and (Test-Path (Join-Path $q 'lane-s.md'))) "exit $cT4 :: $outT4"
  # CLEAN TWIN: the allocator still runs ONCE over the accepted set, so the three that
  # landed got three consecutive ids and the quarantined lane burned none of them.
  $idsT4 = @([regex]::Matches($blT4, '(?m)^### I(\d+)\b') | ForEach-Object { [int]$_.Groups[1].Value })
  $maxT4 = ($idsT4 | Measure-Object -Maximum).Maximum
  $dupT4 = @($idsT4 | Group-Object | Where-Object { $_.Count -gt 1 })
  _C 'CLEAN TWIN' 'ids stay a single dense sequence: the quarantined lane burns none' `
    ($dupT4.Count -eq 0 -and $idsT4.Count -eq ($maxT4 - 39)) "max I$maxT4 over $($idsT4.Count) id(s), $($dupT4.Count) duplicate(s)"
  Remove-Item $q -Recurse -Force -ErrorAction SilentlyContinue

  # CLEAN TWIN: every file bad is still the old behaviour - nothing written - but it is
  # now reached by quarantining each of them rather than by refusing the batch.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-m.md') "## m`n``SHIPPED`` ``queue-6```n`nbody`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-n.md') "## n`n`nno state line at all`n" -Encoding UTF8
  $blPreAll = Get-Content $bl -Raw -Encoding UTF8
  $outAll = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cAll = $LASTEXITCODE
  _C 'CLEAN TWIN' 'every file bad: nothing written, both quarantined, exit 2' `
    ($cAll -eq 2 -and ((Get-Content $bl -Raw -Encoding UTF8) -eq $blPreAll) -and
     (Test-Path (Join-Path $q 'lane-m.md')) -and (Test-Path (Join-Path $q 'lane-n.md'))) "exit $cAll :: $outAll"
  Remove-Item $q -Recurse -Force -ErrorAction SilentlyContinue

  # CLEAN TWIN: the no-findings branch has its own consume step, and it must consume the
  # ACCEPTED files only. A lane that landed with nothing beside a lane that landed badly:
  # the empty one is consumed, the bad one is quarantined, and neither is deleted wrongly.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-nil.md') "NOTHING TO FILE`n`nnothing measured this run`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-rot.md') "## rotten`n``SHIPPED`` ``queue-6```n`nbody`n" -Encoding UTF8
  $blPreNil = Get-Content $bl -Raw -Encoding UTF8
  $outNil = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cNil = $LASTEXITCODE
  _C 'CLEAN TWIN' 'an empty landing beside a bad file: empty consumed, bad quarantined, nothing written' `
    ($cNil -eq 2 -and ((Get-Content $bl -Raw -Encoding UTF8) -eq $blPreNil) -and
     -not (Test-Path (Join-Path $inb 'lane-nil.md')) -and
     (Test-Path (Join-Path $q 'lane-rot.md')) -and
     ((Get-Content (Join-Path $q 'lane-rot.md') -Raw -Encoding UTF8) -match 'rotten')) "exit $cNil :: $outNil"
  Remove-Item $q -Recurse -Force -ErrorAction SilentlyContinue

  # ---------------- -ValidateFile: one file, in isolation, with an exit code ---------
  # The instruction to do this was PROSE in the spawn prompt, and the lanes that skipped
  # it are the ones that broke the batch. These cases make it a step.
  $vbox = Join-Path $tmp 'validate-box'
  New-Item -ItemType Directory -Path $vbox -Force | Out-Null
  $vgood = Join-Path $vbox 'lane-v.md'
  Set-Content $vgood "## a legal finding`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  $vsib = Join-Path $vbox 'lane-v-sibling.md'
  Set-Content $vsib "## a sibling's bad finding`n``SHIPPED`` ``queue-6```n`nbody`n" -Encoding UTF8
  $blV = Get-Content $bl -Raw -Encoding UTF8
  $outV = & $PSCommandPath -ValidateFile $vgood -Backlog $bl 2>&1 | Out-String
  $cV = $LASTEXITCODE
  _C 'MUST NOT FIRE' '-ValidateFile on a legal file is exit 0, writes nothing, consumes nothing' `
    ($cV -eq 0 -and $outV -match 'VALIDATE OK' -and (Test-Path $vgood) -and ((Get-Content $bl -Raw -Encoding UTF8) -eq $blV)) "exit $cV :: $outV"
  _C 'CLEAN TWIN' 'a sibling''s malformed file in the same directory does not fail this lane' `
    ($cV -eq 0 -and $outV -notmatch 'sibling' -and (Test-Path $vsib)) "exit $cV :: $outV"

  $outVb = & $PSCommandPath -ValidateFile $vsib -Backlog $bl 2>&1 | Out-String
  $cVb = $LASTEXITCODE
  _C 'MUST FIRE' '-ValidateFile on a malformed file is exit 2 and names the reason' `
    ($cVb -eq 2 -and $outVb -match 'VALIDATE FAILED' -and $outVb -match 'closed vocabulary') "exit $cVb :: $outVb"

  $outVc = & $PSCommandPath -ValidateFile $vgood -InboxDir $vbox -Backlog $bl 2>&1 | Out-String
  $cVc = $LASTEXITCODE
  _C 'MUST FIRE' '-ValidateFile together with -InboxDir is exit 3, never a quiet pass' `
    ($cVc -eq 3 -and $outVc -match 'COULD NOT EVALUATE') "exit $cVc :: $outVc"

  $outVd = & $PSCommandPath -ValidateFile (Join-Path $vbox 'no-such-lane.md') -Backlog $bl 2>&1 | Out-String
  $cVd = $LASTEXITCODE
  _C 'MUST FIRE' '-ValidateFile on a missing path is exit 3, not exit 0' `
    ($cVd -eq 3 -and $outVd -match 'COULD NOT EVALUATE') "exit $cVd :: $outVd"

  $vskip = Join-Path $vbox 'README.md'
  Set-Content $vskip "## a finding hiding in a skipped name`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  $outVe = & $PSCommandPath -ValidateFile $vskip -Backlog $bl 2>&1 | Out-String
  $cVe = $LASTEXITCODE
  _C 'MUST FIRE' '-ValidateFile on a skipped name is exit 3, because the merge never reads it' `
    ($cVe -eq 3 -and $outVe -match 'SKIPS README') "exit $cVe :: $outVe"

  Get-ChildItem $inb -Filter *.md | Remove-Item -Force -ErrorAction SilentlyContinue

  # A finding with no state line at all.
  Remove-Item (Join-Path $inb 'lane-d.md') -Force -ErrorAction SilentlyContinue   # tolerant BY RULE: no case may depend on what an earlier case left behind
  Set-Content (Join-Path $inb 'lane-e.md') "## no state here`n`njust a body`n" -Encoding UTF8
  $out4 = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  _C 'MUST FIRE' 'a finding with no state line refuses the merge' ($LASTEXITCODE -eq 2 -and $out4 -match 'no state line') $LASTEXITCODE

  # MUST NOT FIRE: a README in the drop box is documentation, not a finding. This is the
  # 2026-09-08 defect exactly: writing the README that explains the convention refused the
  # whole merge with exit 2, because every file in the directory was assumed to be findings.
  Remove-Item (Join-Path $inb 'lane-e.md') -Force -ErrorAction SilentlyContinue
  Set-Content (Join-Path $inb 'README.md') "# how this drop box works`n`nprose, no findings, no state lines`n" -Encoding UTF8
  $outR = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cR = $LASTEXITCODE
  _C 'MUST NOT FIRE' 'a README.md is skipped, not parsed as a finding' ($cR -eq 0) "$cR"
  _C 'MUST NOT FIRE' 'and the README is NOT consumed by the merge' ((Test-Path (Join-Path $inb 'README.md'))) 'README deleted'

  # MUST FIRE: the preamble above the first `##` is not a finding, but a `#` heading there
  # is very likely one written with the wrong number of hashes. Refuse loudly rather than
  # drop it, because a silent loss is worse than a wrong refusal in THIS tool.
  Set-Content (Join-Path $inb 'lane-f.md') "# a finding written with one hash`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  $outP = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cP = $LASTEXITCODE
  _C 'MUST FIRE' 'a one-hash heading WITH a state line under it refuses the merge' ($cP -eq 2 -and $outP -match 'ONE hash') "$cP"

  # MUST NOT FIRE: a plain document TITLE is not a mis-levelled finding. Three of three
  # lanes opened their file with one on 2026-09-08 and all three were refused; a rule
  # broken by everyone who meets it is the defect, not the users.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-t.md') "# Lane: something, 2026-09-08`n`nSome prose about the lane.`n`n## a real finding`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  $blT = Get-Content $bl -Raw -Encoding UTF8
  $outT = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cT = $LASTEXITCODE
  $blT2 = Get-Content $bl -Raw -Encoding UTF8
  _C 'MUST NOT FIRE' 'a plain document TITLE above the findings is accepted' ($cT -eq 0) "$cT"
  _C 'MUST NOT FIRE' 'and the title is not filed as a finding' ($blT2 -match 'a real finding' -and $blT2 -notmatch 'Lane: something') 'title was filed'

  # CLEAN TWIN: a title on a NOTHING TO FILE lane, which is the exact shape a blocked
  # course produced on 2026-09-08.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-u.md') "# Lane: blocked, 2026-09-08`n`nNOTHING TO FILE`n`nthe course refused every supplement`n" -Encoding UTF8
  $outU = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cU = $LASTEXITCODE
  _C 'CLEAN TWIN' 'a titled NOTHING TO FILE lane is accepted and consumed' ($cU -eq 0 -and -not (Test-Path (Join-Path $inb 'lane-u.md'))) "$cU"

  # CLEAN TWIN: ordinary prose above the first finding still merges, and is not itself
  # filed. This is the behaviour the refusal above was most likely to have broken.
  Remove-Item (Join-Path $inb 'lane-f.md') -Force -ErrorAction SilentlyContinue   # tolerant BY RULE: no case may depend on what an earlier case left behind
  Set-Content (Join-Path $inb 'lane-g.md') "a note from the lane, no heading`n`n## a real finding`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  $outG = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cG = $LASTEXITCODE
  $blAfter = Get-Content $bl -Raw -Encoding UTF8
  _C 'CLEAN TWIN' 'prose above the first finding merges, and the prose is not filed' ($cG -eq 0 -and $blAfter -match 'a real finding' -and $blAfter -notmatch 'a note from the lane') "$cG"

  Remove-Item (Join-Path $inb 'README.md') -Force -ErrorAction SilentlyContinue
  # MUST NOT FIRE: a lane that measured nothing can SAY so, and one lane reporting
  # nothing must not refuse every other lane's findings. This is the 2026-09-08 defect:
  # a course blocked by a 403 filed nothing, correctly, and the merge refused the batch.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-h.md') "# Lane: blocked`n`nNOTHING TO FILE`n`nthe course 403'd, so nothing was measured`n" -Encoding UTF8
  Set-Content (Join-Path $inb 'lane-i.md') "## a real finding beside it`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  $blPre = Get-Content $bl -Raw -Encoding UTF8
  $outN = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cN = $LASTEXITCODE
  $blPost = Get-Content $bl -Raw -Encoding UTF8
  _C 'MUST NOT FIRE' 'a declared NOTHING TO FILE lane does not refuse the batch' ($cN -eq 0) "$cN"
  _C 'MUST FIRE' 'and the empty landing is REPORTED by name, not silently dropped' ($outN -match 'NOTHING TO FILE declared by lane-h') 'not reported'
  _C 'MUST NOT FIRE' 'and it is NOT filed as a backlog item' ($blPost -notmatch 'Lane: blocked' -and $blPost -match 'a real finding beside it') 'empty landing was filed'

  # MUST FIRE: zero findings with NO marker is still a refusal. A file empty by accident
  # and a file empty on purpose are otherwise identical.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-j.md') "some prose, no heading, no findings and no marker`n" -Encoding UTF8
  $outS = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cS = $LASTEXITCODE
  _C 'MUST FIRE' 'zero findings with NO marker is still refused' ($cS -eq 2 -and $outS -match 'NOTHING TO FILE') "$cS"

  # CLEAN TWIN: a lane declaring nothing, alone in the inbox, is consumed rather than
  # left to be re-reported on every future run.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-k.md') "NOTHING TO FILE`n`nnothing measured this run`n" -Encoding UTF8
  $outK = & $PSCommandPath -InboxDir $inb -Backlog $bl 2>&1 | Out-String
  $cK = $LASTEXITCODE
  _C 'CLEAN TWIN' 'a lone empty landing is consumed, not re-reported forever' ($cK -eq 0 -and -not (Test-Path (Join-Path $inb 'lane-k.md'))) "$cK"

  # CLEAN TWIN: -DryRun prints the plan and changes nothing.
  # THIS CASE OWNS ITS FIXTURE. It used to assert on `lane-c.md` surviving, where lane-c
  # had been created eight cases earlier for an unrelated purpose. Inserting cases between
  # them turned it red with the message "dry run wrote", which was a claim about the code
  # under test and was FALSE - the file was simply gone. A fixture that lies about which
  # thing failed is worse than one that fails, so it now writes what it asserts on.
  Get-ChildItem $inb -Filter *.md | Remove-Item -Force
  Set-Content (Join-Path $inb 'lane-dry.md') "## a finding for the dry run`n``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 MEASURE```n`nbody`n" -Encoding UTF8
  $before2 = Get-Content $bl -Raw -Encoding UTF8
  $out5 = & $PSCommandPath -InboxDir $inb -Backlog $bl -DryRun 2>&1 | Out-String
  $c5 = $LASTEXITCODE
  _C 'CLEAN TWIN' '-DryRun plans without writing or emptying the inbox' `
    ($c5 -eq 0 -and $out5 -match 'a finding for the dry run' -and (Get-Content $bl -Raw -Encoding UTF8) -eq $before2 -and (Test-Path (Join-Path $inb 'lane-dry.md'))) "dry run wrote, or planned nothing (exit $c5)"

  # ======================= UPDATE blocks (2026-09-23, W3.1 of design\PLAN-push-derived-conflicts-2026-09-23.md) ==========
  # Every case gets its OWN backlog and drop box (_NewBox), seeded LF with no BOM so "every other byte is identical" is
  # asserted on the exact text the case wrote. The UPDATE heading is built by concatenation, so no line of this source
  # is itself a heading. -Today pins the date the merged-from line carries.
  $uh = '## ' + 'UPDATE'
  $DAY = '2026-09-23'
  $u8 = New-Object Text.UTF8Encoding($false)
  $hdI2 = '### I2 - Stray artifacts at the repo root `OPEN` `queue-6` `2-WAY` `RUNG1 BUILD`'
  $hdE7 = '### E7 - `.worktreeinclude` `OPEN` `queue-4` `2-WAY` `RUNG1 READ`'
  $hdI5 = '### I5 - Coursera lapsed on `building-with-the-claude-api` `PARKED - KNOWLEDGE BANKED` - knowledge banked, only the record is missing'
  $seedU = "# Backlog`n`n## Section one`n`n$hdI2`n`nI2 body line.`n`n$hdE7`n`nE7 body.`n`n$hdI5`n`nI5 body.`n`n## Section two`n`n### I40 - an old one ``DONE```n`nI40 body.`n"
  function _NewBox([string]$Name, [string]$Seed = '') {
    $d = Join-Path $script:tmp $Name
    New-Item -ItemType Directory -Path (Join-Path $d 'inbox\updates') -Force -ErrorAction Stop | Out-Null
    $b = Join-Path $d 'backlog.md'
    $s = if ($Seed) { $Seed } else { $script:seedU }
    [IO.File]::WriteAllText($b, $s, $script:u8)
    return [pscustomobject]@{ Dir = $d; Backlog = $b; Inbox = (Join-Path $d 'inbox'); Upd = (Join-Path $d 'inbox\updates'); Q = (Join-Path $d 'inbox\updates\quarantine') }
  }
  function _Merged([string]$File) { return ('**Merged from design\backlog-inbox\updates\' + $File + ' on ' + $script:DAY + '.**') }

  # MUST FIRE: the I2 shape. Exactly its state and tag spans change, the body lands at the end of ITS section, and the
  # expected text is written out whole, so a single stray byte anywhere else is a red.
  $bxA = _NewBox 'u-i2'
  [IO.File]::WriteAllText((Join-Path $bxA.Upd 'lane-u-2026-09-23.md'), ("# lane u, 2026-09-23`n`n" + $uh + " I2`n``DONE`` ``queue-7```nThe stray files are gone.`n"), $u8)
  $oA = & $PSCommandPath -InboxDir $bxA.Inbox -Backlog $bxA.Backlog -Today $DAY 2>&1 | Out-String
  $cA = $LASTEXITCODE
  $gotA = [IO.File]::ReadAllText($bxA.Backlog)
  $expA = $seedU.Replace($hdI2, '### I2 - Stray artifacts at the repo root `DONE` `queue-7`').Replace("I2 body line.`n", ("I2 body line.`n`nThe stray files are gone.`n`n" + (_Merged 'lane-u-2026-09-23.md') + "`n"))
  _C 'MUST FIRE' 'an UPDATE for I2 changes exactly its state and tag spans and appends at the end of I2, every other byte identical' `
    ($cA -eq 0 -and [string]::Equals($gotA, $expA, [StringComparison]::Ordinal)) "exit $cA :: $oA :: GOT >>$gotA<<"
  _C 'MUST FIRE' 'and it prints the commit trailer naming the file, and consumes it' `
    (($oA -match '(?m)^Backlog-Merged-From: updates/lane-u-2026-09-23\.md\s*$') -and -not (Test-Path (Join-Path $bxA.Upd 'lane-u-2026-09-23.md'))) "exit $cA :: $oA"
  $gA = & $AUDIT -Backlog $bxA.Backlog 2>&1 | Out-String
  $gcA = $LASTEXITCODE
  _C 'CLEAN TWIN' 'audit-backlog-status.ps1 over the merged temp backlog exits 0' ($gcA -eq 0 -and $gA -match 'BACKLOG-STATUS-COMPLETE items=4 malformed=0') "exit $gcA :: $gA"

  # MUST FIRE: the E7 shape. The title's own backticked code is a span too, and it is not the state, so it stays.
  $bxB = _NewBox 'u-e7'
  [IO.File]::WriteAllText((Join-Path $bxB.Upd 'lane-e7.md'), ($uh + " E7`n``DONE`` ``4e8102c2```n`nDone at last.`n"), $u8)
  $oB = & $PSCommandPath -InboxDir $bxB.Inbox -Backlog $bxB.Backlog -Today $DAY 2>&1 | Out-String
  $cB = $LASTEXITCODE
  $gotB = [IO.File]::ReadAllText($bxB.Backlog)
  $expB = $seedU.Replace($hdE7, '### E7 - `.worktreeinclude` `DONE` `4e8102c2`').Replace("E7 body.`n", ("E7 body.`n`nDone at last.`n`n" + (_Merged 'lane-e7.md') + "`n"))
  _C 'MUST FIRE' 'E7 shape: a title carrying backticked code keeps that span untouched' `
    ($cB -eq 0 -and [string]::Equals($gotB, $expB, [StringComparison]::Ordinal)) "exit $cB :: $oB :: GOT >>$gotB<<"

  # MUST FIRE: the I5 shape. Prose after the tags is not a span and stays byte-identical; the section ends at a `##`.
  $bxC = _NewBox 'u-i5'
  [IO.File]::WriteAllText((Join-Path $bxC.Upd 'lane-i5.md'), ($uh + " I5`n``DONE`` ``queue-7```n`nThe record was filed.`n"), $u8)
  $oC = & $PSCommandPath -InboxDir $bxC.Inbox -Backlog $bxC.Backlog -Today $DAY 2>&1 | Out-String
  $cC = $LASTEXITCODE
  $gotC = [IO.File]::ReadAllText($bxC.Backlog)
  $expC = $seedU.Replace($hdI5, '### I5 - Coursera lapsed on `building-with-the-claude-api` `DONE` `queue-7` - knowledge banked, only the record is missing').Replace("I5 body.`n", ("I5 body.`n`nThe record was filed.`n`n" + (_Merged 'lane-i5.md') + "`n"))
  _C 'MUST FIRE' 'I5 shape: prose after the tags stays byte-identical, the body stops at the next ## section' `
    ($cC -eq 0 -and [string]::Equals($gotC, $expC, [StringComparison]::Ordinal)) "exit $cC :: $oC :: GOT >>$gotC<<"

  # MUST FIRE: an UPDATE naming an id the backlog does not have.
  $bxD = _NewBox 'u-missing'
  [IO.File]::WriteAllText((Join-Path $bxD.Upd 'lane-miss.md'), ($uh + " I999`n``DONE`` ``queue-7```n`nno such item.`n"), $u8)
  $oD = & $PSCommandPath -InboxDir $bxD.Inbox -Backlog $bxD.Backlog -Today $DAY 2>&1 | Out-String
  $cD = $LASTEXITCODE
  _C 'MUST FIRE' 'an UPDATE naming a missing id is quarantined, exit non-zero, backlog unchanged' `
    ($cD -eq 2 -and [string]::Equals([IO.File]::ReadAllText($bxD.Backlog), $seedU, [StringComparison]::Ordinal) -and
     (Test-Path (Join-Path $bxD.Q 'lane-miss.md')) -and ((Get-Content (Join-Path $bxD.Q 'lane-miss.md.reason.txt') -Raw) -match 'I999') -and
     -not (Test-Path (Join-Path $bxD.Upd 'lane-miss.md'))) "exit $cD :: $oD"

  # MUST FIRE: an UPDATE whose state is not in the closed vocabulary.
  $bxE = _NewBox 'u-state'
  [IO.File]::WriteAllText((Join-Path $bxE.Upd 'lane-ship.md'), ($uh + " I2`n``SHIPPED`` ``queue-7```n`nshipped it.`n"), $u8)
  $oE = & $PSCommandPath -InboxDir $bxE.Inbox -Backlog $bxE.Backlog -Today $DAY 2>&1 | Out-String
  $cE = $LASTEXITCODE
  _C 'MUST FIRE' 'an UPDATE with an unknown state is quarantined and names the vocabulary' `
    ($cE -eq 2 -and $oE -match 'closed vocabulary' -and (Test-Path (Join-Path $bxE.Q 'lane-ship.md')) -and
     [string]::Equals([IO.File]::ReadAllText($bxE.Backlog), $seedU, [StringComparison]::Ordinal)) "exit $cE :: $oE"

  # MUST FIRE: the gate's own rules. The parser accepts this line - its first span IS a state - and only the gate, run
  # over the temp copy, knows an open item owes a reversibility. So this case is the gate path and nothing else.
  $bxF = _NewBox 'u-axes'
  [IO.File]::WriteAllText((Join-Path $bxF.Upd 'lane-axes.md'), ($uh + " I2`n``OPEN`` ``queue-7`` ``RUNG1 BUILD```n`nreopened.`n"), $u8)
  $oF = & $PSCommandPath -InboxDir $bxF.Inbox -Backlog $bxF.Backlog -Today $DAY 2>&1 | Out-String
  $cF = $LASTEXITCODE
  $rF = if (Test-Path (Join-Path $bxF.Q 'lane-axes.md.reason.txt')) { Get-Content (Join-Path $bxF.Q 'lane-axes.md.reason.txt') -Raw } else { '' }
  _C 'MUST FIRE' 'an UPDATE that drops REVERSIBILITY on an open item is quarantined with the gate''s finding' `
    ($cF -eq 2 -and $rF -match 'I2: declares no reversibility' -and $rF -match 'audit-backlog-status' -and
     [string]::Equals([IO.File]::ReadAllText($bxF.Backlog), $seedU, [StringComparison]::Ordinal)) "exit $cF :: $oF :: reason >>$rF<<"

  # MUST FIRE: two files, one id, DIFFERENT tag sets. Settled by nobody: both quarantined, each naming the other.
  $bxG = _NewBox 'u-conflict'
  [IO.File]::WriteAllText((Join-Path $bxG.Upd 'lane-a-2026-09-23.md'), ($uh + " I2`n``DONE`` ``queue-7```n`nfrom a.`n"), $u8)
  [IO.File]::WriteAllText((Join-Path $bxG.Upd 'lane-b-2026-09-23.md'), ($uh + " I2`n``PARKED - SUPERSEDED`` ``queue-7```n`nfrom b.`n"), $u8)
  $oG = & $PSCommandPath -InboxDir $bxG.Inbox -Backlog $bxG.Backlog -Today $DAY 2>&1 | Out-String
  $cG2 = $LASTEXITCODE
  $rGa = if (Test-Path (Join-Path $bxG.Q 'lane-a-2026-09-23.md.reason.txt')) { Get-Content (Join-Path $bxG.Q 'lane-a-2026-09-23.md.reason.txt') -Raw } else { '' }
  $rGb = if (Test-Path (Join-Path $bxG.Q 'lane-b-2026-09-23.md.reason.txt')) { Get-Content (Join-Path $bxG.Q 'lane-b-2026-09-23.md.reason.txt') -Raw } else { '' }
  _C 'MUST FIRE' 'two files giving I2 DIFFERENT tag sets quarantine both, each naming the other, exit 2, backlog unchanged' `
    ($cG2 -eq 2 -and $rGa -match 'lane-b-2026-09-23\.md' -and $rGb -match 'lane-a-2026-09-23\.md' -and $rGa -match 'CONFLICTING' -and
     [string]::Equals([IO.File]::ReadAllText($bxG.Backlog), $seedU, [StringComparison]::Ordinal)) "exit $cG2 :: $oG"

  # MUST FIRE: tag sets that differ only in CASE. The gate reads `done` as DONE, but the two write different headings,
  # so which one lands would be decided by file order. The comparison is ordinal for exactly that reason.
  $bxG2 = _NewBox 'u-conflict-case'
  [IO.File]::WriteAllText((Join-Path $bxG2.Upd 'lane-a-2026-09-23.md'), ($uh + " I2`n``DONE`` ``queue-7```n`nfrom a.`n"), $u8)
  [IO.File]::WriteAllText((Join-Path $bxG2.Upd 'lane-b-2026-09-23.md'), ($uh + " I2`n``done`` ``queue-7```n`nfrom b.`n"), $u8)
  $oG3 = & $PSCommandPath -InboxDir $bxG2.Inbox -Backlog $bxG2.Backlog -Today $DAY 2>&1 | Out-String
  $cG3 = $LASTEXITCODE
  _C 'MUST FIRE' 'tag sets differing only in case are DIFFERENT: both files quarantined, backlog unchanged' `
    ($cG3 -eq 2 -and (Test-Path (Join-Path $bxG2.Q 'lane-a-2026-09-23.md')) -and (Test-Path (Join-Path $bxG2.Q 'lane-b-2026-09-23.md')) -and
     [string]::Equals([IO.File]::ReadAllText($bxG2.Backlog), $seedU, [StringComparison]::Ordinal)) "exit $cG3 :: $oG3"

  # CLEAN TWIN: the same two files agreeing. Both bodies land, in file-name order, and the output says so.
  $bxH = _NewBox 'u-agree'
  [IO.File]::WriteAllText((Join-Path $bxH.Upd 'lane-a-2026-09-23.md'), ($uh + " I2`n``DONE`` ``queue-7```n`nfrom a.`n"), $u8)
  [IO.File]::WriteAllText((Join-Path $bxH.Upd 'lane-b-2026-09-23.md'), ($uh + " I2`n``DONE`` ``queue-7```n`nfrom b.`n"), $u8)
  $oH = & $PSCommandPath -InboxDir $bxH.Inbox -Backlog $bxH.Backlog -Today $DAY 2>&1 | Out-String
  $cH = $LASTEXITCODE
  $gotH = [IO.File]::ReadAllText($bxH.Backlog)
  $expH = $seedU.Replace($hdI2, '### I2 - Stray artifacts at the repo root `DONE` `queue-7`').Replace("I2 body line.`n", ("I2 body line.`n`nfrom a.`n`n" + (_Merged 'lane-a-2026-09-23.md') + "`n`nfrom b.`n`n" + (_Merged 'lane-b-2026-09-23.md') + "`n"))
  _C 'CLEAN TWIN' 'two files giving I2 the SAME tag set both merge, and the output says updated by 2 files' `
    ($cH -eq 0 -and $oH -match 'I2 updated by 2 files: lane-a-2026-09-23\.md, lane-b-2026-09-23\.md' -and
     [string]::Equals($gotH, $expH, [StringComparison]::Ordinal)) "exit $cH :: $oH :: GOT >>$gotH<<"

  # CLEAN TWIN: a plain new-finding file in the same batch still gets the next id, and the trailer names both files.
  $bxI = _NewBox 'u-mixed'
  [IO.File]::WriteAllText((Join-Path $bxI.Inbox 'lane-n.md'), "## a new thing found`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nnew body.`n", $u8)
  [IO.File]::WriteAllText((Join-Path $bxI.Upd 'lane-u.md'), ($uh + " I2`n``DONE`` ``queue-7```n`nfinished.`n"), $u8)
  $oI = & $PSCommandPath -InboxDir $bxI.Inbox -Backlog $bxI.Backlog -Today $DAY 2>&1 | Out-String
  $cI = $LASTEXITCODE
  $gotI = [IO.File]::ReadAllText($bxI.Backlog)
  $idsI = @([regex]::Matches($gotI, '(?m)^### I(\d+)\b') | ForEach-Object { [int]$_.Groups[1].Value })
  _C 'CLEAN TWIN' 'a plain new-finding file in the same batch still gets the next id and merges beside the update' `
    ($cI -eq 0 -and $gotI -match '(?m)^### I41 - a new thing found `OPEN`' -and $gotI -match '(?m)^### I2 - Stray artifacts at the repo root `DONE` `queue-7`$' -and
     (($idsI | Measure-Object -Maximum).Maximum -eq 41) -and $oI -match '(?m)^Backlog-Merged-From: lane-n\.md, updates/lane-u\.md\s*$') "exit $cI :: $oI"

  # MUST NOT FIRE: order. Two updates to two different items commute - applied either way round, the same bytes.
  $upI2 = [pscustomobject]@{ Id = 'I2'; Tags = @('DONE', 'queue-7'); Key = ''; Body = 'i2 done.'; From = 'lane-x.md'; Order = 1; Empty = $false }
  $upE7 = [pscustomobject]@{ Id = 'E7'; Tags = @('DONE', '4e8102c2'); Key = ''; Body = 'e7 done.'; From = 'lane-y.md'; Order = 1; Empty = $false }
  $ordA = Invoke-TcBacklogUpdates -Text $seedU -Updates @($upI2, $upE7) -Date $DAY
  $ordB = Invoke-TcBacklogUpdates -Text $seedU -Updates @($upE7, $upI2) -Date $DAY
  _C 'MUST NOT FIRE' 'UPDATE files for two different items give byte-identical backlogs in either merge order' `
    ([string]::Equals($ordA.Text, $ordB.Text, [StringComparison]::Ordinal) -and -not [string]::Equals($ordA.Text, $seedU, [StringComparison]::Ordinal) -and
     @($ordA.Problems).Count -eq 0 -and @($ordB.Problems).Count -eq 0) 'the two orders gave different text, or applied nothing'

  # MUST NOT FIRE: the merge as it stood BEFORE this change, run from its frozen blob over a drop box holding only an
  # updates\ file. That copy is what every checkout that has not pulled W3.1 still runs, and it must see nothing to mint.
  $OLD_MERGE_BLOB = '371c5a8787fbf9c5c5b26dbf1c1b7f12e30f13a1'   # ops\merge-backlog-inbox.ps1 at f33d11829, the last blob before W3.1
  if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
    $blind++
    Write-Output ("  {0,-14} {1,-58} {2}" -f 'MUST NOT FIRE', 'the pre-W3.1 merge over an updates-only inbox finds no new finding', 'BLIND - not a git checkout, so the frozen blob cannot be read')
  } else {
    $bxK = _NewBox 'u-oldcopy'
    [IO.File]::WriteAllText((Join-Path $bxK.Upd 'lane-u.md'), ($uh + " I2`n``DONE`` ``queue-7```n`nfinished.`n"), $u8)
    $oldDir = Join-Path $bxK.Dir 'old'
    New-Item -ItemType Directory -Path $oldDir -ErrorAction Stop | Out-Null
    $oldPath = Join-Path $oldDir 'merge-backlog-inbox.ps1'
    # The blob's BYTES, not PowerShell's re-encoding of git's output: a process stream copied straight to the file.
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = ('-C "' + $repo + '" cat-file blob ' + $OLD_MERGE_BLOB)
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $gp = [Diagnostics.Process]::Start($psi)
    $fsK = [IO.File]::Create($oldPath)
    try { $gp.StandardOutput.BaseStream.CopyTo($fsK) } finally { $fsK.Dispose() }
    $gErr = $gp.StandardError.ReadToEnd()
    $gp.WaitForExit()
    $oK = ''; $cK2 = -1
    if ($gp.ExitCode -eq 0) {
      $oK = & $oldPath -InboxDir $bxK.Inbox -Backlog $bxK.Backlog 2>&1 | Out-String
      $cK2 = $LASTEXITCODE
    }
    _C 'MUST NOT FIRE' 'the pre-W3.1 merge over an updates-only inbox finds no new finding' `
      ($gp.ExitCode -eq 0 -and $cK2 -eq 0 -and $oK -match 'inbox is empty' -and (Test-Path (Join-Path $bxK.Upd 'lane-u.md')) -and
       [string]::Equals([IO.File]::ReadAllText($bxK.Backlog), $seedU, [StringComparison]::Ordinal)) "git=$($gp.ExitCode) $gErr :: exit $cK2 :: $oK"
  }

  # MUST FIRE: an UPDATE heading filed in the inbox ROOT. Every `##` there is minted as a new item, so it is quarantined.
  $bxL = _NewBox 'u-root'
  [IO.File]::WriteAllText((Join-Path $bxL.Inbox 'lane-root.md'), ($uh + " I2`n``DONE`` ``queue-7```n`nfiled in the wrong folder.`n"), $u8)
  $oL = & $PSCommandPath -InboxDir $bxL.Inbox -Backlog $bxL.Backlog -Today $DAY 2>&1 | Out-String
  $cL = $LASTEXITCODE
  _C 'MUST FIRE' 'an UPDATE heading in the inbox ROOT is quarantined, never minted as a new item' `
    ($cL -eq 2 -and (Test-Path (Join-Path $bxL.Inbox 'quarantine\lane-root.md')) -and $oL -match 'updates' -and
     [string]::Equals([IO.File]::ReadAllText($bxL.Backlog), $seedU, [StringComparison]::Ordinal)) "exit $cL :: $oL"

  # MUST FIRE: the ledger lock, held by ANOTHER PROCESS (lib\mutex-hold.ps1) on this case's own temp backlog, so the
  # merge's wait times out however loaded the box is and no production lock name is ever opened. -LockWaitSec 0 is not a
  # clock: the holder keeps the lock until released, so any wait would time out.
  . (Join-Path $repo 'lib\mutex-hold.ps1')
  $bxM = _NewBox 'u-lock'
  [IO.File]::WriteAllText((Join-Path $bxM.Upd 'lane-u.md'), ($uh + " I2`n``DONE`` ``queue-7```n`nfinished.`n"), $u8)
  $holdM = Start-TcMutexHold -Name (Get-TcLedgerLockName -Path $bxM.Backlog)
  $oM = & $PSCommandPath -InboxDir $bxM.Inbox -Backlog $bxM.Backlog -Today $DAY -LockWaitSec 0 2>&1 | Out-String
  $cM = $LASTEXITCODE
  $untouchedM = [string]::Equals([IO.File]::ReadAllText($bxM.Backlog), $seedU, [StringComparison]::Ordinal) -and (Test-Path (Join-Path $bxM.Upd 'lane-u.md'))
  Stop-TcMutexHold -Hold $holdM
  _C 'MUST FIRE' 'while another process holds the backlog''s ledger lock the merge exits 3 and writes, consumes nothing' `
    ($holdM.Held -and $cM -eq 3 -and $oM -match 'ledger lock' -and $untouchedM) "held=$($holdM.Held) $($holdM.Detail) :: exit $cM :: $oM"
  $oM2 = & $PSCommandPath -InboxDir $bxM.Inbox -Backlog $bxM.Backlog -Today $DAY -LockWaitSec 0 2>&1 | Out-String
  $cM2 = $LASTEXITCODE
  _C 'CLEAN TWIN' 'once that holder lets go, the same merge takes the lock and lands the update' `
    ($cM2 -eq 0 -and ([IO.File]::ReadAllText($bxM.Backlog)) -match '(?m)^### I2 - Stray artifacts at the repo root `DONE` `queue-7`$' -and
     -not (Test-Path (Join-Path $bxM.Upd 'lane-u.md'))) "exit $cM2 :: $oM2"

  # -ValidateFile over an UPDATE file where it sits, under a folder named updates: judged as the merge will read it.
  $bxN = _NewBox 'u-validate'
  $vU = Join-Path $bxN.Upd 'lane-v.md'
  [IO.File]::WriteAllText($vU, ($uh + " I2`n``DONE`` ``queue-7```n`nfinished.`n"), $u8)
  $oN = & $PSCommandPath -ValidateFile $vU -Backlog $bxN.Backlog 2>&1 | Out-String
  $cN2 = $LASTEXITCODE
  _C 'MUST NOT FIRE' '-ValidateFile on a good UPDATE file is exit 0, and nothing is written or consumed' `
    ($cN2 -eq 0 -and $oN -match 'VALIDATE OK' -and $oN -match 'UPDATE file' -and (Test-Path $vU) -and
     [string]::Equals([IO.File]::ReadAllText($bxN.Backlog), $seedU, [StringComparison]::Ordinal)) "exit $cN2 :: $oN"
  $vU2 = Join-Path $bxN.Upd 'lane-v2.md'
  [IO.File]::WriteAllText($vU2, ($uh + " I999`n``DONE`` ``queue-7```n`nno such item.`n"), $u8)
  $oN3 = & $PSCommandPath -ValidateFile $vU2 -Backlog $bxN.Backlog 2>&1 | Out-String
  $cN3 = $LASTEXITCODE
  _C 'MUST FIRE' '-ValidateFile on an UPDATE naming a missing id is exit 2 and names it' `
    ($cN3 -eq 2 -and $oN3 -match 'VALIDATE FAILED' -and $oN3 -match 'I999' -and (Test-Path $vU2)) "exit $cN3 :: $oN3"

  # MUST FIRE: a body line that is a heading would start a new section of the backlog, or a new item.
  $bxO = _NewBox 'u-bodyhead'
  [IO.File]::WriteAllText((Join-Path $bxO.Upd 'lane-h.md'), ($uh + " I2`n``DONE`` ``queue-7```n`nfinished.`n`n### I99 - smuggled ``OPEN```n"), $u8)
  $oO = & $PSCommandPath -InboxDir $bxO.Inbox -Backlog $bxO.Backlog -Today $DAY 2>&1 | Out-String
  $cO = $LASTEXITCODE
  _C 'MUST FIRE' 'an UPDATE whose body carries a heading line is quarantined, and nothing of it lands' `
    ($cO -eq 2 -and $oO -match 'heading line' -and (Test-Path (Join-Path $bxO.Q 'lane-h.md')) -and
     [string]::Equals([IO.File]::ReadAllText($bxO.Backlog), $seedU, [StringComparison]::Ordinal)) "exit $cO :: $oO"

  # MUST NOT FIRE: a `## ` line inside a fenced block in the item is code, not a heading, so the section runs past it.
  $fence = '```'
  $seedP = "# Backlog`n`n$hdI2`n`nbefore the fence.`n`n$fence`n## not a heading`n$fence`n`nafter the fence.`n`n### I40 - an old one ``DONE```n`nI40 body.`n"
  $bxP = _NewBox 'u-fence' $seedP
  [IO.File]::WriteAllText((Join-Path $bxP.Upd 'lane-f.md'), ($uh + " I2`n``DONE`` ``queue-7```n`nfinished.`n"), $u8)
  $oP = & $PSCommandPath -InboxDir $bxP.Inbox -Backlog $bxP.Backlog -Today $DAY 2>&1 | Out-String
  $cP2 = $LASTEXITCODE
  $expP = $seedP.Replace($hdI2, '### I2 - Stray artifacts at the repo root `DONE` `queue-7`').Replace("after the fence.`n", ("after the fence.`n`nfinished.`n`n" + (_Merged 'lane-f.md') + "`n"))
  _C 'MUST NOT FIRE' 'a ## line inside a fenced block does not end the item: the body lands after the fence' `
    ($cP2 -eq 0 -and [string]::Equals([IO.File]::ReadAllText($bxP.Backlog), $expP, [StringComparison]::Ordinal)) "exit $cP2 :: $oP"

  # MUST FIRE: a backlog ALREADY red for its gate. No update can be judged by a gate that fails before it, so the file is
  # left pending where it is, never quarantined for somebody else's defect, and the run says it could not evaluate.
  $seedQ = $seedU.Replace($hdE7, '### E7 - `.worktreeinclude` `OPEN` `queue-4`')
  $bxQ = _NewBox 'u-redbase' $seedQ
  [IO.File]::WriteAllText((Join-Path $bxQ.Upd 'lane-u.md'), ($uh + " I2`n``DONE`` ``queue-7```n`nfinished.`n"), $u8)
  $oQ = & $PSCommandPath -InboxDir $bxQ.Inbox -Backlog $bxQ.Backlog -Today $DAY 2>&1 | Out-String
  $cQ = $LASTEXITCODE
  _C 'MUST FIRE' 'a backlog already failing its gate: exit 3, the update left pending, not quarantined, nothing written' `
    ($cQ -eq 3 -and $oQ -match 'COULD NOT EVALUATE' -and (Test-Path (Join-Path $bxQ.Upd 'lane-u.md')) -and -not (Test-Path $bxQ.Q) -and
     [string]::Equals([IO.File]::ReadAllText($bxQ.Backlog), $seedQ, [StringComparison]::Ordinal)) "exit $cQ :: $oQ"

  # ======================= ONE ALLOCATOR (2026-09-23, W3.4a of design\PLAN-push-derived-conflicts-2026-09-23.md, D17) ======
  # Each case builds its OWN box: a shared .git in the MAIN checkout's shape (a directory), and linked worktrees whose
  # `.git` FILE points at an admin directory under it with a `commondir` file, exactly as git lays them out. Every
  # checkout holds design\BACKLOG-course-findings.md and one new finding. No git runs: the merge reads the pointers, so
  # the fixture is the pointers. -Marker live plants the task's marker in the 'task' worktree's admin directory naming
  # that checkout; 'stale' names a checkout directory that never existed; 'none' plants nothing. The marker file name
  # is spelled here independently of the live constant (by concatenation), so a rename of one without the other goes red.
  $mkName = 'tc-backlog-' + 'allocator'
  function _AllocBox([string]$Name, [string]$Marker = 'live') {
    $d = Join-Path $script:tmp $Name
    $common = Join-Path $d 'main\.git'
    New-Item -ItemType Directory -Path $common -Force -ErrorAction Stop | Out-Null
    $box = [ordered]@{ Dir = $d; Common = $common }
    foreach ($co in @('main', 'task', 'other')) {
      $root = Join-Path $d $co
      New-Item -ItemType Directory -Path (Join-Path $root 'design\backlog-inbox') -Force -ErrorAction Stop | Out-Null
      if ($co -ne 'main') {
        $adm = Join-Path $common ('worktrees\' + $co)
        New-Item -ItemType Directory -Path $adm -Force -ErrorAction Stop | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.git'), ('gitdir: ' + $adm + "`n"), $script:u8)
        [IO.File]::WriteAllText((Join-Path $adm 'commondir'), "../..`n", $script:u8)
        $box[$co + 'Adm'] = $adm
      }
      [IO.File]::WriteAllText((Join-Path $root 'design\BACKLOG-course-findings.md'), $script:seedU, $script:u8)
      [IO.File]::WriteAllText((Join-Path $root 'design\backlog-inbox\lane-n.md'), "## a new thing found`n``OPEN`` ``queue-7`` ``2-WAY`` ``RUNG1 MEASURE```n`nnew body.`n", $script:u8)
      $box[$co] = $root
      $box[$co + 'Backlog'] = Join-Path $root 'design\BACKLOG-course-findings.md'
      $box[$co + 'Inbox'] = Join-Path $root 'design\backlog-inbox'
    }
    if ($Marker -eq 'live' -or $Marker -eq 'stale') {
      $names = if ($Marker -eq 'stale') { Join-Path $d 'gone' } else { $box['task'] }
      $mk = '{"task":"TC Backlog Merge","checkout":' + (ConvertTo-Json ([string]$names)) + ',"written_utc":"2026-09-23T11:00:00Z"}'
      [IO.File]::WriteAllText((Join-Path $box['taskAdm'] $script:mkName), $mk, $script:u8)
    }
    return [pscustomobject]$box
  }
  function _Untouched($Box, [string]$Co) {
    return ([string]::Equals([IO.File]::ReadAllText($Box.($Co + 'Backlog')), $script:seedU, [StringComparison]::Ordinal) -and
            (Test-Path (Join-Path $Box.($Co + 'Inbox') 'lane-n.md')) -and -not (Test-Path (Join-Path $Box.($Co + 'Inbox') 'quarantine')))
  }

  # MUST FIRE, the collision D17 exists for: the MAIN checkout's merge while the task's allocator is live.
  $axA = _AllocBox 'al-main'
  $oA1 = & $PSCommandPath -InboxDir $axA.mainInbox -Backlog $axA.mainBacklog -Today $DAY 2>&1 | Out-String
  $cA1 = $LASTEXITCODE
  _C 'MUST FIRE' 'a merge in the main checkout while an allocator is live is refused, exit 1, nothing read or written' `
    ($cA1 -eq 1 -and $oA1 -match 'REFUSED' -and $oA1 -match [regex]::Escape($axA.task) -and $oA1 -match 'AllowHandMerge' -and (_Untouched $axA 'main')) "exit $cA1 :: $oA1"

  # MUST FIRE: another LINKED worktree, the shape every lane runs in, is refused the same way.
  $axB = _AllocBox 'al-other'
  $oA2 = & $PSCommandPath -InboxDir $axB.otherInbox -Backlog $axB.otherBacklog -Today $DAY 2>&1 | Out-String
  $cA2 = $LASTEXITCODE
  _C 'MUST FIRE' 'a merge in another linked worktree while an allocator is live is refused, exit 1, nothing written' `
    ($cA2 -eq 1 -and $oA2 -match 'REFUSED' -and (_Untouched $axB 'other')) "exit $cA2 :: $oA2"

  # CLEAN TWIN: the task's own worktree merges with no switch, and its trailer carries no hand-merge reason.
  $axC = _AllocBox 'al-task'
  $oA3 = & $PSCommandPath -InboxDir $axC.taskInbox -Backlog $axC.taskBacklog -Today $DAY 2>&1 | Out-String
  $cA3 = $LASTEXITCODE
  _C 'CLEAN TWIN' 'the allocator''s own worktree merges with no switch: I41 minted, trailer with no hand-merge reason' `
    ($cA3 -eq 0 -and ([IO.File]::ReadAllText($axC.taskBacklog)) -match '(?m)^### I41 - a new thing found `OPEN`' -and
     $oA3 -match '(?m)^Backlog-Merged-From: lane-n\.md\s*$' -and $oA3 -match 'allocator: ' -and -not (Test-Path (Join-Path $axC.taskInbox 'lane-n.md'))) "exit $cA3 :: $oA3"

  # CLEAN TWIN: -AllowHandMerge "<reason>" in the main checkout merges, and the reason is on the trailer line.
  $axD = _AllocBox 'al-hand'
  $oA4 = & $PSCommandPath -InboxDir $axD.mainInbox -Backlog $axD.mainBacklog -Today $DAY -AllowHandMerge "Brad asked for`r`nthis id now" 2>&1 | Out-String
  $cA4 = $LASTEXITCODE
  _C 'CLEAN TWIN' '-AllowHandMerge with a reason merges in the main checkout and prints the reason, one line, in its trailer' `
    ($cA4 -eq 0 -and ([IO.File]::ReadAllText($axD.mainBacklog)) -match '(?m)^### I41 - a new thing found' -and
     $oA4 -match '(?m)^Backlog-Merged-From: lane-n\.md; hand-merge: Brad asked for this id now\s*$') "exit $cA4 :: $oA4"

  # MUST FIRE: a blank reason is no reason. It is refused, not read as "the switch was not passed".
  $axE = _AllocBox 'al-blank'
  $oA5 = & $PSCommandPath -InboxDir $axE.mainInbox -Backlog $axE.mainBacklog -Today $DAY -AllowHandMerge '   ' 2>&1 | Out-String
  $cA5 = $LASTEXITCODE
  _C 'MUST FIRE' '-AllowHandMerge with a blank reason is refused, exit 1, nothing written' `
    ($cA5 -eq 1 -and $oA5 -match 'no reason' -and (_Untouched $axE 'main')) "exit $cA5 :: $oA5"

  # MUST NOT FIRE: a dry run writes nothing, so it is never judged - push-main's pre-flight validates from any checkout.
  $axF = _AllocBox 'al-dry'
  $oA6 = & $PSCommandPath -InboxDir $axF.otherInbox -Backlog $axF.otherBacklog -Today $DAY -DryRun 2>&1 | Out-String
  $cA6 = $LASTEXITCODE
  _C 'MUST NOT FIRE' '-DryRun in a non-allocator checkout is not refused: exit 0, the plan printed, nothing written' `
    ($cA6 -eq 0 -and $oA6 -match 'a new thing found' -and $oA6 -notmatch 'REFUSED' -and (_Untouched $axF 'other')) "exit $cA6 :: $oA6"

  # MUST NOT FIRE: -ValidateFile against a non-allocator checkout's backlog still answers.
  $oA7 = & $PSCommandPath -ValidateFile (Join-Path $axF.otherInbox 'lane-n.md') -Backlog $axF.otherBacklog 2>&1 | Out-String
  $cA7 = $LASTEXITCODE
  _C 'MUST NOT FIRE' '-ValidateFile against a non-allocator checkout''s backlog is not refused: exit 0 VALIDATE OK' `
    ($cA7 -eq 0 -and $oA7 -match 'VALIDATE OK' -and (_Untouched $axF 'other')) "exit $cA7 :: $oA7"

  # MUST FIRE: a marker in a checkout's admin directory that names a DIFFERENT checkout does not make it the allocator.
  $axG = _AllocBox 'al-misnamed'
  Copy-Item -LiteralPath (Join-Path $axG.taskAdm $mkName) -Destination (Join-Path $axG.otherAdm $mkName) -ErrorAction Stop
  $oA8 = & $PSCommandPath -InboxDir $axG.otherInbox -Backlog $axG.otherBacklog -Today $DAY 2>&1 | Out-String
  $cA8 = $LASTEXITCODE
  _C 'MUST FIRE' 'a marker naming ANOTHER checkout does not make this one the allocator: refused, exit 1' `
    ($cA8 -eq 1 -and $oA8 -match 'REFUSED' -and (_Untouched $axG 'other')) "exit $cA8 :: $oA8"

  # MUST NOT FIRE, the degrade: with no marker anywhere, a hand merge proceeds as the day before and says so.
  $axH = _AllocBox 'al-none' 'none'
  $oA9 = & $PSCommandPath -InboxDir $axH.mainInbox -Backlog $axH.mainBacklog -Today $DAY 2>&1 | Out-String
  $cA9 = $LASTEXITCODE
  _C 'MUST NOT FIRE' 'with no allocator on the box a hand merge is not refused: exit 0, WARN, and the trailer says why' `
    ($cA9 -eq 0 -and $oA9 -match 'WARN - no TC Backlog Merge allocator is live' -and ([IO.File]::ReadAllText($axH.mainBacklog)) -match '(?m)^### I41 - ' -and
     $oA9 -match '(?m)^Backlog-Merged-From: lane-n\.md; hand-merge: no scheduled allocator was live on this box\s*$') "exit $cA9 :: $oA9"

  # MUST NOT FIRE, the degrade: a marker whose checkout no longer exists is not a live allocator.
  $axI = _AllocBox 'al-stale' 'stale'
  $oA10 = & $PSCommandPath -InboxDir $axI.otherInbox -Backlog $axI.otherBacklog -Today $DAY 2>&1 | Out-String
  $cA10 = $LASTEXITCODE
  _C 'MUST NOT FIRE' 'a marker naming a checkout that is gone arms nothing: the merge proceeds, exit 0, with the WARN' `
    ($cA10 -eq 0 -and $oA10 -match 'WARN - no TC Backlog Merge allocator is live' -and ([IO.File]::ReadAllText($axI.otherBacklog)) -match '(?m)^### I41 - ') "exit $cA10 :: $oA10"

  # ---- A NEW FINDING IS JUDGED BY THE GATE'S OWN STATE RULE (2026-09-24, pd-backlog-2026-09-23.md) ----
  # MUST FIRE, the founding shape: `DONE-ish` passed Test-State (it BEGINS with DONE), merged as I41 with exit 0, and the
  # gate then failed the backlog with 'I41: declares no state'. Now the file is quarantined and the backlog is untouched.
  $gsDir = Join-Path $tmp 'gs'
  New-Item -ItemType Directory -Path (Join-Path $gsDir 'inbox') -Force | Out-Null
  $gsBl = Join-Path $gsDir 'backlog.md'
  $gsSeed = "# Backlog`n`n### I40 - an old one ``DONE```n`nbody`n"
  [IO.File]::WriteAllText($gsBl, $gsSeed, $u8)
  [IO.File]::WriteAllText((Join-Path $gsDir 'inbox\lane-ish.md'), "## a finding with a near-miss state`n``DONE-ish`` ``queue-7```n`nbody`n", $u8)
  $oG1 = & $PSCommandPath -InboxDir (Join-Path $gsDir 'inbox') -Backlog $gsBl -Today $DAY 2>&1 | Out-String
  $cG1 = $LASTEXITCODE
  $gsAfter = [IO.File]::ReadAllText($gsBl)
  _C 'MUST FIRE' 'a finding whose state only BEGINS with a state word (DONE-ish) is quarantined by the gate, exit 2, backlog unchanged' `
    ($cG1 -eq 2 -and [string]::Equals($gsAfter, $gsSeed, [StringComparison]::Ordinal) -and
     (Test-Path -LiteralPath (Join-Path $gsDir 'inbox\quarantine\lane-ish.md')) -and $oG1 -match 'declares no state') "exit $cG1 :: $oG1"
  # CLEAN TWIN: the gate's own legal long form, `DONE - detail`, still merges as the next id, exit 0.
  $gsDir2 = Join-Path $tmp 'gs2'
  New-Item -ItemType Directory -Path (Join-Path $gsDir2 'inbox') -Force | Out-Null
  $gsBl2 = Join-Path $gsDir2 'backlog.md'
  [IO.File]::WriteAllText($gsBl2, $gsSeed, $u8)
  [IO.File]::WriteAllText((Join-Path $gsDir2 'inbox\lane-long.md'), "## a finding with a detailed state`n``DONE - shipped in the same change`` ``queue-7```n`nbody`n", $u8)
  $oG2 = & $PSCommandPath -InboxDir (Join-Path $gsDir2 'inbox') -Backlog $gsBl2 -Today $DAY 2>&1 | Out-String
  $cG2 = $LASTEXITCODE
  _C 'CLEAN TWIN' 'a finding in the gate''s long form (DONE - detail) still merges as I41, exit 0' `
    ($cG2 -eq 0 -and ([IO.File]::ReadAllText($gsBl2)) -match '(?m)^### I41 - a finding with a detailed state `DONE - shipped in the same change` `queue-7`$') "exit $cG2 :: $oG2"

  # MUST FIRE: a `.git` file whose pointer names nothing cannot say whether this is the allocator: exit 3, nothing written.
  $axJ = _AllocBox 'al-blind'
  [IO.File]::WriteAllText((Join-Path $axJ.other '.git'), ('gitdir: ' + (Join-Path $axJ.Dir 'no-such-admin') + "`n"), $u8)
  $oA11 = & $PSCommandPath -InboxDir $axJ.otherInbox -Backlog $axJ.otherBacklog -Today $DAY 2>&1 | Out-String
  $cA11 = $LASTEXITCODE
  _C 'MUST FIRE' 'a checkout whose .git pointer cannot be followed is could-not-evaluate, exit 3, nothing written' `
    ($cA11 -eq 3 -and $oA11 -match 'COULD NOT EVALUATE' -and (_Untouched $axJ 'other')) "exit $cA11 :: $oA11"
  } catch {
    [void]$fails.Add('HARNESS the suite threw before its last case: ' + $_.Exception.Message)
    Write-Output ('  HARNESS        the suite threw before its last case: ' + $_.Exception.Message)
  } finally {
    $env:TC_EVENT_BUS = $prevBus
    if (Get-Command Stop-TcMutexHold -ErrorAction SilentlyContinue) { Stop-TcMutexHold }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  # A LITERAL-CASE SUITE ASSERTS HOW MANY RAN (ops-and-gates.md). A blind case is counted as one that could not look,
  # never as a pass, and it still counts toward the list so a lost case is a shortfall rather than a smaller green.
  $EXPECTED_CASES = 75
  Write-Output ''
  if ($fails.Count -or ($ran + $blind) -ne $EXPECTED_CASES) {
    Write-Output ("merge-backlog-inbox SELF-TEST FAIL: {0} case(s) failed, {1} of {2} case(s) ran, {3} blind" -f $fails.Count, $ran, $EXPECTED_CASES, $blind)
    foreach ($f in $fails) { Write-Output ("  " + $f) }
    exit 1
  }
  if ($blind) {
    Write-Output ("merge-backlog-inbox self-test: {0} of {0} cases pass, {1} blind (not a git checkout, so the frozen-blob case could not look)" -f $ran, $blind)
    exit 0
  }
  Write-Output ("merge-backlog-inbox self-test: {0} of {0} cases pass" -f $ran)
  exit 0
}

# ------------------------------------------------------------------------------------ the merge

function Invoke-TcMerge {
  <# The whole merge, with the ledger lock already held by the caller (or none, under -DryRun). Prints as it goes and
     sets $script:MergeExit; it never exits, so the caller's finally always releases the lock. #>
  $script:MergeExit = 0
  # README.md documents the convention and lives here permanently so the directory survives
  # in git; a name starting with `_` is a scratch file somebody parked. Everything else is
  # findings. The skip list is deliberately TWO NAMES and not a heuristic: a broad "skip what
  # does not look like findings" rule is a silent-loss machine in a tool that exists so that
  # nothing is lost. What was skipped is printed, so a skip is never invisible.
  $all = @(Get-ChildItem -LiteralPath $InboxDir -Filter *.md -ErrorAction SilentlyContinue |
           Sort-Object Name)
  $files = @($all | Where-Object { $_.Name -ne 'README.md' -and $_.Name -notlike '_*' })
  $skipped = @($all).Count - @($files).Count
  # The UPDATE files, from their own folder and NOT recursively below it, so updates\quarantine is never re-read. The
  # same two skipped names. ORDINAL name order, because the order updates apply in must not depend on a culture.
  $updDir = Join-Path $InboxDir 'updates'
  $updAll = @()
  if (Test-Path -LiteralPath $updDir -PathType Container) {
    $updAll = @(Get-ChildItem -LiteralPath $updDir -Filter *.md -File -ErrorAction SilentlyContinue)
  }
  $updKeep = @($updAll | Where-Object { $_.Name -ne 'README.md' -and $_.Name -notlike '_*' })
  $skipped += @($updAll).Count - @($updKeep).Count
  $updNames = [string[]]@($updKeep | ForEach-Object { $_.Name })
  [Array]::Sort($updNames, [StringComparer]::Ordinal)
  $updFiles = @(foreach ($nm in $updNames) { @($updKeep | Where-Object { $_.Name -ceq $nm })[0] })
  if ($skipped -gt 0) { Write-Output ("skipping " + $skipped + " documentation file(s): README.md / _*.md") }
  if (@($files).Count -eq 0 -and @($updFiles).Count -eq 0) {
    Write-Output "inbox is empty. Nothing to merge."
    return
  }

  # READ EVERY FILE BEFORE WRITING ANYTHING, AND JUDGE EACH FILE ALONE. A malformed file
  # is QUARANTINED and its siblings still merge: nothing it says is appended, so the backlog
  # still cannot go red on its account, and the single allocator below still runs once, over
  # the accepted set. The whole-batch refusal this replaced blocked three innocent lanes
  # three times on 2026-09-11 and 12, every time over a closing `## Nothing else` heading
  # with no state line under it.
  $qRoot = Join-Path $InboxDir 'quarantine'
  $qUpd = Join-Path $updDir 'quarantine'
  $findings = @()
  $bad = New-Object System.Collections.ArrayList
  foreach ($f in $files) {
    try {
      $findings += Read-Inbox $f.FullName
    } catch {
      [void]$bad.Add([pscustomobject]@{ Name = $f.Name; Path = $f.FullName; Reason = $_.Exception.Message; QDir = $qRoot; Rel = $f.Name })
    }
  }
  $updParsed = @()
  foreach ($f in $updFiles) {
    try {
      $recs = Read-UpdateFile $f.FullName
      $recs = @($recs)
      $updParsed += [pscustomobject]@{ Name = $f.Name; Path = $f.FullName
        Updates = @($recs | Where-Object { -not $_.Empty }); Empty = (@($recs | Where-Object { $_.Empty }).Count -gt 0) }
    } catch {
      [void]$bad.Add([pscustomobject]@{ Name = $f.Name; Path = $f.FullName; Reason = $_.Exception.Message; QDir = $qUpd; Rel = ('updates/' + $f.Name) })
    }
  }

  # ---- THE UPDATES: every check that can refuse a file runs before the backlog is touched ----
  $text = $null
  $bytes = $null
  $hasBom = $false
  $applyFiles = @()
  $pendingBlind = @()
  $withUpdates = @($updParsed | Where-Object { @($_.Updates).Count -gt 0 })
  if ($withUpdates.Count -gt 0) {
    $bytes = [IO.File]::ReadAllBytes($Backlog)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $off = if ($hasBom) { 3 } else { 0 }
    try {
      # STRICT decoding: an in-place rewrite of a file that is not valid UTF-8 would change bytes nobody asked to change.
      $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes, $off, $bytes.Length - $off)
    } catch {
      Write-Output ("COULD NOT EVALUATE - the backlog is not valid UTF-8, so an in-place UPDATE would rewrite bytes it did not mean to change. Nothing was written, consumed or quarantined: " + $_.Exception.Message)
      $script:MergeExit = 3
      return
    }

    # 1. Each update names an item that exists exactly once, with one state span, and a file never contradicts itself.
    $judged = @()
    foreach ($u in $withUpdates) {
      $why = ''
      foreach ($x in @($u.Updates)) {
        $probe = Set-TcItemUpdate -Text $text -Update $x -Date $Today
        if ($probe.Problem) { $why = ('UPDATE ' + $x.Id + ' ' + $probe.Problem); break }
      }
      if (-not $why) {
        $seenKey = @{}
        foreach ($x in @($u.Updates)) {
          if ($seenKey.ContainsKey($x.Id) -and -not [string]::Equals([string]$seenKey[$x.Id], [string]$x.Key, [StringComparison]::Ordinal)) {
            $why = ('gives ' + $x.Id + ' two different tag sets in one file. One file, one outcome per item: keep the one you mean.')
            break
          }
          $seenKey[$x.Id] = $x.Key
        }
      }
      if ($why) { [void]$bad.Add([pscustomobject]@{ Name = $u.Name; Path = $u.Path; Reason = ('in ' + $u.Name + ': ' + $why); QDir = $qUpd; Rel = ('updates/' + $u.Name) }) }
      else { $judged += $u }
    }

    # 2. A CONFLICTING STATUS IS NEVER SETTLED BY ORDER (Brad's ruling D2): every file giving one id a different tag set
    #    is quarantined, each reason naming the others, and nothing is merged for that id.
    $byId = @{}
    foreach ($u in $judged) {
      foreach ($x in @($u.Updates)) {
        if (-not $byId.ContainsKey($x.Id)) { $byId[$x.Id] = New-Object System.Collections.ArrayList }
        [void]$byId[$x.Id].Add([pscustomobject]@{ File = $u.Name; Key = $x.Key; Tags = $x.Tags })
      }
    }
    $conflictWhy = @{}
    foreach ($cid in @($byId.Keys | Sort-Object)) {
      $rows = @($byId[$cid])
      $keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
      foreach ($r in $rows) { [void]$keys.Add([string]$r.Key) }
      if ($keys.Count -le 1) { continue }
      foreach ($r in $rows) {
        $mine = (@($r.Tags | ForEach-Object { '`' + $_ + '`' })) -join ' '
        $others = @($rows | Where-Object { $_.File -cne $r.File } | ForEach-Object { $_.File + ' gives ' + ((@($_.Tags | ForEach-Object { '`' + $_ + '`' })) -join ' ') } | Select-Object -Unique)
        $line = ("CONFLICTING UPDATE for {0}: this file gives {1}, and {2}. The merge never settles a conflicting status by file order, lane or time (Brad's ruling D2, 2026-09-23), so every file giving {0} a different tag set is quarantined and nothing is merged for {0}. Agree the tag line, keep it in ONE file, and move the files back." -f $cid, $mine, ($others -join '; '))
        if (-not $conflictWhy.ContainsKey($r.File)) { $conflictWhy[$r.File] = New-Object System.Collections.ArrayList }
        if (-not $conflictWhy[$r.File].Contains($line)) { [void]$conflictWhy[$r.File].Add($line) }
      }
    }
    $clear = @()
    foreach ($u in $judged) {
      if ($conflictWhy.ContainsKey($u.Name)) {
        [void]$bad.Add([pscustomobject]@{ Name = $u.Name; Path = $u.Path; Reason = ('in ' + $u.Name + ': ' + ((@($conflictWhy[$u.Name])) -join "`n")); QDir = $qUpd; Rel = ('updates/' + $u.Name) })
      } else { $clear += $u }
    }

    # 3. THE GATE'S OWN RULES over a temp copy: the backlog as it stands first, then each file's updates alone.
    if ($clear.Count -gt 0) {
      $base = Invoke-TcBacklogGate -Text $text
      if ($base.Code -ne 0) {
        $pendingBlind = $clear
        Write-Output ("COULD NOT EVALUATE {0} update file(s): the backlog fails audit-backlog-status.ps1 BEFORE any update is applied (gate exit {1}), so the gate cannot tell what an update would break. They stay in {2} untouched, and none of them lands until the backlog is green again:" -f $clear.Count, $base.Code, $updDir)
        foreach ($ln in @($base.Lines | Select-Object -First 12)) { Write-Output ("    gate: " + $ln) }
      } else {
        foreach ($u in $clear) {
          $alone = Invoke-TcBacklogUpdates -Text $text -Updates @($u.Updates) -Date $Today
          if (@($alone.Problems).Count -gt 0) {
            [void]$bad.Add([pscustomobject]@{ Name = $u.Name; Path = $u.Path; Reason = ('in ' + $u.Name + ': ' + ((@($alone.Problems | ForEach-Object { 'UPDATE ' + $_.Id + ' ' + $_.Why })) -join "`n")); QDir = $qUpd; Rel = ('updates/' + $u.Name) })
            continue
          }
          $g = Invoke-TcBacklogGate -Text $alone.Text
          if ($g.Code -eq 2) {
            [void]$bad.Add([pscustomobject]@{ Name = $u.Name; Path = $u.Path; QDir = $qUpd; Rel = ('updates/' + $u.Name)
              Reason = ('in ' + $u.Name + ': applied to a copy of the backlog, its update(s) fail audit-backlog-status.ps1, the push gate''s own rules:' + "`n" + ((@($g.Lines | ForEach-Object { '  ' + $_.Trim() })) -join "`n")) })
          } elseif ($g.Code -ne 0) {
            $pendingBlind += $u
            Write-Output ("COULD NOT EVALUATE {0}: the gate could not judge the backlog with its update(s) applied (gate exit {1}). It stays in {2} untouched." -f $u.Name, $g.Code, $updDir)
          } else {
            $applyFiles += $u
          }
        }
      }
    }
  }

  # ---- THE NEW FINDINGS, judged by the push gate's own rules, one file at a time (2026-09-24) ----
  # A file whose headings the gate would fail is quarantined whole; one the gate could not judge stays in the inbox
  # untouched and the run exits 3. Either way none of its findings is allocated an id.
  $findingNames = @($findings | Where-Object { -not $_.Empty } | ForEach-Object { $_.From } | Select-Object -Unique)
  $findHeld = @()
  foreach ($fn in $findingNames) {
    $mine = @($findings | Where-Object { -not $_.Empty -and $_.From -ceq $fn })
    $fg = Test-TcFindingFileGate -Findings $mine
    $fObj = @($files | Where-Object { $_.Name -ceq $fn })[0]
    if ($fg.Code -eq 2) {
      [void]$bad.Add([pscustomobject]@{ Name = $fn; Path = $fObj.FullName; QDir = $qRoot; Rel = $fn
        Reason = ('in ' + $fn + ': written as backlog headings, its findings fail audit-backlog-status.ps1, the push gate''s own rules (the ids below are the check''s own, not the ones a merge would allocate):' + "`n" + ((@($fg.Lines | ForEach-Object { '  ' + $_.Trim() })) -join "`n")) })
      $findHeld += $fn
    } elseif ($fg.Code -ne 0) {
      $pendingBlind += $fObj
      $findHeld += $fn
      Write-Output ("COULD NOT EVALUATE {0}: the gate could not judge its findings as backlog headings (gate exit {1}). It stays in the inbox untouched." -f $fn, $fg.Code)
    }
  }
  if ($findHeld.Count) { $findings = @($findings | Where-Object { $findHeld -notcontains $_.From }) }

  if (@($bad).Count -gt 0) {
    $verb = 'QUARANTINED'
    if ($DryRun) { $verb = 'WOULD BE QUARANTINED' }
    Write-Output ("{0} ({1} inbox file(s)) - NOT merged, kept on disk, and this run exits non-zero:" -f $verb, @($bad).Count)
    foreach ($b in $bad) { Write-Output ("  " + $b.Rel + ": " + $b.Reason) }
  }

  # An empty landing is a RESULT and is reported by name; it never becomes a backlog item,
  # because "this lane found nothing" is not a change anybody rules on. The two counts stay
  # separate in the output: a total that folds them together is how a number comes to mean
  # nothing.
  $badPaths = @($bad | ForEach-Object { $_.Path })
  $blindPaths = @($pendingBlind | Where-Object { $_ -is [IO.FileInfo] } | ForEach-Object { $_.FullName })
  $accepted = @($files | Where-Object { $badPaths -notcontains $_.FullName -and $blindPaths -notcontains $_.FullName })
  $empties  = @($findings | Where-Object { $_.Empty })
  $findings = @($findings | Where-Object { -not $_.Empty })
  $updEmpties = @($updParsed | Where-Object { $_.Empty -and @($_.Updates).Count -eq 0 })
  foreach ($e in $empties) { Write-Output ("  NOTHING TO FILE declared by " + $e.From) }
  foreach ($e in $updEmpties) { Write-Output ("  NOTHING TO FILE declared by updates/" + $e.Name) }
  $allUpd = @()
  foreach ($u in $applyFiles) { foreach ($x in @($u.Updates)) { $allUpd += $x } }

  $exitCode = 0
  if (@($bad).Count -gt 0) { $exitCode = 2 }
  if (@($pendingBlind).Count -gt 0) { $exitCode = 3 }

  if (@($findings).Count -eq 0 -and @($allUpd).Count -eq 0) {
    $emptyCount = @($empties).Count + @($updEmpties).Count
    if ($emptyCount -gt 0 -and -not $DryRun) {
      # Consume them, so a lane that landed with nothing is not re-reported forever.
      # ONLY THE ACCEPTED ONES: a quarantined file has landed nowhere, and deleting it
      # would be the silent loss this whole tool exists to prevent.
      foreach ($f in $accepted) { Remove-Item -LiteralPath $f.FullName -Force }
      foreach ($e in $updEmpties) { Remove-Item -LiteralPath $e.Path -Force }
      Write-Output ("no findings to merge; {0} lane(s) declared NOTHING TO FILE and were consumed." -f $emptyCount)
    } else {
      Write-Output "inbox holds $(@($accepted).Count) accepted file(s) and no findings. Nothing to merge."
    }
    if (-not $DryRun) {
      $moved = Move-ToQuarantine -Bad $bad
      if (-not $moved) { $script:MergeExit = 3; return }
    }
    Write-Output ("VERDICT: merged 0 finding(s) from 0 file(s), applied 0 update(s) from 0 file(s), quarantined {0} file(s). Exit {1}." -f @($bad).Count, $exitCode)
    $script:MergeExit = $exitCode
    return
  }

  if ($null -eq $text) { $text = Get-Content -LiteralPath $Backlog -Raw -Encoding UTF8 }
  $next = Get-NextId $text

  $block = New-Object System.Text.StringBuilder
  if (@($findings).Count -gt 0) {
    Write-Output ("MERGING {0} finding(s) from {1} inbox file(s), ids I{2} onward:" -f `
      @($findings).Count, @($accepted).Count, $next)
  }
  $i = $next
  foreach ($f in $findings) {
    Write-Output ("  I{0,-4} {1,-58} <- {2}" -f $i, $f.Title.Substring(0, [Math]::Min(58, $f.Title.Length)), $f.From)
    # LF EXPLICITLY, never AppendLine. `[FIXED 2026-09-08, measured.]` AppendLine emits
    # [Environment]::NewLine, which is CRLF on this box, and the backlog is an LF file. The
    # first real merge put 75 CRLF into 5,927 LF and NOTHING IN THIS SCRIPT NOTICED - git
    # normalises on the way in, so the commit was clean and `git diff` showed nothing. That is
    # the estate's own crlf-flip-is-invisible-in-git-diff trap, arriving through a writer.
    [void]$block.Append("`n")
    [void]$block.Append((Format-TcFindingHeading $i $f) + "`n")
    [void]$block.Append("`n")
    [void]$block.Append("**Merged from ``design\backlog-inbox\$($f.From)`` on $Today.** Written by a course agent during a parallel run; ids are allocated here because this is the only writer.`n")
    [void]$block.Append("`n")
    [void]$block.Append("$($f.Body)`n")
    $i++
  }

  $newText = $null
  if (@($allUpd).Count -gt 0) {
    Write-Output ("APPLYING {0} update(s) from {1} file(s):" -f @($allUpd).Count, @($applyFiles).Count)
    foreach ($x in $allUpd) {
      Write-Output ("  UPDATE {0,-5} {1}  <- updates/{2}" -f $x.Id, ((@($x.Tags | ForEach-Object { '`' + $_ + '`' })) -join ' '), $x.From)
    }
    $idFiles = [ordered]@{}
    foreach ($x in $allUpd) {
      if (-not $idFiles.Contains($x.Id)) { $idFiles[$x.Id] = New-Object System.Collections.ArrayList }
      if (-not $idFiles[$x.Id].Contains($x.From)) { [void]$idFiles[$x.Id].Add($x.From) }
    }
    foreach ($k in @($idFiles.Keys)) {
      if ($idFiles[$k].Count -gt 1) { Write-Output ("  {0} updated by {1} files: {2}" -f $k, $idFiles[$k].Count, ((@($idFiles[$k])) -join ', ')) }
    }
    # NO SECOND GATE RUN OVER THE COMBINED TEXT, deliberately. Every rule the gate applies is per heading or per item
    # body, an update never adds a heading, and two files reaching one item carry the identical tag set (a difference
    # was quarantined above), so each file passing alone is each item passing together. A second run could never be
    # red where the first was green, which makes it a guard no fixture can drive - the shape ops-and-gates.md calls an
    # insensitive fixture. What IS kept is the invariant below: every update that was judged also applies.
    $combined = Invoke-TcBacklogUpdates -Text $text -Updates $allUpd -Date $Today
    if (@($combined.Problems).Count -gt 0) {
      Write-Output ("COULD NOT EVALUATE - {0} update(s) that applied alone would not apply together, so nothing was written, consumed or quarantined:" -f @($combined.Problems).Count)
      foreach ($pr in @($combined.Problems)) { Write-Output ("    " + $pr.From + ": UPDATE " + $pr.Id + " " + $pr.Why) }
      $script:MergeExit = 3
      return
    }
    $newText = $combined.Text + $block.ToString()
  }

  if ($DryRun) {
    Write-Output ''
    Write-Output "-DryRun: nothing written, inbox untouched, nothing quarantined."
    Write-Output ("VERDICT: {0} finding(s) would merge, {1} update(s) would apply, {2} file(s) would be quarantined. Exit {3}." -f @($findings).Count, @($allUpd).Count, @($bad).Count, $exitCode)
    $script:MergeExit = $exitCode
    return
  }

  if ($null -ne $newText) {
    # COMPARE, THEN SWAP. The lock keeps other MERGES out, not a person or a lane editing the file by hand, so the bytes
    # this judged are checked unchanged before a whole-file replace could silently throw an edit away.
    $nowBytes = [IO.File]::ReadAllBytes($Backlog)
    if ((Get-TcSha256Hex $nowBytes) -ne (Get-TcSha256Hex $bytes)) {
      Write-Output "COULD NOT EVALUATE - the backlog changed on disk while this merge was judging it, so an in-place rewrite would throw that change away. Nothing was written, consumed or quarantined. Re-run the merge."
      $script:MergeExit = 3
      return
    }
    try {
      $null = Write-TcAtomicFile -Path $Backlog -Text $newText -NoNewline -NoBom:(-not $hasBom)
    } catch {
      Write-Output ("COULD NOT EVALUATE - the updated backlog could not be written, and the old one is intact. Nothing was consumed or quarantined: " + $_.Exception.Message)
      $script:MergeExit = 3
      return
    }
  } else {
    # NOT Add-Content: it appends [Environment]::NewLine after the value on top of whatever the
    # value already ends with. AppendAllText writes exactly the bytes given, and the explicit
    # UTF8Encoding($false) is the no-BOM form the workspace CLAUDE.md prescribes.
    [IO.File]::AppendAllText($Backlog, $block.ToString(), (New-Object Text.UTF8Encoding($false)))
  }
  # The inbox is emptied only after a successful write, so a crash re-runs cleanly
  # rather than losing the findings - the failure this whole script exists for. ONLY THE
  # ACCEPTED FILES: a quarantined file has landed nowhere and is never deleted, and an UPDATE
  # file the gate could not judge stays where it is.
  foreach ($f in $accepted) { Remove-Item -LiteralPath $f.FullName -Force }
  foreach ($u in $applyFiles) { Remove-Item -LiteralPath $u.Path -Force }
  foreach ($e in $updEmpties) { Remove-Item -LiteralPath $e.Path -Force }

  $moved = Move-ToQuarantine -Bad $bad
  if (-not $moved) { $script:MergeExit = 3; return }

  Write-Output ''
  $emptyNote = if ((@($empties).Count + @($updEmpties).Count) -gt 0) { ", plus {0} lane(s) declaring NOTHING TO FILE" -f (@($empties).Count + @($updEmpties).Count) } else { '' }
  Write-Output ("merged {0} finding(s) and applied {1} update(s){2}. Run ops\audit-backlog-status.ps1 to confirm the states." -f @($findings).Count, @($allUpd).Count, $emptyNote)
  if (@($bad).Count -gt 0) {
    Write-Output ("{0} inbox file(s) were QUARANTINED into {1} or {2} and were NOT merged. Fix each one, move it back, and re-run." -f @($bad).Count, $qRoot, $qUpd)
  }
  # THE TRAILER, for whoever commits this merge: paths below design\backlog-inbox\, forward slashes, as git names them.
  $trail = @(@($findings | ForEach-Object { $_.From } | Select-Object -Unique) + @($applyFiles | ForEach-Object { 'updates/' + $_.Name }))
  # A merge that did not run as the allocator says why on the same line (W3.4a, D17), so the commit carrying it shows it.
  $handTail = if ($script:HandMergeReason) { '; hand-merge: ' + $script:HandMergeReason } else { '' }
  Write-Output ("Backlog-Merged-From: " + ($trail -join ', ') + $handTail)
  Write-Output ("VERDICT: merged {0} finding(s) from {1} file(s), applied {2} update(s) from {3} file(s), quarantined {4} file(s). Exit {5}." -f @($findings).Count, @($accepted).Count, @($allUpd).Count, @($applyFiles).Count, @($bad).Count, $exitCode)
  $script:MergeExit = $exitCode
}

if ($Today -notmatch '^\d{4}-\d{2}-\d{2}$') {
  Write-Output "COULD NOT EVALUATE - -Today must be a date written yyyy-MM-dd; it was '$Today'."
  Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
  exit 3
}
if (-not (Test-Path -LiteralPath $Backlog)) {
  Write-Output "COULD NOT EVALUATE - no backlog at $Backlog."
  Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
  exit 3
}

# ONE ALLOCATOR (W3.4a, D17; the header says why). Decided BEFORE the lock and before the inbox is listed, so a refused
# merge reads, writes and consumes nothing. A dry run writes nothing and is never judged.
$script:HandMergeReason = ''
if (-not $DryRun) {
  $alloc = Get-TcBacklogAllocator -BacklogPath $Backlog
  $handAsked = $PSBoundParameters.ContainsKey('AllowHandMerge')
  $handWhy = (([string]$AllowHandMerge) -replace '\s+', ' ').Trim()
  if ($handAsked -and -not $handWhy) {
    Write-Output "REFUSED - -AllowHandMerge was passed with no reason. A hand merge names why it is not waiting for the $ALLOCATOR_TASK task, and that reason lands in its Backlog-Merged-From trailer. Nothing was read, written or consumed."
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit 1
  }
  if ($alloc.IsCopy -and $alloc.Blind) {
    Write-Output ("COULD NOT EVALUATE - {0} is a checkout's backlog, but whether that checkout is the allocator could not be read ({1}). Nothing was read, written or consumed." -f $Backlog, $alloc.Why)
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit 3
  }
  if ($alloc.IsCopy -and $alloc.IsAllocator) {
    Write-Output ("allocator: {0} is the {1} task's own worktree, the one writer that allocates ids (D17)." -f $alloc.Root, $ALLOCATOR_TASK)
    if ($handAsked) { $script:HandMergeReason = $handWhy }
  } elseif ($alloc.IsCopy -and $handAsked) {
    $script:HandMergeReason = $handWhy
    Write-Output ("HAND MERGE (-AllowHandMerge): {0}. {1} is not the allocator's worktree; the reason goes into the Backlog-Merged-From trailer." -f $handWhy, $alloc.Root)
  } elseif ($alloc.IsCopy -and @($alloc.Live).Count -gt 0) {
    Write-Output ("REFUSED - {0} is not the allocator. The {1} task's worktree ({2}) is the one writer that allocates backlog ids and applies UPDATEs (Brad's ruling D17, 2026-09-23): a merge here would mint ids from its own copy and collide with it on the next rebase. Run the task instead, which uses the same worktree and lands through push-main:" -f $alloc.Root, $ALLOCATOR_TASK, (@($alloc.Live) -join ', '))
    Write-Output ("  Start-ScheduledTask -TaskName '{0}'" -f $ALLOCATOR_TASK)
    Write-Output '  A deliberate hand merge passes -AllowHandMerge "<reason>", and the reason is printed in its trailer. Nothing was read, written or consumed.'
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit 1
  } elseif ($alloc.IsCopy) {
    $script:HandMergeReason = $NO_ALLOCATOR_REASON
    Write-Output ("WARN - no {0} allocator is live on this box (no worktree under the shared .git holds a live {1} marker), so this merge in {2} proceeds exactly as it did before D17 and says so in its trailer. Once the task has run, a merge here needs -AllowHandMerge." -f $ALLOCATOR_TASK, $ALLOCATOR_MARKER, $alloc.Root)
  }
}

if (-not (Test-Path -LiteralPath $InboxDir)) {
  Write-Output "inbox directory does not exist yet: $InboxDir. Nothing to merge."
  Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
  exit 0
}

# ONE MERGE AT A TIME ON ONE BACKLOG. The lock is taken before the inbox is even listed, so two merges can never both
# read the same drop file, and it is held until every accepted file is consumed. A dry run writes nothing and takes none.
$mergeLock = $null
if (-not $DryRun) {
  try {
    $mergeLock = Enter-TcLedgerLock -Path $Backlog -TimeoutMs ([Math]::Max(0, $LockWaitSec) * 1000)
  } catch {
    Write-Output ("COULD NOT EVALUATE - another merge holds the ledger lock on {0} and did not let go within {1} s, so this run merged, consumed and quarantined NOTHING. Re-run it once that merge has finished. ({2})" -f $Backlog, $LockWaitSec, $_.Exception.Message)
    Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
    exit 3
  }
}
$script:MergeExit = 3
$script:MbiScratch = ''
try {
  Invoke-TcMerge
} finally {
  Exit-TcLedgerLock $mergeLock
  if ($script:MbiScratch) { Remove-Item -LiteralPath $script:MbiScratch -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Output 'MERGE-BACKLOG-INBOX-COMPLETE'
exit $script:MergeExit
