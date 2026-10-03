# commodity-density-lib.ps1 - a commodity's DENSITY, read in ONE place (2026-10-03, Brad's R7.4 ruling).
# ---------------------------------------------------------------------------------------------------
# WHY. Queue 2026-10-02-44c416: pricing-math-lib's Convert-ToUnit read "fl oz" as WEIGHT oz on an oz commodity while
# pu-lib's Get-SizeMeasureKind read it as VOLUME. Brad ruled (design/PLAN-weekly-root-families-2026-10-02.md, R7.4) that
# each such commodity declares a SOURCED density so the size converts. The declaration is `density_g_ml` beside a
# `density_source` in grocery/commodities.json. The row contract (row-contract-lib.ps1) and the engine (Get-UnitPrice in
# pricing-math-lib.ps1) both read it HERE, so the size the contract accepts is the divisor the engine uses.
# Split out of pricing-math-lib.ps1 on the day it was written, to keep that file at its size mark
# (ops/audit-file-size-budget.ps1). Pure: functions only, nothing runs on load except the pu-lib dot-source.
# USE WHEN: a builder, audit or test needs to know whether a commodity declares a density, or to convert a volume size to
# its weight unit; never read density_g_ml or kind_equivalent directly.
# ENFORCED BY: grocery/test-row-contract.ps1 (the R7.4 cases)
# ---------------------------------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'pu-lib.ps1')   # Get-SizeMeasureKind: the ONE kind reader

