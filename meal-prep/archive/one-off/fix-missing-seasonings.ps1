<#
  fix-missing-seasonings.ps1 - One-time fix for 15 recipes found (via source-recipe verification, not
  assumption) to be missing a genuinely essential seasoning/aromatic - e.g. "Jerk Pork Bowls" had ZERO
  seasoning at all. Adds each missing ingredient to recipes-db.json (ingredients + grocery_list), recomputes
  cost_batch/cost_batch_true, and for the 6 genuinely-new spices adds Family-Fare-priced commodities to
  recipe-board-everyday.json + ingredient-map.json + product-urls.json (other 5 stores to backfill next,
  same pattern as the 43-item expansion).
#>
$ErrorActionPreference = 'Stop'
$mp = $PSScriptRoot
$g  = Join-Path (Split-Path $mp -Parent) 'grocery'

# ---- 1. six brand-new commodities, Family-Fare priced (verified live via Freshop API) ----
$newCommodities = @(
  @{ id='bay-leaves';     commodity='Bay Leaves';      unit='oz';   price=3.99; per_unit=33.25;  size='0.12 oz'; item="Our Family Bay Leaves 0.12 Oz"; url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/herbs/our_family_bay_leaves_0_12_oz/p/7194347'; category='Spices & Baking'; gpu=28.3495 },
  @{ id='garam-masala';   commodity='Garam Masala';    unit='oz';   price=6.59; per_unit=3.6611; size='1.8 oz';  item='Finest Reserve Garam Masala 1.8 Oz'; url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/special_blends/finest_reserve_garam_masala_1_8_oz/p/1564405684714873799'; category='Spices & Baking'; gpu=28.3495 },
  @{ id='rice-vinegar';   commodity='Rice Vinegar';    unit='floz'; price=5.39; per_unit=0.4492; size='12 fl oz'; item='Nakano Rice Vinegar, Organic, Natural 12 Fl Oz'; url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/cooking_wines_vinegars/nakano_rice_vinegar_organic_natural_12_fl_oz/p/5573392'; category='Sauces & Condiments'; gpu=29.57 },
  @{ id='corn-tortillas'; commodity='Corn Tortillas';  unit='each'; price=1.79; per_unit=0.0597; size='30 ea'; item='La Providencia Corn Tortillas 30 Ea'; url='https://www.shopfamilyfare.com/shop/bakery/tortillas/la_providencia_corn_tortillas_30_ea/p/1564405684715306085'; category='Pasta, Rice & Grains'; gpu=30 },
  @{ id='jerk-seasoning'; commodity='Jerk Seasoning';  unit='oz';   price=6.79; per_unit=1.3773; size='4.93 oz'; item="Lawry's Jerk Seasoning 4.93 Oz"; url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/special_blends/lawry_s_jerk_seasoning_4_93_oz/p/1764405684714689520'; category='Spices & Baking'; gpu=28.3495 },
  @{ id='dried-oregano';  commodity='Dried Oregano';   unit='oz';   price=2.19; per_unit=2.92;   size='0.75 oz'; item='Our Family Oregano Leaves 0.75 Oz'; url='https://www.shopfamilyfare.com/shop/pantry/mixes_spices_seasoning/herbs/our_family_oregano_leaves_0_75_oz/p/6787152'; category='Spices & Baking'; gpu=28.3495 }
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

# ---- 2. ingredient-map additions (6 new + none needed for the 3 reused existing commodities) ----
$gpuById = @{}; foreach ($c in $newCommodities) { $gpuById[$c.id] = $c.gpu }
$newMapItems = @(
  @{ item='Bay Leaves'; board_id='bay-leaves'; gpu=28.3495; unit='oz' },
  @{ item='Garam Masala'; board_id='garam-masala'; gpu=28.3495; unit='oz' },
  @{ item='Rice Vinegar'; board_id='rice-vinegar'; gpu=29.57; unit='floz' },
  @{ item='Corn Tortillas'; board_id='corn-tortillas'; gpu=30; unit='each' },
  @{ item='Jerk Seasoning'; board_id='jerk-seasoning'; gpu=28.3495; unit='oz' },
  @{ item='Dried Oregano'; board_id='dried-oregano'; gpu=28.3495; unit='oz' }
)
$mappedItems = @{}; foreach ($m in $mapList) { $mappedItems[[string]$m.item] = $true }
foreach ($nm in $newMapItems) {
  if ($mappedItems.ContainsKey($nm.item)) { continue }
  $mapList.Add([pscustomobject]@{ item=$nm.item; board_id=$nm.board_id; board='recipe'; grams_per_unit=$nm.gpu; unit=$nm.unit })
}
$map.mappings = $mapList.ToArray()
($map | ConvertTo-Json -Depth 6) | Set-Content $mapF -Encoding UTF8
Write-Output ("ingredient-map: " + @($map.mappings).Count + " total mappings, " + @($map.unmapped).Count + " unmapped")

# ---- 3. per-ingredient current cheapest price (for cost recompute) - from the live feed ----
$feed = Get-Content (Join-Path (Split-Path $g -Parent) 'public\smp-feed.json') -Raw | ConvertFrom-Json
function PriceOf($id) { $e = $feed.ingredients.$id; if ($e) { return [double]$e.cheapest } else { return $null } }
# the 6 new items aren't in the feed yet (just minted) - use their FF price directly
$priceById = @{}
foreach ($c in $newCommodities) { $priceById[$c.id] = $c.per_unit }
foreach ($id in @('ground-cumin','fajita-seasoning','italian-seasoning','sesame-oil','limes','curry-powder')) { $p = PriceOf $id; if ($p) { $priceById[$id] = $p } }
$gpuAll = @{}
foreach ($c in $newCommodities) { $gpuAll[$c.id] = $c.gpu }
$gpuAll['ground-cumin']=28.3495; $gpuAll['fajita-seasoning']=35.44; $gpuAll['italian-seasoning']=28.3495; $gpuAll['sesame-oil']=28.3495; $gpuAll['limes']=30; $gpuAll['curry-powder']=28.3495

# ---- 4. the 15 recipe fixes: {slug, item, grams, buy, board_id} ----
$fixes = @(
  @{ slug='slow-cooker-chicken-tacos-rice-bowls';      item='Lime Juice';       grams=90; buy='3 limes, juiced';              board_id='limes' },
  @{ slug='slow-cooker-king-ranch-chicken-bowls';       item='Corn Tortillas';   grams=450; buy='15 corn tortillas, torn';    board_id='corn-tortillas' },
  @{ slug='slow-cooker-chicken-tikka-masala-rice-bowls';item='Garam Masala';     grams=14; buy='1 jar';                       board_id='garam-masala' },
  @{ slug='slow-cooker-chicken-adobo-rice-bowls';       item='Bay Leaves';       grams=3;  buy='3 dried bay leaves';          board_id='bay-leaves' },
  @{ slug='slow-cooker-greek-chicken-bowls';            item='Dried Oregano';    grams=6;  buy='1 jar';                       board_id='dried-oregano' },
  @{ slug='slow-cooker-cuban-mojo-pork-bowls';          item='Dried Oregano';    grams=6;  buy='1 jar';                       board_id='dried-oregano' },
  @{ slug='slow-cooker-italian-pork-loin-bowls';        item='Italian Seasoning';grams=6;  buy='1 jar';                       board_id='italian-seasoning' },
  @{ slug='slow-cooker-jerk-pork-bowls';                item='Jerk Seasoning';   grams=40; buy='1 jar';                       board_id='jerk-seasoning' },
  @{ slug='slow-cooker-korean-shredded-pork-bowls';     item='Rice Vinegar';     grams=30; buy='1 bottle';                    board_id='rice-vinegar' },
  @{ slug='slow-cooker-filipino-pork-adobo-bowls';      item='Bay Leaves';       grams=3;  buy='3 dried bay leaves';          board_id='bay-leaves' },
  @{ slug='beef-picadillo-rice-bowls';                  item='Dried Oregano';    grams=6;  buy='1 jar';                       board_id='dried-oregano' },
  @{ slug='loaded-beef-taco-skillet-bowls';             item='Ground Cumin';     grams=8;  buy='1 jar';                       board_id='ground-cumin' },
  @{ slug='korean-ground-turkey-bowls';                 item='Sesame Oil';       grams=15; buy='1 bottle';                    board_id='sesame-oil' },
  @{ slug='curry-ground-turkey-bowls';                  item='Curry Powder';     grams=14; buy='1 jar';                       board_id='curry-powder' },
  @{ slug='turkey-fajita-rice-bowls';                   item='Fajita Seasoning'; grams=40; buy='1 packet';                    board_id='fajita-seasoning' }
)

$dbF = Join-Path $mp 'recipes-db.json'
$doc = Get-Content $dbF -Raw | ConvertFrom-Json
$bySlug = @{}; foreach ($r in $doc.recipes) { $bySlug[[string]$r.slug] = $r }
$fixedCount = 0; $totalCostAdded = 0.0
foreach ($fx in $fixes) {
  $r = $bySlug[$fx.slug]
  if (-not $r) { Write-Output ("!! recipe not found: " + $fx.slug); continue }
  if (@($r.ingredients | Where-Object { $_.item -eq $fx.item }).Count -gt 0) { Write-Output ("(already has " + $fx.item + ": " + $fx.slug + ")"); continue }
  $r.ingredients = @($r.ingredients) + @([pscustomobject]@{ item=$fx.item; grams=$fx.grams; buy=$fx.buy })
  $r.grocery_list = @($r.grocery_list) + @($fx.buy)
  $price = $priceById[$fx.board_id]; $gpu = $gpuAll[$fx.board_id]
  $addCost = 0.0
  if ($price -and $gpu) { $addCost = [math]::Round(($fx.grams / $gpu) * $price, 2); $totalCostAdded += $addCost }
  if ($r.PSObject.Properties['cost_batch']) { $r.cost_batch = [math]::Round([double]$r.cost_batch + $addCost, 2) }
  if ($r.PSObject.Properties['cost_batch_true']) { $r.cost_batch_true = [math]::Round([double]$r.cost_batch_true + $addCost, 2) }
  $batchForPS = if ($r.PSObject.Properties['cost_batch_true'] -and $r.cost_batch_true) { [double]$r.cost_batch_true } else { [double]$r.cost_batch }
  $newPS = if ($r.servings) { [math]::Round($batchForPS / [int]$r.servings, 2) } else { $null }
  if ($r.PSObject.Properties['cost_per_serving']) { $r.cost_per_serving = $newPS }
  if ($r.PSObject.Properties['cost_per_serving_true']) { $r.cost_per_serving_true = $newPS }
  $fixedCount++
  Write-Output ("fixed: " + $fx.slug + " +" + $fx.item + " (" + $fx.grams + "g) +$" + $addCost + " -> batch=$" + $r.cost_batch_true)
}
($doc | ConvertTo-Json -Depth 10) | Set-Content $dbF -Encoding UTF8
Write-Output ("TOTAL: " + $fixedCount + " recipes fixed, $" + [math]::Round($totalCostAdded,2) + " total cost added across them")
Write-Output "NEXT: recipe-overlay.ps1, top5-weekly.ps1, export-feed.ps1, add-serving-scaler.ps1 -All, then commit+push."
