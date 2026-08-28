<#
  audit-schema-constraints.ps1 - what a REAL database would refuse to store.

  WHY THIS EXISTS (2026-08-08 architecture review, step 1 of the storage redesign). The estate keeps eight
  files that must agree about the same nouns - db\ingredients.json (price+bid), food-macros-db.json (macros),
  db\densities.json (household units), db\costed.json, ingredient-map.json, recipes-db.json,
  pipeline\v2-perserving.json and the 542 specs. Nothing STRUCTURALLY enforces that agreement, so it is
  enforced by guards written after each incident: Rice 185 g/cup in one file and 200 in another, Turkey
  Bacon's bid pointing at PORK, six items with macros but no price row, Garlic Powder counted in a recipe's
  macros with no cost line anywhere. Every one of those is a constraint violation that a relational store
  would have refused at write time.

  This script does NOT migrate anything. It expresses the intended schema as declarative constraints and
  runs them over today's live data, so the migration's true cost is a measured number rather than a hope.
  Run it before and after any storage change; it is dependency-free (no SQLite, no python) on purpose, so
  it works on this machine exactly as it works on a runner.

  THE INTENDED SCHEMA (the shape being tested, not yet the shape being stored):

    commodity(id PK, label, unit)                            <- grocery\commodities.json
    item(name PK, bid -> commodity.id, gpu, unit,            <- db\ingredients.json
         buy_pkg_g, buy_pkg_label)
    item_alias(alias PK, item -> item.name)                  <- db\ingredients.json `aliases`
    item_macro(item -> item.name, serving_grams,             <- food-macros-db.json
               calories, protein_g, carbs_g, fat_g)          UNIQUE(item)
    item_density(item -> item.name, unit, grams)             <- db\densities.json
                                                             UNIQUE(item, unit)
    spec(slug PK, cal, protein, cost_ps)                     <- db\recipes\*.json
    spec_ingredient(slug -> spec.slug, item -> item.name,    <- spec.scaler.ing + ingredients_grams
                    canon, grams, bid -> commodity.id)       UNIQUE(slug, item)
                    (canon = the spec's own word; item = the row it resolves to)

  CONSTRAINT CLASSES CHECKED (each names the real defect that motivated it):
    FK-BID        an item's bid must name a real commodity          (Turkey Bacon -> PORK)
    FK-SPEC-ITEM  a spec ingredient must name a real item row       (the 6 macro-only items)
                  -- "name" means item name OR adjudicated alias, see Resolve-ItemName
    FK-SPEC-BID   a spec ingredient's bid must name a real commodity
    MACRO-IDENTITY a macro row a SPEC CONSUMES must belong to the item that spec is priced against
                  -- the hard half of the old ORPHAN-MACRO; see Get-OrphanMacroClass
    ORPHAN-MACRO  BACKLOG, never hard: a macro row with no price row that no spec consumes
    ORPHAN-DENS   a density row must belong to a known item
    NOT-NULL-GPU  a priced item needs a grams-per-unit
    UNIQUE-ITEM   one row per item name, per store
    AGREE-DENSITY densities.json and the food DB must not state different grams for the same unit (Rice)
    PAIRED-COST   every macro-counted ingredient must also be costed, and vice versa (Garlic Powder)

  Usage: .\audit-schema-constraints.ps1 [-ShowAll] | -SelfTest
#>
param([switch]$ShowAll, [switch]$SelfTest, [switch]$Baseline, [string]$Root = "")
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'lib\guard-contract.ps1')
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$mpRoot = if ($Root) { $Root } else { Split-Path -Parent $here }
$gRoot  = Join-Path (Split-Path $mpRoot -Parent) 'grocery'

