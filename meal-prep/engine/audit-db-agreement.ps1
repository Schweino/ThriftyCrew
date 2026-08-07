# audit-db-agreement.ps1 - drift guard between the TWO recipe masters (by design: recipes-db.json is
# the catalog INDEX, db\recipes\<slug>.json are the SPECS). Nothing enforced their agreement until
# 2026-07-26 (estate audit finding): a recipe added to one but not the other, or a protein/visibility
# edit applied to only one, silently splits the surfaces (rotation/top5 read the index; cards read specs).
# Checks: slug sets match both ways; protein agrees; the COST BLOCK agrees; the two masters list the SAME
# INGREDIENTS (count and canonical names); spec scaler bids exist in
# db\ingredients.json (a gpu/bid recalibration must reach both, or cheapest_ps diverges from cost basis).
# Exit 0 clean, 1 drift found (caller alerts; non-fatal in the daily chain).
#
# COST-DRIFT was added 2026-08-04 after this guard read CLEAN over a ten-day-old defect. The 2026-07-25
# R300 merge stamped one recipe's entire cost block (1.83 / 25.67 / 31.57 / 2.26 / 18.75 / 50.32) across
# 299 index rows; the specs were recost the next morning and nothing carried it back, so 403 of 513 rows
# disagreed with their own spec by a mean of $0.63 and a worst of $4.31. This guard compared slug and
# protein and could not see any of it. recipes-db's cost fields are a pure COPY of the spec's - only
# update-recipes-db.ps1 and pipeline\sync-recipesdb-cost.ps1 may write them - so any disagreement is
# drift by definition, with no legitimate reading. Run sync-recipesdb-cost.ps1 to repair it.
#
# Usage: audit-db-agreement.ps1 [-SelfTest] [-ShowAll]
param([switch]$SelfTest,[switch]$ShowAll)
$ErrorActionPreference='Stop'
# CATEGORY CAPS (2026-08-07): each check stops ADDING issues after N and appends a "plus X more" line, so
# raising only the print cap produced output that showed everything AND still claimed lines were withheld.
# -ShowAll now lifts the collection caps too, which is what the flag promised.
$CAP8 = if($ShowAll){ [int]::MaxValue } else { 8 }
$CAP6 = if($ShowAll){ [int]::MaxValue } else { 6 }
$CAP4 = if($ShowAll){ [int]::MaxValue } else { 4 }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp = Split-Path -Parent $here
$issues = New-Object System.Collections.Generic.List[string]

# The six numbers recipes-db copies from the spec. Compared only where the INDEX row carries the field:
# 111 pre-r300 rows have no cost_pantry_add / cost_first_run at all, which is a shape difference from an
# older importer, not drift, and failing the daily guard on it every morning would train everyone to
# ignore the one line that matters.
$script:COST_FIELDS = @('cost_per_serving','cost_batch','cost_batch_true','cost_per_serving_true','cost_pantry_add','cost_first_run')

function Get-CostDrift {
    <# Pure, so the founding bug can be pinned by -SelfTest without touching a live file. #>
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)]$Spec, [Parameter(Mandatory)][string]$Slug)
    $out = New-Object System.Collections.Generic.List[string]
    foreach($k in $script:COST_FIELDS){
        if($Row.PSObject.Properties.Name -notcontains $k){ continue }
        if($Spec.PSObject.Properties.Name -notcontains $k){ $out.Add("COST-DRIFT: $Slug index has $k but the spec does not"); continue }
        $a = [double]$Row.$k; $b = [double]$Spec.$k
        if([Math]::Abs($a - $b) -gt 0.005){ $out.Add(("COST-DRIFT: {0} {1} index={2:0.00} spec={3:0.00} (the index copy is stale - run pipeline\sync-recipesdb-cost.ps1)" -f $Slug,$k,$a,$b)) }
    }
    return @($out.ToArray())
}

