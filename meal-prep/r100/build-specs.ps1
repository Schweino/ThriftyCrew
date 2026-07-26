# build-specs.ps1 - Assembles per-recipe spec skeletons (specs\<slug>.json) deterministically from
# recipes-computed.json + recipes-costed.json + r100-board-map.json + food DB + densities.
# Numeric/display/cost/scaler fields are MACHINE-BUILT here; prose fields (intro_html, shop_smart,
# make_it, portion_html, credit_tail, head.description/keywords/steps, prep/cook times) are left as
# "" / [] for the prose wave to fill. spec-guards.ps1 later enforces consistency before any build.
#
# RETIRED - DO NOT RE-RUN (2026-07-25). Two reasons:
#  1. It overwrites specs\<slug>.json, and the shipped specs carry MERGED PROSE this script would wipe.
#  2. It writes the RAW map gpu into the scaler payload with NO unit reconciliation (the 2026-07-19
#     brown-sugar 16x lesson). The shipped specs were corrected by patch-scaler-gpu.ps1; the fixed
#     generator pattern (Resolve-ScalerGpu) lives in r300\build-specs.ps1 - port from there.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$computed = Get-Content (Join-Path $here 'recipes-computed.json') -Raw | ConvertFrom-Json
$costed   = Get-Content (Join-Path $here 'recipes-costed.json') -Raw | ConvertFrom-Json
$mapNew   = (Get-Content (Join-Path $here 'r100-board-map.json') -Raw | ConvertFrom-Json).map
$mapOldM  = (Get-Content (Join-Path $here '..\ingredient-map.json') -Raw | ConvertFrom-Json).mappings
$db       = (Get-Content (Join-Path $here '..\food-macros-db.json') -Raw | ConvertFrom-Json).items
$dn       = (Get-Content (Join-Path $here 'densities.json') -Raw | ConvertFrom-Json).items
$existing113 = Get-Content (Join-Path $here 'EXISTING-113.txt') | ForEach-Object { ($_ -split '\|')[1] } | Where-Object { $_ } | ForEach-Object { $_.Trim() }

$dbm=@{}; foreach($i in $db){ $dbm[$i.item]=$i }
$dnm=@{}; foreach($p in $dn.PSObject.Properties){ $dnm[$p.Name]=$p.Value }
$bidMap=@{}
foreach($p in $mapNew.PSObject.Properties){ $bidMap[$p.Name] = @{ bid=$p.Value.bid; gpu=[double]$p.Value.gpu } }
foreach($m in $mapOldM){ if(-not $bidMap.ContainsKey($m.item)){ $bidMap[$m.item] = @{ bid=$m.board_id; gpu=[double]$m.grams_per_unit } } }

$costIdx=@{}; foreach($c in $costed){ $costIdx[$c.proposed_name]=$c }

