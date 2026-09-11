# audit-one-way-actuators.ps1
# ---------------------------------------------------------------------------------------------------
# A control constant that may only move ONE WAY, with no rate limit and no plausibility bar
# (2026-09-09, backlog I93, ruled by Brad).
#
# THE SHAPE. `lib/ratchet.ps1` guards the audits' high-water mark: it may only FALL, so a fall to zero
# or a fall larger than -MaxDropPct is refused, the old baseline is KEPT, and the refusal is SPOKEN.
# `graph/learning/promote_aliases.py`'s promotion holds are the estate's other one-directional
# actuator - they only ACCUMULATE, never expire, and nothing re-tested them until --recheck-holds - and
# they had none of that machinery. One degraded guard run naming many commodities would have latched a
# permanent hold for every one of them in a single pass.
#
# WHAT THIS LOOKS FOR. A file that writes a latching or ratcheting state file and mentions none of the
# guard vocabulary: a rate limit, a plausibility bar, a keep-the-old-state, or an explicit override.
#
# SCOPE OF A CLEAN REPORT: UNSOUND, and this one especially so. "One-directional actuator" is a
# PROPERTY OF A DESIGN, not a spelling, and no pattern matcher can see it. This finds files whose text
# says they latch, ratchet, hold or only-ever-grow. A design that latches without using any of those
# words is invisible to it, and a file that merely discusses the concept will be flagged and is a false
# positive to be listed in the allow set with a reason. A finding here is worth reading; silence proves
# nothing at all.
#
# A REPORT, NOT A GATE, per the standing rule and per the ruling. It exits 0 and prints. Exit 2 only
# under -Strict, so nobody is trained to ignore red.
#
#   .\audit-one-way-actuators.ps1
#   .\audit-one-way-actuators.ps1 -SelfTest
# Exit 0 report produced, 2 under -Strict with findings, 3 could not evaluate.
# ---------------------------------------------------------------------------------------------------
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [switch]$Strict,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcPathBelowRoot: exclusions match below the root, so a worktree root is not excluded whole

# Words that say THIS FILE'S OWN state only moves one way.
#
# NARROWED 2026-09-09, BEFORE SHIPPING, because the first list was noise. It included the bare word
# `ratchet` and produced 32 findings over 63 files, nearly all false: `grocery/audit-null-rate.ps1`
# was flagged while explicitly saying the ratchet asymmetry does NOT apply to it, and `ops/run-gates.ps1`
# was flagged for LISTING ratchet-shaped gates in its comments. A report that is mostly wrong is one
# people learn to skip, which is the same failure as a gate that is red on day one.
$script:LATCH_WORDS = @('latching actuator', 'may only go DOWN', 'may only move DOWN',
                        'only ever withhold', 'only ever grow', 'never expire', 'only accumulate',
                        'one-directional actuator')
# Words that say "and it is guarded". A file that calls the shared ratchet IS guarded - by the
# library, which is the whole point of having one - so the call itself counts.
$script:GUARD_WORDS = @('rate limit', 'MaxDropPct', 'plausibility', 'baseline KEPT', 'Baseline KEPT',
                        'refuses a fall', 'REFUSED', 'accept-holds', 'AcceptDrop', 'MAX_NEW_HOLDS',
                        'keeps the old', 'kept and reports',
                        'Test-RatchetMove', 'ratchet.ps1',
                        # Same guard, other tense or other spelling. Added 2026-09-09 after reading
                        # the flagged files: audit-cross-module-reach REFUSES to raise its mark and
                        # audit_graph_shape gates a move behind --accept. Both are guarded; only the
                        # wording differed, and matching prose is what makes this detector approximate.
                        'REFUSING', '--accept')
# Files that TALK about the shape rather than implementing one. Each needs a stated reason.
$script:ALLOW = @{
  'docs\CONTROL-CONSTANTS.md'          = 'the register itself - it describes the shape by definition'
  'ops\audit-one-way-actuators.ps1'    = 'this detector; a detector must never scan itself'
  '.claude\rules\ops-and-gates.md'     = 'the rules file states the shape as a rule'
}

function Test-TcLatching {
  <# Does this text describe state that only moves one way? Pure. #>
  param([string]$Text)
  if (-not $Text) { return $false }
  foreach ($w in $script:LATCH_WORDS) {
    if ($Text -match [regex]::Escape($w)) { return $true }
  }
  return $false
}

function Test-TcGuarded {
  <# Does it also carry the guard vocabulary? Pure. #>
  param([string]$Text)
  if (-not $Text) { return $false }
  foreach ($w in $script:GUARD_WORDS) {
    if ($Text -match [regex]::Escape($w)) { return $true }
  }
  return $false
}

