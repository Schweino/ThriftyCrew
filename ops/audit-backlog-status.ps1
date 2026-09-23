<#
  audit-backlog-status.ps1 - every backlog item declares one state, from a closed vocabulary.

  SCOPE OF A CLEAN REPORT: SOUND over the heading LINE, unsound over everything else. Every
    `### <ID> - <title>` heading in the file is read, so a clean state report really does mean
    no heading of that SHAPE is malformed. It is blind to a heading that is not of that shape -
    which is not hypothetical: I71 and I72 sat outside the pattern from the day they were filed
    and were absent from every board count until 2026-09-08.

  WHY THIS EXISTS (2026-09-07). Brad read the seventeen unfinished items in
  `design\BACKLOG-course-findings.md` and asked whether the ones deliberately not being worked should
  be marked closed. The ledger could not answer, because `OPEN` was carrying three situations at once:

    * work nobody has started
    * a decision waiting on Brad
    * a measurement whose own conclusion was "do not build this"

  That is I11's defect one floor up - one label, more than one meaning - and it costs the same thing:
  a list that looks like a to-do list and is not one. Five states now, with a precedence, so an item
  that is half built AND blocked on a ruling reads NEEDS A RULING rather than hiding behind PARTLY
  DONE. The legend at the head of the ledger is the authority; this file enforces it.

  WHAT IT CHECKS. Every `### <ID> - <title>` heading carries EXACTLY ONE backticked tag whose base is
  in the vocabulary. Zero is an item with no state. Two is ambiguity, and it is a real risk here
  because a title may itself contain backticked filenames (`### E7 - `.worktreeinclude` `DONE``) and
  because a status is followed by a commit hash and a queue tag.

  -Summary prints the board grouped by state and exits 0 whatever it finds. That is the point of the
  thing: "what is open for me" should be a command, not a reading exercise.

  THE SECOND AND THIRD FIELDS (2026-09-08). The five states record WHOSE MOVE an item is. They record
  nothing about what it costs to be wrong, and nothing about what its first step actually does - and
  BOTH of those signals were living in the free text after the state, where they were miscounted
  twice. `decision-craft/applies-here.md` 1 has the account: two careful readers scanning this same
  file for "what is the first rung" got 16 of 33 and 17 of 30, and neither had stated its test. That
  is I11's defect - one label, more than one meaning - two floors up, and prose is where it hides.

  So every NOT-CLOSED heading now carries two more backticked tags, and this file reads them:

    * REVERSIBILITY, of the FIRST RUNG, not of the whole item: `2-WAY` or `1-WAY`. A two-way door
      produces a file that can be deleted and costs the time it took; it is never blocked on a
      ruling. A one-way door spends money, GPU hours, a reader-facing change on a live paid site, a
      remote write, a member-data pull, or sets a precedent that gets quoted afterwards.
    * FIRST-RUNG TYPE: `RUNG1 <READ|MEASURE|DOC|BUILD|RULING|BLOCKED>`. READ reads bytes already on
      disk or in git. MEASURE runs something to get a number and writes no tracked file. DOC is text
      only - a comment, a header line, a convention. BUILD ships code. RULING means nothing proceeds
      until Brad decides. BLOCKED waits on another item or an outside party.

  A DONE or PARKED heading needs neither: the axes exist to sort a queue, and a closed item is not in
  one. Requiring them there would have meant re-reading 62 finished items to fill in a field nobody
  would ever sort on, which is the same make-work this audit exists to prevent.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  -Backlog <path> JUDGES ANOTHER COPY (2026-09-23, W3.1 of design\PLAN-push-derived-conflicts-2026-09-23.md).
  ops\merge-backlog-inbox.ps1 applies a lane's `## UPDATE <id>` block to a TEMP copy of the ledger and runs this
  gate over that copy before it writes anything, so an update that would turn this gate red is quarantined instead
  of landing. That is the gate's own rules judging the change, not a second copy of them in the merge. With no
  -Backlog this reads design\BACKLOG-course-findings.md exactly as before, which is how run-gates calls it.

  -Summary OVERLAYS PENDING UPDATES (same change). Progress on an existing item is now filed as an UPDATE under
  design\backlog-inbox\updates\ and waits there until the merge runs, so a board read from the ledger alone would
  show the item's OLD state for that wait. -Summary reads every pending UPDATE (Get-TcPendingUpdates) and prints the
  item under its NEW state, marked `(pending inbox: <file>)`. Two files giving one item different tag spans are
  shown under the CURRENT state and marked as a conflict, because the merge quarantines both and settles nothing by
  order. -InboxDir names another drop box, for the fixtures. THE GATE MODE IS UNCHANGED: without -Summary it judges
  only the ledger file, and a pending update, well formed or not, never moves its verdict.

  Self-test: powershell -File ops\audit-backlog-status.ps1 -SelfTest
#>
# Declared inputs of its -SelfTest (2026-09-23, lib\gate-input-key.ps1). The suite writes every ledger and drop box it
# judges into a per-run temp directory and re-enters this file in-process; guard-contract is the one library it loads.
# gate-inputs: ops\audit-backlog-status.ps1, lib\guard-contract.ps1
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [switch]$Summary, [string]$Backlog = '', [string]$InboxDir = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

# PowerShell LOCATION semantics for a relative -Backlog or -InboxDir, the way Set-Content would resolve it.
$LEDGER = if ($Backlog) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Backlog) } else { Join-Path $repo 'design\BACKLOG-course-findings.md' }
$INBOX  = if ($InboxDir) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InboxDir) } else { Join-Path $repo 'design\backlog-inbox' }

# THE CLOSED VOCABULARY, in precedence order. Longest first matters: 'PARTLY DONE' has to be tested
# before 'DONE' or every PARTLY DONE would read as a DONE with odd leading text.
$STATES = @('DONE', 'PARKED', 'NEEDS A RULING', 'PARTLY DONE', 'OPEN')

# The two states that are somebody's move, and therefore the ones that owe the sorting fields.
$OPEN_STATES = @('NEEDS A RULING', 'PARTLY DONE', 'OPEN')