$LB=453.592; $OZ=28.3495
function Slugify([string]$s){
  $t = $s.ToLower() -replace '\([^)]*\)','' -replace '&','and' -replace '[^a-z0-9 ]','' -replace '\s+','-'
  $t.Trim('-')
}
function Den([string]$item,[string]$u){ if($dnm.ContainsKey($item) -and ($dnm[$item].PSObject.Properties.Name -contains $u)){ [double]$dnm[$item].$u } else { $null } }
function Frac([double]$v){
  # friendly quantity: quarters for small, 1dp for lb
  $r=[Math]::Round($v*4)/4
  if($r -eq [Math]::Floor($r)){ return ([string][int]$r) }
  return $r.ToString('0.##')
}
function FriendlyAmt([string]$item,[double]$g){
  # returns display amount string (without grams)
  if($item -match 'Chicken|Beef|Turkey($|[^ ])|Pork|Sausage|Chorizo|Bacon'){ return ((Frac ($g/$LB)) + ' lb') }
  if($item -eq 'Rice'){ return ((Frac ($g/185.0)) + ' cups dry') }
  if($item -eq 'Eggs'){ return ([string][int][Math]::Round($g/50.0) + ' large eggs') }
  if($item -match 'Pasta|Spaghetti|Ziti|Fettuccine|Orzo|Noodles|Gnocchi|Tortellini|Shells'){ return ((Frac ($g/$OZ)) + ' oz dry') }
  if($item -match 'Cheese|Mozzarella|Cheddar|Feta|Parmesan|Ricotta'){ return ((Frac ($g/$OZ)) + ' oz') }
  $can = Den $item 'can'
  if($can -and $g -ge ($can*0.85)){ $n=[Math]::Round($g/$can,1); if([Math]::Abs($n-[Math]::Round($n)) -lt 0.15){ $n=[Math]::Round($n) }; return ("$n can" + $(if($n -ne 1){'s'})) }
  $each = Den $item 'each'
  if($each -and $each -ge 40 -and $g -ge ($each*0.6)){ $n=[Math]::Round($g/$each,1); if([Math]::Abs($n-[Math]::Round($n)) -lt 0.25){ $n=[Math]::Round($n) }; return ("$n") }
  $tb = Den $item 'tbsp'
  if($tb -and $g -lt 120){ return ((Frac ($g/$tb)) + ' tbsp') }
  $cup = Den $item 'cup'
  if($cup){ return ((Frac ($g/$cup)) + ' cups') }
  return ((Frac ($g/$OZ)) + ' oz')
}
function GpuStr([double]$v){ $v.ToString('0.000') }

# display-name overrides (slug/prose keys unchanged; fixes name-vs-ingredients mismatches)
$NAME_OVERRIDES = @{ 'Turkey Kofta Rice Bowl with Tahini Sauce' = 'Turkey Kofta Bowls with Tahini Sauce' }

$slugSeen=@{}
foreach($s in $existing113){ $slugSeen[$s]=1 }
if(-not (Test-Path (Join-Path $here 'specs'))){ New-Item -ItemType Directory (Join-Path $here 'specs') | Out-Null }

