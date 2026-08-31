<#
  audit-json-encoding.ps1 - the matching rules must stay in the encoding they were written in.

  WHY THIS EXISTS (2026-08-31). commodities.json carried 61,542 literal non-ASCII characters across
  32 lines, and not one of them was a character anybody typed. They were mojibake EIGHT TO TEN
  GENERATIONS deep: one rule read

      "jalape[n<7,466 characters of mojibake>]o\s+peppers,?\s+pickled"

  where the author had written  "jalape[n<n-tilde>]o\s+peppers,?\s+pickled" .

  THE DAMAGE WAS SILENT AND ONE-SIDED, which is why it survived so long. A corrupted character CLASS
  still contains its plain letter, so `jalape[n<junk>]os?` went on matching "jalapenos" exactly as
  before and every spot-check passed. What it could no longer match was the ACCENTED spelling - the
  one the class existed to catch. Measured with the live .NET engine over 80 probes: 16 flipped from
  no-match to match once repaired, and the capture corpus really does carry the accented spelling.
  So the estate quietly stopped matching "jalape<n-tilde>o", "cr<e-grave>me fra<i-circumflex>che",
  "crema salvadore<n-tilde>a" and "saz<o-acute>n" - every one of them a product it had a rule for.

  THE WRITER, NAMED. apply-coverage-batch.ps1 read commodities.json with `Get-Content -Raw` and NO
  -Encoding, which is cp1252 on this box, then wrote it back as UTF-8. That round trip re-encodes
  every non-ASCII character one generation deeper, EVERY RUN - which is exactly why the corruption
  was 8-10 layers deep rather than 1. Its sibling apply-category-excludes.ps1 had already been fixed
  to pass -Encoding UTF8 on the same file; this one never was. Fixed at all three of its reads.

  A MOJIBAKE TOLERANCE IN A RULE IS NOT ITSELF CORRUPTION - AND THIS PASS NEARLY DELETED ONE.
  pickled-jalapenos carries two rules whose class reads [n, n-tilde, and the TWO-CHAR mojibake of
  n-tilde]{1,2}, so it matches "jalapeno", "jalape<n-tilde>o" AND "Jalape(A-tilde)(plus-minus)o". The
  first cut of the repair collapsed them to the clean two-character class, on the strength of a scan
  that found ZERO mojibake in the capture corpus. That scan was WRONG - it covered out\captures\ and
  never looked in out\regular\, which holds 1,286 mojibake sequences, 59 of them in the SAME DAY'S
  Hy-Vee file. Store feeds ship mojibake; a rule that tolerates it is doing its job.
  test-auditors caught it, by name, with a fixture built for exactly this product. The lesson is not
  "be careful" - it is that this guard pins the FILE's encoding and must never be read as licence to
  strip a mojibake ALTERNATIVE out of a matching rule. The two are opposite things: corruption is
  mojibake in the pattern where a real character belongs; a tolerance is mojibake in a character CLASS
  beside the real character, deliberately, because the shelf data is dirty.

  WHY A PIN AND NOT A CLEVERNESS. The repaired file expresses every non-ASCII character as a JSON
  \uXXXX escape, which is the convention its own clean sibling rules already used (lines 46162-46164
  were never corrupted precisely because they were written that way). That makes the rule-bearing
  files pure ASCII, and "pure ASCII" is a check with no judgement in it: a single non-ASCII byte is
  either new corruption or a new convention, and both are worth stopping a push for. A guard that
  tried to tell good accents from bad ones would be the same guess that let this through.

  TIER B IS A RATCHET, NOT A PASS. Other grocery JSON carries mojibake this pass did NOT repair -
  product-urls.json most of all. Those are captured product names, not matching rules, and repairing
  them is a different job with a different owner. Recording a baseline is the honest middle: the
  known damage is named and counted, and it cannot GROW without going red. A silent tolerance would
  read as "these files are fine".

  Usage:
    .\audit-json-encoding.ps1            check
    .\audit-json-encoding.ps1 -SelfTest
#>
param([switch]$SelfTest, [string]$Root = '')

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here

# ---- THE RULE-BEARING FILES. Pure ASCII, because their non-ASCII is written as \uXXXX escapes. ----
$script:ASCII_PINNED = @(
  'commodities.json',      # the match rules themselves - the file this guard was written for
  'categories.json',
  'category-excludes.json'
)

# ---- KNOWN, UNREPAIRED mojibake, counted 2026-08-31. These may not grow. ----
# A count rather than a silence: each is captured product text, not a matching rule, and each has an
# owner other than this pass. Lower a number when you repair a file; never raise one to go green.
$script:MOJI_BASELINE = @{
  'product-urls.json' = 710   # captured product names/links; owner: the url-worklist re-resolve pass
  'known-wrong.json'  = 2     # two ruled cells carry an accented product name
}

