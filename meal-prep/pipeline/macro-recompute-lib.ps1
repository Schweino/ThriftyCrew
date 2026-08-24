# macro-recompute-lib.ps1 - THE ONE per-serving macro arithmetic (extracted 2026-08-24, v3 D8).
# ---------------------------------------------------------------------------------------------------
# grams / serving_grams -> scale every macro by that factor -> divide by the serving count. That is the
# whole rule, and it is parse-compute.ps1's rule: its PerServing() computes exactly this over grams it
# derived from the source qty strings, and build-v2-spec.ps1 re-runs it at write time and THROWS if the
# intake's stated macros drift past 5 cal or 2 g protein from it.
#
# WHY IT IS A LIB NOW. Three copies of this arithmetic already existed - parse-compute's PerServing,
# spec-guards' inline recompute, and wave-preaudit's Get-MacroRecompute - and D8's skeleton builder
# needs a fourth. This estate has a documented scar from exactly that shape ("the cost MATH lives in
# engine\cost-recipes.ps1 ONLY - the two-copies-of-the-same-math blind spot is a documented board
# trap", build-v2-spec.ps1's own header). So the copy with the best fixtures - wave-preaudit's, which
# already covers all four macros where the build guard covers two - moved here, and wave-preaudit and
# build-intake-skeleton both dot-source it. The remaining two copies are older, load-bearing and
# fixtured where they live; consolidating them is real work with a real parity cost and it is NOT
# smuggled into this commit. Recorded, not done.
#
# NO PARAM BLOCK, DELIBERATELY. A dot-sourced file that declares [switch]$SelfTest resets its caller's
# switch in the caller's own scope - the PS 5.1 trap that made migrate-prose-tokens' first -SelfTest
# run execute the live path instead of its fixtures. A lib declares functions and nothing else.
# ---------------------------------------------------------------------------------------------------

function Get-MacroRecompute {
  <#
    Recompute per-serving macros from a row set's own grams x food-macros-db, exactly the arithmetic
    build-v2-spec.ps1 runs at write time (f = grams / serving_grams; scale every macro by f; divide by
    servings) - extended from its cal+protein pair to all four, because an auditor recomputes all four
    and a carb drift is as publishable a wrong number as a calorie one.
    $Rows: objects with .item and .grams.  $Db: hashtable item -> food-DB row.
    Returns an ordered hashtable {cal, protein, carbs, fat, missing}. `missing` is the list of items
    with no usable row, and it is what stops a partial recompute from reading as a complete one.
  #>
  param($Rows, $Db, [int]$Servings)
  $cal = 0.0; $pro = 0.0; $carb = 0.0; $fat = 0.0
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($r in @($Rows)) {
    $item = [string]$r.item
    if (-not $Db.ContainsKey($item)) { if (-not $missing.Contains($item)) { $missing.Add($item) }; continue }
    $d = $Db[$item]
    $sg = [double]$d.serving_grams
    if ($sg -le 0) { if (-not $missing.Contains($item)) { $missing.Add($item) }; continue }
    $f = [double]$r.grams / $sg
    $cal  += $f * [double]$d.calories
    $pro  += $f * [double]$d.protein_g
    $carb += $f * [double]$d.carbs_g
    $fat  += $f * [double]$d.fat_g
  }
  $n = [Math]::Max(1, $Servings)
  return [ordered]@{
    cal     = [Math]::Round($cal  / $n, 1)
    protein = [Math]::Round($pro  / $n, 1)
    carbs   = [Math]::Round($carb / $n, 1)
    fat     = [Math]::Round($fat  / $n, 1)
    missing = @($missing)
  }
}
