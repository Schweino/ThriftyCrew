<#
  audit-backlog-status.ps1 - every backlog item declares one state, from a closed vocabulary.

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

function Get-TcItemState {
  <# The state a heading declares, or a reason it declares none. Pure, so the fixtures drive it with
     synthetic headings rather than with today's ledger.

     Returns @{ Id; State; Detail; Problem }. Problem is '' when the heading is well formed. #>
  param([string]$Heading)
  if ($Heading -notmatch '^###\s+([A-Z][0-9]+)\s+-\s') { return $null }   # not an item heading
  $id = $Matches[1]
  $tags = @([regex]::Matches($Heading, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value })
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
  if ($found.Count -eq 0) {
    return [pscustomobject]@{ Id = $id; State = ''; Detail = ''
      Problem = "declares no state. Give it one of: $($STATES -join ', ')" }
  }
  if ($found.Count -gt 1) {
    return [pscustomobject]@{ Id = $id; State = ''; Detail = ''
      Problem = ("declares {0} states ({1}). One heading, one state." -f $found.Count, (($found | ForEach-Object { $_.State }) -join ' + ')) }
  }
  $detail = $found[0].Tag.Substring($found[0].State.Length).TrimStart(' ', '-').Trim()
  return [pscustomobject]@{ Id = $id; State = $found[0].State; Detail = $detail; Problem = '' }
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
  $r6 = Get-TcItemState '### E5 - Validate at source `PARKED - SEE done-notes.md FOR WHY` `queue-2`'
  T 'MUST NOT FIRE  a filename containing a state word inside the SAME tag does not add a second state' `
    (($r6.State -eq 'PARKED') -and ($r6.Problem -eq '')) ($r6.State + ' problem=' + $r6.Problem)

  # MUST FIRE - the two malformed shapes.
  $b1 = Get-TcItemState '### E44 - An item nobody gave a state `queue-2`'
  T 'MUST FIRE  a heading with no state is a finding' ($b1.Problem -like 'declares no state*') $b1.Problem
  $b2 = Get-TcItemState '### E45 - An item claiming two `DONE` `OPEN`'
  T 'MUST FIRE  a heading declaring two states is a finding, because one of them is a lie' `
    ($b2.Problem -like 'declares 2 states*') $b2.Problem

  # CLEAN TWIN - the scanner around the predicate still walks lines and keeps only the items.
  $all = Get-TcLedgerStates -Lines @('# Title', '### E1 - a `DONE`', 'prose', '### Triage of things', '### E2 - b `OPEN`')
  T 'CLEAN TWIN the scanner keeps the two items and drops the prose and the section heading' `
    (($all.Count -eq 2) -and ($all[0].Id -eq 'E1') -and ($all[1].State -eq 'OPEN')) ("Count=" + $all.Count)
  $one = Get-TcLedgerStates -Lines @('### E1 - a `DONE`')
  T 'CLEAN TWIN a single item comes back as an ARRAY, not unrolled to one object' ($one -is [array]) ($one.GetType().FullName)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 5 must-fire cases including both malformed shapes, 4 must-not-fire cases led by the backticked-filename title that made the parser necessary, plus the scanner and its return arity'
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
      Write-Output ("  {0,-4} {1}" -f $r.Id, $(if ($r.Detail) { $r.Detail } else { '' }))
    }
  }
  Write-Output ''
  Write-GuardComplete -Name 'backlog-status' -Summary ("items={0}" -f $items.Count)
  exit 0
}

$bad = @($items | Where-Object { $_.Problem })
foreach ($b in $bad) { Write-Output ("  {0}: {1}" -f $b.Id, $b.Problem) }
if ($bad.Count) {
  Write-Output ("BACKLOG STATUS AUDIT FAILED: {0} item(s) of {1} do not declare exactly one state from the closed vocabulary ({2}). The legend at the head of design\BACKLOG-course-findings.md says what each one means and which wins when two could apply." -f $bad.Count, $items.Count, ($STATES -join ', '))
  Write-GuardComplete -Name 'backlog-status' -Summary ("items={0} malformed={1}" -f $items.Count, $bad.Count)
  exit 2
}
$byState = ($STATES | ForEach-Object { $s = $_; ("{0} {1}" -f @($items | Where-Object { $_.State -eq $s }).Count, $s) }) -join ', '
Write-Output ("backlog-status: PASSED - all {0} item(s) declare exactly one state. {1}. Run with -Summary for the board." -f $items.Count, $byState)
Write-GuardComplete -Name 'backlog-status' -Summary ("items={0} malformed=0" -f $items.Count)
exit 0
