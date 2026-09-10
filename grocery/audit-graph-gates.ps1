<#
  audit-graph-gates.ps1 - run graph\'s integrity gates against the live board, ADVISORY.

  BRAD'S DECISION (2026-08-21): "I think Im confident to graduate this system and well work out the
  'kinks' as it's live. We dont have a ton of traffic yet." This is that graduation, at the level the
  evidence supports: graph CHECKS the finished board and never decides a price.

  WHAT IT CAN AND CANNOT DO. In this job graph cannot invent a cell, move a crown, or change a number.
  The worst it can do is complain. That distinction is the whole reason this level is safe to ship on
  the same day it was proposed, while the identity/matching job is not: graph's false-merge rate is a
  clean 0.0000 against a <=0.02 gate, but its missed-merge is 0.3590 against <=0.10 - and a MISSED
  merge is a coverage gap the PowerShell estate still fills, while a FALSE merge is a wrong price. The
  dangerous direction is at zero; the failing one is the safe direction. None of that matters here,
  because none of these seven gates ask graph to match anything.

  IT HAS EARNED THIS ONCE ALREADY. On its first run graph flagged that Fareway's weekly ad window had
  expired 2026-08-15 while next_pull said 2026-08-16.

  ADVISORY ON ARRIVAL, AND THE REASON IS CONCRETE, NOT CAUTIOUS. graph reads some of its rules out of
  the PowerShell estate's SOURCE TEXT - it greps capture-policy for $script:MaxCarryDays. On
  2026-08-21 that file was split (its param() block was clobbering caller variables through
  dot-sourcing) and the value moved to capture-policy-lib. graph's row_age gate went red the same day
  with "cannot find $script:MaxCarryDays". It behaved correctly - it refuses to guess - but it means
  graph is coupled to another system's FILE LAYOUT, not just to its values, and nothing in the
  PowerShell tree can know that reader exists. A reasonable refactor over there can turn this red.
  While that is true, this must never be able to stop a publish.
  Promotion to blocking is a per-gate decision, after a clean run of real days, and it is Brad's.

  BLIND IS NOT PASS AND IS NOT FAIL. No interpreter, an import that dies, a rule graph cannot find -
  all of those are exit 3, reported loudly, board publishes. `could not run is not a failure` and
  `fallback tests absence, not function` are both this estate's own lessons; the sibling check
  audit-semantic-identity already follows exactly this convention.

  THE OBSERVATION IMPORT, AND THE 20 DAYS IT DID NOT HAPPEN (2026-09-10). This lane is the one scheduled
  caller of graph\import\import_all.py, and from its first commit (c096c779b, 2026-08-21 16:39) it ran
  the STRUCTURE-ONLY form. Price observations had only ever been imported by hand: graph.db's own
  decision_log records the --observations setting on every import_start, and all 16 that carried it ran
  between 2026-08-20 19:02 and 2026-08-21 01:37:15, inside the build sessions. Every import after 16:19
  that day, including this lane's one a day at ~08:15 from 2026-08-24, carried observations=false. So
  nothing STOPPED: the backfill was never wired, and design\PLAN-use-the-cores-2026-08-23.md recorded
  that it had no caller. The file kept being written, which is why graph\pipeline\nightly.ps1 read
  graph.db as fresh for 20 nights while price_observations stayed at 2026-08-21.

  It runs with --observations now. Measured 2026-09-10 on a snapshot copy of the live graph.db, through
  graph\import\import_all.py --observations at c18472a70: rc=0 in 38 s against this lane's 600 s budget;
  324 capture files; price_observations 26,740 -> 41,824 after the supersede-prune; question_verdicts
  4,141 -> 4,442, with 4,136 keeping their 2026-08-21 decided_at (state.py carries an unchanged verdict's
  date); the state gate PASS. The contested set the nightly model half reads went from 0 of 20,478 to
  6,222 of 35,406. resolve.py is checkpointed and deadline-bounded, so a night that does not finish them
  records PARTIAL and the next resumes.

  AND IT CHECKS WHAT IT IMPORTED. After the import this lane reads the newest observed_at
  (graph\pipeline\newest_observation.py) and judges it with lib\input-assert.ps1 - the same rule and the
  same 36 h window nightly.ps1 derives for its own input - as an eighth advisory verdict,
  observations_fresh. A structure-only import, or an importer that stops adding rows, leaves graph.db's
  file fresh and its content old, and that now reads FAIL instead of reading nothing.

  SCOPE OF A CLEAN REPORT: UNSOUND. The seven status.py gates each check what they were written to check,
  and observations_fresh reads the newest date across every capture lane, so one lane that stopped while
  another kept flowing still reads PASS. A clean report says graph found none of those defects in what it
  imported, never that the board has none.

  Usage: audit-graph-gates.ps1 [-Quiet] [-Python <path>] [-SkipImport] [-SelfTest]
  Exit 0 = ran (findings are advisory). Exit 2 = self-test regression. Exit 3 = BLIND.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$Quiet, [string]$Python = '', [switch]$SkipImport, [switch]$SelfTest, [string]$OutDir = '')
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')
. (Join-Path $root 'python-lib.ps1')
. (Join-Path $root 'native-lib.ps1')   # Invoke-Native: a native child's stderr under EAP=Stop is a TERMINATING error, and `2>&1`/`2>$null` CAUSE that (native-lib.ps1)
. (Join-Path (Split-Path $root -Parent) 'lib\input-assert.ps1')   # the file clock AND the content clock, one rule shared with graph\pipeline\nightly.ps1

