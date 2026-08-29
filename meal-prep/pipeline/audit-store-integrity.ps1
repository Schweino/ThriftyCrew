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
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'lib\guard-contract.ps1')
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mp   = Split-Path -Parent $here

# ---- pure predicates, so the founding bugs can be pinned without touching a live file ----
function Test-MissingSide { param($Item,$InPrice,$InMacro)
  $m=@(); if(-not $InPrice){ $m+='no ingredients.json row (its cost line is silently dropped)' }
  if(-not $InMacro){ $m+='no food-macros-db row (the macro recompute cannot run)' }; return $m }
function Test-NameSplit { param([string]$ScalerName,[string]$MacroName)
  return ($ScalerName -ne $MacroName) }
# HARD or WARN for a name split. Pairing decides it, not resolvability: an intentional display override
# renames one item, so exactly one macro-only name is balanced by one scaler-only name. An UNBALANCED split
# means a line exists on one side and nowhere on the other, which is a dropped cost line or an uncounted
# ingredient - and this is what tiered the founding defect into a WARN nobody alerts on.
function Test-SplitPaired { param([int]$MacroOnly,[int]$ScalerOnly)
  return ($MacroOnly -gt 0 -and $MacroOnly -eq $ScalerOnly) }
function Test-BaseDrift { param([double]$DensityGrams,[double]$FoodDbGrams,[double]$Tol=0.05)
  if($FoodDbGrams -le 0 -or $DensityGrams -le 0){ return $false }
  return ([Math]::Abs($DensityGrams-$FoodDbGrams)/$FoodDbGrams -gt $Tol) }

# HOW MANY OF $Unit IS ONE SERVING? Returns $null when the label does not LEAD with that unit.
#
# WHY THIS EXISTS (2026-08-29). This guard compared densities' grams-per-cup straight against the food
# DB's serving_grams whenever serving_unit merely CONTAINED the word "cup" and serving_qty was 1. But
# serving_unit is a transcribed label sentence, not a unit token - "1/4 cup (62g), about 7 servings per
# container" - so the row means one serving IS a QUARTER cup and IS 62 g. Comparing 246 against 62 and
# calling it a 4x conflict was the guard doing the arithmetic wrong, not the data disagreeing.
#
# MEASURED, because reversing a MUST-FIRE case needs more than an argument. Dividing by the label's own
# fraction reconciles the rows to within rounding, four separate times: Ricotta 62/(1/4)=248 vs 246
# (0.8%), Mexican Cheese Blend 28/(1/4)=112 vs 113 (0.9%), Orzo 56/(1/3)=168 vs 170 (1.2%), Cheese
# Tortellini 120/1=120 vs 122 (1.7%). Four independent products cannot land inside 2% by accident, so
# the food DB rows are faithful transcriptions and this guard's reading of them was the defect. All 13
# standing WARNs were artifacts of it - and this file's own line 173 already warns that a guard crying
# wolf "trains people to scroll past" it.
#
# THE LEADING UNIT IS THE SERVING'S UNIT. Chili Crisp reads "1/4 cup (60g); per 1 tbsp (~14g) that is
# ~98 cal" - it contains "tbsp", so the old check compared densities' 14 g/tbsp against the 60 g that
# belongs to the CUP. A unit mentioned later in the sentence is commentary; only the one the serving is
# actually stated in may be normalised against, so a non-leading unit returns $null and is skipped.
function Get-LabelUnitQty { param([string]$ServingUnit,[string]$Unit)
  if(-not $ServingUnit -or -not $Unit){ return $null }
  $s = $ServingUnit.Trim()
  $u = [regex]::Escape($Unit)
  # '1 1/3 tbsp' - a whole number and a fraction. Must be tried first: the bare-fraction pattern below
  # would otherwise read '1 1/3' as 1/3 and understate the serving by a whole unit.
  $m = [regex]::Match($s, '^(\d+)\s+(\d+)\s*/\s*(\d+)\s*' + $u + '\b')
  if($m.Success){ return [double]$m.Groups[1].Value + ([double]$m.Groups[2].Value / [double]$m.Groups[3].Value) }
  $m = [regex]::Match($s, '^(\d+)\s*/\s*(\d+)\s*' + $u + '\b')                      # '1/4 cup'
  if($m.Success){ return [double]$m.Groups[1].Value / [double]$m.Groups[2].Value }
  $m = [regex]::Match($s, '^(\d+(?:\.\d+)?)\s*' + $u + '\b')                        # '2 tbsp', '1 cup'
  if($m.Success){ return [double]$m.Groups[1].Value }
  $m = [regex]::Match($s, '^' + $u + '\b')                                          # bare 'cup'
  if($m.Success){ return 1.0 }
  return $null }

