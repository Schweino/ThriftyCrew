<#
  apply-bid-decisions.ps1 - applies db\bid-decisions-2026-07-26.json to make every recipe price the
  CORRECT product (Brad: 100% accuracy, even if it raises cost). For each decision:
    - rewrites bid + gpu on EVERY spec's scaler.ing entry for that item (brace-scoped text edit inside
      the scaler.ing array only - never a whole-spec re-serialize, so prose \uXXXX escapes are untouched);
    - if update_db, rewrites the item's db\ingredients.json row (bid/gpu/unit) so EVERYDAY cost moves too.
  Rice is per-recipe (jasmine vs plain by prose); glass noodles get the rice-noodles fix + a db row.

  -WhatIf reports the spec/db line counts without writing. Parse-verifies every file it touches.
#>
param([switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$specDir = Join-Path $mp 'db\recipes'
. (Join-Path $mp 'lib\json-db-io.ps1')

$dec = Get-Content (Join-Path $mp 'db\bid-decisions-2026-07-26.json') -Raw | ConvertFrom-Json
$byItem = @{}
foreach ($d in $dec.decisions) { $byItem[[string]$d.item] = $d }

# --- scaler.ing bid/gpu rewrite, scoped to the scaler.ing array of one spec's raw text ---
function Set-ScalerBid([string]$raw, [string]$item, [string]$bid, [double]$gpu) {
  # locate the scaler.ing array: "scaler" ... "ing":[ ... ]
  $sIdx = $raw.IndexOf('"scaler"'); if ($sIdx -lt 0) { return @{ raw=$raw; n=0 } }
  $ingKey = $raw.IndexOf('"ing"', $sIdx); if ($ingKey -lt 0) { return @{ raw=$raw; n=0 } }
  $open = $raw.IndexOf('[', $ingKey); if ($open -lt 0) { return @{ raw=$raw; n=0 } }
  $depth = 0; $close = -1
  for ($i=$open; $i -lt $raw.Length; $i++) { $c=$raw[$i]; if($c -eq '['){$depth++} elseif($c -eq ']'){ $depth--; if($depth -eq 0){ $close=$i; break } } }
  if ($close -lt 0) { return @{ raw=$raw; n=0 } }
  $arr = $raw.Substring($open, $close-$open+1)
  $esc = [regex]::Escape($item)
  # each scaler.ing entry is a flat {...} object; match the one whose "item" equals $item AND that carries a "bid"
  $objRx = [regex]('\{[^{}]*?"item"\s*:\s*"' + $esc + '"[^{}]*?\}')
  $script:__setN = 0
  $newArr = $objRx.Replace($arr, {
    param($m)
    $o = $m.Value
    if ($o -notmatch '"bid"') { return $o }   # e.g. a bid-less pantry line - leave it
    $o2 = [regex]::Replace($o, '"bid"\s*:\s*"[^"]*"', ('"bid":"' + $bid + '"'), 1)
    $o2 = [regex]::Replace($o2, '"gpu"\s*:\s*"?[0-9.]+"?', ('"gpu":' + $gpu), 1)
    if ($o2 -ne $o) { $script:__setN++ }
    return $o2
  })
  return @{ raw = ($raw.Substring(0,$open) + $newArr + $raw.Substring($close+1)); n = $script:__setN }
}

$specHits = 0; $fileHits = 0; $riceJ = 0; $riceP = 0
foreach ($sf in (Get-ChildItem (Join-Path $specDir '*.json'))) {
  $raw = [IO.File]::ReadAllText($sf.FullName)
  $orig = $raw; $fileChanged = 0
  # generic decisions
  foreach ($item in $byItem.Keys) {
    if ($raw.IndexOf('"' + $item + '"') -lt 0) { continue }
    $d = $byItem[$item]
    $r = Set-ScalerBid $raw $item ([string]$d.bid) ([double]$d.gpu)
    if ($r.n -gt 0) { $raw = $r.raw; $fileChanged += $r.n }
  }
  # Rice (per-recipe): jasmine if the recipe says so, else plain rice
  if ($raw.IndexOf('"Rice"') -ge 0) {
    $isJasmine = ($raw -match '(?i)jasmine')
    if ($isJasmine) { $r = Set-ScalerBid $raw 'Rice' 'jasmine-rice' 28.3495; if($r.n){$riceJ++} }
    else            { $r = Set-ScalerBid $raw 'Rice' 'rice' 453.592;        if($r.n){$riceP++} }
    if ($r.n -gt 0) { $raw = $r.raw; $fileChanged += $r.n }
  }
  # Korean glass noodles bug fix
  if ($raw.IndexOf('Korean glass noodles') -ge 0) {
    $r = Set-ScalerBid $raw 'Korean glass noodles (dangmyeon)' 'rice-noodles' 28.3495
    if ($r.n -gt 0) { $raw = $r.raw; $fileChanged += $r.n }
  }
  if ($fileChanged -gt 0) {
    $null = $raw | ConvertFrom-Json   # verify
    if (-not $WhatIf) { [IO.File]::WriteAllText($sf.FullName, $raw, (New-Object System.Text.UTF8Encoding($false))) }
    $specHits += $fileChanged; $fileHits++
  }
}
Write-Output ("specs: {0} scaler lines rewritten across {1} files (Rice: {2} jasmine, {3} plain)" -f $specHits, $fileHits, $riceJ, $riceP)

# --- db\ingredients.json: product-accuracy rows move too (everyday cost) ---
$dbF = Join-Path $mp 'db\ingredients.json'
$dbRows = New-Object System.Collections.Generic.List[object]
foreach ($row in (Get-Content $dbF -Raw | ConvertFrom-Json)) { $dbRows.Add($row) }
$dbChanged = 0
foreach ($row in $dbRows) {
  $it = [string]$row.item
  if ($byItem.ContainsKey($it) -and $byItem[$it].update_db) {
    $d = $byItem[$it]
    if ([string]$row.bid -ne [string]$d.bid -or [double]$row.gpu -ne [double]$d.gpu) {
      $row.bid = [string]$d.bid; $row.gpu = [double]$d.gpu; $row.unit = [string]$d.unit; $dbChanged++
    }
  }
}
# glass noodles: add a db row if absent (so everyday can price it)
$hasGlass = @($dbRows | Where-Object { [string]$_.item -eq 'Korean glass noodles (dangmyeon)' }).Count -gt 0
if (-not $hasGlass) { $dbRows.Add([pscustomobject]@{ item='Korean glass noodles (dangmyeon)'; bid='rice-noodles'; gpu=28.3495; unit='oz'; board='recipe' }); $dbChanged++ }
Write-Output ("db\ingredients.json: {0} rows updated" -f $dbChanged)
if (-not $WhatIf) { Save-JsonArray -Array $dbRows.ToArray() -Path $dbF -Depth 6 | Out-Null; $null = Get-Content $dbF -Raw | ConvertFrom-Json }
if ($WhatIf) { Write-Output 'WhatIf: nothing written' }