if($SelfTest){
    # FROZEN FIXTURE - the founding bug, 2026-08-04. The MUST-FIRE row is soto-betawi's real numbers as
    # the index held them (panang's block) against its real spec: the worst of the 403. The CLEAN TWIN is
    # panang itself, the one recipe the stamped block legitimately belonged to - the row on which the bug
    # is indistinguishable from correctness, and the reason a spot check would have cleared the batch.
    # The THIRD row pins the shape difference: a pre-r300 index row that never carried cost_first_run
    # must not be reported as drift just for being an older shape.
    $f=0
    function T($m,$c,$g){ if($c){ Write-Output ("ok    "+$m) } else { Write-Output ("FAIL  "+$m+"   got: "+$g); $script:f++ } }
    $stamped = [pscustomobject]@{ cost_per_serving=1.83; cost_batch=25.67; cost_batch_true=31.57; cost_per_serving_true=2.26; cost_pantry_add=18.75; cost_first_run=50.32 }
    $sotoSpec= [pscustomobject]@{ cost_per_serving=6.14; cost_batch=85.95; cost_batch_true=102.28; cost_per_serving_true=7.31; cost_pantry_add=15.41; cost_first_run=117.69 }
    $d1 = Get-CostDrift -Row $stamped -Spec $sotoSpec -Slug 'soto-betawi-indonesian-beef-coconut-soup'
    T 'MUST FIRE  a stamped cost block is reported against its real spec' ($d1.Count -eq 6) ("issues=" + $d1.Count)
    T 'MUST FIRE  the per-serving line names both numbers so triage can act on it' (($d1 -join '|') -match 'cost_per_serving index=1\.83 spec=6\.14') ($d1 -join '|')
    $d2 = Get-CostDrift -Row $stamped -Spec $stamped -Slug 'panang-chicken-curry'
    T 'CLEAN TWIN the one recipe the stamped block belongs to is silent' ($d2.Count -eq 0) ("issues=" + $d2.Count)
    $legacy = [pscustomobject]@{ cost_per_serving=2.45; cost_batch=32.89; cost_batch_true=40.11; cost_per_serving_true=2.87 }
    $legSpec= [pscustomobject]@{ cost_per_serving=2.45; cost_batch=32.89; cost_batch_true=40.11; cost_per_serving_true=2.87; cost_pantry_add=0; cost_first_run=40.11 }
    $d3 = Get-CostDrift -Row $legacy -Spec $legSpec -Slug 'legacy-row'
    T 'CLEAN TWIN a pre-r300 row that never carried first_run is not drift' ($d3.Count -eq 0) ($d3 -join '|')
    $d4 = Get-CostDrift -Row ([pscustomobject]@{ cost_per_serving=2.45 }) -Spec ([pscustomobject]@{ cost_per_serving=2.455 }) -Slug 'rounding'
    T 'CLEAN TWIN a sub-half-cent difference is rounding, not drift' ($d4.Count -eq 0) ($d4 -join '|')
    $d5 = Get-CostDrift -Row ([pscustomobject]@{ cost_per_serving=2.45 }) -Spec ([pscustomobject]@{ cost_per_serving=2.46 }) -Slug 'onecent'
    T 'MUST FIRE  a one-cent disagreement IS drift (the copy has exactly one right value)' ($d5.Count -eq 1) ($d5 -join '|')
    if($f -eq 0){ Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

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

# BID single-source (2026-07-27, overhaul-2): db\ingredients.json holds the canonical bid per item, and a
# spec's scaler bid is a DERIVED copy of it (build-v2-spec). If they diverge, everyday cost (db bid) and the
# cheapest number (spec bid + feed) price DIFFERENT products - the exact root of a cheapest>everyday
# inversion. The only legitimate divergence is a per-recipe product variant (a recipe whose prose calls for,
# and prices, jasmine rice instead of generic rice); those are enumerated in db\spec-bid-overrides.json.
# Any bid mismatch NOT on that list is drift and fails the guard.
#
# GPU-DRIFT (2026-08-06). gpu used to be exempt from value comparison here, on the reasoning that
# build-v2-spec unit-reconciles it so spec.gpu legitimately differs from db.gpu. That is true only when
# a conversion actually applies: Resolve-ScalerGpu rescales gpu by $UNIT_G[feed]/$UNIT_G[map] when the
# map's unit and the feed's unit DIFFER, and returns it untouched when they are the same. So for an
# item whose map unit already equals the feed unit there is no legitimate divergence at all, and the
# blanket exemption was hiding a whole class.
#
# It hid this one: the shared "Tortilla" row was recalibrated in db\ingredients.json (gpu 45 -> 36.85,
# the real weight of the Great Value Small Fajita the board actually prices) while 11 published specs
# kept gpu 45 in their own scaler copy. Both units are "each", so nothing reconciled and nothing
# compared - the map read fixed, the live cards kept pricing on the old basis, and the guard stayed
# green. That is the estate's "repair stops at the source of truth" failure mode, armed.
#
# So: compare gpu whenever no conversion applies (map unit == feed unit, or the feed has no row and
# the units cannot differ). Where a conversion DOES apply, stay silent - recomputing the expected
# value here would duplicate Resolve-ScalerGpu and drift from it.
$feedUnitById=@{}
$fuPath = Join-Path (Split-Path $mp -Parent) 'grocery\out\smp-feed.json'
if(Test-Path $fuPath){
  try { $fu=(Get-Content $fuPath -Raw -Encoding utf8 | ConvertFrom-Json).ingredients
        foreach($p in $fu.PSObject.Properties){ $feedUnitById[$p.Name]=[string]$p.Value.unit } } catch {}
}
$bidOverrides=@{}
$boF = Join-Path $mp 'db\spec-bid-overrides.json'
if(Test-Path $boF){ try { $bo=(Get-Content $boF -Raw|ConvertFrom-Json).overrides; foreach($p in $bo.PSObject.Properties){ $bidOverrides[[string]$p.Name]=@($p.Value | ForEach-Object { [string]$_ }) } } catch {} }

# CHEAPEST-FALLBACK guard (2026-07-26 scale hardening): the live card widget + compute-v2 price the
# "current cheapest" number by looking each ingredient's scaler BID up in the public feed. A bid that is
# NOT a feed key silently falls back to the everyday price - the recipe shows cheapest == everyday and
# nobody notices. Harmless for the handful of exotic ingredients we deliberately do not board-price
# (db\no-board-price-ok.json), but a mass import that ships an UNMAPPED bid would silently mis-price on
# cheapest. This catches exactly that. Feed is optional (skip if not built yet) so the guard never fails
# a machine that has not run the grocery pull.
$feedKeys=@{}; $feedLoaded=$false
$feedPath = Join-Path (Split-Path $mp -Parent) 'grocery\out\smp-feed.json'
if(Test-Path $feedPath){ try { $fj=(Get-Content $feedPath -Raw -Encoding utf8 | ConvertFrom-Json).ingredients; foreach($p in $fj.PSObject.Properties){ $feedKeys[$p.Name]=1 }; $feedLoaded=$true } catch {} }
$noPriceOk=@{}
$npF = Join-Path $mp 'db\no-board-price-ok.json'
if(Test-Path $npF){ try { $npObj=(Get-Content $npF -Raw|ConvertFrom-Json); $npList=if($npObj.PSObject.Properties.Name -contains 'bids'){ $npObj.bids } else { $npObj }; foreach($x in $npList){ $noPriceOk[[string]$x]=1 } } catch {} }

$bidMiss=0; $fallback=@(); $bidDrift=0; $gpuDrift=0
$costDriftRows=0; $costDriftFields=0
foreach($s in $specSlugs.Keys){
  if(-not $idxBySlug.ContainsKey($s)){ continue }
  $spec = Get-Content $specs[$s] -Raw | ConvertFrom-Json
  $row = $idxBySlug[$s]
  # protein: normalize the r100-era 'ground X' spec format to the canonical 4-class before comparing
  $sp = ([string]$spec.protein) -replace '^ground\s+',''
  if($sp -ne [string]$row.protein){ $issues.Add("PROTEIN drift: $s spec='$($spec.protein)' index='$($row.protein)'") }
  # cost block: the index copy has exactly one legitimate value, the spec's. Report per ROW rather than
  # per field - a stale row moves all six numbers at once, and 403 rows x 6 would bury every other line.
  $cd = @(Get-CostDrift -Row $row -Spec $spec -Slug $s)
  if($cd.Count){
    $costDriftRows++; $costDriftFields += $cd.Count
    if($costDriftRows -le $CAP8){ $issues.Add(($cd | Where-Object { $_ -match 'cost_per_serving ' } | Select-Object -First 1)) }
    if($costDriftRows -le 8 -and -not ($cd | Where-Object { $_ -match 'cost_per_serving ' })){ $issues.Add($cd[0]) }
  }
  # INGREDIENT-SET (2026-08-04): the two masters must agree on WHICH ingredients a recipe has. COST-DRIFT
  # above compares what a recipe costs; this compares what is IN it, and nothing did until two defects the
  # same day proved both directions. slow-cooker-dr-pepper-pulled-pork-bowls carried 8 ingredients in the
  # index and 7 in the spec - the namesake soda existed only in the index, so the card sold a Dr Pepper
  # braise with no braising liquid in the list a shopper buys from. korean-turkey-japchae carried
  # "Cornstarch" in the index against the spec's "Rice Noodles", a one-for-one swap from the 2026-07
  # glass-noodle correction that never reached the index, so the Meal Plan Builder (which reads the INDEX,
  # while the card reads the SPEC) shopped 794 g of cornstarch for a noodle dish. Both read CLEAN here.
  # Compared on the CANONICAL name - scaler.canon when a card renames an ingredient for the reader, else
  # scaler.item - which is the key update-recipes-db.ps1 writes into the index. Armed at ZERO.
  $specIng = @($spec.scaler.ing | ForEach-Object { if($_.PSObject.Properties.Name -contains 'canon' -and $_.canon){ [string]$_.canon } else { [string]$_.item } })
  $idxIng  = @($row.ingredients | ForEach-Object { [string]$_.item })
  if($specIng.Count -ne $idxIng.Count){
    $issues.Add("INGREDIENT-COUNT drift: $s spec has $($specIng.Count) ingredient(s), index has $($idxIng.Count) - one master is missing a line the other buys")
  } else {
    $specOnly = @($specIng | Where-Object { $idxIng -notcontains $_ })
    $idxOnly  = @($idxIng  | Where-Object { $specIng -notcontains $_ })
    if($specOnly.Count -or $idxOnly.Count){
      $issues.Add("INGREDIENT-NAME drift: $s spec-only [$($specOnly -join ', ')] index-only [$($idxOnly -join ', ')] - the card and the Meal Plan Builder name different products")
    }
  }
  # visibility is deliberately NOT compared: recipes-db + Ghost own it (the free-dinner rotation flips
  # both weekly); the spec field is only the default for a FIRST publish. engine\publish preserves the
  # live post's visibility and bases its leak-check on the LIVE visibility, not the spec.
  foreach($ing in $spec.scaler.ing){
    $key = if($ing.PSObject.Properties.Name -contains 'canon' -and $ing.canon){ [string]$ing.canon } else { [string]$ing.item }
    if(-not $items.ContainsKey($key)){ $bidMiss++; if($bidMiss -le $CAP8){ $issues.Add("NO-DB-ITEM: $s ingredient '$key' missing from db\ingredients.json") } }
    else {
      $sb  = if($ing.PSObject.Properties.Name -contains 'bid'){ [string]$ing.bid } else { '' }
      $dbb = if($items[$key].PSObject.Properties.Name -contains 'bid'){ [string]$items[$key].bid } else { '' }
      if($sb -and $dbb -and $sb -ne $dbb -and -not ($bidOverrides.ContainsKey($key) -and ($bidOverrides[$key] -contains $sb))){
        $bidDrift++; if($bidDrift -le $CAP8){ $issues.Add("BID-DRIFT: $s '$key' spec bid '$sb' != db bid '$dbb' (not an allowed override; everyday & cheapest would price different products - fix the spec or list it in db\spec-bid-overrides.json)") }
      }
      # GPU-DRIFT: only where no unit conversion can apply (see the header note above).
      if($sb -and $sb -eq $dbb -and ($ing.PSObject.Properties.Name -contains 'gpu')){
        $mapUnit  = if($items[$key].PSObject.Properties.Name -contains 'unit'){ [string]$items[$key].unit } else { '' }
        $feedUnit = if($feedUnitById.ContainsKey($sb)){ $feedUnitById[$sb] } else { $mapUnit }
        if($mapUnit -and $feedUnit -eq $mapUnit){
          $sg = [double]$ing.gpu; $dg = [double]$items[$key].gpu
          if($dg -gt 0 -and $sg -gt 0 -and [Math]::Abs($sg/$dg - 1) -gt 0.005){
            $gpuDrift++
            if($gpuDrift -le $CAP8){ $issues.Add("GPU-DRIFT: $s '$key' spec gpu $sg != db gpu $dg (unit '$mapUnit' both sides, so nothing reconciled it; the card prices grams/gpu * cheapest, so the spec is costing on a stale basis - rebuild the spec or revert the map)") }
          }
        }
      }
    }
    if($feedLoaded){
      $b = if($ing.PSObject.Properties.Name -contains 'bid'){ [string]$ing.bid } else { '' }
      if($b -and (-not $feedKeys.ContainsKey($b)) -and (-not $noPriceOk.ContainsKey($b)) -and (-not $noPriceOk.ContainsKey($key))){
        $fallback += ("$s : '$key' bid '$b' not on feed (cheapest silently = everyday)")
      }
    }
  }
}
# ---- JSON-LD vs THE PAGE (2026-08-04). head.recipeIngredient is what Google reads; ingredients_display
# is what the reader sees. They were never reconciled and drifted apart on 507 of 513 recipes - the
# structured data named 6 of 16 ingredients on american-goulash-pasta, in package units the card never
# used. head.recipeIngredient is now DERIVED from ingredients_display (pipeline\head-ingredients-lib.ps1),
# so any spec where the two disagree has been hand-edited or written by a stale path, and the live pages
# would ship structured data that misrepresents them. Same shape as every other guard here: two derived
# artifacts that are never compared is a defect generator.
$headDrift = 0; $headErr = 0
$foodDbPath = Join-Path $mp 'food-macros-db.json'
. (Join-Path $mp 'pipeline\head-ingredients-lib.ps1')
$hiDb = Get-HiFoodDbMap $foodDbPath
foreach($s in ($specSlugs.Keys | Sort-Object)){
  $spec = Get-Content $specs[$s] -Raw | ConvertFrom-Json
  $want = $null
  try { $want = @(Get-HeadRecipeIngredient $spec.ingredients_display $spec.scaler.ing $hiDb) }
  catch { $headErr++; if($headErr -le $CAP4){ $issues.Add("HEAD-INGREDIENT: $s cannot derive the JSON-LD list :: $($_.Exception.Message)") }; continue }
  $got = @($spec.head.recipeIngredient | ForEach-Object { [string]$_ })
  if(($got -join "`n") -ne ($want -join "`n")){
    $headDrift++
    # SAY WHICH KIND OF DRIFT. Reporting counts when the counts happen to AGREE ("has 16, the card shows
    # 16") reads as a false positive and invites the next reader to wave it off; a content drift has to
    # name the line that differs.
    $why = if($got.Count -ne $want.Count){
      "JSON-LD has $($got.Count) line(s), the card shows $($want.Count)"
    } else {
      $i = 0; while($i -lt $got.Count -and $got[$i] -eq $want[$i]){ $i++ }
      "line $($i+1) says '$($got[$i])', the card says '$($want[$i])'"
    }
    if($headDrift -le $CAP6){ $issues.Add("HEAD-INGREDIENT drift: $s $why - rerun pipeline\repair-head-ingredients.ps1 -Apply -Slugs $s") }
  }
}
if($headDrift -gt $CAP6){ $issues.Add("... plus $($headDrift-6) more HEAD-INGREDIENT drift lines") }
if($headErr -gt $CAP4){ $issues.Add("... plus $($headErr-4) more HEAD-INGREDIENT derive failures") }

if($bidMiss -gt $CAP8){ $issues.Add("... plus $($bidMiss-8) more missing-item lines") }
if($bidDrift -gt $CAP8){ $issues.Add("... plus $($bidDrift-8) more bid-drift lines") }
if($gpuDrift -gt $CAP8){ $issues.Add("... plus $($gpuDrift-8) more gpu-drift lines") }
if($costDriftRows -gt $CAP8){ $issues.Add("... plus $($costDriftRows-8) more COST-DRIFT rows ($costDriftFields stale cost fields in total - run pipeline\sync-recipesdb-cost.ps1)") }
if($fallback.Count){
  foreach($f in ($fallback | Select-Object -First $CAP8)){ $issues.Add("CHEAPEST-FALLBACK: $f") }
  if($fallback.Count -gt $CAP8){ $issues.Add("... plus $($fallback.Count-8) more cheapest-fallback lines (unmapped bid -> add to no-board-price-ok.json if intentional, else fix the bid)") }
}

if($issues.Count -eq 0){ Write-Output ("db-agreement: CLEAN ({0} recipes, index==specs)" -f $specSlugs.Count); exit 0 }
# The headline used to count only what SURVIVED the category caps, so a default run reported 44 when the
# real total was 48. The caps are a display convenience; the count must not inherit them.
$suppressed = 0; $summaryLines = 0
foreach($pair in @(@($gpuDrift,$CAP8),@($bidMiss,$CAP8),@($bidDrift,$CAP8),@($headDrift,$CAP6),@($headErr,$CAP4),@($costDriftRows,$CAP8),@($fallback.Count,$CAP8))){
  if($pair[0] -gt $pair[1]){ $suppressed += ($pair[0] - $pair[1]); $summaryLines++ }
}
# $summaryLines is subtracted because each suppressed category ALREADY pushed a "... plus N more" row into
# $issues. Counting that row AND its N double-counts, which is how the default headline read 49 against
# -ShowAll's 48. The two modes must report the same total or the count is not a count.
Write-Output ("db-agreement: {0} drift issue(s){1}" -f ($issues.Count + $suppressed - $summaryLines), $(if($suppressed -gt 0){ " ($suppressed held back by category caps - rerun with -ShowAll)" } else { '' }))
# -ShowAll because the flat 25-line cap hid real findings behind a homogeneous block: on 2026-08-07 a run
# reported 45 issues and printed 25, every one of them the same expected SPEC-ONLY line, so the 20 that
# actually needed attention were invisible. The cap stays the default (the output is a daily-ops summary),
# but the tail is now COUNTED rather than silently dropped, and -ShowAll prints everything.
$cap = if($ShowAll){ $issues.Count } else { 25 }
$issues | Select-Object -First $cap | ForEach-Object { Write-Output ("  ! " + $_) }
if($issues.Count -gt $cap){ Write-Output ("  ... {0} more not shown - rerun with -ShowAll" -f ($issues.Count - $cap)) }
exit 1