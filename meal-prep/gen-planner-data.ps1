# gen-planner-data.ps1 - Exports slim per-recipe data for the Meal Plan Builder tool.
# Output: meal-prep\planner-data.js  ->  var MPP=[{s,n,c,p,cal,pro,carb,fat,cps,ing:[{i,g,b,bid,gpu}]}]
#   s=slug n=name c=cuisine p=protein-cat cal/pro/carb/fat=per-serving
#   cps=cost per serving, WHOLE-PACKAGE at the board's cheapest store, from pipeline\v2-perserving.json
#   ing: i=item g=grams at 14 servings b=buy amount at 14 servings
#        bid/gpu only when the LIVE FEED can price the item; gpu is reconciled to the FEED row's unit
#        (the brown-sugar 16x lesson: a map gpu is calibrated to its era's board unit, never trust blindly)
# JSON is built manually (PS5.1 ConvertTo-Json chokes on big graphs).
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$db=(Get-Content (Join-Path $here 'recipes-db.json') -Raw | ConvertFrom-Json).recipes

# THE PER-SERVING PRICE COMES FROM THE MANIFEST, NOT THE INDEX (2026-08-04).
# This script used to read $r.cost_per_serving straight off recipes-db, which was wrong twice over:
#   BASIS. recipes-db.cost_per_serving is cost_batch/14 - the UTILIZATION basis, counting only the grams
#   the recipe consumes out of each package. The tool's own note under the grocery list promises the
#   opposite ("every item is priced as full packages (a 2 lb bag of rice costs what the bag costs)...
#   prices come from our verified Omaha grocery board"), and the grocery list below it really does price
#   whole packages at the cheapest store. So the cost tiles and the list they sit above were computed on
#   two different bases, and the tiles were the low one.
#   FRESHNESS. It is a COPY, written once at import time. On 2026-07-25 the R300 merge stamped one
#   recipe's cost block across 299 rows; the specs were recost the next morning and the index sat stale
#   for ten days, so a $6.78 bowl was presented at $1.83. sync-recipesdb-cost.ps1 now keeps that copy
#   honest, but honest-to-the-spec still means the wrong BASIS for this surface.
# cheapest_ps is what every other surface already reads (build-hub-grid, build-card2,
# build-stretcher-data, top5, the rotation), so the planner tile and the recipe card a reader clicks
# through to now quote the same number on the same basis.
$cheapPs=@{}
foreach($m in (Get-Content (Join-Path $here 'pipeline\v2-perserving.json') -Raw | ConvertFrom-Json)){ $cheapPs[[string]$m.slug]=[double]$m.cheapest_ps }
Write-Output ("v2-perserving manifest: {0} priced recipes" -f $cheapPs.Count)

# feed units per bid (what the tool queries live)
$feed=(Get-Content (Join-Path $here '..\grocery\out\smp-feed.json') -Raw | ConvertFrom-Json).ingredients
$feedUnit=@{}
foreach($p in $feed.PSObject.Properties){ $feedUnit[$p.Name]=[string]$p.Value.unit }

