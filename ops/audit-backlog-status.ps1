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

  Self-test: powershell -File ops\audit-backlog-status.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [switch]$Summary)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$LEDGER = Join-Path $repo 'design\BACKLOG-course-findings.md'

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

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

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

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 9 must-fire cases (both malformed state shapes, plus a missing reversibility, a missing first-rung type, a doubled reversibility and an out-of-vocabulary rung type), 10 must-not-fire cases led by the backticked-filename title that made the parser necessary, by the DONE/PARKED items that owe no axes, and by the two line-anchor cases a 2026-09-09 mutation probe proved were missing, and 4 clean twins including the PARTLY DONE heading with a commit hash beside its axes'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not (Test-Path -LiteralPath $LEDGER)) {
  Write-Output ("BACKLOG STATUS AUDIT BLIND: {0} does not exist, so nothing was checked." -f $LEDGER)
  Write-GuardComplete -Name 'backlog-status' -Summary 'blind=no-ledger'
  exit 3
}
$items = Get-TcLedgerStates -Lines ([IO.File]::ReadAllLines($LEDGER))
$items = @($items)
if (-not $items.Count) {
  Write-Output 'BACKLOG STATUS AUDIT BLIND: parsed zero item headings, which means the heading format moved rather than the ledger being empty.'
  Write-GuardComplete -Name 'backlog-status' -Summary 'blind=no-items'
  exit 3
}

if ($Summary) {
  foreach ($s in @('NEEDS A RULING', 'OPEN', 'PARTLY DONE', 'PARKED', 'DONE')) {
    $rows = @($items | Where-Object { $_.State -eq $s })
    Write-Output ''
    Write-Output ("{0}  ({1})" -f $s, $rows.Count)
    if ($s -eq 'DONE') { continue }   # the finished ones are a count, not a list
    foreach ($r in $rows) {
      Write-Output ("  {0,-4} {1,-5} {2,-8} {3}" -f $r.Id, $r.Reversibility, $r.Rung, $(if ($r.Detail) { $r.Detail } else { '' }))
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
  Write-GuardComplete -Name 'backlog-status' -Summary ("items={0} notclosed={1} twoway={2} oneway={3}" -f `
    $items.Count, $notClosed.Count,
    @($notClosed | Where-Object { $_.Reversibility -eq '2-WAY' }).Count,
    @($notClosed | Where-Object { $_.Reversibility -eq '1-WAY' }).Count)
  exit 0
}

$bad = @($items | Where-Object { $_.Problem })
foreach ($b in $bad) { Write-Output ("  {0}: {1}" -f $b.Id, $b.Problem) }
if ($bad.Count) {
  Write-Output ("BACKLOG STATUS AUDIT FAILED: {0} item(s) of {1} are malformed - each either does not declare exactly one state from the closed vocabulary ({2}), or is a not-closed item missing one of the two sorting fields (`2-WAY`/`1-WAY`, and ``RUNG1 <{3}>``). The legend at the head of design\BACKLOG-course-findings.md says what each one means and which wins when two could apply." -f $bad.Count, $items.Count, ($STATES -join ', '), ($RUNG_TYPES -join '|'))
  Write-GuardComplete -Name 'backlog-status' -Summary ("items={0} malformed={1}" -f $items.Count, $bad.Count)
  exit 2
}
$byState = ($STATES | ForEach-Object { $s = $_; ("{0} {1}" -f @($items | Where-Object { $_.State -eq $s }).Count, $s) }) -join ', '
Write-Output ("backlog-status: PASSED - all {0} item(s) declare exactly one state. {1}. Run with -Summary for the board." -f $items.Count, $byState)
Write-GuardComplete -Name 'backlog-status' -Summary ("items={0} malformed=0" -f $items.Count)
exit 0
