<#
  cost-render-lib.ps1 - the ONE rendering of a recipe's cost block from its db\costed.json row.

  ONE COPY ON PURPOSE, same reason as spec-contradiction-lib and buy-label-lib. Two things need this
  rendering and they must not drift:
    pipeline\build-v2-spec.ps1        renders it at intake, from the intake ingredients
    pipeline\recost-spec-cost-block.ps1  re-renders it on an EXISTING spec whose ingredient list changed

  The second one exists because restoring a missing ingredient to a live spec (the PHANTOM class in
  audit-spec-contradictions) adds a line the cost block has to account for, and until 2026-08-05 the only
  code that could produce that block lived inside the intake script, wrapped around intake-only state.
  A hand-patched cost block passes nothing: spec-guards re-parses every printed line and requires the
  utilizations to sum EXACTLY to cost_batch and the Buy amounts to sum EXACTLY to cost_batch_true.

  Extracted VERBATIM from build-v2-spec (2026-08-05). The only change is the signature: $gramsArr,
  $scalerIng and $slug were closure variables and are now parameters. Every rule inside - the
  exactness-gated pantry fold, the spice classification, the broth/stock/milk exemption, the three
  cross-checks against the engine's own totals - is unchanged, because the rendered numbers are what
  513 live cards already show.

  $GramsArr  : [{item, grams}]  ingredient order, item = the CANONICAL name (costed.json's join key)
  $ScalerIng : [{item, canon, buy, ...}]  same order; canon is the costed key, item is reader-facing
  Returns @{ lines; batch; trueC; cps; cpsTrue; pantryAdd; firstRun }.
#>

# A package label that already counts itself. costed.json carries pkg labels like "1 bunch" and "1 head"
# straight off the board row, and the buy line then prefixes ITS OWN count: "Buy " + 3 + " " + "1 head"
# renders "Buy 3 1 heads". Found 2026-08-16 across 10 specs in two waves; zero of the 1,088 live cards
# carry the pattern, so this wave would have introduced it to the site.
#
# Only a leading "1 " is stripped. "2 lb bag" keeps its count, because there the number is part of the
# package SIZE ("buy 3 of the 2 lb bag") rather than a redundant quantity of one.
# THE STRIP IS UNIT-AWARE, and it has to be. A leading "1 " is redundant in "1 bunch" and "1 head" - the
# buy line supplies its own count - but in "1 lb bag" or "1 gal jug" the number is part of the package SIZE,
# and stripping it renders "Buy 3 lb bags" for what is actually three one-pound bags. A wave-3 auditor
# flagged this as latent on 2026-08-16 and measured it: the only leading-"1 " labels across all 574 costed
# recipes are "1 bunch" (7) and "1 head" (4), with zero "1 <unit>" labels anywhere. So it has never fired -
# which is exactly when a trap is cheapest to close, and exactly when nobody remembers to.
$script:PKG_SIZE_UNITS = @('lb','lbs','oz','floz','fl','g','kg','ml','l','liter','litre','gal','gallon',
                           'qt','quart','pt','pint','ct','count','pk','pack','in','inch','cm')
function Get-PkgLabel([string]$label){
  if($label -match '^\s*1\s+(?<rest>\S.*)$'){
    $rest = $Matches['rest'].Trim()
    # If the very next token is a BARE unit of measure, the 1 belongs to the SIZE and must stay:
    # "1 lb bag" is a one-pound bag, and stripping it renders three of them as "Buy 3 lb bags".
    # But a unit token carrying its OWN number is already a size, so the leading 1 is a redundant count:
    # "1 0.75oz clamshell" is one clamshell that happens to hold 0.75 oz, and reads "Buy 1 0.75oz clamshell".
    # The digit test is the whole distinction between those two.
    $firstTok = ($rest -split '\s+')[0]
    if($firstTok -notmatch '\d'){
      $letters = ($firstTok -replace '[^A-Za-z]','').ToLower()
      if($script:PKG_SIZE_UNITS -contains $letters){ return $label }
    }
    return $rest
  }
  return $label
}

function Get-CostPlural([string]$label,[int]$n){
  if($n -le 1){ return $label }
  if($label -match '(?i)each$'){ return $label }            # "Buy 3 each", never "3 eachs"
  if($label -match '(?i)(ch|sh|ss|s|x|z)$'){ return ($label + 'es') }
  return ($label + 's')
}

# ---- how many batches ONE pantry package covers, and what a shopper may be told about it ------------
# THE BLANKET SENTENCE (fixed 2026-08-15). Until today every bulk line whose starter_n was under 2 printed
# "Buy 1 (lasts several batches)" - a constant, never compared against the amount the recipe actually uses.
# Measured across the 513 live specs carrying it: 1628 lines, of which 537 sat on a package covering FEWER
# THAN THREE batches (342 recipes, 56 ingredients). country-captain-chicken is the case that names the bug:
# its cost line said the raisin box "lasts several batches" while its OWN shop_smart paragraph, four fields
# later, said "Not several batches, but the box is not a one-and-done either". One spec, one box, two
# sentences, flatly opposed - and nothing read them together.
#
# THE THRESHOLDS, and why these and not others:
#   3.0  "several". Plain English puts several at three or more, so below three the word is simply false.
#        It is also where the wording STAYS BYTE-IDENTICAL: 1039 of the 1628 live lines are >= 3 and do not
#        change at all. Same reasoning as the serving-noun fix below - derive the wrong cases, leave the
#        right ones alone, and the republish is the size of the defect instead of the size of the catalogue.
#   1.2  the smallest leftover worth mentioning. The engine's own buy-count tolerance is 2% (the -0.02 in
#        cost-recipes' ceil), so by the engine's reckoning anything under ~1.02 IS exactly one batch. 1.2
#        leaves a fifth of a batch in the package - the least that can honestly be called "some left over".
#        Below it the true statement is that the pack covers this batch, and nothing more.
#   1.75 / 2.5  round-to-nearest between the two named counts. "about two batches" for 1.75-2.5 and "about
#        three" for 2.5-3.0 are the same claim a reader would make holding the box.
#
# WHAT THIS DOES NOT FIX, deliberately. A pack at 0.98-1.00 batches (7 live lines; the worst is
# slow-cooker-beef-and-noodles at 924 g of broth from a 907 g carton) still prints "covers this batch",
# because that is what the engine asserts: starter_n uses the IDENTICAL ceil(g/pkg - 0.02) that the non-bulk
# branch uses at line 189 of cost-recipes, so the bulk branch is not bypassing any buy-count logic - the 2%
# slack is a catalogue-wide rounding rule that keeps a recipe from buying a second 907 g carton for 17 g.
# Tightening it would raise buy counts and true costs on the NON-bulk lines too, which is a pricing decision
# and not this repair's to make.
$script:BULK_SEVERAL_MIN  = 3.0
$script:BULK_LEFTOVER_MIN = 1.2
function Get-PackageBuyCount([double]$Grams,[double]$PkgG){
  <# How many packages this batch needs. THE SAME ceil(g/pkg - 0.02) the engine applies at BOTH branches
     of cost-recipes.ps1 (line 171 for the pantry package, line 189 for the buy package) - the bulk branch
     is not a special case and never was. The 2% is deliberate slack so a batch needing 1005 g out of a
     1000 g package does not tell a shopper to buy two. This function is the file's ONE copy: the
     self-test below reconciles it against the engine's own buy_n on every render, so a drift between the
     two throws rather than printing a buy count nobody checked. #>
  if($PkgG -le 0){ return 1 }
  return [Math]::Max(1,[Math]::Ceiling($Grams/$PkgG - 0.02))
}
function Get-BulkCoverageWords([double]$Cov){
  if($Cov -ge $script:BULK_SEVERAL_MIN) { return 'lasts several batches' }
  if($Cov -ge 2.5)                      { return 'covers about three batches' }
  if($Cov -ge 1.75)                     { return 'covers about two batches' }
  if($Cov -ge $script:BULK_LEFTOVER_MIN){ return 'covers this batch with some left over' }
  return 'covers this batch'
}
function Get-BulkBuyPhrase($CostLine,[double]$Grams){
  <# The parenthetical for a single-package bulk line, derived from pantry_pkg_g / grams. Returns the old
     blanket wording when the row carries no package definition - with no package size there is no ratio to
     state, and inventing one is worse than the vague sentence. (Measured 2026-08-15: zero live lines.) #>
  if($null -eq $CostLine -or $Grams -le 0){ return 'lasts several batches' }
  $pkg = $CostLine.starter_pkg_g
  if($null -eq $pkg -or [double]$pkg -le 0){ return 'lasts several batches' }
  return (Get-BulkCoverageWords ([double]$pkg / $Grams))
}

function Render-CostFields($cost,$GramsArr,$ScalerIng,[string]$slug){
  # ported from r300 build-specs (deltas 4/6 kept): pantry fold is EXACTNESS-GATED, printed
  # contributions sum EXACTLY to the printed true cost.
  $gramsArr = @($GramsArr); $scalerIng = @($ScalerIng)
  $costLines=@{}; foreach($l in $cost.lines){ $costLines[$l.item]=$l }
  # build-card2 self-test mirror: ceil(grams/pkg_g - 0.02) must equal the engine's buy_n
  foreach($ig in $gramsArr){
    $cl = $costLines[$ig.item]; if(-not $cl){ continue }
    $pkgG = $null; $n = $null
    if($cl.buy_n -and $cl.pkg_g){ $pkgG=[double]$cl.pkg_g; $n=[int]$cl.buy_n }
    elseif($cl.starter_n -and $cl.starter_pkg_g){ $pkgG=[double]$cl.starter_pkg_g; $n=[int]$cl.starter_n }
    if($null -eq $pkgG -or $pkgG -le 0){ continue }
    $chk = Get-PackageBuyCount ([double]$ig.grams) $pkgG
    if($chk -ne $n){ throw ("SELF-TEST: {0} ceil({1}g/{2}g)={3} != engine buy_n {4} - spec grams and costed row disagree (stale costed.json? run cost-recipes -Slugs {5})" -f $ig.item,$ig.grams,$pkgG,$chk,$n,$slug) }
  }
  $costHtml=@(); $sumUtil=0.0; $sumTrue=0.0
  $pantryItems=@(); $pantryUtil=0.0; $foldSet=@{}
  foreach($ig in $gramsArr){
    $cl = $costLines[$ig.item]
    $util = 0.0; if($cl){ $util=[double]$cl.util_cost }
    $isSpice = ($ig.item -match 'Salt|Pepper$|Powder$|Paprika|Cumin|Coriander|Turmeric|Masala|Cinnamon|Cloves|Allspice|Nutmeg|Oregano|Thyme|Basil$|Dill|Parsley|Bay Leaves|Flakes|Seasoning$|Five-Spice|Cayenne|Italian Seasoning')
    $utilOnly = ($null -eq $cl) -or [bool]$cl.bulk -or (-not $cl.buy_cost)
    # "Pantry seasonings (chicken broth)" reads as a mistake (sopa-de-fideo, writer-wave finding)
    if($ig.item -match 'Broth|Stock|Milk|Cream$|Juice$'){ $isSpice = $false; $utilOnly = $false }
    if(($isSpice -or ($ig.grams -lt 15 -and $util -lt 0.15)) -and $utilOnly){
      $sc = $scalerIng | Where-Object { $_.canon -eq $ig.item } | Select-Object -First 1
      $pantryItems += ([string]$sc.item).ToLower(); $pantryUtil += $util; $foldSet[$ig.item]=1
    }
  }
  foreach($ig in $gramsArr){
    $cl = $costLines[$ig.item]; if(-not $cl){ continue }
    if($foldSet.ContainsKey($ig.item)){ continue }
    $util=[double]$cl.util_cost
    $sumUtil += $util
    $sc = $scalerIng | Where-Object { $_.canon -eq $ig.item } | Select-Object -First 1
    $amt = [string]$sc.buy
    $nm  = [string]$sc.item
    if($cl.bulk){
      $sumTrue += $util
      if($cl.starter_n -and [int]$cl.starter_n -ge 2 -and $cl.starter_pkg){
        $costHtml += ($nm + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Pantry staple; this batch alone uses about ' + [int]$cl.starter_n + ' ' + (Get-CostPlural ([string]$cl.starter_pkg) ([int]$cl.starter_n)) + '.</strong>')
      } else {
        $costHtml += ($nm + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Buy 1 (' + (Get-BulkBuyPhrase $cl ([double]$ig.grams)) + ').</strong>')
      }
    } elseif($cl.buy_cost){
      $sumTrue += [double]$cl.buy_cost
      $pkgTxt = $cl.pkg; if(-not $pkgTxt){ $pkgTxt='pack' }
      $costHtml += ($nm + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Buy ' + $cl.buy_n + ' ' + (Get-CostPlural (Get-PkgLabel $pkgTxt) ([int]$cl.buy_n)) + ': $' + ([double]$cl.buy_cost).ToString('0.00') + '.</strong>')
    } else {
      $sumTrue += $util
      $costHtml += ($nm + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Buy as needed.</strong>')
    }
  }
  foreach($ig in $gramsArr){
    $cl = $costLines[$ig.item]; if(-not $cl){ continue }
    if($foldSet.ContainsKey($ig.item)){ $sumUtil += [double]$cl.util_cost; $sumTrue += [double]$cl.util_cost }
  }
  if($pantryItems.Count -gt 0){
    $pl = ($pantryItems | Select-Object -Unique) -join ', '
    $costHtml += ('Pantry seasonings (' + $pl + '): ~$' + $pantryUtil.ToString('0.00') + '. <strong>From jars you keep on hand.</strong>')
  }
  $batch=[Math]::Round($sumUtil,2); $trueC=[Math]::Round($sumTrue,2)
  $cps = [Math]::Round($batch/14,2); $cpsTrue=[Math]::Round($trueC/14,2)
  $pantryAdd=[double]$cost.cost_pantry_add; $firstRun=[double]$cost.cost_first_run
  # exactness cross-checks against the engine's own totals (never render numbers that disagree)
  if([Math]::Abs($batch-[double]$cost.cost_batch) -gt 0.005){ throw ($slug + ': rendered batch ' + $batch + ' != engine ' + $cost.cost_batch + ' (missing/extra ingredient vs the costed row?)') }
  if([Math]::Abs($trueC-[double]$cost.cost_batch_true) -gt 0.005){ throw ($slug + ': rendered true ' + $trueC + ' != engine ' + $cost.cost_batch_true) }
  if([Math]::Abs(($trueC+$pantryAdd)-$firstRun) -gt 0.005){ throw ($slug + ': first_run ' + $firstRun + ' != true+add ' + ($trueC+$pantryAdd)) }
  # SERVING NOUN (2026-08-07): these two lines said "per bowl" unconditionally, which shipped on all 29
  # wrapped burritos as "roughly $X per bowl" (58 wrong lines, caught at the pre-publish audit). The noun is
  # now derived. Default stays "bowl" so the copy on the 513 existing recipes is byte-identical - this is
  # deliberately NOT a switch to a universal "per serving", which would rewrite every live card.
  # The 'bowl' test comes SECOND on purpose: beef-burrito-bowls, ground-turkey-burrito-bowl and
  # grilled-pork-tenderloin-burrito-bowl all contain "burrito" and are bowls.
  $servingNoun = if($slug -match 'burrito' -and $slug -notmatch 'bowl'){ 'burrito' } else { 'bowl' }
  $costHtml += ('<strong>Batch total: about $' + $batch.ToString('0.00') + ' across 14 servings, so roughly $' + $cps.ToString('0.00') + ' per ' + $servingNoun + '.</strong> This counts only the amounts this batch actually uses from each package, so it is the cost of the food in the containers, not a register receipt.')
  $costHtml += ('<strong>True shopping cost: about $' + $trueC.ToString('0.00') + ' across 14 servings, roughly $' + $cpsTrue.ToString('0.00') + ' per ' + $servingNoun + '.</strong> What the register trip looks like if your pantry is already stocked. Meat, produce, and packaged items are counted as the whole packages you have to buy, since you cannot grab a partial box, can, or jar. Pantry staples you already own (rice, seasonings, oils, and long-lasting sauces) are counted at only what this batch uses.')
  if($pantryAdd -gt 0){
    $costHtml += ('<strong>Starting with an empty pantry? Add about $' + $pantryAdd.ToString('0.00') + ' one time.</strong> That is the extra cost of buying full containers of every pantry staple in this recipe instead of just the amounts used, which puts a first shopping trip near $' + $firstRun.ToString('0.00') + '. Those containers then feed this batch and many more after it.')
  }
  @{ lines=@($costHtml); batch=$batch; trueC=$trueC; cps=$cps; cpsTrue=$cpsTrue; pantryAdd=[Math]::Round($pantryAdd,2); firstRun=[Math]::Round($firstRun,2) }
}