# ---- pure predicates (the constraint logic, testable without any data on disk) ---------------------------
function Test-ForeignKey { param([string]$Value, $ValidKeys)
  # a NULL/absent FK is allowed (the column is nullable); a PRESENT one must resolve
  if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
  return ($ValidKeys -contains $Value)
}
function Test-DensityAgreement { param([double]$A, [double]$B, [double]$Tol = 0.05)
  if ($A -le 0 -or $B -le 0) { return $true }          # nothing to compare
  return ([Math]::Abs($A - $B) / $B -le $Tol)
}
# SOME DISAGREEMENTS ARE THE CORRECT ANSWER, AND THE ESTATE ALREADY WROTE DOWN WHY.
# db\densities.json's basis_reconciliation_2026_08_07 note settles the canned-bean and corn cups: 172/165
# here are DRAINED yields, 260/250 are AS-PACKED label servings - "two different measurements of two
# different things, and merging them would be the error, not the fix". Fresh Basil and Green Onions are the
# same story in produce. A guard that reports those is not finding a defect, it is re-litigating a decision
# someone already made with sources - and it would page daily forever about a settled question.
# The exception list is DERIVED FROM THAT NOTE, not typed independently, so if the note changes this must.
$script:DENSITY_BASIS_EXCEPTIONS = @(
  'Canned Black Beans', 'Seasoned Black Beans', 'Canned Pinto Beans', 'Cannellini Beans', 'Kidney Beans',
  'Chickpeas', 'Refried Beans', 'Sweet Whole Kernel Corn', 'Fresh Basil', 'Green Onions'
)
function Get-AliasMap { param($Items)
  # alias -> row, from db\ingredients.json's `aliases` arrays. The comment rows ('_r300_note') own nothing,
  # and a contested alias is left with its FIRST claimant - audit-vocab-integrity is the guard that reports
  # that collision, and two guards must not disagree about which row won.
  $m = @{}
  foreach ($r in @($Items)) {
    $n = [string]$r.item
    if (-not $n -or $n -like '_*') { continue }
    if ($r.PSObject.Properties.Name -notcontains 'aliases') { continue }
    foreach ($a in @($r.aliases)) { $an = [string]$a; if ($an -and -not $m.ContainsKey($an)) { $m[$an] = $n } }
  }
  return $m
}
function Resolve-ItemName { param([string]$Name, $ItemNames, $AliasMap)
  # A SPEC MAY COST BY AN ALIAS, AND THAT IS NOT A BROKEN REFERENCE. An alias is an adjudicated identity
  # (Brad, 2026-08-16 ruling 9 puts Andouille and generic smoked sausage on the PORK row, never on Smoked
  # Turkey Sausage), and every other reader resolves them - cost-recipes.ps1, build-v2-spec,
  # audit-store-integrity, audit-vocab-integrity. This check was the last one that did not, so it called
  # 12 correctly-costed spec lines across 9 names broken references. Row name wins over alias, so a future
  # row named after an existing alias cannot hijack the specs already costing by that name.
  if ($ItemNames.ContainsKey($Name)) { return $Name }
  if ($AliasMap.ContainsKey($Name))  { return $AliasMap[$Name] }
  return $null
}
function Get-OrphanMacroClass { param([string]$Name, $ItemNames, [int]$SpecUseCount)
  # A MACRO ROW WITH NO PRICE ROW IS TWO DIFFERENT FACTS, AND ONLY ONE OF THEM IS A DEFECT (Brad, 2026-08-28).
  #
  # Until today this was one class standing at 104 against a baseline of 1 recorded on 2026-08-07, so the
  # script exited 1 every single day and nobody could tell a new defect from the standing noise - a
  # duplicate 'Fresh Thyme' key (UNIQUE-ITEM, a STRUCTURAL class) sat unread underneath it. The 104 were
  # read one by one before this split; the trend was reconstructed by recomputing the count at every commit
  # since the baseline. What it showed:
  #
  #   * db\ingredients.json has LOST NOTHING. It grew 277 -> 334 rows over the same three weeks. Exactly
  #     three orphan names ever had a price row, and each was removed by a commit that defends it:
  #     Red Wine (4056603f, deleted as an orphan), Green Bell Pepper (194f34f9, deduped into the existing
  #     'Green Bell Peppers' row on the same bid) and Boneless Pork Chops (2d1b9ea7, withdrawn because the
  #     registrar had ruled against bridging it to pork-chops - "Member's Mark BONE-IN Pork Chops").
  #   * The growth is the recipe-hunter map lane: 54 of the unconsumed rows carry an `added_by` naming a
  #     hunt from the last three days, and the count SAWTOOTHS - each hunt adds rows (+21, +17, +13) and the
  #     registrar commit that follows converts some to price rows (-5, -6, -7). ORPHAN-MACRO was never
  #     measuring a defect; it was measuring the map-lane -> registrar backlog. A hard count ratchet is the
  #     wrong instrument for a number that is SUPPOSED to rise mid-hunt, so this half never fails. It is
  #     still printed, because a backlog nobody can see is a backlog nobody drains.
  #
  # The defect is the other half: a macro row a SPEC ACTUALLY CONSUMES, whose food is not the food that
  # spec is priced against. That is a recipe booking one food's numbers and sending the reader to buy
  # another, and it is hard from the first one.
  #
  # NO ALIAS RESOLUTION HERE, DELIBERATELY - this signature does not even take the alias map, so a future
  # edit cannot quietly add one. db\build_db.py's ORPHAN-MACRO skip explains why on the storage side
  # (item_macro is keyed by item under INSERT OR REPLACE, so Andouille's label would land on top of the
  # Pork Smoked Sausage row - Brad's 2026-08-16 ruling 9). The audit side has its own reason: resolving
  # would SILENCE the finding. There are ten alias-named macro rows, not the three that comment names, and
  # not one of them states the same numbers as the row it resolves to (Pepperoni is Hormel PORK at
  # 500 cal/100 g and resolves to Great Value TURKEY Pepperoni at 250; Tandoori Masala is a real spice row
  # resolving to a Garam Masala row of zeroes). Nine are live in specs. FK-SPEC-ITEM resolves aliases
  # because it asks "does this name reach a price?" - aliases answer that. This check asks "whose numbers
  # are these?" - aliases do not.
  if ($ItemNames.ContainsKey($Name)) { return $null }        # it has its own price row; not an orphan
  if ($SpecUseCount -gt 0) { return 'MACRO-IDENTITY' }
  return 'ORPHAN-MACRO'
}
# Classes that are REPORTED but never hard. Everything else ratchets against the baseline, so a class
# absent from the baseline is hard from its first hit - that is the structural enforcement, and this list
# is the only exemption from it. Adding a name here is a decision someone defends in a diff.
$script:BACKLOG_CLASSES = @('ORPHAN-MACRO')
function Test-PairedCost { param([int]$MacroOnly, [int]$CostOnly)
  # a legitimate display override renames one item: the two "only" sets stay balanced. An unbalanced split
  # means a line exists on one side and nowhere on the other.
  return ($MacroOnly -eq $CostOnly)
}

