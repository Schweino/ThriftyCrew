<#
  audit-pack-basis.ps1 - catches the MULTIPACK TOTAL read as an EACH-SIZE (2026-07-28).

  The engine's count-first idiom ("24 ct 16.9 fl oz") means 24 bottles OF 16.9 oz, so it multiplies to a
  405.6 oz total. That is right for water, vinegar and grits. It is WRONG when the store already printed the
  pack TOTAL after the count: Sam's "Pledge Furniture Polish, 3 ct., 29 oz." is three 9.7 oz cans totalling
  29 oz, and multiplying gave 87 oz -> $0.14/oz, which made Sam's the cheapest furniture polish in Omaha at
  a third of the real price. Text alone cannot tell the two apart, so this audit uses ARITHMETIC:

    when the multiplied reading makes a cell a large outlier under every other store, AND no other store
    sells anything near the each-size that reading implies, the multiply is what created the outlier.

  BOTH conditions are needed. The outlier test alone would flag genuine bulk: a 24 ct x 16.9 fl oz water
  case really is 65% under the single-bottle stores, and its pack-total reading really would look absurd.
  What separates it from Pledge is CORROBORATION of the each-size: peers sell 16.9 fl oz bottles, so
  reading 16.9 as the each-size is confirmed by the market; nobody sells a 29 oz can of furniture polish,
  while three stores sell the 9.7 oz can that 29/3 implies. That is exactly how a human resolves it, and it
  is the check that keeps this guard quiet on real bulk.

  Advisory by design (exit 0 with findings, 2 only on -Strict): it names cells for a human decision instead
  of silently dropping a price.

  Usage: audit-pack-basis.ps1 [-CompareFile <path>] [-Strict]
#>
param([string]$CompareFile = "", [switch]$Strict)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$OutDir = Join-Path $root 'out'
if (-not $CompareFile) {
  $CompareFile = (Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1).FullName
}
$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json

# how far under the next-cheapest store counts as "an outlier this audit should explain"
$OUTLIER = 0.35
# how close a peer's package size has to be to count as corroborating an each-size reading
$SIZE_TOL = 0.15
$findings = @()

function ToUnit([double]$num, [string]$token, [string]$unit) {
  $t = $token.ToLower().Trim().TrimEnd('.')
  switch ($unit) {
    'lb'     { if ($t -match '^(lb|lbs|pound|pounds)$') { return $num }; if ($t -match '^(oz|ounce|ounces)$') { return $num/16.0 }; return $null }
    'oz'     { if ($t -match '^(oz|ounce|ounces|fl\s*oz|floz)$') { return $num }; if ($t -match '^(lb|lbs|pound|pounds)$') { return $num*16.0 }; return $null }
    'floz'   { if ($t -match '^(fl\s*oz|floz|oz|ounce|ounces)$') { return $num }; if ($t -match '^(gal|gallon|gallons)$') { return $num*128.0 }
               if ($t -match '^(qt|quart|quarts)$') { return $num*32.0 }; if ($t -match '^(pt|pint|pints)$') { return $num*16.0 }; if ($t -match '^(ml)$') { return $num/29.5735 }; return $null }
    'gallon' { if ($t -match '^(gal|gallon|gallons)$') { return $num }; if ($t -match '^(fl\s*oz|floz|oz|ounce|ounces)$') { return $num/128.0 }; return $null }
  }
  return $null
}
# the package size a store row states, in the commodity's unit ($null when it does not state one)
function RowSize([string]$sizeText, [string]$unit) {
  if (-not $sizeText) { return $null }
  $s = $sizeText.ToLower()
  # for a count-first multipack the EACH size is the second number, which is what we want to compare
  $mm = [regex]::Match($s, '^\s*\d+(?:\.\d+)?\s*[- ]?\s*(?:ct|count|pk|packs?)\D+(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|ml|gal|gallon|qt|quart|pt|pint|lbs?|pound)\b')
  if ($mm.Success) { return (ToUnit ([double]$mm.Groups[1].Value) $mm.Groups[2].Value $unit) }
  $m = [regex]::Match($s, '(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|ounce|ounces|lb|lbs|pound|pounds|gal|gallon|qt|quart|pt|pint|ml)\b')
  if ($m.Success) { return (ToUnit ([double]$m.Groups[1].Value) $m.Groups[2].Value $unit) }
  return $null
}

