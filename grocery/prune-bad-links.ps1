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

  DEFAULT TOLERANCE IS 0.32, NOT 2%. Every automated call site (check-ad-cycles x2, weekly-post-capture)
  passes -Tol 0.32, and audit-tile-integrity tells a HUMAN to "run prune-bad-links.ps1" with no arguments -
  so the bare default is the one a person actually gets. At the old 0.02 default that instruction deleted
  every RIGHT-product link whose stored price snapshot had merely drifted a few cents: measured 2026-07-30,
  53 links at 0.02 versus 10 at 0.32, i.e. 43 correct links destroyed by following the printed advice.
  A link is removed for being a different PRODUCT (any drift by a factor), never for a stale snapshot -
  the same rule guard 4 uses (>=1.5x / <=0.67x). One tolerance, everywhere.
#>
param([double]$Tol = 0.32, [switch]$WhatIf)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
$root = $PSScriptRoot

# Per-unit math is shared with build-deals-page (the code that actually publishes the number) via
# pu-lib.ps1. This file used to carry its own weaker copy, which returned 0 - "skip this cell" - for
# sizes the published math handles fine ("per lb", a bare "lb", "24 fl oz" on an oz commodity, "dozen",
# a "$0.07/oz" unit price in the size field), silently excluding 8.6% of linked cells from the check.
. (Join-Path $root 'pu-lib.ps1')

$puFile = Join-Path $root 'product-urls.json'
Copy-Item $puFile (Join-Path $root 'out\product-urls.backup-preprune.json') -Force
$doc = Read-JsonFile $puFile
$cmp = Read-JsonFile ((Get-ChildItem (Join-Path $root 'out\comparison-*.json') | Sort-Object Name -Desc | Select-Object -First 1).FullName)

# A LINK THAT SHIPS MUST BE POSITIVELY VERIFIED - "not proven wrong" is not "proven right".
# name-drift is the product-identity check: it compares the board's item to the link's product and flags a
# different brand/form/variant. Load it so the two exemptions below can be narrowed to what they are actually
# for.
$drift = @{}
$ndF = Join-Path $root 'out\name-drift.json'
if (Test-Path $ndF) { foreach ($d in (Read-JsonFile $ndF).flags) { $drift[([string]$d.id + '|' + [string]$d.store)] = [string]$d.reason } }

$dropped = 0; $kept = 0; $sale = 0; $uncomputable = 0; $saleWrong = 0; $unverifiable = 0; $noPrice = 0
foreach ($row in $cmp.comparison) {
  $id = [string]$row.id
  $link = $doc.items.$id
  if (-not $link) { continue }
  foreach ($s in $row.stores) {
    $store = [string]$s.store
    $e = $link.$store
    if (-not $e -or -not $e.url) { continue }        # nothing linked here to judge

    # A LINK WITH NO PRICE CANNOT BE VERIFIED, SO IT CANNOT SHIP.
    # This condition used to read `-not $e.price`, which is TRUE when the price is 0 - so the 16 records that
    # store a size but price=0 (the Walmart/Aldi/Sam's spice tiles) were skipped by the very filter meant to
    # judge them. The links we know LEAST about were the ones waved through. Unknown is not a pass, and the
    # tempting fix - copying the board's price into the link record - makes the check vacuous: the board would
    # be agreeing with itself. A link's price has to come from the store or it proves nothing.
    $pv = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]', ''), [ref]$pv)
    if ($pv -le 0) {
      if (-not $WhatIf) { $link.PSObject.Properties.Remove($store) }
      $dropped++; $noPrice++
      continue
    }

    # PRODUCT IDENTITY IS CHECKED ON EVERY CELL, SALE OR NOT.
    # The old rule skipped sale cells entirely, which is right for the PRICE (a weekly-ad price legitimately
    # differs from the shelf price on the product page) and wrong for the PRODUCT. It let storage-bags ship as
    # the CHEAPEST chip advertising Ziploc 105ct at $0.04/each while its link opened That's Smart 12ct at
    # $0.099 - 138% off, and nothing to do with the ad. Same shape as the soda 12x bug: an exemption hides
    # whatever is behind it, not just what it was written for.
    if ($drift.ContainsKey($id + '|' + $store)) {
      if (-not $WhatIf) { $link.PSObject.Properties.Remove($store) }
      $dropped++
      if (([string]$s.type) -ne 'everyday') { $saleWrong++ }
      continue
    }
    if (([string]$s.type) -ne 'everyday') { $sale++; continue }   # price may differ; product is now checked above
    $sp = 0.0; [void][double]::TryParse((([string]$e.price) -replace '[^0-9.]',''), [ref]$sp)
    $lpu = Get-LinkPerUnit -size ([string]$e.size) -unit ([string]$row.unit) -price $sp -name ([string]$e.name)
    if ($null -eq $lpu) {
      # WE CANNOT COMPUTE THIS LINK'S PER-UNIT, SO WE CANNOT PROVE IT SHOWS OUR PRICE. This used to `continue`,
      # i.e. ship it - the audits' oldest sin, treating "cannot judge" as "fine". Unknown is not a pass. Drop it
      # and the tile falls back to a price with no link, which is honest.
      if (-not $WhatIf) { $link.PSObject.Properties.Remove($store) }
      $uncomputable++; $unverifiable++
      continue
    }
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
Write-Output ("links VERIFIED against the board price : $kept")
Write-Output ("links DROPPED (wrong product/price)    : $dropped   (of which $saleWrong were SALE cells the old rule skipped entirely)")
Write-Output ("links DROPPED (per-unit unverifiable)  : $unverifiable   (cannot prove the link shows our price - unknown is not a pass)")
Write-Output ("links DROPPED (link carries no price)  : $noPrice   (nothing from the store to check against)")
Write-Output ("sale cells kept (price may differ, product verified) : $sale")
Write-Output ''
Write-Output 'Every surviving link has been positively verified: it opens the product the board names, at the'
Write-Output 'price the board shows (or, on a sale cell, the same product at its shelf price). A tile that lost'
Write-Output 'its link now shows a price with no link - incomplete, but honest.'
if ($WhatIf) { Write-Output 'WhatIf - nothing written' }
