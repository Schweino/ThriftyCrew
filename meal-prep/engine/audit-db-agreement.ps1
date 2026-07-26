# audit-db-agreement.ps1 - drift guard between the TWO recipe masters (by design: recipes-db.json is
# the catalog INDEX, db\recipes\<slug>.json are the SPECS). Nothing enforced their agreement until
# 2026-07-26 (estate audit finding): a recipe added to one but not the other, or a protein/visibility
# edit applied to only one, silently splits the surfaces (rotation/top5 read the index; cards read specs).
# Checks: slug sets match both ways; protein agrees; visibility agrees; spec scaler bids exist in
# db\ingredients.json (a gpu/bid recalibration must reach both, or cheapest_ps diverges from cost basis).
# Exit 0 clean, 1 drift found (caller alerts; non-fatal in the daily chain).
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$issues = New-Object System.Collections.Generic.List[string]

$idx = (Get-Content (Join-Path $mp 'recipes-db.json') -Raw | ConvertFrom-Json).recipes
$idxBySlug=@{}; foreach($r in $idx){ if($r.slug){ $idxBySlug[[string]$r.slug]=$r } }
$specSlugs=@{}
$specs=@{}
foreach($sf in (Get-ChildItem (Join-Path $mp 'db\recipes\*.json'))){
  $specSlugs[$sf.BaseName]=1
  $specs[$sf.BaseName]=$sf.FullName
}
foreach($s in $idxBySlug.Keys){ if(-not $specSlugs.ContainsKey($s)){ $issues.Add("INDEX-ONLY: $s (recipes-db row has no db\recipes spec)") } }
foreach($s in $specSlugs.Keys){ if(-not $idxBySlug.ContainsKey($s)){ $issues.Add("SPEC-ONLY: $s (db\recipes spec has no recipes-db row)") } }

$items=@{}
foreach($row in (Get-Content (Join-Path $mp 'db\ingredients.json') -Raw | ConvertFrom-Json)){ $items[[string]$row.item]=$row }
$bidMiss=0
foreach($s in $specSlugs.Keys){
  if(-not $idxBySlug.ContainsKey($s)){ continue }
  $spec = Get-Content $specs[$s] -Raw | ConvertFrom-Json
  $row = $idxBySlug[$s]
  # protein: normalize the r100-era 'ground X' spec format to the canonical 4-class before comparing
  $sp = ([string]$spec.protein) -replace '^ground\s+',''
  if($sp -ne [string]$row.protein){ $issues.Add("PROTEIN drift: $s spec='$($spec.protein)' index='$($row.protein)'") }
  # visibility is deliberately NOT compared: recipes-db + Ghost own it (the free-dinner rotation flips
  # both weekly); the spec field is only the default for a FIRST publish. engine\publish preserves the
  # live post's visibility and bases its leak-check on the LIVE visibility, not the spec.
  foreach($ing in $spec.scaler.ing){
    $key = if($ing.PSObject.Properties.Name -contains 'canon' -and $ing.canon){ [string]$ing.canon } else { [string]$ing.item }
    if(-not $items.ContainsKey($key)){ $bidMiss++; if($bidMiss -le 8){ $issues.Add("NO-DB-ITEM: $s ingredient '$key' missing from db\ingredients.json") } }
  }
}
if($bidMiss -gt 8){ $issues.Add("... plus $($bidMiss-8) more missing-item lines") }

if($issues.Count -eq 0){ Write-Output ("db-agreement: CLEAN ({0} recipes, index==specs)" -f $specSlugs.Count); exit 0 }
Write-Output ("db-agreement: {0} drift issue(s)" -f $issues.Count)
$issues | Select-Object -First 25 | ForEach-Object { Write-Output ("  ! " + $_) }
exit 1