if ($SelfTest) {
  $f = 0
  function T($m, $c, $g) { if ($c) { Write-Output ("ok    " + $m) } else { Write-Output ("FAIL  " + $m + "   got: " + $g); $script:f++ } }
  $keys = @('rice', 'turkey-bacon', 'bacon')
  T 'MUST FIRE  a bid naming no commodity is a broken foreign key' (-not (Test-ForeignKey 'nonexistent' $keys)) 'accepted'
  T 'CLEAN TWIN a bid naming a real commodity passes'              (Test-ForeignKey 'turkey-bacon' $keys) 'rejected'
  T 'CLEAN TWIN an ABSENT nullable fk is not a violation'          (Test-ForeignKey '' $keys) 'rejected a null'
  # the founding density disagreement, frozen: 185 g/cup vs 200
  T 'MUST FIRE  185 g/cup against 200 is a value disagreement'     (-not (Test-DensityAgreement 185 200)) 'tolerated'
  T 'CLEAN TWIN 203 vs 200 is inside rounding'                     (Test-DensityAgreement 203 200) 'flagged rounding'
  # THE serving_qty NORMALISATION, frozen. Rice is 180 g/cup in densities and "45 g per 0.25 cup" in the
  # food DB - the SAME number. Comparing serving_grams raw called that a 4x disagreement (36 false findings
  # on this script's second run, Rice among them). The fixture pins the division, not just the tolerance.
  T 'CLEAN TWIN Rice 180 g/cup vs 45 g per 0.25 cup is EXACT agreement' (Test-DensityAgreement 180 (45 / 0.25)) 'reported a false disagreement'
  T 'MUST FIRE  a real disagreement still fires after normalising'  (-not (Test-DensityAgreement 113 (28 / 1.0))) 'missed a real one'
  # the founding dropped-cost-line, frozen: 1 macro-only name, 0 cost-only
  T 'MUST FIRE  a one-sided macro/cost split (Garlic Powder)'      (-not (Test-PairedCost 1 0)) 'tolerated'
  T 'CLEAN TWIN a paired rename stays legal'                       (Test-PairedCost 1 1) 'flagged a rename'
  # THE ALIAS RESOLUTION, frozen against the row that motivated it. baked-cauliflower-mac-smoked-sausage
  # costs "Smoked Sausage"; that string is an alias on the PORK row, not a row of its own, and it must
  # resolve there - to kielbasa, never to Smoked Turkey Sausage (Brad, 2026-08-16 ruling 9).
  $fx = @(
    [pscustomobject]@{ item = 'Pork Smoked Sausage';   bid = 'kielbasa';              aliases = @('Smoked Sausage', 'Andouille Smoked Sausage') },
    [pscustomobject]@{ item = 'Smoked Turkey Sausage'; bid = 'turkey-sausage' },
    [pscustomobject]@{ item = 'Salt';                  bid = 'salt' },
    [pscustomobject]@{ item = '_r300_note';            aliases = @('Smoked Sausage') }
  )
  $fxNames = @{}; foreach ($r in $fx) { if ([string]$r.item -notlike '_*') { $fxNames[[string]$r.item] = $r } }
  $fxAlias = Get-AliasMap $fx
  T 'CLEAN TWIN a spec costing by an ALIAS resolves to its price row' ((Resolve-ItemName 'Smoked Sausage' $fxNames $fxAlias) -eq 'Pork Smoked Sausage') ((Resolve-ItemName 'Smoked Sausage' $fxNames $fxAlias))
  T 'RULING 9   the smoked-sausage aliases land on PORK, not turkey'  (((Resolve-ItemName 'Andouille Smoked Sausage' $fxNames $fxAlias) -eq 'Pork Smoked Sausage') -and ($fxAlias['Smoked Sausage'] -ne 'Smoked Turkey Sausage')) ((Resolve-ItemName 'Andouille Smoked Sausage' $fxNames $fxAlias))
  T 'CLEAN TWIN a plain row name still resolves to itself'            ((Resolve-ItemName 'Salt' $fxNames $fxAlias) -eq 'Salt') ((Resolve-ItemName 'Salt' $fxNames $fxAlias))
  T 'MUST FIRE  a name that is neither row nor alias is still broken' ($null -eq (Resolve-ItemName 'Unicorn Loin' $fxNames $fxAlias)) 'resolved a name that does not exist'
  T 'a comment row owns no aliases'                                   ($fxAlias.Count -eq 2) ("alias count $($fxAlias.Count)")
  # a row name must beat an alias, or a new row shadows the specs already costing by that name
  $fx2 = @([pscustomobject]@{ item = 'Broccoli'; bid = 'broccoli' }, [pscustomobject]@{ item = 'Broccoli Florets'; bid = 'broccoli-florets'; aliases = @('Broccoli') })
  $fx2Names = @{}; foreach ($r in $fx2) { $fx2Names[[string]$r.item] = $r }
  T 'a ROW NAME wins over another row claiming it as an alias'        ((Resolve-ItemName 'Broccoli' $fx2Names (Get-AliasMap $fx2)) -eq 'Broccoli') ((Resolve-ItemName 'Broccoli' $fx2Names (Get-AliasMap $fx2)))
  # THE ORPHAN-MACRO SPLIT, frozen against the rows that motivated it (Brad, 2026-08-28). 'Pepperoni' is a
  # macro row of Hormel PORK pepperoni with no price row of its own; keto-crustless-pizza-casserole books
  # its grams AND costs it against turkey-pepperoni. That is the hard half. 'Quinoa' is the other half: a
  # map-lane row for a food no spec has used yet, which costs nobody anything today.
  $omNames = @{}; $omNames['Turkey Pepperoni'] = 1; $omNames['Light Sour Cream'] = 1
  T 'MUST FIRE  a macro row a SPEC CONSUMES with no price row is an identity defect' ((Get-OrphanMacroClass 'Pepperoni' $omNames 1) -eq 'MACRO-IDENTITY') ((Get-OrphanMacroClass 'Pepperoni' $omNames 1))
  T 'BACKLOG    an unconsumed orphan is backlog, not a defect'        ((Get-OrphanMacroClass 'Quinoa' $omNames 0) -eq 'ORPHAN-MACRO') ((Get-OrphanMacroClass 'Quinoa' $omNames 0))
  T 'CLEAN TWIN a macro row WITH its own price row is neither'        ($null -eq (Get-OrphanMacroClass 'Turkey Pepperoni' $omNames 3)) ((Get-OrphanMacroClass 'Turkey Pepperoni' $omNames 3))
  # the whole point of the split: the backlog half must never page, the defect half must page immediately
  T 'the backlog half is exempt from the ratchet'                     ($script:BACKLOG_CLASSES -contains 'ORPHAN-MACRO') 'ORPHAN-MACRO would page daily again'
  T 'the identity half is NOT exempt - it is hard from the first one' ($script:BACKLOG_CLASSES -notcontains 'MACRO-IDENTITY') 'MACRO-IDENTITY was exempted'
  # ALIAS-BLIND ON PURPOSE. 'Sour Cream' IS an adjudicated alias of Light Sour Cream, and resolving it here
  # would silence a live finding: the food DB's Sour Cream is full-fat at 198 cal/100 g, Light Sour Cream
  # is 140, and four specs book the first while buying the second. Resolve-ItemName must not reach this
  # check - the fixture passes an alias map to neither call, and the signature refuses to take one.
  T 'RULING     an ALIAS-named consumed macro row still fires (no rescue)' ((Get-OrphanMacroClass 'Sour Cream' $omNames 4) -eq 'MACRO-IDENTITY') ((Get-OrphanMacroClass 'Sour Cream' $omNames 4))
  T 'Get-OrphanMacroClass cannot be handed an alias map at all'       (@((Get-Command Get-OrphanMacroClass).Parameters.Keys) -notcontains 'AliasMap') 'an alias map parameter appeared'
  if ($f -eq 0) { Write-Output 'SELF-TEST PASS'; exit 0 } else { Write-Output "SELF-TEST FAIL: $f case(s)"; exit 1 }
}

