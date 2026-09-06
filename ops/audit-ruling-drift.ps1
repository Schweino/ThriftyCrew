<#
  audit-ruling-drift.ps1 - a ruling document says what this estate does; a script does it. This checks
  they still agree.

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

  Self-test: powershell -File ops\audit-ruling-drift.ps1 -SelfTest
#>
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$REGISTRY = Join-Path $repo 'ops\ruling-implementations.json'
$BASELINE = Join-Path $repo 'ops\ruling-drift-baseline.json'

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
  T 'CLEAN TWIN a different symbol does not match' (-not (Test-TcSymbolPresent -Lines @('x = OTHER_CONST') -Symbol 'DEFAULT_COND')) 'false match'
  T 'CLEAN TWIN case matters - default_cond is not DEFAULT_COND' (-not (Test-TcSymbolPresent -Lines @('x = default_cond') -Symbol 'DEFAULT_COND')) 'case-insensitive match'

  $R = @([pscustomobject]@{ id = 'r1'; file = 'a.py'; symbol = 'GONE'; must = 'absent' },
         [pscustomobject]@{ id = 'r2'; file = 'b.py'; symbol = 'KEEP'; must = 'present' })

  $v1 = Get-TcRulingViolations -Rulings $R -Reader { param($p) if ($p -eq 'a.py') { @('x = GONE') } else { @('y = KEEP') } }
  T 'MUST FIRE  a ruling that says DELETE and the symbol is still there' `
    (@($v1).Count -eq 1 -and $v1[0].Kind -eq 'ruling-not-implemented') (($v1 | ForEach-Object { $_.Kind }) -join ',')

  $v2 = Get-TcRulingViolations -Rulings $R -Reader { param($p) if ($p -eq 'a.py') { @('x = 1') } else { @('y = 1') } }
  T 'MUST FIRE  a ruling that says KEEP and the symbol has gone is a REGRESSION' `
    (@($v2).Count -eq 1 -and $v2[0].Kind -eq 'ruling-regressed') (($v2 | ForEach-Object { $_.Kind }) -join ',')

  $v3 = Get-TcRulingViolations -Rulings $R -Reader { param($p) if ($p -eq 'a.py') { @('x = 1') } else { @('y = KEEP') } }
  T 'CLEAN TWIN both rulings honoured raises nothing' (@($v3).Count -eq 0) (($v3 | ForEach-Object { $_.Kind }) -join ',')

  # A rule about a file nobody can read has stopped being checked, and that must not read as a pass.
  $v4 = Get-TcRulingViolations -Rulings $R -Reader { param($p) $null }
  T 'MUST FIRE  an unreadable file is its own finding, never a silent pass' `
    (@($v4).Count -eq 2 -and $v4[0].Kind -eq 'file-missing') (($v4 | ForEach-Object { $_.Kind }) -join ',')

  T 'MUST FIRE  a single violation comes back as an ARRAY, not unrolled' ($v1 -is [array]) ($v1.GetType().FullName)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: symbol detection with the comment-only twin, both drift directions, the unreadable-file finding, and return arity'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not (Test-Path -LiteralPath $REGISTRY)) {
  Write-Output ("RULING-DRIFT AUDIT BLIND: the registry is missing ({0}). Nothing was checked, so nothing was proven." -f $REGISTRY)
  Write-GuardComplete -Name 'ruling-drift' -Summary 'blind=no-registry'
  exit 3
}
try { $doc = (Get-Content $REGISTRY -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {
  Write-Output ("RULING-DRIFT AUDIT BLIND: the registry will not parse ({0})." -f $_.Exception.Message)
  Write-GuardComplete -Name 'ruling-drift' -Summary 'blind=registry-unparseable'
  exit 3
}
$rulings = @($doc.rulings)
if (-not $rulings.Count) {
  Write-Output 'RULING-DRIFT AUDIT BLIND: the registry declares zero rulings. An empty registry proves nothing and must not read as clean.'
  Write-GuardComplete -Name 'ruling-drift' -Summary 'blind=empty-registry'
  exit 3
}
# A ruling whose DOCUMENT has gone is worse than one whose code drifted: nothing states the rule at all.
$missingDocs = @()
foreach ($r in $rulings) { if (-not (Test-Path -LiteralPath (Join-Path $repo ($r.document -replace '/', '\')))) { $missingDocs += $r.id } }
if ($missingDocs.Count) {
  Write-Output ("RULING-DRIFT AUDIT FAILED: {0} ruling(s) cite a document that no longer exists: {1}. The rule is now stated nowhere." -f $missingDocs.Count, ($missingDocs -join ', '))
  Write-GuardComplete -Name 'ruling-drift' -Summary ("missing-docs={0}" -f $missingDocs.Count)
  exit 2
}

$violations = Get-TcRulingViolations -Rulings $rulings -Reader {
  param($p)
  $full = Join-Path $repo ($p -replace '/', '\')
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
  @{ generated = (Get-Date).ToString('s'); violations = $count
     note = 'HIGH-WATER MARK for ratified rulings the code does not implement. May only go DOWN.' } |
    ConvertTo-Json -Depth 3 | Set-Content $BASELINE -Encoding UTF8
  Write-Output ("ruling-drift: baseline written at {0} unimplemented ruling(s). From here the number may only go DOWN." -f $count)
  Write-GuardComplete -Name 'ruling-drift' -Summary ("baseline={0}" -f $count)
  exit 0
}
$base = [int]((Get-Content $BASELINE -Raw -Encoding UTF8 | ConvertFrom-Json).violations)
if ($count -gt $base) {
  Write-Output ("RULING-DRIFT AUDIT FAILED: {0} ratified ruling(s) the code does not implement, against a baseline of {1}. A ruling was contradicted that was not contradicted before - either the code moved away from the document or a new pair was declared and is already broken." -f $count, $base)
  Write-GuardComplete -Name 'ruling-drift' -Summary ("violations={0} baseline={1}" -f $count, $base)
  exit 2
}
if ($count -lt $base) {
  @{ generated = (Get-Date).ToString('s'); violations = $count
     note = 'HIGH-WATER MARK for ratified rulings the code does not implement. May only go DOWN.' } |
    ConvertTo-Json -Depth 3 | Set-Content $BASELINE -Encoding UTF8
  Write-Output ("ruling-drift: PASSED and TIGHTENED - {0} unimplemented ruling(s), down from {1}. Baseline lowered; it can never rise again." -f $count, $base)
  Write-GuardComplete -Name 'ruling-drift' -Summary ("violations={0} tightened-from={1}" -f $count, $base)
  exit 0
}
Write-Output ("ruling-drift: PASSED - {0} ratified ruling(s) still unimplemented, unchanged from the baseline. These are decisions Brad made that the code does not yet honour; each one implemented lowers the mark permanently." -f $count)
Write-GuardComplete -Name 'ruling-drift' -Summary ("violations={0} baseline={1}" -f $count, $base)
exit 0
