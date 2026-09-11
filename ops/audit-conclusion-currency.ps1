<#
  audit-conclusion-currency.ps1 - a recorded conclusion whose harness has moved since is UNQUALIFIED.

  WS 7d of design\PLAN-brain-v2-2026-09-09.md.

  THE SHAPE. .claude\rules\measurement.md: "name the harness and the commit it ran at". A moved harness
  does not make a verdict wrong; it makes it UNQUALIFIED until somebody re-reads it. This estate has
  paid for that twice - a 30.9-vs-41.7-minute verdict that reverted a working parallel path, and a
  wall-clock EVAL that was arithmetically true and causally wrong - and both were caught by a person
  re-reading a commit clock months later, by luck. ops\audit-measurement-provenance.ps1 makes a
  document NAME its harness and commit. Nothing checked whether that harness had moved since. This is
  the back-link.

  WHAT IT READS. design\EVAL-*.md and design\MEASURE-*.md, the population the provenance audit owns.
    a HARNESS       a repo path to a .ps1 or .py on a line that says harness, measured through, ran
                    through, or generated ... by - and that exists.
    a CITED COMMIT  a hash on a line that says commit, which git resolves to a commit.
  UNQUALIFIED when a named harness has a commit after the NEWEST cited commit. To re-qualify, re-read
  the conclusion against the moved harness and add a line such as
      Re-read at commit <hash>: <what still holds>
  which becomes the newest cited commit.

  A RATCHET on the UNQUALIFIED count (lib\ratchet.ps1). The baseline was every qualifiable document on
  the day this shipped, so it fires only when a conclusion that WAS current goes stale in a push. A
  document naming no harness or no resolvable commit is NOT QUALIFIABLE: that is the provenance audit's
  finding, listed here and not counted twice.

  SCOPE OF A CLEAN REPORT: UNSOUND. It finds harnesses by the words on their line and commits by
  spelling. A conclusion whose harness is named in prose it does not recognise is NOT QUALIFIABLE, not
  current, and a moved harness that changed no behaviour still reads UNQUALIFIED - which is correct,
  because deciding that it changed nothing IS the re-read.

  A RUN THAT IS NOT ASKED TO RECORD WRITES NOTHING (2026-09-11). run-gates runs this with no arguments on every
  pre-push, and a fall used to rewrite the TRACKED baseline right there: the pushing checkout was left dirty, the
  lower mark never rode that push, and a count taken over uncommitted edits is not a baseline. So a fall is SPOKEN
  and the committed mark KEPT; -Tighten records it. ops\audit-write-only-reports.ps1 carries the full account.

    ops\audit-conclusion-currency.ps1              judge the documents, hold the ratchet; writes nothing
    ops\audit-conclusion-currency.ps1 -Tighten     the same, and record a believable FALL as the new high-water mark
    ops\audit-conclusion-currency.ps1 -Accept      record the CURRENT count as the new high-water mark
    ops\audit-conclusion-currency.ps1 -SelfTest    frozen fixtures, plus this script's live path run against a temp repository

  EXIT: 0 held, tightened or able to tighten, 2 the count rose or -Tighten refused an implausible fall, 3 could not
  evaluate (no documents, or no git).
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json, [switch]$Accept, [switch]$ReportOnly, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')

# -Root and -BaselineFile exist so the self-test can drive the LIVE path against a temp repository. A gate passes neither.
$treeRoot = if ($Root) { $Root } else { $repo }

$script:HARNESS_LINE = '(?i)\b(harness|measured through|ran through|generated\b.{0,80}\bby)\b'
$script:COMMIT_LINE  = '(?i)\bcommit\b'
$script:PATH_RX = '(?<![\w/\\.-])((?:ops|grocery|graph|meal-prep|sidecar|lib|tools)[\\/][A-Za-z0-9_.\\/-]+?\.(?:ps1|py))(?![\w])'
$script:HASH_RX = '(?<![0-9A-Za-z])([0-9a-f]{7,40})(?![0-9A-Za-z])'

