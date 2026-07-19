# merge-db.ps1 - Merges verified label data (usda-verified.json + labels-P1/P2/P3.json) into
# ..\food-macros-db.json. Safety: timestamped backup, never-shrink, Atwater guard on every new row,
# no silent overwrite of existing items (conflict -> report + skip).
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dbPath = Join-Path $here '..\food-macros-db.json'
$db = Get-Content $dbPath -Raw | ConvertFrom-Json
$existing=@{}; foreach($i in $db.items){ $existing[$i.item]=1 }
$before = $db.items.Count

# required new items (from normalization)
$required = (Get-Content (Join-Path $here 'new-items.json') -Raw | ConvertFrom-Json) | ForEach-Object { $_.item }

function AtwaterOK($cal,$p,$c,$f){
  $est = 4*$p + 4*$c + 9*$f
  if($cal -le 20){ return $true }        # tiny servings: label rounding dominates
  return ([Math]::Abs($est-$cal)/[Math]::Max($cal,1)) -le 0.25
}

$added=@(); $skipped=@(); $conflicts=@(); $atwaterFail=@()

# 1) usda-verified (authoritative for its 48)
$uv = (Get-Content (Join-Path $here 'usda-verified.json') -Raw | ConvertFrom-Json).items
foreach($r in $uv){
  if($r.needs_verify){ $skipped += ($r.item + ' (still needs_verify)'); continue }
  if($existing.ContainsKey($r.item)){ $conflicts += $r.item; continue }
  if(-not (AtwaterOK $r.calories $r.protein_g $r.carbs_g $r.fat_g)){ $atwaterFail += ($r.item + " ($($r.calories) vs 4/4/9)"); continue }
  $db.items += [pscustomobject]@{
    item=$r.item; brand=$r.brand; serving_grams=[double]$r.serving_grams
    serving_qty=$r.serving_qty; serving_unit=$r.serving_unit
    calories=[double]$r.calories; protein_g=[double]$r.protein_g; carbs_g=[double]$r.carbs_g; fat_g=[double]$r.fat_g
    notes=(('' + $r.notes).Trim() + ' [R100 verified: ' + $r.verify_source + ']').Trim()
  }
  $existing[$r.item]=1; $added += $r.item
}

# 2) agent label files (only rows with real label macros; P3 spice rows w/o labels are price-only)
foreach($f in @('labels-P1.json','labels-P2.json','labels-P3.json')){
  $p = Join-Path $here $f
  if(-not (Test-Path $p)){ Write-Output ("MISSING " + $f + " - run again after it lands"); continue }
  $rows = Get-Content $p -Raw | ConvertFrom-Json
  foreach($r in $rows){
    # normalize item-name variants from agents
    if($r.item -match '^Pasta Shells'){ $r.item = 'Pasta Shells' }
    if($r.item -match '^Chili Crisp'){ $r.item = 'Chili Crisp' }
    if($r.status -notlike 'verified*'){ $skipped += ($r.item + ' (' + $r.status + ')'); continue }
    if($null -eq $r.serving_grams -or $null -eq $r.calories){ continue }   # price-only row
    if($existing.ContainsKey($r.item)){ continue }                          # usda-verified or DB already has it
    if(-not (AtwaterOK $r.calories $r.protein_g $r.carbs_g $r.fat_g)){ $atwaterFail += ($r.item + " [$f]"); continue }
    $db.items += [pscustomobject]@{
      item=$r.item; brand=$r.brand; serving_grams=[double]$r.serving_grams
      serving_qty=1; serving_unit=$r.serving_desc
      calories=[double]$r.calories; protein_g=[double]$r.protein_g; carbs_g=[double]$r.carbs_g; fat_g=[double]$r.fat_g
      notes=('label: ' + $r.product + ' [R100 ' + $f + ']')
    }
    $existing[$r.item]=1; $added += $r.item
  }
}

# 2b) documented manual row: Berbere Seasoning (manufacturer publishes no nutrition panel - spice-blend
# label exemption). Entered parallel to paprika, its dominant ingredient; macro impact ~3 cal/serving max.
if(-not $existing.ContainsKey('Berbere Seasoning')){
  $db.items += [pscustomobject]@{
    item='Berbere Seasoning'; brand='Frontier Co-op'; serving_grams=2.3; serving_qty=1; serving_unit='tsp'
    calories=6; protein_g=0; carbs_g=1; fat_g=0
    notes='no label panel published (spice-exempt); values parallel to paprika (dominant ingredient), macro-immaterial at recipe amounts [R100 documented-manual]'
  }
  $existing['Berbere Seasoning']=1; $added += 'Berbere Seasoning'
}

# 3) report coverage vs required
$missing = @($required | Where-Object { -not $existing.ContainsKey($_) })

$after = $db.items.Count
if($after -lt $before){ throw 'NEVER-SHRINK VIOLATION - aborting' }

# backup + write
$stamp = Get-Date -Format 'yyyy-MM-dd-HHmmss'
Copy-Item $dbPath (Join-Path $here ("food-macros-db.backup-$stamp.json"))
$db | ConvertTo-Json -Depth 6 | Out-File $dbPath -Encoding utf8

Write-Output ("DB: {0} -> {1} items (+{2})" -f $before,$after,($after-$before))
Write-Output ("added: " + ($added.Count))
if($conflicts){ Write-Output ("conflicts (already in DB, untouched): " + ($conflicts -join ', ')) }
if($atwaterFail){ Write-Output ("ATWATER FAIL (excluded!): " + ($atwaterFail -join ', ')) }
if($skipped){ Write-Output ("skipped: " + ($skipped -join '; ')) }
Write-Output ("STILL MISSING vs required 81: " + $missing.Count + ($(if($missing){': ' + ($missing -join ', ')}else{''})))
