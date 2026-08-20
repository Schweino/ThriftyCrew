<#
  capture-lib.ps1 - shared ingest helpers for every browser-capture builder.

  *** WHY THIS FILE EXISTS (two reasons, both learned the hard way on 2026-07-29) ***

  1. ENCODING. A browser Blob download is UTF-8. PowerShell 5.1's Get-Content / Import-Csv default to the
     system ANSI codepage, so "Member<right-quote>s Mark" was decoded as Windows-1252 into "Member" + three
     junk characters, and then faithfully SAVED that way. The corruption is baked into the bytes on disk, so
     re-reading correctly does not undo it - it has to be repaired. 16 board rows shipped mangled names, 6 of
     them CROWNS, which is the first thing a shopper reads: "Member(junk)s Mark Wildflower Pure Premium Honey".
     Only browser-captured stores were hit (Sam's, Fareway, Walmart); every headless store was clean, and Aldi
     escaped only because its names come from URL slugs, which are ASCII by construction.

  2. FORKED BUILDERS. build-walmart-deals.ps1 is a copy of build-sams-deals.ps1 that has since diverged by
     ~124 lines, and BOTH still throw "build-sams-deals: ..." on error, so a failure lies to you about which
     script you are in. The same day, Walmart's cent-denominated unit prices ("24.9 c/oz") were being rejected
     by a dollars-only regex - a store-specific assumption inherited from the store it was copied from, which
     cost 900 priced rows and read as "the pull came back thin". A fix applied to one fork does not reach the
     other. Anything genuinely shared belongs HERE, once.

  *** THIS FILE IS DELIBERATELY PURE ASCII ***
  It is the mojibake repair; it must survive being read under the wrong codepage itself. The test script for
  this logic was written with literal accented characters and PowerShell mangled ITS source and tried to
  execute the fragments. Every non-ASCII character below is built from [char] codes for that reason.

  Usage:  . (Join-Path $PSScriptRoot 'capture-lib.ps1')
          $rows = Import-CaptureCsv -Path <capture.csv> -Delimiter '|'      # UTF-8 + names repaired
          $name = Repair-Mojibake $rawName
          if (Test-PlaceholderProductName $name) { continue }             # vendor TEST listing, not a product
          .\capture-lib.ps1 -CaptureLibSelfTest

  NOTE the switch is NOT called -SelfTest. Dot-sourcing runs a script's param() block in the CALLER's scope,
  so a `param([switch]$SelfTest)` here silently reset every builder's own $SelfTest to $false the moment they
  dot-sourced this - and `build-walmart-deals.ps1 -SelfTest` fell straight past its test block into "-In not
  found". A shared library must not name a parameter anything its callers might already be using.
#>
param([switch]$CaptureLibSelfTest)

# The signatures of UTF-8-read-as-Windows-1252. Built from char codes so this file stays ASCII.
#   0x00C3 = A-tilde   (lead byte of a 2-byte UTF-8 sequence read as 1252)
#   0x00C2 = A-circumflex (lead byte for U+00A0..U+00BF, e.g. (R) and (C))
#   0x00E2 = a-circumflex (lead byte of a 3-byte sequence, e.g. curly quotes, (TM))
$script:MOJI_SIGNATURE = '[' + [char]0x00C3 + [char]0x00C2 + [char]0x00E2 + ']'

function Repair-Mojibake([string]$s) {
  <#
    Undo one round of "UTF-8 bytes decoded as Windows-1252".
    SAFETY: returns the input unchanged unless it both carries a mojibake signature AND round-trips to a
    clean decode. Text that is already correct - including legitimately accented names like "Cafe" with an
    e-acute - must never be touched, because a repair that damages good data is worse than the mojibake.
  #>
  if ([string]::IsNullOrEmpty($s)) { return $s }
  # PEEL UNTIL STABLE. Text can be mangled more than once - a name that went through the bad read twice needs
  # two decodes, and a single pass left 8 of 29 link names still broken (29 -> 8 -> 0 over two runs). Each
  # iteration must independently pass the signature + clean-decode test, so this can only ever remove real
  # mojibake layers; the moment a pass would not help, it stops and returns what it has.
  $cur = $s
  for ($i = 0; $i -lt 4; $i++) {
    if ($cur -notmatch $script:MOJI_SIGNATURE) { break }
    try {
      $bytes = [Text.Encoding]::GetEncoding(1252).GetBytes($cur)
      $dec = New-Object Text.UTF8Encoding($false, $true)   # throwOnInvalidBytes: a bad guess FAILS loudly
      $fixed = $dec.GetString($bytes)
      if ($fixed.IndexOf([char]0xFFFD) -ge 0) { break }    # replacement char -> not really mojibake
      if ($fixed -eq $cur) { break }
      $cur = $fixed
    } catch {
      break                                                # not decodable as UTF-8 -> it was never mojibake
    }
  }
  return $cur
}

# --- PLACEHOLDER / TEST NAMES -------------------------------------------------------------------------
# A store's own catalog sometimes carries a VENDOR TEST LISTING as a real, purchasable, correctly priced row.
# 2026-08-20: "Test Id 1 Homekist Fudge Grahams" (Walmart item 105676485, $2.26, real product page, real CDN
# image) came off a live Omaha "graham crackers" search on 2026-08-11 sitting at result 26, one row below the
# genuine "Homekist Fudge Covered Graham Crackers, 13 oz" at the same price. It passed the marketplace-seller
# quarantine and the engine's unit-price reproduction check, because NOTHING ABOUT THE PRICE WAS WRONG. It
# reached the graph's confirm-match review as a live candidate against graham-crackers at confidence 1.0, and
# was stopped only by a human reading the name. That is not a control; it is luck. This is the control.
#
# The patterns are NOT defined here. They live in placeholder-name-patterns.json so this lane and the graph
# lane (graph/lib/placeholder_names.py) reject exactly the same names, and so the regression set of REAL
# product names they must never reject travels with them. Read that file before adding a pattern.
$script:PLACEHOLDER_PATTERNS = $null
function Get-PlaceholderPatterns {
  if ($null -eq $script:PLACEHOLDER_PATTERNS) {
    $libPath = Join-Path $PSScriptRoot 'placeholder-name-patterns.json'
    # Hard failure, not a silent empty list. A guard that quietly stops guarding is worse than no guard: the
    # rows it should have dropped go straight back to being someone's job to notice in review.
    if (-not (Test-Path $libPath)) { throw "capture-lib: placeholder-name library missing: $libPath" }
    $script:PLACEHOLDER_PATTERNS = @((Get-Content $libPath -Raw -Encoding UTF8 | ConvertFrom-Json).patterns)
  }
  return $script:PLACEHOLDER_PATTERNS
}

function Test-PlaceholderProductName([string]$name) {
  <#
    $true if the name reads as vendor test/placeholder data rather than a product. An EMPTY name is $false:
    callers have their own handling for nameless rows and must keep it, rather than have those quietly
    recounted as placeholders and disappear into this counter.
  #>
  if ([string]::IsNullOrWhiteSpace($name)) { return $false }
  foreach ($p in (Get-PlaceholderPatterns)) { if ($name -match $p) { return $true } }
  return $false
}

function Import-CaptureCsv {
  <#
    Read a browser-capture CSV the way it was actually written (UTF-8) and repair any text that was already
    corrupted by an earlier ANSI read. Use this instead of Import-Csv in every builder.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Delimiter = '|',
    [string[]]$RepairColumns = @('n', 'name', 'item')
  )
  if (-not (Test-Path $Path)) { throw "Import-CaptureCsv: no such capture: $Path" }
  $rows = @(Import-Csv -Path $Path -Delimiter $Delimiter -Encoding UTF8)
  $repaired = 0
  foreach ($r in $rows) {
    foreach ($c in $RepairColumns) {
      if ($r.PSObject.Properties[$c]) {
        $before = [string]$r.$c
        $after = Repair-Mojibake $before
        if ($after -ne $before) { $r.$c = $after; $repaired++ }
      }
    }
  }
  # Drop vendor TEST listings at the moment the capture is read, so no builder downstream can turn one into a
  # priced row. This runs AFTER the mojibake repair on purpose: a name has to be readable before it can be
  # judged. Every builder that reads captures through this function inherits the guard for free.
  $kept = New-Object System.Collections.ArrayList
  $placeholders = 0
  foreach ($r in $rows) {
    $nm = ''
    foreach ($c in $RepairColumns) { if ($r.PSObject.Properties[$c] -and -not $nm) { $nm = [string]$r.$c } }
    if (Test-PlaceholderProductName $nm) { $placeholders++; continue }
    [void]$kept.Add($r)
  }

  # NEVER Write-Output here. A function that returns data must emit NOTHING else: the progress line landed in
  # the returned array as an extra "row" and the very next pipeline died on
  # `Select-Object -ExpandProperty q`. The count goes in a script-scope variable for the caller to report.
  $script:CaptureRepairCount = $repaired
  $script:CapturePlaceholderCount = $placeholders
  return @($kept.ToArray())
}