# The universal mojibake fingerprint: a UTF-8 lead byte that got shown through cp1252 and then
# re-encoded, so it now sits in the text as a Latin-1 capital followed by another high character.
# Built from char codes, never as literals. This file must not carry the bytes it hunts - and a
# guard whose own source can be corrupted by the very ANSI round trip it exists to catch is not a
# guard. The ranges are U+00C2/C3/E2 (the UTF-8 lead bytes as cp1252 sees them) and U+0080-U+00FF.
$script:MOJI = [regex]('[' + [char]0x00C2 + [char]0x00C3 + [char]0x00E2 + '][' + [char]0x0080 + '-' + [char]0x00FF + ']')

function Get-EncodingFindings {
  <# Every finding over one directory of *.json. Returns objects; the caller decides what is fatal. #>
  param([string]$Dir, [string[]]$Pinned, [hashtable]$Baseline)
  $out = @()
  foreach ($f in @(Get-ChildItem (Join-Path $Dir '*.json') -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $start = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    $nonAscii = 0
    for ($i = $start; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -gt 127) { $nonAscii++ } }

    if ($Pinned -contains $f.Name) {
      if ($nonAscii -gt 0) {
        $out += [pscustomobject]@{ kind = 'PINNED'; file = $f.Name; count = $nonAscii; allowed = 0 }
      }
      continue
    }

    $text = [Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)
    $moji = $script:MOJI.Matches($text).Count
    $allow = 0
    if ($Baseline.ContainsKey($f.Name)) { $allow = [int]$Baseline[$f.Name] }
    if ($moji -gt $allow) {
      $out += [pscustomobject]@{ kind = 'MOJIBAKE'; file = $f.Name; count = $moji; allowed = $allow }
    }
  }
  return @($out)
}

