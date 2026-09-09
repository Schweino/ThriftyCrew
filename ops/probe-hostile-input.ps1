# probe-hostile-input.ps1
# ---------------------------------------------------------------------------------------------------
# Every parser here has only ever been shown input a person wrote (2026-09-09, backlog I38).
#
# THE RULING THIS FILE DEPENDS ON (Brad, 2026-09-09). `Get-Random` appears in exactly three other files
# in this tree and all three are REFUSALS - a deterministic verification sample, a reproducible worklist,
# a retry jitter that uses the attempt index instead. Each is correct for what it refuses, which is
# unreproducible WORK SELECTION. None of them is an argument against generated TEST INPUT, because a
# SEEDED generator is reproducible by construction: the seed is printed on every run and re-feeding it
# replays every case byte for byte. That is exactly the property the deterministic-sample rule was
# protecting. Brad ruled that the three refusals do not extend to this, and this header is the record.
#
# WHY THIS ESTATE AND WHY THIS PARSER. This tree parses text it did not author all day - scraped store
# HTML, vendor JSON, Walmart payloads whose price shape has moved twice, ad PDFs, LLM returns. Measured
# 2026-09-07: 255 .ps1 files mention ConvertFrom-Json over 819 lines, and self-test cases whose MUST
# FIRE line names malformed, truncated, corrupt, empty or invalid input number SIX. `Import-CaptureCsv`
# is the first target because EVERY builder reads captures through it, and a capture is the input we
# author least.
#
# THE THREE OUTCOMES THAT MATTER, and the third is the reason this exists:
#   REFUSED  - it threw, or returned nothing. Correct. A parser is allowed to refuse.
#   SURVIVED - it returned rows from a variant that was still readable. Also fine.
#   ACCEPTED-CORRUPT - IT RETURNED ROWS CARRYING DAMAGE. This is the failure with no name, because it
#              looks exactly like success downstream, and a builder will price it.
#
# IT IS A REPORT, NOT A GATE, deliberately and per the standing rule. A gate that is red on day one for
# a backlog nobody is about to clear teaches people to ignore red. Exit 0 unless -Strict is passed.
#
# SCOPE OF A CLEAN REPORT: UNSOUND, and emphatically so. It tries the malformations it knows how to
# make against ONE parser. A clean report means those variants did not corrupt anything; it is not
# evidence the parser is robust, and it says nothing about the other 254 files.
#
#   .\probe-hostile-input.ps1                 run with a fresh seed
#   .\probe-hostile-input.ps1 -Seed 12345     replay a previous run exactly
#   .\probe-hostile-input.ps1 -SelfTest
# Exit 0 report produced, 2 with -Strict when something accepted corrupt input, 3 could not evaluate.
# ---------------------------------------------------------------------------------------------------
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [int]$Seed = 0,
  [int]$Cases = 60,
  [switch]$Strict,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\guard-contract.ps1')

# A known-good capture, written here rather than copied from a real one so the probe is hermetic and
# the same seed means the same bytes on any machine.
$script:GOOD_CAPTURE = @(
  'n|up|lp|size',
  'Great Value Large Eggs|$0.21/ea|3.48|12 ct',
  'Bananas|$0.58/lb|0.58|1 lb',
  'Whole Milk|$0.24/fl oz|3.78|128 fl oz'
) -join "`n"

function Test-TcTextDiffers {
  <# ORDINAL comparison, and this is not a nicety (2026-09-09, found by this file's own must-fire).
     PowerShell's `-ne` on strings is CULTURE-SENSITIVE, and culture-sensitive comparison IGNORES NUL
     characters: `('Bana' + [char]0 + 'nas') -ne 'Bananas'` evaluates to $false even though the two
     strings differ in length. So the default operator is blind to precisely the corruption class this
     probe exists to find, and the first version of this file's own fixture reported two malformation
     kinds as no-ops because of it. Anything comparing text that might carry damage needs Ordinal. #>
  param([string]$A, [string]$B)
  return (-not [string]::Equals($A, $B, [StringComparison]::Ordinal))
}

