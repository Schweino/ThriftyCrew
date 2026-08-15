<#
  package-cost-lib.ps1 - THE PowerShell copy of the recipe card's whole-package pricing rule.

  ONE COPY ON PURPOSE. The authority for this rule is costAt()/cheapestAcross() in
  meal-prep\pipeline\tpl2-scaler-prefix.html, because that is what actually prices what a reader sees.
  Anything server-side that needs the same number (the v2 per-serving manifest, the blast-radius
  measurement) dot-sources THIS file rather than transcribing the JS again. Two PowerShell transcriptions
  of one JS rule is the duplication that let the receipt and the store picker disagree by $21 on the same
  page in the first place.

  THE RULE, and why each branch exists:
    required        = grams / grams_per_unit, in the board row's own unit
    packageBasis    = the STORE's package size when the board captured one, else the recipe's authored
                      pkg_g/gpu. export-feed REFUSES to guess a package size, because a guessed size is a
                      wrong price; the recipe's own authored size is a real one, so it is a legal fallback.
    k               = ceil(required / packageBasis), never less than 1 - you cannot buy 7.5 tbsp of vinegar
    cost            = variable-weight cell (a meat counter, priced by the exact amount): per-unit * required
                      shelf tag * k, but ONLY when the tag rides the feed's OWN package size
                      otherwise per-unit * packageBasis * k
  The middle branch is the subtle one: purchasePriceMinor was measured against packageBasisUnits, so when
  the basis came from the authored fallback the tag belongs to a different package and must not be used.

  CHEAPEST = minimum COST across store cells, NOT minimum per-unit price. A warehouse store wins per-unit
  with a huge package and the reader is billed for the huge package: butter needs 0.194 lb and the old rule
  billed a Sam's Club 4 lb box at $10.22 against Aldi's $2.89 1 lb box; rice needed 1.8 lb and it billed a
  50 lb sack at $40.00. Strict -lt keeps the FIRST minimum, matching the template's `cost<best`, so a tie
  resolves to the feed's own store order.

  The winner depends on the REQUIRED QUANTITY (over ~3.5 lb the Sam's pack really is the cheapest butter),
  which is why no "cheapest store" can be pinned server-side per commodity.
#>

function Get-PkgCellField($cell, [string]$name) {
  if ($null -eq $cell) { return $null }
  $p = $cell.PSObject.Properties[$name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

# Returns $null when the cell cannot be priced; otherwise the cost plus the pieces callers report on.
function Get-PkgCellCost($cell, [double]$Required, [double]$FallbackBasis) {
  $puRaw = Get-PkgCellField $cell 'perUnitMicros'
  $pu = if ($null -eq $puRaw) { 0.0 } else { [double]$puRaw }
  if (-not ($pu -gt 0) -or -not ($Required -gt 0)) { return $null }
  $up = $pu / 1000000
  $variable = ((Get-PkgCellField $cell 'variableWeight') -eq $true)
  $pbuRaw = Get-PkgCellField $cell 'packageBasisUnits'
  $pbu = if ($null -eq $pbuRaw) { 0.0 } else { [double]$pbuRaw }
  $basis = 0.0
  if (-not $variable) { $basis = if ($pbu -gt 0) { $pbu } else { $FallbackBasis } }
  $k = 0
  if ((-not $variable) -and $basis -gt 0) { $k = [int][math]::Max(1, [math]::Ceiling($Required / $basis - 1e-9)) }
  $ppmRaw = Get-PkgCellField $cell 'purchasePriceMinor'
  $ppm = if ($null -eq $ppmRaw) { 0.0 } else { [double]$ppmRaw }
  $cost = $null
  if ($variable) { $cost = $up * $Required }
  elseif ($pbu -gt 0 -and $ppm -gt 0 -and $k -gt 0) { $cost = $ppm * $k / 100 }
  elseif ($basis -gt 0 -and $k -gt 0) { $cost = $up * $basis * $k }
  if ($null -eq $cost) { return $null }
  if (-not ([double]$cost -ge 0)) { return $null }
  return [pscustomobject]@{
    cost = [double]$cost; k = [int]$k; up = $up; variable = $variable
    packageBasis = [double]$basis; own_basis = ($pbu -gt 0)
  }
}

# $Inputs is a pricing_inputs[<bid>] object. -NonSaleOnly is the card's everyday lane and requires a
# schema>=2 feed; on an older feed the caller must not use it, because "no flags" would then read as
# "nothing is on sale" and let a sale price masquerade as a shelf price.
function Get-PkgCheapestAcross($Inputs, [double]$Required, [double]$FallbackBasis, [switch]$NonSaleOnly) {
  $stores = Get-PkgCellField $Inputs 'stores'
  if ($null -eq $stores) { return $null }
  $best = $null
  foreach ($p in $stores.PSObject.Properties) {
    if ($NonSaleOnly -and ((Get-PkgCellField $p.Value 'sale') -eq $true)) { continue }
    $r = Get-PkgCellCost $p.Value $Required $FallbackBasis
    if ($null -eq $r) { continue }
    if ($null -eq $best -or $r.cost -lt $best.cost) {
      $best = [pscustomobject]@{
        cost = $r.cost; k = $r.k; up = $r.up; variable = $r.variable
        packageBasis = $r.packageBasis; own_basis = $r.own_basis; store = [string]$p.Name
      }
    }
  }
  return $best
}
