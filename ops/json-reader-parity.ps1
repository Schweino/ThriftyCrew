<#
  json-reader-parity.ps1 - read EVERY .json/.jsonl in the tree with BOTH readers and compare.

  WHY (2026-09-06, PLAN-top5-2026-09-06 area 5). On 2026-09-05 a regex sweep moved 608 JSON reads from
  `Get-Content -Raw | ConvertFrom-Json` to `Read-JsonFile` on the strength of THREE shapes having been
  measured equivalent. Four more had not been, and one of them - a single-element top-level array coming
  back as the ELEMENT - would have passed every gate in this estate while silently returning a different
  shape at 608 call sites. The gates check the CALL SITES. Nothing checked the FILES.

  This does. It is the one-off harness the plan asks for: run it once before a change to lib\json-io.ps1
  and once after, and read the difference rather than reasoning about it.

  THE EXPECTED ANSWER IS NOT ZERO, AND THAT IS THE POINT. Exactly the BOM-less non-ASCII UTF-8 files MUST
  differ - that difference IS the fix: the old reader decodes them with the ANSI codepage and manufactures
  mojibake. A run reporting 0 differences did not run. Measured on this tree 2026-09-05: 26,573 files -
  5,762 pure ASCII, 18,075 UTF-8 with a BOM, 2,736 BOM-less non-ASCII UTF-8, 0 invalid UTF-8, 0 UTF-16.
  So the shape of a good run is: the differing set EQUALS the BOM-less non-ASCII set, both directions.

  ANYTHING ELSE IS A FINDING: a file that differs for another reason, a U+FFFD on the NEW side (the reader
  substituting where it should refuse), a top-level TYPE change (the array-ness trap), or a throw on one
  side only.

    ops\json-reader-parity.ps1                 the whole tree
    ops\json-reader-parity.ps1 -Limit 500      a smoke run
    ops\json-reader-parity.ps1 -Deep           also compare ConvertTo-Json -Depth 20 -Compress of both
    ops\json-reader-parity.ps1 -OutFile <p>    write the full per-file record as JSON
  Exit 0 = the difference is exactly the expected set. 1 = findings. 3 = BLIND (no files found).
#>
param([int]$Limit = 0, [switch]$Deep, [string]$OutFile = '')
$ErrorActionPreference = 'Continue'
$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'lib\json-io.ps1')

$files = @(Get-ChildItem $repo -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -ieq '.json' -or $_.Extension -ieq '.jsonl' } |
  Where-Object { $_.FullName -notmatch '\\worktrees\\|node_modules|\.venv|\\\.git\\' } |
  Sort-Object FullName)
if ($Limit -gt 0) { $files = @($files | Select-Object -First $Limit) }
if (-not $files.Count) { Write-Output 'json-reader-parity: BLIND - found no .json/.jsonl files'; exit 3 }

$sw = [Diagnostics.Stopwatch]::StartNew()
$shapes = @{ ascii = 0; bom = 0; nobomNonAscii = 0; utf16 = 0; invalid = 0 }
$differ = New-Object System.Collections.ArrayList     # files whose two decodes disagree
$emptyNullDiff = 0
$libMoved = New-Object System.Collections.ArrayList   # files the 2026-09-06 lib change moved vs [IO.File]::ReadAllText
$findings = New-Object System.Collections.ArrayList
$records = New-Object System.Collections.ArrayList
$n = 0