function New-TcHostileVariant {
  <# One seeded malformation of a known-good text. PURE given ($Text, $Kind, $Rand) - no file, no clock,
     so the fixtures drive the same code the sweep runs. #>
  param([string]$Text, [string]$Kind, [int]$Offset = 0)
  switch ($Kind) {
    'empty'          { return '' }
    'header-only'    { return ($Text -split "`n")[0] }
    'no-header'      { return (($Text -split "`n") | Select-Object -Skip 1) -join "`n" }
    'truncated'      { if ($Text.Length -le 1) { return '' } ; return $Text.Substring(0, [Math]::Max(1, $Offset % $Text.Length)) }
    'byte-flipped'   {
      if (-not $Text.Length) { return $Text }
      $i = $Offset % $Text.Length
      $c = [char]([int][char]$Text[$i] -bxor 0x20)
      return $Text.Substring(0, $i) + $c + $Text.Substring($i + 1)
    }
    'lone-quote'     { return $Text -replace 'Bananas', 'Bana"nas' }
    'extra-delims'   { return $Text -replace 'Bananas\|', 'Bananas|||' }
    'number-to-text' { return $Text -replace '3\.48', 'not-a-price' }
    'nul-byte'       { return $Text -replace 'Bananas', ("Bana" + [char]0 + "nas") }
    'huge-field'     { return $Text -replace 'Bananas', ('B' * 20000) }
    'crlf'           { return $Text -replace "`n", "`r`n" }
    'blank-lines'    { return ($Text -replace "`n", "`n`n") }
    default          { return $Text }
  }
}

$script:KINDS = @('empty','header-only','no-header','truncated','byte-flipped','lone-quote',
                  'extra-delims','number-to-text','nul-byte','huge-field','crlf','blank-lines')