# The two closed vocabularies for the sorting axes. Closed on purpose: a free-text reversibility is
# the defect this change exists to remove, not a smaller version of it.
$REVERSIBILITY = @('2-WAY', '1-WAY')
$RUNG_TYPES    = @('READ', 'MEASURE', 'DOC', 'BUILD', 'RULING', 'BLOCKED')

function Get-TcItemState {
  <# The state a heading declares, or a reason it declares none. Pure, so the fixtures drive it with
     synthetic headings rather than with today's ledger.

     Returns @{ Id; State; Detail; Problem }. Problem is '' when the heading is well formed. #>
  param([string]$Heading)
  if ($Heading -notmatch '^###\s+([A-Z][0-9]+)\s+-\s') { return $null }   # not an item heading
  $id = $Matches[1]
  $tags = @([regex]::Matches($Heading, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value })

  # THE SORTING AXES, read before the state so every return path carries them.
  # WRAP THE PIPELINE ITSELF, do not assign first. `$x = $t | Where-Object {...}` with no match sets
  # $x to $null, and `@($null).Count` is 1 - so a MISSING field would count as one PRESENT field and
  # the must-fire below would never fire. [[ps-null-count-is-one]]
  $revHits  = @($tags | Where-Object { $REVERSIBILITY -contains $_ })
  $rungHits = @($tags | Where-Object { $_ -match '^RUNG1\s+(\S+)$' } | ForEach-Object { ($_ -split '\s+', 2)[1] })

  $found = @()
  foreach ($tag in $tags) {
    foreach ($s in ($STATES | Sort-Object { - $_.Length })) {
      # A tag is a state when it IS the state or begins 'STATE - ' / 'STATE <date>'. A filename that
      # merely contains the word (`done-notes.md`) must not count, which is what the boundary buys.
      if ($tag -eq $s -or $tag -match ('^' + [regex]::Escape($s) + '(\s+-\s+|\s+\d{4}-)')) {
        $found += [pscustomobject]@{ State = $s; Tag = $tag }
        break
      }
    }
  }
  $rev  = if ($revHits.Count -eq 1) { $revHits[0] } else { '' }
  $rung = if ($rungHits.Count -eq 1) { $rungHits[0] } else { '' }

  if ($found.Count -eq 0) {
    return [pscustomobject]@{ Id = $id; State = ''; Detail = ''; Reversibility = $rev; Rung = $rung
      Problem = "declares no state. Give it one of: $($STATES -join ', ')" }
  }
  if ($found.Count -gt 1) {
    return [pscustomobject]@{ Id = $id; State = ''; Detail = ''; Reversibility = $rev; Rung = $rung
      Problem = ("declares {0} states ({1}). One heading, one state." -f $found.Count, (($found | ForEach-Object { $_.State }) -join ' + ')) }
  }
  $state  = $found[0].State
  $detail = $found[0].Tag.Substring($state.Length).TrimStart(' ', '-').Trim()

  # THE SORTING FIELDS ARE OWED BY THE OPEN STATES ONLY, and each is owed exactly once. Two
  # reversibility tags is the same ambiguity as two states: one of them is a lie.
  $axis = ''
  if ($OPEN_STATES -contains $state) {
    if     ($revHits.Count -eq 0)  { $axis = "declares no reversibility. Add one of: $($REVERSIBILITY -join ', ') - it is the FIRST RUNG that is being classified, not the whole item" }
    elseif ($revHits.Count -gt 1)  { $axis = ("declares {0} reversibilities ({1}). One heading, one." -f $revHits.Count, ($revHits -join ' + ')) }
    elseif ($rungHits.Count -eq 0) { $axis = "declares no first-rung type. Add ``RUNG1 <$($RUNG_TYPES -join '|')>``" }
    elseif ($rungHits.Count -gt 1) { $axis = ("declares {0} first-rung types ({1}). One heading, one." -f $rungHits.Count, ($rungHits -join ' + ')) }
    elseif ($RUNG_TYPES -notcontains $rung) { $axis = ("first-rung type '{0}' is not in the vocabulary ({1})." -f $rung, ($RUNG_TYPES -join ', ')) }
  }
  return [pscustomobject]@{ Id = $id; State = $state; Detail = $detail
    Reversibility = $rev; Rung = $rung; Problem = $axis }
}

function Get-TcLedgerStates {
  <# One record per item heading. `,@()` so a single result does not unroll to a bare object, and
     CALLERS MUST ASSIGN BEFORE WRAPPING. [[ps-json-array-collapse]] #>
  param([string[]]$Lines)
  $out = @()
  foreach ($ln in @($Lines)) {
    $r = Get-TcItemState $ln
    if ($null -ne $r) { $out += $r }
  }
  return ,@($out)
}

function Get-TcBlockRecheck {
  <# Does an externally-blocked item say how to re-test its block? Pure over one item's body, so the
     fixtures drive it with synthetic text rather than with today's ledger.

     Returns '' when the item is fine, or the reason it is not.

     A BLOCK IS A CLAIM ABOUT THE OUTSIDE WORLD, AND THE OUTSIDE WORLD MOVES. Measured 2026-09-09:
     three items recorded as blocked on an external system had all quietly unblocked - a server that
     only needed starting, a console that had been readable for two days, an API the estate already
     held a credential for. Every one was found by ATTEMPTING the thing, and the note is what the next
     session reads instead.

     NOT A TIMER, and that is deliberate: all three were written that same morning, so any age-based
     expiry would have passed them. The property that is actually checkable is whether the item names
     the one command or observation that settles it.

     WAITING ON BRAD IS OUT OF SCOPE. A ruling is not re-testable by running anything, so RUNG1 RULING
     items are exempt - and that exemption is what stops this being red on items nobody can unblock. #>
  param([string]$State, [string]$Detail, [string]$Rung, [string]$Body)
  if ($OPEN_STATES -notcontains $State) { return '' }
  if ($Rung -eq 'RULING') { return '' }
  $waits = ($Rung -eq 'BLOCKED') -or ($Detail -match '(?i)\bBLOCKED\b|\bWAIT(S|ING)?\b|NEEDS A RUN|OUTSTANDING|IS DOWN|DISPATCH')
  if (-not $waits) { return '' }
  if ($Body -match '(?m)^\s*\*\*RE-CHECK:\*\*') { return '' }
  return ("waits on something outside this machine but states no RE-CHECK. Add a line beginning " +
          "'**RE-CHECK:**' naming the one command or observation that settles whether the block still " +
          "holds - a block written once and never re-tested is how three of these went stale on " +
          "2026-09-09 without anyone noticing.")
}