$index=@()
foreach($r in $computed){
  $cost = $costIdx[$r.proposed_name]
  if(-not $cost){ throw ('no cost row for ' + $r.proposed_name) }
  $slug = Slugify $r.proposed_name
  $n=2; while($slugSeen.ContainsKey($slug)){ $slug = (Slugify $r.proposed_name) + '-' + $n; $n++ }
  $slugSeen[$slug]=1

  $costLines=@{}; foreach($l in $cost.lines){ $costLines[$l.item]=$l }

  # display list: substantive items (>=15g or >=$0.15 util), spices folded into pantry line
  $display=@(); $scalerIng=@(); $pantryItems=@(); $pantryUtil=0.0
  foreach($ing in $r.ingredients){
    if($ing.grams -le 0){ continue }
    $cl = $costLines[$ing.item]
    $util = 0.0; if($cl){ $util=[double]$cl.util_cost }
    $isSpice = ($ing.item -match 'Salt|Pepper$|Powder$|Paprika|Cumin|Coriander|Turmeric|Masala|Cinnamon|Cloves|Allspice|Nutmeg|Oregano|Thyme|Basil$|Dill|Parsley|Bay Leaves|Flakes|Seasoning$|Five-Spice|Cayenne|Italian Seasoning')
    $d = $dbm[$ing.item]
    $brand = ''; if($d -and $d.brand -and $d.brand -notmatch '^fresh$|store'){ $brand = ' (' + (($d.brand -split '/')[0].Trim()) + ')' }
    # COST folds pantry staples into one "Pantry seasonings" line, but the INGREDIENTS list must still
    # itemize every one (2026-07-26 fix: the list omitted salt/pepper/spices the recipe actually needs).
    if($isSpice -or ($ing.grams -lt 15 -and $util -lt 0.15)){
      $pantryItems += $ing.item.ToLower(); $pantryUtil += $util
    }
    $display += ('<strong>' + $ing.item + $brand + ':</strong> ' + (FriendlyAmt $ing.item $ing.grams) + ' (' + [int]$ing.grams + ' g)')
    # scaler entry (ALL items)
    $se = [ordered]@{ item=$ing.item; grams=[int]$ing.grams; buy=(FriendlyAmt $ing.item $ing.grams) }
    if($bidMap.ContainsKey($ing.item)){ $se.bid=$bidMap[$ing.item].bid; $se.gpu=(GpuStr $bidMap[$ing.item].gpu) }
    $scalerIng += [pscustomobject]$se
  }

  # cost section lines (printed sum must equal batch; buy contributions must sum to true)
  $costHtml=@(); $sumUtil=0.0; $sumTrue=0.0
  foreach($ing in $r.ingredients){
    $cl = $costLines[$ing.item]; if(-not $cl){ continue }
    $util=[double]$cl.util_cost
    $isPantry = ($pantryItems -contains $ing.item.ToLower())
    if($isPantry){ continue }
    $sumUtil += $util
    $amt = FriendlyAmt $ing.item $ing.grams
    if($cl.bulk){
      $sumTrue += $util
      $costHtml += ($ing.item + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Buy 1 (lasts several batches).</strong>')
    } elseif($cl.buy_cost){
      $sumTrue += [double]$cl.buy_cost
      $pkgTxt = $cl.pkg; if(-not $pkgTxt){ $pkgTxt='pack' }
      $costHtml += ($ing.item + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Buy ' + $cl.buy_n + ' ' + $pkgTxt + $(if($cl.buy_n -gt 1){'s'}) + ': $' + ([double]$cl.buy_cost).ToString('0.00') + '.</strong>')
    } else {
      $sumTrue += $util
      $costHtml += ($ing.item + ', ' + $amt + ': ~$' + $util.ToString('0.00') + '. <strong>Buy as needed.</strong>')
    }
  }
  # pantry fold line
  $pantryTrue = 0.0
  foreach($ing in $r.ingredients){
    $cl = $costLines[$ing.item]; if(-not $cl){ continue }
    if($pantryItems -contains $ing.item.ToLower()){
      $sumUtil += [double]$cl.util_cost
      $add = if($cl.bulk -or -not $cl.buy_cost){ [double]$cl.util_cost } else { [double]$cl.buy_cost }
      $sumTrue += $add; $pantryTrue += [double]$cl.util_cost
    }
  }
  if($pantryItems.Count -gt 0){
    $pl = ($pantryItems | Select-Object -Unique) -join ', '
    $costHtml += ('Pantry seasonings (' + $pl + '): ~$' + $pantryUtil.ToString('0.00') + '. <strong>From jars you keep on hand.</strong>')
  }
  $batch=[Math]::Round($sumUtil,2); $trueC=[Math]::Round($sumTrue,2)
  $cps = [Math]::Round($batch/14,2); $cpsTrue=[Math]::Round($trueC/14,2)
  # three cost views, each labeled with exactly what it assumes (Brad 2026-07-19):
  #   batch = ingredient value used; true = register trip with a stocked pantry; first run = empty pantry
  $pantryAdd=[double]$cost.cost_pantry_add; $firstRun=[double]$cost.cost_first_run
  # the printed first-run line references the printed true cost; both must come from the SAME sums
  if([Math]::Abs($batch-[double]$cost.cost_batch) -gt 0.005){ throw ($r.proposed_name + ': spec batch ' + $batch + ' != engine ' + $cost.cost_batch) }
  if([Math]::Abs($trueC-[double]$cost.cost_batch_true) -gt 0.005){ throw ($r.proposed_name + ': spec true ' + $trueC + ' != engine ' + $cost.cost_batch_true) }
  if([Math]::Abs(($trueC+$pantryAdd)-$firstRun) -gt 0.005){ throw ($r.proposed_name + ': first_run ' + $firstRun + ' != true+add ' + ($trueC+$pantryAdd)) }
  $costHtml += ('<strong>Batch total: about $' + $batch.ToString('0.00') + ' across 14 servings, so roughly $' + $cps.ToString('0.00') + ' per bowl.</strong> This counts only the amounts this batch actually uses from each package, so it is the cost of the food in the containers, not a register receipt.')
  $costHtml += ('<strong>True shopping cost: about $' + $trueC.ToString('0.00') + ' across 14 servings, roughly $' + $cpsTrue.ToString('0.00') + ' per bowl.</strong> What the register trip looks like if your pantry is already stocked. Meat, produce, and packaged items are counted as the whole packages you have to buy, since you cannot grab a partial box, can, or jar. Pantry staples you already own (rice, seasonings, oils, and long-lasting sauces) are counted at only what this batch uses.')
  if($pantryAdd -gt 0){
    $costHtml += ('<strong>Starting with an empty pantry? Add about $' + $pantryAdd.ToString('0.00') + ' one time.</strong> That is the extra cost of buying full containers of every pantry staple in this recipe instead of just the amounts used, which puts a first shopping trip near $' + $firstRun.ToString('0.00') + '. Those containers then feed this batch and many more after it.')
  }

  $dispName = $r.proposed_name
  if($NAME_OVERRIDES.ContainsKey($dispName)){ $dispName = $NAME_OVERRIDES[$dispName] }
  $spec = [ordered]@{
    name = $dispName
    slug = $slug
    cuisine = $r.cuisine
    protein = $r.protein
    visibility = 'paid'
    source_url = $r.source_url
    source_site = $r.source_site
    manual_balance = ([bool]($r.tuning -match 'RICH-DISH'))
    tuning = @($r.tuning)
    stat = [ordered]@{ cal=[int]$r.per_serving.calories; protein=[int][Math]::Round($r.per_serving.protein_g,0); carbs=[int][Math]::Round($r.per_serving.carbs_g,0); fat=[int][Math]::Round($r.per_serving.fat_g,0); cost_ps=$cps.ToString('0.00') }
    intro_html = ''
    ingredients_display = @($display)
    cost_note_html = 'Real Omaha store prices from our weekly grocery board (2026). They still swing by store and by what is on sale.'
    cost_lines = @($costHtml)
    cost_closing_html = ''
    shop_smart = @()
    make_it = @()
    portion_html = ''
    credit_html = ('Recipe adapted from <a href="' + $r.source_url + '" target="_blank" rel="noopener">' + $r.source_site + '</a>, rebuilt for 14-serving budget meal prep with weighed portions and Omaha pricing.')
    upsell_html = ''
    cost_batch = $batch
    cost_batch_true = $trueC
    cost_per_serving = $cps
    cost_per_serving_true = $cpsTrue
    cost_pantry_add = [Math]::Round($pantryAdd,2)
    cost_first_run = [Math]::Round($firstRun,2)
    scaler = [ordered]@{ cost=$trueC.ToString('0.00'); ing=@($scalerIng) }
    head = [ordered]@{ description=''; keywords=''; image=''; prepTime=''; cookTime=''; totalTime=''; costPerServing=$cps; recipeIngredient=@(); steps=@() }
    ingredients_grams = @($r.ingredients | ForEach-Object { [pscustomobject]@{ item=$_.item; grams=[int]$_.grams } })
  }
  $spec | ConvertTo-Json -Depth 8 | Out-File (Join-Path $here ('specs\' + $slug + '.json')) -Encoding utf8
  $index += [pscustomobject]@{ slug=$slug; name=$r.proposed_name; protein=$r.protein; cuisine=$r.cuisine; cal=$r.per_serving.calories; cost=$cps; manual_balance=([bool]($r.tuning -match 'RICH-DISH')) }
}
$index | ConvertTo-Json -Depth 4 | Out-File (Join-Path $here 'specs\_index.json') -Encoding utf8
Write-Output ("built {0} spec skeletons -> specs\  (manual-balance: {1})" -f $index.Count, (@($index | Where-Object { $_.manual_balance }).Count))
