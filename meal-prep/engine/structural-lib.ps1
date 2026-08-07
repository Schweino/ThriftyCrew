# structural-lib.ps1 - the price-INDEPENDENT half of the golden test, in a library so the same code runs
# against the live catalogue and against the frozen must-fire fixtures. (2026-08-06)
#
# WHAT THIS IS FOR. The old golden test could only speak by diffing db\costed.json against a frozen
# output, so every grocery price move made it louder and less true, and on 2026-08-04 it honestly
# switched itself off. THE cost engine then ran the site's prices for eleven days with no regression
# test. The lesson is not "refresh the baseline sooner": a test that expires whenever prices move will
# always be expired. It is that most of what a cost row can get WRONG has nothing to do with what
# anything costs, and that half can be asserted forever.
#
# So this checks the costed row against ITSELF and against the spec it came from. Not one assertion here
# reads a price board, which is exactly why none of them can rot:
#   C1  spec <-> row correspondence   every spec has exactly one row; no orphan rows
#   C2  line composition             lines are a subsequence of the spec's grams-bearing ingredients
#   C3  priced/unpriced counts       lines_priced = #lines; priced + unpriced = #spec ingredients
#   C4  batch total                  cost_batch = round(sum util_cost)
#   C5  true total                   cost_batch_true = round(sum(bulk ? util : buy_cost ?? util))
#   C6  pantry fold                  cost_pantry_add = max(0, round(sum starter_cost - sum bulk util))
#   C7  first run                    cost_first_run = round(cost_batch_true + cost_pantry_add)
#   C8  per serving                  cost_per_serving[_true] = round(total / 14)
#   C9  buy package math             buy_n = max(1, ceil(g/pkg_g - 0.02)); buy_cost >= util_cost
#   C10 pantry package math          starter_n = max(1, ceil(g/pantry_g - 0.02)); starter_cost >= util_cost
#   C11 bulk/non-bulk field shape    bulk lines carry starter_*, non-bulk carry buy_*; never both
#   C12 package sizes are real       pkg_g / starter_pkg_g match a package the ingredient db defines
#   C13 sane numbers                 no negative, NaN or infinite money
#
# C12 DELIBERATELY DOES NOT re-derive WHICH package the engine should have picked - that precedence
# (board buy pkg -> label pkg -> drained yield) is pinned byte-for-byte by the frozen-input lane instead.
# Two copies of the same math is a documented blind spot in this estate (build-v2-spec.ps1 header), and a
# checker that reimplements the thing it checks agrees with itself, not with reality. Lines whose package
# cannot be checked from the db alone are COUNTED AND REPORTED, never quietly passed.
$SERVINGS = 14.0

function Get-CanonKey($ingRow){
  if($ingRow.PSObject.Properties.Name -contains 'canon' -and $ingRow.canon){ return [string]$ingRow.canon }
  return [string]$ingRow.item
}
function Num($o,[string]$p){
  if($null -eq $o){ return $null }
  $pp = $o.PSObject.Properties[$p]
  if(-not $pp -or $null -eq $pp.Value -or "$($pp.Value)" -eq ''){ return $null }
  return [double]$pp.Value
}
function EngCeil([double]$g,[double]$pkg){
  $n = [Math]::Ceiling(($g/$pkg) - 0.02)
  if($n -lt 1){ $n = 1 }
  return [double]$n
}

