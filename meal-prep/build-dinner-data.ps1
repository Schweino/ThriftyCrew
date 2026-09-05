# build-dinner-data.ps1 - generates the compact embedded dataset for the
# "What's for dinner tonight?" tool from recipes-db.json + ingredient-map.json
# + the live feed (to verify board_ids). Output: dinner-data.js (a JS const)
# and a category review table on stdout.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'lib\json-io.ps1')   # Read-JsonFile: PS 5.1 decodes a BOM-less file with the ANSI codepage
# $PSScriptRoot, not a hard-coded path (2026-09-01), for the same reason build-hub-grid moved off one on
# 2026-08-01: this now runs from the daily chain, and the cloud runner's checkout is not C:\Codex.
$dir  = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\meal-prep' }
$repo = Split-Path $dir -Parent
$tool = Join-Path $repo 'site\tools\dinner-tonight-tool.html'
$db  = Read-JsonFile "$dir\recipes-db.json"
# v2 manifest: current-cheapest whole-package per serving per slug (2026-07-26 basis switch)
$script:cheapPs=@{}
try { (Read-JsonFile (Join-Path $dir 'pipeline\v2-perserving.json')) | ForEach-Object { $script:cheapPs[[string]$_.slug]=[math]::Round([double]$_.cheapest_ps,2) } } catch { Write-Warning 'v2-perserving.json unreadable - legacy cost fallback in effect' }
$map = Read-JsonFile "$dir\ingredient-map.json"
$raw = (Invoke-WebRequest -Uri "https://feed.thriftycrew.com/smp-feed.json" -UseBasicParsing -TimeoutSec 30).Content.TrimStart([char]0xFEFF)
$feed = $raw | ConvertFrom-Json
$feedKeys = @{}
foreach($k in $feed.ingredients.PSObject.Properties.Name){ $feedKeys[$k] = $true }

# item name -> board_id (only if the id actually exists in the live feed)
$boardOf = @{}
foreach($m in $map.mappings){ if($feedKeys.ContainsKey($m.board_id)){ $boardOf[$m.item] = $m.board_id } }

# ---- staples: assumed-on-hand cupboard items (toggle in the tool) ----
$staples = @('Salt','Black Pepper','Olive Oil','Vegetable Oil','Garlic Powder','Onion Powder',
  'Ground Cumin','Chili Powder','Paprika','Smoked Paprika','Dried Oregano','Italian Seasoning',
  'Red Pepper Flakes','Ground Ginger','Bay Leaves','Cornstarch','Brown Sugar','Granulated Sugar',
  'Sugar','Cayenne Pepper','Ground Cinnamon','Dried Thyme','Dried Basil','Dried Rosemary',
  'Crushed Red Pepper','All-Purpose Flour','Flour','Cooking Spray','Ground Coriander','Curry Powder',
  'Chinese Five Spice','Everything Bagel Seasoning','Dried Parsley','Ground Mustard','Celery Seed','White Pepper')

# ---- category rules (first match wins); P protein, V veg/fresh, G grains+pantry, D dairy/eggs, S sauces ----
$cats = @(
  @{c='P'; rx='Chicken Breast|Chicken Thigh|Ground Beef|Ground Turkey|Ground Pork|Pork Loin|Pork Tenderloin|Pork Shoulder|Pork Chop|Chuck Roast|Beef Stew|Flank Steak|Sirloin|Shrimp|Salmon|Tilapia|Cod|Sausage|Kielbasa|Bacon|Ham|Turkey Breast|Chicken Drumstick|Whole Chicken|Rotisserie'},
  @{c='D'; rx='Cheese|Cheddar|Mozzarella|Parmesan|Yogurt|Butter|Milk(?!k)|Cream|Sour Cream|Eggs?$|Egg '},
  @{c='V'; rx='Broccoli|Pepper(s)?$|Bell Pepper|Onion|Potato|Carrot|Celery|Cilantro|Jalapeno|Zucchini|Squash|Green Bean|Cabbage|Spinach|Kale|Lettuce|Tomato(es)?$|Cherry Tomato|Roma|Mushroom|Garlic$|Ginger$|Lime$|Lemon$|Avocado|Cucumber|Corn on|Scallion|Green Onion|Snap Pea|Snow Pea|Asparagus|Cauliflower|Sweet Potato|Edamame|Peas$|Fresh '},
  @{c='G'; rx='Rice$|Rice(?! Vinegar)|Pasta|Penne|Spaghetti|Macaroni|Noodle|Tortilla|Bread|Bun|Oats|Quinoa|Beans|Black Beans|Pinto|Chickpea|Lentil|Broth|Stock|Diced Tomatoes|Crushed Tomatoes|Tomato Sauce|Tomato Paste|Coconut Milk|Corn$|Kernel Corn|Salsa|Green Chiles|Panko|Breadcrumb|Flour Tortilla|Marinara|Peanut(s)?$|Cashew|Almond'},
  @{c='S'; rx='.'}  # everything else -> sauces/condiments/seasoning packets
)

# ---- manual category overrides (fix keyword-rule misfits) ----
$override = @{
  'Celery Salt'='T';
  'Diced Tomatoes'='G'; 'Crushed Tomatoes'='G'; 'Sun-Dried Tomatoes'='G';
  'Chickpeas'='G'; 'Condensed French Onion Soup'='G'; 'Hominy'='G';
  'Coconut Milk'='G'; 'Peanut Butter'='G'; 'Fries'='G';
  'Tomatillos'='V'; 'Shallots'='V'; 'Apple'='V';
  'Half and Half'='D';
  'Turkey Pepperoni'='P'
}