function Get-HarnessPaths {
  <# Repo-relative harness paths named on a harness line OR THE LINE AFTER IT, forward slashes, de-duplicated.

     THE LINE AFTER, because the first live run read EVAL-alert-retention-2026-09-09.md as naming no
     harness: its line 6 is "**Harness and commit** (per ...): the snapshot producer is" and the path
     wraps onto line 7. Markdown prose wraps at a column, not at a sentence. #>
  param([string]$Text)
  $out = New-Object System.Collections.Generic.List[string]
  $all = $Text -split "`r?`n"
  for ($i = 0; $i -lt $all.Count; $i++) {
    if ($all[$i] -notmatch $script:HARNESS_LINE) { continue }
    $line = $all[$i]
    if ($i + 1 -lt $all.Count) { $line = $line + ' ' + $all[$i + 1] }
    foreach ($m in [regex]::Matches($line, $script:PATH_RX)) {
      $p = $m.Groups[1].Value -replace '\\', '/'
      if (-not $out.Contains($p)) { [void]$out.Add($p) }
    }
  }
  $arr = $out.ToArray()
  return ,$arr
}

function Get-CitedHashes {
  <# Hash-shaped tokens on a commit line. A token must carry a letter AND a digit: a date, a count and a
     word like "accede" all fail that, and an all-digit hash is rare enough to be named by hand. #>
  param([string]$Text)
  $out = New-Object System.Collections.Generic.List[string]
  $all = $Text -split "`r?`n"
  for ($i = 0; $i -lt $all.Count; $i++) {
    if ($all[$i] -notmatch $script:COMMIT_LINE) { continue }
    # The line after as well, for the same reason Get-HarnessPaths reads it: EVAL-alert-retention-2026-09-09.md
    # writes "The commit that introduced both is" and puts **`60e944660`** at the start of the next line.
    $line = $all[$i]
    if ($i + 1 -lt $all.Count) { $line = $line + ' ' + $all[$i + 1] }
    foreach ($m in [regex]::Matches($line, $script:HASH_RX)) {
      $h = $m.Groups[1].Value
      if ($h -cmatch '[a-f]' -and $h -match '[0-9]' -and -not $out.Contains($h)) { [void]$out.Add($h) }
    }
  }
  $arr = $out.ToArray()
  return ,$arr
}

function Get-CurrencyVerdict {
  <# @{ Verdict = CURRENT | UNQUALIFIED | NOT-QUALIFIABLE; Moved = @(@{Path; After; Since}); Why }.
     Pure over its scriptblocks, so the fixtures never touch git. #>
  param([string[]]$Paths, [string[]]$Hashes, [scriptblock]$HashExists, [scriptblock]$PathExists, [scriptblock]$After)
  $real = @(@($Hashes) | Where-Object { $_ -and (& $HashExists $_) })
  $hp = @(@($Paths) | Where-Object { $_ -and (& $PathExists $_) })
  if ($hp.Count -eq 0) { return @{ Verdict = 'NOT-QUALIFIABLE'; Moved = @(); Why = 'names no harness that exists' } }
  if ($real.Count -eq 0) { return @{ Verdict = 'NOT-QUALIFIABLE'; Moved = @(); Why = 'cites no commit git can resolve' } }
  $moved = New-Object System.Collections.Generic.List[object]
  foreach ($p in $hp) {
    $min = $null; $since = ''
    foreach ($h in $real) {
      $n = [int](& $After $h $p)
      if ($null -eq $min -or $n -lt $min) { $min = $n; $since = $h }
    }
    if ($min -gt 0) { [void]$moved.Add(@{ Path = $p; After = $min; Since = $since }) }
  }
  if ($moved.Count -gt 0) { return @{ Verdict = 'UNQUALIFIED'; Moved = $moved.ToArray(); Why = '' } }
  return @{ Verdict = 'CURRENT'; Moved = @(); Why = '' }
}