# ---------------------------------------------------------------------------------------------------
if ($SelfTest) {
  $bad = 0
  function T([string]$n, [bool]$ok, [string]$got) {
    if ($ok) { Write-Output ('  ok    ' + $n) } else { Write-Output ('  X     ' + $n + '   got: ' + $got); $script:bad++ }
  }
  $t = Join-Path ([IO.Path]::GetTempPath()) ('jsonenc-' + [guid]::NewGuid().ToString('N'))
  [void](New-Item -ItemType Directory -Force $t)
  try {
    $U8 = New-Object System.Text.UTF8Encoding($false)
    # NEEDLES BUILT BY CONCATENATION, never written as a literal this file could match against
    # itself. The estate has already shipped three self-test assertions that passed by finding
    # their own source text; see the note in lib\ghost-drift-lib.ps1.
    $enye   = [char]0x00F1
    $moji2  = [string][char]0x00C3 + [string][char]0x00B1     # the same n-tilde, one generation deep
    $clean  = '{"id":"x","include":["jalape[n\u00f1]os?"]}'   # the \u escape, literally - ASCII on disk

    [IO.File]::WriteAllText((Join-Path $t 'commodities.json'), $clean, $U8)
    [IO.File]::WriteAllText((Join-Path $t 'categories.json'), '{"a":1}', $U8)
    [IO.File]::WriteAllText((Join-Path $t 'category-excludes.json'), '{"a":1}', $U8)
    [IO.File]::WriteAllText((Join-Path $t 'other.json'), '{"a":1}', $U8)

    $pin = @('commodities.json', 'categories.json', 'category-excludes.json')
    $base = @{}

    $r = @(Get-EncodingFindings -Dir $t -Pinned $pin -Baseline $base)
    T 'a clean tree is clean' ($r.Count -eq 0) (($r | ForEach-Object { $_.file }) -join ',')

    # a LITERAL accent in a pinned file is the corruption signature, even though it is valid UTF-8
    [IO.File]::WriteAllText((Join-Path $t 'commodities.json'), ('{"include":["jalape[n' + $enye + ']os?"]}'), $U8)
    $r = @(Get-EncodingFindings -Dir $t -Pinned $pin -Baseline $base)
    T 'MUST FIRE  a literal non-ASCII char in a pinned rule file is a finding' `
      ($r.Count -eq 1 -and $r[0].kind -eq 'PINNED' -and $r[0].file -eq 'commodities.json') (($r | ForEach-Object { $_.kind + ':' + $_.file }) -join ',')
    T '...and it counts the BYTES, so a 2-byte char is not read as 1' ($r[0].count -eq 2) ([string]$r[0].count)

    # the real defect: mojibake, many generations deep
    [IO.File]::WriteAllText((Join-Path $t 'commodities.json'), ('{"include":["jalape[n' + $moji2 + ']os?"]}'), $U8)
    $r = @(Get-EncodingFindings -Dir $t -Pinned $pin -Baseline $base)
    T 'MUST FIRE  mojibake in a pinned rule file is a finding' `
      ($r.Count -eq 1 -and $r[0].kind -eq 'PINNED') (($r | ForEach-Object { $_.kind }) -join ',')

    # a BOM must not be counted as content
    [IO.File]::WriteAllText((Join-Path $t 'commodities.json'), $clean, (New-Object System.Text.UTF8Encoding($true)))
    $r = @(Get-EncodingFindings -Dir $t -Pinned $pin -Baseline $base)
    T 'a UTF-8 BOM is not mistaken for corrupt content' ($r.Count -eq 0) (($r | ForEach-Object { $_.file }) -join ',')

    # tier B: unpinned files ratchet against a baseline
    [IO.File]::WriteAllText((Join-Path $t 'other.json'), ('{"n":"' + $moji2 + '"}'), $U8)
    $r = @(Get-EncodingFindings -Dir $t -Pinned $pin -Baseline $base)
    T 'MUST FIRE  new mojibake in an unpinned file with no baseline is a finding' `
      ($r.Count -eq 1 -and $r[0].kind -eq 'MOJIBAKE' -and $r[0].file -eq 'other.json') (($r | ForEach-Object { $_.kind + ':' + $_.file }) -join ',')
    $r = @(Get-EncodingFindings -Dir $t -Pinned $pin -Baseline @{ 'other.json' = 1 })
    T 'a baselined file AT its baseline is silent' ($r.Count -eq 0) (($r | ForEach-Object { $_.file }) -join ',')
    [IO.File]::WriteAllText((Join-Path $t 'other.json'), ('{"n":"' + $moji2 + $moji2 + '"}'), $U8)
    $r = @(Get-EncodingFindings -Dir $t -Pinned $pin -Baseline @{ 'other.json' = 1 })
    T 'MUST FIRE  a baselined file that GROWS is a finding' `
      ($r.Count -eq 1 -and $r[0].count -eq 2 -and $r[0].allowed -eq 1) (($r | ForEach-Object { $_.count.ToString() + '/' + $_.allowed }) -join ',')

    # a legitimate accent in an UNPINNED file is not mojibake and must not fire
    [IO.File]::WriteAllText((Join-Path $t 'other.json'), ('{"n":"caf' + [char]0x00E9 + '"}'), $U8)
    $r = @(Get-EncodingFindings -Dir $t -Pinned $pin -Baseline $base)
    T 'MUST NOT FIRE  a real accented character in an unpinned file is not corruption' ($r.Count -eq 0) (($r | ForEach-Object { $_.file }) -join ',')
  }
  finally { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }

  if ($bad -eq 0) { Write-Output 'audit-json-encoding SELF-TEST PASS'; exit 0 }
  Write-Output ("audit-json-encoding SELF-TEST FAIL: {0} case(s)" -f $bad); exit 1
}

# ---------------------------------------------------------------------------------------------------
$dir = if ($Root) { $Root } else { $here }
$findings = @(Get-EncodingFindings -Dir $dir -Pinned $script:ASCII_PINNED -Baseline $script:MOJI_BASELINE)

foreach ($f in $findings) {
  if ($f.kind -eq 'PINNED') {
    Write-Output ("ENCODING: {0} carries {1} literal non-ASCII byte(s) and must carry none - its non-ASCII belongs in \uXXXX escapes. Either a writer read it as ANSI and wrote it back as UTF-8 (see apply-coverage-batch.ps1, fixed 2026-08-31), or a rule was hand-edited with a literal accent." -f $f.file, $f.count)
  } else {
    Write-Output ("ENCODING: {0} holds {1} mojibake sequence(s), baseline {2} - the known damage has GROWN. Something re-encoded this file; find it before repairing the data." -f $f.file, $f.count, $f.allowed)
  }
}

if ($findings.Count) {
  Write-Output ("JSON-ENCODING-COMPLETE findings={0}" -f $findings.Count)
  exit 1
}
Write-Output ("json-encoding: {0} rule file(s) pure ASCII, no mojibake growth in {1} baselined file(s)" -f $script:ASCII_PINNED.Count, $script:MOJI_BASELINE.Count)
Write-Output 'JSON-ENCODING-COMPLETE findings=0'
exit 0