foreach ($r in $doc.comparison) {
  $rows = @($r.stores | Where-Object { [double]$_.per_unit -gt 0 })
  if ($rows.Count -lt 2) { continue }
  $ranked = @($rows | Sort-Object { [double]$_.per_unit })
  foreach ($s in $ranked) {
    $size = [string]$s.size
    # the count-first idiom the engine multiplies on
    $m = [regex]::Match($size.ToLower(), '^\s*(\d+(?:\.\d+)?)\s*[- ]?\s*(?:ct|count|pk|packs?)\D+(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|ml|gal|gallon|qt|quart|pt|pint|lbs?|pound)\b')
    if (-not $m.Success) { continue }
    $cnt = [double]$m.Groups[1].Value
    if ($cnt -le 1) { continue }
    $published = [double]$s.per_unit
    # the alternative reading: the printed size was the pack TOTAL, so the price divides by it, not by count*it
    $asTotal = $published * $cnt
    # cheapest OTHER store on this commodity
    $others = @($ranked | Where-Object { $_.store -ne $s.store } | ForEach-Object { [double]$_.per_unit })
    if ($others.Count -eq 0) { continue }
    $peer = ($others | Sort-Object)[0]
    if ($peer -le 0) { continue }
    $underNow  = (($peer - $published) / $peer)
    $underThen = (($peer - $asTotal) / $peer)
    if (-not ($underNow -ge $OUTLIER -and $underThen -lt $OUTLIER)) { continue }
    # CORROBORATION. The published reading says each unit in this pack is $each big. If any other store
    # sells a package about that size, the market confirms the reading and this is real bulk, not a bug.
    $each = ToUnit ([double]$m.Groups[2].Value) $m.Groups[3].Value ([string]$r.unit)
    if ($each -ne $null -and $each -gt 0) {
      $peerSizes = @($ranked | Where-Object { $_.store -ne $s.store } | ForEach-Object { RowSize ([string]$_.size) ([string]$r.unit) } | Where-Object { $_ -ne $null -and $_ -gt 0 })
      $confirmed = @($peerSizes | Where-Object { [math]::Abs($_ - $each) / $each -le $SIZE_TOL })
      if ($confirmed.Count -gt 0) { continue }   # another store sells that each-size: the multiply is right
    }
    # published reading is a big outlier, the pack-total reading is not, and nothing on the market sells
    # the each-size the multiply assumes -> the multiply is what created the outlier
    if ($true) {
      $findings += [pscustomobject]@{
        id = [string]$r.id; commodity = [string]$r.commodity; store = [string]$s.store
        unit = [string]$r.unit; published = [math]::Round($published,4)
        as_pack_total = [math]::Round($asTotal,4); peer_cheapest = [math]::Round($peer,4)
        count = $cnt; size = $size; ad = [string]$s.ad; item = [string]$s.item
      }
    }
  }
}

$rep = Join-Path $OutDir 'pack-basis-audit.json'
([pscustomobject]@{ generated = (Get-Date -Format 'yyyy-MM-dd HH:mm'); compare_file = (Split-Path $CompareFile -Leaf); finding_count = $findings.Count; findings = $findings } |
  ConvertTo-Json -Depth 5) | Set-Content $rep -Encoding UTF8

if ($findings.Count -eq 0) { Write-Output 'pack-basis: ok - no multipack cell owes its cheapest-in-Omaha rank to the count multiply'; exit 0 }
Write-Output ("pack-basis: " + $findings.Count + " cell(s) are cheapest ONLY because a pack count was multiplied into the size - verify the size is per-item, not the pack total:")
foreach ($f in $findings) {
  Write-Output ("  {0,-24} {1,-12} published {2}/{3} vs {4} as a pack total (peer {5}) | size '{6}' | {7}" -f `
    $f.id, $f.store, $f.published, $f.unit, $f.as_pack_total, $f.peer_cheapest, $f.size, $f.item)
}
Write-Output ("  report: " + $rep)
if ($Strict) { exit 2 }
exit 0