$graphDir = Join-Path (Split-Path $root -Parent) 'graph'

function Get-GateVerdicts {
  <#
    .SYNOPSIS Parse graph's status output into (name, verdict) pairs.
    .DESCRIPTION Pure, so the fixtures below exercise the REAL parser over frozen text instead of a
                 description of it. The output shape is graph/eval/status.py's "gate checks:" block:
                     PASS  omaha_identity
                     FAIL  row_age
                           {"error": "..."}
                 A gate line that is neither PASS nor FAIL is returned as 'UNKNOWN' rather than being
                 dropped - silently discarding a verdict shape we do not recognise is how a check
                 reports "all clear" about rows it never looked at.
  #>
  param([string]$Text)
  $out = @()
  $inBlock = $false
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -match '^\s*gate checks:\s*$') { $inBlock = $true; continue }
    if (-not $inBlock) { continue }
    if ($line -match '^\s*$') { continue }
    if ($line -match '^\s{0,8}(PASS|FAIL|SKIP|ERROR)\s+([A-Za-z0-9_]+)\s*$') {
      $out += [pscustomobject]@{ gate = $Matches[2]; verdict = $Matches[1].ToUpper(); detail = '' }
      continue
    }
    # An indented continuation line carries the previous gate's error payload.
    if ($out.Count -and $line -match '^\s{6,}\S') { $out[-1].detail = ($line.Trim()); continue }
    # Anything else ends the block (the next section of the report).
    if ($line -match '^\s{0,4}\S' -and $line -notmatch '^\s*(PASS|FAIL|SKIP|ERROR)\b') { $inBlock = $false }
  }
  return $out
}

function ConvertTo-FreshnessVerdict {
  <#
    .SYNOPSIS lib\input-assert.ps1's state for graph.db, in this report's verdict vocabulary. PURE.
    .DESCRIPTION FRESH is PASS and STALE is FAIL, a finding. MISSING and UNREADABLE are ERROR: this lane
                 could not read the clock, and Get-GateVerdicts' own rule is that an unrecognised shape
                 is surfaced rather than assumed good.
  #>
  param([string]$State)
  switch ($State) {
    'FRESH' { return 'PASS' }
    'STALE' { return 'FAIL' }
    default { return 'ERROR' }
  }
}

