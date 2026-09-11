<#
  audit-arg-binding.ps1 - a CHECKING script must REFUSE an argument it does not understand.

  WHY THIS EXISTS (2026-09-07). During the 09-07 triage an operator ran

      ops\verify-bulk-edit.ps1 -Paths grocery\commodities.json

  to check one edited file. There is no -Paths parameter on that script and there never was. A
  PowerShell script without [CmdletBinding()] is a SIMPLE command: an argument matching no declared
  parameter is not an error, it is dropped into $args and ignored. So both tokens vanished, the script
  ran its UNSCOPED sweep over all 52 modified files, reported "0 finding(s)" and exited 0 - and the
  operator read that as "my file is clean" when the file had never been singled out at all. Measured
  again on HEAD 43f09cff4 while writing this: rc 0, 52 files, scope silently ignored.

  THE CLASS, and why it is worse inside a checker than anywhere else. Everywhere else a dropped
  argument produces the wrong OUTPUT, and wrong output tends to look wrong. In a verification tool a
  dropped argument produces a PASS - the most reassuring output there is - over a question nobody
  actually asked. It is the same shape as a could-not-look settling a question, except the tool prints
  a green line while it does it. Two of the estate's older bugs have this shape already:
  [[names-gate-cannot-see-a-lost-flag]] and the undeclared -SelfTest that lands in $args and would make
  publish-deals-page perform a REAL publish (test-auditors pins that one by hand).

  WHAT IT CHECKS. Every audit-, verify-, test-, validate-, check- script plus guards / run-gates /
  sanity-check / regression-test / json-reader-parity under ops\ and grocery\ that declares a param()
  block must carry [CmdletBinding()] above it. Archive, one-offs and out\ debris are out of scope: a
  scrap script's arguments are nobody's evidence.

  A RATCHET, NOT A GATE. 96 files were fixed in one sweep on 2026-09-07 and the count went to 0, but
  the point is the CEILING, not today's number: a new checking script that forgets the attribute pushes
  the count above the baseline and fails. The high-water mark may only go DOWN (lib\ratchet.ps1 decides
  whether a fall is believable, so a broken scan cannot record 0 as the new permanent ceiling).

  A RUN THAT IS NOT ASKED TO RECORD WRITES NOTHING (2026-09-11). run-gates runs this with no arguments on every
  pre-push, and a fall used to rewrite the TRACKED baseline right there: the pushing checkout was left dirty, the
  lower mark never rode that push, and a count taken over uncommitted edits is not a baseline. So a fall is SPOKEN
  and the committed mark KEPT; -Tighten records it. ops\audit-write-only-reports.ps1 carries the full account.

  Usage:
    .\audit-arg-binding.ps1            scan, report, ratchet against ops\out\arg-binding-baseline.json; writes nothing
    .\audit-arg-binding.ps1 -Tighten   the same, and record a believable FALL as the new high-water mark
    .\audit-arg-binding.ps1 -Accept    record the CURRENT count as the new high-water mark
    .\audit-arg-binding.ps1 -SelfTest  frozen fixtures, plus this script's live path run against a temp tree

  Exit: 0 = at or under the baseline. 2 = MORE unbound checking scripts than the baseline, or -Tighten refused an
  implausible fall. 3 = BLIND.
