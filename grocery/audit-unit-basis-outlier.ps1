# audit-unit-basis-outlier.ps1 - catches a WRONG BASIS by arithmetic, when nothing in the row declares it.
#
# WHY THIS EXISTS (2026-07-31 Aldi finding, verified in-browser):
#   pull-aldi-instore.js reads each product's PRODUCT PAGE and takes its "size" field. For a multipack
#   that field is the PER-UNIT size, while the price it stores is the PACK price. PurAqua Purified Water
#   captured as size "16.9 fl oz" at $3.19, when the storefront tile says 24 x 16.9 fl oz for that price.
#
#   Guard 5 (multipack size) cannot see this. Guard 5 tests rows whose NAME states a pack count against
#   their size; here the name says "16.9 FL OZ", the size says "16.9 fl oz", and the count appears
#   NOWHERE on the captured surface. There is no declaration to contradict. The row is internally
#   consistent and completely wrong.
#
#   What IS left is arithmetic. A pack price divided by one unit's size produces a per-unit figure several
#   times every other store's for the same commodity. That is the same fingerprint as the mirror bug in
#   the board-basis notes (a per-lb rate printed in the size, a pack total as the each-size), so this
#   audit catches the whole family, not just Aldi's version of it.
#
# ADVISORY BY DESIGN, never a hard gate. Some products really are several times dearer per unit than
# their shelf-mates (organic vs conventional, a tiny jar vs a bulk tub). The job here is to put a short,
# ranked list in front of a human, not to block a publish on a heuristic.
#
#   .\audit-unit-basis-outlier.ps1                 audit the newest comparison
#   .\audit-unit-basis-outlier.ps1 -Ratio 4        change the flag threshold (default 4x the median)
#   .\audit-unit-basis-outlier.ps1 -SelfTest       frozen founding-bug fixture + clean twins
# Exit 0 = clean or advisory findings only. Exit 2 = self-test regression. Exit 3 = BLIND (nothing seen).
param([string]$CompareFile = '', [double]$Ratio = 4.0, [int]$MinStores = 4, [switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# THE DETECTOR, kept pure so the fixture can reach it without any data files (fix-needs-reachable-selftest).
# Returns one finding per store whose per-unit is >= $Ratio x the row's median per-unit.
# The median, not the minimum: comparing against the cheapest store would flag every ordinary premium
# brand on a row where one store runs a deep sale, which is noise, not basis error.
# Does a size string declare a pack? "24 x 16.9 fl oz", "12 pk 2.5 oz", "18 pack", "40 ct".
function Test-PackShape([string]$size) {
  if (-not $size) { return $false }
  return ($size -imatch '(^|\s)\d+\s*(x|pk|pack|ct|count)(\s|$|\d)')
}

function Find-BasisOutliers {
  param([object[]]$Rows, [double]$Ratio = 4.0, [int]$MinStores = 4)
  $out = @()
  foreach ($r in $Rows) {
    $priced = @($r.stores | Where-Object { [double]$_.per_unit -gt 0 })
    if (@($priced).Count -lt $MinStores) { continue }
    $vals = @($priced | ForEach-Object { [double]$_.per_unit } | Sort-Object)
    $mid  = $vals[[int]([math]::Floor($vals.Count / 2))]
    if ($mid -le 0) { continue }
    foreach ($s in $priced) {
      $pu = [double]$s.per_unit
      $mult = $pu / $mid
      if ($mult -lt $Ratio) { continue }
      # THE STRONGEST SIGNAL IS NOT THE ARITHMETIC, IT IS THE SIZE SHAPE.
      # A first draft of this audit tried to read the pack count out of the multiple, on the theory that a
      # pack price over one unit lands on a whole multiple of the real rate. It does not: stores genuinely
      # differ on price, so the founding case came out at 20.52x for a 24-pack. Reporting "pack of 21"
      # would have been invented precision of exactly the kind this board exists to avoid.
      # What IS checkable: on the founding row every other store recorded "24 x 16.9 fl oz" and Aldi
      # recorded "16.9 fl oz". An outlier whose size carries NO pack form while its shelf-mates do is the
      # pack-price-on-a-unit-size shape, stated from the data rather than inferred from a ratio.
      $peers = @($priced | Where-Object { [string]$_.store -ne [string]$s.store })
      $peersPacked = @($peers | Where-Object { Test-PackShape ([string]$_.size) }).Count
      $selfPacked = Test-PackShape ([string]$s.size)
      $shapeMismatch = ((-not $selfPacked) -and @($peers).Count -ge 2 -and ($peersPacked / [double]@($peers).Count) -ge 0.5)
      $out += [pscustomobject]@{
        id = [string]$r.id; commodity = [string]$r.commodity; unit = [string]$r.unit
        store = [string]$s.store; per_unit = $pu; median = $mid
        mult = [math]::Round($mult, 2)
        size = [string]$s.size; item = [string]$s.item
        peers_packed = ("{0} of {1}" -f $peersPacked, @($peers).Count)
        size_shape_mismatch = $shapeMismatch
      }
    }
  }
  return ,@($out)
}

if ($SelfTest) {
  # FROZEN FIXTURES. Hand-written, never regenerated from the live board (guard-fixture rule).
  # MUST-FIRE 1 is the founding case: PurAqua at Aldi, a 24-pack price on a one-bottle size.
  $mustFire = @(
    [pscustomobject]@{ id='bottled-water'; commodity='Bottled Water'; unit='floz'; stores=@(
      [pscustomobject]@{ store='Walmart';     per_unit=0.0079; size='24 x 16.9 fl oz'; item='Great Value Water' }
      [pscustomobject]@{ store='Hy-Vee';      per_unit=0.0089; size='24 x 16.9 fl oz'; item='Hy-Vee Water' }
      [pscustomobject]@{ store="Baker's";     per_unit=0.0092; size='24 x 16.9 fl oz'; item='Kroger Water' }
      [pscustomobject]@{ store='Family Fare'; per_unit=0.0095; size='24 x 16.9 fl oz'; item='OF Water' }
      # the bug: $3.19 pack price over ONE 16.9 fl oz bottle = 0.1888/fl oz, ~21x the median
      [pscustomobject]@{ store='Aldi';        per_unit=0.1888; size='16.9 fl oz';      item='Puraqua Purified Water 16.9 FL OZ' }
    )}
  )
  # MUST-FIRE 2 is the mirror: a 12-pack popcorn price on a single 2.5 oz bag.
  $mustFire += [pscustomobject]@{ id='microwave-popcorn'; commodity='Microwave Popcorn'; unit='oz'; stores=@(
      [pscustomobject]@{ store='Walmart';     per_unit=0.150; size='12 x 2.5 oz'; item='GV Popcorn' }
      [pscustomobject]@{ store='Hy-Vee';      per_unit=0.163; size='12 x 2.5 oz'; item='Hy-Vee Popcorn' }
      [pscustomobject]@{ store="Baker's";     per_unit=0.171; size='12 x 2.5 oz'; item='Kroger Popcorn' }
      [pscustomobject]@{ store='Family Fare'; per_unit=0.180; size='12 x 2.5 oz'; item='OF Popcorn' }
      [pscustomobject]@{ store='Aldi';        per_unit=1.796; size='2.5 oz';      item='Clancy S Movie Theater Butter Microwave Popcorn 2.5 OZ' }
    )}
  # CLEAN TWINS. These must stay silent or the audit is useless noise.
  $clean = @(
    # ordinary price spread across seven stores: dearest is under 2x the median
    [pscustomobject]@{ id='whole-milk'; commodity='Milk'; unit='gallon'; stores=@(
      [pscustomobject]@{ store='Aldi'; per_unit=2.29 }, [pscustomobject]@{ store='Walmart'; per_unit=2.48 }
      [pscustomobject]@{ store='Hy-Vee'; per_unit=2.99 }, [pscustomobject]@{ store="Baker's"; per_unit=3.19 }
      [pscustomobject]@{ store='Fareway'; per_unit=3.29 }, [pscustomobject]@{ store='Family Fare'; per_unit=3.49 }
    )}
    # a genuinely premium outlier that is still under the threshold: 3.1x must NOT fire at 4x
    [pscustomobject]@{ id='olive-oil'; commodity='Olive Oil'; unit='floz'; stores=@(
      [pscustomobject]@{ store='Aldi'; per_unit=0.21 }, [pscustomobject]@{ store='Walmart'; per_unit=0.24 }
      [pscustomobject]@{ store='Hy-Vee'; per_unit=0.27 }, [pscustomobject]@{ store="Baker's"; per_unit=0.31 }
      [pscustomobject]@{ store='Fareway'; per_unit=0.84 }
    )}
    # THIN ROW: a huge multiple on only three priced stores must NOT fire - the median is not yet meaningful
    [pscustomobject]@{ id='saffron'; commodity='Saffron'; unit='oz'; stores=@(
      [pscustomobject]@{ store='Aldi'; per_unit=1.00 }, [pscustomobject]@{ store='Hy-Vee'; per_unit=1.20 }
      [pscustomobject]@{ store='Walmart'; per_unit=40.0 }
    )}
  )
  $bad = 0
  $f1 = Find-BasisOutliers -Rows $mustFire -Ratio $Ratio -MinStores $MinStores
  foreach ($id in @('bottled-water','microwave-popcorn')) {
    $hit = @($f1 | Where-Object { $_.id -eq $id -and $_.store -eq 'Aldi' })
    if (@($hit).Count -ne 1) { Write-Output ("  X MUST-FIRE: $id did not flag Aldi (found " + @($hit).Count + ")"); $bad++ ; continue }
    # the SHAPE mismatch is the assertion that matters: every peer records a pack form, this row does not
    if (-not $hit[0].size_shape_mismatch) { Write-Output ("  X MUST-FIRE: $id flagged on arithmetic but missed the size-shape tell (peers_packed=" + $hit[0].peers_packed + ", size='" + $hit[0].size + "')"); $bad++ }
  }
  $f2 = Find-BasisOutliers -Rows $clean -Ratio $Ratio -MinStores $MinStores
  if (@($f2).Count -ne 0) {
    foreach ($c in $f2) { Write-Output ("  X CLEAN TWIN fired: " + $c.commodity + " / " + $c.store + " at " + $c.mult + "x") }
    $bad += @($f2).Count
  }
  if ($bad -eq 0) { Write-Output 'audit-unit-basis-outlier SELF-TEST PASS (2 must-fire, 3 clean twins)'; exit 0 }
  Write-Output ("audit-unit-basis-outlier SELF-TEST FAIL ($bad)"); exit 2
}

# ---- live run ----
$OutDir = Join-Path $root 'out'
if (-not $CompareFile) {
  $cmp = Get-ChildItem (Join-Path $OutDir 'comparison-*.json') | Where-Object { $_.BaseName -match '^comparison-\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending | Select-Object -First 1
  if (-not $cmp) { Write-Output 'BLIND: no comparison-*.json to audit'; exit 3 }
  $CompareFile = $cmp.FullName
}
$doc = Get-Content $CompareFile -Raw | ConvertFrom-Json
$rows = @($doc.comparison)
if (-not $rows.Count) { Write-Output 'BLIND: comparison file has no rows'; exit 3 }

$findings = Find-BasisOutliers -Rows $rows -Ratio $Ratio -MinStores $MinStores
$eligible = @($rows | Where-Object { @($_.stores | Where-Object { [double]$_.per_unit -gt 0 }).Count -ge $MinStores }).Count
if ($eligible -eq 0) { Write-Output ("BLIND: no row had $MinStores+ priced stores, so no median could be formed"); exit 3 }

# rank by how integer-clean the multiple is, then by size: a near-whole multiple is the strongest signal
# that the number is a pack count rather than a genuinely dearer product.
$ranked = @($findings | Sort-Object @{e={-not $_.size_shape_mismatch}}, @{e={-$_.mult}})
Write-Output ("audit-unit-basis-outlier: $($rows.Count) rows, $eligible with $MinStores+ priced stores, $(@($findings).Count) at or above $($Ratio)x the row median")
foreach ($f in ($ranked | Select-Object -First 25)) {
  $tag = if ($f.size_shape_mismatch) { 'PACK-SHAPE MISMATCH' } else { 'wide spread      ' }
  Write-Output ("  [{0}] {1,-24} {2,-12} {3}x median  {4} vs {5}  size='{6}' (peers packed {7})  {8}" -f $tag, $f.commodity, $f.store, $f.mult, ('{0:N4}' -f $f.per_unit), ('{0:N4}' -f $f.median), $f.size, $f.peers_packed, $f.item)
}
$nearInt = @($findings | Where-Object { $_.size_shape_mismatch })
if (@($ranked).Count -gt 25) { Write-Output ("  ... and " + (@($ranked).Count - 25) + " more (nothing is truncated silently: rerun with -Ratio to widen or narrow)") }
$outFile = Join-Path $OutDir 'basis-outliers.json'
@{ generated = (Get-Date).ToString('s'); compare_file = (Split-Path $CompareFile -Leaf); ratio = $Ratio; min_stores = $MinStores; findings = @($ranked) } |
  ConvertTo-Json -Depth 6 | Set-Content $outFile -Encoding UTF8
Write-Output ("  -> $outFile   ($(@($nearInt).Count) with the pack-shape mismatch, which is the pack-price-on-a-unit-size fingerprint)")
exit 0