foreach ($f in $files) {
  $n++
  $bytes = $null
  try { $bytes = [IO.File]::ReadAllBytes($f.FullName) } catch { [void]$findings.Add("UNREADABLE  $($f.FullName) - $($_.Exception.Message)"); continue }
  # ---- what SHAPE is this file, from its bytes. This is the ground truth the comparison is judged against.
  $hasBom  = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  $isUtf16 = ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF)))
  $off = if ($hasBom) { 3 } else { 0 }
  # ONE STRICT DECODE ANSWERS BOTH QUESTIONS. A per-byte PowerShell loop over a multi-megabyte capture is
  # the whole cost of this harness - the strict decoder already walks the bytes in .NET, and a regex over
  # the resulting string answers "non-ASCII?" far faster than the interpreter can index an array.
  $validUtf8 = $true
  $nonAscii = $false
  if ($isUtf16) { $nonAscii = $true }
  else {
    try {
      $probe = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes, $off, $bytes.Length - $off)
      $nonAscii = ($probe -match '[^\x00-\x7F]')
    } catch { $validUtf8 = $false }
  }
  if     ($isUtf16)      { $shapes.utf16++ }
  elseif (-not $validUtf8) { $shapes.invalid++ }
  elseif (-not $nonAscii)  { if ($hasBom) { $shapes.bom++ } else { $shapes.ascii++ } }
  elseif ($hasBom)       { $shapes.bom++ }
  else                   { $shapes.nobomNonAscii++ }
  # EXPECTED TO DIFFER: no BOM, non-ASCII, valid UTF-8. That is the population the fix exists for.
  $expectDiff = ((-not $hasBom) -and (-not $isUtf16) -and $nonAscii -and $validUtf8)

  # ---- the OLD reader, exactly as the sweep found it, and the NEW one -----------------------------------
  $oldText = $null; $oldErr = ''
  try { $oldText = Get-Content -LiteralPath $f.FullName -Raw } catch { $oldErr = $_.Exception.Message }   # json-readers:allow this IS the reader under comparison, performed on purpose
  $newText = $null; $newErr = ''
  try { $newText = Read-TextFile $f.FullName } catch { $newErr = $_.Exception.Message }
  # THE THIRD READER: [IO.File]::ReadAllText, which is what Read-TextFile WAS before 2026-09-06. This is
  # how "run it once before the lib change and once after" is answered in ONE run - the before-reader is
  # still callable. Any file where the pre-change and post-change readers disagree is a file the lib
  # change moved, and every one of those must be a file that ReadAllText was decoding WRONG.
  $preText = $null; $preErr = ''
  try { $preText = [IO.File]::ReadAllText($f.FullName) } catch { $preErr = $_.Exception.Message }
  if (-not $preErr -and -not $newErr) {
    $pN = if ($null -eq $preText) { '' } else { [string]$preText }
    $nN2 = if ($null -eq $newText) { '' } else { [string]$newText }
    if ($pN -ne $nN2) { [void]$libMoved.Add($f.FullName) }
  } elseif ($preErr -and -not $newErr) { [void]$libMoved.Add($f.FullName + '  (ReadAllText threw, the new reader did not)') }
  elseif ($newErr -and -not $preErr) { [void]$libMoved.Add($f.FullName + '  (the new reader threw, ReadAllText did not: ' + $newErr + ')') }

  if ($oldErr -and -not $newErr) { [void]$findings.Add("OLD THREW ONLY  $($f.FullName) - $oldErr") }
  if ($newErr -and -not $oldErr) { [void]$findings.Add("NEW THREW ONLY  $($f.FullName) - $newErr") }
  if ($oldErr -or $newErr) { continue }
  # A U+FFFD ON THE NEW SIDE, AND THE TWO REASONS IT CAN BE THERE. They are opposite findings and the
  # first version of this harness reported both as the same thing, which was wrong on all three hits.
  #   - the file is NOT valid UTF-8: the reader substituted where it must refuse. Structurally impossible
  #     since 2026-09-06 (it throws), which is exactly when to keep asserting it.
  #   - the file IS valid UTF-8 and its BYTES are EF BF BD: the replacement character is already baked in,
  #     from a cp1252 round trip that happened before anyone read this file today. No reader can undo that,
  #     and it is a DATA finding, not a reader finding. Measured 2026-09-06: three files, all of them a
  #     lost "n-tilde" in Jalapeno - grocery\out\audit\unmatched.json carries TWO replacement characters in
  #     one word ("Jalape<?><?>o"), i.e. two generations of the loss.
  if ($newText -and $newText.IndexOf([char]0xFFFD) -ge 0) {
    if ($validUtf8) { [void]$findings.Add("U+FFFD IN THE DATA  $($f.FullName) - the file's own bytes carry EF BF BD: a cp1252 round trip already destroyed a character here, and no reader can recover it") }
    else            { [void]$findings.Add("U+FFFD ON NEW SIDE  $($f.FullName) - the reader SUBSTITUTED instead of refusing invalid bytes") }
  }

  # NORMALISE $null AND '' EXPLICITLY, because they are not the same thing to `-eq` and the two readers
  # genuinely disagree on a ZERO-BYTE file: `Get-Content -Raw` returns $null, Read-TextFile returns ''.
  # Measured here on grocery\_batch19a.json, which is 0 bytes. Both then ConvertFrom-Json to $null, so it
  # is benign at the JSON level - but it is a real difference at the TEXT level and it is written down
  # rather than papered over. A caller that tests `if ($null -eq $text)` sees it.
  $oldN = if ($null -eq $oldText) { '' } else { [string]$oldText }
  $newN = if ($null -eq $newText) { '' } else { [string]$newText }
  $textSame = ($oldN -eq $newN)
  if ($bytes.Length -eq 0 -and $null -eq $oldText -and $null -ne $newText) { $emptyNullDiff++ }
  # ---- top-level TYPE, which is the array-ness trap (defect 6). .jsonl is not one JSON document, so it
  # is compared as TEXT only; parsing it would throw identically on both sides and prove nothing.
  # ONLY PARSE WHEN THE TEXT DIFFERS. ConvertFrom-Json is deterministic in its input, so identical text
  # cannot yield a different top-level type - and parsing 26,573 files twice is the difference between
  # minutes and an hour and a half (measured: 400 files took 72s with the unconditional parse).
  $typeSame = $true; $deepSame = $true
  if (($f.Extension -ieq '.json') -and ((-not $textSame) -or $Deep)) {
    $oT = ''; $nT = ''
    try { $o = $oldText | ConvertFrom-Json; $oT = if ($null -eq $o) { 'null' } else { $o.GetType().Name } } catch { $oT = 'THREW' }
    try { $nn = $newText | ConvertFrom-Json; $nT = if ($null -eq $nn) { 'null' } else { $nn.GetType().Name } } catch { $nT = 'THREW' }
    $typeSame = ($oT -eq $nT)
    if (-not $typeSame) { [void]$findings.Add("TYPE CHANGED  $($f.FullName) - old=$oT new=$nT (this is the single-element-array unroll class)") }
    if ($Deep -and $oT -ne 'THREW' -and $nT -ne 'THREW') {
      try {
        $os = ($oldText | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress)
        $ns = ($newText | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress)
        $deepSame = ($os -eq $ns)
      } catch { $deepSame = $textSame }
    }
  }

  if (-not $textSame) { [void]$differ.Add($f.FullName) }
  # THE TWO DIRECTIONS, BOTH REPORTED. "Everything that differs was expected to" is only half the claim;
  # "everything expected to differ did" is the half that catches a reader that quietly stopped fixing.
  if ((-not $textSame) -and (-not $expectDiff)) {
    [void]$findings.Add("UNEXPECTED DIFF  $($f.FullName) - bom=$hasBom utf16=$isUtf16 nonAscii=$nonAscii validUtf8=$validUtf8")
  }
  if ($textSame -and $expectDiff) {
    [void]$findings.Add("EXPECTED DIFF MISSING  $($f.FullName) - BOM-less non-ASCII UTF-8 read IDENTICALLY both ways, so the fix did not apply to it")
  }
  if ($Deep -and -not $deepSame -and -not $expectDiff) {
    [void]$findings.Add("DEEP DIFF  $($f.FullName) - the parsed documents serialise differently for a reason other than encoding")
  }
  if ($OutFile) {
    [void]$records.Add([ordered]@{
      path = $f.FullName.Replace($repo, '').TrimStart('\'); bom = $hasBom; utf16 = $isUtf16
      nonAscii = $nonAscii; validUtf8 = $validUtf8; expectDiff = $expectDiff; textSame = $textSame; typeSame = $typeSame
    })
  }
}
$sw.Stop()

