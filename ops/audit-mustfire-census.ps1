# audit-mustfire-census.ps1 - a must-fire assertion may not quietly leave the tree.
#
# SCOPE OF A CLEAN REPORT: UNSOUND, and it is the more useful direction here. It counts
#   assertions carrying the labels it knows, so a clean report means the LABELLED census did
#   not shrink. A must-fire whose sense lives only in its prose is outside its reach - exactly
#   the limit audit-fixture-vocabulary.ps1 states about itself.
#
# WHY THIS EXISTS (2026-09-06, PLAN-top5-2026-09-06 area 4). The estate's rule is that every guard ships
# with two fixtures: one where it MUST FIRE - and that one is the bug that caused the guard to be written -
# and one where it must stay silent. The whole scheme rests on those lines still being there.
#
# A BROKEN MUST-FIRE ANNOUNCES ITSELF. It flips to FAIL and the suite goes red, which is the design working.
# A DELETED ONE DOES NOT. The suite goes green with fewer cases, the tally moves by one, and nobody counts
# tallies. This estate has already paid for exactly that arithmetic twice:
#
#   [[exit-code-first-tally-second]]   a case was deleted and the run still exited 0
#   [[names-gate-cannot-see-a-lost-flag]]  a suite compared CASES and could not see a lost flag
#
# So: count them per file, and ratchet. A file whose must-fire count DROPS is a hard fail that names the
# file; a file whose count RISES is the estate getting better and is reported so the baseline is retrained.
# The count is deliberately per FILE rather than per case name: case labels are prose and get reworded all
# the time, and a ratchet that fails on a reworded label is a ratchet people delete.
#
# WHAT IT COUNTS. Lines inside a script's `if ($SelfTest) { ... }` body that carry MUST FIRE / MUST-FIRE /
# MUST NOT FIRE in any case, written as SEPARATE words: a run-together identifier ($mustFire, a function
# named for must-fires, a 'mustfire' fixture name) is not counted. That includes the assertion label, which
# is where this estate writes it. It
# does NOT run anything - run-gates already runs every self-test, and this answers the different question
# run-gates cannot: is the same set of must-fires still THERE.
#
#   ops\audit-mustfire-census.ps1            scan against ops\mustfire-census-baseline.json
#   ops\audit-mustfire-census.ps1 -Update    rewrite the baseline (deliberate, after a real change)
#   ops\audit-mustfire-census.ps1 -SelfTest  frozen must-fire fixtures + clean twins
# Exit 0 = nothing lost. 1 = a file lost must-fire assertions. 2 = self-test regression. 3 = BLIND.
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [switch]$Update)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')       # Write-TcLfFile: the baseline is a TRACKED eol=lf blob
. (Join-Path $repo 'lib\selftest-lib.ps1')   # Get-SelfTestBlock: PowerShell's own parser, shared with audit-fixture-inputs
. (Join-Path $repo 'lib\tree-walk.ps1')      # Get-TcPathBelowRoot: exclusions match below the root, so a worktree root is not excluded whole

function Get-MustFireCount {
  <# Pure. How many must-fire assertions does this self-test body carry? #>
  param([string]$Text)
  if (-not $Text) { return 0 }
  $n = 0
  foreach ($l in ($Text -split "`r?`n")) {
    # A COMMENT ABOUT must-fires is not a must-fire, or the essays this estate writes above its fixtures
    # would inflate the count and the ratchet would fail the day someone tidied the prose.
    if ($l.TrimStart().StartsWith('#')) { continue }
    # The SEPARATOR IS REQUIRED and MUST may not follow a word character or a hyphen. With the separator
    # optional, a case-insensitive match counted identifiers - $mustFire, Get-MustFireCount, a
    # 'feedfresh-mustfire.json' fixture name - so renaming a variable read as a LOST assertion. Measured
    # 2026-09-11: 19 such lines in 6 files. The boundary keeps a name like Get-Must-Fire-Thing out too.
    if ($l -match '(?i)(?<![\w-])MUST[ -](NOT[ -])?FIRE') { $n++ }
  }
  return $n
}

function Get-MustFireCensusScripts {
  <# Every .ps1 the census reads under $RootDir, excluded on the path BELOW the root (lib\tree-walk.ps1).
     On the full path a root under .claude\worktrees\ excluded itself whole: the census found no must-fire
     assertion anywhere and exited 3 from every spawned session (2026-09-11). #>
  param([string]$RootDir)
  $rootFull = Get-TcRootFull $RootDir
  Get-ChildItem $rootFull -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
    Where-Object { (Get-TcPathBelowRoot $_.FullName $rootFull) -notmatch '\\worktrees\\|\\archive\\|node_modules|\.venv|\\out\\' } |
    Sort-Object FullName
}

