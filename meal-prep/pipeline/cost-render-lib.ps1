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

function Get-CostPlural([string]$label,[int]$n){
  if($n -le 1){ return $label }
  if($label -match '(?i)each$'){ return $label }            # "Buy 3 each", never "3 eachs"
  if($label -match '(?i)(ch|sh|ss|s|x|z)$'){ return ($label + 'es') }
  return ($label + 's')
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
    $chk = [Math]::Max(1,[Math]::Ceiling([double]$ig.grams/$pkgG - 0.02))
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
        $costHtml += ($nm + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Buy 1 (lasts several batches).</strong>')
      }
    } elseif($cl.buy_cost){
      $sumTrue += [double]$cl.buy_cost
      $pkgTxt = $cl.pkg; if(-not $pkgTxt){ $pkgTxt='pack' }
      $costHtml += ($nm + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Buy ' + $cl.buy_n + ' ' + (Get-CostPlural $pkgTxt ([int]$cl.buy_n)) + ': $' + ([double]$cl.buy_cost).ToString('0.00') + '.</strong>')
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
  $costHtml += ('<strong>Batch total: about $' + $batch.ToString('0.00') + ' across 14 servings, so roughly $' + $cps.ToString('0.00') + ' per bowl.</strong> This counts only the amounts this batch actually uses from each package, so it is the cost of the food in the containers, not a register receipt.')
  $costHtml += ('<strong>True shopping cost: about $' + $trueC.ToString('0.00') + ' across 14 servings, roughly $' + $cpsTrue.ToString('0.00') + ' per bowl.</strong> What the register trip looks like if your pantry is already stocked. Meat, produce, and packaged items are counted as the whole packages you have to buy, since you cannot grab a partial box, can, or jar. Pantry staples you already own (rice, seasonings, oils, and long-lasting sauces) are counted at only what this batch uses.')
  if($pantryAdd -gt 0){
    $costHtml += ('<strong>Starting with an empty pantry? Add about $' + $pantryAdd.ToString('0.00') + ' one time.</strong> That is the extra cost of buying full containers of every pantry staple in this recipe instead of just the amounts used, which puts a first shopping trip near $' + $firstRun.ToString('0.00') + '. Those containers then feed this batch and many more after it.')
  }
  @{ lines=@($costHtml); batch=$batch; trueC=$trueC; cps=$cps; cpsTrue=$cpsTrue; pantryAdd=[Math]::Round($pantryAdd,2); firstRun=[Math]::Round($firstRun,2) }
}
