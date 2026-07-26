# update-recipes-db4.ps1 - v4: textual splice + .NET JavaScriptSerializer for both the per-recipe
# serialization and the final validation parse (PS5.1 ConvertTo/From-Json proved unreliable at this size:
# OOM, ArgumentOutOfRange). Hashtables in, MaxJsonLength = int32 max.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Web.Extensions
$js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$js.MaxJsonLength = [int]::MaxValue

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dbPath = Join-Path $here '..\recipes-db.json'
$backup = Get-ChildItem $here -Filter 'recipes-db.backup-*.json' | Sort-Object Name -Descending | Select-Object -First 1
$raw = [IO.File]::ReadAllText($backup.FullName)
$iClose = $raw.LastIndexOf(']')
$tail = $raw.Substring($iClose)
if($tail -notmatch '^\]\s*\}\s*$'){ throw ('unexpected tail: ' + $tail) }

$have = @{}
foreach($m in [regex]::Matches($raw, '"slug"\s*:\s*"([^"]+)"')){ $have[$m.Groups[1].Value]=1 }
Write-Output ("backup slugs: " + $have.Count)

$ready = Get-Content (Join-Path $here 'specs-ready.txt') | Where-Object { $_ }
$today = Get-Date -Format 'yyyy-MM-dd'
$parts = New-Object System.Collections.Generic.List[string]
$added=0
foreach($slug in $ready){
  if($have.ContainsKey($slug)){ continue }
  $s = $js.DeserializeObject([IO.File]::ReadAllText((Join-Path $here "specs\$slug.json")))
  $ings = New-Object System.Collections.ArrayList
  foreach($sc in $s['scaler']['ing']){
    [void]$ings.Add(@{ item=$sc['item']; grams=[int]$sc['grams']; buy=$sc['buy'] })
  }
  $stat = $s['stat']
  $rec = @{
    name=$s['name']; slug=$slug; visibility='paid'; cuisine=$s['cuisine']; servings=14
    ingredients=$ings
    grocery_list=$s['head']['recipeIngredient']
    per_serving=@{ calories=[int]$stat['cal']; protein_g=[int]$stat['protein']; carbs_g=[int]$stat['carbs']; fat_g=[int]$stat['fat'] }
    batch=@{ calories=([int]$stat['cal']*14); protein_g=([int]$stat['protein']*14); carbs_g=([int]$stat['carbs']*14); fat_g=([int]$stat['fat']*14) }
    cost_per_serving=[double]$s['cost_per_serving']; cost_batch=[double]$s['cost_batch']
    cost_batch_true=[double]$s['cost_batch_true']; cost_per_serving_true=[double]$s['cost_per_serving_true']
    published=$today
    source_url=$s['source_url']; source_site=$s['source_site']
    notes=('R100 build ' + $today + '; adapted from ' + $s['source_site'] + '; macros computed from food-macros-db')
  }
  $parts.Add($js.Serialize($rec))
  $added++
}
Write-Output ("serialized new recipes: " + $added)
$out = $raw.Substring(0, $iClose) + ',' + ($parts -join ',') + $raw.Substring($iClose)

# validate with the same serializer
$test = $js.DeserializeObject($out)
$total = $test['recipes'].Count
if($total -ne ($have.Count + $added)){ throw ("validate mismatch: {0} vs {1}+{2}" -f $total,$have.Count,$added) }
$src=0; foreach($r in $test['recipes']){ if($r.ContainsKey('source_url') -and $r['source_url']){ $src++ } }
[IO.File]::WriteAllText($dbPath, $out, (New-Object Text.UTF8Encoding($false)))
Write-Output ("recipes-db WRITTEN + VALIDATED: {0} recipes, {1} with source_url" -f $total, $src)
