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

  EXIT: 0 held or tightened, 2 the count rose, 3 could not evaluate (no documents, or no git).
#>
[CmdletBinding()]
param([switch]$SelfTest, [switch]$Json, [switch]$Accept, [switch]$ReportOnly)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')

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
$docs = @(Get-ChildItem (Join-Path $repo 'design') -File -Filter '*.md' -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -like 'EVAL-*' -or $_.Name -like 'MEASURE-*' } | Sort-Object Name)
if ($docs.Count -eq 0) {
  Write-Output 'CONCLUSION CURRENCY BLIND: no EVAL-* or MEASURE-* documents under design\ - nothing was judged.'
  if ($Json) { 'conclusion-currency-json: {"known": false}' }
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 3 -Summary 'docs=0 blind=1'
}
$head = & git -C $repo rev-parse --verify --quiet HEAD
if ($LASTEXITCODE -ne 0 -or -not $head) {
  Write-Output 'CONCLUSION CURRENCY BLIND: not a git checkout, so no harness history can be read.'
  if ($Json) { 'conclusion-currency-json: {"known": false}' }
  Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 3 -Summary "docs=$($docs.Count) blind=1"
}

$hashExists = { param($h) $null = & git -C $repo rev-parse --verify --quiet "$h^{commit}"; return ($LASTEXITCODE -eq 0) }
$pathExists = { param($p) return (Test-Path -LiteralPath (Join-Path $repo ($p -replace '/', '\'))) }
$afterFn = { param($h, $p) $n = & git -C $repo rev-list --count "$h..HEAD" -- $p; return [int]("$n".Trim()) }

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
        $newest = & git -C $repo log -1 '--format=%h %cs' -- $m.Path
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

$blF = Join-Path $here 'conclusion-currency-baseline.json'
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
if ($move.Verdict -eq 'tightened') { Write-CcBaseline $unq; Write-Output "  ratchet tightened: $unq, was $base." }
elseif ($move.Verdict -eq 'implausible') { Write-Output ('  ' + $move.Message + ' - baseline kept at ' + $base) }
Exit-Guard -Name 'CONCLUSION-CURRENCY' -Code 0 -Summary "docs=$($docs.Count) unqualified=$unq baseline=$base"
