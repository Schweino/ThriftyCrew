# update-recipes-db3.ps1 - v3 TEXTUAL SPLICE. PS5.1 ConvertTo-Json cannot re-serialize the big graph
# (OOM in v1, ArgumentOutOfRange in v2), but PARSING works fine. So: keep the backup's bytes verbatim,
# serialize ONLY the 100 new small recipe objects (individually, compact), splice them before the final
# "]\n}" of the recipes array, validate the result by parsing, then write.
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dbPath = Join-Path $here '..\recipes-db.json'
$backup = Get-ChildItem $here -Filter 'recipes-db.backup-*.json' | Sort-Object Name -Descending | Select-Object -First 1
$raw = [IO.File]::ReadAllText($backup.FullName)

# find the LAST ']' (closes recipes array) - verify the tail shape first
$iClose = $raw.LastIndexOf(']')
if($iClose -lt 0){ throw 'no closing bracket' }
$tail = $raw.Substring($iClose)
if($tail -notmatch '^\]\s*\}\s*$'){ throw ('unexpected tail: ' + $tail.Substring(0,[Math]::Min(40,$tail.Length))) }

$have = @{}
# collect existing slugs from raw text (cheap regex; slugs are "slug": "...")
foreach($m in [regex]::Matches($raw, '"slug"\s*:\s*"([^"]+)"')){ $have[$m.Groups[1].Value]=1 }
Write-Output ("backup: {0} existing slugs" -f $have.Count)

$ready = Get-Content (Join-Path $here 'specs-ready.txt') | Where-Object { $_ }
$today = Get-Date -Format 'yyyy-MM-dd'
$parts = New-Object System.Collections.Generic.List[string]
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
  $parts.Add(($rec | ConvertTo-Json -Depth 6 -Compress))
  $added++
}
Write-Output ("serialized {0} new recipes" -f $added)
$insert = ',' + ($parts -join ',')
$out = $raw.Substring(0, $iClose) + $insert + $raw.Substring($iClose)

# validate by parsing (parsing large JSON works fine in PS5.1)
$test = $out | ConvertFrom-Json
$total = $test.recipes.Count
if($total -ne ($have.Count + $added)){ throw ("validate: {0} != {1}+{2}" -f $total, $have.Count, $added) }
$src = @($test.recipes | Where-Object { $_.source_url }).Count
[IO.File]::WriteAllText($dbPath, $out, (New-Object Text.UTF8Encoding($false)))
Write-Output ("recipes-db WRITTEN: {0} recipes ({1} with source_url) VALIDATED" -f $total, $src)