if ($SelfTest) {
  $fail = 0
  function McT([string]$m, [bool]$c) { if ($c) { Write-Output ('  PASS  ' + $m) } else { Write-Output ('  FAIL  ' + $m); $script:fail++ } }
  # Needles built by concatenation, or these fixture lines would be counted by the very scan they test
  # ([[selftest-greps-its-own-source]]).
  $MF = 'MUST' + ' FIRE'
  $MNF = 'MUST' + ' NOT ' + 'FIRE'

  McT 'MUST FIRE: an assertion label carrying the marker is counted' `
      ((Get-MustFireCount -Text ("T '" + $MF + ": a stripped BOM is reported' `$x")) -eq 1)
  McT 'MUST FIRE: the negative form is counted too - it is the same kind of assertion' `
      ((Get-MustFireCount -Text ("T '" + $MNF + ": a bid whose value is the string null' `$x")) -eq 1)
  McT 'MUST FIRE: the hyphenated spelling this estate also uses is counted' `
      ((Get-MustFireCount -Text ("Write-Output '  X MUST" + "-FIRE: a fresh finding must be actionable'")) -eq 1)
  McT 'CLEAN TWIN: a COMMENT about must-fires is prose, not an assertion' `
      ((Get-MustFireCount -Text ("# the " + $MF + " fixture below is the founding bug")) -eq 0)
  McT 'CLEAN TWIN: an empty body counts nothing' ((Get-MustFireCount -Text '') -eq 0)
  McT 'MUST FIRE: every assertion is counted, not just the first' `
      ((Get-MustFireCount -Text ("T '" + $MF + " one'`nT '" + $MF + " two'")) -eq 2)
  # THE WHOLE POINT: a deleted line changes the count. Written as a comparison so the ratchet's own
  # arithmetic is asserted rather than assumed.
  $two = "T '" + $MF + " one'`nT '" + $MF + " two'"
  $one = "T '" + $MF + " one'"
  McT 'MUST FIRE: deleting an assertion LOWERS the count - which is the thing the ratchet reads' `
      ((Get-MustFireCount -Text $one) -lt (Get-MustFireCount -Text $two))
  # And only the SELF-TEST body is counted: a must-fire label in the production path is not a fixture.
  $src = "if (`$SelfTest) {`n  T '" + $MF + " inside'`n}`nWrite-Output '" + $MF + " outside, in the live path'"
  McT 'CLEAN TWIN: a must-fire label OUTSIDE the self-test body is not a fixture' `
      ((Get-MustFireCount -Text (Get-SelfTestBlock -Text $src)) -eq 1)

  # IDENTIFIERS ARE NOT LABELS (2026-09-11). With the separator optional the match counted names, so renaming
  # a $mustFire variable read as a LOST assertion and the ratchet went red on a rename. Each needle is built by
  # concatenation: this body is itself in the census, and a literal would be counted by the scan under test.
  McT 'MUST NOT FIRE: a run-together variable name is not an assertion label' `
      ((Get-MustFireCount -Text ('$must' + 'Fire = @(')) -eq 0)
  McT 'MUST NOT FIRE: a call to the counting function is not an assertion label' `
      ((Get-MustFireCount -Text ('$c = Get-Must' + 'FireCount -Text $blk')) -eq 0)
  McT 'MUST NOT FIRE: a hyphenated name with the words inside it is not a label' `
      ((Get-MustFireCount -Text ('$r = Get-Must-' + 'Fire-Thing -Path $x')) -eq 0)
  McT 'MUST NOT FIRE: a run-together banner is not an assertion label' `
      ((Get-MustFireCount -Text ("Write-Output 'MUST" + "FIRE-CENSUS SELF-TEST PASSED'")) -eq 0)
  $spellings = "T '" + $MF + ": a'`nT 'MUST" + "-FIRE: b'`nT '" + $MNF + ": c'"
  McT 'CLEAN TWIN: all three separated spellings still count, one per line' `
      ((Get-MustFireCount -Text $spellings) -eq 3)

  # THE WALK, FROM A WORKTREE ROOT (2026-09-11, lib\tree-walk.ps1). Matched on the FULL path, every file under
  # .claude\worktrees\<name> was excluded: the census counted nothing and exited 3 from every spawned session.
  $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'grocery\b.ps1' = 'Write-Output 2' }
  try {
    $wtFound = @(Get-MustFireCensusScripts -RootDir $wtFx.Root)
    $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
    McT ($MF + ': a root that IS a worktree is scanned, not excluded whole') ($wtHits.Root -eq 2)
    McT ($MNF + ': a sibling worktree BELOW that root is still excluded') ($wtHits.Sibling -eq 0)
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }

  if ($fail) { Write-Output "MUSTFIRE-CENSUS SELF-TEST FAILED ($fail)"; exit 2 }
  Write-Output 'MUSTFIRE-CENSUS SELF-TEST PASSED (every spelling counted, prose excluded, and a deletion provably moves the number)'
  exit 0
}

# ---- live path -----------------------------------------------------------------------------------------
$scripts = @(Get-MustFireCensusScripts -RootDir $repo)

$now = [ordered]@{}
$total = 0
foreach ($s in $scripts) {
  $blk = Get-SelfTestBlock -Text ([IO.File]::ReadAllText($s.FullName))
  if (-not $blk) { continue }
  $c = Get-MustFireCount -Text $blk
  if ($c -le 0) { continue }
  $rel = $s.FullName.Replace($repo, '').TrimStart('\')
  $now[$rel] = $c
  $total += $c
}
if (-not $now.Count) {
  Write-Output 'audit-mustfire-census: BLIND - found no must-fire assertions anywhere, which means this discovery is broken, not that the estate has none'
  Exit-Guard -Name 'audit-mustfire-census' -Summary 'blind=no-mustfires' -Code 3
}

$baseFile = Join-Path $PSScriptRoot 'mustfire-census-baseline.json'
if ($Update) {
  # LF, WITH the BOM the committed blob carries (2026-09-11). This was Write-JsonFile, which writes ConvertTo-Json's
  # CRLF: the -Update that day left 208 CR bytes over an LF blob, the shape lib\lf-write.ps1 exists for, and
  # 3176eb82b moved the other baseline writers without this one.
  $null = Write-TcLfFile -Path $baseFile -Text ([ordered]@{
    readme  = 'Baseline for ops\audit-mustfire-census.ps1: how many must-fire assertions each self-test carries. A DROP is a hard fail - a must-fire that breaks goes red on its own, and a must-fire that is DELETED goes green with one fewer case and nobody counts tallies. A RISE is the estate getting better; re-run with -Update to retrain. Counting is per FILE, not per case name, because case labels are prose and a ratchet that fails on a reworded label is a ratchet people delete.'
    written = (Get-Date).ToString('yyyy-MM-dd')
    total   = $total
    files   = $now
  } | ConvertTo-Json -Depth 6)
  Write-Output ("audit-mustfire-census: baseline rewritten - {0} file(s), {1} must-fire assertion(s)" -f $now.Count, $total)
  exit 0
}

$base = $null
if (Test-Path -LiteralPath $baseFile) { try { $base = (Read-JsonFile $baseFile).files } catch { $base = $null } }
if ($null -eq $base) {
  Write-Output ("audit-mustfire-census: no baseline at {0} - run with -Update once to record today's census. {1} file(s), {2} assertion(s) counted." -f $baseFile, $now.Count, $total)
  Exit-Guard -Name 'audit-mustfire-census' -Summary 'no baseline' -Code 3
}

$lost = New-Object System.Collections.ArrayList
$gained = New-Object System.Collections.ArrayList
foreach ($p in $base.PSObject.Properties) {
  $was = [int]$p.Value
  $isNow = if ($now.Contains($p.Name)) { [int]$now[$p.Name] } else { 0 }
  if ($isNow -lt $was) { [void]$lost.Add(("{0}  {1} -> {2}" -f $p.Name, $was, $isNow)) }
  elseif ($isNow -gt $was) { [void]$gained.Add(("{0}  {1} -> {2}" -f $p.Name, $was, $isNow)) }
}
foreach ($k in $now.Keys) {
  if (-not ($base.PSObject.Properties.Name -contains $k)) { [void]$gained.Add(("{0}  new, {1}" -f $k, $now[$k])) }
}

Write-Output ("audit-mustfire-census: {0} self-test(s) carry {1} must-fire assertion(s); {2} lost, {3} gained" -f $now.Count, $total, $lost.Count, $gained.Count)
foreach ($g in $gained) { Write-Output ('  + ' + $g) }
foreach ($l in $lost) { Write-Output ('  ! LOST: ' + $l) }
if ($lost.Count) {
  Write-Output '  A must-fire assertion is the bug that caused its guard to be written. One that BREAKS turns red'
  Write-Output '  and everybody sees it; one that is DELETED leaves a green suite with one fewer case, and a tally'
  Write-Output '  nobody reads. If the removal is right - the rule it guarded was genuinely retired - say so in the'
  Write-Output '  commit and re-run with -Update. Do not retrain the baseline to make a red go away.'
}
if ($gained.Count -and -not $lost.Count) { Write-Output '  (a rise is the estate getting better - re-run with -Update to retrain the baseline)' }
Write-GuardComplete -Name 'audit-mustfire-census' -Summary ("{0} assertion(s), {1} lost" -f $total, $lost.Count)
if ($lost.Count) { exit 1 }
exit 0