Write-Output ("json-reader-parity: {0} file(s) in {1:N1}s" -f $n, $sw.Elapsed.TotalSeconds)
Write-Output ("  shapes: {0} pure ASCII, {1} UTF-8 with BOM, {2} BOM-less non-ASCII, {3} UTF-16, {4} invalid UTF-8" -f `
  $shapes.ascii, $shapes.bom, $shapes.nobomNonAscii, $shapes.utf16, $shapes.invalid)
Write-Output ("  {0} file(s) read DIFFERENTLY by the two readers; {1} were expected to" -f $differ.Count, $shapes.nobomNonAscii)
Write-Output ("  {0} file(s) decode differently under the NEW lib than under [IO.File]::ReadAllText (the pre-2026-09-06 reader)" -f $libMoved.Count)
foreach ($lm in ($libMoved | Select-Object -First 10)) { Write-Output ('    lib-moved: ' + $lm) }
if ($libMoved.Count -gt 10) { Write-Output ('    ...and ' + ($libMoved.Count - 10) + ' more') }
if ($emptyNullDiff) { Write-Output ("  note: {0} ZERO-BYTE file(s) - the old reader returns `$null there and the new one returns '' (both ConvertFrom-Json to `$null; benign, and recorded rather than hidden)" -f $emptyNullDiff) }

# THE POSITIVE CONTROL, NAMED. A harness that reports 0 differences on this tree did not run: the BOM-less
# non-ASCII files are known to exist and are known to be exactly what the fix is for.
if ($differ.Count -eq 0) {
  Write-Output '  ! A RUN WITH ZERO DIFFERENCES DID NOT RUN. This tree carries BOM-less non-ASCII files and the'
  Write-Output '    old reader manufactures mojibake from every one of them. Zero means the comparison is inert.'
  [void]$findings.Add('ZERO DIFFERENCES - the harness proved nothing')
}
if ($differ.Count) {
  Write-Output '  first few differing files (these are the fix working):'
  $differ | Select-Object -First 5 | ForEach-Object { Write-Output ('    ' + $_.Replace($repo, '').TrimStart('\')) }
}
foreach ($x in $findings) { Write-Output ('  ! ' + $x) }
if ($OutFile) {
  Write-JsonFile -Path $OutFile -Content ([ordered]@{
    written = (Get-Date).ToString('s'); files = $n; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    shapes = $shapes; differing = $differ.Count; findings = @($findings.ToArray()); records = @($records.ToArray())
  }) -Depth 8
  Write-Output ("  full record written to " + $OutFile)
}
if ($findings.Count) { exit 1 }
Write-Output '  parity holds: the two readers differ on exactly the BOM-less non-ASCII files and nowhere else.'
exit 0