# ---- collect unique ingredients w/ frequency ----
$freq = @{}
foreach($r in $db.recipes){ foreach($i in $r.ingredients){ $freq[$i.item] = 1 + $(if($freq.ContainsKey($i.item)){$freq[$i.item]}else{0}) } }

$names = $freq.Keys | Sort-Object { -$freq[$_] }, { $_ }
$ing = @(); $idxOf = @{}
foreach($n in $names){
  $isSt = $staples -contains $n
  $cat = 'S'
  if(-not $isSt){ foreach($rule in $cats){ if($n -match $rule.rx){ $cat = $rule.c; break } } } else { $cat = 'T' }
  if($override.ContainsKey($n)){ $cat = $override[$n] }
  $idxOf[$n] = $ing.Count
  $ing += ,@{ n=$n; b=$(if($boardOf.ContainsKey($n)){$boardOf[$n]}else{$null}); c=$cat; f=$freq[$n] }
}

# ---- recipes ----
$recs = @()
foreach($r in $db.recipes){
  # 2026-07-26: fallback cost = current-cheapest whole-package per serving (v2 manifest), the same
  # basis as the recipe pages/hub/top5. Legacy recipes-db figure only if the manifest lacks the slug.
  $cost = if($script:cheapPs -and $script:cheapPs.ContainsKey([string]$r.slug)){ $script:cheapPs[[string]$r.slug] }
          elseif($r.cost_per_serving_true){ $r.cost_per_serving_true } else { $r.cost_per_serving }
  $recs += ,@{ n=$r.name; s=$r.slug; sv=$r.servings; cal=$r.per_serving.calories; p=$r.per_serving.protein_g;
               c=[math]::Round($cost,2); i=@($r.ingredients | ForEach-Object { $idxOf[$_.item] }) }
}

# ---- emit JS (manual JSON to keep it compact + avoid PS5.1 quirks) ----
function JStr([string]$s){ '"' + ($s -replace '\\','\\\\' -replace '"','\"') + '"' }
$sb = New-Object System.Text.StringBuilder
[void]$sb.Append("var DIN={ing:[")
$first=$true
foreach($g in $ing){
  if(-not $first){[void]$sb.Append(',')}; $first=$false
  $b = if($g.b){ JStr $g.b } else { 'null' }
  [void]$sb.Append('{"n":'+(JStr $g.n)+',"b":'+$b+',"c":"'+$g.c+'","f":'+$g.f+'}')
}
[void]$sb.Append('],rec:[')
$first=$true
foreach($r in $recs){
  if(-not $first){[void]$sb.Append(',')}; $first=$false
  [void]$sb.Append('{"n":'+(JStr $r.n)+',"s":'+(JStr $r.s)+',"sv":'+$r.sv+',"cal":'+$r.cal+',"p":'+$r.p+',"c":'+$r.c+',"i":['+($r.i -join ',')+']}')
}
[void]$sb.Append(']};')
$js = $sb.ToString()
[IO.File]::WriteAllText("$dir\dinner-data.js", $js, (New-Object System.Text.UTF8Encoding($false)))

# ---- SPLICE INTO THE TOOL (2026-09-01) ----------------------------------------------------------
# This script wrote a .js file and stopped, and the header told a human to paste it. Nobody did:
# dinner-data.js was last written 2026-08-04 and the live tool was 74 recipes behind the catalog while
# still listing 7 retired ones. A build step whose last mile is a person's memory is not a build step.
# Literal string ops between markers, exactly as build-cheapnow-data.ps1 has always done.
$spliced = $false
if (Test-Path $tool) {
  $html = [IO.File]::ReadAllText($tool)
  $m1 = '/*DIN-DATA*/'; $m2 = '/*DIN-END*/'
  $a = $html.IndexOf($m1); $b = $html.IndexOf($m2)
  if ($a -ge 0 -and $b -gt $a) {
    $html = $html.Substring(0, $a + $m1.Length) + $js + $html.Substring($b)
    [IO.File]::WriteAllText($tool, $html, (New-Object System.Text.UTF8Encoding($false)))
    $spliced = $true
  }
}

"WROTE dinner-data.js  ($([math]::Round((Get-Item "$dir\dinner-data.js").Length/1KB,1)) KB)  ingredients=$($ing.Count) recipes=$($recs.Count)"
if ($spliced) { "SPLICED into dinner-tonight-tool.html  ($([math]::Round((Get-Item $tool).Length/1KB,1)) KB total)" }
else { "WARNING: markers not found in $tool - data NOT spliced, the live tool will stay behind" }
"board_id coverage: $(( $ing | Where-Object { $_.b } ).Count) of $($ing.Count) ingredients have live-price ids"
""
"--- CATEGORY REVIEW (eyeball for miscategorized items) ---"
foreach($c in 'P','V','G','D','S','T'){
  $label = @{P='PROTEIN';V='VEG/FRESH';G='GRAIN/PANTRY';D='DAIRY/EGG';S='SAUCE/OTHER';T='STAPLE'}[$c]
  ""; "== $label =="
  ($ing | Where-Object { $_.c -eq $c } | ForEach-Object { "$($_.f)x $($_.n)" }) -join "`n"
}