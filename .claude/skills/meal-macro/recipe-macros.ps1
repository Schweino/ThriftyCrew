<#
  recipe-macros.ps1  -  Compute batch + per-serving macros for a recipe from the verified food DB.
  Ingredients passed as "Item Name|grams" strings (Item Name must match the DB 'item' exactly).
  Macros are scaled by grams using each item's serving_grams. Optionally pass -CostTotal for cost/serving.
  Usage:
    & recipe-macros.ps1 -Servings 8 -CostTotal 14.80 -Ingredients @('93/7 Ground Beef|907','Rice|400')
#>
param(
  [string]$DbPath="C:\Codex\ThriftyCrew\meal-prep\food-macros-db.json",
  [Parameter(Mandatory=$true)][string[]]$Ingredients,
  [Parameter(Mandatory=$true)][int]$Servings,
  [double]$CostTotal=0,
  [string]$Name="Recipe"
)
$data=(Get-Content $DbPath -Raw | ConvertFrom-Json).items
$tc=0.0;$tp=0.0;$tcarb=0.0;$tf=0.0;$missing=@()
Write-Output ("=== "+$Name+" ===")
foreach($line in $Ingredients){
  $parts=$line -split '\|'; $name=$parts[0].Trim(); $g=[double]$parts[1]
  $it=$data | Where-Object { $_.item -eq $name } | Select-Object -First 1
  if(-not $it){ $missing+=$name; Write-Output ("  !! NOT IN DB: "+$name); continue }
  $per=$g/[double]$it.serving_grams
  $c=$per*$it.calories; $p=$per*$it.protein_g; $cb=$per*$it.carbs_g; $f=$per*$it.fat_g
  $tc+=$c;$tp+=$p;$tcarb+=$cb;$tf+=$f
  Write-Output ("  {0,-34} {1,6:N0}g  {2,5:N0}cal {3,5:N1}p {4,5:N1}c {5,5:N1}f" -f $name,$g,$c,$p,$cb,$f)
}
Write-Output ("  ---------------------------------------------------------------")
Write-Output ("  BATCH TOTAL                       {0,5:N0}cal {1,5:N1}p {2,5:N1}c {3,5:N1}f" -f $tc,$tp,$tcarb,$tf)
Write-Output ("  PER SERVING (/{0})                  {1,5:N0}cal {2,5:N1}p {3,5:N1}c {4,5:N1}f" -f $Servings,($tc/$Servings),($tp/$Servings),($tcarb/$Servings),($tf/$Servings))
if($CostTotal -gt 0){ Write-Output ("  COST: batch `${0:N2}  ->  per serving `${1:N2}" -f $CostTotal,($CostTotal/$Servings)) }
if($missing.Count){ Write-Output ("  MISSING ITEMS: "+($missing -join ', ')) }
Write-Output ""