# 2026-07-26 engine consolidation: mapping + package sizes come from THE canonical store
# db\ingredients.json (which merged r100/r300 board maps, ingredient-map, pantry-packages and the
# engines' $PKG tables with the same precedence this script used to reimplement). The old per-run
# reads broke when the run folders were archived. planner-extra-packages.json remains the planner's
# own supplemental package list (fold-in candidate).
$item=@{}
$pkg=@{}
foreach($row in (Get-Content (Join-Path $here 'db\ingredients.json') -Raw | ConvertFrom-Json)){
  $nm=[string]$row.item
  if($row.PSObject.Properties.Name -contains 'bid' -and $row.bid){
    $item[$nm]=@{bid=[string]$row.bid;gpu=[double]$row.gpu;unit=[string]$row.unit}
  }
  # whole-package size: pantry container first (staple jars), else the buy package
  $pg=$null;$pl=$null
  if($row.PSObject.Properties.Name -contains 'pantry_pkg_g' -and $row.pantry_pkg_g){ $pg=[double]$row.pantry_pkg_g; $pl=[string]$row.pantry_pkg_label }
  elseif($row.PSObject.Properties.Name -contains 'buy_pkg_g' -and $row.buy_pkg_g){ $pg=[double]$row.buy_pkg_g; $pl=[string]$row.buy_pkg_label }
  if($pg){ $pkg[$nm]=@{ g=$pg; l=$pl } }
}
$UNIT_G=@{ lb=453.592; oz=28.3495; floz=29.57; kg=1000.0; g=1.0 }
foreach($p in ((Get-Content (Join-Path $here 'planner-extra-packages.json') -Raw | ConvertFrom-Json).packages).PSObject.Properties){
  if(-not $pkg.ContainsKey($p.Name)){ $pkg[$p.Name]=@{ g=[double]$p.Value.g; l=[string]$p.Value.label } }
}
function Feed-Gpu($it){
  if(-not $item.ContainsKey($it)){ return $null }
  $b=$item[$it]
  if(-not $feedUnit.ContainsKey($b.bid)){ return $null }
  $fu=$feedUnit[$b.bid]
  if(-not $b.unit -or -not $fu -or $b.unit -eq $fu){ return @{bid=$b.bid;gpu=$b.gpu} }
  if($UNIT_G.ContainsKey($b.unit) -and $UNIT_G.ContainsKey($fu)){ return @{bid=$b.bid;gpu=[Math]::Round($b.gpu*($UNIT_G[$fu]/$UNIT_G[$b.unit]),4)} }
  return $null   # non-standard unit mismatch: no live pricing for this line (never guess)
}

