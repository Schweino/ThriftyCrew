# update-recipes-db2.ps1 - v2: restores from the backup, then appends the 100 R100 recipes using
# PER-RECIPE serialization (PS5.1 ConvertTo-Json OOMs on the whole 213-recipe graph; each recipe alone
# is tiny). Assembles the final JSON textually: {"readme":...,"recipes":[r1,r2,...]}.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dbPath = Join-Path $here '..\recipes-db.json'
$backup = Get-ChildItem $here -Filter 'recipes-db.backup-*.json' | Sort-Object Name -Descending | Select-Object -First 1
if(-not $backup){ throw 'no backup found' }
$db = Get-Content $backup.FullName -Raw | ConvertFrom-Json
$before = $db.recipes.Count
Write-Output ("restored from {0}: {1} recipes" -f $backup.Name, $before)

$have=@{}; foreach($r in $db.recipes){ $have[$r.slug]=1 }
$ready = Get-Content (Join-Path $here 'specs-ready.txt') | Where-Object { $_ }
$today = Get-Date -Format 'yyyy-MM-dd'

$sb = New-Object Text.StringBuilder
[void]$sb.Append('{"readme":')
[void]$sb.Append(($db.readme | ConvertTo-Json -Depth 3))
[void]$sb.Append(',"recipes":[')
$first = $true
foreach($r in $db.recipes){
  if(-not $first){ [void]$sb.Append(',') }
  [void]$sb.Append(($r | ConvertTo-Json -Depth 8 -Compress))
  $first = $false
}
$added=0
foreach($slug in $ready){
  if($have.ContainsKey($slug)){ continue }
  $s = Get-Content (Join-Path $here "specs\$slug.json") -Raw | ConvertFrom-Json
  $ings=@(); foreach($sc in $s.scaler.ing){ $ings += [pscustomobject]@{ item=$sc.item; grams=[int]$sc.grams; buy=$sc.buy } }
  $rec = [pscustomobject]@{
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
  if(-not $first){ [void]$sb.Append(',') }
  [void]$sb.Append(($rec | ConvertTo-Json -Depth 8 -Compress))
  $first = $false
  $added++
}
[void]$sb.Append(']}')
$json = $sb.ToString()
# validate before writing
$test = $json | ConvertFrom-Json
if($test.recipes.Count -ne ($before + $added)){ throw ("validation: expected {0}, got {1}" -f ($before+$added), $test.recipes.Count) }
[IO.File]::WriteAllText($dbPath, $json, (New-Object Text.UTF8Encoding($false)))
Write-Output ("recipes-db: {0} -> {1} (+{2})  VALIDATED" -f $before, $test.recipes.Count, $added)
