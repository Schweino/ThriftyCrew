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

Write-Output ""
if ($fail -eq 0) { Write-Output "ALL GUARD PREDICATE TESTS PASS" } else { Write-Output ("$fail TEST(S) FAILED"); exit 1 }