function Get-ActuatorSourceFiles {
  <# Every .ps1/.py the sweep reads under $RootDir, excluded on the path BELOW the root (lib\tree-walk.ps1).
     On the full path a root under .claude\worktrees\ excluded itself whole, and this report exited 3 from
     every spawned session (2026-09-11). #>
  param([string]$RootDir)
  $rootFull = Get-TcRootFull $RootDir
  Get-ChildItem $rootFull -Recurse -File -Include '*.ps1', '*.py' -ErrorAction SilentlyContinue |
    Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch '\\\.claude\\worktrees\\|\\grocery\\out\\|\\archive\\|\\node_modules\\|\\\.venv' }
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     " + $n + "   got: " + $got); $script:bad++ }
  }

  # MUST FIRE - the founding case, promotion-holds before I93: it latches and says nothing about a limit.
  $unguarded = 'promotion-holds.json is a latching actuator: it can only ever withhold more.'
  T 'MUST FIRE  text that says it latches, with no guard vocabulary, is a finding' `
    ((Test-TcLatching $unguarded) -and (-not (Test-TcGuarded $unguarded))) 'not flagged'

  # MUST NOT FIRE - the ratchet, which latches AND is guarded. Flagging it would be crying wolf on the
  # one file in the estate that already does this correctly.
  $guarded = 'a high-water mark that may only go DOWN. A fall over MaxDropPct is REFUSED and the Baseline KEPT.'
  T 'MUST NOT FIRE  a latching thing that carries a rate limit is NOT a finding' `
    ((Test-TcLatching $guarded) -and (Test-TcGuarded $guarded)) 'the ratchet was flagged'

  # MUST NOT FIRE - ordinary code that latches nothing.
  $plain = 'Write-Output "hello"; $x = 1'
  T 'MUST NOT FIRE  a file that latches nothing is not examined for guards' `
    (-not (Test-TcLatching $plain)) 'flagged'

  # MUST FIRE - the guard words alone do not make an unlatching file interesting.
  T 'MUST NOT FIRE  guard words with no latching state are not a finding' `
    (-not (Test-TcLatching 'this has a rate limit and a plausibility bar')) 'flagged'

  T 'the allow set names a REASON for every entry, never a bare filename' `
    (@($script:ALLOW.Keys | Where-Object { -not $script:ALLOW[$_] }).Count -eq 0) 'an entry has no reason'

  # CLEAN TWIN - the adjacent behaviour: matching is literal, so a regex metacharacter in a word list
  # entry cannot silently widen the match. A positive assertion.
  T 'CLEAN TWIN  the word list is matched literally, not as a regex' `
    (-not (Test-TcLatching 'high water')) 'a hyphenless spelling matched, so the match is not literal'

  # THE WALK, FROM A WORKTREE ROOT (2026-09-11, lib\tree-walk.ps1). Matched on the FULL path, every file under
  # .claude\worktrees\<name> was excluded and this report exited 3 from every spawned session.
  $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'graph\b.py' = 'print(1)' }
  try {
    $wtFound = @(Get-ActuatorSourceFiles -RootDir $wtFx.Root)
    $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
    T 'MUST FIRE  a root that IS a worktree is scanned, not excluded whole' ($wtHits.Root -eq 2) ("root=" + $wtHits.Root)
    T 'MUST NOT FIRE  a sibling worktree BELOW that root is still excluded' ($wtHits.Sibling -eq 0) ("sibling=" + $wtHits.Sibling)
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

  if ($bad -gt 0) { Write-Output ("one-way-actuators SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'one-way-actuators SELF-TEST PASS: 8 case(s) resolved'
  Exit-Guard -Name 'one-way-actuators' -Summary 'selftest pass' -Code 0
}

# ---- sweep -----------------------------------------------------------------------------------------
$files = @(Get-ActuatorSourceFiles -RootDir $repo)
if (-not $files.Count) { Write-Output 'one-way-actuators: no source files found - discovery is broken, not clean.'; exit 3 }

$findings = @()
$latching = 0
foreach ($f in $files) {
  $rel = $f.FullName.Substring($repo.Length).TrimStart('\','/')
  if ($script:ALLOW.ContainsKey($rel)) { continue }
  $text = [IO.File]::ReadAllText($f.FullName)
  if (-not (Test-TcLatching $text)) { continue }
  $latching++
  if (Test-TcGuarded $text) { continue }
  $findings += $rel
}

Write-Output ("one-way-actuators: scanned {0} source file(s); {1} describe one-directional state; {2} of those carry no rate limit or plausibility bar" -f `
  $files.Count, $latching, $findings.Count)
foreach ($x in $findings) { Write-Output ("    {0}" -f $x) }
if ($findings.Count -gt 0) {
  Write-Output '  A one-directional actuator needs a rate limit AND a plausibility bar, must KEEP its old'
  Write-Output '  state on refusal, and must SAY SO - a silent decline looks like nothing to do.'
  Write-Output '  The shape and the register: docs\CONTROL-CONSTANTS.md'
}
Write-Output '  SCOPE: UNSOUND. "One-directional" is a property of a design, not a spelling. Silence here'
Write-Output '  is not evidence; a finding is worth reading.'
if ($Strict -and $findings.Count -gt 0) {
  Exit-Guard -Name 'one-way-actuators' -Summary ("scanned={0} latching={1} unguarded={2}" -f $files.Count, $latching, $findings.Count) -Code 2
}
Exit-Guard -Name 'one-way-actuators' -Summary ("scanned={0} latching={1} unguarded={2}" -f $files.Count, $latching, $findings.Count) -Code 0
