# update-recipes-db5.ps1 - v5 FINAL: manual JSON string construction per recipe (no serializer at all;
# every PS5.1 JSON serializer failed at this job: ConvertTo-Json OOM/AOOR, JavaScriptSerializer
# InvalidOperation). Parsing DOES work, so each hand-built part is parse-validated individually,
# then spliced into the backup's known-valid text. Final check: slug count in output == 113+new.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Web.Extensions
$js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$js.MaxJsonLength = [int]::MaxValue

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dbPath = Join-Path $here '..\recipes-db.json'
$backup = Get-ChildItem $here -Filter 'recipes-db.backup-*.json' | Sort-Object Name -Descending | Select-Object -First 1
$raw = [IO.File]::ReadAllText($backup.FullName)
$iClose = $raw.LastIndexOf(']')
if($raw.Substring($iClose) -notmatch '^\]\s*\}\s*$'){ throw 'unexpected tail' }

$have=@{}
foreach($m in [regex]::Matches($raw, '"slug"\s*:\s*"([^"]+)"')){ $have[$m.Groups[1].Value]=1 }
Write-Output ("backup slugs: " + $have.Count)

function J([string]$s){
  if($null -eq $s){ return '""' }
  $sb=New-Object Text.StringBuilder
  [void]$sb.Append('"')
  foreach($ch in $s.ToCharArray()){
    switch($ch){
      '"'{[void]$sb.Append('\"')} '\'{[void]$sb.Append('\\')}
      "`n"{[void]$sb.Append('\n')} "`r"{[void]$sb.Append('\r')} "`t"{[void]$sb.Append('\t')}
      default{ if([int]$ch -lt 32){ [void]$sb.AppendFormat('\u{0:x4}',[int]$ch) } else { [void]$sb.Append($ch) } }
    }
  }
  [void]$sb.Append('"')
  $sb.ToString()
}
function N($v){ ([double]$v).ToString([Globalization.CultureInfo]::InvariantCulture) }

$ready = Get-Content (Join-Path $here 'specs-ready.txt') | Where-Object { $_ }
$today = Get-Date -Format 'yyyy-MM-dd'
$parts = New-Object System.Collections.Generic.List[string]
$added=0
foreach($slug in $ready){
  if($have.ContainsKey($slug)){ continue }
  $s = $js.DeserializeObject([IO.File]::ReadAllText((Join-Path $here "specs\$slug.json")))
  $stat=$s['stat']
  $ingParts=@()
  foreach($sc in $s['scaler']['ing']){
    $ingParts += ('{"item":' + (J $sc['item']) + ',"grams":' + [int]$sc['grams'] + ',"buy":' + (J $sc['buy']) + '}')
  }
  $glParts=@()
  foreach($g in $s['head']['recipeIngredient']){ $glParts += (J ([string]$g)) }
  $rec = '{' +
    '"name":' + (J $s['name']) + ',"slug":' + (J $slug) + ',"visibility":"paid","cuisine":' + (J $s['cuisine']) + ',"servings":14,' +
    '"ingredients":[' + ($ingParts -join ',') + '],' +
    '"grocery_list":[' + ($glParts -join ',') + '],' +
    '"per_serving":{"calories":' + [int]$stat['cal'] + ',"protein_g":' + [int]$stat['protein'] + ',"carbs_g":' + [int]$stat['carbs'] + ',"fat_g":' + [int]$stat['fat'] + '},' +
    '"batch":{"calories":' + ([int]$stat['cal']*14) + ',"protein_g":' + ([int]$stat['protein']*14) + ',"carbs_g":' + ([int]$stat['carbs']*14) + ',"fat_g":' + ([int]$stat['fat']*14) + '},' +
    '"cost_per_serving":' + (N $s['cost_per_serving']) + ',"cost_batch":' + (N $s['cost_batch']) + ',' +
    '"cost_batch_true":' + (N $s['cost_batch_true']) + ',"cost_per_serving_true":' + (N $s['cost_per_serving_true']) + ',' +
    '"cost_pantry_add":' + (N $s['cost_pantry_add']) + ',"cost_first_run":' + (N $s['cost_first_run']) + ',' +
    '"published":' + (J $today) + ',"source_url":' + (J $s['source_url']) + ',"source_site":' + (J $s['source_site']) + ',' +
    '"notes":' + (J ('R100 build ' + $today + '; adapted from ' + $s['source_site'] + '; macros computed from food-macros-db')) +
  '}'
  # parse-validate this part alone (parsing works; serialization was the broken half)
  $null = $js.DeserializeObject($rec)
  $parts.Add($rec)
  $added++
}
Write-Output ("built + parse-validated new recipes: " + $added)

$out = $raw.Substring(0, $iClose) + ',' + ($parts -join ',') + $raw.Substring($iClose)
$slugCount = [regex]::Matches($out, '"slug"\s*:\s*"([^"]+)"').Count
if($slugCount -ne ($have.Count + $added)){ throw ("slug count {0} != {1}" -f $slugCount, ($have.Count+$added)) }
[IO.File]::WriteAllText($dbPath, $out, (New-Object Text.UTF8Encoding($false)))
Write-Output ("recipes-db WRITTEN: {0} total recipes ({1} + {2} new)" -f $slugCount, $have.Count, $added)