if ($SelfTest) {
  $f = 0
  function T($ok, $m) { if ($ok) { Write-Output "ok    $m" } else { Write-Output "FAIL  $m"; $script:f++ } }

  # FROZEN: the real output shape, including the row_age failure this estate caused on 2026-08-21 by
  # splitting capture-policy.ps1 out from under graph's rule reader.
  $frozen = @"
  gate checks:
     PASS  omaha_identity
     PASS  ad_window
     FAIL  row_age
           {"error": "RuntimeError: cannot find `$script:MaxCarryDays in ...capture-policy.ps1; row_age has no window to enforce"}
     PASS  provenance_complete

  learning: {'applied': 159}
"@
  $g = @(Get-GateVerdicts -Text $frozen)
  T ($g.Count -eq 4) "parses every gate in the block (got $($g.Count), expected 4)"
  # MUST FIRE: the failure has to survive parsing. A parser that silently drops the FAIL line would
  # make this whole check report clean forever, which is the worst possible failure for a guard.
  $bad = @($g | Where-Object { $_.verdict -eq 'FAIL' })
  T ($bad.Count -eq 1 -and $bad[0].gate -eq 'row_age') 'a FAILING gate is reported, not dropped'
  T ($bad[0].detail -match 'MaxCarryDays') 'the failure detail is carried through, so the cause is visible'
  # CLEAN TWIN: the trailing "learning:" line must not be swallowed as a gate.
  T (-not (@($g | Where-Object { $_.gate -eq 'learning' })).Count) 'the block ends where it should - a later section is not read as a gate'
  # CLEAN TWIN: an all-pass report yields no findings.
  $clean = "  gate checks:`n     PASS  omaha_identity`n     PASS  ad_window`n"
  $g2 = @(Get-GateVerdicts -Text $clean)
  T ($g2.Count -eq 2 -and -not (@($g2 | Where-Object { $_.verdict -ne 'PASS' })).Count) 'an all-pass report produces no findings'
  # MUST FIRE: an unrecognised verdict is surfaced, never assumed good.
  $odd = "  gate checks:`n     ERROR  ad_window`n"
  $g3 = @(Get-GateVerdicts -Text $odd)
  T ($g3.Count -eq 1 -and $g3[0].verdict -eq 'ERROR') 'an ERROR verdict is kept rather than read as a pass'
  # BLIND behaviour: a bogus interpreter path must resolve to nothing, not to the Store stub.
  T (-not (Get-GraphPython -Explicit 'C:\nope\python.exe')) 'a bad explicit interpreter resolves to empty, so the caller can report BLIND'

  # ---- the observation import (2026-09-10) ------------------------------------------------------------
  # MUST FIRE, SOURCE ASSERTION, THE FOUNDING BUG: this lane called import_all.py with no flags from its
  # first commit, so the prices it exists to check stopped reaching graph.db on 2026-08-21 and nothing
  # said so for 20 days. NEEDLES BUILT BY CONCATENATION, or these check lines would be their own matches.
  $src = [IO.File]::ReadAllText($PSCommandPath)
  # $nImportObs is built FROM $nImportAny and never written out whole: the first version of this line
  # spelled the call in one literal, and the count below found that literal as a second import call.
  $nImportAny = "'import\import_" + "all.py')"
  $nImportObs = $nImportAny + " '--" + "observations'"
  T ($src.Contains($nImportObs)) 'MUST FIRE  the scheduled import passes --observations, or no price reaches graph.db'
  $nImports = ([regex]::Matches($src, [regex]::Escape($nImportAny))).Count
  T ($nImports -eq 1) "MUST FIRE  exactly ONE import call, so no structure-only call can sit beside the real one (found $nImports)"

  # MUST FIRE, THE FOUNDING CASE THROUGH THE LIVE PATH: a graph.db written seconds ago whose newest
  # observation is 20 days old is FAIL, not PASS. Test-TcInput reads the real file's mtime.
  $tmpDb = Join-Path $env:TEMP ('graph-gates-selftest-' + [guid]::NewGuid().ToString('N') + '.db')
  try {
    [IO.File]::WriteAllText($tmpDb, 'x')
    $what = 'newest price_observations.observed_at'
    $old = (Get-Date).AddDays(-20).ToString('yyyy-MM-dd')
    $rep = Test-TcInput -Path $tmpDb -Producer 'self-test' -MaxAgeHours 26.0 -NewestRecord $old -NewestRecordWhat $what -RecordMaxAgeHours 36.0
    T ((ConvertTo-FreshnessVerdict -State $rep.State) -eq 'FAIL') "MUST FIRE  a fresh graph.db over a 20-day-old newest observation reads FAIL (got $($rep.State))"
    $rep = Test-TcInput -Path $tmpDb -Producer 'self-test' -MaxAgeHours 26.0 -NewestRecord ((Get-Date).ToString('yyyy-MM-dd')) -NewestRecordWhat $what -RecordMaxAgeHours 36.0
    T ((ConvertTo-FreshnessVerdict -State $rep.State) -eq 'PASS') "CLEAN TWIN  the same file with an observation dated today reads PASS (got $($rep.State))"
    $rep = Test-TcInput -Path $tmpDb -Producer 'self-test' -MaxAgeHours 26.0 -NewestRecord '' -NewestRecordWhat $what -RecordMaxAgeHours 36.0
    T ((ConvertTo-FreshnessVerdict -State $rep.State) -eq 'ERROR') "MUST FIRE  a clock the reader could not read is ERROR, never PASS (got $($rep.State))"
  } finally {
    Remove-Item $tmpDb -Force -ErrorAction SilentlyContinue
  }
  # The reader's real output shape parses to its date, not to the COMPLETE marker printed after it.
  $readerOut = @('lane regular newest=2026-08-21 rows=26740', 'NEWEST-OBSERVATION observed_at=2026-08-21 rows=26740 future_rows=0', 'NEWEST-OBSERVATION-COMPLETE rc=0')
  $stamp = Get-TcStampFromLines -Lines $readerOut -Marker 'NEWEST-OBSERVATION' -Key 'observed_at'
  T ($stamp -eq '2026-08-21') "CLEAN TWIN  the newest-observation line parses to its date (got '$stamp')"

  Write-Output ("GRAPH-GATES " + $(if ($f) { "SELF-TEST FAILED ($f)" } else { 'SELF-TEST PASS' }))
  Exit-Guard -Name 'graph-gates' -Summary "selftest failed=$f" -Code $(if ($f) { 2 } else { 0 })
}

