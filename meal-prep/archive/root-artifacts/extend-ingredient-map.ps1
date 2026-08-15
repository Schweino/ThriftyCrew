<#
  extend-ingredient-map.ps1 - one-shot (2026-07-25): close the 47 unmapped ingredient names found while
  normalizing recipes to canonical ids (Brad: "redo ALL the recipes so it uses the same ID format across
  the entire site"). 39 names map to real board commodities (they also become LIVE-priced in the cost
  engine instead of static pantry estimates); 8 are EVIDENCE-REJECTED per the variety/form precedents
  (red-bell-pepper, fresh-vs-frozen) and stay unmapped on purpose - a wrong price is worse than a static one.

  gpu convention (from existing entries): lb=453.592, oz=28.3495, floz=29.57 (water-like default).
  board field: 'recipe' if the id is in grocery\recipe-commodities.json, else 'weekly' (staple board).
#>
$ErrorActionPreference = 'Stop'
$root = 'C:\Codex\ThriftyCrew'
$mapFile = Join-Path $root 'meal-prep\ingredient-map.json'
Copy-Item $mapFile ($mapFile + '.bak-idnorm') -Force
$mp = Get-Content $mapFile -Raw | ConvertFrom-Json

$recipeBoardIds = @{}
try {
  $rc = Get-Content (Join-Path $root 'grocery\recipe-commodities.json') -Raw | ConvertFrom-Json
  foreach ($p in $rc.PSObject.Properties) { if ($p.Name -ne 'readme') { $recipeBoardIds[$p.Name] = $true } }
  foreach ($e in @($rc.commodities)) { if ($e.id) { $recipeBoardIds[[string]$e.id] = $true } }
} catch {}

$gpu = @{ lb = 453.592; oz = 28.3495; floz = 29.57 }
# name -> board_id, unit   (unit read off commodities.json when this was authored)
$add = @(
  @{ n='ground pork';               id='ground-pork';           u='lb' }
  @{ n='pork chops';                id='pork-chops';            u='lb' }
  @{ n='sweet potatoes';            id='sweet-potatoes';        u='lb' }
  @{ n='cheese tortellini';         id='cheese-tortellini';     u='oz' }
  @{ n='ground cloves';             id='ground-cloves';         u='oz' }
  @{ n='rice noodles';              id='rice-noodles';          u='oz' }
  @{ n='dill pickles';              id='pickles';               u='oz' }
  @{ n='butter crackers';           id='crackers';              u='oz' }
  @{ n='fresh basil';               id='fresh-basil';           u='oz' }
  @{ n='frozen hash browns';        id='hash-browns';           u='oz' }
  @{ n='ziti pasta';                id='pasta';                 u='oz' }
  @{ n='spaghetti';                 id='pasta';                 u='oz' }
  @{ n='fettuccine';                id='pasta';                 u='oz' }
  @{ n='orzo pasta';                id='pasta';                 u='oz' }
  @{ n='pasta shells';              id='pasta';                 u='oz' }
  @{ n='lo mein noodles';           id='egg-noodles';           u='oz' }   # lo mein noodles ARE wheat egg noodles
  @{ n='egg noodles';               id='egg-noodles';           u='oz' }
  @{ n='mexican cheese blend';      id='shredded-cheese';       u='oz' }
  @{ n='cajun seasoning';           id='cajun-seasoning';       u='oz' }
  @{ n='berbere seasoning';         id='berbere-seasoning';     u='oz' }
  @{ n='poppy seeds';               id='poppy-seeds';           u='oz' }
  @{ n='chili crisp';               id='chili-crisp';           u='oz' }
  @{ n='red curry paste';           id='red-curry-paste';       u='oz' }
  @{ n='grits';                     id='grits';                 u='oz' }
  @{ n='walnuts';                   id='walnuts';               u='oz' }
  @{ n='peanuts';                   id='peanuts';               u='oz' }
  @{ n='hummus';                    id='hummus';                u='oz' }
  @{ n='japanese curry roux';       id='japanese-curry-roux';   u='oz' }
  @{ n='refrigerated biscuits';     id='refrigerated-biscuits'; u='oz' }
  @{ n='lemongrass paste';          id='lemongrass-paste';      u='oz' }
  @{ n='harissa paste';             id='harissa-paste';         u='oz' }
  @{ n='bbq sauce';                 id='bbq-sauce';             u='oz' }
  @{ n='oyster sauce';              id='oyster-sauce';          u='floz' }
  @{ n='heavy cream';               id='heavy-cream';           u='floz' }
  @{ n='mirin';                     id='mirin';                 u='floz' }
  @{ n='pomegranate molasses';      id='pomegranate-molasses';  u='floz' }
)
# EVIDENCE-REJECTED (stay unmapped; pantry-static pricing preserves today's behavior):
#   red onion            - variety pricing differs from yellow (red-bell-pepper precedent)
#   cherry tomatoes      - different product class from slicing tomatoes
#   ricotta cheese       - no board commodity; cottage/cream cheese are different products
#   smoked turkey sausage- no turkey-sausage id; pork sausages are a form-flip
#   pork chorizo         - no chorizo id; italian-sausage is a different seasoning class
#   corn muffin mix      - no id
#   potato gnocchi       - no id; potatoes are the ingredient, not the product
#   corn chips           - distinct product from tortilla-chips
#   achiote paste        - no id

$existing = @{}
foreach ($e in $mp.mappings) { $existing[([string]$e.item).ToLower().Trim()] = $true }
$db = Get-Content (Join-Path $root 'meal-prep\recipes-db.json') -Raw | ConvertFrom-Json
$nameCase = @{}   # canonical display case as the recipes actually spell it
foreach ($r in $db.recipes) { foreach ($i in @($r.ingredients)) { $nameCase[([string]$i.item).ToLower().Trim()] = [string]$i.item } }

$mappings = @($mp.mappings)
$added = 0
foreach ($a in $add) {
  if ($existing.ContainsKey($a.n)) { continue }
  $disp = if ($nameCase.ContainsKey($a.n)) { $nameCase[$a.n] } else { $a.n }
  $board = if ($recipeBoardIds.ContainsKey($a.id)) { 'recipe' } else { 'weekly' }
  $mappings += [pscustomobject]@{ item=$disp; board_id=$a.id; board=$board; grams_per_unit=[double]$gpu[$a.u]; unit=$a.u }
  $added++
}
$mp.mappings = $mappings
$mp | ConvertTo-Json -Depth 4 | Set-Content $mapFile -Encoding UTF8
Write-Output ("ingredient-map: +$added entr(ies) -> " + @($mappings).Count + " total (8 names evidence-rejected on purpose, listed in this script)")