if ($SelfTest) {
  $ran = New-Object System.Collections.Generic.List[string]
  $fails = New-Object System.Collections.Generic.List[string]
  function Case([string]$Label, [string]$Name, [bool]$Ok, [string]$Detail = '') {
    [void]$ran.Add($Name)
    if (-not $Ok) { [void]$fails.Add("$Label $Name") }
    Write-Output ("  {0,-14} {1,-66} {2}" -f $Label, $Name, $(if ($Ok) { 'ok' } else { "FAIL $Detail" }))
  }
  $yes = { param($x) $true }
  $no = { param($x) $false }

  $t1 = 'Harness: grocery/guards.ps1, run three times.'
  $hp1 = Get-HarnessPaths -Text $t1
  $p1 = @($hp1)
  Case 'MUST FIRE' 'a script named on a harness line is the harness' ($p1.Count -eq 1 -and $p1[0] -eq 'grocery/guards.ps1') ($p1 -join ',')
  $t2 = 'Commit it ran at: 47150b330.'
  $hh2 = Get-CitedHashes -Text $t2
  $h2 = @($hh2)
  Case 'MUST FIRE' 'a hash on a commit line is a cited commit' ($h2.Count -eq 1 -and $h2[0] -eq '47150b330') ($h2 -join ',')
  $v3 = Get-CurrencyVerdict -Paths @('grocery/guards.ps1') -Hashes @('47150b330') -HashExists $yes -PathExists $yes -After { param($h, $p) 2 }
  Case 'MUST FIRE' 'a harness with commits after the cited one is UNQUALIFIED' ($v3.Verdict -eq 'UNQUALIFIED' -and $v3.Moved[0].After -eq 2) $v3.Verdict

  $tw = "**Harness and commit** (per the rule): the snapshot producer is`n``ops/member-cohorts.ps1``, run nightly."
  $hpw = Get-HarnessPaths -Text $tw
  $pw = @($hpw)
  Case 'MUST FIRE' 'a harness path wrapped onto the line after the harness line is still found' ($pw.Count -eq 1 -and $pw[0] -eq 'ops/member-cohorts.ps1') ($pw -join ',')
  $t5 = "We then looked at grocery/check-ad-cycles.ps1 for a while.`n`nAnd later at ops/run-gates.ps1 too."
  $hp5 = Get-HarnessPaths -Text $t5
  $p5 = @($hp5)
  Case 'MUST NOT FIRE' 'a script named in prose, not on a harness line, is not a harness' ($p5.Count -eq 0) ($p5 -join ',')
  $hhw = Get-CitedHashes -Text "The commit that introduced both is`n**``60e944660``**, dated 2026-09-09."
  $hw = @($hhw)
  Case 'MUST FIRE' 'a hash wrapped onto the line after the commit line is still cited' ($hw.Count -eq 1 -and $hw[0] -eq '60e944660') ($hw -join ',')
  $hh6 = Get-CitedHashes -Text 'The commit landed on 2026-09-09 after 1630 seconds, and the fix was accede.'
  $h6 = @($hh6)
  Case 'MUST NOT FIRE' 'a date, a count and a hex-letter word on a commit line are not hashes' ($h6.Count -eq 0) ($h6 -join ',')
  $v7 = Get-CurrencyVerdict -Paths @('grocery/guards.ps1') -Hashes @('abc1234') -HashExists $no -PathExists $yes -After { param($h, $p) 9 }
  Case 'MUST NOT FIRE' 'a hash git cannot resolve leaves the document NOT QUALIFIABLE, not unqualified' ($v7.Verdict -eq 'NOT-QUALIFIABLE') $v7.Verdict
  $v8 = Get-CurrencyVerdict -Paths @('grocery/gone.ps1') -Hashes @('abc1234') -HashExists $yes -PathExists $no -After { param($h, $p) 9 }
  Case 'MUST NOT FIRE' 'a harness path that does not exist is not a harness' ($v8.Verdict -eq 'NOT-QUALIFIABLE') $v8.Verdict
  $hh9 = Get-CitedHashes -Text 'See commit deadbeef and commit 12345678.'
  $h9 = @($hh9)
  Case 'MUST NOT FIRE' 'all-letter and all-digit tokens are not taken as hashes' ($h9.Count -eq 0) ($h9 -join ',')

  $v10 = Get-CurrencyVerdict -Paths @('ops/run-gates.ps1') -Hashes @('679a153') -HashExists $yes -PathExists $yes -After { param($h, $p) 0 }
  Case 'CLEAN TWIN' 'an unmoved harness is CURRENT' ($v10.Verdict -eq 'CURRENT') $v10.Verdict
  $after = { param($h, $p) if ($h -eq 'aaa1111') { 5 } else { 0 } }
  $v11 = Get-CurrencyVerdict -Paths @('ops/run-gates.ps1') -Hashes @('aaa1111', 'bbb2222') -HashExists $yes -PathExists $yes -After $after
  Case 'CLEAN TWIN' 'a re-read line citing a NEWER commit re-qualifies the conclusion' ($v11.Verdict -eq 'CURRENT') $v11.Verdict
  $hp12 = Get-HarnessPaths -Text 'Measured through meal-prep\pipeline\hunt-run.ps1 at width 4.'
  $p12 = @($hp12)
  Case 'CLEAN TWIN' 'a backslash path is read and normalised to forward slashes' ($p12.Count -eq 1 -and $p12[0] -eq 'meal-prep/pipeline/hunt-run.ps1') ($p12 -join ',')
  $docs = @(Get-ChildItem (Join-Path $repo 'design') -File -Filter '*.md' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'EVAL-*' -or $_.Name -like 'MEASURE-*' })
  Case 'CLEAN TWIN' 'the population is the EVAL-* and MEASURE-* documents, and it is not empty' ($docs.Count -gt 0) "$($docs.Count)"

  # THE LIVE PATH, DRIVEN (2026-09-11). The founding shape is a pre-push run-gates pass whose count FELL: it rewrote
  # the tracked baseline and left the pushing checkout dirty. These run THIS script as a child against a temp git
  # repository whose one EVAL document cites a commit its harness has since moved past, and a temp baseline, so they
  # exercise the code a gate runs, not a copy of it. One directory per run, removed in finally, because concurrent
  # pushes run this suite in the same %TEMP%.
  # THE REPOSITORY ENVIRONMENT IS CLEARED FIRST (lib\git-repo-env.ps1): under a hook in a linked worktree GIT_DIR is
  # exported, and the git init and git -C <temp> config below would otherwise write the shared .git.
  . (Join-Path $repo 'lib\git-repo-env.ps1')
  Clear-TcGitRepoEnv
  $lt = Join-Path $env:TEMP ('cc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $lt -ErrorAction Stop | Out-Null
  try {
    $ltTree = Join-Path $lt 'tree'
    [void][IO.Directory]::CreateDirectory((Join-Path $ltTree 'ops'))
    [void][IO.Directory]::CreateDirectory((Join-Path $ltTree 'design'))
    $ltUtf8 = New-Object Text.UTF8Encoding($false)
    $null = & git -c init.defaultBranch=main init -q $ltTree
    $null = & git -C $ltTree config user.name Fixture
    $null = & git -C $ltTree config user.email t@t
    $null = & git -C $ltTree config commit.gpgsign false
    [IO.File]::WriteAllText((Join-Path $ltTree 'ops\h.ps1'), 'Write-Output 1', $ltUtf8)
    $null = & git -C $ltTree add -- ops/h.ps1
    $null = & git -C $ltTree commit -q -m one
    $ltCited = ([string](& git -C $ltTree rev-parse HEAD)).Trim()
    [IO.File]::WriteAllText((Join-Path $ltTree 'ops\h.ps1'), 'Write-Output 2', $ltUtf8)
    $null = & git -C $ltTree add -- ops/h.ps1
    $null = & git -C $ltTree commit -q -m two   # the harness moves after the cited commit
    [IO.File]::WriteAllText((Join-Path $ltTree 'design\EVAL-fixture.md'), ("Harness: ops/h.ps1`nCommit it ran at: " + $ltCited + "`n"), $ltUtf8)
    $ltBl = Join-Path $lt 'baseline.json'
    [IO.File]::WriteAllText($ltBl, "{`n    ""unqualified"":  2,`n    ""note"":  ""fixture""`n}`n", $ltUtf8)
    $ltSeed = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltBl))
    $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltBl
    $rc1 = $LASTEXITCODE
    $o1 = @($o1)
    $same1 = [string]::Equals($ltSeed, [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltBl)), [StringComparison]::Ordinal)
    $tally1 = (@($o1) -match 'document\(s\) UNQUALIFIED') -join ' '
    Case 'LIVE PATH' 'a FALL (1 unqualified, baseline 2) without -Tighten is spoken and NOT written, so a gate run leaves its checkout clean' `
      ($rc1 -eq 0 -and $same1 -and (($o1 -join "`n") -match 'CAN tighten')) ("rc=$rc1 baselineUnchanged=$same1 $tally1")
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltBl -Tighten
    $rc2 = $LASTEXITCODE
    $b2 = [IO.File]::ReadAllBytes($ltBl)
    $cr2 = 0; foreach ($x in $b2) { if ($x -eq 13) { $cr2++ } }
    $bom2 = ($b2.Length -ge 3 -and $b2[0] -eq 0xEF -and $b2[1] -eq 0xBB -and $b2[2] -eq 0xBF)
    $doc2 = $null
    try { $doc2 = [Text.Encoding]::UTF8.GetString($b2) | ConvertFrom-Json } catch { }
    # The committed blob is LF, no BOM, one trailing LF, and -Tighten must keep that shape.
    Case 'LIVE PATH' '-Tighten records the fall in the committed shape: no CR, no BOM, one trailing LF, and the new mark of 1' `
      ($rc2 -eq 0 -and $cr2 -eq 0 -and -not $bom2 -and $b2[-1] -eq 10 -and $null -ne $doc2 -and [int]$doc2.unqualified -eq 1) `
      ("rc=$rc2 cr=$cr2 bom=$bom2 unqualified=$(if ($doc2) { $doc2.unqualified })")
    $ltRise = Join-Path $lt 'baseline-rise.json'
    [IO.File]::WriteAllText($ltRise, "{`n    ""unqualified"":  0,`n    ""note"":  ""fixture""`n}`n", $ltUtf8)
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltRise
    $rc3 = $LASTEXITCODE
    Case 'CLEAN TWIN' 'a count that ROSE still fails the run with exit 2, so not writing on a fall did not disarm the ratchet' ($rc3 -eq 2) ("rc=$rc3")
  } finally {
    Remove-Item -LiteralPath $lt -Recurse -Force -ErrorAction SilentlyContinue
  }

  Write-Output ''
  if ($fails.Count) {
    Write-Output ("audit-conclusion-currency selftest: {0} FAILED of {1}" -f $fails.Count, $ran.Count)
    $fails | ForEach-Object { Write-Output "  $_" }
    Exit-Guard -Name 'CONCLUSION-CURRENCY-SELFTEST' -Code 1 -Summary "failed=$($fails.Count) cases=$($ran.Count)"
  }
  Write-Output ("audit-conclusion-currency selftest: {0} of {0} cases pass" -f $ran.Count)
  Exit-Guard -Name 'CONCLUSION-CURRENCY-SELFTEST' -Code 0 -Summary "cases=$($ran.Count)"
}

