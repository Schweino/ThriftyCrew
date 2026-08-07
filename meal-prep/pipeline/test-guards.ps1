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

# ---- cal-floor guard predicate ----
# FROZEN FIXTURE of the founding change (2026-08-06): the gate was a flat
# `if($spec.stat.cal -lt 550){ Fail }`, which hard-failed all 29 wrapped burritos - a format capped at
# 400 cal by design (fixed 90-cal high-fiber tortilla + 4 oz raw meat). A format may now declare
# spec.cal_floor. The escape hatch is deliberately narrow, so the must-fire cases below matter more than
# the clean ones: a lowered floor on a NON-burrito, and a floor under the 200 hard minimum, must both
# still fail. The FIRST clean twin is the real regression canary: an ordinary 400-cal dinner carrying no
# cal_floor must fail exactly as it always did, or this change quietly deleted the house floor.
# MIRRORS spec-guards.ps1 (search '$calFloor = 550'). If you edit one, edit both.
function CalFloorFlags($slug, $cal, $declared) {
  $floor = 550
  if ($null -ne $declared) { $floor = [int]$declared }
  if ($floor -ne 550 -and $slug -notmatch 'burrito') { return 'non-burrito lowered floor' }
  if ($floor -lt 200) { return 'under hard minimum' }
  if ($cal -lt $floor) { return 'under declared floor' }
  return $null
}
Write-Output "cal-floor guard:"
Check "MUST FIRE ordinary dinner at 400 with no declared floor (old 550 behaviour intact)" ($null -ne (CalFloorFlags 'chicken-tikka-masala-bowls' 400 $null))
Check "MUST FIRE a non-burrito trying to declare a lowered floor"                          ((CalFloorFlags 'beef-birria-rice-bowls' 300 250) -eq 'non-burrito lowered floor')
Check "MUST FIRE a floor under the 200 hard minimum"                                       ((CalFloorFlags 'buffalo-chicken-burrito' 150 150) -eq 'under hard minimum')
Check "MUST FIRE a burrito that falls under its OWN declared floor"                        ((CalFloorFlags 'buffalo-chicken-burrito' 240 250) -eq 'under declared floor')
Check "CLEAN TWIN a burrito at 380 declaring 250"                                          ($null -eq (CalFloorFlags 'buffalo-chicken-burrito' 380 250))
Check "CLEAN TWIN the batch's leanest, shawarma at 273 declaring 250"                      ($null -eq (CalFloorFlags 'chicken-shawarma-burrito' 273 250))
Check "CLEAN TWIN the batch's fullest, carne asada at 398 declaring 250"                   ($null -eq (CalFloorFlags 'carne-asada-burrito' 398 250))
Check "CLEAN TWIN an ordinary 600-cal dinner with no declared floor"                       ($null -eq (CalFloorFlags 'slow-cooker-barbacoa-bowls' 600 $null))
Check "CLEAN TWIN a burrito with NO declared floor still faces 550"                        ($null -ne (CalFloorFlags 'some-future-burrito' 400 $null))

# ---- bounded-calorie-claim exemption ----
# FROZEN FIXTURE of the founding change (2026-08-07): STAT-PROSE flags any calorie figure in prose that is
# not the stat, which is right for a STALE number ("499 calories" on a 373-cal card) and wrong for a TRUE
# UPPER BOUND. The 29 wrapped burritos are capped at 400 by design and say so, which tripped the gate 21
# times on statements that were all true. The exemption is deliberately narrow, so the must-fire cases below
# are the point: an UNSATISFIED bound and an unbounded figure must both still fire.
# MIRRORS pipeline\spec-contradiction-lib.ps1 (search 'Test-CalClaimContradiction'). Edit one, edit both.
# That pointer named a function that no longer existed for one revision - the mirror contract had a dead
# address, which is the same failure as the mirror itself drifting, just harder to notice.
$RX_CAL_T   = '(?i)\b(\d{3,4})\s*cal(?:orie)?s?\b'
$RX_BOUND_T = '(?i)(?<!\bnot\s)(?<!\bnever\s)(?<![a-z])(?:under|below|beneath|less than|fewer than|no more than|at most)\s*$'
function StatProseCalFlags($text, $statCal) {
  foreach ($m in [regex]::Matches($text, $RX_CAL_T)) {
    $claimed = [int]$m.Groups[1].Value
    $start = [Math]::Max(0, $m.Index - 24)
    $bounded = ($text.Substring($start, $m.Index - $start) -match $RX_BOUND_T)
    if ($bounded) { if ($statCal -ge $claimed) { return $true } }
    elseif ($claimed -ne $statCal) { return $true }
  }
  return $false
}
Write-Output "bounded-calorie-claim exemption:"
Check "MUST FIRE  a stale figure '499 calories' on a 373-cal card (the founding STAT-PROSE bug)" (StatProseCalFlags 'a 499 calorie bowl you can batch' 373)
Check "MUST FIRE  an UNSATISFIED bound 'under 300 calories' on a 396-cal recipe"                 (StatProseCalFlags 'every one lands under 300 calories' 396)
Check "MUST FIRE  a bare '400 calories' with no bound word on a 396-cal recipe"                  (StatProseCalFlags 'these are 400 calories each' 396)
Check "MUST FIRE  an exact-equal bound 'under 396 calories' on a 396-cal recipe (not under it)"  (StatProseCalFlags 'lands under 396 calories' 396)
Check "CLEAN TWIN 'under 400 calories' on a 396-cal recipe (true, and the batch's premise)"      (-not (StatProseCalFlags 'every one lands under 400 calories' 396))
Check "CLEAN TWIN 'under 400 calories' on the leanest, 273 cal"                                  (-not (StatProseCalFlags 'under 400 calories with 34 g protein' 273))
Check "CLEAN TWIN 'less than 400 calories'"                                                      (-not (StatProseCalFlags 'less than 400 calories a burrito' 396))
Check "CLEAN TWIN 'no more than 400 calories'"                                                   (-not (StatProseCalFlags 'no more than 400 calories each' 396))
Check "CLEAN TWIN the exact stat quoted plainly"                                                 (-not (StatProseCalFlags 'a 396 calorie burrito' 396))
Check "MUST FIRE  a bound too far away to reach the number (lookback is a 24-char window)"       (StatProseCalFlags 'under a tight budget and a long day of cooking, 500 calories' 396)
Check "MUST FIRE  a NEGATED bound 'not under 400 calories' on a 396-cal recipe"                  (StatProseCalFlags 'these are not under 400 calories' 396)
Check "MUST FIRE  a word merely ENDING in a bound word ('thunder 400 calories')"                 (StatProseCalFlags 'a clap of thunder 400 calories later' 396)
Check "CLEAN TWIN 'never under 400' still fires, but plain 'under 400' after a comma passes"     (-not (StatProseCalFlags 'lean, under 400 calories' 396))

Write-Output ""
if ($fail -eq 0) { Write-Output "ALL GUARD PREDICATE TESTS PASS" } else { Write-Output ("$fail TEST(S) FAILED"); exit 1 }
