<#
  audit-threshold-register.ps1 - a similarity threshold must say which space it was tuned in.

  WHY THIS EXISTS (2026-09-06, backlog E25). Two traps sit under every similarity number here and
  neither is visible in the code. Cosine and Euclidean answer different questions: on text of unequal
  length Euclidean calls two long strings similar for being long. And cosine's range depends on the
  space - on a signed embedding it runs -1 to 1 so 0 is the MIDDLE, while on anything built by
  counting (term frequencies, tf-idf, BM25) every component is non-negative so 0 is the FLOOR. A
  threshold carried from one to the other is silently wrong by half the range, and it fails by
  admitting or refusing rows rather than by erroring.

  This estate runs THREE non-comparable spaces at once - bi-encoder cosine, cross-encoder sigmoid
  probability, and BM25 - and the two most confusable numbers sit TEN LINES APART in sweep.py:
  COVERAGE_COS_FLOOR 0.55 (bi-encoder) and COVERAGE_RERANK_FLOOR 0.90 (cross-encoder). They read like
  a loose bar and a strict one. They do not share a scale at all.

  WHAT IT CHECKS, AND WHAT IT DELIBERATELY DOES NOT. It checks that every threshold-shaped constant
  and flag in the scanned files is NAMED in sidecar\THRESHOLDS.md. It cannot check that the recorded
  space is CORRECT - no static check can - so this buys the one thing a static check can buy: a new
  threshold cannot appear without someone writing down which space it came from.

  STRICT, NOT A RATCHET, unlike audit-write-seam. A ratchet is right when a real backlog exists that
  nobody can clear in a sitting; here the register was written complete on the day the gate shipped,
  so there is no backlog to amortise and a new unregistered threshold is always a new omission.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File ops\audit-threshold-register.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\ops' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$REGISTER = Join-Path $repo 'sidecar\THRESHOLDS.md'

# E25's own scope: sidecar, the dedup rescore, and the near-name shelf scorer. Deliberately NOT the
# whole tree - harvest.py's BAND_CAL_MIN is a nutrition band, not a similarity, and a detector that
# swept every numeric constant in the estate would drown the real ones.
$SCAN = @(
  'sidecar\*.py'
  'meal-prep\pipeline\harvest_embed.py'
  'meal-prep\pipeline\bm25_dedup_probe.py'
)

# NAME-DRIVEN, because a threshold is recognisable by what it is called and not by its value. The
# vocabulary is the similarity words; a constant called TIMEOUT_SEC is not in scope and should not be.
$CONST_RX = '^(?<n>[A-Z][A-Z0-9_]*(COS|RERANK|SIM|MARGIN|RATIO|FLOOR|ABOVE)[A-Z0-9_]*)\s*=\s*(?<v>-?[0-9])'
$FLAG_RX = 'add_argument\(\s*"--(?<n>margin|keep-above|[a-z-]*floor|[a-z-]*sim|[a-z-]*cos|[a-z-]*thresh[a-z-]*)"'

function Get-Thresholds([string]$root) {
  <# Every threshold-shaped name in scope, as [pscustomobject]@{ Name; File; Line }.
     A FUNCTION, not a script block, because compare-deals' lifters taught this estate that a
     $script: variable never travels with a lift. #>
  $found = New-Object System.Collections.Generic.List[object]
  foreach ($pat in $SCAN) {
    $full = Join-Path $root $pat
    $dir = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { continue }
    $leaf = Split-Path $full -Leaf
    foreach ($f in @(Get-ChildItem -Path $dir -Filter $leaf -File -ErrorAction SilentlyContinue)) {
      if ($f.FullName -match '\\\.venv\\|\\archive\\|\\worktrees\\') { continue }
      $n = 0
      foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
        $n++
        # Comments cannot declare a threshold, and the prose in THRESHOLDS.md quotes these names.
        if ($line -match '^\s*#') { continue }
        $m = [regex]::Match($line, $CONST_RX)
        if (-not $m.Success) { $m = [regex]::Match($line, $FLAG_RX) }
        if ($m.Success) {
          $found.Add([pscustomobject]@{ Name = $m.Groups['n'].Value; File = $f.Name; Line = $n })
        }
      }
    }
  }
  return $found
}

function Test-Registered([string]$name, [string]$registerText) {
  <# Named in the register. Substring, not word-boundary: a flag is written --keep-above in the code
     and `--keep-above` in the table, and a name can appear inside a sentence as well as a cell. #>
  return ($registerText -like ('*' + $name + '*'))
}

