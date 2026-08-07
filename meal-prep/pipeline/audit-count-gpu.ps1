# audit-count-gpu.ps1 - the COUNT-UNIT gpu guard.
#
# WHY THIS EXISTS (founding bug, 2026-08-06):
#   db\ingredients.json carried the shared "Tortilla" row as
#       gpu 45 | unit each | buy_pkg_g 300 | buy_pkg_label "10ct pack"
#   A 300 g pack of 10 is 30 g each, so the row contradicted its OWN gpu by 1.5x. It also matched no
#   product the board has ever priced: the tortillas cell's cheapest is a Great Value Small Fajita,
#   26 oz / 20 ct = 36.85 g. gpu 45 is an 8-inch soft-taco tortilla - the size several SOURCE recipes
#   call for. Someone calibrated gpu to the recipe's tortilla instead of the PRICED tortilla.
#
#   That is the brown-sugar 16x class (2026-07-19) all over again, and build-v2-spec's
#   Resolve-ScalerGpu could not catch it: that function reconciles gpu when the map's UNIT LABEL
#   differs from the feed's ("oz" vs "lb"), converting via $UNIT_G. Here map unit and feed unit are
#   both "each", so it returns gpu untouched. "each" is not in $UNIT_G and has no conversion factor,
#   so for every count-priced commodity the gpu MAGNITUDE is a free parameter that nothing checks.
#
#   This guard closes that hole using a cross-check the estate already had and never compared:
#   buy_pkg_g and buy_pkg_label are an INDEPENDENT statement of the same physical fact. A pack of
#   N units weighing P grams says each unit is P/N grams. That must equal gpu.
#
# WHAT IT CHECKS. A count-unit row is one of two shapes, and only a like-for-like comparison is sound:
#
#   MULTIPACK  buy_pkg_label names a count > 1 ("20ct pack", "30ct pack", "6ct pack").
#              The pack holds N of the thing, so unit_g = buy_pkg_g / N is an INDEPENDENT measure of
#              one unit, and everything that claims to describe one unit must match it:
#                1. PACK    gpu                          == unit_g   (hard, 2%)
#                2. DENSITY densities items.<item>.each  == unit_g   (hard, 2%)
#                3. MACRO   food-macros-db serving_grams ~= unit_g   (warn, 10%) - only when the macro
#                           row's serving IS one unit (serving_qty 1 + a count noun, not g/cup/tbsp),
#                           and loose because a label rounds (36 g printed on a 36.85 g tortilla).
#
#   SINGLE     buy_pkg_label names no count ("each", "bunch", "head", "whole bird", "dozen").
#              The pack IS the unit, so the only sound check is gpu == buy_pkg_g (hard, 2%).
#
# What it deliberately does NOT do: compare densities' `each` or a macro serving against gpu on a
# SINGLE row. Those are different physical things and the comparison generates pure noise - densities
# `each` is the COOK's unit (a garlic clove is 5 g, one egg is 50 g) while gpu is the BOARD's purchase
# unit (a head is 40 g, a dozen is 600 g), and a macro serving is a nutrition-label portion (100 g of
# apple) not a purchase. An early draft of this guard checked those and produced 17 findings, 15 of
# them false. A guard that cries wolf gets ignored and joins the estate's dead-guard pile; this one
# only speaks about the class where the arithmetic is actually closed.
#
# Run:  .\audit-count-gpu.ps1              (exit 0 = clean, 1 = at least one hard fail)
#       .\audit-count-gpu.ps1 -SelfTest    (frozen fixtures: the founding bug + its clean twin)
[CmdletBinding()]
param(
  [string]$IngredientsFile,
  [string]$DensitiesFile,
  [string]$FoodDbFile,
  [switch]$SelfTest,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp   = Split-Path -Parent $here
if(-not $IngredientsFile){ $IngredientsFile = Join-Path $mp 'db\ingredients.json' }
if(-not $DensitiesFile){   $DensitiesFile   = Join-Path $mp 'db\densities.json' }
if(-not $FoodDbFile){      $FoodDbFile      = Join-Path $mp 'food-macros-db.json' }

# Units priced per discrete item. 'dozen' is a count of 12 and is handled by the label parse below.
$COUNT_UNITS = @('each','dozen')
$PACK_TOL    = 0.02
$DEN_TOL     = 0.02
$MACRO_TOL   = 0.10
# A macro row whose serving_unit is one of these states a MEASURE, not one whole item ("100 g of
# apple", "1 cup"), so it says nothing about what one purchased unit weighs. Only a count noun
# ("1 tortilla", "1 egg") is comparable to a per-unit pack weight.
$MEASURE_UNITS = @('g','gram','grams','oz','ounce','ounces','lb','cup','cups','tbsp','tsp','ml','floz','fl oz','serving','piece','slice')

# The count inside a package label: "20ct pack", "30 ct", "16 pk", "12 ea", "6ct pack".
# Deliberately does NOT match a size ("26 oz", "13.7oz/6ct" would match the 6ct, which is correct).
$COUNT_RX = '(\d+(?:\.\d+)?)\s*(?:ct\b|count\b|pk\b|pack\b|ea\b)'

function Get-PackCount([string]$label){
  if(-not $label){ return $null }
  $m = [regex]::Match($label, $COUNT_RX)
  if(-not $m.Success){ return $null }
  $n = [double]$m.Groups[1].Value
  if($n -le 1){ return $null }   # "1 pack" / "each pack" is a single-unit row, not a multipack
  return $n
}

# Returns an array of finding hashtables. Pure function over already-parsed inputs so the frozen
# fixtures below exercise the SAME predicate the live run uses (never a reimplementation).
function Test-CountGpuRows($rows, $densMap, $macroMap){
  $findings = New-Object System.Collections.ArrayList
  foreach($r in $rows){
    $unit = [string]$r.unit
    if($COUNT_UNITS -notcontains $unit){ continue }
    $item = [string]$r.item
    $gpu  = [double]$r.gpu
    $pkg  = [double]$r.buy_pkg_g
    if($gpu -le 0){
      [void]$findings.Add([pscustomobject]@{ sev='FAIL'; check='GPU'; item=$item; msg=("gpu is {0} on a count-unit row" -f $gpu) })
      continue
    }
    if($pkg -le 0){ continue }   # no package stated (Fajita Seasoning, Lime Juice) - nothing to close against

    $n = Get-PackCount ([string]$r.buy_pkg_label)

    if($null -eq $n){
      # SINGLE: the package IS one unit, so gpu and buy_pkg_g are two statements of one number.
      $ratio = $pkg / $gpu
      if([Math]::Abs($ratio - 1) -gt $PACK_TOL){
        [void]$findings.Add([pscustomobject]@{ sev='FAIL'; check='SINGLE'; item=$item; msg=(
          "label '{0}' is one unit, so buy_pkg_g should equal gpu, but buy_pkg_g={1} and gpu={2} (x{3})" -f `
          [string]$r.buy_pkg_label, $pkg, $gpu, [Math]::Round($ratio,3)) })
      }
      continue
    }

    # MULTIPACK: unit_g is the independent measure everything else must agree with.
    $unitG = $pkg / $n

    # 1. PACK
    $ratio = $unitG / $gpu
    if([Math]::Abs($ratio - 1) -gt $PACK_TOL){
      [void]$findings.Add([pscustomobject]@{ sev='FAIL'; check='PACK'; item=$item; msg=(
        "buy_pkg_g {0} / {1} in label '{2}' = {3} g each, but gpu says {4} g (x{5})" -f `
        $pkg, $n, [string]$r.buy_pkg_label, [Math]::Round($unitG,2), $gpu, [Math]::Round($ratio,3)) })
    }

    # 2. DENSITY
    if($densMap.ContainsKey($item)){
      $de = [double]$densMap[$item]
      if($de -gt 0){
        $ratio = $de / $unitG
        if([Math]::Abs($ratio - 1) -gt $DEN_TOL){
          [void]$findings.Add([pscustomobject]@{ sev='FAIL'; check='DENSITY'; item=$item; msg=(
            "densities each = {0} g but the pack says {1} g each ({2} / {3}) (x{4})" -f `
            $de, [Math]::Round($unitG,2), $pkg, $n, [Math]::Round($ratio,3)) })
        }
      }
    }

    # 3. MACRO (warn only, and only when the macro serving IS one unit)
    if($macroMap.ContainsKey($item)){
      $m  = $macroMap[$item]
      $sg = [double]$m.grams
      if($sg -gt 0 -and [double]$m.qty -eq 1 -and $MEASURE_UNITS -notcontains ([string]$m.unit).ToLower()){
        $ratio = $sg / $unitG
        if([Math]::Abs($ratio - 1) -gt $MACRO_TOL){
          [void]$findings.Add([pscustomobject]@{ sev='WARN'; check='MACRO'; item=$item; msg=(
            "food-macros-db says 1 {0} = {1} g but the priced pack says {2} g each (x{3}) - the macro row and the priced product look like different products" -f `
            [string]$m.unit, $sg, [Math]::Round($unitG,2), [Math]::Round($ratio,3)) })
        }
      }
    }
  }
  return $findings.ToArray()
}

# ---------------------------------------------------------------- frozen fixtures
# Per the estate's guard-fixture rule: every guard ships the exact shape of its founding bug and a
# clean twin, FROZEN as literals. These are never regenerated from the live files - once ingredients
# .json is fixed, a fixture rebuilt from it would silently stop testing anything.
if($SelfTest){
  $fail = 0
  function Check($name, $cond){ if($cond){ Write-Output "  PASS  $name" } else { Write-Output "  FAIL  $name"; $script:fail++ } }

  $emptyDen = @{}; $emptyMac = @{}
  # Findings are PSCustomObjects, never hashtables: a hashtable's .Count is its KEY count, so
  # `($f | Where-Object ...).Count -eq 1` silently reads 4 and every must-fire test passes as a
  # false negative. This helper is the only place a finding set is counted.
  function NFind($rows, $dens, $macs, $check, $sev){
    $r = @(Test-CountGpuRows $rows $dens $macs)
    if($check){ $r = @($r | Where-Object { $_.check -eq $check }) }
    if($sev){   $r = @($r | Where-Object { $_.sev   -eq $sev   }) }
    return $r.Count
  }

  # -- must fire: the founding bug, verbatim as it shipped
  $bug = ,([pscustomobject]@{ item='Tortilla'; bid='tortillas'; gpu=45; unit='each'; buy_pkg_g=300; buy_pkg_label='10ct pack' })
  Check "MUST FIRE: tortillas gpu 45 vs 300 g / 10ct (= 30 g each)" ((NFind $bug $emptyDen $emptyMac 'PACK' $null) -eq 1)

  # -- must fire: the same class on corn-tortillas (gpu 30 vs 750 g / 30ct = 25 g)
  $bug2 = ,([pscustomobject]@{ item='Corn Tortillas'; bid='corn-tortillas'; gpu=30; unit='each'; buy_pkg_g=750; buy_pkg_label='30ct pack' })
  Check "MUST FIRE: corn-tortillas gpu 30 vs 750 g / 30ct (= 25 g each)" ((NFind $bug2 $emptyDen $emptyMac 'PACK' $null) -eq 1)

  # -- clean twin: the repaired row. 737 g / 20 ct = 36.85 g, exactly gpu.
  $fix = ,([pscustomobject]@{ item='Tortilla'; bid='tortillas'; gpu=36.85; unit='each'; buy_pkg_g=737; buy_pkg_label='20ct pack' })
  Check "CLEAN TWIN: tortillas gpu 36.85 vs 737 g / 20ct passes" ((NFind $fix $emptyDen $emptyMac $null $null) -eq 0)

  # -- density arm must fire on the founding bug's densities value (30) against the true gpu
  Check "MUST FIRE: densities each 30 against gpu 36.85"          ((NFind $fix @{ 'Tortilla' = 30 }    $emptyMac 'DENSITY' $null) -eq 1)
  Check "CLEAN TWIN: densities each 36.85 against gpu 36.85"      ((NFind $fix @{ 'Tortilla' = 36.85 } $emptyMac 'DENSITY' $null) -eq 0)

  # -- macro arm: the La Banderita 65 g row on a 36.85 g priced product is the exact overload that
  #    understated calories on 11 live recipes by 2.2x per gram. Warn, not fail.
  function Mac($g,$q,$u){ return @{ 'Tortilla' = [pscustomobject]@{ grams=$g; qty=$q; unit=$u } } }
  Check "MUST FIRE (warn): macro '1 tortilla = 65 g' against a 36.85 g pack unit" ((NFind $fix $emptyDen (Mac 65 1 'tortilla') 'MACRO' 'WARN') -eq 1)
  Check "CLEAN TWIN: macro '1 tortilla = 36 g' (label rounding) passes"           ((NFind $fix $emptyDen (Mac 36 1 'tortilla') 'MACRO' $null) -eq 0)
  # a macro row stating a MEASURE, not one item, must be ignored - this is what made the first draft
  # of this guard fire on apples ("100 g of apple" vs a 175 g apple) and on eggs and garlic cloves.
  Check "IGNORES a measure-based macro serving ('100 g')" ((NFind $fix $emptyDen (Mac 100 1 'g') 'MACRO' $null) -eq 0)
  Check "IGNORES a fractional macro serving ('0.25 cup')" ((NFind $fix $emptyDen (Mac 100 0.25 'cup') 'MACRO' $null) -eq 0)

  # -- single-unit rows: the pack IS the unit, so gpu must equal buy_pkg_g and nothing else applies
  $single = ,([pscustomobject]@{ item='Apple'; bid='apple'; gpu=175; unit='each'; buy_pkg_g=175; buy_pkg_label='each' })
  Check "PASSES single-unit row (gpu == buy_pkg_g)" ((NFind $single $emptyDen $emptyMac $null $null) -eq 0)
  # densities 'each' for an apple is a cook's apple and a macro serving is 100 g; neither is comparable
  # to a purchase unit, and on a SINGLE row this guard must stay silent about both.
  Check "SINGLE row ignores densities each"  ((NFind $single @{ 'Apple' = 180 } $emptyMac $null $null) -eq 0)
  Check "SINGLE row ignores macro serving"   ((NFind $single $emptyDen @{ 'Apple' = [pscustomobject]@{ grams=100; qty=1; unit='apple' } } $null $null) -eq 0)
  $bunch = ,([pscustomobject]@{ item='Cilantro'; bid='cilantro'; gpu=57; unit='each'; buy_pkg_g=57; buy_pkg_label='bunch' })
  Check "PASSES single-unit row (label 'bunch')" ((NFind $bunch $emptyDen $emptyMac $null $null) -eq 0)
  # must fire: garlic states a 40 g head but a 50 g gpu - two numbers for one purchased thing
  $garlic = ,([pscustomobject]@{ item='Garlic'; bid='garlic'; gpu=50; unit='each'; buy_pkg_g=40; buy_pkg_label='head' })
  Check "MUST FIRE: single-unit garlic, buy_pkg_g 40 vs gpu 50" ((NFind $garlic $emptyDen $emptyMac 'SINGLE' $null) -eq 1)
  # a row with no package stated has nothing to close against and must not be guessed at
  $nopkg = ,([pscustomobject]@{ item='Lime Juice'; bid='limes'; gpu=30; unit='each'; buy_pkg_g=0; buy_pkg_label='' })
  Check "SKIPS a row with no buy_pkg_g" ((NFind $nopkg $emptyDen $emptyMac $null $null) -eq 0)

  # -- an oz-unit row must be ignored entirely; this guard owns COUNT units only
  $ozrow = ,([pscustomobject]@{ item='Tomato Sauce'; bid='tomato-sauce'; gpu=28.3495; unit='oz'; buy_pkg_g=425; buy_pkg_label='15oz can' })
  Check "IGNORES oz-unit rows (not this guard's class)" ((NFind $ozrow $emptyDen $emptyMac $null $null) -eq 0)

  Write-Output ''
  if($fail -gt 0){ Write-Output "SELF-TEST: $fail predicate(s) regressed"; exit 1 }
  Write-Output 'SELF-TEST: all predicates hold'
  exit 0
}

# ---------------------------------------------------------------- live run
$rows = Get-Content $IngredientsFile -Raw -Encoding utf8 | ConvertFrom-Json

$densMap = @{}
$den = Get-Content $DensitiesFile -Raw -Encoding utf8 | ConvertFrom-Json
foreach($p in $den.items.PSObject.Properties){
  $v = $p.Value
  if($v.PSObject.Properties.Name -contains 'each'){ $densMap[$p.Name] = [double]$v.each }
}

$macroMap = @{}
foreach($m in (Get-Content $FoodDbFile -Raw -Encoding utf8 | ConvertFrom-Json).items){
  $k = [string]$m.item
  if($macroMap.ContainsKey($k)){ continue }
  $macroMap[$k] = [pscustomobject]@{
    grams = [double]$m.serving_grams
    qty   = $(if($m.PSObject.Properties.Name -contains 'serving_qty'){ [double]$m.serving_qty } else { 0 })
    unit  = [string]$m.serving_unit
  }
}

$findings = Test-CountGpuRows $rows $densMap $macroMap
$hard = @($findings | Where-Object { $_.sev -eq 'FAIL' })
$warn = @($findings | Where-Object { $_.sev -eq 'WARN' })
$counted = @($rows | Where-Object { $COUNT_UNITS -contains [string]$_.unit })

if(-not $Quiet){
  Write-Output ("count-unit gpu audit: {0} count-unit rows checked" -f $counted.Count)
  foreach($f in $hard){ Write-Output ("  FAIL [{0}] {1}: {2}" -f $f.check, $f.item, $f.msg) }
  foreach($f in $warn){ Write-Output ("  WARN [{0}] {1}: {2}" -f $f.check, $f.item, $f.msg) }
  if($hard.Count -eq 0 -and $warn.Count -eq 0){ Write-Output '  clean' }
}
if($hard.Count -gt 0){ exit 1 }
exit 0