#>
[CmdletBinding()]   # this file is itself in the class it audits
param([switch]$SelfTest, [switch]$Accept, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')   # Write-TcLfFile: the baseline is tracked and stored eol=lf
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcPathBelowRoot: skip dirs match below the root, so a worktree root is not skipped whole

# WHICH FILES ARE "CHECKING" SCRIPTS. Built by concatenation rather than written as one literal, so
# this file's own name (audit-...) and the prose above cannot enrol or exempt anything by accident.
$script:AB_CLASS_RX = '(?i)^(' + 'audit-|verify-|test-|validate-|check-' + ')|^(' +
  'guards|run-gates|sanity-check|regression-test|json-reader-parity' + ')\.ps1$'

function Test-IsCheckingScript {
  <# Name-based on purpose: the question is what a READER of the filename expects the script to do.
     A file called audit-anything that answers "clean" is evidence to somebody. #>
  param([string]$Leaf)
  return ($Leaf -match $script:AB_CLASS_RX)
}

function Get-ScriptParamBlockAst {
  <# The SCRIPT's own param() block, via the real parser. $ast.ParamBlock is exactly that and nothing
     else - not a function's, and not text that merely looks like one.

     THE PARSER, NOT A REGEX, and the reason is a bug this file's own sweep committed. The first cut
     matched (?m)^param\s*\( . grocery\test-capture-builders.ps1 defines FAKE builder scripts as
     here-strings, and their param lines sit at column 0 INSIDE the string - so the regex found one,
     called it the script's, and the sweep wrote [CmdletBinding()] into a fixture. That is
     verify-bulk-edit's defect 2 (a frozen literal converted by a sweep) committed by the tool fixing
     defect 7. A tokenizer cannot make that mistake, and it costs about a millisecond a file. #>
  param([string]$Text)
  $err = $null
  $tok = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$err)
  if ($null -eq $ast) { return $null }
  return $ast.ParamBlock
}

function Test-NeedsCmdletBinding {
  <# Pure, over the file's TEXT, so the fixture drives exactly the live rule.
     Returns $true when this source declares a SCRIPT param() block with no [CmdletBinding()] on it -
     i.e. an argument that matches nothing is silently discarded.

     THREE THINGS THAT ARE NOT FINDINGS, and each of them cost a false positive on the way here:
       * no script param() block: nothing binds, so nothing can be silently dropped.
       * a function's param block, or one inside a here-string fixture: not the script's.
       * [CmdletBinding()] already declared, in any casing or spacing. #>
  param([string]$Text)
  $pb = Get-ScriptParamBlockAst $Text
  if ($null -eq $pb) { return $false }
  foreach ($a in @($pb.Attributes)) {
    if ($a.TypeName.Name -match '(?i)^CmdletBinding$') { return $false }
  }
  return $true
}

function Get-ScriptParamBlock {
  <# The SCRIPT's param() block text with its comments stripped, or '' if it has none.
     Comments must go first: this rule looks for an automatic variable inside a DEFAULT VALUE, and
     after the 2026-09-07 fix three of these blocks explain the trap in prose that names the very
     variable. A rule that reads its own explanation is the estate's oldest false positive. #>
  param([string]$Text)
  $pb = Get-ScriptParamBlockAst $Text
  if ($null -eq $pb) { return '' }
  $blk = $pb.Extent.Text
  return (($blk -split "`r?`n" | ForEach-Object { $_ -replace '#.*$', '' }) -join "`n")
}

function Test-BindingBreaksScriptRootDefault {
  <# THE SECOND HALF OF THE SAME ATTRIBUTE, and it is a trap rather than an omission.

     Under PS 5.1, [CmdletBinding()] makes a script an ADVANCED function, and a param default is then
     evaluated in a scope where $PSScriptRoot, $PSCommandPath and $MyInvocation.MyCommand.Path are
     EMPTY. `[string]$OutDir = (Join-Path $PSScriptRoot 'out')` throws at bind time, before the
     script's first statement. Measured 2026-09-07 while adding the attribute to 96 files: three of
     them did this, audit-coverage-regression.ps1 died on it, and the only symptom anywhere else was
     guards.ps1 reporting a HARD FAIL on coverage regression - a real gate going red for a reason that
     had nothing to do with coverage.

     So the two rules ship together on purpose. Adding the attribute without this one converts a
     silently-ignored argument into a silently-broken script, which is a worse trade. #>
  param([string]$Text)
  if (-not ($Text -match '(?i)\[\s*CmdletBinding\s*\(')) { return $false }
  $blk = Get-ScriptParamBlock $Text
  if (-not $blk) { return $false }
  return ($blk -match '(?i)\$PSScriptRoot|\$PSCommandPath|\$MyInvocation')
}

function Get-AbCandidateFiles {
  <# Every .ps1 under ops\ and grocery\ below $RootDir that sits in no skipped directory. The skip list is matched
     on the path BELOW the root (lib\tree-walk.ps1): on the full path \.claude\ and \worktrees\ are in EVERY path
     of a linked worktree, so this ratchet examined 0 files and exited 3 from every spawned session (2026-09-11). #>
  param([string]$RootDir)
  $rootFull = Get-TcRootFull $RootDir
  $skipDirs = @('\archive\', '\out\', '\.claude\', '\node_modules\', '\.git\', '\worktrees\',
                '\.venv\', '\venv\', '\site-packages\', '\dist-info\')
  foreach ($sub in @('ops', 'grocery')) {
    $d = Join-Path $rootFull $sub
    if (-not (Test-Path $d)) { continue }
    foreach ($f in @(Get-ChildItem $d -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue)) {
      $below = Get-TcPathBelowRoot $f.FullName $rootFull
      $skip = $false
      foreach ($sd in $skipDirs) { if ($below -like ('*' + $sd + '*')) { $skip = $true; break } }
      if (-not $skip) { $f }
    }
  }
}

if ($SelfTest) {
  $script:bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  # FROZEN LITERALS, single-quoted with doubled inner quotes. A fixture assembled with + would pass
  # THREE positional arguments to T and run against a fragment ([[ps-concat-in-argument-is-three-args]]).
  $founding = 'param([switch]$SelfTest, [switch]$Staged)'
  T 'MUST FIRE  the founding line: verify-bulk-edit''s own param block, unbound (-Paths fell into $args and the sweep ran unscoped)' `
    (Test-NeedsCmdletBinding $founding) 'not reported'
  $fixed = "[CmdletBinding()]`nparam([switch]`$SelfTest, [switch]`$Staged)"
  T 'MUST NOT FIRE  the same param block WITH the attribute is silent' `
    (-not (Test-NeedsCmdletBinding $fixed)) 'reported'
  $spaced = "[ CmdletBinding( ) ]`nparam([switch]`$Quiet)"
  T 'MUST NOT FIRE  spacing inside the attribute does not defeat the check' `
    (-not (Test-NeedsCmdletBinding $spaced)) 'reported'
  $withHeader = "<#`n  a header that mentions param( and CmdletBinding in prose`n#>`nparam([switch]`$Quiet)"
  T 'MUST FIRE  an attribute NAMED IN A COMMENT is prose, not a declaration' `
    (Test-NeedsCmdletBinding $withHeader) 'not reported'
  $noParam = "`$ErrorActionPreference = 'Stop'`nWrite-Output 'hello'"
  T 'MUST NOT FIRE  a script with no param() block binds nothing and cannot drop an argument' `
    (-not (Test-NeedsCmdletBinding $noParam)) 'reported'
  $fnParam = "function Get-Thing {`n  param([string]`$Name)`n}`nGet-Thing 'x'"
  T 'MUST NOT FIRE  an INDENTED param( is a function''s, not the script''s' `
    (-not (Test-NeedsCmdletBinding $fnParam)) 'reported'
  # MUST NOT FIRE, and this one is the sweep's own bug turned into a case. test-capture-builders.ps1
  # writes FAKE builder scripts as here-strings; their param lines sit at column 0 inside the string,
  # a regex called one of them the script's own, and the sweep edited a fixture. The parser cannot.
  $inHereString = "Set-Content `$p -Value @'`nparam([string]`$In,[string]`$Date)`nexit 0`n'@"
  T 'MUST NOT FIRE  a param line at column 0 INSIDE A HERE-STRING is a fixture, not a declaration (the sweep wrote into one)' `
    (-not (Test-NeedsCmdletBinding $inHereString)) 'reported'
  # CLEAN TWIN for the class filter: the naming rule still admits the real files and still excludes a
  # builder. Losing this would make the audit either empty or estate-wide, and both look like a pass.
  T 'CLEAN TWIN  the class admits the real checking scripts' `
    ((Test-IsCheckingScript 'verify-bulk-edit.ps1') -and (Test-IsCheckingScript 'audit-coverage-gaps.ps1') -and
     (Test-IsCheckingScript 'guards.ps1') -and (Test-IsCheckingScript 'run-gates.ps1')) 'a checking script was excluded'
  T 'CLEAN TWIN  the class excludes builders and publishers, whose arguments are not evidence' `
    ((-not (Test-IsCheckingScript 'build-deals-page.ps1')) -and (-not (Test-IsCheckingScript 'publish-deals-page.ps1')) -and
     (-not (Test-IsCheckingScript 'compare-deals.ps1'))) 'a builder was pulled into the class'
  # ---- rule 2: the trap the fix itself walked into (2026-09-07) -------------------------------------
  $trap = "[CmdletBinding()]`nparam([string]`$OutDir = (Join-Path `$PSScriptRoot 'out'))"
  T 'MUST FIRE  [CmdletBinding()] with $PSScriptRoot in a param DEFAULT - empty at bind time under PS 5.1, so the script dies before line one (audit-coverage-regression, which surfaced as a guards HARD FAIL)' `
    (Test-BindingBreaksScriptRootDefault $trap) 'not reported'
  $trapFixed = "[CmdletBinding()]`nparam([string]`$OutDir = '')`nif (-not `$OutDir) { `$OutDir = Join-Path `$PSScriptRoot 'out' }"
  T 'MUST NOT FIRE  the same default resolved BELOW the block is correct and must stay silent' `
    (-not (Test-BindingBreaksScriptRootDefault $trapFixed)) 'reported'
  $trapNoAttr = "param([string]`$OutDir = (Join-Path `$PSScriptRoot 'out'))"
  T 'MUST NOT FIRE  without the attribute the same default works, so it is not a finding on its own' `
    (-not (Test-BindingBreaksScriptRootDefault $trapNoAttr)) 'reported'
  # CLEAN TWIN, and it is why comments are stripped first: all three files fixed on 2026-09-07 now
  # EXPLAIN the trap in a comment inside the param block, naming the variable. Matching raw text would
  # report every one of them - a check that fires on its own fix is a check somebody deletes.
  $trapProse = "[CmdletBinding()]`nparam(`n  # NOT (Join-Path `$PSScriptRoot 'out'): empty under CmdletBinding`n  [string]`$OutDir = ''`n)"
  T 'CLEAN TWIN  the variable NAMED IN A COMMENT inside the param block is documentation, not a default' `
    (-not (Test-BindingBreaksScriptRootDefault $trapProse)) 'reported'
  # PS 5.1: @($null).Count is 1, so an empty finding set must not score 1 ([[ps-null-count-is-one]]).
  $empty = @()
  T 'an empty finding set counts 0, not the PS 5.1 @($null) 1' ((@($empty)).Count -eq 0) ([string](@($empty)).Count)
  # THE WALK, FROM A WORKTREE ROOT (2026-09-11, lib\tree-walk.ps1). The skip list matched \.claude\ and
  # \worktrees\ on the FULL path, both of which are in every path of a linked worktree: 0 examined, exit 3.
  # THE NEGATIVE CASE IS A WORKTREE INSIDE grocery\, not the fixture's usual sibling under .claude\. This walk
  # starts in ops\ and grocery\ and never reaches .claude\, so a sibling there is skipped whatever the rule says:
  # a mutation that dropped the skip list entirely left that version of this case green. This one goes red.
  $wtFx = New-TcWorktreeFixture -Files @{ 'ops\audit-a.ps1' = 'Write-Output 1'; 'grocery\check-b.ps1' = 'Write-Output 2'
                                          'grocery\worktrees\stale\check-c.ps1' = 'Write-Output 3' }
  try {
    $wtFound = @(Get-AbCandidateFiles -RootDir $wtFx.Root)
    $wtNested = @($wtFound | Where-Object { (Get-TcPathBelowRoot $_.FullName $wtFx.Root) -like '*\grocery\worktrees\*' })
    $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
    T 'MUST FIRE  a root that IS a worktree is scanned, not skipped whole' (($wtHits.Root - $wtNested.Count) -eq 2) ("root=" + $wtHits.Root)
    T 'MUST NOT FIRE  a worktree nested inside a scanned directory below that root is still skipped' ($wtNested.Count -eq 0) ("nested=" + $wtNested.Count)
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }
  # THE LIVE PATH, DRIVEN (2026-09-11). The founding shape is a pre-push run-gates pass whose count FELL: it rewrote
  # the tracked baseline and left the pushing checkout dirty. These run THIS script as a child against a one-file
  # temp tree and a temp baseline, so they exercise the code a gate runs, not a copy of it. One directory per run,
  # removed in finally, because concurrent pushes run this suite in the same %TEMP%.
  $lt = Join-Path $env:TEMP ('ab-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $lt -ErrorAction Stop | Out-Null
  try {
    $ltTree = Join-Path $lt 'tree'
    [void][IO.Directory]::CreateDirectory((Join-Path $ltTree 'ops'))
    [IO.File]::WriteAllText((Join-Path $ltTree 'ops\audit-fx.ps1'), $founding, (New-Object Text.UTF8Encoding($false)))   # exactly one unbound checking script
    $ltBl = Join-Path $lt 'baseline.json'
    $ltSeedJson = [ordered]@{ generated = '2026-01-01T00:00:00'; unbound = 2; examined = 2; names = @('ops\audit-fx.ps1', 'ops\audit-retired.ps1') } | ConvertTo-Json -Depth 3
    $null = Write-TcLfFile $ltBl $ltSeedJson
    $ltSeed = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltBl))
    $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltBl
    $rc1 = $LASTEXITCODE
    $o1 = @($o1)
    $same1 = [string]::Equals($ltSeed, [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltBl)), [StringComparison]::Ordinal)
    T 'a FALL (1 unbound script, baseline 2) without -Tighten is spoken and NOT written, so a gate run leaves its checkout clean' `
      ($rc1 -eq 0 -and $same1 -and (($o1 -join "`n") -match 'CAN tighten')) ("rc=$rc1 baselineUnchanged=$same1")
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltBl -Tighten
    $rc2 = $LASTEXITCODE
    $b2 = [IO.File]::ReadAllBytes($ltBl)
    $cr2 = 0; foreach ($x in $b2) { if ($x -eq 13) { $cr2++ } }
    $bom2 = ($b2.Length -ge 3 -and $b2[0] -eq 0xEF -and $b2[1] -eq 0xBB -and $b2[2] -eq 0xBF)
    $doc2 = $null
    if ($bom2) { $doc2 = [Text.Encoding]::UTF8.GetString($b2, 3, $b2.Length - 3) | ConvertFrom-Json }
    T '-Tighten records the fall in the bytes git stores: no CR, the BOM, one trailing LF, and the new mark of 1' `
      ($rc2 -eq 0 -and $cr2 -eq 0 -and $bom2 -and $b2[-1] -eq 10 -and $null -ne $doc2 -and [int]$doc2.unbound -eq 1) `
      ("rc=$rc2 cr=$cr2 bom=$bom2 unbound=$(if ($doc2) { $doc2.unbound })")
    $ltRise = Join-Path $lt 'baseline-rise.json'
    $ltRiseJson = [ordered]@{ generated = '2026-01-01T00:00:00'; unbound = 0; examined = 0; names = @() } | ConvertTo-Json -Depth 3
    $null = Write-TcLfFile $ltRise $ltRiseJson
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltRise
    $rc3 = $LASTEXITCODE
    T 'CLEAN TWIN  a count that ROSE still fails the run with exit 2, so not writing on a fall did not disarm the ratchet' ($rc3 -eq 2) ("rc=$rc3")
  } finally {
    Remove-Item -LiteralPath $lt -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($bad -eq 0) { Write-Output 'ARG-BINDING SELF-TEST PASS'; Write-GuardComplete -Name 'arg-binding' -Summary 'selftest ok'; exit 0 }
  Write-Output ("ARG-BINDING SELF-TEST FAILED ($bad)"); Write-GuardComplete -Name 'arg-binding' -Summary "selftest failed=$bad"; exit 2
}

# ---- live scan ----
if (-not $Root) { $Root = $repo }
$rootFull = Get-TcRootFull $Root
$scanned = 0
$findings = New-Object System.Collections.Generic.List[string]
# Rule 2 is a HARD failure, not a ratchet entry. It is not a backlog: a script in this state cannot
# run at all, so there is nothing to work down and nothing to grandfather.
$broken = New-Object System.Collections.Generic.List[string]
foreach ($f in @(Get-AbCandidateFiles -RootDir $rootFull)) {
  if (-not (Test-IsCheckingScript $f.Name)) { continue }
  $scanned++
  $p = $f.FullName
  $txt = ''
  try { $txt = [IO.File]::ReadAllText($p) } catch { continue }
  $rel = (Get-TcPathBelowRoot $p $rootFull).TrimStart('\', '/')
  if (Test-NeedsCmdletBinding $txt) { [void]$findings.Add($rel) }
  if (Test-BindingBreaksScriptRootDefault $txt) { [void]$broken.Add($rel) }
}
if ($scanned -eq 0) {
  Write-Output 'arg-binding: BLIND - zero checking scripts reached the scan, so a clean result would prove nothing'
  Exit-Guard -Name 'arg-binding' -Summary 'blind=nothing-scanned' -Code 3
}
$n = @($findings).Count
# THE DENOMINATOR, ALWAYS. "0 findings" is a mood; "0 of 99 examined" is a measurement.
Write-Output ("arg-binding: examined {0} checking script(s) under ops\ and grocery\; {1} declare param() with no [CmdletBinding()], so an undeclared argument is silently dropped" -f $scanned, $n)
foreach ($w in $findings) { Write-Output ('  UNBOUND  ' + $w) }
$nBroken = @($broken).Count
Write-Output ("arg-binding: {0} of the same {1} carry [CmdletBinding()] AND an automatic script-location variable inside a param default, which is empty at bind time under PS 5.1" -f $nBroken, $scanned)
foreach ($w in $broken) { Write-Output ('  DEAD-AT-BIND  ' + $w + '  (resolve the default below the param block)') }
if ($nBroken -gt 0) {
  Write-Output 'arg-binding: HARD FAIL - a script in this state throws before its first statement, and the symptom surfaces somewhere else entirely (on 2026-09-07 it read as a guards coverage-regression HARD FAIL).'
  Exit-Guard -Name 'arg-binding' -Summary "unbound=$n dead_at_bind=$nBroken examined=$scanned" -Code 2
}

$blF = if ($BaselineFile) { $BaselineFile } else { Join-Path $here 'out\arg-binding-baseline.json' }
$blDir = Split-Path $blF -Parent
if (-not (Test-Path $blDir)) { New-Item -ItemType Directory -Force $blDir | Out-Null }
$base = $null
if (Test-Path $blF) { try { $base = [int]((Get-Content $blF -Raw | ConvertFrom-Json).unbound) } catch { $base = $null } }
function Write-AbBaseline([int]$Count) {
  $json = @{ generated = (Get-Date).ToString('s'); unbound = $Count; examined = $scanned; names = @($findings)
     note = 'High-water mark for the arg-binding ratchet (2026-09-07, the verify-bulk-edit -Paths drop). This number may only go DOWN. A run above it means a NEW checking script can silently ignore an argument it was given.' } | ConvertTo-Json -Depth 3
  # LF with the BOM the committed blob carries, not the CRLF Set-Content writes under PS 5.1 (lib\lf-write.ps1).
  $null = Write-TcLfFile $blF $json
}
if ($Accept -or $null -eq $base) {
  Write-AbBaseline $n
  Write-Output ("  baseline written: $n unbound of $scanned examined. From here the number may only go DOWN.")
  Exit-Guard -Name 'arg-binding' -Summary "unbound=$n examined=$scanned baseline=$n" -Code 0
}
$move = Test-RatchetMove -Name 'arg-binding' -Count $n -Baseline $base
if ($move.Verdict -eq 'rose') {
  Write-Output ("arg-binding: RATCHET BROKEN - $n unbound of $scanned examined, baseline $base. A checking script was added or edited so that an argument it does not declare is silently discarded, and its PASS then answers a question nobody asked.")
  Exit-Guard -Name 'arg-binding' -Summary "unbound=$n examined=$scanned baseline=$base" -Code 2
}
if ($move.Verdict -eq 'tightened') {
  if ($Tighten) {
    Write-AbBaseline $n
    Write-Output ("  ratchet tightened: $n unbound, was $base. New baseline written - commit it, or it protects only this checkout.")
  } else {
    Write-Output ("  ratchet CAN tighten: $n unbound, baseline $base. NOT written: this may be a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit ops\out\arg-binding-baseline.json.")
  }
} elseif ($move.Verdict -eq 'implausible') {
  Write-Output ('  ' + $move.Message + ' - baseline kept at ' + $base + ' (-Accept is this script''s -AcceptDrop.)')
  if ($Tighten) { Exit-Guard -Name 'arg-binding' -Summary "unbound=$n examined=$scanned baseline=$base refused-to-lower" -Code 2 }
}
Write-Output ("arg-binding: $n of $scanned examined are unbound, against a baseline of $base.")
Exit-Guard -Name 'arg-binding' -Summary "unbound=$n examined=$scanned baseline=$base" -Code 0
