<#
  audit-capture-encoding.ps1 - can EVERY reader agree on what this capture file says?

  WHY THIS EXISTS (2026-09-05). Windows PowerShell 5.1's Get-Content decodes a file with NO byte-order
  mark using the system ANSI codepage (cp1252 on this box), not UTF-8. A BOM-less UTF-8 capture read that
  way has every non-ASCII byte silently reinterpreted, and the misdecoded string is then written back, so
  the damage is baked into the BYTES and each round trip adds one generation. That is how the live
  Campbell's row reached 117 characters for a 36-character name. See lib\json-io.ps1, which proves the
  decoding bug still exists before claiming to fix it.

  THE HAZARD IS A PAIR: a writer that emits BOM-less UTF-8 (Python's json.dump, .NET WriteAllText with
  UTF8Encoding($false)) and a reader that omits an encoding. lib\json-io.ps1 fixed the READER side estate-
  wide, and audit-json-readers.ps1 ratchets it to zero. This guard closes the other half - not by demanding
  the reader be ours, but by requiring the FILE to say what it is.

  WHY THE INVARIANT IS "BOM **OR** PURE ASCII", AND NOT "BOM".
  A guard that simply demanded a byte-order mark would be wrong here, and it would fight a policy this
  estate already depends on. audit-json-encoding.ps1 pins commodities.json, categories.json and
  category-excludes.json to PURE ASCII WITH NO BOM - deliberately, because pure ASCII decodes identically
  under UTF-8 and cp1252, so those files are unambiguous WITHOUT a mark. apply-category-excludes maintains
  that pin. Two guards pulling in opposite directions on the same property is how one of them gets switched
  off. So the real property is neither "has a BOM" nor "has no BOM" - it is:

      EVERY READER, WHATEVER ITS DEFAULT, DECODES THIS FILE TO THE SAME STRING.

  which holds in exactly two ways: the file carries a byte-order mark (UTF-8 or UTF-16 - the decoder is
  told), or the file is pure ASCII (there is nothing for a decoder to disagree about). A file that is
  BOM-less AND carries a byte above 0x7F is the one shape where two honest readers get two different
  answers, and that is all this guard reports.

  MEASURED ON THIS TREE THE DAY IT WAS WRITTEN: 359 capture files, 45 with no BOM, and 6 of those 45
  carrying non-ASCII - so 6 files were genuinely ambiguous and 39 were already safe by the ASCII route.
  All 45 were normalised to a BOM in the same commit, which is why a clean run today reports zero. The
  guard is what stops them coming back, and it names the FILE, which names the WRITER.

  WHAT IS NOT IN SCOPE, STATED RATHER THAN HIDDEN. Only the engine's capture read set - out\regular,
  out\sams, out\bakers, out\fareway - the four directories the 359-file measurement covered and the ones
  compare-deals actually prices from. out\throttled holds pull diagnostics and out\captures is a single
  legacy file; neither reaches a board cell, and widening the scope to every .json under out\ would bury
  the signal in artifacts this guard has no opinion about.

  TWO LIVE WRITERS STILL EMIT BOM-LESS FILES: the bakers-deals and fareway-deals families (the newest
  bakers-deals is from the 09-02 cycle). Neither pull-bakers.ps1 nor pull-fareway-ads.ps1 writes them -
  they come from a vision-read step nobody has pinned down. This guard is deliberately the answer to that
  rather than a code search: the moment one appears it names the file, and a dated filename identifies its
  writer faster than grepping the estate for who might have produced it.

  Usage:
    .\audit-capture-encoding.ps1              check the capture read set
    .\audit-capture-encoding.ps1 -Fix         rewrite every ambiguous file with a UTF-8 BOM (content-identical)
    .\audit-capture-encoding.ps1 -SelfTest    frozen must-fire + clean twins
  Exit 0 = every capture is unambiguous. 2 = at least one is not. 3 = BLIND (no capture files to judge).
#>
param([string]$Root = '', [switch]$Fix, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\guard-contract.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-TextFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Root) { $Root = Join-Path $here 'out' }

