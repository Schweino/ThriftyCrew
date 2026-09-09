<#
  audit-python-pins.ps1 - what sidecar\requirements.txt DECLARES is what sidecar\.venv HAS.

  SCOPE OF A CLEAN REPORT: SOUND over the `==` pins, silent about everything else. Every pinned line
    is compared against the installed distribution, so a clean report really does mean no PIN is
    lying. An UNPINNED line (`numpy`, `duckdb`) is not a claim and is not checked - the file makes no
    assertion about those versions, so this check cannot have an opinion either.

  WHY THIS EXISTS (2026-09-08, backlog I58). `sidecar/requirements.txt` declares seven packages, five
  with `==` pins, and NOTHING in this estate had ever compared it to the venv. Its only two references
  anywhere were prose. Measured the day this shipped, two of the five were wrong:

      sentence-transformers==5.1.2   installed 5.6.1     DRIFTED
      fastapi==0.121.2               installed 0.141.1   DRIFTED

  WHY THAT MATTERS MORE THAN AN UNTIDY FILE. `sentence-transformers` is the library the matcher's
  whole score space is built on - `sidecar/lib_match.py` imports `SentenceTransformer` and
  `CrossEncoder` from it and constructs the embedder, and that is the ONLY import of it in the tree.
  Every bi-encoder and cross-encoder number this estate has ever produced came through it.
  `sidecar/THRESHOLDS.md` registers three score spaces, and `sidecar/freeze_eval.py` exists because a
  changed input once moved holdout AUC from 0.9705 to 0.7921. A minor-version move across 5.1 to 5.6
  is exactly the kind of change that shifts a score space without shifting a number anybody watches -
  and the only written record of which version a recorded AUC ran on was WRONG.

  THIS IS NOT THE PROBLEM CONTAINERS SOLVE, and the item was queued believing it might be. The drift
  is between a DECLARATION and an INSTALL on one box. An image rebuild would have carried it forward
  unchanged. What catches it is a comparison, not a runtime.

  A MISSING VENV IS BLIND, NOT CLEAN. A worktree, a CI runner or a fresh checkout has no
  sidecar\.venv, and reporting "0 mismatches" there would be this estate's worst shape: an assertion
  that ran against nothing. Exit 3.

  WHICH IS WHY ONLY THE -SelfTest IS GATED, AND THE LIVE RUN IS NOT REGISTERED IN run-gates' $static
  LIST. The item that filed this called the check "hermetic", and the SELF-TEST is - it drives pure
  functions with synthetic fixtures and passes on any machine, so run-gates discovers it like every
  other. The LIVE run is hermetic only where sidecar\.venv exists, which on a CI runner it does not,
  and a correctly-BLIND exit 3 there would make the gate red for a condition nobody can clear. That is
  the red-on-day-one shape wearing a different coat: the fix is to run the live half where the venv
  lives, not to soften the blind verdict into a pass. Run it by hand, or from the daily chain, on the
  box that has the venv:  powershell -File ops\audit-python-pins.ps1

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File ops\audit-python-pins.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$REQ  = Join-Path $repo 'sidecar\requirements.txt'
$SITE = Join-Path $repo 'sidecar\.venv\Lib\site-packages'

function Get-TcNormalisedName {
  <# PEP 503 normalisation. The dist-info directory writes `sentence_transformers` where the
     requirement writes `sentence-transformers`, so a naive string compare finds NOTHING and reports
     a clean file - the agreeing zero this estate has a memory about. Pure. #>
  param([string]$Name)
  return ([regex]::Replace($Name.Trim().ToLowerInvariant(), '[-_.]+', '-'))
}

function Get-TcPinnedRequirements {
  <# The `==` pins only, as @{ Name; Version; Raw }. A comment, a blank line, an unpinned name and a
     `>=` bound are all SKIPPED rather than flagged: none of them is a claim about a version.
     `,@()` so a single pin does not unroll to a bare object. Pure. #>
  param([string[]]$Lines)
  $out = @()
  foreach ($ln in @($Lines)) {
    $t = $ln
    $hash = $t.IndexOf('#')
    if ($hash -ge 0) { $t = $t.Substring(0, $hash) }      # strip an inline comment
    $t = $t.Trim()
    if (-not $t) { continue }
    # Exactly `name==version`. A `>=`, `~=` or bare name is deliberately not matched.
    if ($t -match '^([A-Za-z0-9][A-Za-z0-9._-]*)\s*==\s*(\S+)$') {
      $out += [pscustomobject]@{ Name = Get-TcNormalisedName $Matches[1]; Version = $Matches[2]; Raw = $t }
    }
  }
  return ,@($out)
}

