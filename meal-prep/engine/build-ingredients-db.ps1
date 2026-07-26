# build-ingredients-db.ps1 - constructs db\ingredients.json, the ONE canonical ingredient store.
# One row per canonical ingredient name, merging every place item knowledge currently lives:
#   macros/brand ......... food-macros-db.json (items)
#   board mapping ........ ingredient-map.json + r100\r100-board-map.json + r300\mapper\map-extensions.json
#                          + orig\mapper\map-extensions.json  (item -> bid, gpu, unit)
#   BUY package .......... the hardcoded $PKG tables inside r100/r300/orig cost-engine.ps1 (parsed here)
#   PANTRY package ....... r100/r300/orig pantry-packages.json
#   drained yields ....... densities.json ('can' = drained grams per can)
#   label prices ......... r100 labels-P*.json (agent-captured package prices for untracked items)
# Merge precedence (later wins): r100 -> r300 -> orig, EXCEPT conflicts are REPORTED loudly - nothing
# resolves silently. Run with -Audit to only print the conflict report without writing.
param([switch]$Audit)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$LB=453.592; $OZ=28.3495

$rows=@{}   # name -> ordered hash (the eventual row)
function Row([string]$name){ if(-not $rows.ContainsKey($name)){ $rows[$name]=[ordered]@{ item=$name } }; $rows[$name] }
$conflicts=New-Object System.Collections.Generic.List[string]
function SetField([string]$name,[string]$field,$value,[string]$src){
  $r = Row $name
  if($r.Contains($field) -and $null -ne $r[$field] -and "$($r[$field])" -ne "$value"){
    $conflicts.Add(("{0} .{1}: '{2}' vs '{3}' (from {4} - later wins)" -f $name,$field,$r[$field],$value,$src))
  }
  $r[$field]=$value
}

# ---- 1. macros + brand ----
$fm = (Get-Content (Join-Path $mp 'food-macros-db.json') -Raw | ConvertFrom-Json).items
foreach($i in $fm){
  $r = Row $i.item
  $r['brand']=[string]$i.brand; $r['serving_grams']=$i.serving_grams; $r['serving_qty']=$i.serving_qty; $r['serving_unit']=[string]$i.serving_unit
  $r['calories']=$i.calories; $r['protein_g']=$i.protein_g; $r['carbs_g']=$i.carbs_g; $r['fat_g']=$i.fat_g
  if($i.PSObject.Properties.Name -contains 'notes' -and $i.notes){ $r['notes']=[string]$i.notes }
}

# ---- 2. board mappings ----
# Precedence: the VETTED mapper eras override in order (ingredient-map -> r100-board-map -> r300-ext),
# exactly as the r100/r300 engines merged them. The orig extension is FILL-ONLY: it was seeded from the
# old original cards' harvested scaler payloads (legacy ids, blank units, pre-16x-fix gpus), so it may
# only cover items no vetted map knows - never override one. Where the old original cards used a legacy
# mapping for a SHARED item, the unified engine now prices it the vetted way; those diffs are FIXES
# (golden test lists them; affected originals get re-anchored + republished).
function LoadMap([string]$path,[string]$label,[switch]$FillOnly){
  if(-not (Test-Path $path)){ return }
  $raw = Get-Content $path -Raw | ConvertFrom-Json
  $rows2=@()
  if($raw.PSObject.Properties.Name -contains 'map'){ foreach($p in $raw.map.PSObject.Properties){ $rows2 += [pscustomobject]@{ item=$p.Name; bid=[string]$p.Value.bid; gpu=[double]$p.Value.gpu; unit=[string]$p.Value.unit; board=$null } } }
  if($raw.PSObject.Properties.Name -contains 'mappings'){ foreach($m in $raw.mappings){ $rows2 += [pscustomobject]@{ item=$m.item; bid=[string]$m.board_id; gpu=[double]$m.grams_per_unit; unit=[string]$m.unit; board=$(if($m.PSObject.Properties.Name -contains 'board'){[string]$m.board}else{$null}) } } }
  foreach($m in $rows2){
    if($FillOnly -and $rows.ContainsKey($m.item) -and $rows[$m.item].Contains('bid')){ continue }
    SetField $m.item 'bid' $m.bid $label; SetField $m.item 'gpu' $m.gpu $label
    if($m.unit){ SetField $m.item 'unit' $m.unit $label }
    if($m.board){ SetField $m.item 'board' $m.board $label }
  }
}
LoadMap (Join-Path $mp 'ingredient-map.json') 'ingredient-map'
LoadMap (Join-Path $mp 'archive\r100\r100-board-map.json') 'r100-board-map'
LoadMap (Join-Path $mp 'archive\r300\mapper\map-extensions.json') 'r300-extensions'
LoadMap (Join-Path $mp 'archive\orig\mapper\map-extensions.json') 'orig-extensions' -FillOnly

