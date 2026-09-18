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
# WHAT A SEED REPLAYS, AND WHAT IT DOES NOT (2026-09-18, backlog I210). The ruling above holds only
# while the DRAW is unchanged. A case is drawn as an index into $script:KINDS, so adding, removing or
# reordering one kind moves every later case of an old seed (measured 2026-09-18 under PS 5.1: after
# one seeding, eight index draws over 9 kinds against 10 kinds differed at 2 of 8 positions). So a seed
# is printed with three things beside it, and replays exactly only when all three match: the draw
# version ($script:DRAW_VERSION), the kind count and a fingerprint of the kind list, and the commit.
# The draw comes from ONE [System.Random] built from the seed and passed down, never from the
# session-global Get-Random stream, so nothing else in the session can shift the cases and the probe
# cannot shift anybody else's draws. A failure worth keeping is NOT kept as a seed: it is promoted to
# a recorded VALUE in $script:RECORDED_CASES, which every run executes whatever the seed and whatever
# happens to KINDS later (Hypothesis's `@example`, backlog I203).
#
# DUPLICATE DRAWS ARE ONE INPUT (2026-09-18, backlog I203). Ten of the twelve kinds ignore the drawn
# offset, so most draws re-run an input already run: at 0cc1d9702, seed 20260909's 12 ACCEPTED-CORRUPT
# cases were 3 copies of one nul-byte input and 9 of one huge-field input. The probe therefore keys an
# input on the BYTES it produced (Get-TcInputId), runs each distinct input once, keys a failure on
# kind plus reason (Get-TcFailureBuckets), and prints `offset=any` for a kind whose bytes the offset did
# not change, derived by running the generator (Test-TcKindUsesOffset), never from a declared list.
# SHRINKING is not built and is not worth building yet: a case is one kind and one offset, already
# minimal. It starts paying the day a case COMPOSES several malformations or generates the rows; widen
# the probe that way over a recorded list of choices, so a failing case can be reduced by deleting them.
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
#   .\probe-hostile-input.ps1                        run with a fresh seed
#   .\probe-hostile-input.ps1 -Seed 12345            replay a previous run (same draw, kinds and commit)
#   .\probe-hostile-input.ps1 -Kind nul-byte         run ONE case by value, no seed involved
#   .\probe-hostile-input.ps1 -Kind truncated -Offset 42
#   .\probe-hostile-input.ps1 -SelfTest
# Exit 0 report produced, 2 with -Strict when something accepted corrupt input, 3 could not evaluate.
# ---------------------------------------------------------------------------------------------------
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [int]$Seed = 0,
  [int]$Cases = 60,
  [string]$Kind = '',
  [int]$Offset = 0,
  [switch]$Strict,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$runSelfTest = [bool]$SelfTest

$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
. (Join-Path $repo 'lib\guard-contract.ps1')

# A known-good capture, written here rather than copied from a real one so the probe is hermetic: the
# same seed gives the same bytes on any machine AT THE SAME DRAW VERSION AND KIND LIST (see the header).
$script:GOOD_CAPTURE = @(
  'n|up|lp|size',
  'Great Value Large Eggs|$0.21/ea|3.48|12 ct',
  'Bananas|$0.58/lb|0.58|1 lb',
  'Whole Milk|$0.24/fl oz|3.78|128 fl oz'
) -join "`n"

# The draw procedure. Bump it whenever Get-TcHostileCasePlan draws differently, so an old seed printed
# beside the old version cannot be mistaken for a replay. v1 (to 2026-09-18) drew from the session-global
# Get-Random stream; v2 draws kind index then offset, per case, from one [System.Random]($Seed).
$script:DRAW_VERSION = 2

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
  <# One seeded malformation of a known-good text. PURE given ($Text, $Kind, $Offset) - no file, no clock,
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

