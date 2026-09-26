<#
  probe-sams-unit-price-shapes.ps1 - which NOTATION does Sam's print a unit price in, and to what PRECISION?

  WHY THIS IS COMMITTED RATHER THAN DESCRIBED (measurement.md, "NAMING A SCRATCH HARNESS IS NOT NAMING A
  HARNESS"). On 2026-09-20 Sam's changed how it renders a sub-dollar unit price: "$0.93/lb" became
  "92.8 c/lb". That single change cost 6 of 8 terms on the day's capture, because the capture agent's row
  contract accepted only the dollar spelling. The question "what shape is Sam's printing today, and has it
  moved?" is therefore one that WILL be asked again - by whoever investigates the next thin Sam's pull - so
  the probe that answered it the first time is committed instead of re-derived.

  This is a REPORT, never a gate. It reads captures on disk and prints what it found; it has no bar to fail
  and no ratchet, because the shape is Sam's decision and not something a push can be wrong about.
  `.\probe-sams-unit-price-shapes.ps1 -SelfTest` drives it over frozen fixture captures.

  SCOPE OF A CLEAN REPORT: this reads the capture FILES on disk and nothing else. It is sound for the
  captures it names and says nothing whatever about captures it was not pointed at, about rows a sweep never
  collected, or about what Sam's will print tomorrow. It reports SHAPES, never whether a price is right.

  WHAT IT MEASURED ON 2026-09-20 (29 capture files, grocery/out/captures/sams-capture-*.csv, 25,434 priced
  and blank rows):
    - dollar form  24,073 rows, EVERY ONE of them carrying exactly 2 decimal places
    - cents  form       7 rows, every one on 2026-09-20, every one carrying exactly 1 decimal place
    - blank         1,354 rows
    - other             0 rows
  and on 2026-09-20 alone the split is mechanical, with ZERO exceptions over the 20 priced rows: every unit
  price below $1.00 printed in cents, every one at or above $1.00 printed in dollars. Same item ids across
  2026-09-19 and 2026-09-20 show the SAME product switching notation ("Sweet Onions, 6 lbs." $0.93/lb ->
  92.8 c/lb), which is what makes this a rendering change by Sam's rather than a rare row shape.

  THE PRECISION IS THE HALF OF THIS THAT MATTERS TO PRICING. The cents form is not a re-spelling, it is a
  MORE PRECISE number: $0.25/oz became 24.8 c/oz, and $0.99/ea became 99.2 c/ea. build-sams-deals back-solves
  a pack size out of linePrice / unitPrice, so the rounding in the unit price IS the error bar on the size it
  derives - and a cents-form price is rounded to a TENTH of a cent, ten times tighter than the cent the whole
  builder was written around. This probe prints the decimal places for that reason: a shape census that did
  not would hide the number the pricing path actually turns on.
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop
param(
  [string]$CaptureDir = '',
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
# The self-test is hermetic: in-file fixtures and temp files it writes itself, no repo file but this one.
# gate-inputs: grocery\probe-sams-unit-price-shapes.ps1
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

<#
  Classify ONE captured unit-price string. Returns @{ form; value; decimals; halfUlp } or $null.

    form      'dollar' | 'cents'
    value     the price in DOLLARS per unit, whichever way it was printed
    decimals  decimal places as PRINTED, in the notation it was printed in
    halfUlp   half the last printed digit, IN DOLLARS - the true rounding bound on `value`

  halfUlp is the whole point. "$0.93/lb" is rounded to the cent, so it is 0.93 +/- 0.005; "92.8 c/lb" is
  rounded to the tenth of a cent, so it is 0.928 +/- 0.0005. Reporting one bound for both would state an
  uncertainty ten times too wide for every cents row, and the size build-sams-deals derives from it carries
  that bound onto the board.
#>
function Get-SamsUnitPriceShape([string]$Text) {
  $t = ("" + $Text).Trim()
  if (-not $t) { return $null }

  $dollar = [regex]::Match($t, '^\$\s*([\d,]+(?:\.(\d{1,4}))?)\s*/\s*(.+)$')
  if ($dollar.Success) {
    $digits = $dollar.Groups[2].Value
    $v = 0.0
    if (-not [double]::TryParse(($dollar.Groups[1].Value -replace ',', ''), [ref]$v)) { return $null }
    return @{ form = 'dollar'; value = $v; decimals = $digits.Length
              halfUlp = 0.5 * [math]::Pow(10, -1 * $digits.Length); unit = $dollar.Groups[3].Value.Trim() }
  }

  # Cents. ANCHORED ON THE CENT GLYPH FAMILY, deliberately NOT on "any 1-3 non-digit characters" the way
  # walmart-row-lib.ps1 does it. The loose form reads a hypothetical "0.20 USD/oz" as 0.0020 USD/oz - a
  # silent hundredfold basis error on a live paid board, which is the class .claude/rules/grocery.md calls
  # the hardest defect here to find later. An unrecognised glyph returns $null, which downstream is an
  # ordinary per-row reject: a row we decline to price, never a row we price wrongly.
  # U+00A2 is what arrives today (read off the 2026-09-20 capture, codepoint by codepoint). U+00C2 U+00A2
  # is the cp1252-mangled spelling the capture sink used to produce, recorded in walmart-row-lib.ps1's
  # header; a bare "c" is accepted because in this position it can be nothing else.
  # THE PATTERN IS BUILT, NEVER TYPED. A cent glyph written as a literal here puts non-ASCII bytes in a
  # .ps1 that PowerShell 5.1 reads as ANSI, and the script then fails to PARSE - which is how the first
  # version of this file died. Concatenating from [char] codepoints keeps the source pure ASCII.
  $centClass = '(?:' + ([string][char]0x00C2) + '?' + ([string][char]0x00A2) + '|[cC])'
  $cents = [regex]::Match($t, ('^([\d,]+(?:\.(\d{1,4}))?)\s*' + $centClass + '\s*/\s*(.+)$'))
  if ($cents.Success) {
    $digits = $cents.Groups[2].Value
    $v = 0.0
    if (-not [double]::TryParse(($cents.Groups[1].Value -replace ',', ''), [ref]$v)) { return $null }
    return @{ form = 'cents'; value = ($v / 100.0); decimals = $digits.Length
              halfUlp = 0.5 * [math]::Pow(10, -1 * ($digits.Length + 2)); unit = $cents.Groups[3].Value.Trim() }
  }
  return $null
}

# Writes the report to the output stream and records its code in $script:ShapeExit. It does NOT `return`
# the code: a returned value JOINS the function's output in PowerShell, so `@(Invoke-SamsShapeReport ...)`
# came back with a bare 0 as its last element and the -COMPLETE marker was no longer the last line - the
# exact shape lib\selftest-verdict.ps1 scores 3 rather than ok.
function Invoke-SamsShapeReport([string]$Dir) {
  $files = @(Get-ChildItem -LiteralPath $Dir -Filter 'sams-capture-*.csv' -File -ErrorAction SilentlyContinue |
             Sort-Object Name)
  if ($files.Count -eq 0) {
    # A could-not-look is never an answer about Sam's (.claude/rules/grocery.md). Say so and exit 3.
    Write-Output ("SAMS-UNIT-PRICE-SHAPES: BLIND - no sams-capture-*.csv under " + $Dir +
                  '. The captures are gitignored, so a worktree or clean checkout has none; this run says NOTHING about what Sam''s prints.')
    Write-Output 'SAMS-UNIT-PRICE-SHAPES-COMPLETE scanned=0 findings=0 blind=1'
    $script:ShapeExit = 3
    return
  }

  $tot = 0; $blank = 0; $unparsed = 0
  $byForm = @{}
  $byFormDec = @{}
  $unknown = New-Object System.Collections.Generic.List[string]
  $perFile = New-Object System.Collections.Generic.List[object]

  foreach ($f in $files) {
    $rows = 0; $d = 0; $c = 0; $b = 0; $x = 0
    foreach ($line in @(Get-Content -LiteralPath $f.FullName -Encoding UTF8)) {
      if (-not $line) { continue }
      if ($line.StartsWith('#')) { continue }
      $parts = $line -split '\|'
      if ($parts.Count -lt 5) { continue }
      if ($parts[0] -eq 'q') { continue }
      $rows++; $tot++
      $up = ("" + $parts[3]).Trim()
      if (-not $up) { $b++; $blank++; continue }
      $shape = Get-SamsUnitPriceShape $up
      if ($null -eq $shape) {
        $x++; $unparsed++
        if ($unknown.Count -lt 25) { [void]$unknown.Add($up) }
        continue
      }
      if ($shape.form -eq 'cents') { $c++ } else { $d++ }
      $byForm[$shape.form] = 1 + [int]$byForm[$shape.form]
      $k = $shape.form + '/' + $shape.decimals
      $byFormDec[$k] = 1 + [int]$byFormDec[$k]
    }
    [void]$perFile.Add([pscustomobject]@{ file = $f.Name; rows = $rows; dollar = $d; cents = $c; blank = $b; unparsed = $x })
  }

  Write-Output ('SAMS UNIT-PRICE SHAPES over ' + $files.Count + ' capture file(s) in ' + $Dir)
  Write-Output ''
  Write-Output ('{0,-44} {1,6} {2,7} {3,6} {4,6} {5,9}' -f 'file', 'rows', '$form', 'cform', 'blank', 'unparsed')
  foreach ($r in $perFile) {
    Write-Output ('{0,-44} {1,6} {2,7} {3,6} {4,6} {5,9}' -f $r.file, $r.rows, $r.dollar, $r.cents, $r.blank, $r.unparsed)
  }
  Write-Output ''
  # A RATE IS PRINTED WITH ITS DENOMINATOR, always (measurement.md / backlog E20).
  foreach ($k in @($byFormDec.Keys | Sort-Object)) {
    $n = [int]$byFormDec[$k]
    $parts = $k -split '/'
    $dec = [int]$parts[1]
    $halfUlp = if ($parts[0] -eq 'cents') { 0.5 * [math]::Pow(10, -1 * ($dec + 2)) } else { 0.5 * [math]::Pow(10, -1 * $dec) }
    Write-Output ('  {0,-8} {1} decimal place(s)  ->  rounding bound +/- ${2,-8}   {3} of {4} priced-or-blank rows ({5:N2}%)' -f `
                  $parts[0], $dec, $halfUlp, $n, $tot, (100.0 * $n / [math]::Max(1, $tot)))
  }
  Write-Output ('  blank    (no unit price at all)                              ' + $blank + ' of ' + $tot)
  if ($unparsed -gt 0) {
    Write-Output ('  UNPARSED (a shape this probe does not know)                  ' + $unparsed + ' of ' + $tot)
    foreach ($u in $unknown) { Write-Output ('      [' + $u + ']') }
  }
  Write-Output ''
  Write-Output ('SAMS-UNIT-PRICE-SHAPES-COMPLETE scanned=' + $tot + ' findings=' + $unparsed + ' blind=0')
  $script:ShapeExit = 0
}

# ---------------------------------------------------------------------------------------------------
if (-not $SelfTest) {
  if (-not $CaptureDir) { $CaptureDir = Join-Path $here 'out\captures' }
  $script:ShapeExit = 1
  Invoke-SamsShapeReport $CaptureDir
  exit $script:ShapeExit
}

# --- SELF-TEST ---------------------------------------------------------------------------------------
# Cases are a LITERAL LIST, so the count is asserted: a suite whose target set it knows owes that number
# (.claude/rules/ops-and-gates.md). Every temp path is unique to this run and removed in finally.
$fail = 0
$ran = 0
function T([string]$name, [bool]$ok, $got) {
  $script:ran++
  if ($ok) { Write-Output ('  ok    ' + $name) }
  else { Write-Output ('  X     ' + $name + '   got: ' + $got); $script:fail++ }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('sams-shape-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $scratch -ErrorAction Stop | Out-Null
try {
  # NAMED IN FULL, never $C. PowerShell variable names are CASE-INSENSITIVE, so a $C here and the $c holding
  # a parsed shape a few lines below are ONE variable: the fixture rows were built with a Hashtable where the
  # cent sign should have been, and three cases failed for a reason that had nothing to do with the code
  # under test - each reporting $null from a parser that was working perfectly.
  # .claude/rules/ops-and-gates.md records the same trap as a fixture's $pS being $PS.
  $CentSign = [string][char]0x00A2

  # ---- the shape reader itself ----
  $d = Get-SamsUnitPriceShape '$0.93/lb'
  T 'MUST NOT FIRE  dollar form is read, and keeps its cent rounding bound' `
    ($null -ne $d -and $d.form -eq 'dollar' -and [math]::Abs($d.value - 0.93) -lt 1e-12 -and [math]::Abs($d.halfUlp - 0.005) -lt 1e-12) `
    ($(if ($d) { $d.form + ' ' + $d.value + ' +/-' + $d.halfUlp } else { '$null' }))

  $c = Get-SamsUnitPriceShape ('92.8 ' + $CentSign + '/lb')
  T 'MUST FIRE  the 2026-09-20 cents form is read as DOLLARS (92.8c -> $0.928)' `
    ($null -ne $c -and $c.form -eq 'cents' -and [math]::Abs($c.value - 0.928) -lt 1e-12) `
    ($(if ($c) { $c.form + ' ' + $c.value } else { '$null' }))
  T 'MUST FIRE  ...and carries a TENTH-of-a-cent bound, not a cent one' `
    ($null -ne $c -and [math]::Abs($c.halfUlp - 0.0005) -lt 1e-12) `
    ($(if ($c) { $c.halfUlp } else { '$null' }))
  T 'the unit survives the conversion' ($null -ne $c -and $c.unit -eq 'lb') ($(if ($c) { $c.unit } else { '$null' }))

  # The cp1252-mangled spelling walmart-row-lib.ps1's header records the sink producing.
  $m = Get-SamsUnitPriceShape ('24.8 ' + [string][char]0x00C2 + $CentSign + '/oz')
  T 'a cp1252-mangled cent glyph still reads' `
    ($null -ne $m -and [math]::Abs($m.value - 0.248) -lt 1e-12) ($(if ($m) { $m.value } else { '$null' }))

  # A whole-cent cents form is rounded to the CENT, so its bound must widen back to 0.005.
  $w = Get-SamsUnitPriceShape ('86 ' + $CentSign + '/ea')
  T 'a cents value with NO decimals gets the cent bound back, not the tenth' `
    ($null -ne $w -and [math]::Abs($w.value - 0.86) -lt 1e-12 -and [math]::Abs($w.halfUlp - 0.005) -lt 1e-12) `
    ($(if ($w) { $w.value.ToString() + ' +/-' + $w.halfUlp } else { '$null' }))

  # THE REASON THIS IS NOT walmart-row-lib's LOOSE GLYPH MATCH. Refusing is the safe answer.
  T 'MUST NOT FIRE  a three-letter currency token is REFUSED, never divided by 100' `
    ($null -eq (Get-SamsUnitPriceShape '0.20 USD/oz')) ((Get-SamsUnitPriceShape '0.20 USD/oz') | Out-String)
  T 'MUST NOT FIRE  a bare number with no unit is refused' ($null -eq (Get-SamsUnitPriceShape '0.93')) 'parsed'
  T 'MUST NOT FIRE  an empty string is refused without throwing' ($null -eq (Get-SamsUnitPriceShape '')) 'parsed'

  # ---- the report over a fixture directory ----
  $cap = Join-Path $scratch 'captures'
  New-Item -ItemType Directory -Path $cap -ErrorAction Stop | Out-Null
  $body = @(
    '#tc-store store="Omaha Sam''s Club" read="page" rows=4',
    'q|n|lp|up|id|was|ful',
    ('onion|Sweet Onions, 6 lbs.|$5.57|92.8 ' + $CentSign + '/lb|586190K8GLVK||PERISHABLE@'),
    'tomato|Tomatoes on the Vine, 3 lbs.|$4.97|$1.66/lb|4WQ0DM58Y18Y||PERISHABLE@',
    'chile|505 Roasted Green Chile 40oz.|$8.22||6XEE3FJUBRET||PERISHABLE@',
    'odd|Something Strange|$1.00|0.20 USD/oz|ZZZ||NONE'
  ) -join "`n"
  [IO.File]::WriteAllText((Join-Path $cap 'sams-capture-2026-09-20.csv'), $body + "`n", (New-Object Text.UTF8Encoding($false)))

  $out = @(Invoke-SamsShapeReport $cap)
  $txt = ($out -join "`n")
  T 'the report counts both notations over a real file' `
    ($txt -match 'cents\s+1 decimal place' -and $txt -match 'dollar\s+2 decimal place') $txt
  T 'the report NAMES an unparsed shape rather than silently dropping it' `
    ($txt -match 'UNPARSED' -and $txt -match 'USD') $txt
  T 'it owes a -COMPLETE marker as its last line, with its denominator' `
    ($out[-1] -match '^SAMS-UNIT-PRICE-SHAPES-COMPLETE scanned=4 findings=1 blind=0$') $out[-1]

  # A COULD-NOT-LOOK IS NEVER AN ANSWER. An empty directory must say BLIND and exit 3, never report zero.
  $empty = Join-Path $scratch 'empty'
  New-Item -ItemType Directory -Path $empty -ErrorAction Stop | Out-Null
  $outE = @(Invoke-SamsShapeReport $empty)
  T 'MUST FIRE  a directory with no captures reports BLIND, never a clean zero' `
    (($outE -join "`n") -match 'BLIND' -and ($outE -join "`n") -match 'blind=1') ($outE -join ' / ')

  T 'the literal case list ran every case above this one' ($ran -eq 13) ("ran=" + $ran)
}
finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($fail -eq 0) { Write-Output ("probe-sams-unit-price-shapes self-test: PASS (" + $ran + " cases)"); exit 0 }
Write-Output ("probe-sams-unit-price-shapes SELF-TEST FAIL (" + $fail + " of " + $ran + " cases)")
exit 1