function Get-TcPendingUpdates {
  <# The `## UPDATE <id>` blocks ONE updates\ drop file carries, for -Summary's overlay. Pure over the file's name
     and text, so the fixtures drive it without a disk.

     Returns one record per block: Id, File, Tags (the backticked spans of the next non-empty line) and Readable.
     A block whose next non-empty line is not a line of backticked spans is Readable = $false: the merge will
     quarantine that file, and the board says so rather than guessing at a state.

     THE SAME TWO RULES THE MERGE READS WITH, and only those two: the heading is `## UPDATE <id>` at column 0 with
     the id pattern [A-Z]+[0-9]+, and the tag line is the next non-empty line. Whether the update would PASS is not
     decided here; the merge decides that by running this file's gate mode over a temp copy. #>
  param([string]$Name, [string]$Text)
  $out = @()
  $lines = ([string]$Text -replace ('^' + [string][char]0xFEFF), '') -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -notmatch '^##[ \t]+UPDATE[ \t]+([A-Z]+[0-9]+)[ \t]*$') { continue }
    $id = $Matches[1]
    $tagLine = ''
    for ($j = $i + 1; $j -lt $lines.Count; $j++) { if ($lines[$j].Trim()) { $tagLine = $lines[$j]; break } }
    $tags = @([regex]::Matches($tagLine, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value.Trim() })
    $readable = ($tags.Count -gt 0) -and ($tagLine -match '^\s*(`[^`]+`\s*)+$')
    $out += [pscustomobject]@{ Id = $id; File = $Name; Tags = $tags; Readable = $readable }
  }
  return ,@($out)
}

function Get-TcPendingOverlay {
  <# Folds the pending UPDATE records into the ledger's item records for -Summary. Pure over both lists.
     Returns Items (every ledger item, each with a Pending note, '' when nothing is pending for it) and Orphans
     (the lines to print for pending blocks that name no item in the ledger).

     An item with ONE agreed tag set pending is shown with the state, detail and axes that tag set gives it, read by
     Get-TcItemState over a heading built from those tags. An item with two DIFFERENT tag sets pending keeps its
     current state and is marked CONFLICT, because the merge quarantines both files and settles nothing by order.
     An unreadable block keeps the current state too, and says so. #>
  param([object[]]$Items, [object[]]$Pending)
  $byId = @{}
  foreach ($p in @($Pending)) {
    if (-not $byId.ContainsKey($p.Id)) { $byId[$p.Id] = New-Object System.Collections.ArrayList }
    [void]$byId[$p.Id].Add($p)
  }
  $known = @{}
  $outItems = @()
  foreach ($it in @($Items)) {
    $known[$it.Id] = $true
    $note = ''
    $rec = $it
    if ($byId.ContainsKey($it.Id)) {
      $ps = @($byId[$it.Id])
      $files = (@($ps | ForEach-Object { $_.File } | Select-Object -Unique)) -join ', '
      $unread = @($ps | Where-Object { -not $_.Readable })
      # ORDINAL, because `DONE` and `done` are two different headings, and a culture-sensitive default would call
      # them one tag set and hide a conflict the merge will refuse.
      $keySet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
      foreach ($p2 in $ps) { if ($p2.Readable) { [void]$keySet.Add(($p2.Tags -join [string][char]31)) } }
      if ($unread.Count) {
        $note = "(pending inbox: $files - UNREADABLE, the merge will quarantine it)"
      } elseif ($keySet.Count -gt 1) {
        $note = "(pending inbox: CONFLICT $files - the merge quarantines both and settles nothing by order)"
      } else {
        $spans = (@($ps[0].Tags | ForEach-Object { '`' + $_ + '`' })) -join ' '
        $ov = Get-TcItemState ('### ' + $it.Id + ' - pending ' + $spans)
        if ($null -ne $ov -and $ov.State) {
          $rec = [pscustomobject]@{ Id = $it.Id; State = $ov.State; Detail = $ov.Detail
            Reversibility = $ov.Reversibility; Rung = $ov.Rung; Problem = $ov.Problem }
          $note = "(pending inbox: $files)"
        } else {
          $note = "(pending inbox: $files - its tag line declares no state the gate accepts, so the merge will quarantine it)"
        }
      }
    }
    $outItems += [pscustomobject]@{ Id = $rec.Id; State = $rec.State; Detail = $rec.Detail
      Reversibility = $rec.Reversibility; Rung = $rec.Rung; Problem = $rec.Problem; Pending = $note }
  }
  $orphans = @()
  foreach ($k in @($byId.Keys | Sort-Object)) {
    if ($known.ContainsKey($k)) { continue }
    $files = (@($byId[$k] | ForEach-Object { $_.File } | Select-Object -Unique)) -join ', '
    $orphans += ("  {0,-4} (pending inbox: {1} - names no item in this ledger, so the merge will quarantine it)" -f $k, $files)
  }
  return [pscustomobject]@{ Items = $outItems; Orphans = $orphans }
}

