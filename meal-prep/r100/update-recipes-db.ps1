# update-recipes-db.ps1 - Adds the published R100 recipes to ..\recipes-db.json (backup + never-shrink).
# New fields per recipe: source_url, source_site (Brad's credit requirement). Run AFTER publish verifies.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dbPath = Join-Path $here '..\recipes-db.json'
$db = Get-Content $dbPath -Raw | ConvertFrom-Json
$before = $db.recipes.Count
$have=@{}; foreach($r in $db.recipes){ $have[$r.slug]=1 }
$ready = Get-Content (Join-Path $here 'specs-ready.txt') | Where-Object { $_ }
$today = Get-Date -Format 'yyyy-MM-dd'
$added=0
foreach($slug in $ready){
  if($have.ContainsKey($slug)){ continue }
  $s = Get-Content (Join-Path $here "specs\$slug.json") -Raw | ConvertFrom-Json
  $ings=@(); foreach($sc in $s.scaler.ing){ $ings += [pscustomobject]@{ item=$sc.item; grams=[int]$sc.grams; buy=$sc.buy } }
  $db.recipes += [pscustomobject]@{
    name=$s.name; slug=$slug; visibility='paid'; cuisine=$s.cuisine; servings=14
    ingredients=@($ings)
    grocery_list=@($s.head.recipeIngredient)
    per_serving=[pscustomobject]@{ calories=[int]$s.stat.cal; protein_g=[int]$s.stat.protein; carbs_g=[int]$s.stat.carbs; fat_g=[int]$s.stat.fat }
    batch=[pscustomobject]@{ calories=([int]$s.stat.cal*14); protein_g=([int]$s.stat.protein*14); carbs_g=([int]$s.stat.carbs*14); fat_g=([int]$s.stat.fat*14) }
    cost_per_serving=[double]$s.cost_per_serving; cost_batch=[double]$s.cost_batch
    cost_batch_true=[double]$s.cost_batch_true; cost_per_serving_true=[double]$s.cost_per_serving_true
    published=$today
    source_url=$s.source_url; source_site=$s.source_site
    notes=('R100 build ' + $today + '; adapted from ' + $s.source_site + '; macros computed from food-macros-db')
  }
  $added++
}
if(($before+$added) -lt $before){ throw 'never-shrink violation' }
Copy-Item $dbPath (Join-Path $here ('recipes-db.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'))
$db | ConvertTo-Json -Depth 8 | Out-File $dbPath -Encoding utf8
Write-Output ("recipes-db: $before -> $($before+$added) (+$added)")
