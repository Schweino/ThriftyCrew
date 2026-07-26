# build-r300-board-map.ps1 - Post-publish close-out fix (2026-07-25 review).
# The r100 run shipped r100\r100-board-map.json so gen-planner-data could feed-price r100 item names.
# The r300 run never produced its equivalent, so 236 r300 ingredient lines (incl Turkey Breast, Pork
# Shoulder, Beef Flank/Sirloin Steak) had no bid in the Meal Plan Builder and showed as unpriced.
#
# Sources (all already audited by the r300 pipeline - no new price logic):
#   - recipes-db.json          r300 rows carry ingredient-level item_id == board/feed id (audit ruling)
#   - built\*.body.html        scaler payloads carry the UNIT-RECONCILED gpu per (item, bid) from
#                              build-specs' Resolve-ScalerGpu (calibrated against the live feed unit)
#   - ..\..\grocery\out\smp-feed.json  the live feed (bid must exist + unit for standard-unit gpu)
#
# Guards (never guess):
#   - a NAME goes in the map only if its item_id is UNIQUE across every r300 row that uses that name
#   - gpu comes from the scaler payloads; all occurrences for (name,bid) must agree within 0.01,
#     else the name is SKIPPED and listed
#   - bid must exist in the feed
#   - names already covered by r100-board-map or ingredient-map are left alone (precedence unchanged)
$ErrorActionPreference='Stop'
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path   # meal-prep\r300
$mp    = Split-Path -Parent $here                          # meal-prep
$db    = (Get-Content (Join-Path $mp 'recipes-db.json') -Raw | ConvertFrom-Json).recipes
$feed  = (Get-Content (Join-Path $mp '..\grocery\out\smp-feed.json') -Raw | ConvertFrom-Json).ingredients
$slugs = @{}; Get-Content (Join-Path $here 'specs-ready.txt') | ForEach-Object { $slugs[$_]=1 }

$feedUnit=@{}; foreach($p in $feed.PSObject.Properties){ $feedUnit[$p.Name]=[string]$p.Value.unit }

# names already mapped by the existing sources (do not shadow them)
$covered=@{}
foreach($p in ((Get-Content (Join-Path $mp 'r100\r100-board-map.json') -Raw | ConvertFrom-Json).map).PSObject.Properties){ $covered[$p.Name]=1 }
foreach($m in ((Get-Content (Join-Path $mp 'ingredient-map.json') -Raw | ConvertFrom-Json).mappings)){ $covered[[string]$m.item]=1 }

# 1) name -> set of item_ids across r300 rows
$nameIds=@{}
foreach($r in $db){ if(-not $slugs[$r.slug]){continue}
  foreach($ing in $r.ingredients){
    if(-not $ing.item_id){ continue }
    $n=[string]$ing.item
    if(-not $nameIds.ContainsKey($n)){ $nameIds[$n]=@{} }
    $nameIds[$n][[string]$ing.item_id]=1
  }
}

# 2) gpu per (bid) from the built scaler payloads (unit-reconciled by build-specs)
$gpuSet=@{}   # bid -> @{ vals = hashset of gpu }
Get-ChildItem (Join-Path $here 'built') -Filter '*.body.html' | ForEach-Object {
  $b=[IO.File]::ReadAllText($_.FullName,[Text.Encoding]::UTF8)
  $m=[regex]::Match($b,'class="smp-sc-data">(\{.*?\})</script>','Singleline')
  if(-not $m.Success){ return }
  $d=$m.Groups[1].Value | ConvertFrom-Json
  foreach($ing in $d.ing){
    if(-not $ing.bid -or -not $ing.gpu){ continue }
    $bid=[string]$ing.bid
    if(-not $gpuSet.ContainsKey($bid)){ $gpuSet[$bid]=@{} }
    $gpuSet[$bid][([double]$ing.gpu).ToString('0.####')]=1
  }
}

# 3) build the map for names not already covered
$UNIT_G=@{ lb=453.592; oz=28.3495; floz=29.57; kg=1000.0; g=1.0 }
$map=[ordered]@{}; $skipped=New-Object System.Collections.Generic.List[string]
foreach($n in ($nameIds.Keys | Sort-Object)){
  if($covered.ContainsKey($n)){ continue }
  $ids=@($nameIds[$n].Keys)
  if($ids.Count -ne 1){ $skipped.Add("$n :: AMBIGUOUS item_ids: $($ids -join ', ')"); continue }
  $bid=$ids[0]
  if(-not $feedUnit.ContainsKey($bid)){ $skipped.Add("$n :: bid '$bid' not in feed"); continue }
  $fu=$feedUnit[$bid]
  $gpu=$null
  if($UNIT_G.ContainsKey($fu)){ $gpu=$UNIT_G[$fu] }
  elseif($gpuSet.ContainsKey($bid)){
    $vals=@($gpuSet[$bid].Keys | ForEach-Object { [double]$_ })
    $mn=($vals | Measure-Object -Minimum).Minimum; $mx=($vals | Measure-Object -Maximum).Maximum
    if(($mx-$mn) -le 0.01){ $gpu=$vals[0] } else { $skipped.Add("$n :: gpu disagrees for bid '$bid' ($($vals -join ', '))"); continue }
  } else { $skipped.Add("$n :: non-standard feed unit '$fu' and no scaler gpu for bid '$bid'"); continue }
  # unit recorded AS the feed unit, so gen-planner-data's reconciliation is a no-op (already calibrated)
  $map[$n]=[ordered]@{ bid=$bid; gpu=$gpu; unit=$fu }
}

$doc=[ordered]@{
  readme='item NAME -> {bid,gpu,unit} for r300 recipe ingredients, same shape as r100-board-map.json. Built by build-r300-board-map.ps1 from recipes-db item_ids (audited board ids) + the built scaler payloads'' unit-reconciled gpu. gen-planner-data loads it after the r100 map, before ingredient-map.'
  map=$map
}
$json = $doc | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText((Join-Path $here 'r300-board-map.json'),$json,(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("r300-board-map.json: {0} names mapped, {1} skipped" -f $map.Count,$skipped.Count)
$skipped | ForEach-Object { "  SKIP: $_" }
