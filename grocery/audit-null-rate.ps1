<#
  audit-null-rate.ps1 - a field that stops being extracted while the rows keep arriving.

  WHY THIS EXISTS (2026-09-07, backlog I12). The four standing data-quality checks are freshness,
  volume, schema drift and NULL RATE. Three are implemented here several times over. The fourth was
  absent: a grep of the whole tree for null_rate|null rate|blank rate|missing rate|pct_null returned
  zero hits, verified twice.

  IT IS THE ONE SCRAPER FAILURE NOTHING ELSE SEES. A scraper rarely dies - that is loud, and freshness
  and volume both catch it. What it does is DEGRADE: a selector moves, a price node changes shape, a
  unit string stops parsing, and one field goes empty while every row still arrives on time and in the
  usual quantity. Freshness passes. Volume passes. Schema drift passes, because the KEY is still there
  - it is the VALUE that is now blank. The board then prices from rows whose size or price is missing,
  and the first sign is a wrong number on a page somebody paid to read.

  WHAT IT IS NOT, since the estate has three checks that look like this and are not:
    * audit-row-age's UNDATED arm asks whether a store's rows carry a date at all - field PRESENCE,
      hard pass/fail, not a rate, and not compared with yesterday.
    * audit-coverage-gaps and audit-cell-drops count missing BOARD CELLS - an output, not a field
      inside a source row.
    * audit-coverage-ledger counts `examined` per check - coverage of the checking, not completeness
      of the data.

  THE STORE COMES FROM THE FILE, NOT FROM A MAP HERE. audit-row-age.ps1 carries a store-to-glob table
  and duplicating it would be a second copy to drift - which this estate gates against in
  audit-twin-drift.ps1. Every engine file already names its own store, so this reads that.

  THE BASELINE IS A REFERENCE, NOT A HIGH-WATER MARK. Unlike the ratchets, a RISE is the finding here
  and a fall is simply better data, so lib\ratchet.ps1's asymmetry does not apply: this records what
  each field's null rate normally is and fires when one climbs away from it.

  EXIT CODES (lib\guard-contract.ps1 vocabulary): 0 clean, 2 hard finding, 3 could-not-evaluate.
  Read the verdict LINE, not the number (backlog E2).

  Self-test: powershell -File grocery\audit-null-rate.ps1 -SelfTest
#>
[CmdletBinding()]   # an undeclared argument must be a hard error, never a silent $args drop (2026-09-07)
param([switch]$SelfTest, [switch]$Update, [string]$OutDir = '')
$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
$repo = Split-Path $here -Parent
. (Join-Path $repo 'lib\guard-contract.ps1')

$BASELINE = Join-Path $here 'null-rate-baseline.json'

# A field has to be worth measuring before a rate about it means anything. A key that appears on three
# rows of five thousand is not a field going blank, it is a field that was always optional.
$MIN_ROWS = 200
$MIN_PRESENT_PCT = 50.0

# How far a rate may climb before it reads as a shape change rather than a normal day. Deliberately
# loose while there is no history: the founding case is a field going from populated to EMPTY, which
# is a jump of tens of points, not two. It tightens once the baseline has been observed a while.
$RISE_PCT = 25.0

function Get-NullRates([object[]]$Rows) {
  <# field -> @{ Present; Blank; Rate } over the rows given.

     BLANK IS NOT ABSENT AND BOTH COUNT. A selector that moves usually leaves the key in place with an
     empty string behind it, which is exactly the case a "does the key exist" check passes. #>
  $fields = @{}
  foreach ($r in $Rows) {
    foreach ($p in $r.PSObject.Properties) {
      $n = $p.Name
      if (-not $fields.ContainsKey($n)) { $fields[$n] = @{ Present = 0; Blank = 0 } }
      $fields[$n].Present++
      $v = $p.Value
      if ($null -eq $v -or ([string]$v).Trim() -eq '') { $fields[$n].Blank++ }
    }
  }
  $out = @{}
  $total = $Rows.Count
  foreach ($k in $fields.Keys) {
    $presentPct = 100.0 * $fields[$k].Present / [math]::Max(1, $total)
    if ($presentPct -lt $MIN_PRESENT_PCT) { continue }
    $out[$k] = [pscustomobject]@{
      Present = $fields[$k].Present
      Blank   = $fields[$k].Blank
      Rate    = [math]::Round(100.0 * $fields[$k].Blank / [math]::Max(1, $fields[$k].Present), 2)
    }
  }
  return $out
}