# The declaration. Understood: a numeric density_g_ml > 0, and kind_equivalent 'near-water' (an allowlist of understood
# values, read the way audit-unit-basis-outlier's Test-KindEquivalentSkip reads it, never "any value silences").
# Anything else is NOT a declaration. Returns @{ value; source } or $null.
function Get-TcCommodityDensity($Commodity) {
  if ($null -eq $Commodity) { return $null }
  $p = $Commodity.PSObject.Properties
  if ($Commodity -is [hashtable]) {
    if ($Commodity.ContainsKey('density_g_ml')) { $d = 0.0; if ([double]::TryParse([string]$Commodity['density_g_ml'], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -gt 0) { return @{ value = $d; source = 'commodity.density_g_ml' } } }
    if ($Commodity.ContainsKey('kind_equivalent') -and [string]$Commodity['kind_equivalent'] -eq 'near-water') { return @{ value = 1.0; source = 'commodity.kind_equivalent=near-water' } }
    return $null
  }
  if ($p['density_g_ml']) { $d = 0.0; if ([double]::TryParse([string]$Commodity.density_g_ml, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and $d -gt 0) { return @{ value = $d; source = 'commodity.density_g_ml' } } }
  if ($p['kind_equivalent'] -and [string]$Commodity.kind_equivalent -eq 'near-water') { return @{ value = 1.0; source = 'commodity.kind_equivalent=near-water' } }
  return $null
}

# THE DENSITY THE ARITHMETIC USES: a NUMERIC density_g_ml on a weight commodity (oz, lb), else 0. 'near-water' is 0 on
# purpose: its declaration says the two units are interchangeable at the board's precision (disinfectant-spray's
# kind_equivalent_why), which is what the engine already does, so it silences the kind question without moving a price.
function Get-TcDensityGml($Commodity) {
  $d = Get-TcCommodityDensity $Commodity
  if ($null -eq $d -or [string]$d.source -ne 'commodity.density_g_ml') { return 0.0 }
  $u = ''
  if ($Commodity -is [hashtable]) { $u = [string]$Commodity['unit'] } elseif ($Commodity.PSObject.Properties['unit']) { $u = [string]$Commodity.unit }
  if ($u -ne 'oz' -and $u -ne 'lb') { return 0.0 }
  return [double]$d.value
}

# THE DENSITY ONE ROW MAY USE: the commodity's, except on a row whose name states the size's number as a weight
# (Test-TcKindLabelsDisagree below), where it is 0 and the row is read exactly as before. Get-UnitPrice and the row
# contract both call this, so they decide the same row the same way.
function Get-TcRowDensityGml($Commodity, [string]$SizeText, [string]$Name, [string]$Unit) {
  $dg = Get-TcDensityGml $Commodity
  if ($dg -gt 0 -and (Test-TcKindLabelsDisagree $SizeText $Name $Unit)) { return 0.0 }
  return $dg
}

# THE PRICED ROW WHEN A DENSITY MOVED THE DIVISOR: Get-UnitPrice's size-or-name amount $Amt was read with the density;
# the same source read without it says whether the density changed anything. When it did, the result names the density
# in its basis and carries size_override with the WEIGHT divided by, so every reader of the cell's size (pu-lib, the
# kind audit) reads the quantity the price used, as Get-UnitPrice's gallon-jug branch does. $null = nothing moved, and
# Get-UnitPrice returns its ordinary result.
function Get-TcDensityPriced($Deal, [string]$SizeForAmt, [string]$Unit, [double]$Dg, $Pr, [double]$Amt) {
  if ($Dg -le 0 -or $Amt -le 0) { return $null }
  $src = $SizeForAmt
  if ($null -eq (Get-SizeAmount $SizeForAmt $Unit $Dg)) { $src = [string]$Deal.name }   # Get-UnitPrice's own name fallback
  $amt0 = Get-SizeAmount $src $Unit
  if ($null -eq $amt0 -or [math]::Abs($amt0 - $Amt) -le 1e-9) { return $null }
  $aR = [math]::Round($Amt, 3); $inv = [Globalization.CultureInfo]::InvariantCulture
  return @{ unit_price = ($Pr.per_item / $Amt); basis = ("size $aR $Unit (a volume size at " + $Dg.ToString($inv) + " g/ml, commodity.density_g_ml)"); size_override = ($aR.ToString($inv) + ' ' + $Unit); note = $Pr.note }
}

# A VOLUME TOKEN TO A WEIGHT UNIT THROUGH A DENSITY: the floz arm of Convert-ToUnit reads the volume, x 29.5735 ml per
# fl oz x g/ml, / 28.3495 g per oz or 453.592 g per lb (the constants Convert-ToUnit's arms already use). $null when the
# token is not a volume, the unit not a weight, or no density, so the caller falls through to its ordinary arm.
function Convert-TcVolumeToWeight([double]$num, [string]$t, [string]$unit, [double]$densityGml) {
  if ($densityGml -le 0 -or ($unit -ne 'oz' -and $unit -ne 'lb')) { return $null }
  if ($t -notmatch '^(fl\s*oz|floz|gal|gallon|gallons|qt|quart|quarts|pt|pint|pints|l|liter|liters|ltr|ml)$') { return $null }
  $vf = Convert-ToUnit $num $t 'floz'
  if ($null -eq $vf) { return $null }
  $grams = $vf * 29.5735 * $densityGml
  if ($unit -eq 'oz') { return $grams / 28.3495 }
  return $grams / 453.592
}

# TWO PARTIES, TWO KINDS, ONE NUMBER: the size field says a volume and the NAME states the commodity's weight at the SAME
# amount (1% bar): "Magnolia Sweetened Condensed Milk, 14 oz., 6 pk." sized "84 fl oz" is 84 WEIGHT oz. A density must
# NOT convert such a row (84 fl oz of condensed milk is 113 oz, a 26% understatement); the row contract refuses it as
# KIND-LABELS-DISAGREE and the engine leaves its number as read. Amounts from Get-SizeAmount with no density.
function Test-TcKindLabelsDisagree([string]$SizeText, [string]$Name, [string]$Unit) {
  if (-not $SizeText -or -not $Name) { return $false }
  if ($Unit -ne 'oz' -and $Unit -ne 'lb') { return $false }
  if ((Get-SizeMeasureKind -Size $SizeText -Unit $Unit) -ne 'volume') { return $false }
  if (Test-NameOffersTwoSizes $Name) { return $false }
  if ((Get-SizeMeasureKind -Size $Name -Unit $Unit) -ne 'weight') { return $false }
  $a = Get-SizeAmount $SizeText $Unit; $n = Get-SizeAmount $Name $Unit
  if ($null -eq $a -or $null -eq $n -or $a -le 0) { return $false }
  return ([math]::Abs($a - $n) / $a -le 0.01)
}