function Get-TcPendingUpdateFiles {
  <# The pending UPDATE drop files under <inbox>\updates, as (Name, Text) pairs in ordinal name order. The same
     skip rule as the merge: README.md and _*.md are documentation, never updates. Absent directory, none pending. #>
  param([string]$Inbox)
  $dir = Join-Path $Inbox 'updates'
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return ,@() }
  $names = @(Get-ChildItem -LiteralPath $dir -Filter *.md -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -ne 'README.md' -and $_.Name -notlike '_*' } | ForEach-Object { $_.Name })
  $sorted = [string[]]$names
  [Array]::Sort($sorted, [StringComparer]::Ordinal)
  $out = @()
  foreach ($n in $sorted) {
    $out += [pscustomobject]@{ Name = $n; Text = [IO.File]::ReadAllText((Join-Path $dir $n)) }
  }
  return ,@($out)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0; $n = 0
  function T($m, $cond, $got) { $script:n++; if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  # ---- A BLOCK MUST SAY HOW TO RE-TEST ITSELF (2026-09-09) ----------------------------------------
  # MUST FIRE: the founding shape. I44 as it stood this morning - blocked on Google, no way stated to
  # ask Google, so "is it still blocked?" cost archaeology every time somebody wondered.
  T 'MUST FIRE  an externally blocked item with no RE-CHECK is flagged' `
    ((Get-TcBlockRecheck 'PARTLY DONE' 'ONLY GOOGLE''S RE-CRAWL VERDICT IS OUTSTANDING' 'BLOCKED' 'body with no marker') -ne '') 'passed'
  T 'MUST FIRE  the wait can be in the DETAIL rather than the rung - I61 said THE RUN NEEDS A SERVER THAT IS DOWN' `
    ((Get-TcBlockRecheck 'PARTLY DONE' 'INSTRUMENTED; THE RUN NEEDS A SERVER THAT IS DOWN' 'MEASURE' 'no marker') -ne '') 'passed'
  # MUST NOT FIRE: the same item once it states the command that settles it.
  T 'MUST NOT FIRE  a stated RE-CHECK satisfies it' `
    ((Get-TcBlockRecheck 'PARTLY DONE' 'ONLY GOOGLE''S VERDICT IS OUTSTANDING' 'BLOCKED' ("x`n**RE-CHECK:** run the inspector`ny")) -eq '') 'flagged'
  # MUST NOT FIRE: waiting on BRAD is a ruling, not a block - no command re-tests a decision.
  T 'MUST NOT FIRE  a RULING waiting on Brad owes no re-check' `
    ((Get-TcBlockRecheck 'PARTLY DONE' 'THE SPEND DECISION IS STILL BRAD''S' 'RULING' 'no marker') -eq '') 'flagged'
  # MUST NOT FIRE: an item that waits on nothing.
  T 'MUST NOT FIRE  an ordinary open item owes no re-check' `
    ((Get-TcBlockRecheck 'OPEN' 'RUNG 1 IS A MEASUREMENT' 'MEASURE' 'no marker') -eq '') 'flagged'
  # MUST NOT FIRE: a CLOSED item keeps its history without owing anything.
  T 'MUST NOT FIRE  a DONE item that once said BLOCKED is not re-flagged' `
    ((Get-TcBlockRecheck 'DONE' 'WAS BLOCKED, NOW MEASURED' 'BLOCKED' 'no marker') -eq '') 'flagged'

  # EVERY FIXTURE IS A SINGLE-QUOTED LITERAL with doubled inner quotes. Built by concatenation they
  # would be three positional arguments, not one string - the trap that let two of
  # audit-fixture-vocabulary's own cases pass on a fragment (2026-09-07).
  $r = Get-TcItemState '### I9 - The Python tree is not a package `PARKED - MEASUREMENT ONLY, NO WORK PROPOSED` `queue-2`'
  T 'MUST FIRE  a state with free text after it is read as that state, and the text is kept' `
    (($r.State -eq 'PARKED') -and ($r.Detail -like 'MEASUREMENT ONLY*')) ($r.State + ' / ' + $r.Detail)
  $r2 = Get-TcItemState '### E1 - The estate takes irreversible actions with no safety layer `PARTLY DONE` `723be4ad`'
  T 'MUST FIRE  PARTLY DONE is not read as DONE, and a commit hash beside it is not a state' `
    ($r2.State -eq 'PARTLY DONE') ($r2.State + ' problem=' + $r2.Problem)
  $r3 = Get-TcItemState '### I30 - Eighteen live tables carry 28 indexes `NEEDS A RULING - THE AUDIT IS SPECIFIED AND NOT ORDERED` `queue-3`'
  T 'MUST FIRE  a multi-word state is matched whole' ($r3.State -eq 'NEEDS A RULING') $r3.State

  # MUST NOT FIRE - the shapes that must be accepted or ignored, not flagged.
  $r4 = Get-TcItemState '### E7 - `.worktreeinclude` `DONE` `4e8102c2`'
  T 'MUST NOT FIRE  THE ONE THAT MADE THIS PARSER NECESSARY - a title containing its own backticked filename still resolves to ONE state' `
    (($r4.State -eq 'DONE') -and ($r4.Problem -eq '')) ($r4.State + ' problem=' + $r4.Problem)
  $r5 = Get-TcItemState '### I11 - The vocabulary `DONE 2026-09-07` `queue-2`'
  T 'MUST NOT FIRE  a dated state is the same state, not an unknown one' `
    (($r5.State -eq 'DONE') -and ($r5.Problem -eq '')) ($r5.State + ' problem=' + $r5.Problem)
  T 'MUST NOT FIRE  a section heading that is not an item is skipped entirely, not reported stateless' `
    ($null -eq (Get-TcItemState '### Triage of I8-I27, 2026-09-07')) 'a prose heading was treated as an item'
  # ADDED 2026-09-09 BY A MUTATION PROBE (backlog I37), which is the only reason this gap was found.
  # Dropping the `^` anchor from the heading pattern left the whole suite GREEN: no case asserted that
  # a `###` has to start the LINE. Prose and code blocks in this ledger quote item headings inline all
  # the time, and every one of them would have been parsed as a real item - inflating the board and,
  # worse, reporting a quoted heading as declaring no state.
  T 'MUST NOT FIRE  a heading quoted MID-LINE is not an item - the pattern is anchored at line start' `
    ($null -eq (Get-TcItemState 'see ### I31 - the LLM cost item `OPEN` for the shape')) `
    'an inline mention of a heading was parsed as a real item'
  T 'MUST NOT FIRE  and the same inside a fenced code block, which this ledger uses for commands' `
    ($null -eq (Get-TcItemState '    ### I82 - lifted functions `OPEN` `2-WAY` `RUNG1 BUILD`')) `
    'an indented code-block line was parsed as a real item'
  $r6 = Get-TcItemState '### E5 - Validate at source `PARKED - SEE done-notes.md FOR WHY` `queue-2`'
  T 'MUST NOT FIRE  a filename containing a state word inside the SAME tag does not add a second state' `
    (($r6.State -eq 'PARKED') -and ($r6.Problem -eq '')) ($r6.State + ' problem=' + $r6.Problem)

  # MUST FIRE - the two malformed shapes.
  $b1 = Get-TcItemState '### E44 - An item nobody gave a state `queue-2`'
  T 'MUST FIRE  a heading with no state is a finding' ($b1.Problem -like 'declares no state*') $b1.Problem
  $b2 = Get-TcItemState '### E45 - An item claiming two `DONE` `OPEN`'
  T 'MUST FIRE  a heading declaring two states is a finding, because one of them is a lie' `
    ($b2.Problem -like 'declares 2 states*') $b2.Problem

  # ------- THE SORTING AXES (2026-09-08). Every fixture is a single-quoted literal, one argument.
  $s1 = Get-TcItemState '### I33 - fifteen days of latency history `OPEN - RUNG 1 IS A READ` `queue-4` `2-WAY` `RUNG1 READ`'
  T 'MUST NOT FIRE  an OPEN heading carrying both axes is clean, and both values come back' `
    (($s1.Problem -eq '') -and ($s1.Reversibility -eq '2-WAY') -and ($s1.Rung -eq 'READ')) `
    ($s1.Reversibility + '/' + $s1.Rung + ' problem=' + $s1.Problem)

  $s2 = Get-TcItemState '### I37 - a self-test nobody mutated `OPEN` `queue-4`'
  T 'MUST FIRE  THE FOUNDING BUG - an OPEN item with no reversibility is the untriaged shape this change exists to end' `
    ($s2.Problem -like 'declares no reversibility*') ("problem='" + $s2.Problem + "'")

  $s3 = Get-TcItemState '### I37 - a self-test nobody mutated `OPEN` `queue-4` `2-WAY`'
  T 'MUST FIRE  reversibility alone is not enough; the first-rung type is owed too' `
    ($s3.Problem -like 'declares no first-rung type*') ("problem='" + $s3.Problem + "'")

  $s4 = Get-TcItemState '### I37 - a self-test nobody mutated `OPEN` `2-WAY` `1-WAY` `RUNG1 READ`'
  T 'MUST FIRE  two reversibilities is the same ambiguity as two states - one of them is a lie' `
    ($s4.Problem -like 'declares 2 reversibilities*') ("problem='" + $s4.Problem + "'")

  $s5 = Get-TcItemState '### I37 - a self-test nobody mutated `OPEN` `2-WAY` `RUNG1 PONDER`'
  T 'MUST FIRE  a first-rung type outside the closed vocabulary is a finding, not a new value' `
    ($s5.Problem -like "*'PONDER' is not in the vocabulary*") ("problem='" + $s5.Problem + "'")

  $s6 = Get-TcItemState '### I9 - The Python tree is not a package `PARKED - MEASUREMENT ONLY` `queue-2`'
  T 'MUST NOT FIRE  a PARKED item owes NO axes - the fields sort a queue and a closed item is not in one' `
    ($s6.Problem -eq '') ("problem='" + $s6.Problem + "'")

  $s7 = Get-TcItemState '### E1 - the irreversible-write layer `DONE` `723be4ad`'
  T 'MUST NOT FIRE  a DONE item owes no axes either' ($s7.Problem -eq '') ("problem='" + $s7.Problem + "'")

  $s8 = Get-TcItemState '### I97 - Ghost holds every signup date `NEEDS A RULING` `queue-5` `1-WAY` `RUNG1 RULING`'
  T 'MUST NOT FIRE  NEEDS A RULING owes the axes and a one-way ruling item satisfies them' `
    (($s8.Problem -eq '') -and ($s8.Reversibility -eq '1-WAY') -and ($s8.Rung -eq 'RULING')) `
    ($s8.Reversibility + '/' + $s8.Rung + ' problem=' + $s8.Problem)

  $s9 = Get-TcItemState '### I71 - per-store pacing is static `OPEN - RUNG 1 IS A MEASUREMENT` `2-WAY` `RUNG1 MEASURE`'
  T 'CLEAN TWIN a state whose free text contains the words RUNG 1 is still parsed as the state, and the RUNG1 tag is read separately' `
    (($s9.State -eq 'OPEN') -and ($s9.Rung -eq 'MEASURE') -and ($s9.Problem -eq '')) `
    ($s9.State + '/' + $s9.Rung + ' problem=' + $s9.Problem)

  $s10 = Get-TcItemState '### I44 - the Recipe rich result `PARTLY DONE - ONLY GOOGLE''S VERDICT IS OUTSTANDING` `b3a35c7cf` `2-WAY` `RUNG1 BLOCKED`'
  T 'CLEAN TWIN THE ONE THAT MADE THE STATE PARSER NECESSARY still works with the axes beside it - a commit hash is not a reversibility' `
    (($s10.State -eq 'PARTLY DONE') -and ($s10.Reversibility -eq '2-WAY') -and ($s10.Problem -eq '')) `
    ($s10.State + '/' + $s10.Reversibility + ' problem=' + $s10.Problem)

  # CLEAN TWIN - the scanner around the predicate still walks lines and keeps only the items.
  $all = Get-TcLedgerStates -Lines @('# Title', '### E1 - a `DONE`', 'prose', '### Triage of things', '### E2 - b `OPEN`')
  T 'CLEAN TWIN the scanner keeps the two items and drops the prose and the section heading' `
    (($all.Count -eq 2) -and ($all[0].Id -eq 'E1') -and ($all[1].State -eq 'OPEN')) ("Count=" + $all.Count)
  $one = Get-TcLedgerStates -Lines @('### E1 - a `DONE`')
  T 'CLEAN TWIN a single item comes back as an ARRAY, not unrolled to one object' ($one -is [array]) ($one.GetType().FullName)

  # ------- PENDING UPDATES AND -Backlog (2026-09-23, W3.1 of design\PLAN-push-derived-conflicts-2026-09-23.md) -------
  # The UPDATE heading is built by concatenation and assigned before use: one string, one argument, and no line of this
  # source is itself a heading an inbox reader could take for a block.
  $uh = '## ' + 'UPDATE'
  $pText1 = "# lane title`n`nprose`n`n$uh I165`n``DONE`` ``queue-7```nthe body`n"
  $p1 = Get-TcPendingUpdates -Name 'lane-u.md' -Text $pText1
  $p1 = @($p1)
  T 'MUST FIRE  an UPDATE block is read as its id, its file and every tag span on the next non-empty line' `
    (($p1.Count -eq 1) -and ($p1[0].Id -eq 'I165') -and ($p1[0].File -eq 'lane-u.md') -and $p1[0].Readable -and
     (($p1[0].Tags -join '|') -eq 'DONE|queue-7')) ("count=" + $p1.Count + " tags=" + $(if ($p1.Count) { $p1[0].Tags -join '|' } else { '' }))
  $pText2 = "## a new finding`n``OPEN`` ``queue-6```n`nsee $uh I2 for the shape`n$uh I2 - with a title after it`n``DONE```n    $uh I3`n``DONE```n"
  $p2 = Get-TcPendingUpdates -Name 'lane-x.md' -Text $pText2
  $p2 = @($p2)
  T 'MUST NOT FIRE  a plain finding heading, an UPDATE quoted mid-line, one with a title after its id and an indented one are not pending updates' `
    ($p2.Count -eq 0) ("count=" + $p2.Count)
  $pText3 = "$uh I2`n`nthe tags were forgotten and this is prose`n"
  $p3 = Get-TcPendingUpdates -Name 'lane-y.md' -Text $pText3
  $p3 = @($p3)
  T 'MUST FIRE  an UPDATE whose next non-empty line is not a line of tag spans is read as UNREADABLE, never guessed at' `
    (($p3.Count -eq 1) -and (-not $p3[0].Readable)) ("count=" + $p3.Count + " readable=" + $(if ($p3.Count) { $p3[0].Readable } else { 'n/a' }))

  $ovItems = Get-TcLedgerStates -Lines @('### I2 - stray artifacts `OPEN` `queue-6` `2-WAY` `RUNG1 BUILD`', '### E7 - `.worktreeinclude` `OPEN` `queue-4` `2-WAY` `RUNG1 READ`')
  $ovOne = @([pscustomobject]@{ Id = 'I2'; File = 'lane-u.md'; Tags = @('DONE', 'queue-7'); Readable = $true })
  $ov1 = Get-TcPendingOverlay -Items $ovItems -Pending $ovOne
  $ov1i = @($ov1.Items | Where-Object { $_.Id -eq 'I2' })
  $ov1e = @($ov1.Items | Where-Object { $_.Id -eq 'E7' })
  T 'CLEAN TWIN a pending UPDATE moves its item to the NEW state and names the file it waits in; an item nothing updates keeps its state' `
    (($ov1i.Count -eq 1) -and ($ov1i[0].State -eq 'DONE') -and ($ov1i[0].Pending -match 'pending inbox: lane-u\.md') -and
     ($ov1e[0].State -eq 'OPEN') -and ($ov1e[0].Pending -eq '')) ("I2=" + $(if ($ov1i.Count) { $ov1i[0].State + ' ' + $ov1i[0].Pending } else { 'missing' }) + " E7=" + $ov1e[0].State)
  $ovTwo = @([pscustomobject]@{ Id = 'I2'; File = 'lane-a.md'; Tags = @('DONE', 'queue-7'); Readable = $true },
             [pscustomobject]@{ Id = 'I2'; File = 'lane-b.md'; Tags = @('PARKED - SUPERSEDED', 'queue-7'); Readable = $true })
  $ov2 = Get-TcPendingOverlay -Items $ovItems -Pending $ovTwo
  $ov2i = @($ov2.Items | Where-Object { $_.Id -eq 'I2' })
  T 'MUST FIRE  two files giving one item DIFFERENT tag sets keep it under its CURRENT state, marked CONFLICT with both files named' `
    (($ov2i[0].State -eq 'OPEN') -and ($ov2i[0].Pending -match 'CONFLICT') -and ($ov2i[0].Pending -match 'lane-a\.md') -and ($ov2i[0].Pending -match 'lane-b\.md')) `
    ($ov2i[0].State + ' ' + $ov2i[0].Pending)
  $ovOrphan = @([pscustomobject]@{ Id = 'I999'; File = 'lane-z.md'; Tags = @('DONE'); Readable = $true })
  $ov3 = Get-TcPendingOverlay -Items $ovItems -Pending $ovOrphan
  $ov3o = @($ov3.Orphans)
  T 'MUST FIRE  a pending UPDATE naming no item in the ledger is printed as an orphan the merge will quarantine' `
    (($ov3o.Count -eq 1) -and ($ov3o[0] -match 'I999') -and ($ov3o[0] -match 'lane-z\.md') -and ($ov3o[0] -match 'quarantine')) ("orphans=" + $ov3o.Count)

  # End to end, in a per-run temp directory removed in the finally. Each run re-enters this file in-process.
  $abt = Join-Path $env:TEMP ('abs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  try {
    New-Item -ItemType Directory -Path $abt -ErrorAction Stop | Out-Null
    $u8 = New-Object Text.UTF8Encoding($false)
    $good = Join-Path $abt 'good.md'
    [IO.File]::WriteAllText($good, "# Backlog`n`n### I2 - stray artifacts ``OPEN`` ``queue-6`` ``2-WAY`` ``RUNG1 BUILD```n`nbody`n`n### E7 - ``.worktreeinclude`` ``DONE`` ``4e8102c2```n`nbody`n`n### I40 - an old one ``DONE```n`nbody`n", $u8)
    $badL = Join-Path $abt 'bad.md'
    [IO.File]::WriteAllText($badL, "# Backlog`n`n### I2 - stray artifacts ``OPEN`` ``queue-6```n`nbody`n", $u8)
    $inbA = Join-Path $abt 'inbox'
    New-Item -ItemType Directory -Path (Join-Path $inbA 'updates') -ErrorAction Stop | Out-Null

    $oBad = & $PSCommandPath -Backlog $badL 2>&1 | Out-String
    $cBad = $LASTEXITCODE
    T 'MUST FIRE  -Backlog judges THAT file: a temp ledger with an OPEN item missing its axes exits 2 and names the item' `
      (($cBad -eq 2) -and ($oBad -match 'I2: declares no reversibility') -and ($oBad -match 'items=1 malformed=1')) ("exit $cBad :: $oBad")
    $oGood = & $PSCommandPath -Backlog $good 2>&1 | Out-String
    $cGood = $LASTEXITCODE
    T 'CLEAN TWIN -Backlog over a clean temp ledger exits 0 and counts THAT ledger''s three items, not the real one' `
      (($cGood -eq 0) -and ($oGood -match 'BACKLOG-STATUS-COMPLETE items=3 malformed=0')) ("exit $cGood :: $oGood")

    [IO.File]::WriteAllText((Join-Path $inbA 'updates\lane-bad.md'), ($uh + " I2`n``SHIPPED```n`nbody`n"), $u8)
    $oGate = & $PSCommandPath -Backlog $good -InboxDir $inbA 2>&1 | Out-String
    $cGate = $LASTEXITCODE
    T 'MUST NOT FIRE  the gate mode judges only the ledger file: a malformed PENDING update beside it does not move the verdict' `
      (($cGate -eq 0) -and ($oGate -match 'items=3 malformed=0')) ("exit $cGate :: $oGate")
    Remove-Item -LiteralPath (Join-Path $inbA 'updates\lane-bad.md') -Force

    [IO.File]::WriteAllText((Join-Path $inbA 'updates\lane-u.md'), ($uh + " I2`n``DONE`` ``queue-7```n`nfinished.`n"), $u8)
    $oSum = & $PSCommandPath -Summary -Backlog $good -InboxDir $inbA 2>&1 | Out-String
    $cSum = $LASTEXITCODE
    $sumLines = @($oSum -split "`r?`n")
    $doneAt = -1; $i2At = -1; $openHdr = ''
    for ($k = 0; $k -lt $sumLines.Count; $k++) {
      if ($sumLines[$k] -match '^DONE  \(') { $doneAt = $k }
      if ($sumLines[$k] -match '^OPEN  \(') { $openHdr = $sumLines[$k] }
      if ($sumLines[$k] -match '^\s+I2\s.*\(pending inbox: lane-u\.md\)') { $i2At = $k }
    }
    T 'CLEAN TWIN -Summary shows a pending UPDATE''s item under its NEW state, marked pending, and exits 0' `
      (($cSum -eq 0) -and ($doneAt -ge 0) -and ($i2At -gt $doneAt) -and ($openHdr -eq 'OPEN  (0)') -and ($oSum -match 'pending=1')) `
      ("exit $cSum done_at=$doneAt i2_at=$i2At open='$openHdr' :: $oSum")
  } catch {
    T 'HARNESS the end-to-end block ran to its end without throwing' $false $_.Exception.Message
  } finally {
    Remove-Item -LiteralPath $abt -Recurse -Force -ErrorAction SilentlyContinue
  }

  # A LITERAL-CASE SUITE ASSERTS HOW MANY RAN (ops-and-gates.md): a case lost to a comment, a glued line or a throw
  # is a shortfall here, never a smaller green number.
  $EXPECTED_CASES = 39
  if ($f -or $n -ne $EXPECTED_CASES) {
    Write-Output ("audit-backlog-status SELF-TEST FAIL: {0} check(s) failed, {1} of {2} case(s) ran" -f $f, $n, $EXPECTED_CASES)
    exit 1
  }
  Write-Output ("audit-backlog-status SELF-TEST PASS: {0} of {0} cases (headings and axes, block re-checks, the pending-UPDATE overlay and -Backlog)" -f $n)
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not (Test-Path -LiteralPath $LEDGER)) {
  Write-Output ("BACKLOG STATUS AUDIT BLIND: {0} does not exist, so nothing was checked." -f $LEDGER)
  Exit-Guard -Name 'backlog-status' -Summary 'blind=no-ledger' -Code 3
}
$items = Get-TcLedgerStates -Lines ([IO.File]::ReadAllLines($LEDGER))
$items = @($items)
if (-not $items.Count) {
  Write-Output 'BACKLOG STATUS AUDIT BLIND: parsed zero item headings, which means the heading format moved rather than the ledger being empty.'
  Exit-Guard -Name 'backlog-status' -Summary 'blind=no-items' -Code 3
}

if ($Summary) {
  # THE PENDING OVERLAY. Every UPDATE waiting under <inbox>\updates is shown under the state it will give its item,
  # so the board a person reads between a lane filing and the merge running is the board they are about to get.
  $pendFiles = Get-TcPendingUpdateFiles -Inbox $INBOX
  $pendFiles = @($pendFiles)
  $pending = @()
  foreach ($pf in $pendFiles) {
    $recs = Get-TcPendingUpdates -Name $pf.Name -Text $pf.Text
    $pending += @($recs)
  }
  $ov = Get-TcPendingOverlay -Items $items -Pending $pending
  $items = @($ov.Items)
  if ($pending.Count) {
    Write-Output ("{0} pending UPDATE block(s) in {1} file(s) under {2} are overlaid below. The ledger itself is unchanged until ops\merge-backlog-inbox.ps1 runs." -f $pending.Count, $pendFiles.Count, (Join-Path $INBOX 'updates'))
  }
  foreach ($o in @($ov.Orphans)) { Write-Output $o }
  foreach ($s in @('NEEDS A RULING', 'OPEN', 'PARTLY DONE', 'PARKED', 'DONE')) {
    $rows = @($items | Where-Object { $_.State -eq $s })
    Write-Output ''
    Write-Output ("{0}  ({1})" -f $s, $rows.Count)
    # The finished ones are a count, not a list - except an item a pending update is about to finish, which is the
    # one DONE row a reader needs to see before the merge makes it true.
    if ($s -eq 'DONE') { $rows = @($rows | Where-Object { $_.Pending }) }
    foreach ($r in $rows) {
      $line = ("  {0,-4} {1,-5} {2,-8} {3}" -f $r.Id, $r.Reversibility, $r.Rung, $(if ($r.Detail) { $r.Detail } else { '' }))
      if ($r.Pending) { $line = $line.TrimEnd() + ' ' + $r.Pending }
      Write-Output $line
    }
  }

  # THE REVERSIBILITY SORT, WITH ITS DENOMINATOR. A rate is printed with what it is over, always
  # (.claude/rules/measurement.md). "82% are two-way" is a mood; "56 of 68 not-closed" is the sort.
  $notClosed = @($items | Where-Object { $OPEN_STATES -contains $_.State })
  Write-Output ''
  Write-Output ("REVERSIBILITY OF THE FIRST RUNG, over the {0} not-closed item(s) of {1} in the ledger:" -f $notClosed.Count, $items.Count)
  foreach ($v in $REVERSIBILITY) {
    $n = @($notClosed | Where-Object { $_.Reversibility -eq $v }).Count
    Write-Output ("  {0,-6} {1,3} of {2}   {3}" -f $v, $n, $notClosed.Count,
      $(if ($v -eq '2-WAY') { 'does NOT wait on a ruling; it waits on somebody having time' } else { 'spends money, GPU hours, a live reader-facing change, a remote write or a precedent' }))
  }
  $blank = @($notClosed | Where-Object { -not $_.Reversibility }).Count
  if ($blank) { Write-Output ("  {0,-6} {1,3} of {2}   UNSORTED - these are the ones the audit is failing on" -f '(none)', $blank, $notClosed.Count) }

  Write-Output ''
  Write-Output ("FIRST RUNG, same {0} item(s):" -f $notClosed.Count)
  foreach ($t in $RUNG_TYPES) {
    $n = @($notClosed | Where-Object { $_.Rung -eq $t }).Count
    Write-Output ("  {0,-8} {1,3} of {2}" -f $t, $n, $notClosed.Count)
  }
  Write-Output ''
  Write-GuardComplete -Name 'backlog-status' -Summary ("items={0} notclosed={1} twoway={2} oneway={3} pending={4}" -f `
    $items.Count, $notClosed.Count,
    @($notClosed | Where-Object { $_.Reversibility -eq '2-WAY' }).Count,
    @($notClosed | Where-Object { $_.Reversibility -eq '1-WAY' }).Count,
    $pending.Count)
  exit 0
}

