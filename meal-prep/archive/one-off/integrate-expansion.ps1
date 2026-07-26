<#
  integrate-expansion.ps1 - Folds expansion-proposal.json (agent-collected Family Fare prices for the
  previously-untracked recipe ingredients) into the live system:
    1. recipe-board-everyday.json  += new commodity rows (single Family Fare store entry, type=everyday)
    2. ingredient-map.json         += map_additions (and removes those items from unmapped)
    3. product-urls.json           += Family Fare product links for the new ids
  Idempotent: skips ids/items that already exist. Run the downstream after: recipe-overlay, top5-weekly,
  export-feed, add-serving-scaler -All. Other stores' floors get filled by the monthly browser agent.
#>
$ErrorActionPreference = 'Stop'
$mp = $PSScriptRoot
$g  = Join-Path (Split-Path $mp -Parent) 'grocery'
$prop = Get-Content (Join-Path $mp 'expansion-proposal.json') -Raw | ConvertFrom-Json

# category by keyword (for the grocery page's recipe section grouping)
function CatOf([string]$id, [string]$name) {
  $t = ($id + ' ' + $name).ToLower()
  if ($t -match 'beef|pork|chicken|turkey|sausage|loin|tenderloin|roast|bacon|ham') { return 'Meat & Poultry' }
  if ($t -match 'rice|pasta|penne|noodle|spaghetti|orzo|tortilla') { return 'Pasta, Rice & Grains' }
  if ($t -match 'bean|canned|corn|tomatoes|chiles|chipotle|broth|stock|coconut-milk') { return 'Beans & Canned' }
  if ($t -match 'seasoning|powder|cumin|paprika|spice|salt|pepper\b|italian-season') { return 'Spices & Baking' }
  if ($t -match 'broccoli|pepper|onion|garlic|lime|lemon|carrot|celery|potato|florets') { return 'Produce' }
  if ($t -match 'cheese|cheddar|mozzarella|parmesan|yogurt|cream') { return 'Cheese & Dairy' }
  return 'Sauces & Condiments'
}

# 1. recipe-board-everyday.json
$bevF = Join-Path $g 'out\recipe-board-everyday.json'
$bev = Get-Content $bevF -Raw | ConvertFrom-Json
$have = @{}; foreach ($r in $bev.comparison) { $have[[string]$r.id] = $true }
$cmpF = Get-ChildItem (Join-Path $g 'out\comparison-*.json') | Sort-Object Name -Descending | Select-Object -First 1
foreach ($r in (Get-Content $cmpF.FullName -Raw | ConvertFrom-Json).comparison) { $have[[string]$r.id] = $true }
$added = 0; $rows = @($bev.comparison)
foreach ($c in $prop.new_commodities) {
  $id = [string]$c.id
  if ($have.ContainsKey($id)) { Write-Output ("skip (id exists): " + $id); continue }
  $store = [pscustomobject]@{ store='Family Fare'; per_unit=[math]::Round([double]$c.ff.per_unit,4); unit=[string]$c.unit; type='everyday'; bulk=$false; membership=$false; item=[string]$c.ff.item; size=[string]$c.ff.size }
  $rows += [pscustomobject]@{ id=$id; commodity=[string]$c.commodity; unit=[string]$c.unit; category=(CatOf $id ([string]$c.commodity)); cheapest_store='Family Fare'; cheapest_price=[math]::Round([double]$c.ff.per_unit,4); cheapest_type='everyday'; stores=@($store) }
  $added++
}
$bev.comparison = $rows
($bev | ConvertTo-Json -Depth 8) | Set-Content $bevF -Encoding UTF8
Write-Output ("recipe-board-everyday: +" + $added + " commodities (now " + @($rows).Count + ")")

# 2. ingredient-map.json
$mapF = Join-Path $mp 'ingredient-map.json'
$map = Get-Content $mapF -Raw | ConvertFrom-Json
$mapped = @{}; foreach ($m in $map.mappings) { $mapped[[string]$m.item] = $true }
$newMaps = @($map.mappings); $mAdd = 0
foreach ($a in $prop.map_additions) {
  if ($mapped.ContainsKey([string]$a.item)) { continue }
  $newMaps += [pscustomobject]@{ item=[string]$a.item; board_id=[string]$a.board_id; board='recipe'; grams_per_unit=[double]$a.grams_per_unit; unit=[string]$a.unit }
  $mAdd++
}
$map.mappings = $newMaps
$doneItems = @{}; foreach ($a in $prop.map_additions) { $doneItems[[string]$a.item] = $true }
$map.unmapped = @($map.unmapped | Where-Object { -not $doneItems.ContainsKey([string]$_.item) })
($map | ConvertTo-Json -Depth 6) | Set-Content $mapF -Encoding UTF8
Write-Output ("ingredient-map: +" + $mAdd + " mappings; unmapped now " + @($map.unmapped).Count)

# 3. product-urls.json (Family Fare links for the new ids)
$puF = Join-Path $g 'product-urls.json'
$pu = Get-Content $puF -Raw | ConvertFrom-Json
$uAdd = 0
foreach ($c in $prop.new_commodities) {
  $id = [string]$c.id
  if (-not $c.ff.url) { continue }
  if (-not $pu.items.PSObject.Properties[$id]) {
    $pu.items | Add-Member -NotePropertyName $id -NotePropertyValue ([pscustomobject]@{ commodity=[string]$c.commodity })
  }
  $entry = $pu.items.$id
  if (-not $entry.PSObject.Properties['Family Fare']) {
    $entry | Add-Member -NotePropertyName 'Family Fare' -NotePropertyValue ([pscustomobject]@{ url=[string]$c.ff.url; price=[double]$c.ff.price; size=[string]$c.ff.size; name=[string]$c.ff.item })
    $uAdd++
  }
}
($pu | ConvertTo-Json -Depth 6) | Set-Content $puF -Encoding UTF8
Write-Output ("product-urls: +" + $uAdd + " Family Fare links")
Write-Output "NEXT: recipe-overlay.ps1, top5-weekly.ps1, export-feed.ps1, add-serving-scaler.ps1 -All, then commit+push."