# FAILURES PROMOTED TO VALUES (backlog I203). Each ran ACCEPTED-CORRUPT under seed 20260909 at
# 0cc1d9702. They run on EVERY probe run, seed or no seed, so a change to KINDS or to the draw cannot
# silently stop them being tried. Add a row here when a seeded run finds a new distinct failure.
$script:RECORDED_CASES = @(
  [pscustomobject]@{ kind = 'nul-byte';   offset = 0; found = 'seed 20260909, draw v1, 3 of 60 cases' },
  [pscustomobject]@{ kind = 'huge-field'; offset = 0; found = 'seed 20260909, draw v1, 9 of 60 cases' }
)

function Get-TcKindsFingerprint {
  <# The first 8 hex of SHA-256 over the kind list in order. Printed beside the seed: a seed replays only
     against the same fingerprint, because the draw is an INDEX into this list. #>
  param([string[]]$Kinds)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Kinds -join ','))) } finally { $sha.Dispose() }
  return (($h[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-TcInputId {
  <# What makes two cases the SAME case: the bytes they feed the parser, and nothing else. Keyed on the
     text, never on kind plus offset, because ten kinds ignore the offset (backlog I203). #>
  param([string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) } finally { $sha.Dispose() }
  return (($h[0..5] | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Test-TcKindUsesOffset {
  <# Does the offset change this kind's bytes? Derived by running the generator at three offsets, so it
     cannot drift from the code the way a declared list could. #>
  param([string]$Text, [string]$Kind)
  $a = New-TcHostileVariant -Text $Text -Kind $Kind -Offset 17
  $b = New-TcHostileVariant -Text $Text -Kind $Kind -Offset 42
  $c = New-TcHostileVariant -Text $Text -Kind $Kind -Offset 1000
  return ((Test-TcTextDiffers -A $a -B $b) -or (Test-TcTextDiffers -A $a -B $c))
}

function Get-TcHostileCasePlan {
  <# The seeded draw, draw version 2: ONE [System.Random] built from the seed, and per case a kind index
     then an offset. PURE given ($Seed, $Cases, $Kinds): it never reads or reseeds the session-global
     Get-Random stream (backlog I210), so another caller in the session cannot shift these cases and
     this cannot shift theirs. #>
  param([int]$Seed, [int]$Cases, [string[]]$Kinds)
  $rng = New-Object System.Random($Seed)
  $plan = @()
  for ($i = 0; $i -lt $Cases; $i++) {
    $k = $Kinds[$rng.Next(0, $Kinds.Count)]
    $o = $rng.Next(0, 4096)
    $plan += [pscustomobject]@{ case = $i; kind = $k; offset = $o }
  }
  return ,$plan
}

function Get-TcFailureBuckets {
  <# Distinct failures, keyed on kind plus reason (Hypothesis keys on exception type plus raising line and
     reports each key once). A count of generated failures is not a count of bugs. One row per bucket,
     with how many cases and how many DISTINCT inputs fell into it. #>
  param([object[]]$Results)
  $buckets = [ordered]@{}
  foreach ($r in @($Results)) {
    if ($null -eq $r -or $r.outcome -ne 'ACCEPTED-CORRUPT') { continue }
    $key = "$($r.kind)|$($r.detail)"
    if (-not $buckets.Contains($key)) {
      $buckets[$key] = [pscustomobject]@{ kind = $r.kind; detail = $r.detail; cases = 0; inputs = @{}; offsets = @() }
    }
    $b = $buckets[$key]
    $b.cases++
    $b.inputs[$r.input] = $true
    $b.offsets += $r.offset
  }
  $out = @()
  foreach ($b in $buckets.Values) {
    $out += [pscustomobject]@{ kind = $b.kind; detail = $b.detail; cases = $b.cases; inputs = $b.inputs.Count; offsets = $b.offsets }
  }
  return ,$out
}

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

function Get-TcProbeCommit {
  <# The commit the probe ran at, marked when this file differs from it, because a seed replays against
     a harness and a harness is a commit (measurement.md). 'unknown' when git cannot answer. #>
  $c = 'unknown'
  try {
    $got = & git -C $repo rev-parse --short HEAD
    if ($LASTEXITCODE -eq 0 -and $got) { $c = [string]$got }
    & git -C $repo diff --quiet HEAD -- 'ops/probe-hostile-input.ps1'
    if ($LASTEXITCODE -ne 0) { $c += '+probe-modified' }
  } catch { $c = 'unknown' }
  return $c
}

# ---- self-test -------------------------------------------------------------------------------------
if ($runSelfTest) {
  $bad = 0
  $ran = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    $script:ran++
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

  # ---- backlog I203: duplicate draws are one input, and a failure is counted once -----------------
  # MUST FIRE - the founding shape: seed 20260909's three nul-byte cases were drawn at offsets 1601, 932
  # and 2184, and the bytes are identical, so they are ONE input. Keyed on kind plus offset they read
  # as three, which is how "12 ACCEPTED CORRUPT" came to mean 2 distinct inputs.
  $nulIds = @(1601, 932, 2184 | ForEach-Object { Get-TcInputId -Text (New-TcHostileVariant -Text $g -Kind 'nul-byte' -Offset $_) })
  $nulDistinct = @($nulIds | Select-Object -Unique).Count
  T 'MUST FIRE  three offsets of an offset-blind kind are ONE input, not three' ($nulDistinct -eq 1) ("distinct=$nulDistinct")
  # CLEAN TWIN - dedupe must not merge inputs that really differ: two truncation points are two inputs.
  $trIds = @(5, 9 | ForEach-Object { Get-TcInputId -Text (New-TcHostileVariant -Text $g -Kind 'truncated' -Offset $_) })
  $trDistinct = @($trIds | Select-Object -Unique).Count
  T 'CLEAN TWIN  two truncation offsets are still TWO distinct inputs' ($trDistinct -eq 2) ("distinct=$trDistinct")

  # MUST FIRE - offset-blindness is DERIVED, so the report can print offset=any: nul-byte ignores it.
  T 'MUST FIRE  nul-byte is derived as ignoring the offset' (-not (Test-TcKindUsesOffset -Text $g -Kind 'nul-byte')) 'said it uses the offset'
  # CLEAN TWIN - and truncated is derived as using it, so the offset is still printed where it matters.
  T 'CLEAN TWIN  truncated is derived as using the offset' (Test-TcKindUsesOffset -Text $g -Kind 'truncated') 'said it ignores the offset'

  # MUST FIRE - bucketing: the founding run's 12 corrupt cases (3 nul-byte, 9 huge-field, each over one
  # input) are 2 distinct failures over 2 distinct inputs, with the case counts kept beside them.
  $syn = @()
  foreach ($o in 1601, 932, 2184) { $syn += [pscustomobject]@{ kind = 'nul-byte'; offset = $o; outcome = 'ACCEPTED-CORRUPT'; detail = 'a field carries a NUL byte'; input = 'n1' } }
  foreach ($o in 3569, 1376, 2559, 3054, 800, 2582, 4076, 1082, 1131) { $syn += [pscustomobject]@{ kind = 'huge-field'; offset = $o; outcome = 'ACCEPTED-CORRUPT'; detail = 'a field is 20000 characters long'; input = 'h1' } }
  $syn += [pscustomobject]@{ kind = 'crlf'; offset = 7; outcome = 'SURVIVED'; detail = 'returned 3 row(s)'; input = 'c1' }
  $bk = Get-TcFailureBuckets -Results $syn
  $bkShape = (@($bk) | ForEach-Object { "$($_.kind):$($_.cases)/$($_.inputs)" }) -join ','
  T 'MUST FIRE  12 corrupt cases over 2 inputs bucket to 2 distinct failures, counts kept' ($bkShape -eq 'nul-byte:3/1,huge-field:9/1') $bkShape
  # MUST NOT FIRE - a run with no corrupt case has no failure bucket.
  $bk0 = Get-TcFailureBuckets -Results @($syn[-1])
  T 'MUST NOT FIRE  a SURVIVED case makes no failure bucket' (@($bk0).Count -eq 0) ("buckets=" + @($bk0).Count)

  # MUST FIRE - the two found failures are VALUES now, not a seed: both are recorded, by kind.
  $recKinds = (@($script:RECORDED_CASES) | ForEach-Object { $_.kind }) -join ','
  T 'MUST FIRE  the found failures nul-byte and huge-field are recorded as values' ($recKinds -eq 'nul-byte,huge-field') $recKinds

  # MUST FIRE - one failure replays BY VALUE, no seed involved: the real probe, out of process, run as
  # -Kind nul-byte -Strict, runs exactly one case, names it ACCEPTED-CORRUPT and exits 2.
  $me = Join-Path $here 'probe-hostile-input.ps1'
  $prevEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $childOut = @(& powershell -NoProfile -File $me -Kind nul-byte -Strict); $childRc = $LASTEXITCODE } finally { $ErrorActionPreference = $prevEap }
  $childDone = @($childOut | Where-Object { $_ -like 'HOSTILE-INPUT-COMPLETE cases=1 *corrupt=1 *kind=nul-byte*' }).Count
  T 'MUST FIRE  -Kind nul-byte -Strict replays one case by value, ACCEPTED-CORRUPT, exit 2' ($childRc -eq 2 -and $childDone -eq 1) ("rc=$childRc marker=$childDone last=" + ($childOut | Select-Object -Last 1))

  # ---- backlog I210: a seed replays only against the same draw, and the draw is isolated ----------
  # MUST FIRE - the draw never touches the session-global Get-Random stream. Seed the global stream,
  # draw once; reseed it identically, build a plan, draw again: the two global draws must agree. The v1
  # probe reseeded the global stream itself, so this read different numbers and nothing said so.
  Get-Random -SetSeed 7 | Out-Null
  $g1 = Get-Random -Minimum 0 -Maximum 1000000
  Get-Random -SetSeed 7 | Out-Null
  $null = Get-TcHostileCasePlan -Seed 20260909 -Cases 5 -Kinds $script:KINDS
  $g2 = Get-Random -Minimum 0 -Maximum 1000000
  T 'MUST FIRE  building a plan leaves the session Get-Random stream untouched, both directions' ($g1 -eq $g2) ("before=$g1 after=$g2")

  # MUST FIRE - the draw is PINNED: seed 20260909 under draw v2 over the current 12 kinds gives exactly
  # these first four cases. When this goes red, the draw or KINDS changed and EVERY OLD SEED NOW REPLAYS
  # DIFFERENT CASES: bump $script:DRAW_VERSION if the draw changed, re-pin these, and say so in the commit.
  $pin = Get-TcHostileCasePlan -Seed 20260909 -Cases 4 -Kinds $script:KINDS
  $pinShape = (@($pin) | ForEach-Object { "$($_.kind)@$($_.offset)" }) -join ','
  T 'MUST FIRE  seed 20260909 draws the pinned first four cases (a red here means old seeds moved)' ($pinShape -eq 'lone-quote@2978,crlf@1439,nul-byte@2029,crlf@1942') $pinShape
  T 'MUST FIRE  the kinds fingerprint printed beside a seed is the pinned one for these 12 kinds' ((Get-TcKindsFingerprint -Kinds $script:KINDS) -eq 'eb8662a9') (Get-TcKindsFingerprint -Kinds $script:KINDS)
  # MUST FIRE - one added kind changes the fingerprint, so a reader holding an old seed can SEE it moved.
  T 'MUST FIRE  adding one kind changes the fingerprint' ((Get-TcKindsFingerprint -Kinds ($script:KINDS + 'x')) -ne (Get-TcKindsFingerprint -Kinds $script:KINDS)) 'fingerprint did not move'
  # CLEAN TWIN - reproducibility itself still works: the same seed twice gives the same plan.
  $r1 = (@(Get-TcHostileCasePlan -Seed 424242 -Cases 20 -Kinds $script:KINDS) | ForEach-Object { "$($_.kind)@$($_.offset)" }) -join ','
  $r2 = (@(Get-TcHostileCasePlan -Seed 424242 -Cases 20 -Kinds $script:KINDS) | ForEach-Object { "$($_.kind)@$($_.offset)" }) -join ','
  T 'CLEAN TWIN  the same seed twice draws the same 20 cases' ($r1 -eq $r2 -and $r1.Length -gt 0) 'two plans differed'

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

  # A literal list knows its own number, so a shortfall is a defect rather than a smaller suite.
  $expected = 24
  if ($ran -ne $expected) { Write-Output ("  X     the suite ran {0} case(s), expected {1}" -f $ran, $expected); $bad++ }

  if ($bad -gt 0) { Write-Output ("hostile-input SELF-TEST FAIL ({0})" -f $bad); exit 2 }
  Write-Output ("hostile-input SELF-TEST PASS: {0} case(s) resolved" -f $ran)
  Exit-Guard -Name 'hostile-input' -Summary 'selftest pass' -Code 0
}

# ---- the probe -------------------------------------------------------------------------------------
$capLib = Join-Path $repo 'grocery\capture-lib.ps1'
if (-not (Test-Path $capLib)) { Write-Output 'hostile-input: grocery\capture-lib.ps1 not found - BLIND, not clean.'; exit 3 }
. $capLib

$commit = Get-TcProbeCommit
$kfp = Get-TcKindsFingerprint -Kinds $script:KINDS
$replayOne = [bool]$Kind
if ($replayOne) {
  if ($script:KINDS -notcontains $Kind) {
    Write-Output ("hostile-input: unknown -Kind '{0}'. Kinds: {1}" -f $Kind, ($script:KINDS -join ', ')); exit 3
  }
  $plan = @([pscustomobject]@{ case = 0; kind = $Kind; offset = $Offset })
  $recorded = @()
  Write-Output ("hostile-input: ONE case by value, kind={0} offset={1} (no seed involved)  commit {2}" -f $Kind, $Offset, $commit)
} else {
  if ($Seed -le 0) { $Seed = (New-Object System.Random).Next(1, 2147483646) }
  $plan = Get-TcHostileCasePlan -Seed $Seed -Cases $Cases -Kinds $script:KINDS
  $recorded = @($script:RECORDED_CASES)
  Write-Output ("hostile-input: seed {0}  draw v{1}  kinds {2} (fp {3})  commit {4}" -f $Seed, $script:DRAW_VERSION, $script:KINDS.Count, $kfp, $commit)
  Write-Output ("  -Seed {0} replays these exact cases only at draw v{1} over kinds fp {2}; a change to either moves them." -f $Seed, $script:DRAW_VERSION, $kfp)
}

$offsetKinds = @($script:KINDS | Where-Object { Test-TcKindUsesOffset -Text $script:GOOD_CAPTURE -Kind $_ })

function Invoke-TcProbeInput {
  <# Run one input through the real parser and classify it. #>
  param([string]$Text, [string]$Path)
  [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
  $outcome = ''; $detail = ''; $rowCount = 0
  try {
    $rows = @(Import-CaptureCsv -Path $Path)
    $rowCount = $rows.Count
    $why = Test-TcRowsCorrupt -Rows $rows
    if ($why) { $outcome = 'ACCEPTED-CORRUPT'; $detail = $why }
    elseif ($rowCount -eq 0) { $outcome = 'REFUSED'; $detail = 'returned no rows' }
    else { $outcome = 'SURVIVED'; $detail = "returned $rowCount row(s)" }
  } catch {
    $outcome = 'REFUSED'; $detail = ($_.Exception.Message -replace '\s+', ' ')
    if ($detail.Length -gt 90) { $detail = $detail.Substring(0, 90) }
  }
  return [pscustomobject]@{ outcome = $outcome; rows = $rowCount; detail = $detail }
}

$results = @()
$recResults = @()
$byInput = @{}   # input id -> outcome; each DISTINCT input runs once
$tmpDir = Join-Path $env:TEMP ('tc-hostile-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
try {
  $n = 0
  foreach ($set in @(@{ name = 'seed'; cases = $plan }, @{ name = 'recorded'; cases = $recorded })) {
    foreach ($p in @($set.cases)) {
      if ($null -eq $p) { continue }
      $text = New-TcHostileVariant -Text $script:GOOD_CAPTURE -Kind $p.kind -Offset $p.offset
      $id = Get-TcInputId -Text $text
      if (-not $byInput.ContainsKey($id)) {
        $byInput[$id] = Invoke-TcProbeInput -Text $text -Path (Join-Path $tmpDir ("input-$n.csv"))
        $n++
      }
      $o = $byInput[$id]
      $offTxt = if ($offsetKinds -contains $p.kind) { [string]$p.offset } else { 'any' }
      $row = [pscustomobject]@{ case = $p.case; kind = $p.kind; offset = $offTxt; input = $id; outcome = $o.outcome
                                rows = $o.rows; detail = $o.detail }
      if ($set.name -eq 'seed') { $results += $row } else { $recResults += $row }
    }
  }
} finally {
  if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ONE ROW PER CASE, and the totals derived from them.
$corrupt  = @($results | Where-Object { $_.outcome -eq 'ACCEPTED-CORRUPT' })
$refused  = @($results | Where-Object { $_.outcome -eq 'REFUSED' })
$survived = @($results | Where-Object { $_.outcome -eq 'SURVIVED' })
$inputs   = @($results | ForEach-Object { $_.input } | Select-Object -Unique).Count
$buckets  = Get-TcFailureBuckets -Results $results
$corruptInputs = @($corrupt | ForEach-Object { $_.input } | Select-Object -Unique).Count

Write-Output ("  {0} case(s) over {1} distinct input(s) against Import-CaptureCsv: {2} refused, {3} survived, {4} ACCEPTED CORRUPT INPUT" -f `
  $results.Count, $inputs, $refused.Count, $survived.Count, $corrupt.Count)
Write-Output ("  the offset changes the bytes of {0} of {1} kind(s) ({2}); for the rest it prints offset=any" -f `
  $offsetKinds.Count, $script:KINDS.Count, ($offsetKinds -join ', '))
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
  Write-Output ("  {0} case(s), {1} distinct input(s), {2} DISTINCT FAILURE(S) - one line per failure, not per case:" -f `
    $corrupt.Count, $corruptInputs, @($buckets).Count)
  foreach ($b in @($buckets)) {
    $offs = if ($offsetKinds -contains $b.kind) { 'offsets ' + ((@($b.offsets) | Select-Object -Unique) -join ',') } else { 'offset did not matter (any offset gives these bytes)' }
    Write-Output ("    kind={0}: {1}  [{2} case(s) over {3} input(s); {4}]" -f $b.kind, $b.detail, $b.cases, $b.inputs, $offs)
  }
  if ($replayOne) {
    Write-Output ("  Replay with: .\probe-hostile-input.ps1 -Kind {0} -Offset {1}" -f $Kind, $Offset)
  } else {
    Write-Output ("  Replay with: .\probe-hostile-input.ps1 -Seed {0}   (draw v{1}, kinds fp {2}); one failure by value: -Kind <kind>" -f $Seed, $script:DRAW_VERSION, $kfp)
  }
}
$recCorrupt = @($recResults | Where-Object { $_.outcome -eq 'ACCEPTED-CORRUPT' })
if (@($recResults).Count -gt 0) {
  Write-Output ''
  Write-Output ("  RECORDED cases (found failures kept as values, run on every seed): {0} of {1} still ACCEPTED CORRUPT" -f $recCorrupt.Count, @($recResults).Count)
  foreach ($r in $recResults) { Write-Output ("    kind={0} offset={1}: {2} - {3}" -f $r.kind, $r.offset, $r.outcome, $r.detail) }
}
if ($replayOne) {
  $summary = "cases={0} inputs={1} corrupt={2} distinct_failures={3} kind={4} offset={5} commit={6}" -f `
    $results.Count, $inputs, $corrupt.Count, @($buckets).Count, $Kind, $Offset, $commit
} else {
  $summary = "cases={0} inputs={1} corrupt={2} distinct_failures={3} recorded_corrupt={4}/{5} seed={6} draw=v{7} kinds={8} kfp={9} commit={10}" -f `
    $results.Count, $inputs, $corrupt.Count, @($buckets).Count, $recCorrupt.Count, @($recResults).Count, $Seed, $script:DRAW_VERSION, $script:KINDS.Count, $kfp, $commit
}
Write-GuardComplete -Name 'hostile-input' -Summary $summary
if ($Strict -and ($corrupt.Count + $recCorrupt.Count) -gt 0) { exit 2 }
exit 0