# ---- 3. BUY packages from the hardcoded $PKG tables ----
function LoadPkgTable([string]$enginePath,[string]$label){
  if(-not (Test-Path $enginePath)){ return }
  $src = Get-Content $enginePath -Raw
  $m = [regex]::Match($src,'\$PKG\s*=\s*@\{(.*?)\n\}','Singleline')
  if(-not $m.Success){ Write-Warning ("no `$PKG table in " + $label); return }
  $body = $m.Groups[1].Value
  foreach($e in [regex]::Matches($body,"'([^']+)'\s*=\s*@\{g=([^;]+);label='([^']*)'\}")){
    $name=$e.Groups[1].Value
    $gExpr=$e.Groups[2].Value.Trim()
    $g = switch -Regex ($gExpr){
      '^\$LB$' { $LB } '^\$OZ$' { $OZ }
      '^[\d.]+$' { [double]$gExpr }
      '^\$LB\*([\d.]+)$' { $LB*[double]$Matches[1] }
      '^([\d.]+)\*\$LB$' { [double]$Matches[1]*$LB }
      '^([\d.]+)\*\$OZ$' { [double]$Matches[1]*$OZ }
      '^\$OZ\*([\d.]+)$' { $OZ*[double]$Matches[1] }
      default { $null }
    }
    if($null -eq $g){ $conflicts.Add(("PKG parse miss {0} in {1}: g expr '{2}'" -f $name,$label,$gExpr)); continue }
    SetField $name 'buy_pkg_g' ([math]::Round($g,3)) $label
    SetField $name 'buy_pkg_label' ($e.Groups[3].Value) $label
  }
}
LoadPkgTable (Join-Path $mp 'archive\r100\cost-engine.ps1') 'r100-PKG'
LoadPkgTable (Join-Path $mp 'archive\r300\cost-engine.ps1') 'r300-PKG'
LoadPkgTable (Join-Path $mp 'archive\orig\cost-engine.ps1') 'orig-PKG'

# ---- 4. PANTRY packages ----
function LoadPantry([string]$path,[string]$label){
  if(-not (Test-Path $path)){ return }
  foreach($p in ((Get-Content $path -Raw | ConvertFrom-Json).packages).PSObject.Properties){
    SetField $p.Name 'pantry_pkg_g' ([double]$p.Value.g) $label
    SetField $p.Name 'pantry_pkg_label' ([string]$p.Value.label) $label
  }
}
LoadPantry (Join-Path $mp 'archive\r100\pantry-packages.json') 'r100-pantry'
LoadPantry (Join-Path $mp 'archive\r300\pantry-packages.json') 'r300-pantry'
LoadPantry (Join-Path $mp 'archive\orig\pantry-packages.json') 'orig-pantry'

# ---- 4b. BULK flags (pantry-staple path) from the most complete engine list (orig == r300 superset;
# r100's list is a strict subset, so the union is just orig's) ----
$bulkSrc = Get-Content (Join-Path $mp 'archive\orig\cost-engine.ps1') -Raw
$bm = [regex]::Match($bulkSrc,'\$BULK\s*=\s*@\((.*?)\)\s*\r?\n\r?\n','Singleline')
if(-not $bm.Success){ $bm = [regex]::Match($bulkSrc,'\$BULK\s*=\s*@\((.*?)\n\)','Singleline') }
if($bm.Success){
  $names = [regex]::Matches($bm.Groups[1].Value,"'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
  foreach($n in $names){ (Row $n)['bulk'] = $true }
  Write-Output ("bulk flags: {0}" -f @($names).Count)
} else { throw 'could not parse $BULK from orig engine' }

# ---- 5. drained yields (densities 'can') ----
$denPath = Join-Path $mp 'archive\r300\densities.json'
if(Test-Path $denPath){
  $dn = Get-Content $denPath -Raw | ConvertFrom-Json
  foreach($p in $dn.PSObject.Properties){
    if($p.Value.PSObject.Properties.Name -contains 'can'){ SetField $p.Name 'can_drained_g' ([double]$p.Value.can) 'densities' }
  }
}

# ---- 6. label package prices: kept as their OWN store (raw agent-captured rows; the engine applies
# SizeToGrams + canon folds at load, exactly as the per-run engines did). Union of every run's label
# files, later files win on a duplicate item (golden test arbitrates).
$labelRows=[ordered]@{}
foreach($lf in @(Get-ChildItem (Join-Path $mp 'archive\r100\labels-P*.json') -ErrorAction SilentlyContinue | Sort-Object Name) + @(Get-ChildItem (Join-Path $mp 'archive\r300\labels-r300.json') -ErrorAction SilentlyContinue)){
  foreach($l in (Get-Content $lf.FullName -Raw | ConvertFrom-Json)){
    if($l.PSObject.Properties.Name -contains 'item' -and $l.item){ $labelRows[[string]$l.item] = $l }
  }
}

# ---- report + write ----
# The override list is the audit record, not a blocker: the per-run engines already applied the same
# later-wins precedence (ingredient-map base, then run board-maps), so the merged operative values are
# behaviorally identical to what costed the live catalog. The golden test proves it numerically.
Write-Output ("rows: {0}   overrides recorded: {1}" -f $rows.Count, $conflicts.Count)
if($Audit){ $conflicts | ForEach-Object { Write-Output ("  ! " + $_) }; Write-Output "(audit only - nothing written)"; exit 0 }
New-Item -ItemType Directory -Force (Join-Path $mp 'db') | Out-Null
[IO.File]::WriteAllLines((Join-Path $mp 'db\ingredients-merge-log.txt'), @("merge overrides (later-wins, same precedence as the retired per-run engines) - " + (Get-Date -Format s)) + @($conflicts), (New-Object Text.UTF8Encoding($false)))
$out = $rows.GetEnumerator() | Sort-Object Name | ForEach-Object { [pscustomobject]$_.Value }
. (Join-Path $mp 'lib\json-db-io.ps1')
Save-JsonArray -Array @($out) -Path (Join-Path $mp 'db\ingredients.json') -Depth 4 | Out-Null
Save-JsonArray -Array @($labelRows.Values) -Path (Join-Path $mp 'db\label-prices.json') -Depth 4 | Out-Null
Write-Output ("wrote db\ingredients.json ({0} rows) + db\label-prices.json ({1} rows) + merge log" -f @($out).Count, $labelRows.Count)