# ---- BLIND checks first. Each one publishes the board and says why it could not look. -------------
if (-not (Test-Path $graphDir)) {
  Write-Output "graph-gates: BLIND - no graph\ directory. Nothing to check; the board is unaffected."
  Exit-Guard -Name 'graph-gates' -Summary 'BLIND: no graph dir' -Code 3
}
$py = Get-GraphPython -Explicit $Python
if (-not $py) {
  Write-Output "graph-gates: BLIND - no Python interpreter found (registry, known paths, PATH all checked). The board is unaffected."
  Exit-Guard -Name 'graph-gates' -Summary 'BLIND: no python' -Code 3
}

# REFRESH FIRST, or the gates judge a board that no longer exists. Measured at ~1s. This is the same
# staleness trap that made audit-capture-eviction's artifact fail its own freshness assertion twice
# today: a derived verdict must name the generation it was computed against.
if (-not $SkipImport) {
  try {
    # --observations IS THE WHOLE REFRESH (header, 2026-09-10): captures -> price_observations ->
    # resolve -> cell_state + question_verdicts -> state gate -> supersede-prune -> graph\state export.
    # Without it this call refreshes structure only and graph.db's content stays wherever it last was.
    $impR = Invoke-Native $py (Join-Path $graphDir 'import\import_all.py') '--observations'
    $impOut = @($impR.Lines)
    $impRc = $impR.ExitCode
    if ($impRc -ne 0) {
      Write-Output ("graph-gates: BLIND - import failed (exit $impRc). The board is unaffected.")
      Write-Output ("  " + (($impOut | Select-Object -Last 3) -join ' | '))
      Exit-Guard -Name 'graph-gates' -Summary "BLIND: import exit $impRc" -Code 3
    }
  } catch {
    Write-Output ("graph-gates: BLIND - import threw: " + $_.Exception.Message + ". The board is unaffected.")
    Exit-Guard -Name 'graph-gates' -Summary 'BLIND: import threw' -Code 3
  }
}

