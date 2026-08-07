# audit-store-integrity.ps1 - the cross-store referential integrity guard.
#
# WHY THIS EXISTS (2026-08-07 architecture review). The estate keeps a fact in one place and COPIES it to
# several others, and until now nothing compared the copies. Every defect found during the 29-burrito batch
# was a seam, not a value:
#   * 6 ingredients had macros but no price row -> silently DROPPED from recipe cost
#   * 1 had a price row but no macro row       -> the spec builder THREW mid-run
#   * Rice was 185 g/cup in densities and 200 g/cup in the food DB
#   * Tortilla carried THREE different gram weights across three files, one contradicting its own package
#   * Turkey Bacon's bid pointed at PORK bacon and mispriced a live recipe for weeks
# Each is the same missing check. audit-db-agreement owns the TWO RECIPE MASTERS (recipes-db vs specs);
# this owns the INGREDIENT STORES (ingredients.json, food-macros-db, densities) and the spec->card layer.
#
# TIERS. HARD = a real defect with a wrong number or a dropped line behind it. WARN = a disagreement worth
# fixing that is not currently producing a wrong published number. The distinction matters: a guard that
# cries wolf gets ignored and joins the estate's dead-guard pile.
#
# Run:  .\audit-store-integrity.ps1            exit 0 clean, 1 = at least one HARD finding
#       .\audit-store-integrity.ps1 -SelfTest  frozen fixtures of each founding bug + its clean twin
#       .\audit-store-integrity.ps1 -ShowAll   no per-category cap
param([switch]$SelfTest,[switch]$ShowAll)
$ErrorActionPreference='Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp   = Split-Path -Parent $here

# ---- pure predicates, so the founding bugs can be pinned without touching a live file ----
function Test-MissingSide { param($Item,$InPrice,$InMacro)
  $m=@(); if(-not $InPrice){ $m+='no ingredients.json row (its cost line is silently dropped)' }
  if(-not $InMacro){ $m+='no food-macros-db row (the macro recompute cannot run)' }; return $m }
function Test-NameSplit { param([string]$ScalerName,[string]$MacroName)
  return ($ScalerName -ne $MacroName) }
function Test-BaseDrift { param([double]$DensityGrams,[double]$FoodDbGrams,[double]$Tol=0.05)
  if($FoodDbGrams -le 0 -or $DensityGrams -le 0){ return $false }
  return ([Math]::Abs($DensityGrams-$FoodDbGrams)/$FoodDbGrams -gt $Tol) }

