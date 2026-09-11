<#
  audit-ruling-drift.ps1 - a ruling document says what this estate does; a script does it. This checks
  they still agree.

  SCOPE OF A CLEAN REPORT: UNSOUND, and this is the one where it matters most. It compares a
    ruling's stated numbers and names against what a script contains, by pattern. A clean
    report means the pairs it was TOLD to compare still agree. A ruling nobody wired in here
    has never been compared to anything, and looks identical from the outside to one that
    agrees.

  WHY THIS EXISTS (2026-09-06, backlog E12). ops\audit-twin-drift.ps1 covers CODE-to-CODE duplication:
  one rule implemented in two files, with a scoreboard of five real bugs behind it. Nothing covered
  DOCUMENT-to-CODE, which is the shape E12 names - Brad's rulings, the band rules and the naming
  conventions are written for humans and change WITHOUT A DEPLOY, so the document moves and the script
  enforcing it does not notice.

  ITS FOUNDING CASE WAS ALREADY LIVE AND ALREADY WRITTEN DOWN, WHICH IS THE ARGUMENT FOR IT. Brad ruled
  on 2026-09-04 that every hard-coded macro band goes, because the band is his and is stated per run.
  design\BRIEF-no-hardcoded-bands-2026-09-04.md carries the ruling, the survey and the fixtures. Its
  `shipped_commit` field still reads "(none yet)", DEFAULT_COND and DEFAULT_BAND are still at lines 105
  and 114 of hunt-daemon.py, resolve_conditions still falls back to the prose one, and
  design\PLAN-after-dedup-2026-09-04.md records in passing that "the prose side still reaches three
  agent prompts". So the contradiction was known, recorded, and gated by nothing.

  A RATCHET, NOT A HARD FAIL. Three violations exist on the day this ships and failing the gate on them
  would make it the gate everyone skips - run-gates' own header explains why. The baseline is a
  high-water mark that may only go DOWN. Implementing a ruling lowers it permanently; adding a NEW
  contradiction fails.

  WHAT THIS DOES NOT DO: it does not implement any ruling. Executing the bands brief is its own queued
  work with its own fixtures, and doing it here under E12's name would be a different item wearing this
  one's clothes. This makes the debt LOUD and non-growable, which is what E12 actually asks for.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  A RUN THAT IS NOT ASKED TO RECORD WRITES NOTHING (2026-09-11). run-gates runs this with no arguments on every
  pre-push, and a fall used to rewrite the TRACKED baseline right there: the pushing checkout was left dirty, the
  lower mark never rode that push, and a count taken over uncommitted edits is not a baseline. So a fall is SPOKEN
  and the committed mark KEPT; -Tighten records it. ops\audit-write-only-reports.ps1 carries the full account.

    ops\audit-ruling-drift.ps1               check the registry, hold the ratchet; writes nothing
    ops\audit-ruling-drift.ps1 -Tighten      the same, and record a believable FALL as the new high-water mark
    ops\audit-ruling-drift.ps1 -AcceptDrop   record a fall lib\ratchet.ps1 would refuse
    ops\audit-ruling-drift.ps1 -SelfTest     frozen fixtures, plus this script's live path run against a temp tree
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [switch]$AcceptDrop, [switch]$Tighten, [string]$Root = '', [string]$BaselineFile = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')
. (Join-Path $repo 'lib\ratchet.ps1')
. (Join-Path $repo 'lib\lf-write.ps1')   # Write-TcLfFile: the baseline is tracked and stored eol=lf

# -Root and -BaselineFile exist so the self-test can drive the LIVE path against a temp tree. A gate passes neither.
$treeRoot = if ($Root) { $Root } else { $repo }
$REGISTRY = Join-Path $treeRoot 'ops\ruling-implementations.json'
$BASELINE = if ($BaselineFile) { $BaselineFile } else { Join-Path $treeRoot 'ops\ruling-drift-baseline.json' }

