<#
  prune-bad-links.ps1 - a "See item" link is only correct if it opens the product whose PRICE the
  board shows. Name similarity is not enough: it happily picked a 3 oz Badia garlic powder for a cell
  priced on the 10.5 oz jar, a 12-pack case of hominy, and a 4-pack of vinegar.

  It also matters because merge-product-urls.ps1 re-merges EVERY store-*-urls.json in out\url-inputs,
  including OLD ones, so a merge can resurrect stale links whose prices no longer match the board.

  Rule:
    - EVERYDAY cell: the link's per-unit must equal the board's per-unit, or the link is opening a
      different product than the price shown -> REMOVE it. An unlinked cell is honest; a cell whose
      price and link disagree is not.
    - SALE cell: skipped. A weekly-ad price legitimately differs from the shelf price on the product
      page, so a mismatch there is expected.

  Uses the SAME quantity math as audit-everyday-mismatch.ps1 (validated against the stores), including
  the rule that a pack count multiplies a WEIGHT only when it is in the SIZE field - "Applesauce Cups
  6 Count" with size "24 oz" is 24 oz TOTAL, not 6 x 24 - while for an 'each' commodity the pack count
  IS the quantity and may come from the name ("24 Pack" bottled water, size "each").
#>
param([double]$Tol = 0.02, [switch]$WhatIf)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Qty([string]$size, [string]$name, [string]$unit) {
  $s = ("" + $size).ToLower()
  $nm = ("" + $name).ToLower()
  $pkSize = 1
  $pmS = [regex]::Match($s, '(\d+)\s*(?:x|pk\b|pack\b|ct\b|count\b)')
  if ($pmS.Success) { $pkSize = [double]$pmS.Groups[1].Value }
  $pkAny = $pkSize
  if ($pkAny -le 1) {
    $pmN = [regex]::Match($nm, '(\d+)\s*(?:x|pk\b|pack\b|ct\b|count\b)')
    if ($pmN.Success) { $pkAny = [double]$pmN.Groups[1].Value }
  }
  $pk = $pkSize
  $m = [regex]::Matches($s, '([\d.]+)\s*(fl\s?oz|floz|oz|lbs?|pound|gal|qt|l|ml|g)\b')
  if ($m.Count -eq 0) {
    if ($unit -eq 'each') { return $pkAny }
    if ($unit -eq 'lb'   -and $s -match '^\s*lb\s*$')   { return 1 }
    if ($unit -eq 'gallon' -and $s -match '^\s*gal') { return 1 }
    return 0
  }
  $last = $m[$m.Count-1]
  $n = [double]$last.Groups[1].Value
  $u = $last.Groups[2].Value -replace '\s',''
  $base = 0.0
  switch ($unit) {
    'oz'     { if ($u -eq 'oz') { $base=$n } elseif ($u -match '^(lbs?|pound)$') { $base=$n*16 } elseif ($u -eq 'g') { $base=$n*0.035274 } }
    'floz'   { if ($u -match '^(floz|oz)$') { $base=$n } elseif ($u -eq 'l') { $base=$n*33.814 } elseif ($u -eq 'ml') { $base=$n*0.033814 } elseif ($u -eq 'gal') { $base=$n*128 } elseif ($u -eq 'qt') { $base=$n*32 } }
    'lb'     { if ($u -match '^(lbs?|pound)$') { $base=$n } elseif ($u -eq 'oz') { $base=$n/16 } }
    'gallon' { if ($u -eq 'gal') { $base=$n } elseif ($u -match '^(floz|oz)$') { $base=$n/128 } }
    'each'   { return $pkAny }
    'dozen'  { if ($u -match '^(ct|count)$') { $base=$n/12 } else { $base = 0 } }
    default  { $base = 0 }
  }
  if ($base -le 0) { return 0 }
  if ($pk -gt 1) { $base = $base * $pk }
  return $base
}

$puFile = Join-Path $root 'product-urls.json'
Copy-Item $puFile (Join-Path $root 'out\product-urls.backup-preprune.json') -Force
$doc = Get-Content $puFile -Raw | ConvertFrom-Json
$cmp = Get-Content (Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName -Raw | ConvertFrom-Json

$dropped = 0; $kept = 0; $sale = 0; $uncomputable = 0
foreach ($row in $cmp.comparison) {
  $id = [string]$row.id
  $link = $doc.items.$id
  if (-not $link) { continue }
  foreach ($s in $row.stores) {
    $store = [string]$s.store
    $e = $link.$store
    if (-not $e -or -not $e.price) { continue }
    if (([string]$s.type) -ne 'everyday') { $sale++; continue }
    $q = Qty ([string]$e.size) ([string]$e.name) ([string]$row.unit)
    if ($q -le 0) { $uncomputable++; continue }
    $lpu = [double]$e.price / $q
    $bpu = [double]$s.per_unit
    if ($bpu -le 0) { continue }
    if ([math]::Abs($lpu - $bpu) / $bpu -gt $Tol) {
      if (-not $WhatIf) { $link.PSObject.Properties.Remove($store) }
      $dropped++
    } else { $kept++ }
  }
}

if (-not $WhatIf) { ($doc | ConvertTo-Json -Depth 8) | Set-Content $puFile -Encoding UTF8 }
Write-Output ("links that MATCH the board price : $kept")
Write-Output ("links DROPPED (wrong product)    : $dropped")
Write-Output ("sale cells skipped (expected)    : $sale")
Write-Output ("uncomputable size (left alone)   : $uncomputable")
if ($WhatIf) { Write-Output 'WhatIf - nothing written' }