if($SelfTest){
  $f=0
  function T($m,$c,$g){ if($c){ Write-Output ("ok    "+$m) } else { Write-Output ("FAIL  "+$m+"   got: "+$g); $script:f++ } }
  # FROZEN FIXTURES - each is a real defect this estate actually shipped, with the twin that must stay quiet.
  T 'MUST FIRE  macros but no price row (the 6 items that dropped out of recipe cost)' ((Test-MissingSide -Item 'Rotisserie Chicken' -InPrice $false -InMacro $true).Count -eq 1) 'no finding'
  T 'MUST FIRE  price row but no macros (the spinach that made build-v2-spec throw)'   ((Test-MissingSide -Item 'Spinach' -InPrice $true -InMacro $false).Count -eq 1) 'no finding'
  T 'MUST FIRE  neither side (the 19 unmapped names)'                                  ((Test-MissingSide -Item 'Panko Breadcrumbs' -InPrice $false -InMacro $false).Count -eq 2) 'wrong count'
  T 'CLEAN TWIN an item present on both sides'                                         ((Test-MissingSide -Item 'Rice' -InPrice $true -InMacro $true).Count -eq 0) 'spurious finding'
  T 'MUST FIRE  a spec naming one thing to cost and another to count macros'           (Test-NameSplit 'Green Olives' 'Olives') 'no finding'
  T 'CLEAN TWIN both arrays naming the same item'                                      (-not (Test-NameSplit 'Rice' 'Rice')) 'spurious finding'
  T 'MUST FIRE  Rice at 185 g/cup in densities against 200 in the food DB'             (Test-BaseDrift 185 200) 'no finding'
  T 'MUST FIRE  Ricotta at 246 g/cup against 62 (a 1/4-cup serving labelled a cup)'    (Test-BaseDrift 246 62) 'no finding'
  T 'CLEAN TWIN a base inside rounding (203 vs 200)'                                   (-not (Test-BaseDrift 203 200)) 'spurious finding'
  T 'CLEAN TWIN a missing base is not drift'                                           (-not (Test-BaseDrift 0 200)) 'spurious finding'
  if($f -eq 0){ Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

$hard = New-Object System.Collections.Generic.List[string]
$warn = New-Object System.Collections.Generic.List[string]

$ing = Get-Content (Join-Path $mp 'db\ingredients.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$ingm=@{}; foreach($r in $ing){ $ingm[[string]$r.item]=$r }
$fdb = Get-Content (Join-Path $mp 'food-macros-db.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$fdbm=@{}; foreach($g in $fdb.PSObject.Properties){ if($g.Value -is [array]){ foreach($x in $g.Value){ if($x.item -and -not $fdbm.ContainsKey($x.item)){ $fdbm[$x.item]=$x } } } }
$dens = (Get-Content (Join-Path $mp 'db\densities.json') -Raw -Encoding UTF8 | ConvertFrom-Json).items

# ---- 1+2: every item a spec USES must exist on both sides, and the spec's two arrays must agree ----
foreach($sf in (Get-ChildItem (Join-Path $mp 'db\recipes\*.json'))){
  $sp = Get-Content $sf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $macroNames = @($sp.ingredients_grams | ForEach-Object { [string]$_.item })
  $scalerNames = @($sp.scaler.ing | ForEach-Object { $k=$_.item; if($_.canon){$k=$_.canon}; [string]$k })
  foreach($n in ($macroNames + $scalerNames | Sort-Object -Unique)){
    $miss = Test-MissingSide -Item $n -InPrice $ingm.ContainsKey($n) -InMacro $fdbm.ContainsKey($n)
    foreach($m in $miss){ $hard.Add("MISSING-SIDE: $($sf.BaseName) '$n' - $m") }
  }
  # The two arrays are parallel by construction, so a name in one and not the other means the cost line and
  # the macro line describe different products - the Green Bell Pepper / Green Bell Peppers rename class,
  # and the reason a projection of scaler.ing disagreed with the real macro basis on 4 of 429 specs.
  # TIERING: a DISPLAY OVERRIDE is legitimate and documented (build-run-specs.ps1: a japchae card must say
  # "Korean glass noodles (dangmyeon)", never "Rice Noodles"). Those resolve on BOTH sides, so they are WARN.
  # A split where one side does NOT resolve is a half-finished rename with a real break behind it - HARD.
  foreach($n in $macroNames){ if($scalerNames -notcontains $n){
    $line = "NAME-SPLIT: $($sf.BaseName) macro basis says '$n', the scaler does not"
    if($fdbm.ContainsKey($n) -and $ingm.ContainsKey($n)){ $warn.Add($line + ' (both names resolve - looks like an intentional display override)') }
    else { $hard.Add($line + ' - and it does not resolve on both sides, so this is a half-finished rename') } } }
  foreach($n in $scalerNames){ if($macroNames -notcontains $n){
    $line = "NAME-SPLIT: $($sf.BaseName) scaler says '$n', the macro basis does not"
    if($fdbm.ContainsKey($n) -and $ingm.ContainsKey($n)){ $warn.Add($line + ' (both names resolve - looks like an intentional display override)') }
    else { $hard.Add($line + ' - and it does not resolve on both sides, so this is a half-finished rename') } } }
}

# ---- 3: densities vs the food DB's own serving base ----
foreach($p in $dens.PSObject.Properties){
  $item=$p.Name; if(-not $fdbm.ContainsKey($item)){ continue }
  $row=$fdbm[$item]
  foreach($u in @('cup','tbsp','each')){
    if(-not $p.Value.PSObject.Properties[$u]){ continue }
    if([string]$row.serving_unit -notmatch $u){ continue }
    if([double]$row.serving_qty -ne 1){ continue }
    if(Test-BaseDrift ([double]$p.Value.$u) ([double]$row.serving_grams)){
      $warn.Add("BASE-DRIFT: '$item' one $u is $($p.Value.$u) g in densities but $($row.serving_grams) g in the food DB - buy labels and macros disagree about the same measure")
    }
  }
}

# ---- 4: the built card must show the spec's own numbers (CONTENT, never mtime - a spec is rewritten by
#         re-anchors that do not change the card, so a timestamp comparison is 100% false positives) ----
foreach($sf in (Get-ChildItem (Join-Path $mp 'db\recipes\*.json'))){
  $card = Join-Path $mp ("db\built\" + $sf.BaseName + '.body.html')
  if(-not (Test-Path $card)){ continue }
  $sp = Get-Content $sf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $html = [IO.File]::ReadAllText($card)
  $m = [regex]::Match($html,'\$(\d+\.\d{2})\s*per serving')
  if($m.Success -and [Math]::Abs([double]$m.Groups[1].Value - [double]$sp.stat.cost_ps) -gt 0.005){
    $hard.Add("CARD-STALE: $($sf.BaseName) card shows `$$($m.Groups[1].Value)/serving, spec says `$$($sp.stat.cost_ps) - rebuild + publish")
  }
  $mc = [regex]::Match($html,'~(\d{3,4})\s*cal')
  if($mc.Success -and [int]$mc.Groups[1].Value -ne [int]$sp.stat.cal){
    $hard.Add("CARD-STALE: $($sf.BaseName) card shows $($mc.Groups[1].Value) cal, spec says $($sp.stat.cal)")
  }
}

$cap = if($ShowAll){ [int]::MaxValue } else { 12 }
Write-Output ("store-integrity: {0} HARD, {1} WARN" -f $hard.Count, $warn.Count)
$hard | Select-Object -First $cap | ForEach-Object { Write-Output ("  ! " + $_) }
if($hard.Count -gt $cap){ Write-Output ("  ... {0} more HARD not shown - rerun with -ShowAll" -f ($hard.Count-$cap)) }
$warn | Select-Object -First $cap | ForEach-Object { Write-Output ("  ~ " + $_) }
if($warn.Count -gt $cap){ Write-Output ("  ... {0} more WARN not shown - rerun with -ShowAll" -f ($warn.Count-$cap)) }
if($hard.Count -eq 0 -and $warn.Count -eq 0){ Write-Output 'store-integrity: CLEAN (ingredient stores agree, cards match their specs)' }
exit $(if($hard.Count){ 1 } else { 0 })