# ---- THE LIVE ARM OF THE RE-CHECK RULE. A helper with fixtures and no caller is a helper that
# never runs, which is what audit-guard-contract calls DEAD and what this estate has a frozen fixture
# about. The bodies are sliced here because the heading carries the state and the rung while the
# RE-CHECK lives in the prose underneath it, and the parser above only ever read headings.
$allLines = [IO.File]::ReadAllLines($LEDGER)
$bodies = @{}
$curId = ''
$buf = New-Object System.Collections.Generic.List[string]
foreach ($ln in $allLines) {
  if ($ln -match '^###\s+([A-Z][0-9]+)\s+-\s') {
    if ($curId) { $bodies[$curId] = ($buf -join "`n") }
    $curId = $Matches[1]
    $buf = New-Object System.Collections.Generic.List[string]
  } elseif ($curId) { [void]$buf.Add($ln) }
}
if ($curId) { $bodies[$curId] = ($buf -join "`n") }

$noRecheck = @()
foreach ($it in $items) {
  $body = if ($bodies.ContainsKey($it.Id)) { [string]$bodies[$it.Id] } else { '' }
  $why = Get-TcBlockRecheck $it.State $it.Detail $it.Rung $body
  if ($why) { $noRecheck += [pscustomobject]@{ Id = $it.Id; Why = $why } }
}
if ($noRecheck.Count) {
  foreach ($n in $noRecheck) { Write-Output ("  {0}: {1}" -f $n.Id, $n.Why) }
  Write-Output ("BACKLOG STATUS AUDIT FAILED: {0} item(s) wait on the outside world and do not say how to re-test that. Three blocks went stale on 2026-09-09 unnoticed; a stated RE-CHECK is what turns 'is it still blocked?' into one command." -f $noRecheck.Count)
  Exit-Guard -Name 'backlog-status' -Summary ("items={0} norecheck={1}" -f $items.Count, $noRecheck.Count) -Code 2
}

