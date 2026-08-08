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
    item_macro(item -> item.name, serving_grams,             <- food-macros-db.json
               calories, protein_g, carbs_g, fat_g)          UNIQUE(item)
    item_density(item -> item.name, unit, grams)             <- db\densities.json
                                                             UNIQUE(item, unit)
    spec(slug PK, cal, protein, cost_ps)                     <- db\recipes\*.json
    spec_ingredient(slug -> spec.slug, item -> item.name,    <- spec.scaler.ing + ingredients_grams
                    grams, bid -> commodity.id)              UNIQUE(slug, item)

  CONSTRAINT CLASSES CHECKED (each names the real defect that motivated it):
    FK-BID        an item's bid must name a real commodity          (Turkey Bacon -> PORK)
    FK-SPEC-ITEM  a spec ingredient must name a real item row       (the 6 macro-only items)
    FK-SPEC-BID   a spec ingredient's bid must name a real commodity
    ORPHAN-MACRO  a macro row must belong to a known item
    ORPHAN-DENS   a density row must belong to a known item
    NOT-NULL-GPU  a priced item needs a grams-per-unit
    UNIQUE-ITEM   one row per item name, per store
    AGREE-DENSITY densities.json and the food DB must not state different grams for the same unit (Rice)
    PAIRED-COST   every macro-counted ingredient must also be costed, and vice versa (Garlic Powder)

  Usage: .\audit-schema-constraints.ps1 [-ShowAll] | -SelfTest
#>
param([switch]$ShowAll, [switch]$SelfTest, [switch]$Baseline, [string]$Root = "")
$ErrorActionPreference = 'Stop'
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

# ---- item_macro: every macro row must belong to a known item --------------------------------------------
$macroOf = @{}
foreach ($grp in $fdbRaw.PSObject.Properties) {
  if ($grp.Value -isnot [array]) { continue }
  foreach ($m in $grp.Value) {
    $n = [string]$m.item
    if (-not $n) { continue }
    if ($macroOf.ContainsKey($n)) { V 'UNIQUE-ITEM' "food-macros-db has '$n' more than once (would break UNIQUE(item))" ; continue }
    $macroOf[$n] = $m
    if (-not $itemNames.ContainsKey($n)) { V 'ORPHAN-MACRO' "macro row '$n' has no db\ingredients.json row (cannot be costed)" }
  }
}

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
    if (-not $itemNames.ContainsKey($n)) { V 'FK-SPEC-ITEM' "$slug costs '$n', which has no db\ingredients.json row" }
    if (-not (Test-ForeignKey ([string]$si.bid) $comIds)) { V 'FK-SPEC-BID' "$slug '$n' bid='$($si.bid)' names no commodity" }
  }
  # PAIRED-COST: the macro basis and the cost basis must describe the same set (modulo paired renames)
  $macroNames  = @(@($s.ingredients_grams | ForEach-Object { [string]$_.item }) | Where-Object { $_ })
  $scalerNames = @(@($s.scaler.ing | ForEach-Object { $k = $_.item; if ($_.canon) { $k = $_.canon }; [string]$k }) | Where-Object { $_ })
  $mOnly = @($macroNames  | Where-Object { $scalerNames -notcontains $_ })
  $cOnly = @($scalerNames | Where-Object { $macroNames  -notcontains $_ })
  if (($mOnly.Count -or $cOnly.Count) -and -not (Test-PairedCost $mOnly.Count $cOnly.Count)) {
    V 'PAIRED-COST' ("{0}: macro-only [{1}] vs cost-only [{2}] - one side has a line the other lacks" -f $slug, ($mOnly -join '|'), ($cOnly -join '|'))
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
  foreach ($g in ($violations | Group-Object cls | Sort-Object Name)) { $out[$g.Name] = $g.Count }
  ($out | ConvertTo-Json -Depth 3) | Out-File $baselinePath -Encoding utf8
  Write-Output ("schema-constraint baseline recorded: " + (($out.Keys | ForEach-Object { "$_=$($out[$_])" }) -join ', '))
  exit 0
}
$hard = @()
foreach ($g in ($violations | Group-Object cls)) {
  $was = if ($base.ContainsKey($g.Name)) { $base[$g.Name] } else { 0 }   # unrecorded class => 0 => any hit is hard
  if ($g.Count -gt $was) { $hard += ($g.Group | Select-Object -First ($g.Count - $was)) }
}

# ---- report ----------------------------------------------------------------------------------------------
$byCls = $violations | Group-Object cls | Sort-Object Count -Descending
Write-Output ("schema constraints: {0} row(s) would REFUSE to insert into the normalized schema ({1} hard)" -f $violations.Count, $hard.Count)
Write-Output ("  scope: {0} commodities, {1} items, {2} macro rows, {3} density rows, {4} specs" -f $comIds.Count, $itemNames.Count, $macroOf.Count, @($dens.PSObject.Properties).Count, @(Get-ChildItem (Join-Path $mpRoot 'db\recipes\*.json')).Count)
Write-Output ''
foreach ($g in $byCls) { Write-Output ("  {0,-14} {1,5}" -f $g.Name, $g.Count) }
Write-Output ''
$cap = if ($ShowAll) { 10000 } else { 6 }
foreach ($g in $byCls) {
  Write-Output ("--- {0}" -f $g.Name)
  $g.Group | Select-Object -First $cap | ForEach-Object { Write-Output ("    " + $_.detail) }
  if (-not $ShowAll -and $g.Count -gt $cap) { Write-Output ("    ... {0} more (-ShowAll)" -f ($g.Count - $cap)) }
}
foreach ($h in ($hard | Select-Object -First 10)) { Write-Output ("  ! " + $h.detail) }
if (-not (Test-Path $baselinePath)) { Write-Output '  (no baseline recorded yet - run -Baseline once to arm the value-class ratchet)' }
exit $(if ($hard.Count) { 1 } else { 0 })