function Test-TcRowsCorrupt {
  <# Did rows come back carrying damage? This is the ACCEPTED-CORRUPT test, and it is the whole point.
     Returns '' when the rows are clean, or the reason they are not. Pure. #>
  param([object[]]$Rows)
  foreach ($r in @($Rows)) {
    if ($null -eq $r) { continue }
    foreach ($p in $r.PSObject.Properties) {
      $v = [string]$p.Value
      if ($v -and $v.IndexOf([char]0) -ge 0) { return "a field carries a NUL byte" }
      if ($v -and $v.Length -gt 5000) { return "a field is $($v.Length) characters long" }
    }
  }
  return ''
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ("  ok    " + $n) } else { Write-Output ("  X     " + $n + "   got: " + $got); $script:bad++ }
  }

  $g = $script:GOOD_CAPTURE

  # MUST FIRE - the generator actually changes the bytes. A no-op generator would make every run green
  # while testing nothing, which is the exact shape of a fixture that cannot fail.
  # MUST FIRE - THE TRAP THIS FILE FOUND IN ITSELF. PowerShell's -ne is culture-sensitive and ignores
  # NUL, so the naive check reported two real malformations as no-ops. Ordinal sees them.
  $nulText = 'Bana' + [char]0 + 'nas'
  T 'MUST FIRE  -ne is BLIND to a NUL-byte difference, which is why every comparison here is Ordinal' `
    (($nulText -ne 'Bananas') -eq $false) 'PowerShell -ne saw the NUL after all; re-read this fixture'
  T 'MUST FIRE  Ordinal comparison DOES see it' (Test-TcTextDiffers -A $nulText -B 'Bananas') 'Ordinal missed a NUL difference'

  $changed = 0
  foreach ($k in $script:KINDS) {
    $v = New-TcHostileVariant -Text $g -Kind $k -Offset 17
    if (Test-TcTextDiffers -A $v -B $g) { $changed++ }
  }
  T 'MUST FIRE  every malformation kind actually changes the input' ($changed -eq $script:KINDS.Count) ("changed=$changed of $($script:KINDS.Count)")

  # MUST FIRE - REPRODUCIBILITY, which is the entire basis of the ruling this file rests on.
  $a1 = New-TcHostileVariant -Text $g -Kind 'truncated' -Offset 42
  $a2 = New-TcHostileVariant -Text $g -Kind 'truncated' -Offset 42
  T 'MUST FIRE  the same seed/offset reproduces the same bytes - this is why a SEEDED generator is not the thing the estate refuses' (-not (Test-TcTextDiffers -A $a1 -B $a2)) 'two runs differed'
  $a3 = New-TcHostileVariant -Text $g -Kind 'truncated' -Offset 43
  T 'MUST NOT FIRE  a different offset gives a different case, so the generator is not a constant' (Test-TcTextDiffers -A $a1 -B $a3) 'offsets 42 and 43 agreed'

  # MUST FIRE - the corruption detector sees a NUL that survived into a field.
  $nulRow = @([pscustomobject]@{ n = ("Bana" + [char]0 + "nas"); up = '$0.58/lb' })
  T 'MUST FIRE  a NUL byte surviving into a parsed field is ACCEPTED-CORRUPT' ((Test-TcRowsCorrupt -Rows $nulRow) -like '*NUL*') (Test-TcRowsCorrupt -Rows $nulRow)
  $bigRow = @([pscustomobject]@{ n = ('B' * 20000) })
  T 'MUST FIRE  a 20,000-character field is ACCEPTED-CORRUPT' ((Test-TcRowsCorrupt -Rows $bigRow) -like '*characters long*') (Test-TcRowsCorrupt -Rows $bigRow)

  # MUST NOT FIRE - a clean row is not reported, or the probe cries wolf on every run.
  $okRow = @([pscustomobject]@{ n = 'Bananas'; up = '$0.58/lb'; lp = '0.58' })
  T 'MUST NOT FIRE  a clean parsed row is not called corrupt' ((Test-TcRowsCorrupt -Rows $okRow) -eq '') (Test-TcRowsCorrupt -Rows $okRow)
  T 'MUST NOT FIRE  an EMPTY row set is not called corrupt - refusing is a legal outcome, not damage' ((Test-TcRowsCorrupt -Rows @()) -eq '') (Test-TcRowsCorrupt -Rows @())

  # MUST NOT FIRE - the empty variant really is empty, so "returned nothing" is reachable.
  T 'MUST NOT FIRE  the empty variant is empty' ((New-TcHostileVariant -Text $g -Kind 'empty') -eq '') 'not empty'

  # CLEAN TWIN - the adjacent behaviour a malformation must not break: an UNMODIFIED capture still
  # parses into three rows. A positive assertion, and the thing that proves the harness itself works.
  $tmp = Join-Path $env:TEMP ('tc-hostile-selftest-' + [guid]::NewGuid().ToString('N') + '.csv')
  try {
    [IO.File]::WriteAllText($tmp, $g, (New-Object Text.UTF8Encoding($false)))
    . (Join-Path $repo 'grocery\capture-lib.ps1')
    $rows = @(Import-CaptureCsv -Path $tmp)
    T 'CLEAN TWIN  the UNMODIFIED capture still parses to 3 rows through the real parser' ($rows.Count -eq 3) ("rows=" + $rows.Count)
  } finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
  }

  if ($bad -gt 0) { Write-Output ("hostile-input SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output 'hostile-input SELF-TEST PASS: 10 case(s) resolved'
  Write-GuardComplete -Name 'hostile-input' -Summary 'selftest pass'
  exit 0
}

# ---- the probe -------------------------------------------------------------------------------------
$capLib = Join-Path $repo 'grocery\capture-lib.ps1'
if (-not (Test-Path $capLib)) { Write-Output 'hostile-input: grocery\capture-lib.ps1 not found - BLIND, not clean.'; exit 3 }
. $capLib

if ($Seed -le 0) { $Seed = Get-Random -Minimum 1 -Maximum 2147483646 }
Get-Random -SetSeed $Seed | Out-Null
Write-Output ("hostile-input: seed {0}  (re-run with -Seed {0} to replay these exact cases)" -f $Seed)

$results = @()
$tmpDir = Join-Path $env:TEMP ('tc-hostile-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
try {
  for ($i = 0; $i -lt $Cases; $i++) {
    $kind = $script:KINDS[(Get-Random -Minimum 0 -Maximum $script:KINDS.Count)]
    $off  = Get-Random -Minimum 0 -Maximum 4096
    $text = New-TcHostileVariant -Text $script:GOOD_CAPTURE -Kind $kind -Offset $off
    $f = Join-Path $tmpDir ("case-$i.csv")
    [IO.File]::WriteAllText($f, $text, (New-Object Text.UTF8Encoding($false)))

    $outcome = ''; $detail = ''; $rowCount = 0
    try {
      $rows = @(Import-CaptureCsv -Path $f)
      $rowCount = $rows.Count
      $why = Test-TcRowsCorrupt -Rows $rows
      if ($why) { $outcome = 'ACCEPTED-CORRUPT'; $detail = $why }
      elseif ($rowCount -eq 0) { $outcome = 'REFUSED'; $detail = 'returned no rows' }
      else { $outcome = 'SURVIVED'; $detail = "returned $rowCount row(s)" }
    } catch {
      $outcome = 'REFUSED'; $detail = ($_.Exception.Message -replace '\s+', ' ')
      if ($detail.Length -gt 90) { $detail = $detail.Substring(0, 90) }
    }
    $results += [pscustomobject]@{ case = $i; kind = $kind; offset = $off; outcome = $outcome
                                   rows = $rowCount; detail = $detail }
  }
} finally {
  if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ONE ROW PER CASE, and the totals derived from them.
$corrupt  = @($results | Where-Object { $_.outcome -eq 'ACCEPTED-CORRUPT' })
$refused  = @($results | Where-Object { $_.outcome -eq 'REFUSED' })
$survived = @($results | Where-Object { $_.outcome -eq 'SURVIVED' })

Write-Output ("  {0} case(s) against Import-CaptureCsv: {1} refused, {2} survived, {3} ACCEPTED CORRUPT INPUT" -f `
  $results.Count, $refused.Count, $survived.Count, $corrupt.Count)