function Compare-NullRates($BaseRates, $NowRates, [double]$RisePct = 25.0) {
  <# The findings. Two shapes, and the second is the one a rate comparison alone would miss.

     1. A field's blank rate CLIMBED by more than RisePct - the selector moved and the value went away.
     2. A field the baseline knew is GONE from the rows entirely - a rate cannot rise if the field
        stopped being emitted, so comparing rates alone would report nothing at all. #>
  $findings = @()
  foreach ($f in ($BaseRates.PSObject.Properties.Name | Sort-Object)) {
    $was = [double]$BaseRates.$f
    if (-not $NowRates.ContainsKey($f)) {
      $findings += ("{0}: field VANISHED from the rows (was measured at {1}% blank). A rate cannot rise for a field nothing emits, so this is the case a rate comparison alone would miss entirely." -f $f, $was)
      continue
    }
    $now = [double]$NowRates[$f].Rate
    if (($now - $was) -gt $RisePct) {
      $findings += ("{0}: blank rate {1}% -> {2}%, a rise of {3} points. The rows still arrive; the VALUE stopped arriving." -f $f, $was, $now, [math]::Round($now - $was, 1))
    }
  }
  return $findings
}

if ($SelfTest) {
  $fail = 0
  function T($n, $c, $g = '') { if ($c) { Write-Output ("ok    " + $n) } else { Write-Output ("FAIL  " + $n + "   got: " + $g); $script:fail++ } }

  $rows = @()
  for ($i = 0; $i -lt 300; $i++) { $rows += [pscustomobject]@{ item = "p$i"; regular = '1.99'; size = '12 oz' } }
  $r = Get-NullRates $rows
  T 'a fully populated field reads 0% blank' ([double]$r['size'].Rate -eq 0.0) $r['size'].Rate

  # THE FOUNDING CASE. The key is still there, the value is gone - which is exactly what a
  # does-the-key-exist check passes and what freshness and volume never see.
  $broken = @()
  for ($i = 0; $i -lt 300; $i++) { $broken += [pscustomobject]@{ item = "p$i"; regular = '1.99'; size = '' } }
  $rb = Get-NullRates $broken
  T 'MUST FIRE  a field whose VALUE went empty reads 100% blank while the key is still present' ([double]$rb['size'].Rate -eq 100.0) $rb['size'].Rate

  $base = [pscustomobject]@{ item = 0.0; regular = 0.0; size = 0.0 }
  $f = Compare-NullRates $base $rb $RISE_PCT
  T 'MUST FIRE  that jump is a finding' ((@($f) -join ' ') -like '*size*stopped arriving*') ($f -join '; ')

  $f2 = Compare-NullRates $base (Get-NullRates $rows) $RISE_PCT
  T 'MUST NOT FIRE unchanged data is not a finding' (@($f2).Count -eq 0) ($f2 -join '; ')

  # A small wobble must NOT fire, or the guard cries daily and stops being read.
  $wobble = @()
  for ($i = 0; $i -lt 300; $i++) { $wobble += [pscustomobject]@{ item = "p$i"; regular = '1.99'; size = $(if ($i -lt 15) { '' } else { '12 oz' }) } }
  $f3 = Compare-NullRates $base (Get-NullRates $wobble) $RISE_PCT
  T 'MUST NOT FIRE a 5-point wobble is normal variation, not a shape change' (@($f3).Count -eq 0) ($f3 -join '; ')

  # THE CASE A RATE COMPARISON ALONE CANNOT SEE.
  $gone = @()
  for ($i = 0; $i -lt 300; $i++) { $gone += [pscustomobject]@{ item = "p$i"; regular = '1.99' } }
  $f4 = Compare-NullRates $base (Get-NullRates $gone) $RISE_PCT
  T 'MUST FIRE  a field that VANISHED is a finding, not a silent pass' ((@($f4) -join ' ') -like '*VANISHED*') ($f4 -join '; ')

  # An optional field must not be measured at all, or every sparse key is a permanent finding.
  $sparse = @()
  for ($i = 0; $i -lt 300; $i++) {
    if ($i -lt 5) { $sparse += [pscustomobject]@{ item = "p$i"; note = 'x' } } else { $sparse += [pscustomobject]@{ item = "p$i" } }
  }
  $rs = Get-NullRates $sparse
  T 'CLEAN TWIN a field on 2% of rows is optional and is not measured' (-not $rs.ContainsKey('note')) ($rs.Keys -join ',')

  if ($fail -gt 0) { Write-Output ("SELF-TEST FAIL: {0} case(s)" -f $fail); Write-GuardComplete -Name 'null-rate' -Summary ("selftest-fail={0}" -f $fail); exit 2 }
  Write-Output 'SELF-TEST PASS: the founding case where the key stays and the value goes, the vanished field a rate comparison cannot see, and the wobble that must not fire'
  Exit-Guard -Name 'null-rate' -Summary 'selftest=pass' -Code 0
}

