# test-guards.ps1 - regression tests for the two NEW regex-based spec-guards (the prose-ingredient
# drift guard and the stale-superlative guard). These predicates are the parts most likely to silently
# break under a well-meaning edit; the numeric/format guards are covered by the 300/300 full run.
# Run: .\test-guards.ps1   (exit 0 = all pass, non-zero = a guard predicate regressed)
$ErrorActionPreference = 'Stop'
$fail = 0
function Check($name, $cond) { if ($cond) { Write-Output "  PASS  $name" } else { Write-Output "  FAIL  $name"; $script:fail++ } }

# ---- prose-ingredient guard predicate ----
# a protein marker in recipeIngredient must be backed by an ingredient in the dish.
$MARKERS = @('italian sausage','ground beef','chicken thigh','chicken breast','beef chuck','chuck roast','sirloin','flank','pork belly')
function ProseIngredientFlags($riLine, $ingBlob) {
  $rb = $riLine.ToLower(); $ib = $ingBlob.ToLower(); $hit = @()
  foreach ($mk in $MARKERS) { if ($rb -match [regex]::Escape($mk) -and -not $ib.Contains($mk.TrimEnd('s'))) { $hit += $mk } }
  return $hit
}
Write-Output "prose-ingredient guard:"
Check "flags 'chicken breast' when dish is thigh"   ((ProseIngredientFlags '6 lb boneless skinless chicken breast' 'boneless skinless chicken thigh | rice').Count -ge 1)
Check "flags 'ground beef' when dish is flank"       ((ProseIngredientFlags '3 lb ground beef' 'beef flank/sirloin steak').Count -ge 1)
Check "flags removed 'beef chuck roast'"             ((ProseIngredientFlags '5.5 lb beef chuck roast, 1.75 lb beef steak' 'beef flank/sirloin steak').Count -ge 1)
Check "PASSES thighs when dish is thigh"             ((ProseIngredientFlags '6 lb boneless skinless chicken thighs' 'boneless skinless chicken thigh').Count -eq 0)
Check "PASSES sirloin when dish is flank/sirloin"    ((ProseIngredientFlags '4.25 lb beef sirloin' 'beef flank/sirloin steak').Count -eq 0)
Check "PASSES 'italian seasoning' (not the sausage)" ((ProseIngredientFlags '2 tsp italian seasoning' 'smoked turkey sausage | italian seasoning').Count -eq 0)

# ---- superlative guard predicate ----
$primacyRx = '(?i)(?<!one of )(?<!among )\b(?:the|second)\s+(?:highest|most|biggest)\s+protein\b[^.<"]{0,28}?\b(?:batch|collection|page|group|lineup|library|section)\b'
$subsetRx  = '(?i)\b(?:soup|stew|chili|bowl|bake|casserole|skillet|noodle|beef|chicken|pork|turkey|half)\b'
function SuperlativeFlags($text, $isRank1) {
  if ($isRank1) { return $false }
  foreach ($m in [regex]::Matches($text, $primacyRx)) { if ($m.Value -notmatch $subsetRx) { return $true } }
  return $false
}
Write-Output "superlative guard:"
Check "flags 'the highest protein in the collection' on non-#1" (SuperlativeFlags 'the highest protein count in this whole collection' $false)
Check "flags 'the second highest protein in the batch' on non-#1" (SuperlativeFlags 'the second highest protein count in the batch' $false)
Check "PASSES 'one of the highest protein in the batch'"       (-not (SuperlativeFlags 'one of the highest protein numbers in this batch' $false))
Check "PASSES 'among the highest protein plates in the batch'" (-not (SuperlativeFlags 'among the highest protein plates in the batch' $false))
Check "PASSES scoped 'highest protein soup in this batch'"     (-not (SuperlativeFlags 'the highest protein soup in this batch' $false))
Check "PASSES the true #1 saying 'the highest by a wide margin'" (-not (SuperlativeFlags 'the highest protein dish in this batch by a wide margin' $true))
Check "PASSES a plain 'a genuinely high protein number'"       (-not (SuperlativeFlags 'a genuinely high protein number for a stew' $false))

# ---- buy-has-a-unit guard predicate ----
# FROZEN FIXTURE of the founding bug (2026-08-04): FriendlyAmt's each branch returned the bare count, so
# 661 lines across 339 specs shipped as "Potato (generic): 18.4 (3909 g)" - a number with no noun, which
# reads as a typo and is recoverable only from the gram restatement. The clean twins are the catalog's
# real freeform labels, which look irregular but are NOT this defect and must never be swept up with it.
# Kept in step with the predicate in spec-guards.ps1; if that one changes, this file is where it is proven.
function BuyHasUnitFlags($buy) { return (([string]$buy) -notmatch '[A-Za-z]') }
Write-Output "buy-has-a-unit guard:"
Check "MUST FIRE  a bare count '18.4' (the founding bug, Potato)"  (BuyHasUnitFlags '18.4')
Check "MUST FIRE  a bare count '1.5' (Yellow Onion)"               (BuyHasUnitFlags '1.5')
Check "MUST FIRE  a bare single '1' (Green Cabbage)"               (BuyHasUnitFlags '1')
Check "MUST FIRE  a bare RANGE '1-2' (also breaks the widget's scaleBuy)" (BuyHasUnitFlags '1-2')
Check "PASSES the repaired label '18.4 potatoes'"                  (-not (BuyHasUnitFlags '18.4 potatoes'))
Check "PASSES the singular repair '1 onion'"                       (-not (BuyHasUnitFlags '1 onion'))
Check "PASSES a two-word noun '3 lemons worth'"                    (-not (BuyHasUnitFlags '3 lemons worth'))
Check "CLEAN TWIN an ordinary weight '5.75 lb'"                    (-not (BuyHasUnitFlags '5.75 lb'))
Check "CLEAN TWIN a fraction '1/2 cup'"                            (-not (BuyHasUnitFlags '1/2 cup'))
Check "CLEAN TWIN freeform 'to taste'"                             (-not (BuyHasUnitFlags 'to taste'))
Check "CLEAN TWIN freeform 'about 1 3/4 cups shredded'"            (-not (BuyHasUnitFlags 'about 1 3/4 cups shredded'))
Check "CLEAN TWIN freeform 'juice of 1 lime'"                      (-not (BuyHasUnitFlags 'juice of 1 lime'))
Check "CLEAN TWIN freeform '1 (1 oz) packet'"                      (-not (BuyHasUnitFlags '1 (1 oz) packet'))

Write-Output ""
if ($fail -eq 0) { Write-Output "ALL GUARD PREDICATE TESTS PASS" } else { Write-Output ("$fail TEST(S) FAILED"); exit 1 }
