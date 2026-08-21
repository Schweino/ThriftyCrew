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

  Usage: audit-graph-gates.ps1 [-Quiet] [-Python <path>] [-SkipImport] [-SelfTest]
  Exit 0 = ran (findings are advisory). Exit 2 = self-test regression. Exit 3 = BLIND.
#>
param([switch]$Quiet, [string]$Python = '', [switch]$SkipImport, [switch]$SelfTest, [string]$OutDir = '')
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $OutDir) { $OutDir = Join-Path $root 'out' }
. (Join-Path (Split-Path $root -Parent) 'lib\guard-contract.ps1')
. (Join-Path $root 'python-lib.ps1')

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

  Write-Output ("GRAPH-GATES " + $(if ($f) { "SELF-TEST FAILED ($f)" } else { 'SELF-TEST PASS' }))
  Write-GuardComplete -Name 'graph-gates' -Summary "selftest failed=$f"
  exit $(if ($f) { 2 } else { 0 })
}

# ---- BLIND checks first. Each one publishes the board and says why it could not look. -------------
if (-not (Test-Path $graphDir)) {
  Write-Output "graph-gates: BLIND - no graph\ directory. Nothing to check; the board is unaffected."
  Write-GuardComplete -Name 'graph-gates' -Summary 'BLIND: no graph dir'
  exit 3
}
$py = Get-GraphPython -Explicit $Python
if (-not $py) {
  Write-Output "graph-gates: BLIND - no Python interpreter found (registry, known paths, PATH all checked). The board is unaffected."
  Write-GuardComplete -Name 'graph-gates' -Summary 'BLIND: no python'
  exit 3
}

# REFRESH FIRST, or the gates judge a board that no longer exists. Measured at ~1s. This is the same
# staleness trap that made audit-capture-eviction's artifact fail its own freshness assertion twice
# today: a derived verdict must name the generation it was computed against.
if (-not $SkipImport) {
  try {
    $impOut = & $py (Join-Path $graphDir 'import\import_all.py') 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Output ("graph-gates: BLIND - import failed (exit $LASTEXITCODE). The board is unaffected.")
      Write-Output ("  " + (($impOut | Select-Object -Last 3) -join ' | '))
      Write-GuardComplete -Name 'graph-gates' -Summary "BLIND: import exit $LASTEXITCODE"
      exit 3
    }
  } catch {
    Write-Output ("graph-gates: BLIND - import threw: " + $_.Exception.Message + ". The board is unaffected.")
    Write-GuardComplete -Name 'graph-gates' -Summary 'BLIND: import threw'
    exit 3
  }
}

$statusOut = ''
try { $statusOut = (& $py (Join-Path $graphDir 'eval\status.py') 2>&1 | Out-String) }
catch {
  Write-Output ("graph-gates: BLIND - status threw: " + $_.Exception.Message + ". The board is unaffected.")
  Write-GuardComplete -Name 'graph-gates' -Summary 'BLIND: status threw'
  exit 3
}
# NOTE: status.py exits non-zero when a gate fails, which is a FINDING, not blindness. Only an absent
# gate block means we could not look - conflating the two would turn every real finding into a shrug.
$gates = @(Get-GateVerdicts -Text $statusOut)
if (-not $gates.Count) {
  Write-Output 'graph-gates: BLIND - status produced no gate block (its output shape may have moved). The board is unaffected.'
  Write-GuardComplete -Name 'graph-gates' -Summary 'BLIND: no gate block'
  exit 3
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
Write-GuardComplete -Name 'graph-gates' -Summary "gates=$($gates.Count) failing=$($failing.Count) advisory=yes"
exit 0