Write-Output ("  {0,-16} {1,-18} {2,7}  {3}" -f 'kind', 'outcome', 'rows', 'detail')
$byKind = @{}
foreach ($r in $results) {
  $k = "$($r.kind)|$($r.outcome)"
  if (-not $byKind.ContainsKey($k)) { $byKind[$k] = $r; Write-Output ("  {0,-16} {1,-18} {2,7}  {3}" -f $r.kind, $r.outcome, $r.rows, $r.detail) }
}
if ($corrupt.Count -gt 0) {
  Write-Output ''
  Write-Output '  ACCEPTED-CORRUPT is the outcome that matters: the parser returned rows carrying damage,'
  Write-Output '  which looks exactly like success to every builder downstream and gets priced.'
  foreach ($c in $corrupt) {
    Write-Output ("    case {0} kind={1} offset={2}: {3}" -f $c.case, $c.kind, $c.offset, $c.detail)
  }
  Write-Output ("  Replay with: .\probe-hostile-input.ps1 -Seed {0}" -f $Seed)
}
Write-GuardComplete -Name 'hostile-input' -Summary ("cases={0} corrupt={1} seed={2}" -f $results.Count, $corrupt.Count, $Seed)
if ($Strict -and $corrupt.Count -gt 0) { exit 2 }
exit 0