function Test-TcSymbolPresent {
  <# Is $Symbol used as CODE in these lines? Comment lines are stripped first: a header explaining why
     a constant must go is not the constant. The bands brief is discussed at length inside the very
     file it indicts, so without this the gate could never read clean even after the fix. #>
  param([string[]]$Lines, [string]$Symbol)
  foreach ($l in @($Lines)) {
    if ($l -match '^\s*#') { continue }
    if ($l -cmatch ('\b' + [regex]::Escape($Symbol) + '\b')) { return $true }
  }
  return $false
}

function Get-TcRulingViolations {
  <# Pure. $Rulings is the registry list; $Reader returns the lines of a repo-relative path, or $null
     when the file is missing. A MISSING FILE IS NOT A PASS - it is its own finding, because a rule
     about a file nobody can read has stopped being checked. #>
  param([object[]]$Rulings, [scriptblock]$Reader)
  $out = @()
  foreach ($r in @($Rulings)) {
    $lines = & $Reader $r.file
    if ($null -eq $lines) {
      $out += [pscustomobject]@{ Id = $r.id; Kind = 'file-missing'; Detail = ("cannot read " + $r.file) }
      continue
    }
    $present = Test-TcSymbolPresent -Lines $lines -Symbol $r.symbol
    if ($r.must -eq 'absent' -and $present) {
      $out += [pscustomobject]@{ Id = $r.id; Kind = 'ruling-not-implemented'
                                 Detail = ($r.symbol + ' is still live in ' + $r.file) }
    } elseif ($r.must -eq 'present' -and -not $present) {
      $out += [pscustomobject]@{ Id = $r.id; Kind = 'ruling-regressed'
                                 Detail = ($r.symbol + ' has gone from ' + $r.file) }
    }
  }
  return ,@($out)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  T 'MUST FIRE  a symbol used as code is present' (Test-TcSymbolPresent -Lines @('x = DEFAULT_COND') -Symbol 'DEFAULT_COND') 'missed'
  # THE CASE WITHOUT WHICH THIS GATE COULD NEVER READ CLEAN: the file that must lose a constant is the
  # same file whose header explains at length why it must go.
  T 'CLEAN TWIN a symbol only NAMED IN A COMMENT is not present' `
    (-not (Test-TcSymbolPresent -Lines @('# DEFAULT_COND above states the same numbers in prose') -Symbol 'DEFAULT_COND')) 'a comment counted as an implementation'
  T 'MUST NOT FIRE a different symbol does not match' (-not (Test-TcSymbolPresent -Lines @('x = OTHER_CONST') -Symbol 'DEFAULT_COND')) 'false match'
  T 'MUST NOT FIRE case matters - default_cond is not DEFAULT_COND' (-not (Test-TcSymbolPresent -Lines @('x = default_cond') -Symbol 'DEFAULT_COND')) 'case-insensitive match'

  $R = @([pscustomobject]@{ id = 'r1'; file = 'a.py'; symbol = 'GONE'; must = 'absent' },
         [pscustomobject]@{ id = 'r2'; file = 'b.py'; symbol = 'KEEP'; must = 'present' })

  $v1 = Get-TcRulingViolations -Rulings $R -Reader { param($p) if ($p -eq 'a.py') { @('x = GONE') } else { @('y = KEEP') } }
  T 'MUST FIRE  a ruling that says DELETE and the symbol is still there' `
    (@($v1).Count -eq 1 -and $v1[0].Kind -eq 'ruling-not-implemented') (($v1 | ForEach-Object { $_.Kind }) -join ',')

  $v2 = Get-TcRulingViolations -Rulings $R -Reader { param($p) if ($p -eq 'a.py') { @('x = 1') } else { @('y = 1') } }
  T 'MUST FIRE  a ruling that says KEEP and the symbol has gone is a REGRESSION' `
    (@($v2).Count -eq 1 -and $v2[0].Kind -eq 'ruling-regressed') (($v2 | ForEach-Object { $_.Kind }) -join ',')

  $v3 = Get-TcRulingViolations -Rulings $R -Reader { param($p) if ($p -eq 'a.py') { @('x = 1') } else { @('y = KEEP') } }
  T 'MUST NOT FIRE both rulings honoured raises nothing' (@($v3).Count -eq 0) (($v3 | ForEach-Object { $_.Kind }) -join ',')

  # A rule about a file nobody can read has stopped being checked, and that must not read as a pass.
  $v4 = Get-TcRulingViolations -Rulings $R -Reader { param($p) $null }
  T 'MUST FIRE  an unreadable file is its own finding, never a silent pass' `
    (@($v4).Count -eq 2 -and $v4[0].Kind -eq 'file-missing') (($v4 | ForEach-Object { $_.Kind }) -join ',')

  T 'MUST FIRE  a single violation comes back as an ARRAY, not unrolled' ($v1 -is [array]) ($v1.GetType().FullName)

  # THE LIVE PATH, DRIVEN (2026-09-11). The founding shape is a pre-push run-gates pass whose count FELL: it rewrote
  # the tracked baseline and left the pushing checkout dirty. These run THIS script as a child against a temp tree
  # holding one unimplemented ruling and a temp baseline, so they exercise the code a gate runs, not a copy of it.
  # One directory per run, removed in finally, because concurrent pushes run this suite in the same %TEMP%.
  $lt = Join-Path $env:TEMP ('rd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $lt -ErrorAction Stop | Out-Null
  try {
    $ltTree = Join-Path $lt 'tree'
    [void][IO.Directory]::CreateDirectory((Join-Path $ltTree 'ops'))
    $ltUtf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $ltTree 'doc.md'), '# the fixture ruling', $ltUtf8)
    [IO.File]::WriteAllText((Join-Path $ltTree 'a.py'), 'x = GONE', $ltUtf8)
    [IO.File]::WriteAllText((Join-Path $ltTree 'ops\ruling-implementations.json'), '{ "rulings": [ { "id": "r1", "document": "doc.md", "file": "a.py", "symbol": "GONE", "must": "absent", "ruled": "fixture", "why": "fixture" } ] }', $ltUtf8)
    $ltBl = Join-Path $lt 'baseline.json'
    $ltSeedJson = [ordered]@{ generated = '2026-01-01T00:00:00'; violations = 2; note = 'fixture' } | ConvertTo-Json -Depth 3
    $null = Write-TcLfFile $ltBl $ltSeedJson
    $ltSeed = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltBl))
    $o1 = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltBl
    $rc1 = $LASTEXITCODE
    $o1 = @($o1)
    $same1 = [string]::Equals($ltSeed, [Convert]::ToBase64String([IO.File]::ReadAllBytes($ltBl)), [StringComparison]::Ordinal)
    T 'a FALL (1 unimplemented ruling, baseline 2) without -Tighten is spoken and NOT written, so a gate run leaves its checkout clean' `
      ($rc1 -eq 0 -and $same1 -and (($o1 -join "`n") -match 'CAN tighten')) ("rc=$rc1 baselineUnchanged=$same1")
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltBl -Tighten
    $rc2 = $LASTEXITCODE
    $b2 = [IO.File]::ReadAllBytes($ltBl)
    $cr2 = 0; foreach ($x in $b2) { if ($x -eq 13) { $cr2++ } }
    $bom2 = ($b2.Length -ge 3 -and $b2[0] -eq 0xEF -and $b2[1] -eq 0xBB -and $b2[2] -eq 0xBF)
    $doc2 = $null
    if ($bom2) { $doc2 = [Text.Encoding]::UTF8.GetString($b2, 3, $b2.Length - 3) | ConvertFrom-Json }
    T '-Tighten records the fall in the bytes git stores: no CR, the BOM, one trailing LF, and the new mark of 1' `
      ($rc2 -eq 0 -and $cr2 -eq 0 -and $bom2 -and $b2[-1] -eq 10 -and $null -ne $doc2 -and [int]$doc2.violations -eq 1) `
      ("rc=$rc2 cr=$cr2 bom=$bom2 violations=$(if ($doc2) { $doc2.violations })")
    $ltRise = Join-Path $lt 'baseline-rise.json'
    $ltRiseJson = [ordered]@{ generated = '2026-01-01T00:00:00'; violations = 0; note = 'fixture' } | ConvertTo-Json -Depth 3
    $null = Write-TcLfFile $ltRise $ltRiseJson
    $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Root $ltTree -BaselineFile $ltRise
    $rc3 = $LASTEXITCODE
    T 'CLEAN TWIN  a count that ROSE still fails the run with exit 2, so not writing on a fall did not disarm the ratchet' ($rc3 -eq 2) ("rc=$rc3")
  } finally {
    Remove-Item -LiteralPath $lt -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: symbol detection with the comment-only twin, both drift directions, the unreadable-file finding, return arity, and the live path: a fall is not written without -Tighten, -Tighten writes LF, a rise still fails'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not (Test-Path -LiteralPath $REGISTRY)) {
  Write-Output ("RULING-DRIFT AUDIT BLIND: the registry is missing ({0}). Nothing was checked, so nothing was proven." -f $REGISTRY)
  Exit-Guard -Name 'ruling-drift' -Summary 'blind=no-registry' -Code 3
}
try { $doc = (Get-Content $REGISTRY -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {
  Write-Output ("RULING-DRIFT AUDIT BLIND: the registry will not parse ({0})." -f $_.Exception.Message)
  Exit-Guard -Name 'ruling-drift' -Summary 'blind=registry-unparseable' -Code 3
}
$rulings = @($doc.rulings)
if (-not $rulings.Count) {
  Write-Output 'RULING-DRIFT AUDIT BLIND: the registry declares zero rulings. An empty registry proves nothing and must not read as clean.'
  Exit-Guard -Name 'ruling-drift' -Summary 'blind=empty-registry' -Code 3
}
# A ruling whose DOCUMENT has gone is worse than one whose code drifted: nothing states the rule at all.
$missingDocs = @()
foreach ($r in $rulings) { if (-not (Test-Path -LiteralPath (Join-Path $treeRoot ($r.document -replace '/', '\')))) { $missingDocs += $r.id } }
if ($missingDocs.Count) {
  Write-Output ("RULING-DRIFT AUDIT FAILED: {0} ruling(s) cite a document that no longer exists: {1}. The rule is now stated nowhere." -f $missingDocs.Count, ($missingDocs -join ', '))
  Exit-Guard -Name 'ruling-drift' -Summary ("missing-docs={0}" -f $missingDocs.Count) -Code 2
}

$violations = Get-TcRulingViolations -Rulings $rulings -Reader {
  param($p)
  $full = Join-Path $treeRoot ($p -replace '/', '\')
  if (-not (Test-Path -LiteralPath $full)) { return $null }
  return [IO.File]::ReadAllLines($full)
}
$violations = @($violations)
$count = $violations.Count

foreach ($v in $violations) {
  $r = @($rulings | Where-Object { $_.id -eq $v.Id })[0]
  Write-Output ("  {0,-34} {1}" -f $v.Id, $v.Detail)
  Write-Output ("      ruled: {0}" -f $r.ruled)
  Write-Output ("      why:   {0}" -f $r.why)
}

if (-not (Test-Path -LiteralPath $BASELINE)) {
  $json = @{ generated = (Get-Date).ToString('s'); violations = $count
     note = 'HIGH-WATER MARK for ratified rulings the code does not implement. May only go DOWN.' } | ConvertTo-Json -Depth 3
  # LF with the BOM the committed blob carries, not the CRLF Set-Content writes under PS 5.1 (lib\lf-write.ps1).
  $null = Write-TcLfFile $BASELINE $json
  Write-Output ("ruling-drift: baseline written at {0} unimplemented ruling(s). From here the number may only go DOWN." -f $count)
  Exit-Guard -Name 'ruling-drift' -Summary ("baseline={0}" -f $count) -Code 0
}
$base = [int]((Get-Content $BASELINE -Raw -Encoding UTF8 | ConvertFrom-Json).violations)
if ($count -gt $base) {
  Write-Output ("RULING-DRIFT AUDIT FAILED: {0} ratified ruling(s) the code does not implement, against a baseline of {1}. A ruling was contradicted that was not contradicted before - either the code moved away from the document or a new pair was declared and is already broken." -f $count, $base)
  Exit-Guard -Name 'ruling-drift' -Summary ("violations={0} baseline={1}" -f $count, $base) -Code 2
}
# THE FALL IS THE DIRECTION THAT CANNOT BE TRUSTED (2026-09-07, backlog I15). This block used to
# lower the baseline unconditionally, so a detector that broke and found NOTHING recorded 0 as the
# permanent ceiling and printed "PASSED and TIGHTENED" forever after. lib\ratchet.ps1 refuses a fall
# to zero or a fall over 60% in one run, KEEPS the old baseline, and says what to check. -AcceptDrop
# records a genuine bulk migration in one flag rather than a hand-edited baseline file.
$move = Test-RatchetMove -Name 'ruling-drift' -Count $count -Baseline $base -AcceptDrop:$AcceptDrop
if ($move.Verdict -eq 'implausible') {
  Write-Output $move.Message
  Exit-Guard -Name 'ruling-drift' -Summary ("violations={0} baseline={1} refused-to-lower" -f $count, $base) -Code 2
}
if ($move.Verdict -eq 'tightened') {
  # A FALL IS SPOKEN, NOT WRITTEN, unless this run was asked to record it (2026-09-11, see the header). -AcceptDrop
  # is such an ask: it has always recorded the fall it names.
  if (-not ($Tighten -or $AcceptDrop)) {
    Write-Output ("ruling-drift: PASSED, and the ratchet CAN tighten - {0} unimplemented ruling(s), baseline {1}. NOT written: this may be a pre-push gate, and a rewrite here dirties the checkout being pushed without riding the push. Record it with -Tighten and commit ops\ruling-drift-baseline.json." -f $count, $base)
    Exit-Guard -Name 'ruling-drift' -Summary ("violations={0} baseline={1} can-tighten" -f $count, $base) -Code 0
  }
  $doc = $null
  try { $doc = Get-Content $BASELINE -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  if (-not $doc) { $doc = [pscustomobject]@{} }
  $hist = Add-RatchetHistory -Doc $doc -Count $count
  $json = @{ generated = (Get-Date).ToString('s'); violations = $move.NewBaseline; history = $hist
     note = 'HIGH-WATER MARK for ratified rulings the code does not implement. May only go DOWN, and an implausible fall is refused.' } | ConvertTo-Json -Depth 5
  $null = Write-TcLfFile $BASELINE $json
  # The library message already names the guard; prefixing it again read as "x: ... x: ...".
  Write-Output ("PASSED and TIGHTENED - " + $move.Message)
  Write-Output ("  " + (Get-RatchetTrend -History $hist))
  Exit-Guard -Name 'ruling-drift' -Summary ("violations={0} tightened-from={1}" -f $count, $base) -Code 0
}
Write-Output ("ruling-drift: PASSED - {0} ratified ruling(s) still unimplemented, unchanged from the baseline. These are decisions Brad made that the code does not yet honour; each one implemented lowers the mark permanently." -f $count)
Exit-Guard -Name 'ruling-drift' -Summary ("violations={0} baseline={1}" -f $count, $base) -Code 0
