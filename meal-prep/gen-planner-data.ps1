# gen-planner-data.ps1 - Exports slim per-recipe data for the Meal Plan Builder tool.
# Output: meal-prep\planner-data.js  ->  var MPP=[{s,n,c,p,cal,pro,carb,fat,cps,ing:[{i,g,b,bid,gpu}]}]
#   s=slug n=name c=cuisine p=protein-cat cal/pro/carb/fat=per-serving cps=cost per serving (everyday)
#   ing: i=item g=grams at 14 servings b=buy amount at 14 servings
#        bid/gpu only when the LIVE FEED can price the item; gpu is reconciled to the FEED row's unit
#        (the brown-sugar 16x lesson: a map gpu is calibrated to its era's board unit, never trust blindly)
# JSON is built manually (PS5.1 ConvertTo-Json chokes on big graphs).
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$db=(Get-Content (Join-Path $here 'recipes-db.json') -Raw | ConvertFrom-Json).recipes

# feed units per bid (what the tool queries live)
$feed=(Get-Content (Join-Path $here '..\grocery\out\smp-feed.json') -Raw | ConvertFrom-Json).ingredients
$feedUnit=@{}
foreach($p in $feed.PSObject.Properties){ $feedUnit[$p.Name]=[string]$p.Value.unit }

# item -> bid+gpu+unit (r100 map first: calibrated this week; then the r300 map; then the 90-run map)
$mapNew=(Get-Content (Join-Path $here 'r100\r100-board-map.json') -Raw | ConvertFrom-Json).map
$mapR300=(Get-Content (Join-Path $here 'r300\r300-board-map.json') -Raw | ConvertFrom-Json).map   # 2026-07-25 close-out: r300 names (Turkey Breast, Pork Shoulder, ...) were feed-unpriced without it
$mapOld=(Get-Content (Join-Path $here 'ingredient-map.json') -Raw | ConvertFrom-Json).mappings
# PRECEDENCE (flipped 2026-07-25 close-out): r300 map FIRST - it is derived from the CURRENT audited
# recipes-db item_ids (incl. the proxy-debt re-points: Red Onion->red-onion, Ricotta->ricotta, ...).
# r100's era map second, the 90-run map last.
$item=@{}
foreach($p in $mapR300.PSObject.Properties){ $item[$p.Name]=@{bid=$p.Value.bid;gpu=[double]$p.Value.gpu;unit=[string]$p.Value.unit} }
foreach($p in $mapNew.PSObject.Properties){ if(-not $item.ContainsKey($p.Name)){ $item[$p.Name]=@{bid=$p.Value.bid;gpu=[double]$p.Value.gpu;unit=[string]$p.Value.unit} } }
foreach($m in $mapOld){ if(-not $item.ContainsKey($m.item)){ $item[$m.item]=@{bid=$m.board_id;gpu=[double]$m.grams_per_unit;unit=[string]$m.unit} } }
$UNIT_G=@{ lb=453.592; oz=28.3495; floz=29.57; kg=1000.0; g=1.0 }

# package sizes per item (whole-package pricing in the tool: "assume the user owns nothing"):
# pantry staples from pantry-packages.json + fresh/boxed items parsed from cost-engine's $PKG table
$pkg=@{}
foreach($p in ((Get-Content (Join-Path $here 'r300\pantry-packages.json') -Raw | ConvertFrom-Json).packages).PSObject.Properties){  # r300 file = r100 entries + r300 additions (superset since 2026-07-25)
  $pkg[$p.Name]=@{ g=[double]$p.Value.g; l=[string]$p.Value.label }
}
foreach($p in ((Get-Content (Join-Path $here 'planner-extra-packages.json') -Raw | ConvertFrom-Json).packages).PSObject.Properties){
  if(-not $pkg.ContainsKey($p.Name)){ $pkg[$p.Name]=@{ g=[double]$p.Value.g; l=[string]$p.Value.label } }
}
$engineSrc=Get-Content (Join-Path $here 'r100\cost-engine.ps1') -Raw
$pkgBlock=[regex]::Match($engineSrc,'\$PKG\s*=\s*@\{(?s)(.*?)\r?\n\}').Groups[1].Value
$pkgRe = '''([^'']+)''\s*=\s*@\{g=([\d.]+|\$LB|\$OZ);label=''([^'']*)''\}'
foreach($m in [regex]::Matches($pkgBlock,$pkgRe)){
  $nm=$m.Groups[1].Value.Trim()
  if($pkg.ContainsKey($nm)){ continue }   # pantry file wins
  $gv=$m.Groups[2].Value
  $g = if($gv -match 'LB'){453.592} elseif($gv -match 'OZ'){28.3495} else {[double]$gv}
  $pkg[$nm]=@{ g=$g; l=$m.Groups[3].Value }
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
foreach($r in $db){
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
  $cps=[double]$r.cost_per_serving
  [void]$rows.Add('{"s":'+(J $r.slug)+',"n":'+(J $r.name)+',"c":'+(J ([string]$r.cuisine))+',"p":'+(J (Get-ProteinCat $r))+
    ',"cal":'+[int]$r.per_serving.calories+',"pro":'+[int]$r.per_serving.protein_g+',"carb":'+[int]$r.per_serving.carbs_g+',"fat":'+[int]$r.per_serving.fat_g+
    ',"cps":'+$cps.ToString('0.00')+',"ing":['+($ings -join ',')+']}')
}
$js='var MPP=['+($rows -join ",`n")+'];'
# parse-validate the JSON payload before shipping
$check=$js.Substring(8,$js.Length-9)
$null=$check | ConvertFrom-Json   # throws if malformed
[IO.File]::WriteAllText((Join-Path $here 'planner-data.js'),$js,(New-Object System.Text.UTF8Encoding($false)))
$kb=[Math]::Round((Get-Item (Join-Path $here 'planner-data.js')).Length/1024,0)
$noPkg=@{}
foreach($r in $db){ foreach($ing in $r.ingredients){ if($ing.grams -gt 0 -and -not $pkg.ContainsKey($ing.item)){ $noPkg[$ing.item]=1 } } }
Write-Output ("planner-data.js: {0} recipes, {1}/{2} ingredient lines feed-priced, {3} KB, pkg table {4} items" -f $rows.Count,$withBid,$totalIng,$kb,$pkg.Count)
if($noPkg.Count -gt 0){ Write-Output ("ITEMS WITHOUT PACKAGE DEF ({0}): {1}" -f $noPkg.Count, (($noPkg.Keys | Sort-Object) -join ', ')) }
