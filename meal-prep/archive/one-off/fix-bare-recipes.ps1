<#
  fix-bare-recipes.ps1 - Second wave: 4 recipes found by a generic "zero seasoning ingredient" proxy (not
  name-matching) to be missing their ENTIRE seasoning/aromatic profile vs their real source recipe. Mints 5
  new commodities (Salt, Black Pepper, Fresh Cilantro, Jalapeno, Liquid Smoke) priced via Family Fare, adds
  the confirmed-missing ingredients to each recipe (reusing already-tracked commodities where applicable:
  Garlic, Ground Cumin, Dried Oregano, Chili Powder, Chicken Broth, Lime Juice, Poblano Peppers, Orange
  Juice), recomputes cost. Additive only - does not remove any existing ingredient.
#>
$ErrorActionPreference = 'Stop'
$mp = $PSScriptRoot
$g  = Join-Path (Split-Path $mp -Parent) 'grocery'

$newCommodities = @(
  @{ id='salt';           commodity='Salt';           unit='oz';   price=0.99; per_unit=0.0381; size='26 oz';   item='Iodized Salt Our Family'; url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/salt_pepper/iodized_salt_our_family/p/6787156'; category='Spices & Baking'; gpu=28.3495 },
  @{ id='black-pepper';   commodity='Black Pepper';   unit='oz';   price=1.39; per_unit=0.695;  size='2 oz';    item="That's Smart! Ground Black Pepper"; url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/salt_pepper/that_s_smart_ground_black_pepper/p/1564405684704741125'; category='Spices & Baking'; gpu=28.3495 },
  @{ id='fresh-cilantro'; commodity='Fresh Cilantro'; unit='each'; price=0.99; per_unit=0.99;   size='1 ct';    item='Cilantro (Chinese Parsley/Coriander)'; url='https://www.shopfamilyfare.com/shop/fresh_fruits_vegetables/fresh_spices_herbs/cilantro_chinese_parsley_coriander/p/78771'; category='Produce'; gpu=28 },
  @{ id='jalapeno';       commodity='Jalapeno Pepper';unit='lb';   price=2.29; per_unit=2.29;   size='lb';      item='Jalapeno Peppers'; url='https://www.shopfamilyfare.com/shop/fresh_fruits_vegetables/peppers/jalapeno_peppers/p/12548'; category='Produce'; gpu=453.592 },
  @{ id='liquid-smoke';   commodity='Liquid Smoke';   unit='floz'; price=3.49; per_unit=0.8725; size='4 fl oz';item='Colgin Original Recipe Hickory Liquid Smoke 4 Fl Oz'; url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/marinades/colgin_original_recipe_hickory_liquid_smoke_4_fl_oz/p/38455'; category='Sauces & Condiments'; gpu=29.57 }
)

$bevF = Join-Path $g 'out\recipe-board-everyday.json'
$bev = Get-Content $bevF -Raw | ConvertFrom-Json
$existing = @{}; foreach ($r in $bev.comparison) { $existing[[string]$r.id] = $true }
$puF = Join-Path $g 'product-urls.json'
$pu = Get-Content $puF -Raw | ConvertFrom-Json
$mapF = Join-Path $mp 'ingredient-map.json'
$map = Get-Content $mapF -Raw | ConvertFrom-Json
$mapList = [System.Collections.Generic.List[object]]::new(); foreach ($m in $map.mappings) { $mapList.Add($m) }

foreach ($c in $newCommodities) {
  if ($existing.ContainsKey($c.id)) { Write-Output ("(already exists, skip mint: " + $c.id + ")"); continue }
  $store = [pscustomobject]@{ store='Family Fare'; per_unit=$c.per_unit; unit=$c.unit; type='everyday'; bulk=$false; membership=$false; item=$c.item; size=$c.size }
  $row = [pscustomobject]@{ id=$c.id; commodity=$c.commodity; unit=$c.unit; category=$c.category; cheapest_store='Family Fare'; cheapest_price=$c.per_unit; cheapest_type='everyday'; stores=@($store) }
  $bev.comparison = @($bev.comparison) + $row
  if (-not $pu.items.PSObject.Properties[$c.id]) { $pu.items | Add-Member -NotePropertyName $c.id -NotePropertyValue ([pscustomobject]@{ commodity=$c.commodity }) }
  $pu.items.($c.id) | Add-Member -NotePropertyName 'Family Fare' -NotePropertyValue ([pscustomobject]@{ url=$c.url; price=$c.price; size=$c.size; name=$c.item }) -Force
  Write-Output ("minted: " + $c.id + " (" + $c.commodity + ") @ Family Fare $" + $c.price + " = $" + $c.per_unit + "/" + $c.unit)
}
($bev | ConvertTo-Json -Depth 8) | Set-Content $bevF -Encoding UTF8
($pu | ConvertTo-Json -Depth 6) | Set-Content $puF -Encoding UTF8

$newMapItems = @(
  @{ item='Salt'; board_id='salt'; gpu=28.3495; unit='oz' },
  @{ item='Black Pepper'; board_id='black-pepper'; gpu=28.3495; unit='oz' },
  @{ item='Fresh Cilantro'; board_id='fresh-cilantro'; gpu=28; unit='each' },
  @{ item='Jalapeno'; board_id='jalapeno'; gpu=453.592; unit='lb' },
  @{ item='Liquid Smoke'; board_id='liquid-smoke'; gpu=29.57; unit='floz' }
)
$mappedItems = @{}; foreach ($m in $mapList) { $mappedItems[[string]$m.item] = $true }
foreach ($nm in $newMapItems) { if ($mappedItems.ContainsKey($nm.item)) { continue }; $mapList.Add([pscustomobject]@{ item=$nm.item; board_id=$nm.board_id; board='recipe'; grams_per_unit=$nm.gpu; unit=$nm.unit }) }
$map.mappings = $mapList.ToArray()
($map | ConvertTo-Json -Depth 6) | Set-Content $mapF -Encoding UTF8
Write-Output ("ingredient-map: " + @($map.mappings).Count + " total mappings")

$feed = Get-Content (Join-Path (Split-Path $g -Parent) 'public\smp-feed.json') -Raw | ConvertFrom-Json
function PriceOf($id) { $e = $feed.ingredients.$id; if ($e) { return [double]$e.cheapest } else { return $null } }
$priceById = @{}
foreach ($c in $newCommodities) { $priceById[$c.id] = $c.per_unit }
foreach ($id in @('garlic','ground-cumin','dried-oregano','chili-powder','chicken-broth','limes','poblano-peppers','orange-juice')) { $p = PriceOf $id; if ($p) { $priceById[$id] = $p } }
$gpuAll = @{}
foreach ($c in $newCommodities) { $gpuAll[$c.id] = $c.gpu }
$gpuAll['garlic']=50; $gpuAll['ground-cumin']=28.3495; $gpuAll['dried-oregano']=28.3495; $gpuAll['chili-powder']=28.3495; $gpuAll['chicken-broth']=29.57; $gpuAll['limes']=30; $gpuAll['poblano-peppers']=453.592; $gpuAll['orange-juice']=29.57

# {slug, adds:[{item,grams,buy,board_id}]}
$fixes = @(
  @{ slug='slow-cooker-kalua-pork-bowls'; adds=@(
      @{ item='Salt'; grams=15; buy='2 tbsp'; board_id='salt' },
      @{ item='Liquid Smoke'; grams=15; buy='1 bottle'; board_id='liquid-smoke' }
  )},
  @{ slug='slow-cooker-white-chicken-chili-bowls'; adds=@(
      @{ item='Jalapeno'; grams=30; buy='1 jalapeno'; board_id='jalapeno' },
      @{ item='Garlic'; grams=12; buy='1 bulb'; board_id='garlic' },
      @{ item='Ground Cumin'; grams=8; buy='1 jar'; board_id='ground-cumin' },
      @{ item='Dried Oregano'; grams=4; buy='1 jar'; board_id='dried-oregano' },
      @{ item='Chili Powder'; grams=14; buy='1 jar'; board_id='chili-powder' },
      @{ item='Salt'; grams=10; buy='1 container'; board_id='salt' },
      @{ item='Black Pepper'; grams=4; buy='1 jar'; board_id='black-pepper' },
      @{ item='Chicken Broth'; grams=360; buy='1 carton'; board_id='chicken-broth' },
      @{ item='Lime Juice'; grams=60; buy='2 limes, juiced'; board_id='limes' },
      @{ item='Fresh Cilantro'; grams=28; buy='1 bunch'; board_id='fresh-cilantro' }
  )},
  @{ slug='slow-cooker-chicken-chile-verde-bowls'; adds=@(
      @{ item='Poblano Peppers'; grams=200; buy='1.5 poblano peppers'; board_id='poblano-peppers' },
      @{ item='Jalapeno'; grams=30; buy='1 jalapeno'; board_id='jalapeno' },
      @{ item='Garlic'; grams=12; buy='1 bulb'; board_id='garlic' },
      @{ item='Fresh Cilantro'; grams=28; buy='1 bunch'; board_id='fresh-cilantro' },
      @{ item='Lime Juice'; grams=60; buy='2 limes, juiced'; board_id='limes' },
      @{ item='Ground Cumin'; grams=8; buy='1 jar'; board_id='ground-cumin' },
      @{ item='Dried Oregano'; grams=4; buy='1 jar'; board_id='dried-oregano' },
      @{ item='Salt'; grams=10; buy='1 container'; board_id='salt' },
      @{ item='Black Pepper'; grams=4; buy='1 jar'; board_id='black-pepper' },
      @{ item='Chicken Broth'; grams=240; buy='1 carton'; board_id='chicken-broth' }
  )},
  @{ slug='slow-cooker-pork-posole-verde-bowls'; adds=@(
      @{ item='Garlic'; grams=15; buy='1 bulb'; board_id='garlic' },
      @{ item='Salt'; grams=10; buy='1 container'; board_id='salt' },
      @{ item='Black Pepper'; grams=4; buy='1 jar'; board_id='black-pepper' },
      @{ item='Dried Oregano'; grams=4; buy='1 jar (Mexican oregano)'; board_id='dried-oregano' },
      @{ item='Ground Cumin'; grams=8; buy='1 jar'; board_id='ground-cumin' },
      @{ item='Chili Powder'; grams=10; buy='1 jar'; board_id='chili-powder' },
      @{ item='Orange Juice'; grams=120; buy='1/2 cup'; board_id='orange-juice' },
      @{ item='Lime Juice'; grams=60; buy='2 limes, juiced'; board_id='limes' },
      @{ item='Chicken Broth'; grams=480; buy='1 carton'; board_id='chicken-broth' }
  )}
)

$dbF = Join-Path $mp 'recipes-db.json'
$doc = Get-Content $dbF -Raw | ConvertFrom-Json
$bySlug = @{}; foreach ($r in $doc.recipes) { $bySlug[[string]$r.slug] = $r }
$fixedCount = 0; $totalCostAdded = 0.0
foreach ($fx in $fixes) {
  $r = $bySlug[$fx.slug]
  if (-not $r) { Write-Output ("!! recipe not found: " + $fx.slug); continue }
  $recipeCost = 0.0
  foreach ($add in $fx.adds) {
    if (@($r.ingredients | Where-Object { $_.item -eq $add.item }).Count -gt 0) { Write-Output ("(already has " + $add.item + ": " + $fx.slug + ")"); continue }
    $r.ingredients = @($r.ingredients) + @([pscustomobject]@{ item=$add.item; grams=$add.grams; buy=$add.buy })
    $r.grocery_list = @($r.grocery_list) + @($add.buy)
    $price = $priceById[$add.board_id]; $gpu = $gpuAll[$add.board_id]
    $addCost = 0.0
    if ($price -and $gpu) { $addCost = [math]::Round(($add.grams / $gpu) * $price, 2) }
    $recipeCost += $addCost
  }
  if ($r.PSObject.Properties['cost_batch']) { $r.cost_batch = [math]::Round([double]$r.cost_batch + $recipeCost, 2) }
  if ($r.PSObject.Properties['cost_batch_true']) { $r.cost_batch_true = [math]::Round([double]$r.cost_batch_true + $recipeCost, 2) }
  $batchForPS = if ($r.PSObject.Properties['cost_batch_true'] -and $r.cost_batch_true) { [double]$r.cost_batch_true } else { [double]$r.cost_batch }
  $newPS = if ($r.servings) { [math]::Round($batchForPS / [int]$r.servings, 2) } else { $null }
  if ($r.PSObject.Properties['cost_per_serving']) { $r.cost_per_serving = $newPS }
  if ($r.PSObject.Properties['cost_per_serving_true']) { $r.cost_per_serving_true = $newPS }
  $fixedCount++; $totalCostAdded += $recipeCost
  Write-Output ("fixed: " + $fx.slug + " +$" + [math]::Round($recipeCost,2) + " (" + @($fx.adds).Count + " ingredients) -> batch=$" + $r.cost_batch_true)
}
($doc | ConvertTo-Json -Depth 10) | Set-Content $dbF -Encoding UTF8
Write-Output ("TOTAL: " + $fixedCount + " recipes fixed, $" + [math]::Round($totalCostAdded,2) + " total cost added")