# The engine's capture read set. Named here, once, so widening the scope is a deliberate edit rather than
# a glob quietly growing.
$script:CAPTURE_LANES = @('regular', 'sams', 'bakers', 'fareway')

# ONE implementation, driven by the self-test with frozen bytes and by the live path with real files.
function Test-BytesUnambiguous {
  <# $true when every reader decodes these bytes the same way: a byte-order mark says which encoding it is,
     and pure ASCII means there is nothing to disagree about. A BOM-less file carrying a byte above 0x7F is
     the ONLY shape two honest readers can read differently, and it is the whole finding. #>
  param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
  if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { return $true }  # UTF-8 BOM
  if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return $true }                          # UTF-16 LE
  if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return $true }                          # UTF-16 BE
  foreach ($b in $Bytes) { if ($b -gt 0x7F) { return $false } }
  return $true
}

function Get-NonAsciiCount {
  param([Parameter(Mandatory=$true)][AllowEmptyCollection()][byte[]]$Bytes)
  $n = 0
  foreach ($b in $Bytes) { if ($b -gt 0x7F) { $n++ } }
  return $n
}

if ($SelfTest) {
  $fail = 0
  # The FROZEN founding string, as a codepoint rather than a literal, so re-encoding THIS FILE can never
  # quietly alter the fixture ([[guard-fixture-rule]]). It is the apostrophe out of the live Hy-Vee
  # Campbell's row that started all of this.
  $apos = [char]0x2019
  $nonAscii = '{"item":"Campbell' + $apos + 's Turkey Gravy"}'
  $asciiOnly = '{"item":"Plain ASCII Gravy"}'
  $noBomEnc  = New-Object Text.UTF8Encoding($false)
  $bomEnc    = New-Object Text.UTF8Encoding($true)

  # (1) MUST FIRE - the founding shape. BOM-less AND non-ASCII: a PS 5.1 bare read and a UTF-8 read
  #     disagree about this file, and only one of them is right.
  $b = $noBomEnc.GetBytes($nonAscii)
  if (-not (Test-BytesUnambiguous -Bytes $b)) { Write-Output '  PASS  MUST FIRE: a BOM-less file carrying non-ASCII is reported - two honest readers decode it differently' }
  else { Write-Output '  FAIL  the founding shape went unreported - a BOM-less UTF-8 capture can mangle silently again'; $fail++ }

  # (2) CLEAN TWIN - BOM-less and PURE ASCII. This is the shape audit-json-encoding.ps1 deliberately PINS
  #     commodities.json to. If this ever fires, the two guards are fighting and one of them will be
  #     switched off. It must stay silent.
  $b = $noBomEnc.GetBytes($asciiOnly)
  if (Test-BytesUnambiguous -Bytes $b) { Write-Output '  PASS  CLEAN TWIN: BOM-less PURE ASCII is silent - this guard does not fight the commodities.json ASCII pin' }
  else { Write-Output '  FAIL  a BOM-less pure-ASCII file was reported - this guard now contradicts audit-json-encoding'; $fail++ }

  # (3) CLEAN TWIN - a BOM plus non-ASCII, which is what a normalised capture looks like. The fix must
  #     read as clean or the guard can never go green.
  #     GetPreamble() IS REQUIRED HERE. UTF8Encoding($true).GetBytes() encodes the STRING and does not
  #     prepend the mark - the $true only tells WriteAllText to emit a preamble. Building this fixture
  #     with GetBytes alone produced a BOM-less byte array, and the case failed against correct code.
  $b = $bomEnc.GetPreamble() + $bomEnc.GetBytes($nonAscii)
  if (Test-BytesUnambiguous -Bytes $b) { Write-Output '  PASS  CLEAN TWIN: a BOM-carrying file with non-ASCII is silent - the normalised shape passes' }
  else { Write-Output '  FAIL  a correctly BOM-marked capture was reported'; $fail++ }

  # (4) CLEAN TWIN - UTF-16, which also declares itself. Not what this estate writes, but a mark is a mark,
  #     and reporting it would be reporting a file no reader can misread.
  $b = [Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes($nonAscii)
  if (Test-BytesUnambiguous -Bytes $b) { Write-Output '  PASS  CLEAN TWIN: a UTF-16 BOM also declares the encoding, so it is not a finding' }
  else { Write-Output '  FAIL  a UTF-16 BOM was treated as ambiguous'; $fail++ }

  # (5) an empty file is not ambiguous. It may be a different problem - fail-open-reads-as-empty is its own
  #     class with its own guards - but it is not THIS one, and claiming it here would be noise.
  if (Test-BytesUnambiguous -Bytes ([byte[]]@())) { Write-Output '  PASS  an empty file is not an ENCODING finding (it is a different class, with its own guards)' }
  else { Write-Output '  FAIL  an empty file was reported as an encoding ambiguity'; $fail++ }

  # (6) THE COUNTER, so a finding can say how much is at stake rather than just "non-ASCII".
  if ((Get-NonAsciiCount -Bytes ($noBomEnc.GetBytes($nonAscii))) -eq 3 -and (Get-NonAsciiCount -Bytes ($noBomEnc.GetBytes($asciiOnly))) -eq 0) {
    Write-Output '  PASS  the non-ASCII byte count is real (U+2019 is 3 UTF-8 bytes; pure ASCII is 0)'
  } else { Write-Output '  FAIL  the non-ASCII counter is wrong'; $fail++ }

  # (7) END TO END, on real files on disk, because everything above judges byte arrays and the live path
  #     judges files. A fixture directory with one of each shape must report exactly the one.
  $t = Join-Path $env:TEMP ('cap-enc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force (Join-Path $t 'regular') | Out-Null
  [IO.File]::WriteAllText((Join-Path $t 'regular\bad-regular-2026-01-01.json'),  $nonAscii,  $noBomEnc)
  [IO.File]::WriteAllText((Join-Path $t 'regular\ok1-regular-2026-01-01.json'),  $asciiOnly, $noBomEnc)
  [IO.File]::WriteAllText((Join-Path $t 'regular\ok2-regular-2026-01-01.json'),  $nonAscii,  $bomEnc)
  $out = & powershell -NoProfile -File $PSCommandPath -Root $t
  $rc = $LASTEXITCODE
  $named = (($out -join ' ') -match 'bad-regular-2026-01-01\.json')
  $quiet = -not (($out -join ' ') -match 'ok1-regular|ok2-regular')
  if ($rc -eq 2 -and $named -and $quiet) { Write-Output '  PASS  END TO END: over a real directory it reports the one ambiguous file BY NAME and stays silent on both clean twins' }
  else { Write-Output ("  FAIL  end-to-end run was wrong (rc=$rc named=$named quiet=$quiet): " + ($out -join ' | ')); $fail++ }

  # (8) -Fix repairs that file and the SAME run then reads clean - and the content is byte-identical
  #     apart from the mark, because a normalisation that changes a product name is a data edit wearing
  #     a maintenance costume.
  $before = [IO.File]::ReadAllText((Join-Path $t 'regular\bad-regular-2026-01-01.json'))
  $null = & powershell -NoProfile -File $PSCommandPath -Root $t -Fix
  $after = [IO.File]::ReadAllText((Join-Path $t 'regular\bad-regular-2026-01-01.json'))
  $null = & powershell -NoProfile -File $PSCommandPath -Root $t
  $rc2 = $LASTEXITCODE
  if ($rc2 -eq 0 -and $before -eq $after) { Write-Output '  PASS  -Fix adds the mark, the next run is clean, and the decoded content is UNCHANGED' }
  else { Write-Output "  FAIL  -Fix did not repair cleanly (rc=$rc2 contentUnchanged=$($before -eq $after))"; $fail++ }

  # (9) BLIND, not clean. A run that judged nothing must say so: an empty scope is the shape in which a
  #     renamed lane reads as a perfect score forever.
  $t2 = Join-Path $env:TEMP ('cap-enc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force $t2 | Out-Null
  $null = & powershell -NoProfile -File $PSCommandPath -Root $t2
  if ($LASTEXITCODE -eq 3) { Write-Output '  PASS  BLIND: judging zero files exits 3, not 0 - an empty scope never reads as clean' }
  else { Write-Output "  FAIL  an empty capture set exited $LASTEXITCODE instead of 3 (BLIND)"; $fail++ }

  Remove-Item $t  -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $t2 -Recurse -Force -ErrorAction SilentlyContinue
  if ($fail) { Write-Output "SELF-TEST FAILED ($fail)"; exit 2 }
  Write-Output 'SELF-TEST PASS - founding shape armed, four clean twins hold, end-to-end and -Fix verified, empty scope is BLIND'
  exit 0
}

# ---- live path -------------------------------------------------------------------------------------
$files = @()
foreach ($lane in $script:CAPTURE_LANES) {
  $d = Join-Path $Root $lane
  if (Test-Path $d) { $files += @(Get-ChildItem (Join-Path $d '*.json') -File -ErrorAction SilentlyContinue) }
}
if (-not $files.Count) {
  Write-Output ("BLIND: no capture .json under " + $Root + "\{" + ($script:CAPTURE_LANES -join ',') + "} - nothing was judged, which is not the same as nothing being wrong")
  Write-GuardComplete -Name 'capture-encoding' -Summary 'BLIND - no capture files in scope'
  exit 3
}

$findings = New-Object System.Collections.ArrayList
# FAIL CLOSED ON A FILE WE COULD NOT READ. A guard that counts is a guard whose count must be complete;
# a file skipped because it was locked lowers the finding count and reads as a cleaner tree than we have.
$unreadable = New-Object System.Collections.ArrayList
$fixed = 0
foreach ($f in $files) {
  $bytes = $null
  try { $bytes = [IO.File]::ReadAllBytes($f.FullName) } catch { [void]$unreadable.Add($f.Name + ' (' + $_.Exception.Message + ')'); continue }
  if (Test-BytesUnambiguous -Bytes $bytes) { continue }
  $n = Get-NonAsciiCount -Bytes $bytes
  if ($Fix) {
    # Decode as UTF-8 (which is what these files are - every one of the 45 found on 2026-09-05 decoded as
    # valid UTF-8) and rewrite WITH the mark. The decoded string is unchanged; only the preamble is added.
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    [IO.File]::WriteAllText($f.FullName, $text, (New-Object Text.UTF8Encoding($true)))
    $fixed++
    continue
  }
  [void]$findings.Add([pscustomobject]@{ file = $f.FullName; name = $f.Name; non_ascii_bytes = $n })
}

if ($unreadable.Count) {
  Write-Output ("BLIND: " + $unreadable.Count + " of " + $files.Count + " capture file(s) could not be read, so this count is a floor, not a measurement:")
  $unreadable | Select-Object -First 10 | ForEach-Object { Write-Output ('  ' + $_) }
  Write-GuardComplete -Name 'capture-encoding' -Summary ('BLIND on ' + $unreadable.Count + ' file(s)')
  exit 3
}

if ($Fix) {
  Write-Output ("audit-capture-encoding: $($files.Count) capture file(s); $fixed rewritten with a UTF-8 BOM (content unchanged)")
  Write-GuardComplete -Name 'capture-encoding' -Summary "$fixed file(s) normalised over $($files.Count)"
  exit 0
}

Write-Output ("audit-capture-encoding: $($files.Count) capture file(s) across " + ($script:CAPTURE_LANES -join ', ') + "; $($findings.Count) that no two readers need agree on")
foreach ($x in ($findings | Sort-Object name)) {
  Write-Output ("  AMBIGUOUS  {0}  - no byte-order mark and {1} non-ASCII byte(s), so PS 5.1's Get-Content decodes it as cp1252 and a UTF-8 reader does not" -f $x.name, $x.non_ascii_bytes)
}
if ($findings.Count) {
  Write-Output ("audit-capture-encoding: the file name identifies the WRITER - fix the producer, then run this with -Fix to normalise what is already on disk. See lib\json-io.ps1 for why the reader side alone is not enough.")
  Write-GuardComplete -Name 'capture-encoding' -Summary "$($findings.Count) ambiguous file(s) of $($files.Count)"
  exit 2
}
Write-GuardComplete -Name 'capture-encoding' -Summary "0 ambiguous of $($files.Count) capture file(s)"
exit 0