# protein category: heaviest real-meat ingredient (broths never count) - same deriver as the hub grid
function Get-ProteinCat($rec){
  $best='other'; $bestG=-1
  foreach($ing in $rec.ingredients){
    $n=([string]$ing.item).ToLower()
    if($n -match 'broth|stock|bouillon|base\b|gravy'){ continue }
    $g=[double]$ing.grams; $cat=$null
    if($n -match 'turkey'){ $cat='turkey' }
    elseif($n -match 'chicken'){ $cat='chicken' }
    elseif($n -match 'ground beef|beef|steak|chuck|sirloin|brisket|\bkofta\b|meatball' -and $n -notmatch 'turkey|chicken|pork'){ $cat='beef' }
    elseif($n -match 'pork|sausage|chorizo|bacon|\bham\b|prosciutto|pancetta|kielbasa|carnitas|\bribs?\b'){ $cat='pork' }
    if($cat -and $g -gt $bestG){ $bestG=$g; $best=$cat }
  }
  return $best
}
function J([string]$s){
  $s=$s.Replace('\','\\').Replace('"','\"').Replace("`r",'').Replace("`n",' ')
  return '"'+$s+'"'
}

# reader-facing display renames (macro/pricing identity stays canonical; the shopper must see the
# real grocery name - mirrors the card-side scaler rename, e.g. japchae's dangmyeon vs Cornstarch)
$DISPLAY_OVERRIDES=@{ 'korean-turkey-japchae|Cornstarch'='Korean glass noodles (dangmyeon)' }

$rows=New-Object System.Collections.Generic.List[string]
$withBid=0; $totalIng=0
$unpriced=@()
foreach($r in $db){
  # COLLECT-AND-REPORT, the same contract compute-v2-perserving.ps1 runs on: a recipe the manifest cannot
  # price is DROPPED and named, never shipped at a fallback price. There is no honest fallback here - the
  # index copy is a different basis and quoting it would put a too-low number on a conversion surface,
  # which is the exact defect this block exists to close. The file is still written for every other
  # recipe (a hard throw would leave the tool serving yesterday's data with nothing said), and the run
  # exits 1 so the daily chain alerts.
  if(-not $cheapPs.ContainsKey([string]$r.slug)){ $unpriced += [string]$r.slug; continue }
  $ings=New-Object System.Collections.Generic.List[string]
  foreach($ing in $r.ingredients){
    $g=[int][Math]::Round([double]$ing.grams,0)
    if($g -le 0){ continue }
    $totalIng++
    $fb=Feed-Gpu $ing.item
    $extra=''
    if($fb){ $withBid++; $extra=',"bid":'+(J $fb.bid)+',"gpu":'+$fb.gpu }
    if($pkg.ContainsKey($ing.item)){ $extra+=',"pk":'+$pkg[$ing.item].g+',"pl":'+(J $pkg[$ing.item].l) }
    $dispName=[string]$ing.item
    $ovKey=([string]$r.slug)+'|'+$dispName
    if($DISPLAY_OVERRIDES.ContainsKey($ovKey)){ $dispName=$DISPLAY_OVERRIDES[$ovKey] }
    [void]$ings.Add('{"i":'+(J $dispName)+',"g":'+$g+',"b":'+(J ([string]$ing.buy))+$extra+'}')
  }
  $cps=$cheapPs[[string]$r.slug]
  [void]$rows.Add('{"s":'+(J $r.slug)+',"n":'+(J $r.name)+',"c":'+(J ([string]$r.cuisine))+',"p":'+(J (Get-ProteinCat $r))+
    ',"cal":'+[int]$r.per_serving.calories+',"pro":'+[int]$r.per_serving.protein_g+',"carb":'+[int]$r.per_serving.carbs_g+',"fat":'+[int]$r.per_serving.fat_g+
    ',"cps":'+$cps.ToString('0.00')+',"ing":['+($ings -join ',')+']}')
}
$js='var MPP=['+($rows -join ",`n")+'];'
# parse-validate the JSON payload before shipping
$check=$js.Substring(8,$js.Length-9)
$null=$check | ConvertFrom-Json   # throws if malformed
[IO.File]::WriteAllText((Join-Path $here 'planner-data.js'),$js,(New-Object System.Text.UTF8Encoding($false)))
# SCALE (2026-07-26): also emit the pure-JSON array to public\planner-data.json - the Worker serves it
# statically (like smp-feed) and the tool fetches it at load time instead of embedding it in the Ghost
# post, so the post stays template-size no matter how big the catalog grows. Compact (no whitespace).
$jsonArr='['+($rows -join ',')+']'
$null=$jsonArr | ConvertFrom-Json   # validate the served copy too
$pubPlanner=Join-Path (Split-Path $here -Parent) 'public\planner-data.json'
[IO.File]::WriteAllText($pubPlanner,$jsonArr,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("public\planner-data.json: " + [Math]::Round((Get-Item $pubPlanner).Length/1024,0) + " KB (Worker-served)")
$kb=[Math]::Round((Get-Item (Join-Path $here 'planner-data.js')).Length/1024,0)
$noPkg=@{}
foreach($r in $db){ foreach($ing in $r.ingredients){ if($ing.grams -gt 0 -and -not $pkg.ContainsKey($ing.item)){ $noPkg[$ing.item]=1 } } }
Write-Output ("planner-data.js: {0} of {1} recipes, {2}/{3} ingredient lines feed-priced, {4} KB, pkg table {5} items" -f $rows.Count,@($db).Count,$withBid,$totalIng,$kb,$pkg.Count)
if($noPkg.Count -gt 0){ Write-Output ("ITEMS WITHOUT PACKAGE DEF ({0}): {1}" -f $noPkg.Count, (($noPkg.Keys | Sort-Object) -join ', ')) }
if($unpriced.Count -gt 0){
  # No silent caps: a recipe missing from the planner has to say so by name, or a shrinking catalog
  # reads as a clean run. Re-run pipeline\compute-v2-perserving.ps1 and check what it skipped.
  Write-Output ("DROPPED {0} recipe(s) with no v2-perserving row (not shown in the Meal Plan Builder): {1}" -f $unpriced.Count, ($unpriced -join ', '))
  exit 1
}