if ($CaptureLibSelfTest) {
  $fail = 0
  function _Corrupt([string]$clean) {
    # reproduce the bug exactly: UTF-8 bytes handed to a 1252 decoder
    return [Text.Encoding]::GetEncoding(1252).GetString([Text.Encoding]::UTF8.GetBytes($clean))
  }
  $RQ = [char]0x2019   # right single quote
  $RG = [char]0x00AE   # registered
  $TM = [char]0x2122   # trademark
  $EA = [char]0x00E9   # e-acute

  $corruptible = @(
    ('Member' + $RQ + 's Mark Wildflower Pure Premium Honey, 48 oz.'),
    ('Glad' + $RG + ' ForceFlex Tall Kitchen Drawstring Trash Bags'),
    ('Gorton' + $RQ + 's Super Crunchy Fish Sticks, Frozen, 64 ct.'),
    ('Saran' + $TM + ' Premium Wrap Plastic Film')
  )
  foreach ($c in $corruptible) {
    $got = Repair-Mojibake (_Corrupt $c)
    if ($got -eq $c) { Write-Output ('ok    round-trips: ' + $c) } else { Write-Output ('FAIL  got [' + $got + '] want [' + $c + ']'); $fail++ }
    # idempotent: repairing an already-good string must be a no-op
    if ((Repair-Mojibake $got) -ne $got) { Write-Output 'FAIL  not idempotent'; $fail++ }
  }

  # clean text - including a legitimately accented name - must come back byte-identical
  $untouched = @(
    "Member's Mark Bacon 3 lbs.",
    'Great Value Whole Natural Almonds',
    'Kroger 80% Lean Ground Beef',
    ('Caf' + $EA + ' Bustelo Espresso Ground Coffee'),
    ('Glad' + $RG + ' ForceFlex')            # already correct (R) must NOT be re-decoded
  )
  foreach ($u in $untouched) {
    $got = Repair-Mojibake $u
    if ($got -eq $u) { Write-Output ('ok    left alone: ' + $u) } else { Write-Output ('FAIL  damaged clean text [' + $u + '] -> [' + $got + ']'); $fail++ }
  }
  if ([string]::IsNullOrEmpty((Repair-Mojibake ''))) { Write-Output 'ok    empty input is safe' } else { Write-Output 'FAIL  empty'; $fail++ }

  # PLACEHOLDER GUARD - driven by the SAME must_match / must_not_match sets the Python lane asserts against, so
  # the two lanes cannot silently drift apart. must_not_match is the part that matters: it is real product
  # names lifted from live captures (vitaminwater XXX, Melinda's XXXX Reserve habanero, America's Test Kitchen)
  # that a lazier pattern would have thrown away.
  $plib = Get-Content (Join-Path $PSScriptRoot 'placeholder-name-patterns.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($n in @($plib.must_match)) {
    if (Test-PlaceholderProductName $n) { Write-Output ('ok    rejected test row: ' + $n) }
    else { Write-Output ('FAIL  test row NOT rejected: ' + $n); $fail++ }
  }
  foreach ($n in @($plib.must_not_match)) {
    if (Test-PlaceholderProductName $n) { Write-Output ('FAIL  REAL product rejected: ' + $n); $fail++ }
    else { Write-Output ('ok    real product kept: ' + $n) }
  }
  if (Test-PlaceholderProductName '') { Write-Output 'FAIL  empty name treated as placeholder'; $fail++ }
  else { Write-Output 'ok    empty name is not a placeholder' }

  # DOUBLE mangling: a name that went through the bad read twice needs two decodes. This is not theoretical -
  # 8 of 29 link names survived the first pass and only cleared on a second run.
  $twice = _Corrupt (_Corrupt ('Member' + $RQ + 's Mark Taco Seasoning, 23 oz.'))
  $got = Repair-Mojibake $twice
  if ($got -eq ('Member' + $RQ + 's Mark Taco Seasoning, 23 oz.')) { Write-Output 'ok    double-mangled text peels all the way clean in one call' }
  else { Write-Output ('FAIL  double-mangle: got [' + $got + ']'); $fail++ }

  if ($fail) { Write-Output "$fail FAILED"; exit 1 } else { Write-Output 'capture-lib: all self-tests pass'; exit 0 }
}