function Get-TcInstalledVersions {
  <# name -> version, from the *.dist-info DIRECTORY NAMES. A hashtable, so a caller can ask about a
     package that is not installed and get $null rather than an exception. Pure. #>
  param([string[]]$DistInfoNames)
  $map = @{}
  foreach ($d in @($DistInfoNames)) {
    $n = $d -replace '\.dist-info$', ''
    $i = $n.LastIndexOf('-')
    if ($i -lt 1) { continue }
    $map[(Get-TcNormalisedName $n.Substring(0, $i))] = $n.Substring($i + 1)
  }
  return $map
}

function Compare-TcPins {
  <# One row per pin: Name, Declared, Installed, Status (match | DRIFTED | NOT INSTALLED). Pure, so
     the fixtures drive the whole verdict without a venv on disk. #>
  param([object[]]$Pins, [hashtable]$Installed)
  $out = @()
  foreach ($p in @($Pins)) {
    $have = $Installed[$p.Name]
    $status = if (-not $have) { 'NOT INSTALLED' } elseif ($have -eq $p.Version) { 'match' } else { 'DRIFTED' }
    $out += [pscustomobject]@{ Name = $p.Name; Declared = $p.Version; Installed = $have; Status = $status }
  }
  return ,@($out)
}

# ------------------------------------------------------------------------------------- self-test
if ($SelfTest) {
  $f = 0
  function T($m, $cond, $got) { if ($cond) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $got); $script:f++ } }

  # EVERY FIXTURE IS A SINGLE-QUOTED LITERAL. Built by concatenation in the argument position they
  # would be three positional arguments and the case would run on a fragment (2026-09-07).
  $reqLines = @(
    '# Reproduce with: uv venv --python 3.12',
    'torch==2.11.0+cu128',
    'numpy',
    'sentence-transformers==5.1.2',
    'duckdb',
    'fastapi==0.121.2   # the API layer',
    ''
  )
  $pins = Get-TcPinnedRequirements -Lines $reqLines
  T 'MUST NOT FIRE  only the == lines are pins: 3 of 6 non-blank lines, and numpy/duckdb are not claims' `
    ($pins.Count -eq 3) ("count=" + $pins.Count)
  T 'CLEAN TWIN a local version segment survives intact - 2.11.0+cu128 is not truncated at the plus' `
    (($pins | Where-Object { $_.Name -eq 'torch' }).Version -eq '2.11.0+cu128') (($pins | Where-Object { $_.Name -eq 'torch' }).Version)
  T 'CLEAN TWIN an inline comment is stripped from the pin rather than becoming part of the version' `
    (($pins | Where-Object { $_.Name -eq 'fastapi' }).Version -eq '0.121.2') (($pins | Where-Object { $_.Name -eq 'fastapi' }).Version)

  $inst = Get-TcInstalledVersions -DistInfoNames @(
    'torch-2.11.0+cu128.dist-info', 'sentence_transformers-5.6.1.dist-info', 'fastapi-0.141.1.dist-info')
  T 'MUST NOT FIRE  THE ONE THAT WOULD HAVE MADE THIS CHECK VACUOUS - the dist-info UNDERSCORE name matches the hyphenated requirement, or every pin reads NOT INSTALLED and nothing is ever compared' `
    ($inst['sentence-transformers'] -eq '5.6.1') ("got '" + $inst['sentence-transformers'] + "'")

  $rows = Compare-TcPins -Pins $pins -Installed $inst
  $drift = @($rows | Where-Object { $_.Status -eq 'DRIFTED' })
  T 'MUST FIRE  THE FOUNDING BUG - a declared 5.1.2 against an installed 5.6.1 is a finding, not a rounding' `
    (($drift.Count -eq 2) -and ($drift.Name -contains 'sentence-transformers')) ("drifted=" + $drift.Count)
  T 'MUST NOT FIRE  a pin that agrees with the install is silent' `
    (@($rows | Where-Object { $_.Name -eq 'torch' })[0].Status -eq 'match') (@($rows | Where-Object { $_.Name -eq 'torch' })[0].Status)

  $rows2 = Compare-TcPins -Pins $pins -Installed @{}
  T 'MUST FIRE  a pinned package that is not installed at all is NOT INSTALLED, never a silent match' `
    (@($rows2 | Where-Object { $_.Status -eq 'NOT INSTALLED' }).Count -eq 3) ("count=" + @($rows2 | Where-Object { $_.Status -eq 'NOT INSTALLED' }).Count)

  $none = Get-TcPinnedRequirements -Lines @('# nothing but a comment', '', 'numpy')
  T 'CLEAN TWIN a file with NO pins comes back as an empty ARRAY, count 0 - @($null).Count is 1 in PS 5.1 and would have invented a pin' `
    (($none -is [array]) -and ($none.Count -eq 0)) ("count=" + @($none).Count)
  $one = Get-TcPinnedRequirements -Lines @('uvicorn==0.52.0')
  T 'CLEAN TWIN a SINGLE pin comes back as an array, not unrolled to one object' `
    (($one -is [array]) -and ($one.Count -eq 1)) ($one.GetType().FullName)

  if ($f) { Write-Output ("SELF-TEST FAIL: {0} check(s)" -f $f); exit 1 }
  Write-Output 'SELF-TEST PASS: 2 must-fire cases led by the founding drift (5.1.2 declared against 5.6.1 installed) plus the not-installed shape, 3 must-not-fire cases led by the dist-info underscore normalisation that would otherwise make every comparison vacuous, and 4 clean twins over local version segments, inline comments and array arity'
  exit 0
}

# ------------------------------------------------------------------------------------- live run
if (-not (Test-Path -LiteralPath $REQ)) {
  Write-Output ("PYTHON PINS AUDIT BLIND: {0} does not exist, so nothing was compared." -f $REQ)
  Exit-Guard -Name 'python-pins' -Summary 'blind=no-requirements' -Code 3
}
if (-not (Test-Path -LiteralPath $SITE)) {
  Write-Output ("PYTHON PINS AUDIT BLIND: {0} does not exist. A worktree, a CI runner and a fresh checkout all look like this, and reporting a clean pass here would be an assertion that ran against nothing." -f $SITE)
  Exit-Guard -Name 'python-pins' -Summary 'blind=no-venv' -Code 3
}

$pins = Get-TcPinnedRequirements -Lines ([IO.File]::ReadAllLines($REQ))
$pins = @($pins)
if (-not $pins.Count) {
  Write-Output ("PYTHON PINS AUDIT BLIND: {0} declares no `==` pins, which means the file's shape moved rather than the pins being satisfied." -f $REQ)
  Exit-Guard -Name 'python-pins' -Summary 'blind=no-pins' -Code 3
}
$dists = @(Get-ChildItem -LiteralPath $SITE -Directory -Filter '*.dist-info' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$rows = Compare-TcPins -Pins $pins -Installed (Get-TcInstalledVersions -DistInfoNames $dists)
$rows = @($rows)

foreach ($r in $rows) {
  Write-Output ("  {0,-26} declared {1,-16} installed {2,-16} {3}" -f $r.Name, $r.Declared, $(if ($r.Installed) { $r.Installed } else { '-' }), $r.Status)
}
$bad = @($rows | Where-Object { $_.Status -ne 'match' })
if ($bad.Count) {
  Write-Output ("PYTHON PINS AUDIT FAILED: {0} of {1} pinned package(s) in sidecar\requirements.txt do not match sidecar\.venv, against {2} installed distribution(s). Either the declaration is stale - correct it, and DATE the correction so a later reader can see it was retro-fitted to the install - or the venv is wrong, which is the expensive answer and needs sidecar\freeze_eval.py re-run to show the score space did not move." -f $bad.Count, $rows.Count, $dists.Count)
  Exit-Guard -Name 'python-pins' -Summary ("pins={0} mismatched={1} dists={2}" -f $rows.Count, $bad.Count, $dists.Count) -Code 2
}
Write-Output ("python-pins: PASSED - all {0} pinned package(s) match the venv, read against {1} installed distribution(s). Unpinned lines are not claims and are not checked." -f $rows.Count, $dists.Count)
Exit-Guard -Name 'python-pins' -Summary ("pins={0} mismatched=0 dists={1}" -f $rows.Count, $dists.Count) -Code 0