# AN ALIAS IS A PRICE ROW (2026-08-16). This guard indexed db\ingredients.json by `item` alone, so every
# canon name that reaches its row through an adjudicated ALIAS read as "no ingredients.json row (its cost
# line is silently dropped)" - a sentence that is false twice over: the row is there, and the line is
# priced. V2 of the vocabulary plan made aliases first-class on 2026-08-16 and the cost engine learned them
# (f60ede7f); this reader did not, so it reported 8 hard findings for 7 Brad-adjudicated aliases (Cream
# Cheese, Sour Cream, Smoked Sausage, Andouille Smoked Sausage, Baby Bella (Crimini) Mushrooms, Tandoori
# Masala, Pepperoni). wave-publish P5 hard-fails on any non-zero exit, so a guard crying wolf about a
# mechanism the estate deliberately adopted was blocking every wave in the run from publishing at all.
# A false HARD is worse than no guard: it trains the operator to reach for -Skip on the one gate that must
# never be skipped. Build the price-side index over item names AND their aliases, exactly as resolution
# actually works.
function Add-PriceNames { param($Rows,[hashtable]$Map)
  foreach($r in $Rows){
    $n=[string]$r.item
    if(-not $n){ continue }
    if(-not $Map.ContainsKey($n)){ $Map[$n]=$r }
    if($r.PSObject.Properties.Name -notcontains 'aliases'){ continue }
    foreach($a in @($r.aliases)){ $an=[string]$a; if($an -and -not $Map.ContainsKey($an)){ $Map[$an]=$r } }
  }
  return $Map }