if ($SelfTest) {
  $fail = 0
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('thr-' + [guid]::NewGuid().ToString('N'))
  # THE ALLOCATOR REMEMBERS, not the fixture: a suite that leaks a temp dir per run is one this estate
  # has already been bitten by (memory: test-suites-leak-temp-dirs).
  try {
    New-Item -ItemType Directory -Path (Join-Path $tmp 'sidecar') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmp 'meal-prep\pipeline') -Force | Out-Null

    $probe = Join-Path $tmp 'sidecar\probe.py'
    @'
COVERAGE_COS_FLOOR = 0.55
TIMEOUT_SEC = 30
# COMMENTED_COS_FLOOR = 0.99
    ap.add_argument("--keep-above", type=float, default=0.1)
'@ | Set-Content $probe -Encoding UTF8

    $hits = Get-Thresholds $tmp
    $names = @($hits | ForEach-Object { $_.Name })

    if ($names -contains 'COVERAGE_COS_FLOOR') { Write-Output 'ok    finds a module-level similarity constant' } else { Write-Output 'FAIL  missed a module-level constant'; $fail++ }
    if ($names -contains 'keep-above') { Write-Output 'ok    finds an argparse threshold flag' } else { Write-Output 'FAIL  missed an argparse flag'; $fail++ }
    if ($names -notcontains 'TIMEOUT_SEC') { Write-Output 'ok    CLEAN TWIN a non-similarity constant is out of scope, not a finding' } else { Write-Output 'FAIL  swept a timeout in as a similarity threshold - this is how a detector becomes noise'; $fail++ }
    if ($names -notcontains 'COMMENTED_COS_FLOOR') { Write-Output 'ok    CLEAN TWIN a commented-out constant declares nothing' } else { Write-Output 'FAIL  a comment was read as a live threshold'; $fail++ }

    # MUST FIRE: the register is what makes this gate mean anything, so an unregistered name must be
    # caught. This is the founding case - COVERAGE_COS_FLOOR and COVERAGE_RERANK_FLOOR sit ten lines
    # apart in different spaces, and the register is the only place that says so.
    if (-not (Test-Registered 'COVERAGE_COS_FLOOR' 'a register that mentions nothing')) { Write-Output 'ok    MUST FIRE  an unregistered threshold is a finding' } else { Write-Output 'FAIL  an unregistered threshold passed'; $fail++ }
    if (Test-Registered 'COVERAGE_COS_FLOOR' '| `COVERAGE_COS_FLOOR` | sweep.py | 0.55 | S1 |') { Write-Output 'ok    CLEAN TWIN a registered threshold passes' } else { Write-Output 'FAIL  a registered threshold was reported missing'; $fail++ }
    if (-not (Test-Registered 'keep-above' 'mentions margin but not the other flag')) { Write-Output 'ok    MUST FIRE  a flag absent from the register is a finding' } else { Write-Output 'FAIL  an unregistered flag passed'; $fail++ }

    # The register on disk must actually cover the live tree - a self-test that only ever reads its
    # own fixture proves the regex compiles and nothing about the estate.
    if (Test-Path $REGISTER) {
      $reg = [IO.File]::ReadAllText($REGISTER)
      $live = Get-Thresholds $repo
      $missing = @(@($live | Where-Object { -not (Test-Registered $_.Name $reg) }) | ForEach-Object { $_.Name } | Sort-Object -Unique)
      if ($live.Count -gt 0) { Write-Output ("ok    the live tree yields {0} threshold(s) to check" -f $live.Count) } else { Write-Output 'FAIL  found NO thresholds in the live tree - the scan is broken, not the tree clean'; $fail++ }
      if ($missing.Count -eq 0) { Write-Output 'ok    every live threshold is named in THRESHOLDS.md' } else { Write-Output ('FAIL  unregistered in the live tree: ' + ($missing -join ', ')); $fail++ }
    } else {
      Write-Output 'FAIL  sidecar\THRESHOLDS.md is missing - the gate cannot mean anything without it'; $fail++
    }
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }

  if ($fail -gt 0) {
    Write-Output ("SELF-TEST FAIL: {0} case(s)" -f $fail)
    Exit-Guard -Name 'threshold-register' -Summary ("selftest-fail={0}" -f $fail) -Code 2
  }
  Write-Output 'SELF-TEST PASS: scope, comments, the must-fire for an unregistered threshold, and the live tree against the register on disk'
  Exit-Guard -Name 'threshold-register' -Summary 'selftest=pass' -Code 0
}

if (-not (Test-Path $REGISTER)) {
  Write-Output ("THRESHOLD REGISTER COULD NOT EVALUATE: {0} does not exist. This is discovery broken, NOT a clean tree." -f $REGISTER)
  Exit-Guard -Name 'threshold-register' -Summary 'blind=no-register' -Code 3
}
$reg = [IO.File]::ReadAllText($REGISTER)
$live = Get-Thresholds $repo
if ($live.Count -eq 0) {
  Write-Output 'THRESHOLD REGISTER COULD NOT EVALUATE: the scan found no thresholds at all in files that are known to contain them. The scan is broken, not the tree clean.'
  Exit-Guard -Name 'threshold-register' -Summary 'blind=no-hits' -Code 3
}
$missing = @($live | Where-Object { -not (Test-Registered $_.Name $reg) })
if ($missing.Count -gt 0) {
  foreach ($m in $missing) { Write-Output ("  unregistered  {0}  ({1}:{2})" -f $m.Name, $m.File, $m.Line) }
  Write-Output ("THRESHOLD REGISTER AUDIT FAILED: {0} similarity threshold(s) are not named in sidecar\THRESHOLDS.md. Add a row saying which of the three spaces it was tuned in - bi-encoder cosine, cross-encoder probability, or BM25 - because a number carried between them is wrong by a large fraction of the range and fails by admitting or refusing rows rather than by erroring." -f $missing.Count)
  Exit-Guard -Name 'threshold-register' -Summary ("unregistered={0} scanned={1}" -f $missing.Count, $live.Count) -Code 2
}
Write-Output ("threshold-register: PASSED - all {0} similarity threshold(s) in scope are named in sidecar\THRESHOLDS.md with the space they were tuned in." -f $live.Count)
Exit-Guard -Name 'threshold-register' -Summary ("scanned={0} unregistered=0" -f $live.Count) -Code 0