$outRoot = if ($OutDir) { $OutDir } else { Join-Path $here 'out' }
if (-not (Test-Path $outRoot)) {
  Write-Output ("NULL-RATE COULD NOT EVALUATE: no output directory at {0}. Discovery broken, NOT a clean tree." -f $outRoot)
  Exit-Guard -Name 'null-rate' -Summary 'blind=no-outdir' -Code 3
}

# Newest file per store, taken from the files themselves rather than from a duplicated glob table.
$byStore = @{}
$globs = @('regular\*.json', 'ads-*.json', 'bakers\bakers-deals-*.json', 'fareway\fareway-deals-*.json')
foreach ($g in $globs) {
  $files = @(Get-ChildItem (Join-Path $outRoot $g) -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  foreach ($f in $files) {
    try { $doc = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    $rows = @($doc.deals)
    if ($rows.Count -lt $MIN_ROWS) { continue }
    $store = [string]$doc.store
    if (-not $store) { $store = $f.BaseName }
    $key = $store + ' | ' + (Split-Path $g -Leaf).Replace('*', '').Replace('.json', '')
    if ($byStore.ContainsKey($key)) { continue }     # newest wins
    $byStore[$key] = @{ File = $f.Name; Rows = $rows }
  }
}

if (-not $byStore.Count) {
  Write-Output ("NULL-RATE COULD NOT EVALUATE: no engine file under {0} carries at least {1} rows. That is discovery broken or an empty checkout, NOT a clean tree - and this estate's boards are gitignored, so a worktree lands here." -f $outRoot, $MIN_ROWS)
  Exit-Guard -Name 'null-rate' -Summary 'blind=no-rows' -Code 3
}

$now = @{}
foreach ($k in ($byStore.Keys | Sort-Object)) {
  $rates = Get-NullRates $byStore[$k].Rows
  $now[$k] = $rates
  Write-Output ("  {0}  ({1}, {2} rows)" -f $k, $byStore[$k].File, $byStore[$k].Rows.Count)
  foreach ($f in ($rates.Keys | Sort-Object)) {
    Write-Output ("      {0,-16} {1,6}% blank" -f $f, $rates[$f].Rate)
  }
}

if ($Update -or -not (Test-Path $BASELINE)) {
  $doc = [ordered]@{ generated = (Get-Date).ToString('s')
    note = 'Per store+source, each measured field''s BLANK rate. A RISE is the finding: the rows still arrive and the value stopped. Not a high-water ratchet - a fall here is simply better data.'
    rise_pct = $RISE_PCT
    stores = [ordered]@{} }
  foreach ($k in ($now.Keys | Sort-Object)) {
    $fields = [ordered]@{}
    foreach ($f in ($now[$k].Keys | Sort-Object)) { $fields[$f] = $now[$k][$f].Rate }
    $doc.stores[$k] = $fields
  }
  ($doc | ConvertTo-Json -Depth 6) | Set-Content $BASELINE -Encoding UTF8
  Write-Output ("null-rate: baseline written for {0} store/source pair(s). From here a field's blank rate rising more than {1} points, or a field vanishing, is a finding." -f $now.Count, $RISE_PCT)
  Exit-Guard -Name 'null-rate' -Summary ("baseline=$($now.Count)") -Code 0
}

$base = Get-Content $BASELINE -Raw -Encoding UTF8 | ConvertFrom-Json
$findings = @()
foreach ($k in ($now.Keys | Sort-Object)) {
  if (-not $base.stores.PSObject.Properties[$k]) { continue }
  foreach ($msg in (Compare-NullRates $base.stores.$k $now[$k] $RISE_PCT)) {
    $findings += ("{0}  {1}" -f $k, $msg)
  }
}

foreach ($f in $findings) { Write-Output ("  " + $f) }
if ($findings.Count -gt 0) {
  Write-Output ("NULL-RATE AUDIT FAILED: {0} field(s) across {1} store/source pair(s) stopped carrying values while their rows kept arriving. Freshness and volume both pass on this shape, and the board prices from what is left." -f $findings.Count, $now.Count)
  Exit-Guard -Name 'null-rate' -Summary ("pairs={0} findings={1}" -f $now.Count, $findings.Count) -Code 2
}
Write-Output ("null-rate: PASSED - {0} store/source pair(s) checked, no field's blank rate climbed more than {1} points and none vanished." -f $now.Count, $RISE_PCT)
Exit-Guard -Name 'null-rate' -Summary ("pairs={0} findings=0" -f $now.Count) -Code 0
