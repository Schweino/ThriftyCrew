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

# ---------------------------------------------------------------------------------------------------
# THE SCALER DATA BLOCK'S gpu, AND THE ONE RULE THAT SAYS WHICH BASIS IT IS ON (2026-09-02, corn04).
#
# The card's data block carries three numbers per line: grams, pkg_g and gpu. grams and pkg_g are the
# DRAINED basis wherever the engine has a drained yield (a 15.25 oz can of corn drains to 298 g, not
# 432 g), because that is the material the recipe actually uses. gpu was still the ingredient row's
# GROSS grams per feed unit - 28.3495 g/oz of can including the packing water. Nothing declared which
# basis gpu was on and nothing checked, so:
#     required = grams / gpu        paired a DRAINED numerator with a GROSS denominator
#     k        = ceil(required / packageBasisUnits)
# under-bought on 88 of 105 same-package drained lines across 76 live cards, in the widget, the print
# module, the store picker, compute-v2's cheapest_ps and (on a third basis of its own) the Meal Plan
# Builder. The static Buy N line was right the whole time because it pairs grams with pkg_g.
#
# THE FIX IS ONE BASIS, NOT ONE MORE FORMULA. gpu becomes THIS LINE's grams per feed unit, so the
# block is internally consistent and every reader of it - JS included, unchanged - lands on the
# engine's own count:
#     required / (pkg_g/gpu_eff)  ==  grams / pkg_g
# and the authored fallback package pkg_g/gpu_eff becomes the real 15.24 oz can again instead of the
# 10.51 oz object that never existed.
#
# It is a no-op on every non-drained line by construction (PkgGrossG == PkgG), which is why 30,884 of
# the 31,372 routed rows in the 2026-09-02 measurement could not move.
function Get-ScalerGpu([double]$Gpu, [double]$PkgG, [double]$PkgGrossG) {
  if ($Gpu -le 0) { return 0.0 }
  if ($PkgGrossG -gt 0 -and $PkgG -gt 0 -and $PkgGrossG -ne $PkgG) { return [math]::Round($Gpu * $PkgG / $PkgGrossG, 4) }
  return $Gpu
}

# THE OUTCOME CHECK FOR THAT BASIS, in ONE place because two callers need it and a second copy of a
# 0.5% tolerance is how the estate's twins are born (build-card2 refuses to EMIT a mis-based block;
# wave-preaudit refuses a CARD carrying one). The question is not "is gpu the number I expect" - it is
# "does the block's own authored fallback package come out as the physical package a reader buys".
# That is a fact about the world (a 15.25 oz can), so it is checkable without trusting either input.
# Returns $null when the block is sound, else the two package sizes and the relative gap.
function Get-ScalerBasisMismatch([double]$PkgG, [double]$BlockGpu, [double]$PkgGrossG, [double]$AuthoredGpu, [double]$Tol = 0.005) {
  if (-not ($PkgG -gt 0) -or -not ($BlockGpu -gt 0) -or -not ($PkgGrossG -gt 0) -or -not ($AuthoredGpu -gt 0)) { return $null }
  $fallback = $PkgG / $BlockGpu
  $physical = $PkgGrossG / $AuthoredGpu
  if (-not ($physical -gt 0)) { return $null }
  $rel = [math]::Abs($fallback - $physical) / $physical
  if ($rel -le $Tol) { return $null }
  return [pscustomobject]@{ fallback = [double]$fallback; physical = [double]$physical; rel = [double]$rel; tol = [double]$Tol }
}

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
  # 0.02, the estate's ONE whole-package ceil tolerance, matching costAt() in tpl2-scaler-prefix.html
  # (which this file mirrors) and the engine, the render library and the planner (2026-09-02). Both
  # sides sat at 1e-9 and rounded on floating-point noise, so a line 0.4% over a whole package bought
  # an extra one against the Buy N printed beside it. Declared as whole-package-ceil-tolerance in
  # ops\twin-rules.json; audit-twin-drift fails if this constant and the JS stop agreeing.
  if ((-not $variable) -and $basis -gt 0) { $k = [int][math]::Max(1, [math]::Ceiling($Required / $basis - 0.02)) }
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
