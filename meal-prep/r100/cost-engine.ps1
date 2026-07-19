# cost-engine.ps1 - Everyday cost + TRUE shopping cost per recipe (R100).
# Price sources, in order: (1) board Walmart everyday price via r100-board-map / ingredient-map (verified),
# (2) agent label package prices (labels-P1/P2/P3) for untracked items.
# Invariants (house rules from the 90-run):
#   batch total = EXACT sum of per-line util costs; per-serving = batch/14
#   true cost   = sum of per-line contributions where package items round UP to whole packages
#                 and bulk/pantry items stay at utilization; true >= batch always.
# Output: recipes-costed.json + cost-flags.txt (any item without a price basis = HARD FLAG, never guessed).
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$computed = Get-Content (Join-Path $here 'recipes-computed.json') -Raw | ConvertFrom-Json
$cmpFile = Get-ChildItem (Join-Path $here '..\..\grocery\out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
$cmp = (Get-Content $cmpFile.FullName -Raw | ConvertFrom-Json).comparison
$mapNew = (Get-Content (Join-Path $here 'r100-board-map.json') -Raw | ConvertFrom-Json).map
$mapOld = (Get-Content (Join-Path $here '..\ingredient-map.json') -Raw | ConvertFrom-Json).mappings

$LB=453.592; $OZ=28.3495

# board rows by id -> walmart (preferred) or cheapest nomem price per unit (row UNIT kept for reconciliation)
$board=@{}
foreach($row in $cmp){
  $wm = $row.stores | Where-Object { $_.store -eq 'Walmart' } | Select-Object -First 1
  $p = $null; $src=''
  if($wm -and $wm.per_unit -gt 0){ $p=[double]$wm.per_unit; $src='walmart' }
  elseif($row.nomem_price -gt 0){ $p=[double]$row.nomem_price; $src=('nomem:'+$row.nomem_store) }
  if($p){ $board[$row.id] = @{ per_unit=$p; unit=[string]$row.unit; src=$src } }
}

# UNIT RECONCILIATION (2026-07-19, the brown-sugar 16x lesson): a map's gpu was calibrated against the
# board unit of ITS era; boards re-register commodities with new units (recipe-board oz -> weekly lb).
# For standard weight/volume units, rescale gpu to the CURRENT row unit; anything else must match exactly.
$UNIT_G=@{ lb=453.592; oz=28.3495; floz=29.57; kg=1000.0; g=1.0 }
function Resolve-Gpu([double]$gpu,[string]$mapUnit,[string]$rowUnit){
  if(-not $mapUnit -or -not $rowUnit -or $mapUnit -eq $rowUnit){ return $gpu }
  if($UNIT_G.ContainsKey($mapUnit) -and $UNIT_G.ContainsKey($rowUnit)){ return $gpu * ($UNIT_G[$rowUnit]/$UNIT_G[$mapUnit]) }
  return -1.0   # non-standard mismatch: caller must hard-flag
}

# recipe board (the 90-run's own verified per-store data; ids like pork-loin live ONLY here).
# Same walmart-preferred rule as the weekly board; never overrides a weekly-board id.
$rbFile = Join-Path $here '..\..\grocery\out\recipe-board.json'
if(Test-Path $rbFile){
  $rb = (Get-Content $rbFile -Raw | ConvertFrom-Json).comparison
  foreach($row in $rb){
    if($board.ContainsKey($row.id)){ continue }
    $wm = $row.stores | Where-Object { $_.store -eq 'Walmart' } | Select-Object -First 1
    $p=$null; $src=''
    if($wm -and $wm.per_unit -gt 0){ $p=[double]$wm.per_unit; $src='recipeboard-walmart' }
    elseif($row.cheapest_price -gt 0){ $p=[double]$row.cheapest_price; $src=('recipeboard-cheapest:'+$row.cheapest_store) }
    if($p){ $board[$row.id] = @{ per_unit=$p; unit=$row.unit; src=$src } }
  }
}

# smp-feed (recipe-board ingredient prices, our own verified data - what the live widgets use)
$feed = (Get-Content (Join-Path $here '..\..\grocery\out\smp-feed.json') -Raw | ConvertFrom-Json).ingredients
$feedMap=@{}
if($feed){ foreach($p in $feed.PSObject.Properties){ if($p.Value.cheapest -gt 0){ $feedMap[$p.Name] = @{ per_unit=[double]$p.Value.cheapest; unit=$p.Value.unit } } } }

# pantry starter packages: whole-container size per BULK item (empty-pantry one-time stock-up)
$pantryPkg=@{}
foreach($p in ((Get-Content (Join-Path $here 'pantry-packages.json') -Raw | ConvertFrom-Json).packages).PSObject.Properties){
  $pantryPkg[$p.Name] = @{ g=[double]$p.Value.g; label=[string]$p.Value.label }
}

# canonical item -> board id + gpu + the unit that gpu was calibrated against (new map first, then the 90-run map)
$itemBoard=@{}
foreach($p in $mapNew.PSObject.Properties){ $itemBoard[$p.Name] = @{ bid=$p.Value.bid; gpu=[double]$p.Value.gpu; unit=[string]$p.Value.unit } }
foreach($m in $mapOld){ if(-not $itemBoard.ContainsKey($m.item)){ $itemBoard[$m.item] = @{ bid=$m.board_id; gpu=[double]$m.grams_per_unit; unit=[string]$m.unit } } }

# label package prices (P1/P2/P3): item -> pkg grams + price
function SizeToGrams([string]$s){
  $s=$s.ToLower()
  if($s -match '([\d.]+)\s*(fl\.? ?oz|floz)'){ return [double]$Matches[1]*29.57 }
  if($s -match '([\d.]+)\s*oz'){ return [double]$Matches[1]*$OZ }
  if($s -match '([\d.]+)\s*lb'){ return [double]$Matches[1]*$LB }
  if($s -match '([\d.]+)\s*kg'){ return [double]$Matches[1]*1000 }
  if($s -match '([\d.]+)\s*g\b'){ return [double]$Matches[1] }
  return $null
}
$labels=@{}
foreach($f in @('labels-P1.json','labels-P2.json','labels-P3.json')){
  foreach($r in (Get-Content (Join-Path $here $f) -Raw | ConvertFrom-Json)){
    $nm = $r.item
    if($nm -match '^Pasta Shells'){ $nm='Pasta Shells' }
    if($nm -match '^Chili Crisp'){ $nm='Chili Crisp' }
    if($null -eq $r.package_price_usd -or $r.package_price_usd -le 0){ continue }
    $g = SizeToGrams ([string]$r.package_size)
    if(-not $g){ continue }
    if(-not $labels.ContainsKey($nm)){ $labels[$nm] = @{ pkg_g=$g; pkg_price=[double]$r.package_price_usd; desc=($r.brand + ' ' + $r.package_size) } }
  }
}

# BULK/pantry items: counted at utilization in the true cost (one container covers several batches)
$BULK = @('Salt','Black Pepper','Garlic Powder','Onion Powder','Paprika','Smoked Paprika','Cayenne Pepper','Chili Powder','Ground Cumin','Ground Coriander','Ground Turmeric','Garam Masala','Curry Powder','Five-Spice Powder','Ground Cinnamon','Ground Cloves','Ground Allspice','Ground Nutmeg','Ground Ginger','Dried Oregano','Dried Thyme','Dried Basil','Dried Dill','Dried Parsley','Bay Leaves','Red Pepper Flakes','Italian Seasoning','Cajun Seasoning','Berbere Seasoning','Taco Seasoning','Fajita Seasoning','Ranch Seasoning Mix',
'Olive Oil','Vegetable Oil','Sesame Oil','White Vinegar','Red Wine Vinegar','Apple Cider Vinegar','Rice Vinegar','Balsamic Vinegar',
'Soy Sauce','Fish Sauce','Oyster Sauce','Worcestershire Sauce','Hoisin Sauce','Mirin','Sriracha','Hot Sauce','Ketchup','Dijon Mustard','BBQ Sauce','BBQ Sauce (Sugar Free)','Buffalo Wing Sauce','Honey','Hot Honey','Sugar-Free Maple Syrup','Gochujang','Chili Crisp','Tahini','Peanut Butter','Teriyaki Sauce','Lemongrass Paste','Pomegranate Molasses','Achiote Paste','Harissa Paste','Miso Paste','Sweet Chili Sauce','Liquid Smoke',
'All-Purpose Flour','Sugar','Brown Sugar','Cornstarch','Bread Crumbs','Rice','Grits','Lemon Juice','Lime Juice','Mayonnaise','Golden Raisins','Toasted Sesame Seeds','Poppy Seeds','Sun-Dried Tomatoes','Dill Pickles','Chicken Broth','Beef Broth','Red Wine','Butter Crackers','Chipotle in Adobo','Diced Green Chiles')

# package definitions for board-priced items (grams per package + how price maps)
# board price is per unit (lb/oz/floz/each/dozen); package = typical Walmart pack.
$PKG = @{
  'Boneless Skinless Chicken Breast'=@{g=$LB;label='lb'}; 'Boneless Skinless Chicken Thigh'=@{g=$LB;label='lb'}
  '93/7 Ground Beef'=@{g=$LB;label='lb'}; '93/7 Ground Turkey'=@{g=$LB;label='lb'}; 'Ground Pork'=@{g=$LB;label='lb'}
  'Pork Chops'=@{g=$LB;label='lb'}; 'Pork Tenderloin'=@{g=$LB;label='lb'}; 'Pork Loin'=@{g=$LB;label='lb'}
  'Hot Italian Sausage'=@{g=$LB;label='lb'}; 'Hickory Smoked Bacon'=@{g=$LB;label='lb'}
  'Eggs'=@{g=600;label='dozen'}
  'Butter'=@{g=$LB;label='lb box'}
  'Heavy Cream'=@{g=473;label='pint'}
  'Milk'=@{g=3785;label='gallon'}
  'Light Sour Cream'=@{g=454;label='16oz tub'}
  'Greek Yogurt'=@{g=907;label='32oz tub'}
  '1/3 Fat Cream Cheese'=@{g=227;label='8oz brick'}
  'Cheddar Cheese, Shredded'=@{g=227;label='8oz bag'}; 'Reduced Fat Mozzarella'=@{g=227;label='8oz bag'}
  'Mexican Cheese Blend'=@{g=227;label='8oz bag'}; 'Feta Cheese'=@{g=170;label='6oz tub'}
  'Parmesan Cheese'=@{g=227;label='8oz tub'}; 'Cottage Cheese'=@{g=680;label='24oz tub'}
  'Penne Pasta'=@{g=454;label='16oz box'}; 'Rotini Pasta'=@{g=454;label='16oz box'}
  'Spaghetti'=@{g=454;label='16oz box'}; 'Ziti Pasta'=@{g=454;label='16oz box'}
  'Fettuccine'=@{g=454;label='16oz box'}; 'Orzo Pasta'=@{g=454;label='16oz box'}
  'Pasta Shells'=@{g=340;label='12oz box'}; 'Egg Noodles'=@{g=340;label='12oz bag'}
  'Frozen Hash Browns'=@{g=737;label='26oz bag'}
  'Potato'=@{g=$LB;label='lb'}; 'Sweet Potatoes'=@{g=$LB;label='lb'}
  'Yellow Onion'=@{g=$LB;label='lb'}; 'Red Onion'=@{g=$LB;label='lb'}; 'Jalapeno'=@{g=$LB;label='lb'}
  'Green Onions'=@{g=90;label='bunch'}; 'Cucumber'=@{g=300;label='each'}; 'Celery'=@{g=450;label='bunch'}
  'Fresh Cilantro'=@{g=57;label='bunch'}
  'Carrots'=@{g=$LB;label='lb'}; 'Zucchini'=@{g=$LB;label='lb'}; 'Green Cabbage'=@{g=900;label='head'}
  'Green Bell Peppers'=@{g=120;label='each'}; 'Red Bell Pepper'=@{g=120;label='each'}; 'Poblano Peppers'=@{g=$LB;label='lb'}
  'White Mushrooms'=@{g=227;label='8oz pack'}; 'Broccoli Florets'=@{g=340;label='12oz bag'}
  'Frozen Chopped Spinach'=@{g=284;label='10oz box'}; 'Frozen Green Peas'=@{g=340;label='12oz bag'}; 'Green Beans'=@{g=340;label='12oz bag'}
  'Cherry Tomatoes'=@{g=283;label='10oz clamshell'}
  'Diced Tomatoes'=@{g=411;label='can'}; 'Crushed Tomatoes'=@{g=794;label='28oz can'}; 'Tomato Sauce'=@{g=425;label='15oz can'}
  'Tomato Paste'=@{g=170;label='6oz can'}; 'Diced Tomatoes & Green Chilies'=@{g=283;label='10oz can'}
  'Sweet Whole Kernel Corn'=@{g=432;label='can'}; 'Seasoned Black Beans'=@{g=425;label='can'}; 'Kidney Beans'=@{g=425;label='can'}
  'Chickpeas'=@{g=425;label='can'}; 'Cannellini Beans'=@{g=425;label='can'}; 'Hominy'=@{g=425;label='can'}
  'Coconut Milk'=@{g=400;label='13.5oz can'}; 'Enchilada Sauce'=@{g=283;label='10oz can'}
  'Marinara Sauce'=@{g=680;label='24oz jar'}; 'Traditional Pasta Sauce'=@{g=680;label='24oz jar'}; 'Alfredo Sauce'=@{g=425;label='15oz jar'}
  'Salsa'=@{g=454;label='16oz jar'}; 'Salsa Verde'=@{g=454;label='16oz jar'}
  'Olives'=@{g=170;label='6oz can'}; 'Roasted Red Peppers'=@{g=340;label='12oz jar'}; 'Pineapple Chunks'=@{g=567;label='20oz can'}
  'Tomatillos'=@{g=$LB;label='lb'}; 'Hummus'=@{g=283;label='10oz tub'}
  'Tortilla'=@{g=300;label='10ct pack'}
  'Frozen Green Peas '=@{g=340;label='bag'}
  'Fresh Basil'=@{g=14;label='0.5oz pack'}; 'Fresh Mint'=@{g=14;label='0.5oz pack'}
  'Walnuts'=@{g=227;label='8oz bag'}; 'Peanuts'=@{g=454;label='16oz jar'}; 'Cashews'=@{g=227;label='8oz can'}
  'Garlic'=@{g=40;label='head'}; 'Ginger'=@{g=100;label='piece'}
  'Potato Gnocchi'=@{g=499;label='17.6oz pack'}; 'Cheese Tortellini'=@{g=539;label='19oz bag'}
  'Rice Noodles'=@{g=397;label='14oz box'}; 'Lo Mein Noodles'=@{g=397;label='14oz pack'}
  'Pork Chorizo'=@{g=255;label='9oz tube'}; 'Smoked Turkey Sausage'=@{g=368;label='13oz rope'}
  'Ricotta Cheese'=@{g=425;label='15oz tub'}
  'Refrigerated Biscuits'=@{g=462;label='8ct can'}; 'Corn Muffin Mix'=@{g=241;label='box'}
  'Corn Chips'=@{g=262;label='9.25oz bag'}; 'Grits'=@{g=680;label='24oz canister'}
  'Japanese Curry Roux'=@{g=92;label='3.2oz box'}; 'Red Curry Paste'=@{g=113;label='4oz jar'}
  'Mole Paste'=@{g=234;label='8.25oz jar'}; 'Golden Raisins '=@{g=340;label='bag'}
  'Sugar-Free Maple Syrup '=@{g=340;label='bottle'}; 'Swiss Cheese'=@{g=227;label='8oz'}
  'Orange Juice'=@{g=1560;label='52floz carton'}
}

$out=@(); $costFlags=New-Object System.Collections.Generic.List[string]
foreach($r in $computed){
  $lines=@(); $batch=0.0; $trueCost=0.0; $bulkUtil=0.0; $starterOutlay=0.0
  foreach($ing in $r.ingredients){
    $g=[double]$ing.grams
    if($g -le 0){ continue }
    $ppg=$null; $basis=''
    if($itemBoard.ContainsKey($ing.item)){
      $b=$itemBoard[$ing.item]
      if($board.ContainsKey($b.bid)){
        $eg = Resolve-Gpu $b.gpu $b.unit $board[$b.bid].unit
        if($eg -le 0){ $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: UNIT MISMATCH ' + $b.unit + ' vs ' + $board[$b.bid].unit)); continue }
        $ppg = $board[$b.bid].per_unit / $eg; $basis=('board:'+$b.bid+':'+$board[$b.bid].src)
      }
      elseif($feedMap.ContainsKey($b.bid)){
        $eg = Resolve-Gpu $b.gpu $b.unit $feedMap[$b.bid].unit
        if($eg -le 0){ $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: UNIT MISMATCH ' + $b.unit + ' vs feed ' + $feedMap[$b.bid].unit)); continue }
        $ppg = $feedMap[$b.bid].per_unit / $eg; $basis=('feed:'+$b.bid)
      }
    }
    if($null -eq $ppg -and $labels.ContainsKey($ing.item)){
      $L=$labels[$ing.item]; $ppg = $L.pkg_price/$L.pkg_g; $basis=('label:'+$L.desc)
    }
    if($null -eq $ppg){
      $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: NO PRICE BASIS')); continue
    }
    $util = [Math]::Round($g*$ppg,2)
    $batch += $util
    $isBulk = $BULK -contains $ing.item
    $buyN=$null; $buyCost=$null; $pkgLabel=$null; $stN=$null; $stCost=$null; $stPkg=$null
    if($isBulk){
      $trueCost += $util
      # empty-pantry starter: whole container(s) of this staple at the same price basis
      if($pantryPkg.ContainsKey($ing.item)){
        $pp=$pantryPkg[$ing.item]
        $stN=[Math]::Ceiling(($g/$pp.g) - 0.02); if($stN -lt 1){ $stN=1 }
        $stCost=[Math]::Round($stN*$pp.g*$ppg,2)
        if($stCost -lt $util){ $stCost=$util }
        $stPkg=$pp.label
        $bulkUtil += $util; $starterOutlay += $stCost
      } else {
        # never guess: a bulk item without a pantry package is a hard flag, counted at util
        $bulkUtil += $util; $starterOutlay += $util
        $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: BULK ITEM WITHOUT PANTRY PACKAGE DEF'))
      }
    } else {
      # package rounding
      $pg=$null
      if($PKG.ContainsKey($ing.item)){ $pg=$PKG[$ing.item] }
      elseif($labels.ContainsKey($ing.item)){ $pg=@{g=$labels[$ing.item].pkg_g; label=$labels[$ing.item].desc} }
      if($pg){
        $pkgPrice = $pg.g*$ppg
        $buyN = [Math]::Ceiling(($g/$pg.g) - 0.02)   # 2% tolerance for rounding noise
        if($buyN -lt 1){ $buyN = 1 }
        $buyCost = [Math]::Round($buyN*$pkgPrice,2)
        if($buyCost -lt $util){ $buyCost = $util }
        $trueCost += $buyCost
        $pkgLabel = $pg.label
      } else {
        $trueCost += $util
        $costFlags.Add(($r.proposed_name + ' :: ' + $ing.item + ' :: no package def, counted at util in true cost'))
      }
    }
    $lines += [pscustomobject]@{ item=$ing.item; grams=$g; util_cost=$util; basis=$basis; bulk=$isBulk; buy_n=$buyN; buy_cost=$buyCost; pkg=$pkgLabel; starter_n=$stN; starter_cost=$stCost; starter_pkg=$stPkg }
  }
  $batch=[Math]::Round($batch,2); $trueCost=[Math]::Round($trueCost,2)
  # empty-pantry math (exact): first run = true cost with each pantry staple upgraded from
  # utilization to whole container(s); pantry_add is the one-time extra over the true cost.
  $pantryAdd=[Math]::Round($starterOutlay-$bulkUtil,2)
  if($pantryAdd -lt 0){ $pantryAdd=0.0 }
  $firstRun=[Math]::Round($trueCost+$pantryAdd,2)
  $out += [pscustomobject]@{
    proposed_name=$r.proposed_name
    cost_batch=$batch; cost_per_serving=[Math]::Round($batch/14,2)
    cost_batch_true=$trueCost; cost_per_serving_true=[Math]::Round($trueCost/14,2)
    cost_pantry_add=$pantryAdd; cost_first_run=$firstRun
    lines=@($lines)
  }
}
$out | ConvertTo-Json -Depth 7 | Out-File (Join-Path $here 'recipes-costed.json') -Encoding utf8
$costFlags | Out-File (Join-Path $here 'cost-flags.txt') -Encoding utf8
$cps = $out | ForEach-Object { $_.cost_per_serving }
Write-Output ("costed {0} recipes; flags {1}; per-serving range \${2}-\${3} avg \${4}" -f $out.Count, $costFlags.Count, (($cps|Measure-Object -Minimum).Minimum), (($cps|Measure-Object -Maximum).Maximum), ([Math]::Round(($cps|Measure-Object -Average).Average,2)))
$bad = @($out | Where-Object { $_.cost_batch_true -lt $_.cost_batch })
Write-Output ("true<batch violations: " + $bad.Count)
$bad2 = @($out | Where-Object { $_.cost_first_run -lt $_.cost_batch_true })
Write-Output ("firstrun<true violations: " + $bad2.Count)