# ---- load the eight stores -------------------------------------------------------------------------------
# Read-JsonArrayFile, NOT @(... | ConvertFrom-Json). In PS 5.1 the latter yields ONE element (the whole
# array) for a top-level JSON array, so every FK set collapses to a single stringified blob and every
# lookup "fails" - this script's first run reported 15,262 violations against a scope of "1 commodities,
# 1 items" for exactly that reason. The estate keeps this helper because the trap is unavoidable otherwise.
. (Join-Path $mpRoot 'lib\json-db-io.ps1')
$commodities = @(Read-JsonArrayFile -Path (Join-Path $gRoot 'commodities.json'))
# THE FK TARGET IS THE PRICEABLE NAMESPACE, WHICH IS WIDER THAN commodities.json. A bid resolves against
# the FEED (smp-feed.json's ingredient keys, 574) - commodities.json (505) is the board's commodity roster,
# and real bids like 'pork-loin', '93-7-ground-beef' and 'penne-pasta' are priced in the feed without
# being roster commodities. Modelling the FK against the roster alone reported 984 false violations on this
# script's second run. The union is what "does this bid resolve to something priceable" actually means.
$comIds = @($commodities | ForEach-Object { [string]$_.id })
$feedPath = Join-Path $gRoot 'out\smp-feed.json'
if (Test-Path $feedPath) {
  $feed = Get-Content $feedPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $comIds = @($comIds + @($feed.ingredients.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object -Unique)
} else {
  Write-Output '  WARNING: no out\smp-feed.json - FK checks fall back to the roster alone and will over-report'
}
$ing = @(Read-JsonArrayFile -Path (Join-Path $mpRoot 'db\ingredients.json'))
$fdbRaw = Get-Content (Join-Path $mpRoot 'food-macros-db.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$dens = (Get-Content (Join-Path $mpRoot 'db\densities.json') -Raw -Encoding UTF8 | ConvertFrom-Json).items

$violations = New-Object System.Collections.Generic.List[object]
function V($cls, $detail) { $violations.Add([pscustomobject]@{ cls = $cls; detail = $detail }) }

# ---- item table: PK uniqueness, FK to commodity, NOT NULL gpu -------------------------------------------
$itemNames = @{}
foreach ($r in $ing) {
  $n = [string]$r.item
  if (-not $n -or $n -like '_*') { continue }        # '_r300_note' and friends are comments, not rows
  if ($itemNames.ContainsKey($n)) { V 'UNIQUE-ITEM' "db\ingredients.json has '$n' more than once" }
  $itemNames[$n] = $r
  if (-not (Test-ForeignKey ([string]$r.bid) $comIds)) { V 'FK-BID' "item '$n' bid='$($r.bid)' names no commodity" }
  if ($r.PSObject.Properties['bid'] -and $r.bid -and -not $r.gpu) { V 'NOT-NULL-GPU' "priced item '$n' has no gpu" }
}

$aliasMap = Get-AliasMap $ing

# ---- item_macro: every macro row must belong to a known item --------------------------------------------
# The orphans are only COLLECTED here. Which half of the split each one lands in depends on whether a spec
# consumes it, and the specs are not read until below - see Get-OrphanMacroClass for why the two halves are
# not the same finding.
$macroOf = @{}
$orphanMacro = @{}
foreach ($grp in $fdbRaw.PSObject.Properties) {
  if ($grp.Value -isnot [array]) { continue }
  foreach ($m in $grp.Value) {
    $n = [string]$m.item
    if (-not $n) { continue }
    if ($macroOf.ContainsKey($n)) { V 'UNIQUE-ITEM' "food-macros-db has '$n' more than once (would break UNIQUE(item))" ; continue }
    $macroOf[$n] = $m
    if (-not $itemNames.ContainsKey($n)) { $orphanMacro[$n] = $true }
  }
}
$macroUse = @{}   # macro-row name -> the slugs whose ingredients_grams book it

# ---- item_density: rows belong to known items, and must agree with the food DB's own base ---------------
foreach ($p in $dens.PSObject.Properties) {
  $n = [string]$p.Name
  if ($n -like '_*') { continue }   # '_r300_additions_note' is a comment key, not a data row (same rule as items)
  if (-not $itemNames.ContainsKey($n)) { V 'ORPHAN-DENS' "density row '$n' has no db\ingredients.json row" }
  $m = $macroOf[$n]
  if (-not $m) { continue }
  $su = [string]$m.serving_unit; $sg = [double]$m.serving_grams
  # NORMALISE BY serving_qty FIRST. The food DB states "45 g per 0.25 cup", not "45 g per cup" - comparing
  # serving_grams directly against a per-ONE-unit density called Rice a 4x disagreement when the two files
  # agree exactly (180 g/cup both sides). That error produced 36 false AGREE-DENSITY findings, including the
  # Rice row this check was written for.
  $sq = 1.0; if ($m.PSObject.Properties['serving_qty'] -and [double]$m.serving_qty -gt 0) { $sq = [double]$m.serving_qty }
  $perUnit = $sg / $sq
  if (-not $su -or $perUnit -le 0) { continue }
  foreach ($u in $p.Value.PSObject.Properties) {
    if ([string]$u.Name -ne $su) { continue }
    if ($script:DENSITY_BASIS_EXCEPTIONS -contains $n) { continue }   # settled: drained yield vs as-packed label
    if (-not (Test-DensityAgreement ([double]$u.Value) $perUnit)) {
      V 'AGREE-DENSITY' ("'{0}' one {1} is {2} g in densities.json but {3} g in the food DB ({4} g / {5} {1})" -f $n, $u.Name, $u.Value, [math]::Round($perUnit,1), $sg, $sq)
    }
  }
}

# ---- spec + spec_ingredient ------------------------------------------------------------------------------
foreach ($sf in (Get-ChildItem (Join-Path $mpRoot 'db\recipes\*.json'))) {
  $s = Get-Content $sf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $slug = $sf.BaseName
  $seen = @{}
  foreach ($si in @($s.scaler.ing)) {
    $n = [string]$(if ($si.canon) { $si.canon } else { $si.item })
    if (-not $n) { continue }
    if ($seen.ContainsKey($n)) { V 'UNIQUE-ITEM' "$slug lists '$n' twice in scaler.ing (breaks UNIQUE(slug,item))" }
    $seen[$n] = 1
    if ($null -eq (Resolve-ItemName $n $itemNames $aliasMap)) { V 'FK-SPEC-ITEM' "$slug costs '$n', which is neither a db\ingredients.json row nor an adjudicated alias of one" }
    if (-not (Test-ForeignKey ([string]$si.bid) $comIds)) { V 'FK-SPEC-BID' "$slug '$n' bid='$($si.bid)' names no commodity" }
  }
  # PAIRED-COST: the macro basis and the cost basis must describe the same set (modulo paired renames)
  $macroNames  = @(@($s.ingredients_grams | ForEach-Object { [string]$_.item }) | Where-Object { $_ })
  foreach ($mn in $macroNames) {
    if (-not $macroUse.ContainsKey($mn)) { $macroUse[$mn] = @() }
    if ($macroUse[$mn] -notcontains $slug) { $macroUse[$mn] += $slug }
  }
  $scalerNames = @(@($s.scaler.ing | ForEach-Object { $k = $_.item; if ($_.canon) { $k = $_.canon }; [string]$k }) | Where-Object { $_ })
  $mOnly = @($macroNames  | Where-Object { $scalerNames -notcontains $_ })
  $cOnly = @($scalerNames | Where-Object { $macroNames  -notcontains $_ })
  if (($mOnly.Count -or $cOnly.Count) -and -not (Test-PairedCost $mOnly.Count $cOnly.Count)) {
    V 'PAIRED-COST' ("{0}: macro-only [{1}] vs cost-only [{2}] - one side has a line the other lacks" -f $slug, ($mOnly -join '|'), ($cOnly -join '|'))
  }
}

# ---- the orphan-macro split (needs both the macro rows and the specs) ------------------------------------
foreach ($n in ($orphanMacro.Keys | Sort-Object)) {
  # ContainsKey FIRST. @($hashtable['missing']) is @($null), whose .Count is 1 in PS 5.1, not 0 - written
  # the short way this put all 104 orphans in the defect half, each reading "1 spec(s) ... []".
  $slugs = @(); if ($macroUse.ContainsKey($n)) { $slugs = @($macroUse[$n]) }
  switch (Get-OrphanMacroClass $n $itemNames $slugs.Count) {
    'MACRO-IDENTITY' {
      # name the row it is PRICED as, because that is the question the reader has to answer: are these
      # numbers this food's, or that one's? Reporting only "no price row" hid that for three weeks.
      $as = if ($aliasMap.ContainsKey($n)) { "priced as '$($aliasMap[$n])'" } else { 'nothing on the price side owns this name' }
      $shown = if ($slugs.Count -gt 3) { (($slugs | Select-Object -First 3) -join ', ') + ", +$($slugs.Count - 3) more" } else { $slugs -join ', ' }
      V 'MACRO-IDENTITY' "$($slugs.Count) spec(s) book macros from '$n', which has no db\ingredients.json row - $as [$shown]"
    }
    'ORPHAN-MACRO' {
      $by = if ($macroOf[$n].PSObject.Properties['added_by']) { " (added by $($macroOf[$n].added_by))" } else { '' }
      V 'ORPHAN-MACRO' "macro row '$n' has no db\ingredients.json row and no spec books it$by"
    }
  }
}

# ---- tiering ---------------------------------------------------------------------------------------------
# STRUCTURAL classes are what a relational engine enforces at write time - a broken reference, a duplicate
# key, a half-present row. Those are ALWAYS hard: today they stand at zero, and any new one means a write
# landed that a real database would have rejected.
# VALUE classes (two stores holding different numbers for the same fact) cannot be settled by arithmetic -
# the estate's own rule is that deciding a gram figure needs the SOURCE, not a sweep. They are ratcheted
# against a recorded baseline so the known dozen stay visible in the report without paging, while a NEW one
# fires. That is the contested-flag lesson: never bless a whole pending set, but never cry daily either.
# EVERY class ratchets, and that IS the structural enforcement: the structural classes (FK-*, UNIQUE-*,
# PAIRED-COST, NOT-NULL-GPU) all stand at ZERO today, so their baseline is zero and any single new one is
# hard immediately - exactly what a write-time constraint would do. Marking them "always hard" instead
# would page every day for the handful of known, already-adjudicated value rows and teach everyone to
# scroll past the one report that can see a broken reference.
$baselinePath = Join-Path $mpRoot 'db\schema-constraint-baseline.json'
$base = @{}
if (Test-Path $baselinePath) {
  $b = Get-Content $baselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($p in $b.PSObject.Properties) { $base[$p.Name] = [int]$p.Value }
}
if ($Baseline) {
  $out = [ordered]@{}
  # a backlog class carries no baseline line - it cannot fail, so a number here would be a decision nobody
  # is actually making. The stale ORPHAN-MACRO=1 line from 2026-08-07 drops out on the next -Baseline run.
  foreach ($g in ($violations | Group-Object cls | Sort-Object Name)) {
    if ($script:BACKLOG_CLASSES -contains $g.Name) { continue }
    $out[$g.Name] = $g.Count
  }
  ($out | ConvertTo-Json -Depth 3) | Out-File $baselinePath -Encoding utf8
  Write-Output ("schema-constraint baseline recorded: " + (($out.Keys | ForEach-Object { "$_=$($out[$_])" }) -join ', '))
  exit 0
}
$hard = @()
foreach ($g in ($violations | Group-Object cls)) {
  if ($script:BACKLOG_CLASSES -contains $g.Name) { continue }            # reported, never hard - see BACKLOG_CLASSES
  $was = if ($base.ContainsKey($g.Name)) { $base[$g.Name] } else { 0 }   # unrecorded class => 0 => any hit is hard
  if ($g.Count -gt $was) { $hard += ($g.Group | Select-Object -First ($g.Count - $was)) }
}

# ---- report ----------------------------------------------------------------------------------------------
$byCls = $violations | Group-Object cls | Sort-Object Count -Descending
Write-Output ("schema constraints: {0} row(s) would REFUSE to insert into the normalized schema ({1} hard)" -f $violations.Count, $hard.Count)
Write-Output ("  scope: {0} commodities, {1} items, {2} macro rows, {3} density rows, {4} specs" -f $comIds.Count, $itemNames.Count, $macroOf.Count, @($dens.PSObject.Properties).Count, @(Get-ChildItem (Join-Path $mpRoot 'db\recipes\*.json')).Count)
Write-Output ''
foreach ($g in $byCls) {
  $tag = if ($script:BACKLOG_CLASSES -contains $g.Name) { '   backlog - reported, never fails' } else { '' }
  Write-Output ("  {0,-14} {1,5}{2}" -f $g.Name, $g.Count, $tag)
}
Write-Output ''
$cap = if ($ShowAll) { 10000 } else { 6 }
foreach ($g in $byCls) {
  Write-Output ("--- {0}" -f $g.Name)
  $g.Group | Select-Object -First $cap | ForEach-Object { Write-Output ("    " + $_.detail) }
  if (-not $ShowAll -and $g.Count -gt $cap) { Write-Output ("    ... {0} more (-ShowAll)" -f ($g.Count - $cap)) }
}
foreach ($h in ($hard | Select-Object -First 10)) { Write-Output ("  ! " + $h.detail) }
if (-not (Test-Path $baselinePath)) { Write-Output '  (no baseline recorded yet - run -Baseline once to arm the value-class ratchet)' }
Write-GuardComplete -Name 'schema-constraints' -Summary ("violations={0} hard={1}" -f $violations.Count, $hard.Count)
exit $(if ($hard.Count) { 1 } else { 0 })
