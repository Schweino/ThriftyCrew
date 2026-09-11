<#
  audit-source-comment-strip.ps1 - a check that reads SOURCE must not be able to read PROSE as code.

  WHY THIS EXISTS (2026-09-07). ops\run-gates.ps1 decides which scripts have a -SelfTest by matching
  the declaration against the file's text. On 2026-09-01 it learned to strip comments first, after a
  comment DISCUSSING the switch enrolled run-gates in its own discovery and spawned 18 copies of
  itself over 39 minutes. That fix stripped LINE comments only:

      ($t -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

  A block header is not a line comment. Measured the day this shipped: EIGHT shared libraries were
  enrolled as self-tests by their own headers - every one of them a header explaining why a library
  must NOT declare that switch, because a dot-sourced param block runs in the caller's scope. None of
  the eight accepts the switch. run-gates ran all eight with -SelfTest, the flag fell into $args
  (they have no param block at all), each exited 0 doing nothing, and the gate counted eight passing
  self-tests that do not exist. Discovery went 209 -> 201 when the block strip was added, and no file
  was added, which is what says the eight were phantom rather than lost.

  THE CLASS, and why it has two failure directions that look identical from outside:
    * TOO LITTLE stripping enrols prose as code. A check fires on its own documentation, or - worse,
      as here - counts a file it should never have run and reports the result as green.
    * TOO MUCH stripping deletes code. A `#` inside a quoted string is not a comment, and cutting to
      end-of-line there takes the rest of the statement with it and unbalances every brace count
      after it. audit-write-only-reports carries a fixture for that exact shape.
  Both produce a quiet pass, which is why the reduction belongs in one fixtured place -
  lib\ps-source.ps1 - rather than in each caller.

  WHAT IT CHECKS. Any .ps1 under ops\, grocery\, lib\ or meal-prep\ that reduces PowerShell source by
  dropping whole-line comments, and then MATCHES a declaration or call against the result, must also
  remove block comments - either by calling Get-PsCodeOnly or by stripping them itself.

  SCOPE OF A CLEAN REPORT: UNSOUND, so a clean report proves nothing. It matches ONE spelling of the
  class - a whole-line drop by -notmatch on a leading hash - and a scanner that reads comments by line
  some other way is out of its reach. Found 2026-09-11: ops\audit-cross-module-reach.ps1 decided comment
  or code by whether a hash sat EARLIER ON THE SAME LINE, so every line of a block header scored as code,
  its ratchet read 133 -> 134 for a path named in header prose, and 15 of its 133 code sites that day were
  block-comment prose. This audit examined that file and stayed silent, correctly by its own needle,
  because that scanner never drops a line. A second needle for the hash-position spelling was measured
  and NOT added: of the 506 files this audit examined, 6 spell an IndexOf on a hash, and only that one
  classified PowerShell by line comments alone. 2 strip blocks first (audit-git-sweepers,
  audit-lift-completeness) and 3 apply it to Python, a requirements file or a URL fragment, where it is
  right (audit-full-path-excludes, audit-python-pins, audit-search-links). All 6 name a .ps1 somewhere, so
  no text test tells the PowerShell reader apart: the needle would fire 3 times for 1 real case. The
  scanner was fixed instead (it reads comments from the tokenizer now), which leaves that spelling
  unguarded for the NEXT scanner. That is the gap, stated rather than closed.

  A RATCHET. The known call sites are recorded as a high-water mark that may only go DOWN, so an
  existing one can be worked off but a NEW scanner cannot appear with the gap.

  A RUN THAT IS NOT ASKED TO RECORD WRITES NOTHING (2026-09-11). run-gates runs this with no arguments on every
  pre-push, and a fall used to rewrite the TRACKED baseline right there: the pushing checkout was left dirty, the
  lower mark never rode that push, and a count taken over uncommitted edits is not a baseline. So a fall is SPOKEN
  and the committed mark KEPT; -Tighten records it. ops\audit-write-only-reports.ps1 carries the full account.

  Usage:
    .\audit-source-comment-strip.ps1            scan and ratchet; writes nothing
    .\audit-source-comment-strip.ps1 -Tighten   the same, and record a believable FALL as the new high-water mark
    .\audit-source-comment-strip.ps1 -Accept    record the CURRENT count as the new high-water mark
    .\audit-source-comment-strip.ps1 -SelfTest  frozen fixtures, plus this script's live path run against a temp tree

  Exit: 0 = at or under the baseline. 2 = a NEW line-comment-only scanner, or -Tighten refused an implausible
  fall. 3 = could not evaluate.
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Accept, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')   # Write-TcLfFile: the baseline is tracked and stored eol=lf
. (Join-Path $repo 'lib\ps-source.ps1')
. (Join-Path $repo 'lib\tree-walk.ps1')   # Get-TcPathBelowRoot: skip dirs match below the root, so a worktree root is not skipped whole

# NEEDLES BY CONCATENATION. This file scans source for a comment-stripping idiom, so spelling the
# idiom out as a literal would make this file match itself - and a detector that finds itself cannot
# fail ([[selftest-greps-its-own-source]]). run-gates and audit-write-seam both carry the same rule.
$script:SCS_LINE_STRIP = '(?i)-notmatch\s+[''"]\^' + '\\s\*#'
$script:SCS_BLOCK_STRIP = '(?i)<' + '#\.\*\?#' + '>|Get-PsCodeOnly|Get-PsCodeLines'

function Test-StripsLineCommentsOnly {
  <# Pure over one file's text. True when the file reduces source by dropping whole-line comments and
     never removes block comments - so a block header reaches whatever it matches next. #>
  param([string]$Text)
  if ($null -eq $Text) { return $false }
  if ($Text -notmatch $script:SCS_LINE_STRIP) { return $false }
  if ($Text -match $script:SCS_BLOCK_STRIP) { return $false }
  return $true
}

function Get-ScsCandidateFiles {
  <# Every .ps1 under ops\, grocery\, lib\ and meal-prep\ below $RootDir that sits in no skipped directory. The
     skip list is matched on the path BELOW the root (lib\tree-walk.ps1): on the full path \.claude\ and
     \worktrees\ are in EVERY path of a linked worktree, so this ratchet examined 0 files and exited 3 from every
     spawned session (2026-09-11). #>
  param([string]$RootDir)
  $rootFull = Get-TcRootFull $RootDir
  $skipDirs = @('\archive\', '\out\', '\.claude\', '\node_modules\', '\.git\', '\worktrees\',
                '\.venv\', '\venv\', '\site-packages\', '\dist-info\')
  foreach ($sub in @('ops', 'grocery', 'lib', 'meal-prep')) {
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
  # THE FOUNDING LINE, as a single-quoted literal with doubled inner quotes. Built with + it would be
  # three positional arguments and the case would run on a fragment ([[ps-concat-in-argument-is-three-args]]).
  $founding = '$code = ($t -split "`r?`n" | Where-Object { $_ -notmatch ''^\s*#'' }) -join "`n"'
  T 'MUST FIRE  run-gates'' own reduction line, line comments only (it enrolled 8 libraries as self-tests)' `
    (Test-StripsLineCommentsOnly $founding) 'not reported'
  $viaLib = '$code = Get-PsCodeOnly -Text $t'
  T 'MUST NOT FIRE  a caller routed through the shared reduction is silent' `
    (-not (Test-StripsLineCommentsOnly $viaLib)) 'reported'
  $ownBlock = '$s = [regex]::Replace($t, ''(?s)<#.*?#>'', '''')' + "`n" + '$c = @($s -split "`n" | Where-Object { $_ -notmatch ''^\s*#'' })'
  T 'MUST NOT FIRE  a file that strips block comments ITSELF before the line strip is correct' `
    (-not (Test-StripsLineCommentsOnly $ownBlock)) 'reported'
  $noStrip = '$rows = @($lines | Where-Object { $_ -match ''price'' })'
  T 'MUST NOT FIRE  a file that never reduces source is not in this class at all' `
    (-not (Test-StripsLineCommentsOnly $noStrip)) 'reported'
  # CLEAN TWIN: THIS FILE. It names the idiom in its own header and builds its needles by
  # concatenation precisely so it cannot match itself. If that ever stops being true the detector
  # reports itself, someone adds an exclusion, and the exclusion is the next blind spot.
  $selfSrc = ''
  try { $selfSrc = [IO.File]::ReadAllText($PSCommandPath) } catch { }
  T 'CLEAN TWIN  the detector does not match its OWN source (needles are built, never written out)' `
    ($selfSrc -and (-not (Test-StripsLineCommentsOnly $selfSrc))) 'the detector found itself'
  # PS 5.1: @($null).Count is 1 ([[ps-null-count-is-one]]).
  T 'an empty finding set counts 0, not the PS 5.1 @($null) 1' ((@(@())).Count -eq 0) ([string](@(@())).Count)
  # THE WALK, FROM A WORKTREE ROOT (2026-09-11, lib\tree-walk.ps1). The skip list matched \.claude\ and
  # \worktrees\ on the FULL path, both of which are in every path of a linked worktree: 0 examined, exit 3.
  # THE NEGATIVE CASE IS A WORKTREE INSIDE grocery\, not the fixture's usual sibling under .claude\. This walk
  # starts in four module directories and never reaches .claude\, so a sibling there is skipped whatever the rule
  # says: a mutation that dropped the skip list entirely left that version of this case green. This one goes red.
  $wtFx = New-TcWorktreeFixture -Files @{ 'ops\a.ps1' = 'Write-Output 1'; 'lib\b.ps1' = 'Write-Output 2'
                                          'grocery\worktrees\stale\c.ps1' = 'Write-Output 3' }
  try {
    $wtFound = @(Get-ScsCandidateFiles -RootDir $wtFx.Root)
    $wtNested = @($wtFound | Where-Object { (Get-TcPathBelowRoot $_.FullName $wtFx.Root) -like '*\grocery\worktrees\*' })
    $wtHits = Measure-TcWorktreeFixture -Fixture $wtFx -Found $wtFound
    T 'MUST FIRE  a root that IS a worktree is scanned, not skipped whole' (($wtHits.Root - $wtNested.Count) -eq 2) ("root=" + $wtHits.Root)
    T 'MUST NOT FIRE  a worktree nested inside a scanned directory below that root is still skipped' ($wtNested.Count -eq 0) ("nested=" + $wtNested.Count)
  } finally { Remove-Item -LiteralPath $wtFx.Temp -Recurse -Force -ErrorAction SilentlyContinue }
  # THE LIVE PATH, DRIVEN (2026-09-11). The founding shape is a pre-push run-gates pass whose count FELL: it rewrote
  # the tracked baseline and left the pushing checkout dirty. These run THIS script as a child against a one-file
  # temp tree and a temp baseline, so they exercise the code a gate runs, not a copy of it. One directory per run,
  # removed in finally, because concurrent pushes run this suite in the same %TEMP%.
  $lt = Join-Path $env:TEMP ('scs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $lt -ErrorAction Stop | Out-Null
  try {
    $ltTree = Join-Path $lt 'tree'
    [void][IO.Directory]::CreateDirectory((Join-Path $ltTree 'ops'))
    [IO.File]::WriteAllText((Join-Path $ltTree 'ops\scan.ps1'), $founding, (New-Object Text.UTF8Encoding($false)))   # exactly one line-only scanner
    $ltBl = Join-Path $lt 'baseline.json'
    $ltSeedJson = [ordered]@{ generated = '2026-01-01T00:00:00'; line_only = 2; examined = 2; names = @('ops\scan.ps1', 'ops\retired.ps1') } | ConvertTo-Json -Depth 3
    $null = Write-TcLfFile $ltBl $ltSeedJson
    $ltSeed = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltBl))
    $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltBl
    $rc1 = $LASTEXITCODE
    $o1 = @($o1)
    $same1 = [string]::Equals($ltSeed, [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltBl)), [StringComparison]::Ordinal)
    T 'a FALL (1 line-only scanner, baseline 2) without -Tighten is spoken and NOT written, so a gate run leaves its checkout clean' `
      ($rc1 -eq 0 -and $same1 -and (($o1 -join "`n") -match 'CAN tighten')) ("rc=$rc1 baselineUnchanged=$same1")
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltBl -Tighten
    $rc2 = $LASTEXITCODE
    $b2 = [IO.File]::ReadAllBytes($ltBl)
    $cr2 = 0; foreach ($x in $b2) { if ($x -eq 13) { $cr2++ } }
    $bom2 = ($b2.Length -ge 3 -and $b2[0] -eq 0xEF -and $b2[1] -eq 0xBB -and $b2[2] -eq 0xBF)
    $doc2 = $null
    if ($bom2) { $doc2 = [Text.Encoding]::UTF8.GetString($b2, 3, $b2.Length - 3) | ConvertFrom-Json }
    T '-Tighten records the fall in the bytes git stores: no CR, the BOM, one trailing LF, and the new mark of 1' `
      ($rc2 -eq 0 -and $cr2 -eq 0 -and $bom2 -and $b2[-1] -eq 10 -and $null -ne $doc2 -and [int]$doc2.line_only -eq 1) `
      ("rc=$rc2 cr=$cr2 bom=$bom2 line_only=$(if ($doc2) { $doc2.line_only })")
    $ltRise = Join-Path $lt 'baseline-rise.json'
    $ltRiseJson = [ordered]@{ generated = '2026-01-01T00:00:00'; line_only = 0; examined = 0; names = @() } | ConvertTo-Json -Depth 3
    $null = Write-TcLfFile $ltRise $ltRiseJson
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltRise
    $rc3 = $LASTEXITCODE
    T 'CLEAN TWIN  a count that ROSE still fails the run with exit 2, so not writing on a fall did not disarm the ratchet' ($rc3 -eq 2) ("rc=$rc3")
  } finally {
    Remove-Item -LiteralPath $lt -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($bad -eq 0) { Write-Output 'SOURCE-COMMENT-STRIP SELF-TEST PASS'; Write-GuardComplete -Name 'source-comment-strip' -Summary 'selftest ok'; exit 0 }
  Write-Output ("SOURCE-COMMENT-STRIP SELF-TEST FAILED ($bad)"); Write-GuardComplete -Name 'source-comment-strip' -Summary "selftest failed=$bad"; exit 2
}

# ---- live scan ----
if (-not $Root) { $Root = $repo }
$rootFull = Get-TcRootFull $Root
$scanned = 0
$findings = New-Object System.Collections.Generic.List[string]
foreach ($f in @(Get-ScsCandidateFiles -RootDir $rootFull)) {
  $scanned++
  $p = $f.FullName
  $txt = ''
  try { $txt = [IO.File]::ReadAllText($p) } catch { continue }
  if (Test-StripsLineCommentsOnly $txt) { [void]$findings.Add((Get-TcPathBelowRoot $p $rootFull).TrimStart('\', '/')) }
}
if ($scanned -eq 0) {
  Write-Output 'source-comment-strip: BLIND - zero .ps1 files reached the scan, so a clean result would prove nothing'
  Exit-Guard -Name 'source-comment-strip' -Summary 'blind=nothing-scanned' -Code 3
}
$n = @($findings).Count
Write-Output ("source-comment-strip: examined {0} .ps1 file(s); {1} reduce source by dropping LINE comments only, so a block header still reaches whatever they match" -f $scanned, $n)
foreach ($w in $findings) { Write-Output ('  LINE-ONLY  ' + $w) }

$blF = if ($BaselineFile) { $BaselineFile } else { Join-Path $here 'out\source-comment-strip-baseline.json' }
$blDir = Split-Path $blF -Parent
if (-not (Test-Path $blDir)) { New-Item -ItemType Directory -Force $blDir | Out-Null }
$base = $null
if (Test-Path $blF) { try { $base = [int]((Get-Content $blF -Raw | ConvertFrom-Json).line_only) } catch { $base = $null } }
function Write-ScsBaseline([int]$Count) {
  $json = @{ generated = (Get-Date).ToString('s'); line_only = $Count; examined = $scanned; names = @($findings)
     note = 'High-water mark for the comment-strip ratchet (2026-09-07, the 8 libraries run-gates enrolled from their own headers). This number may only go DOWN.' } | ConvertTo-Json -Depth 3
  # LF with the BOM the committed blob carries, not the CRLF Set-Content writes under PS 5.1 (lib\lf-write.ps1).
  $null = Write-TcLfFile $blF $json
}
if ($Accept -or $null -eq $base) {
  Write-ScsBaseline $n
  Write-Output ("  baseline written: $n of $scanned examined. From here the number may only go DOWN.")
  Exit-Guard -Name 'source-comment-strip' -Summary "line_only=$n examined=$scanned baseline=$n" -Code 0
}
$move = Test-RatchetMove -Name 'source-comment-strip' -Count $n -Baseline $base
if ($move.Verdict -eq 'rose') {
  Write-Output ("source-comment-strip: RATCHET BROKEN - $n of $scanned examined, baseline $base. A new source scanner reduces PowerShell by line comments only, so a block header can be matched as code.")
  Exit-Guard -Name 'source-comment-strip' -Summary "line_only=$n examined=$scanned baseline=$base" -Code 2
}
if ($move.Verdict -eq 'tightened') {
  if ($Tighten) {
    Write-ScsBaseline $n
    Write-Output ("  ratchet tightened: $n, was $base. New baseline written - commit it, or it protects only this checkout.")
  } else {
    Write-Output ("  ratchet CAN tighten: $n, baseline $base. NOT written: this may be a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit ops\out\source-comment-strip-baseline.json.")
  }
} elseif ($move.Verdict -eq 'implausible') {
  Write-Output ('  ' + $move.Message + ' - baseline kept at ' + $base + ' (-Accept is this script''s -AcceptDrop.)')
  if ($Tighten) { Exit-Guard -Name 'source-comment-strip' -Summary "line_only=$n examined=$scanned baseline=$base refused-to-lower" -Code 2 }
}
Write-Output ("source-comment-strip: $n of $scanned examined, against a baseline of $base.")
Exit-Guard -Name 'source-comment-strip' -Summary "line_only=$n examined=$scanned baseline=$base" -Code 0
