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

# THE RECIPE DRAINS WHAT THE ENGINE BUYS GROSS (2026-09-02).
#
# There is no field anywhere that declares "this ingredient's grams are drained grams". The cost engine
# INFERS it (cost-recipes.ps1:141): densities.can is read as a DRAINED yield and buy_pkg_g as the can's
# NET weight, and a row qualifies only when can < buy_pkg_g x 0.95. So a densities row that copies the net
# weight into `can` - Sweet Whole Kernel Corn 432/432, Pineapple Chunks 567/567 - opts OUT of the drained
# branch silently, while its spec lines happily say "cups, drained" and carry drained grams. The engine
# then divides drained grams by a gross can and under-buys: 13 corn recipes were each a can short.
#
# THIS IS THE ONE CONTRADICTION THAT IS VISIBLE WITHOUT A NEW MEASUREMENT. It needs no yield figure and no
# judgement about what a cup weighs: the SPEC says the cook drains the can, and the DB says the engine
# bought it undrained. Those two cannot both be right, whatever the true yield turns out to be. HARD,
# because the wrong number it produces is a shopping list that sends a reader home short.
#
# 'undrained' MUST NOT MATCH. \b already refuses it (there is no word boundary inside "undrained"), and
# the lookbehind states the intent so a later edit to the boundary cannot quietly widen the rule.
#
# A PACKAGE THAT IS ITSELF A DRAINED WEIGHT IS NOT A CONTRADICTION - and this term was added the first
# time the check ran over live data, not designed in. densities.can is one way to say "the buy package
# needs draining down"; declaring buy_pkg_g AS the drained weight is the other, and Black Olives does
# exactly that: buy_pkg_g 170 labelled '6oz drained-weight can', with mediterranean-chicken-w-marinade
# asking for 728 g of drained olives. Drained grams over a drained package is correct arithmetic, so
# firing there would be a false HARD - and a false HARD on this guard blocks wave-publish P5 outright,
# which is how a detector gets reached for with -Skip. Measured 2026-09-02 over all 351 ingredient rows:
# exactly one declares a drained buy package this way and exactly one declares a gross one
# (Sun-Dried Tomatoes (Oil-Packed), 'GROSS jar weight incl. packing oil'), and the guard must tell those
# two apart. It reads the estate's own declaration; it never infers one.
function Test-DrainedLineWithoutYield { param([string]$BuyText,[double]$CanG,[double]$PkgG,[string]$PkgLabel='')
  if($PkgLabel -match '(?<!un)\bdrain(ed)?\b'){ return $false }
  return ($BuyText -match '(?<!un)\bdrained\b' -and $PkgG -gt 0 -and -not ($CanG -gt 0 -and $CanG -lt $PkgG * 0.95)) }

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

  # ---- THE serving_qty HALF OF THE LABEL (2026-09-02) ----------------------------------------------
  # FROZEN as read from meal-prep\food-macros-db.json and db\densities.json on 2026-09-02, BEFORE the corn
  # re-basis moved either file. These are the literal rows, not a regeneration: re-reading them from the
  # live files after the fix would make the founding bug vanish and the case would pass by finding nothing.
  T 'MUST FIRE  a 1/2-cup label serving is TWO servings to the cup (Sweet Whole Kernel Corn 165 vs 125/0.5 = 250)' `
    (Test-BaseDrift 165 (125 / (0.5 * (Get-LabelUnitQty 'cup' 'cup')))) `
    'still skipping every serving_qty != 1 row, which is every Great Value canned-vegetable label'
  # CLEAN TWINS: three live rows with the SAME serving_qty 0.5 / 0.25 shape whose bases genuinely agree.
  # Normalising is not excusing - if these went noisy the change would have traded a blind guard for a
  # crying one, and this file's own header says which of those is worse.
  T 'CLEAN TWIN Refried Beans 260 vs {0.5 cup = 130 g} -> 260, silent' `
    (-not (Test-BaseDrift 260 (130 / (0.5 * (Get-LabelUnitQty 'cup' 'cup'))))) 'false positive on a row that agrees'
  T 'CLEAN TWIN Cottage Cheese 226 vs {0.5 cup = 113 g} -> 226, silent' `
    (-not (Test-BaseDrift 226 (113 / (0.5 * (Get-LabelUnitQty 'cup' 'cup'))))) 'false positive on a row that agrees'
  T 'CLEAN TWIN Rice 180 vs {0.25 cup = 45 g} -> 180, silent' `
    (-not (Test-BaseDrift 180 (45 / (0.25 * (Get-LabelUnitQty 'cup' 'cup'))))) 'false positive on a row that agrees'
  # AND THE OTHER ENCODING MUST STILL WORK. Ricotta states its fraction in the label SENTENCE with
  # serving_qty 1; the two encodings multiply, and measured over all 434 rows on 2026-09-02 not one
  # carries both, so the product is never applied twice.
  T 'CLEAN TWIN the label-sentence fraction still reconciles when serving_qty is 1 (Ricotta 62 -> 248 vs 246)' `
    (-not (Test-BaseDrift 246 (62 / (1 * (Get-LabelUnitQty '1/4 cup (62g), about 7 servings per container' 'cup'))))) `
    'the serving_qty factor broke the label-sentence branch'

  # ---- DRAINED-NO-YIELD (2026-09-02) --------------------------------------------------------------
  # FROZEN: street-corn-chicken-rice-bowls' real line as it stood this morning - buy '7 cups, drained',
  # densities can 432, ingredients buy_pkg_g 432. That is the founding bug: the cook drains the can, the
  # engine buys it whole, and 1148 g / 432 bought three cans where four are needed.
  T 'MUST FIRE  a line that says drained on an item whose densities.can is the NET weight (street-corn corn 432/432)' `
    (Test-DrainedLineWithoutYield '7 cups, drained' 432 432) `
    'the basis contradiction that under-bought a can of corn on 13 recipes is invisible again'
  # CLEAN TWIN 1: the same shape with a real drained yield present - chili-cornbread-casserole's Kidney
  # Beans, 255 g drained against a 425 g net can. This is what a correctly encoded drained item looks like.
  T 'CLEAN TWIN a drained line WITH a yield is silent (Kidney Beans 255 drained / 425 net)' `
    (-not (Test-DrainedLineWithoutYield '3 cans, drained' 255 425)) 'fires on a correctly encoded drained item'
  # CLEAN TWIN 2: Refried Beans, can 454 == buy_pkg_g 454 and nothing is drained. A can whose densities
  # row copies the net weight is only a defect when the RECIPE drains it.
  T 'CLEAN TWIN a gross can that nobody drains is silent (Refried Beans 454/454, buy "1 can")' `
    (-not (Test-DrainedLineWithoutYield '1 can' 454 454)) 'fires on every gross can in the catalogue'
  # CLEAN TWIN 3: the fix itself. After densities.can moves to the USDA drained yield the founding row
  # must go quiet, or the guard would block its own repair.
  T 'CLEAN TWIN the SAME street-corn line goes silent once can becomes the drained yield (298/432)' `
    (-not (Test-DrainedLineWithoutYield '7 cups, drained' 298 432)) 'the guard cannot be satisfied by fixing the data'
  # 'undrained' IS ITS OWN WORD. A line that says the can goes in juice and all is not a drained line.
  T 'MUST NOT FIRE  "undrained" is not "drained"' `
    (-not (Test-DrainedLineWithoutYield '2 cans, undrained' 567 567)) 'matched the substring inside undrained'
  T 'CLEAN TWIN an item with no buy package at all has nothing to contradict' `
    (-not (Test-DrainedLineWithoutYield '2 cups, drained' 0 0)) 'fired on a bulk item with no package def'
  # CLEAN TWIN 4, FROZEN from db\ingredients.json 'Black Olives' as read 2026-09-02: buy_pkg_g 170 with the
  # label '6oz drained-weight can', against mediterranean-chicken-w-marinade's 728 g of drained olives.
  # The first live run of this predicate reported it HARD; it is correct arithmetic, and it is the reason
  # the package label is now part of the question.
  T 'CLEAN TWIN a buy package that IS a drained weight is not a contradiction (Black Olives 170 g "6oz drained-weight can")' `
    (-not (Test-DrainedLineWithoutYield 'about 1 1/2 lb drained black olives (three 14.5 oz cans)' 0 170 '6oz drained-weight can')) `
    'false HARD on a correctly drained package - this blocks wave-publish P5'
  # AND THE TWIN MUST NOT BECOME A LOOPHOLE. The same line against a package NOT declared drained still
  # fires, so the exemption is the declaration and nothing else.
  T 'MUST FIRE  the same olive line against an undeclared package still fires' `
    (Test-DrainedLineWithoutYield 'about 1 1/2 lb drained black olives (three 14.5 oz cans)' 0 170 '6oz can') `
    'the package-label term swallowed the whole check'
  # FROZEN from db\ingredients.json 'Sun-Dried Tomatoes (Oil-Packed)': buy_pkg_g 680, label '24oz jar',
  # note 'GROSS jar weight incl. packing oil (Brad, 2026-08-16). Do not correct to drained weight - that
  # would be a guess.' creamy-tuscan-chicken-skillet asks for 193 g '1 3/4 cups oil-packed, drained'.
  T 'MUST FIRE  a jar declared GROSS against a line that drains it (Sun-Dried Tomatoes 680 g "24oz jar")' `
    (Test-DrainedLineWithoutYield '1 3/4 cups oil-packed, drained' 0 680 '24oz jar') `
    'the oil-packed gross-jar case went silent'
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
  # ---- DRAINED-NO-YIELD: the spec drains a can the engine buys whole ----------------------------------
  # Read off the SAME three stores this guard already loads. Walks scaler.ing rather than the built card,
  # because a spec with no card yet is exactly the one about to publish with the defect in it.
  foreach($si in @($sp.scaler.ing)){
    if(-not $si){ continue }
    $sName = if($si.canon){ [string]$si.canon } else { [string]$si.item }
    $sBuy  = if($si.PSObject.Properties.Name -contains 'buy'){ [string]$si.buy } else { '' }
    if(-not $sBuy){ continue }
    if(-not $ingm.ContainsKey($sName)){ continue }               # MISSING-SIDE above already owns that
    $iRow = $ingm[$sName]
    if($iRow.PSObject.Properties.Name -notcontains 'buy_pkg_g'){ continue }
    $pkgG = [double]$iRow.buy_pkg_g
    $pkgL = if($iRow.PSObject.Properties.Name -contains 'buy_pkg_label'){ [string]$iRow.buy_pkg_label } else { '' }
    $canG = 0.0
    $dRow = $dens.PSObject.Properties[$sName]
    if($dRow -and ($dRow.Value.PSObject.Properties.Name -contains 'can')){ $canG = [double]$dRow.Value.can }
    if(Test-DrainedLineWithoutYield $sBuy $canG $pkgG $pkgL){
      $hard.Add("DRAINED-NO-YIELD: $($sf.BaseName) :: $sName :: line says drained but densities.can $canG is not a drained yield against buy_pkg_g $pkgG - the cook drains the can, the engine buys it whole, so buy_n is computed off gross grams and under-buys")
    }
  }

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
    # NORMALISE THE LABEL BEFORE COMPARING. serving_grams is the weight of ONE SERVING, and the serving
    # is only sometimes one whole $u - see Get-LabelUnitQty. $null means this unit is not the one the
    # serving is stated in, which is a skip rather than a finding: there is nothing to compare.
    $labelQty = Get-LabelUnitQty ([string]$row.serving_unit) $u
    if($null -eq $labelQty -or $labelQty -le 0){ continue }
    # THE SERVING SIZE LIVES IN TWO FIELDS, AND THIS CHECK USED TO READ ONLY ONE (2026-09-02).
    #
    # It opened with `if([double]$row.serving_qty -ne 1){ continue }`, which skipped 296 of 434 food-DB
    # rows - and not a random 296. "1/2 cup (125g)" is transcribed as serving_qty 0.5 with serving_unit
    # 'cup', which is the shape of EVERY Great Value canned-vegetable label in this DB, so the one class
    # of row this check exists to police was the one class it never looked at. Sweet Whole Kernel Corn
    # sat at 165 g/cup in densities against 125/0.5 = 250 g/cup on its label - a 34% split, invisible
    # since the row was written, and the reason 13 recipes under-bought a can of corn each.
    #
    # BOTH FIELDS MULTIPLY. serving_qty is how many of the stated unit make one serving; Get-LabelUnitQty
    # is how many of $u the LABEL SENTENCE leads with. Measured 2026-09-02 over all 434 rows: ZERO carry
    # both encodings (no row has serving_qty != 1 AND a leading number in serving_unit), so the product
    # can never be applied twice. A row that only ever states one of them multiplies by 1 and behaves
    # exactly as before.
    $sq = [double]$row.serving_qty
    if($sq -le 0){ $sq = 1 }
    $qty = $sq * $labelQty
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