# ------------------------------------------------------------------------------------------------ live
$docs = @(Get-ChildItem (Join-Path $treeRoot 'design') -File -Filter '*.md' -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -like 'EVAL-*' -or $_.Name -like 'MEASURE-*' } | Sort-Object Name)
if ($docs.Count -eq 0) {
  Write-Output 'CONCLUSION CURRENCY BLIND: no EVAL-* or MEASURE-* documents under design\ - nothing was judged.'
  if ($Json) { 'conclusion-currency-json: {"known": false}' }
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 3 -Summary 'docs=0 blind=1'
}
$head = & git -C $treeRoot rev-parse --verify --quiet HEAD
if ($LASTEXITCODE -ne 0 -or -not $head) {
  Write-Output 'CONCLUSION CURRENCY BLIND: not a git checkout, so no harness history can be read.'
  if ($Json) { 'conclusion-currency-json: {"known": false}' }
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 3 -Summary "docs=$($docs.Count) blind=1"
}

$hashExists = { param($h) $null = & git -C $treeRoot rev-parse --verify --quiet "$h^{commit}"; return ($LASTEXITCODE -eq 0) }
$pathExists = { param($p) return (Test-Path -LiteralPath (Join-Path $treeRoot ($p -replace '/', '\'))) }
$afterFn = { param($h, $p) $n = & git -C $treeRoot rev-list --count "$h..HEAD" -- $p; return [int]("$n".Trim()) }

$unq = 0; $cur = 0; $nq = 0
Write-Output 'CONCLUSION CURRENCY - does each recorded conclusion still describe the harness it names?'
Write-Output ''
foreach ($d in $docs) {
  $text = [IO.File]::ReadAllText($d.FullName)
  $hpR = Get-HarnessPaths -Text $text
  $paths = @($hpR)
  $hhR = Get-CitedHashes -Text $text
  $hashes = @($hhR)
  $v = Get-CurrencyVerdict -Paths $paths -Hashes $hashes -HashExists $hashExists -PathExists $pathExists -After $afterFn
  switch ($v.Verdict) {
    'UNQUALIFIED' {
      $unq++
      Write-Output ("  UNQUALIFIED      {0}" -f $d.Name)
      foreach ($m in @($v.Moved)) {
        $newest = & git -C $treeRoot log -1 '--format=%h %cs' -- $m.Path
        Write-Output ("                   {0} has {1} commit(s) after cited {2}; newest {3}" -f $m.Path, $m.After, $m.Since, "$newest".Trim())
      }
    }
    'CURRENT' { $cur++; Write-Output ("  current          {0}" -f $d.Name) }
    default { $nq++; Write-Output ("  not qualifiable  {0} - {1}" -f $d.Name, $v.Why) }
  }
}
Write-Output ''
Write-Output ("  {0} of {1} document(s) UNQUALIFIED, {2} current, {3} not qualifiable (ops\audit-measurement-provenance.ps1's finding)" -f $unq, $docs.Count, $cur, $nq)
Write-Output '  To re-qualify one: re-read it against the moved harness and add "Re-read at commit <hash>: <what still holds>".'

$blF = if ($BaselineFile) { $BaselineFile } else { Join-Path $here 'conclusion-currency-baseline.json' }
$base = $null
if (Test-Path $blF) { try { $base = [int]([IO.File]::ReadAllText($blF) | ConvertFrom-Json).unqualified } catch { $base = $null } }
function Write-CcBaseline([int]$Count) {
  $o = [ordered]@{ unqualified = $Count; examined = $docs.Count; recorded = (Get-Date).ToString('yyyy-MM-dd')
                   note = 'High-water mark for the conclusion-currency ratchet (WS 7d, 2026-09-10). May only go DOWN; a re-read lowers it.' }
  [IO.File]::WriteAllText($blF, ((($o | ConvertTo-Json) -replace "`r`n", "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
}
if ($Json) {
  'conclusion-currency-json: ' + (([ordered]@{ known = $true; docs = $docs.Count; unqualified = $unq; current = $cur; not_qualifiable = $nq }) | ConvertTo-Json -Compress)
}
if ($ReportOnly) {
  # ops\brain-report.ps1 reads and never writes. The ratchet's verdict is run-gates' to give, and a report that
  # could tighten a baseline as a side effect of being read would be a writer by accident.
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 0 -Summary "docs=$($docs.Count) unqualified=$unq report-only=1"
}
if ($Accept -or $null -eq $base) {
  Write-CcBaseline $unq
  Write-Output "  baseline written: $unq of $($docs.Count). From here the number may only go DOWN."
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 0 -Summary "docs=$($docs.Count) unqualified=$unq baseline=$unq"
}
$move = Test-RatchetMove -Name 'conclusion-currency' -Count $unq -Baseline $base
if ($move.Verdict -eq 'rose') {
  Write-Output "conclusion-currency: RATCHET BROKEN - $unq unqualified, baseline $base. A conclusion that was current now names a harness changed after it. Re-read it and add a Re-read at commit line."
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 2 -Summary "docs=$($docs.Count) unqualified=$unq baseline=$base"
}
if ($move.Verdict -eq 'tightened') {
  if ($Tighten) {
    Write-CcBaseline $unq
    Write-Output "  ratchet tightened: $unq, was $base. New baseline written - commit it, or it protects only this checkout."
  } else {
    Write-Output "  ratchet CAN tighten: $unq unqualified, baseline $base. NOT written: this may be a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit ops\conclusion-currency-baseline.json."
  }
} elseif ($move.Verdict -eq 'implausible') {
  Write-Output ('  ' + $move.Message + ' - baseline kept at ' + $base + ' (-Accept is this script''s -AcceptDrop.)')
  if ($Tighten) { Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 2 -Summary "docs=$($docs.Count) unqualified=$unq baseline=$base refused-to-lower" }
}
Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 0 -Summary "docs=$($docs.Count) unqualified=$unq baseline=$base"
