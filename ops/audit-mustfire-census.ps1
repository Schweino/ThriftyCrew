# audit-mustfire-census.ps1 - a must-fire assertion may not quietly leave the tree.
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
# MUST NOT FIRE in any case. That includes the assertion label, which is where this estate writes it. It
# does NOT run anything - run-gates already runs every self-test, and this answers the different question
# run-gates cannot: is the same set of must-fires still THERE.
#
#   ops\audit-mustfire-census.ps1            scan against ops\mustfire-census-baseline.json
#   ops\audit-mustfire-census.ps1 -Update    rewrite the baseline (deliberate, after a real change)
#   ops\audit-mustfire-census.ps1 -SelfTest  frozen must-fire fixtures + clean twins
# Exit 0 = nothing lost. 1 = a file lost must-fire assertions. 2 = self-test regression. 3 = BLIND.
param([switch]$SelfTest, [switch]$Update)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\json-io.ps1')
. (Join-Path $repo 'lib\selftest-lib.ps1')   # Get-SelfTestBlock: PowerShell's own parser, shared with audit-fixture-inputs

function Get-MustFireCount {
  <# Pure. How many must-fire assertions does this self-test body carry? #>
  param([string]$Text)
  if (-not $Text) { return 0 }
  $n = 0
  foreach ($l in ($Text -split "`r?`n")) {
    # A COMMENT ABOUT must-fires is not a must-fire, or the essays this estate writes above its fixtures
    # would inflate the count and the ratchet would fail the day someone tidied the prose.
    if ($l.TrimStart().StartsWith('#')) { continue }
    if ($l -match '(?i)MUST[ -]?(NOT[ -])?FIRE') { $n++ }
  }
  return $n
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
      ((Get-MustFireCount -Text ("Write-Output '  X MUST-FIRE: a fresh finding must be actionable'")) -eq 1)
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

  if ($fail) { Write-Output "MUSTFIRE-CENSUS SELF-TEST FAILED ($fail)"; exit 2 }
  Write-Output 'MUSTFIRE-CENSUS SELF-TEST PASSED (every spelling counted, prose excluded, and a deletion provably moves the number)'
  exit 0
}

# ---- live path -----------------------------------------------------------------------------------------
$scripts = @(Get-ChildItem $repo -Recurse -File -Filter *.ps1 -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '\\worktrees\\|\\archive\\|node_modules|\.venv|\\out\\' } |
  Sort-Object FullName)

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
  Write-GuardComplete -Name 'audit-mustfire-census' -Summary 'blind=no-mustfires'
  exit 3
}

$baseFile = Join-Path $PSScriptRoot 'mustfire-census-baseline.json'
if ($Update) {
  Write-JsonFile -Path $baseFile -Content ([ordered]@{
    readme  = 'Baseline for ops\audit-mustfire-census.ps1: how many must-fire assertions each self-test carries. A DROP is a hard fail - a must-fire that breaks goes red on its own, and a must-fire that is DELETED goes green with one fewer case and nobody counts tallies. A RISE is the estate getting better; re-run with -Update to retrain. Counting is per FILE, not per case name, because case labels are prose and a ratchet that fails on a reworded label is a ratchet people delete.'
    written = (Get-Date).ToString('yyyy-MM-dd')
    total   = $total
    files   = $now
  }) -Depth 6
  Write-Output ("audit-mustfire-census: baseline rewritten - {0} file(s), {1} must-fire assertion(s)" -f $now.Count, $total)
  exit 0
}

$base = $null
if (Test-Path -LiteralPath $baseFile) { try { $base = (Read-JsonFile $baseFile).files } catch { $base = $null } }
if ($null -eq $base) {
  Write-Output ("audit-mustfire-census: no baseline at {0} - run with -Update once to record today's census. {1} file(s), {2} assertion(s) counted." -f $baseFile, $now.Count, $total)
  Write-GuardComplete -Name 'audit-mustfire-census' -Summary 'no baseline'
  exit 3
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