$bad = @($items | Where-Object { $_.Problem })
foreach ($b in $bad) { Write-Output ("  {0}: {1}" -f $b.Id, $b.Problem) }
if ($bad.Count) {
  Write-Output ("BACKLOG STATUS AUDIT FAILED: {0} item(s) of {1} are malformed - each either does not declare exactly one state from the closed vocabulary ({2}), or is a not-closed item missing one of the two sorting fields (`2-WAY`/`1-WAY`, and ``RUNG1 <{3}>``). The legend at the head of design\BACKLOG-course-findings.md says what each one means and which wins when two could apply." -f $bad.Count, $items.Count, ($STATES -join ', '), ($RUNG_TYPES -join '|'))
  Exit-Guard -Name 'backlog-status' -Summary ("items={0} malformed={1}" -f $items.Count, $bad.Count) -Code 2
}
$byState = ($STATES | ForEach-Object { $s = $_; ("{0} {1}" -f @($items | Where-Object { $_.State -eq $s }).Count, $s) }) -join ', '
Write-Output ("backlog-status: PASSED - all {0} item(s) declare exactly one state. {1}. Run with -Summary for the board." -f $items.Count, $byState)
Exit-Guard -Name 'backlog-status' -Summary ("items={0} malformed=0" -f $items.Count) -Code 0