$statusOut = ''
try { $statusOut = ((@((Invoke-Native $py (Join-Path $graphDir 'eval\status.py')).Lines)) | Out-String) }
catch {
  Write-Output ("graph-gates: BLIND - status threw: " + $_.Exception.Message + ". The board is unaffected.")
  Exit-Guard -Name 'graph-gates' -Summary 'BLIND: status threw' -Code 3
}
# NOTE: status.py exits non-zero when a gate fails, which is a FINDING, not blindness. Only an absent
# gate block means we could not look - conflating the two would turn every real finding into a shrug.
$gates = @(Get-GateVerdicts -Text $statusOut)
if (-not $gates.Count) {
  Write-Output 'graph-gates: BLIND - status produced no gate block (its output shape may have moved). The board is unaffected.'
  Exit-Guard -Name 'graph-gates' -Summary 'BLIND: no gate block' -Code 3
}

# ---- WHAT THE IMPORT BROUGHT IN (2026-09-10): the file clock is not the content clock. -------------
# Read AFTER the import, and also under -SkipImport, because a content clock that stopped is exactly
# what a skipped or structure-only import leaves behind. 36 h is nightly.ps1's derived window for the
# same input; this lane reads it ~08:15, hours after the end of the newest healthy capture day.
$obsLines = @()
try { $obsLines = @((Invoke-Native $py (Join-Path $graphDir 'pipeline\newest_observation.py')).Lines) } catch { $obsLines = @() }
$obsStamp = Get-TcStampFromLines -Lines $obsLines -Marker 'NEWEST-OBSERVATION' -Key 'observed_at'
$fresh = Test-TcInput -Path (Join-Path $graphDir 'sqlite\graph.db') -Producer 'this lane''s import (graph\import\import_all.py --observations)' `
           -MaxAgeHours 26.0 -NewestRecord $obsStamp -NewestRecordWhat 'newest price_observations.observed_at' -RecordMaxAgeHours 36.0
$gates += [pscustomobject]@{
  gate    = 'observations_fresh'
  verdict = (ConvertTo-FreshnessVerdict -State $fresh.State)
  detail  = ("{0}: newest observed_at '{1}', {2} h old against a {3} h window; graph.db written {4} h ago" -f `
             $fresh.State, $obsStamp, $fresh.RecordAgeHours, $fresh.RecordMaxAgeHours, $fresh.AgeHours)
}

$failing = @($gates | Where-Object { $_.verdict -ne 'PASS' })
$doc = [ordered]@{
  updated = (Get-Date).ToString('s')
  python = $py
  mode = 'ADVISORY - graph checks the finished board and can never change a price or stop a publish. Promotion to blocking is per-gate, after a clean record of real days, and is Brad''s call.'
  gates_total = $gates.Count
  gates_failing = $failing.Count
  gates = @($gates | ForEach-Object { [ordered]@{ gate = $_.gate; verdict = $_.verdict; detail = $_.detail } })
}
$outF = Join-Path $OutDir 'graph-gates.json'
[IO.File]::WriteAllText($outF, ($doc | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

if (-not $Quiet) {
  Write-Output ("graph-gates  -  {0} gate(s), {1} failing   [ADVISORY: cannot block a publish]" -f $gates.Count, $failing.Count)
  foreach ($g in $gates) {
    Write-Output ("  {0,-6} {1}" -f $g.verdict, $g.gate)
    if ($g.detail) { Write-Output ("         " + $g.detail.Substring(0, [Math]::Min(150, $g.detail.Length))) }
  }
  Write-Output ("  -> " + $outF)
}
Exit-Guard -Name 'graph-gates' -Summary "gates=$($gates.Count) failing=$($failing.Count) advisory=yes" -Code 0
