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

# Per-unit math is shared with build-deals-page (the code that actually publishes the number) via
# pu-lib.ps1. This file used to carry its own weaker copy, which returned 0 - "skip this cell" - for
# sizes the published math handles fine ("per lb", a bare "lb", "24 fl oz" on an oz commodity, "dozen",
# a "$0.07/oz" unit price in the size field), silently excluding 8.6% of linked cells from the check.
. (Join-Path $root 'pu-lib.ps1')

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
    $sp = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$sp)
    $lpu = Get-LinkPerUnit -size ([string]$e.size) -unit ([string]$row.unit) -price $sp -name ([string]$e.name)
    if ($null -eq $lpu) { $uncomputable++; continue }
    $bpu = [double]$s.per_unit
    if ($bpu -le 0) { continue }
    # HALF-CENT RULE (same as audit-everyday-mismatch). A link whose size field holds the store's own
    # cent-rounded unit price ("$0.06/oz" for a $1.00/15.5 oz can, truly $0.0645/oz) is not a bad link - it
    # is two decimal places. Never delete a good link over rounding.
    if (([math]::Abs($lpu - $bpu) / $bpu -gt $Tol) -and ([math]::Abs($lpu - $bpu) -gt 0.005)) {
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