# Returns @{ failures=[string[]]; checked=int; unverifiable=int; note=string }
function Invoke-StructuralCheck {
  param(
    [Parameter(Mandatory)][string]$CostedFile,
    [Parameter(Mandatory)][string]$SpecDir,
    [Parameter(Mandatory)][string]$IngredientsFile,
    [string]$DensitiesFile,
    [string]$LabelPricesFile,
    [double]$Tol = 0.011
  )
  $fail = New-Object System.Collections.Generic.List[string]
  # NB the doubled parens: @(Get-Content | ConvertFrom-Json) does NOT unroll in PS 5.1 - ConvertFrom-Json
  # emits the whole array as ONE object, so @() wraps it and you iterate once over an Object[].
  $rows = @((Get-Content $CostedFile -Raw | ConvertFrom-Json))
  $bySlug = @{}
  foreach($r in $rows){
    $s = [string]$r.slug
    if($bySlug.ContainsKey($s)){ $fail.Add("C1 duplicate costed row for '$s'") ; continue }
    $bySlug[$s] = $r
  }

  # ---- ingredient package knowledge (sizes only; no prices are read anywhere in this file) ----
  $pkgSizes=@{}; $hasLabel=@{}
  foreach($row in (Get-Content $IngredientsFile -Raw | ConvertFrom-Json)){
    $nm=[string]$row.item; $set=New-Object System.Collections.Generic.List[double]
    foreach($f in 'buy_pkg_g','pantry_pkg_g'){ $v = Num $row $f; if($null -ne $v -and $v -gt 0){ $set.Add($v) } }
    $pkgSizes[$nm]=$set
  }
  if($DensitiesFile -and (Test-Path $DensitiesFile)){
    foreach($p in ((Get-Content $DensitiesFile -Raw | ConvertFrom-Json).items).PSObject.Properties){
      $v = Num $p.Value 'can'
      if($null -ne $v -and $v -gt 0){ if(-not $pkgSizes.ContainsKey($p.Name)){ $pkgSizes[$p.Name]=New-Object System.Collections.Generic.List[double] }; $pkgSizes[$p.Name].Add($v) }
    }
  }
  if($LabelPricesFile -and (Test-Path $LabelPricesFile)){
    # presence only: a label-priced line's package grams come from parsing the label's size text, and
    # re-parsing it here would just be the engine's own SizeToGrams a second time. Mark it unverifiable.
    foreach($r in (Get-Content $LabelPricesFile -Raw | ConvertFrom-Json)){ $hasLabel[[string]$r.item]=$true }
  }

  $specs = @(Get-ChildItem (Join-Path $SpecDir '*.json'))
  $checked=0; $unverifiable=0
  $seen=@{}
  foreach($sf in $specs){
    $slug = $sf.BaseName
    $seen[$slug]=$true
    if(-not $bySlug.ContainsKey($slug)){
      # THE FOUNDING BUG (2026-08-06): the -Slugs splice could only REPLACE an existing row, so a
      # brand-new recipe was costed correctly, found no row to overwrite, and vanished without a flag.
      $fail.Add("C1 spec '$slug' has NO costed row (costed.json is stale, or a targeted recost dropped it)")
      continue
    }
    $r = $bySlug[$slug]
    $spec = Get-Content $sf.FullName -Raw | ConvertFrom-Json
    $specIng = @($spec.scaler.ing | Where-Object { (Num $_ 'grams') -gt 0 })
    $lines = @($r.lines)
    $checked++

    # ---- C2 lines are a subsequence of the spec's grams-bearing ingredients, same item and same grams
    $si=0
    foreach($l in $lines){
      $item=[string]$l.item; $g = Num $l 'grams'
      $matched=$false
      while($si -lt $specIng.Count){
        $k = Get-CanonKey $specIng[$si]; $sg = Num $specIng[$si] 'grams'; $si++
        if($k -eq $item -and [math]::Abs($sg - $g) -lt 0.0001){ $matched=$true; break }
        if($k -eq $item){ $fail.Add("C2 $slug :: $item :: costed grams $g but spec says $sg (spec edited without a recost)"); $matched=$true; break }
      }
      if(-not $matched){ $fail.Add("C2 $slug :: $item :: costed line is not in the spec's ingredient order") }
    }

    # ---- C3 priced/unpriced accounting
    $lp = Num $r 'lines_priced'; $lu = Num $r 'lines_unpriced'
    if($lp -ne $lines.Count){ $fail.Add("C3 $slug lines_priced $lp but $($lines.Count) lines present") }
    if(($lp + $lu) -ne $specIng.Count){ $fail.Add("C3 $slug lines_priced+unpriced $($lp+$lu) but spec has $($specIng.Count) grams-bearing ingredients") }

    # ---- per-line checks + running totals for C4..C7
    $sumUtil=0.0; $sumTrue=0.0; $sumBulkUtil=0.0; $sumStarter=0.0
    foreach($l in $lines){
      $item=[string]$l.item; $g = Num $l 'grams'; $util = Num $l 'util_cost'
      $isBulk = ($l.PSObject.Properties['bulk'] -and $l.bulk)
      $buyN = Num $l 'buy_n'; $buyCost = Num $l 'buy_cost'; $pkgG = Num $l 'pkg_g'
      $stN  = Num $l 'starter_n'; $stCost = Num $l 'starter_cost'; $stPkgG = Num $l 'starter_pkg_g'

      # C13
      foreach($pair in @(@('util_cost',$util),@('buy_cost',$buyCost),@('starter_cost',$stCost))){
        $v=$pair[1]
        if($null -ne $v -and ($v -lt 0 -or [double]::IsNaN($v) -or [double]::IsInfinity($v))){ $fail.Add("C13 $slug :: $item :: $($pair[0]) = $v") }
      }
      $sumUtil += $util

      if($isBulk){
        # ---- C11 shape
        if($null -ne $buyN -or $null -ne $buyCost -or $null -ne $pkgG){ $fail.Add("C11 $slug :: $item :: bulk line carries buy package fields") }
        $sumTrue += $util; $sumBulkUtil += $util
        if($null -ne $stPkgG){
          # ---- C10
          $want = EngCeil $g $stPkgG
          if($stN -ne $want){ $fail.Add("C10 $slug :: $item :: starter_n $stN but ceil($g g / $stPkgG g - 0.02) = $want") }
          if($stCost -lt ($util - $Tol)){ $fail.Add("C10 $slug :: $item :: starter_cost $stCost below util_cost $util (the engine clamps it up)") }
          $sumStarter += $stCost
          # ---- C12
          if($pkgSizes.ContainsKey($item) -and @($pkgSizes[$item] | Where-Object { [math]::Abs($_ - $stPkgG) -lt 0.5 }).Count -eq 0){
            if($hasLabel.ContainsKey($item)){ $unverifiable++ } else { $fail.Add("C12 $slug :: $item :: starter_pkg_g $stPkgG is not a package db\ingredients.json defines for it") }
          } elseif(-not $pkgSizes.ContainsKey($item)){ $unverifiable++ }
        } else {
          if($null -ne $stN -or $null -ne $stCost){ $fail.Add("C11 $slug :: $item :: starter_n/cost without starter_pkg_g") }
          $sumStarter += $util   # engine: a bulk item with no pantry def contributes its util to the outlay
        }
      } else {
        if($null -ne $stN -or $null -ne $stCost -or $null -ne $stPkgG){ $fail.Add("C11 $slug :: $item :: non-bulk line carries pantry fields") }
        if($null -ne $pkgG){
          # ---- C9
          $want = EngCeil $g $pkgG
          if($buyN -ne $want){ $fail.Add("C9 $slug :: $item :: buy_n $buyN but ceil($g g / $pkgG g - 0.02) = $want") }
          if($buyCost -lt ($util - $Tol)){ $fail.Add("C9 $slug :: $item :: buy_cost $buyCost below util_cost $util (the engine clamps it up)") }
          $sumTrue += $buyCost
          # ---- C12
          if($pkgSizes.ContainsKey($item) -and @($pkgSizes[$item] | Where-Object { [math]::Abs($_ - $pkgG) -lt 0.5 }).Count -eq 0){
            if($hasLabel.ContainsKey($item)){ $unverifiable++ } else { $fail.Add("C12 $slug :: $item :: pkg_g $pkgG is not a package db\ingredients.json defines for it") }
          } elseif(-not $pkgSizes.ContainsKey($item)){ $unverifiable++ }
        } else {
          if($null -ne $buyN -or $null -ne $buyCost){ $fail.Add("C11 $slug :: $item :: buy_n/cost without pkg_g") }
          $sumTrue += $util
        }
      }
    }

    # ---- C4..C8 the row's own arithmetic
    $batch = Num $r 'cost_batch'; $true_ = Num $r 'cost_batch_true'
    $pantry = Num $r 'cost_pantry_add'; $first = Num $r 'cost_first_run'
    $wBatch=[Math]::Round($sumUtil,2); $wTrue=[Math]::Round($sumTrue,2)
    $wPantry=[Math]::Round($sumStarter - $sumBulkUtil,2); if($wPantry -lt 0){ $wPantry = 0.0 }
    $wFirst=[Math]::Round($wTrue + $wPantry,2)
    if([math]::Abs($batch-$wBatch)  -gt $Tol){ $fail.Add("C4 $slug cost_batch $batch but sum(util_cost) = $wBatch") }
    if([math]::Abs($true_-$wTrue)   -gt $Tol){ $fail.Add("C5 $slug cost_batch_true $true_ but sum(bulk util / buy_cost) = $wTrue") }
    if([math]::Abs($pantry-$wPantry)-gt $Tol){ $fail.Add("C6 $slug cost_pantry_add $pantry but starter outlay - bulk util = $wPantry") }
    if([math]::Abs($first-$wFirst)  -gt $Tol){ $fail.Add("C7 $slug cost_first_run $first but true $true_ + pantry $pantry = $wFirst") }
    $ps = Num $r 'cost_per_serving'; $pst = Num $r 'cost_per_serving_true'
    if([math]::Abs($ps  - [Math]::Round($batch/$SERVINGS,2)) -gt $Tol){ $fail.Add("C8 $slug cost_per_serving $ps but round($batch/$SERVINGS) = $([Math]::Round($batch/$SERVINGS,2))") }
    if([math]::Abs($pst - [Math]::Round($true_/$SERVINGS,2)) -gt $Tol){ $fail.Add("C8 $slug cost_per_serving_true $pst but round($true_/$SERVINGS) = $([Math]::Round($true_/$SERVINGS,2))") }
  }

  # ---- C1 orphans
  foreach($s in $bySlug.Keys){ if(-not $seen.ContainsKey($s)){ $fail.Add("C1 costed row '$s' has no spec in $SpecDir (a deleted recipe still priced)") } }

  return @{ failures=@($fail); checked=$checked; unverifiable=$unverifiable }
}