if($SelfTest){
  $f=0
  function T($m,$c,$g){ if($c){ Write-Output ("ok    "+$m) } else { Write-Output ("FAIL  "+$m+"   got: "+$g); $script:f++ } }
  # FROZEN FIXTURE: creamy-mushroom-pork-chops-over-mashed-potatoes as it shipped - 13 macro items, 12 scaler
  # items, Garlic Powder counted in the macros with no cost line anywhere. "Garlic Powder" resolves in both
  # stores, so the old resolvability tiering filed this WARN and the daily chain alerts on HARD only.
  T 'MUST FIRE  a ONE-SIDED split is a dropped cost line, not a rename (macros 13, scaler 12)' `
    (-not (Test-SplitPaired 1 0)) 'tiered WARN, which is how the founding defect stayed quiet'
  # CLEAN TWIN: the japchae display override, which is the reason the WARN tier exists at all.
  T 'CLEAN TWIN a PAIRED rename (Rice Noodles <-> Korean glass noodles) stays a WARN' `
    (Test-SplitPaired 1 1) 'promoted a legitimate display override to HARD'
  T 'CLEAN TWIN no split at all is not paired'                                          (-not (Test-SplitPaired 0 0)) 'spurious'
  T 'MUST FIRE  an uncounted-but-costed ingredient (scaler surplus) is also unpaired'    (-not (Test-SplitPaired 0 1)) 'missed'
  # FROZEN FIXTURES - each is a real defect this estate actually shipped, with the twin that must stay quiet.
  T 'MUST FIRE  macros but no price row (the 6 items that dropped out of recipe cost)' ((Test-MissingSide -Item 'Rotisserie Chicken' -InPrice $false -InMacro $true).Count -eq 1) 'no finding'
  T 'MUST FIRE  price row but no macros (the spinach that made build-v2-spec throw)'   ((Test-MissingSide -Item 'Spinach' -InPrice $true -InMacro $false).Count -eq 1) 'no finding'
  T 'MUST FIRE  neither side (the 19 unmapped names)'                                  ((Test-MissingSide -Item 'Panko Breadcrumbs' -InPrice $false -InMacro $false).Count -eq 2) 'wrong count'
  T 'CLEAN TWIN an item present on both sides'                                         ((Test-MissingSide -Item 'Rice' -InPrice $true -InMacro $true).Count -eq 0) 'spurious finding'
  T 'MUST FIRE  a spec naming one thing to cost and another to count macros'           (Test-NameSplit 'Green Olives' 'Olives') 'no finding'
  T 'CLEAN TWIN both arrays naming the same item'                                      (-not (Test-NameSplit 'Rice' 'Rice')) 'spurious finding'
  T 'MUST FIRE  Rice at 185 g/cup in densities against 200 in the food DB'             (Test-BaseDrift 185 200) 'no finding'
  T 'CLEAN TWIN a base inside rounding (203 vs 200)'                                   (-not (Test-BaseDrift 203 200)) 'spurious finding'
  T 'CLEAN TWIN a missing base is not drift'                                           (-not (Test-BaseDrift 0 200)) 'spurious finding'

  # ---- THE LABEL FRACTION (2026-08-29) -------------------------------------------------------------
  # A CASE WAS REVERSED HERE, deliberately, and this is the reasoning so nobody re-flips it by feel.
  # This suite used to assert:
  #     'MUST FIRE  Ricotta at 246 g/cup against 62 (a 1/4-cup serving labelled a cup)'  Test-BaseDrift 246 62
  # The case NAME had the diagnosis right - it is a 1/4-cup serving - and then demanded a finding
  # anyway, which pinned the arithmetic error in place as an invariant. 62 g is not Ricotta's cup
  # weight and was never claimed to be; it is the weight of a quarter cup, and 62 x 4 = 248 against
  # densities' 246. The rows agreed all along.
  T 'a quarter-cup label serving normalises to the cup, and then AGREES (Ricotta 62 -> 248 vs 246)' `
    (-not (Test-BaseDrift 246 (62 / (Get-LabelUnitQty '1/4 cup (62g), about 7 servings per container' 'cup')))) `
    'still reporting the founding false positive'
  T 'the same holds for shredded cheese (Mexican Cheese Blend 28 -> 112 vs 113)' `
    (-not (Test-BaseDrift 113 (28 / (Get-LabelUnitQty '1/4 cup (28g), about 8 servings per container' 'cup')))) 'false positive'
  T 'and for a third-cup label (Orzo 56 -> 168 vs 170)' `
    (-not (Test-BaseDrift 170 (56 / (Get-LabelUnitQty '1/3 cup (56g) dry' 'cup')))) 'false positive'
  # AND THE GUARD MUST STILL BITE. Normalising is not the same as excusing: a row whose normalised base
  # really does disagree has to fail, or this change would have replaced a noisy guard with a silent one.
  T 'MUST FIRE  a genuinely drifted base still fails after normalising (100 vs 56/(2/3)=84)' `
    (Test-BaseDrift 100 (56 / (Get-LabelUnitQty '2/3 cup (56g) dry' 'cup'))) 'the fix silenced a real finding'

  T 'a bare unit with no number is one of that unit'      ((Get-LabelUnitQty 'cup' 'cup') -eq 1)              ([string](Get-LabelUnitQty 'cup' 'cup'))
  T 'an explicit whole number is read as itself'          ((Get-LabelUnitQty '2 tbsp (30g) paste' 'tbsp') -eq 2) ([string](Get-LabelUnitQty '2 tbsp (30g) paste' 'tbsp'))
  # '1 1/3 tbsp' must not read as 1/3. Achiote Paste is the live row: 20 g per 1 1/3 tbsp is 15 g/tbsp,
  # where reading the fraction alone would claim 60 and invent a 4x drift out of nothing.
  T 'MUST FIRE  a mixed number is not read as its fraction alone (1 1/3 tbsp, not 1/3)' `
    ([Math]::Abs((Get-LabelUnitQty '1 1/3 tbsp (20g)' 'tbsp') - 1.3333) -lt 0.001) ([string](Get-LabelUnitQty '1 1/3 tbsp (20g)' 'tbsp'))
  # THE CHILI CRISP CASE. Its label mentions tbsp only as an aside after the cup serving, so the old
  # substring test compared densities' 14 g/tbsp against the 60 g belonging to the cup.
  T 'MUST NOT FIRE  a unit mentioned only later in the sentence is not the serving unit' `
    ($null -eq (Get-LabelUnitQty '1/4 cup (60g); per 1 tbsp (~14g) that is ~98 cal' 'tbsp')) `
    ([string](Get-LabelUnitQty '1/4 cup (60g); per 1 tbsp (~14g) that is ~98 cal' 'tbsp'))
  T 'CLEAN TWIN ...but the LEADING unit on that same label still resolves' `
    ((Get-LabelUnitQty '1/4 cup (60g); per 1 tbsp (~14g) that is ~98 cal' 'cup') -eq 0.25) `
    ([string](Get-LabelUnitQty '1/4 cup (60g); per 1 tbsp (~14g) that is ~98 cal' 'cup'))
  T 'a unit absent from the label yields nothing to compare' ($null -eq (Get-LabelUnitQty '1 slice (28g)' 'cup')) 'matched a unit that is not there'
  # EVERY BRANCH MUST BE ANCHORED, not just the bare-unit one. Found by neuter: dropping the leading ^
  # from the FRACTION branch left the suite green, because no fixture stated its serving in one unit and
  # then mentioned a fraction of another. This is that fixture. Unanchored, 'cup' would resolve to 0.5
  # here and the guard would compare densities' grams-per-cup against 113/0.5 = 226 g - a fabricated
  # base for a food sold by the patty.
  T 'MUST NOT FIRE  a fraction of a DIFFERENT unit later in the label is not the serving' `
    ($null -eq (Get-LabelUnitQty '1 patty (113g), about 1/2 cup crumbled' 'cup')) `
    ([string](Get-LabelUnitQty '1 patty (113g), about 1/2 cup crumbled' 'cup'))
  T 'CLEAN TWIN ...and the unit it IS stated in still resolves' `
    ((Get-LabelUnitQty '1 patty (113g), about 1/2 cup crumbled' 'patty') -eq 1) `
    ([string](Get-LabelUnitQty '1 patty (113g), about 1/2 cup crumbled' 'patty'))
  # ALIAS INDEXING - the 2026-08-16 false-HARD class that blocked three waves. Fixture mirrors the real rows.
  $aliasRows = @(
    [pscustomobject]@{ item='1/3 Fat Cream Cheese'; bid='1-3-fat-cream-cheese'; aliases=@('Cream Cheese') },
    [pscustomobject]@{ item='Pork Smoked Sausage';  bid='kielbasa'; aliases=@('Smoked Sausage','Andouille Smoked Sausage') },
    [pscustomobject]@{ item='Salt';                 bid='salt' }
  )
  $am = Add-PriceNames $aliasRows @{}
  T 'MUST FIRE  an adjudicated alias resolves as a price row'        ($am.ContainsKey('Cream Cheese'))              'alias still reads as MISSING-SIDE'
  T 'MUST FIRE  a second alias on one row resolves too'              ($am.ContainsKey('Andouille Smoked Sausage'))  'only the first alias indexed'
  T 'an alias points at its OWN row, not a copy'                     ([string]$am['Cream Cheese'].bid -eq '1-3-fat-cream-cheese') ([string]$am['Cream Cheese'].bid)
  T 'the row name itself still resolves'                             ($am.ContainsKey('Pork Smoked Sausage'))       'item name lost'
  T 'a row with no aliases array is handled'                         ($am.ContainsKey('Salt'))                      'threw or skipped'
  # CLEAN TWIN: widening the index must not make an unknown name resolve - that would hide real dropped lines.
  T 'CLEAN TWIN an unmapped name still does NOT resolve'             (-not $am.ContainsKey('Panko Breadcrumbs'))    'alias widening swallowed a real MISSING-SIDE'
  if($f -eq 0){ Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

$hard = New-Object System.Collections.Generic.List[string]
$warn = New-Object System.Collections.Generic.List[string]

$ing = Get-Content (Join-Path $mp 'db\ingredients.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$ingm=@{}; $ingm = Add-PriceNames $ing $ingm   # item names AND adjudicated aliases - see Add-PriceNames
# THIS EXIT READ AS A CLEAN CROSS-STORE CHECK (2026-08-23). check-ad-cycles judges this guard on its
# OUTPUT, not its exit code: zero lines means "did not run", any line starting with ! is a HARD
# finding, and anything else falls through to "no hard findings". This branch printed one line that
# started with 'a' and exited 1 - so a parse error severe enough to index under 200 price names was
# reported to Brad as a clean board. Prefix it so it lands in the hard set where it belongs, and mark
# completion so a real crash here still reads as a crash.
if($ingm.Count -lt 200){
  Write-Output ("  ! audit-store-integrity: indexed only $($ingm.Count) price names - implausible; parse error, not data.")
  Write-GuardComplete -Name 'store-integrity' -Summary 'BLIND: price-name index implausibly small'
  exit 1
}
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
  # PAIRING, not resolvability, is what separates a rename from a dropped line. The first version tiered on
  # "does the name resolve in both stores", which says nothing about whether the spec actually COSTS the item -
  # so creamy-mushroom-pork-chops-over-mashed-potatoes, which counts Garlic Powder in its macros and has no
  # scaler line for it at all (macros 13, scaler 12), was filed WARN and the caller only alerts on HARD. That
  # is the founding dropped-cost-line defect, tiered into silence.
  # A genuine display override is PAIRED: the japchae card renames "Rice Noodles" to "Korean glass noodles",
  # so one macro-only name is matched by one scaler-only name and the arrays stay the same length. A ONE-SIDED
  # split means a line exists on one side and nowhere on the other - macro-only is a cost line silently
  # dropped from the total, scaler-only is an ingredient costed but not counted in the macros.
  $macroOnly  = @($macroNames  | Where-Object { $scalerNames -notcontains $_ })
  $scalerOnly = @($scalerNames | Where-Object { $macroNames  -notcontains $_ })
  $paired = Test-SplitPaired $macroOnly.Count $scalerOnly.Count
  foreach($n in $macroOnly){
    $line = "NAME-SPLIT: $($sf.BaseName) macro basis says '$n', the scaler does not"
    if(-not ($fdbm.ContainsKey($n) -and $ingm.ContainsKey($n))){ $hard.Add($line + ' - and it does not resolve on both sides, so this is a half-finished rename') }
    elseif($paired){ $warn.Add($line + ' (paired with a scaler-only name and both resolve - an intentional display override)') }
    else { $hard.Add($line + " - and NOTHING on the scaler side is unmatched to pair it with, so this item's cost is silently missing from the recipe total (macros $($macroNames.Count), scaler $($scalerNames.Count))") }
  }
  foreach($n in $scalerOnly){
    $line = "NAME-SPLIT: $($sf.BaseName) scaler says '$n', the macro basis does not"
    if(-not ($fdbm.ContainsKey($n) -and $ingm.ContainsKey($n))){ $hard.Add($line + ' - and it does not resolve on both sides, so this is a half-finished rename') }
    elseif($paired){ $warn.Add($line + ' (paired with a macro-only name and both resolve - an intentional display override)') }
    else { $hard.Add($line + " - and NOTHING on the macro side is unmatched to pair it with, so this item is bought and costed but not counted in the macros (macros $($macroNames.Count), scaler $($scalerNames.Count))") }
  }

  # ---- BID TARGET is NOT checked here, deliberately. ----------------------------------------------------
  # engine\audit-db-agreement.ps1 (see its note at "BID single-source") already holds it: db\ingredients.json
  # is canonical, a spec's scaler bid is a derived copy, and any mismatch NOT enumerated in
  # db\spec-bid-overrides.json fails that guard closed. So the Turkey Bacon defect named in this file's header
  # DOES have detection - in the sibling guard, not here.
  # A version of this check was added here on 2026-08-07 and removed the same hour: it reported 79 HARD
  # findings because it did not consult the overrides list, and every one of them was the intentional
  # Rice -> jasmine-rice variant. That is the two-copies-of-a-rule class arriving as a false-positive flood -
  # a second copy of a rule that disagrees with the first is worse than no copy, because it trains people to
  # scroll past the guard. If bid coverage ever needs widening, widen it in audit-db-agreement.
}

# ---- 3: densities vs the food DB's own serving base ----
foreach($p in $dens.PSObject.Properties){
  $item=$p.Name; if(-not $fdbm.ContainsKey($item)){ continue }
  $row=$fdbm[$item]
  foreach($u in @('cup','tbsp','each')){
    if(-not $p.Value.PSObject.Properties[$u]){ continue }
    if([double]$row.serving_qty -ne 1){ continue }
    # NORMALISE THE LABEL BEFORE COMPARING. serving_grams is the weight of ONE SERVING, and the serving
    # is only sometimes one whole $u - see Get-LabelUnitQty. $null means this unit is not the one the
    # serving is stated in, which is a skip rather than a finding: there is nothing to compare.
    $qty = Get-LabelUnitQty ([string]$row.serving_unit) $u
    if($null -eq $qty -or $qty -le 0){ continue }
    $dbPerUnit = [double]$row.serving_grams / $qty
    if(Test-BaseDrift ([double]$p.Value.$u) $dbPerUnit){
      # Show the label's own fraction as a fraction. [Math]::Round on 2/3 prints 0.666666666666667,
      # which reads as a computed quantity rather than the "2/3 cup" actually printed on the box.
      $qtyText = switch($true){
        ([Math]::Abs($qty - [Math]::Round($qty,0)) -lt 0.001) { [string][int][Math]::Round($qty,0); break }
        default { $r = [Math]::Round($qty,3); "$r" }
      }
      $labelFrac = ([regex]::Match([string]$row.serving_unit, '^\s*(\d+(?:\s+\d+\s*/\s*\d+)?|\d+\s*/\s*\d+)\s*' + [regex]::Escape($u))).Groups[1].Value
      if($labelFrac){ $qtyText = ($labelFrac -replace '\s+',' ').Trim() }
      $shown = if($qty -eq 1){ "$($row.serving_grams) g" } else { "$([Math]::Round($dbPerUnit,0)) g (label serving $($row.serving_grams) g per $qtyText $u)" }
      $warn.Add("BASE-DRIFT: '$item' one $u is $($p.Value.$u) g in densities but $shown in the food DB - buy labels and macros disagree about the same measure")
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
Write-GuardComplete -Name 'store-integrity' -Summary ("hard={0} warn={1}" -f $hard.Count, $warn.Count)
exit $(if($hard.Count){ 1 } else { 0 })
