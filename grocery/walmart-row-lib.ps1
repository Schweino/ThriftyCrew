# walmart-row-lib.ps1 - Walmart's capture-row builder, as a PROVIDED interface.
# ---------------------------------------------------------------------------------------------------
# WHY THIS FILE EXISTS (2026-09-11, the follow-on to backlog I82). Build-Row turns one raw Walmart product
# (name, linePrice, unitPrice, item id) into an engine-shaped board row. It had two callers and only one of
# them could reach it: build-walmart-deals.ps1 defined it, and import-walmart-batch.ps1 read the builder's
# TEXT with Get-Content, cut Build-Row, its six helpers and $script:UnitFamily out of it by regex off a
# hand-maintained name list, and ran them through Invoke-Expression. That was the last live production
# lift in the estate: `ops\count-source-lifters.ps1 -Script build-walmart-deals.ps1` named it as the one
# file executing lifted text on 2026-09-11.
#
# THE REASON NOBODY JUST DOT-SOURCED IT is the one pricing-math-lib.ps1 records for compare-deals.ps1: the
# builder does work on load. It reads -In, writes out\regular, mutates the rollback ledger and advances the
# capture cursor, so a dot-source would have run a build. The functions never needed any of that. They were
# moved here as one contiguous block, cut by line range out of the committed builder, and no line of code
# changed. One COMMENT did: the one inside Get-SameFamilyNameQty that explained its locals by the lift this
# file retires. design\PLAN-walmart-row-lib-2026-09-11.md holds the before/after proof, including
# byte-identical walmart-regular output built from the same real captures by both revisions.
#
# WHAT A CALLER MUST PROVIDE, because a library that reads its caller's state has to say so:
#   - Get-UnitPrice. Dot-source pricing-math-lib.ps1 before the first Build-Row call. Commands resolve at
#     CALL time, so a caller that forgets it loads cleanly and fails on its first row with "not recognized".
#   - $script:CaptureDate, the capture date Build-Row stamps into every row's as_of. build-walmart-deals.ps1
#     sets it from -Date or the input filename. import-walmart-batch.ps1 does NOT set it: its rows come back
#     with as_of $null and its import loop stamps the run date itself.
# WHAT IT PROVIDES: Resolve-Unit, Get-NameQtyCandidates, Get-NamePackMultipliers, Get-SameFamilyNameQty,
# Get-NamePack, Format-Qty, Build-Row, and the $script:UnitFamily constant the helpers read.
#
# THE RULES THAT KEEP IT DOT-SOURCEABLE:
#   - NO WORK ON LOAD. It defines seven functions and assigns one constant, and must keep it that way. A
#     line here that does work at import re-creates the exact obstacle that produced the lift.
#   - NO param() BLOCK. Dot-sourcing runs a script's param block in the CALLER's scope, which is how a
#     library's -SelfTest once reset build-walmart-deals' own $SelfTest to $false (see capture-lib.ps1).
#   - NO SELF-TEST HERE. The cases stay with their callers: build-walmart-deals.ps1 -SelfTest owns Build-Row's
#     frozen rows, import-walmart-batch.ps1 -SelfTest the batch ones, and guards.ps1 runs both as hard kids.
#   - PURE ASCII, LF, no BOM, like the builder it came from. PS 5.1 decodes a BOM-less script as the ANSI
#     codepage, so a non-ASCII literal needs a code-point escape ([char]0x00A2), never the glyph.
#
# NOT FOR build-sams-deals.ps1 AS IT STANDS. Sam's carries its own copies. Five of the eight items here are
# code-identical to them, but Build-Row is not, and on purpose: the two stores refuse different things.
# Dot-sourcing this file there would load a Walmart Build-Row that the Sam's file then silently redefines.
# The ruling, and the shape that would let the shared half be shared, is in the plan named above.
# ---------------------------------------------------------------------------------------------------
# unit token as Sam's prints it -> (engine size token, engine category unit for the invariant check)
# Sam's abbreviates FLUID OUNCE as "foz" ("$0.16/foz"). Missing that silently drops every liquid in the
# catalog - ~190 rows in a full pull - so it is spelled out here rather than left to a generic oz match,
# which would price a fluid ounce as a WEIGHT ounce.
# Units we deliberately do NOT map: "sft"/"sq ft" (square foot - Reynolds foil, paper towels). There is no
# honest conversion from square feet to a roll, so those rows are rejected by name rather than guessed at.
#
# STILL THE RIGHT ANSWER - BUT NOT FOR THE REASON THIS COMMENT USED TO GIVE (measured 2026-09-05).
# It said "we track those commodities per EACH/roll". That is true of parchment-paper, plastic-wrap and
# paper-towels: all three are unit=each and all three are priced at 5 to 7 stores on the live board, so
# their sq-ft rows are a shape we do not need rather than a hole. It is NOT true of aluminum-foil, which
# is declared unit=sq_ft - the ONLY sq_ft commodity in the catalog of 592.
# AND ADDING THE UNIT HERE WOULD NOT PRICE IT. compare-deals' Convert-ToUnit has no sq_ft case either, so
# for a sq_ft commodity EVERY size token converts to $null and no cell can ever be computed. Measured:
# aluminum-foil is absent from comparison-2026-09-02 entirely, while 11 rows across the 8 newest
# out\regular captures match its include - it is not "nobody carries it", it is a commodity the engine
# cannot express. This function refusing "sq ft" is downstream of that, not the cause of it.
# SO THE GAP IS A DECISION ABOUT THAT COMMODITY'S UNIT, NOT A MISSING LINE IN THIS FUNCTION: either
# aluminum-foil becomes each/roll like its three siblings, or the engine grows a real square-foot
# vocabulary for one commodity. A commodity's unit is Brad's call, so neither was done here.
# It is not trivially each-able either: "Reynolds Wrap Aluminum Foil 200 sq. ft. Box" parses to size
# "200 ct", which under unit=each reads as 200 boxes rather than one.
function Resolve-Unit([string]$u) {
  switch -Regex (($u -replace '\.','').Trim().ToLower()) {
    '^(ea|each|ct|count)$'          { return @{ tok='ct';     unit='each'   } }
    '^(lb|lbs|pound|pounds)$'       { return @{ tok='lb';     unit='lb'     } }
    '^(fl\s*oz|floz|foz)$'          { return @{ tok='fl oz';  unit='floz'   } }
    '^(oz|ounce|ounces)$'           { return @{ tok='oz';     unit='oz'     } }
    '^(gal|gallon|gallons)$'        { return @{ tok='gal';    unit='gallon' } }
    '^(dozen|doz|dz)$'              { return @{ tok='dozen';  unit='dozen'  } }
  }
  return $null
}

# How many of $tok one of each name-unit is worth. A name states its size in whatever unit the package uses,
# which is often NOT the unit Sam's priced by: milk is "1 gal." but priced per fluid ounce. Without these
# conversions the name is ignored, the rounded lp/up quotient stands unchallenged, and at $0.03/foz (where
# cent-rounding is +/-16%) a gallon of milk derives as 124 fl oz and publishes at $3.84/gal instead of $3.72.
$script:UnitFamily = @{
  'fl oz' = @{ 'fl oz'=1; 'floz'=1; 'oz'=1; 'gal'=128; 'gallon'=128; 'qt'=32; 'quart'=32; 'pt'=16; 'pint'=16; 'l'=33.814; 'liter'=33.814; 'ml'=0.033814 }
  'oz'    = @{ 'oz'=1; 'ounce'=1; 'ounces'=1; 'lb'=16; 'lbs'=16; 'pound'=16; 'pounds'=16; 'g'=0.035274; 'gram'=0.035274; 'grams'=0.035274; 'kg'=35.274 }
  'lb'    = @{ 'lb'=1; 'lbs'=1; 'pound'=1; 'pounds'=1; 'oz'=0.0625; 'ounce'=0.0625; 'ounces'=0.0625; 'kg'=2.20462; 'g'=0.00220462 }
  'gal'   = @{ 'gal'=1; 'gallon'=1; 'gallons'=1; 'qt'=0.25; 'quart'=0.25; 'fl oz'=0.0078125; 'floz'=0.0078125 }
  'dozen' = @{ 'dozen'=1; 'doz'=1; 'dz'=1 }
}
# NOTE for 'fl oz': a name's bare "oz" on a liquid is a FLUID ounce (stores print "16 oz" on a bottle), which
# is why it maps 1:1 here; under 'oz' the same token is a weight ounce. The tok we were priced by decides.

# EVERY quantity the NAME could plausibly mean, expressed in the unit Sam's priced by. The caller picks the
# one that reproduces Walmart's own unit price - we do not guess here.
#
# WHY A LIST AND NOT ONE ANSWER: names put two counts in either order and mean different things by them.
#   "Pampers ... 13 pk., 728 ct."          -> 728 is the total (the LAST count)
#   "Q-tips Cotton Swabs, 1750 ct., 3 pk." -> 1750 is the total (the FIRST count)
# No fixed rule picks right in both, and picking wrong published $0.01/swab for a $0.0053 swab. So offer
# every reading - each count, and their product - and let Sam's arithmetic decide.
function Get-NameQtyCandidates([string]$name, [string]$tok) {
  $out = New-Object System.Collections.Generic.List[double]
  if (-not $name) { return $out }
  $n = $name.ToLower()
  $counts = @([regex]::Matches($n, '(\d+)\s*-?\s*(?:ct|count|pk|packs?)\b') | ForEach-Object { [double]$_.Groups[1].Value } | Where-Object { $_ -gt 0 })

  if ($tok -eq 'ct') {
    foreach ($c in $counts) { $out.Add($c) }
    if ($counts.Count -gt 1) { $p = 1.0; foreach ($c in $counts) { $p *= $c }; $out.Add($p) }   # 3 boxes x 1750
    return $out
  }

  $fam = $script:UnitFamily[$tok]
  if (-not $fam) { return $out }
  # (\d[\d.]*|\.\d+): leading-dot decimals (".98 oz", ".59 oz") - ported from build-sams-deals 2026-07-30.
  # A leading-digit-only pattern reads ".98" as "98" (100x); 6 live Walmart products carry the form today.
  foreach ($mm in [regex]::Matches($n, '(\d[\d.]*|\.\d+)\s*-?\s*(fl\.?\s*oz|floz|ounces?|oz|lbs?|pounds?|gallons?|gal|quarts?|qt|pints?|pt|liters?|l|ml|kg|grams?|g|dozen|doz|dz)\b')) {
    $qtxt = ($mm.Groups[1].Value).TrimEnd('.')
    if ($qtxt -notmatch '^(\d+(\.\d+)?|\.\d+)$') { continue }   # ".98" is a valid quantity too
    $nu = ($mm.Groups[2].Value -replace '\.','' -replace '\s+',' ')   # "fl. oz." -> "fl oz"
    if (-not $fam.ContainsKey($nu)) { continue }                       # a unit from another family - ignore
    $each = [double]$qtxt * [double]$fam[$nu]
    if ($each -le 0) { continue }
    $out.Add($each)                                                    # the package IS the total
    foreach ($c in $counts) { $out.Add($each * $c) }                   # ...or it is the per-item size of a multipack
  }
  return $out
}

# EVERY PACK MULTIPLE A NAME STATES, including 1 (the package IS the total).
#
# Get-NameQtyCandidates already multiplies a stated size by counts written as "N ct / N count / N pk /
# N pack", because those are the forms it needs to SNAP to Walmart's unit price. This function exists for
# the weaker question the refusal branch asks: is a disagreement between the printed quantity and lp/up
# EXPLAINED by a pack the name states, in any wording? A name that says "(Pack of 24) ... 16.9 fl oz" is
# describing 405.6 fl oz and is perfectly publishable on the derived quantity; a name that says
# "1.82 pounds" and nothing else, against a derived 10.891 lb, is not.
# 1 is always in the list so that a name quantity within the tolerance of lp/up counts as agreement -
# the strict test above wants the name to REPRODUCE Walmart's rounded unit price to the cent, which a
# correct name can miss on rounding alone.
function Get-NamePackMultipliers([string]$name) {
  $out = New-Object System.Collections.Generic.List[double]
  $out.Add(1.0)
  if (-not $name) { return $out }
  $n = $name.ToLower()
  foreach ($pat in @(
    '(\d+)\s*-?\s*(?:ct|count|pk|packs?)\b',   # "24 ct", "24-count", "12 pack"  (the existing forms)
    '\bpacks?\s+of\s+(\d+)\b',                 # "(Pack of 24)"
    '\bbox\s+of\s+(\d+)\b',
    '\bcase\s+of\s+(\d+)\b',
    '(\d+)\s*/\s*(?:carton|case|box)\b',       # "24/carton"
    '\(\s*(\d+)\s*x\s*[\d.]+',                 # "(2 x 16 oz)"
    '\b(\d+)\s*x\s*[\d.]+\s*(?:fl\.?\s*oz|floz|oz|lbs?|ml|g)\b'
  )) {
    foreach ($m in [regex]::Matches($n, $pat)) {
      $v = [double]$m.Groups[1].Value
      if ($v -gt 0 -and -not $out.Contains($v)) { $out.Add($v) }
    }
  }
  if ($n -match '\btwin\s+pack\b' -and -not $out.Contains(2.0)) { $out.Add(2.0) }
  # A name can state BOTH an inner count and an outer one ("3 boxes x 1750 ct"); their product is a real
  # multiple too, and Get-NameQtyCandidates already treats it as one for the snap.
  $counts = @($out | Where-Object { $_ -gt 1 })
  if ($counts.Count -gt 1) {
    $p = 1.0; foreach ($c in $counts) { $p *= $c }
    if (-not $out.Contains($p)) { $out.Add($p) }
  }
  return $out
}

# THE QUANTITIES A NAME STATES IN THE SAME PHYSICAL FAMILY AS THE PRICED UNIT.
#
# Get-NameQtyCandidates is deliberately generous: UnitFamily maps a bare "oz" into the FL OZ family because a
# bottle labelled "16 oz" holds sixteen FLUID ounces, and a generous candidate list is exactly right when the
# caller only accepts a reading that REPRODUCES Walmart's own unit price. It is wrong for the refusal test,
# which asks the opposite question - does the name CONTRADICT the unit price - because a weight on the label
# beside a volume on the shelf tag is two different measurements, not a contradiction. import-walmart-batch
# froze that ruling on 'Some Sauce, 32 oz Jar' at 10.0 cents per fl oz: cross-family, the name does not
# override, and Walmart's derived 64 fl oz publishes.
# So this returns only quantities whose unit sits in the same family the row was PRICED by. An empty result
# means the name says nothing about the priced dimension, and there is nothing to refuse.
function Get-SameFamilyNameQty([string]$name, [string]$tok) {
  # The unit lists and the pattern live INSIDE the function on purpose. They were put here while
  # import-walmart-batch.ps1 lifted this function as TEXT and took $script:UnitFamily separately, when any
  # other script-scope variable a lifted function read would have quietly arrived as $null and returned an
  # empty result rather than throwing. Both Walmart writers dot-source walmart-row-lib.ps1 now (2026-09-11),
  # which carries script-scope state, so that hazard is gone; the locals stay because they are still the
  # smaller interface. .NET caches compiled patterns, so the literal costs nothing per call.
  $VOL = @('fl oz','floz','gal','gallon','gallons','qt','quart','quarts','pt','pint','pints','l','liter','liters','ml')
  $WT  = @('oz','ounce','ounces','lb','lbs','pound','pounds','g','gram','grams','kg')
  $RX  = '(\d[\d.]*|\.\d+)\s*-?\s*(fl\.?\s*oz|floz|ounces?|oz|lbs?|pounds?|gallons?|gal|quarts?|qt|pints?|pt|liters?|l|ml|kg|grams?|g)\b'
  # Returns a plain ARRAY, and the CALLER wraps the result in @(). A List[double] returned from a
  # PowerShell function is unrolled by the pipeline: empty comes back as $null and one element comes back
  # as a bare double, so the caller's $strict.Count read whatever the unroll happened to produce rather
  # than the number of readings found. That cost a full board rebuild to find, because the refusal simply
  # never fired and the row published exactly as it had before. Returning `, $out` instead is the other
  # trap: @() around a comma-wrapped array yields a one-element array holding an array, and the ratio
  # arithmetic below then divides an Object[].
  $out = @()
  if (-not $name) { return $out }
  $want = ''
  if ($tok -eq 'fl oz' -or $tok -eq 'gal') { $want = 'vol' }
  elseif ($tok -eq 'oz' -or $tok -eq 'lb') { $want = 'wt' }
  if ($want -eq '') { return $out }        # ct and dozen have no weight/volume family to contradict
  $fam = $script:UnitFamily[$tok]
  if (-not $fam) { return $out }
  foreach ($mm in [regex]::Matches($name.ToLower(), $RX)) {
    $qtxt = ($mm.Groups[1].Value).TrimEnd('.')
    if ($qtxt -notmatch '^(\d+(\.\d+)?|\.\d+)$') { continue }
    $nu = ($mm.Groups[2].Value -replace '\.', '' -replace '\s+', ' ')
    $got = ''
    if ($VOL -contains $nu) { $got = 'vol' }
    elseif ($WT -contains $nu) { $got = 'wt' }
    if ($got -ne $want) { continue }
    if (-not $fam.ContainsKey($nu)) { continue }
    $each = [double]$qtxt * [double]$fam[$nu]
    if ($each -gt 0) { $out += $each }
  }
  return $out
}


# The PER-ITEM measure a name states IMMEDIATELY NEXT TO a count ("...3.2 oz., 32 ct." -> @{count=32;
# measure='3.2 oz'}). Returns $null when no count/measure pair sits together.
#
# WHY THIS EXISTS: a size of just "32 ct" carries no weight, so for a commodity measured in OZ the engine
# cannot convert it, falls back to scanning the NAME, and finds the per-POUCH "3.2 oz" - pricing a $15.98 box
# of 32 pouches at $4.99/oz instead of $0.156/oz, 32x high. Emitting the full multipack descriptor
# "32 ct 3.2 oz" satisfies BOTH readings: Get-PackCount still sees 32 for an each-commodity, and the multipack
# branch of Get-SizeAmount computes 32 x 3.2 = 102.4 oz for a weight-commodity.
#
# NOT EVERY MEASURE IN A NAME IS THE CONTENTS, and two rules keep this honest:
#  1. ADJACENCY. Sam's writes real contents beside the count ("3.2 oz., 32 ct."); an unrelated descriptor sits
#     away from it ("...Power Flex 13-Gallon Tall Kitchen Trash Bags, Fresh Scent, 200 ct."). Only pair when
#     nothing but spaces/commas separate them.
#  2. CONTENTS UNITS ONLY - oz / fl oz / lb / ml. A GALLON figure next to a count is, in this catalog, a bag
#     CAPACITY, not product: "13 Gallon, 110 ct." would pair into "110 ct 13 gal" and claim 1,430 gallons of
#     trash bag. Adjacency alone cannot catch that one - the capacity sits right next to the count - so the
#     unit itself has to be the tell. (Harmless today, since trash bags are counted per-each and the count
#     still governs; excluded so it stays harmless if a volume commodity ever matches.)
function Get-NamePack([string]$name) {
  if (-not $name) { return $null }
  $n = $name.ToLower()
  # Sam's punctuates fluid ounce as "fl. oz." as often as "fl oz" - without the optional dot the measure in
  # "Thai Kitchen Unsweetened Coconut Milk 13.66 fl. oz. cans, 6 pk." is invisible.
  $unit = '(fl\.?\s*oz|floz|oz|lbs?|pounds?|ml)'
  $cnt  = '(?:ct|count|pk|packs?)'
  # "Adjacent" allows a couple of connecting WORDS ("...13.66 fl. oz. cans, 6 pk."), just no other NUMBER -
  # a digit in between means the two figures belong to different facts. The contents-unit restriction above,
  # not the gap width, is what keeps a bag CAPACITY from being paired.
  foreach ($pat in @(
    "(\d[\d.]*|\.\d+)\s*-?\s*$unit\b[^\d]{0,14}(\d+)\s*-?\s*$cnt\b",   # "3.2 oz., 32 ct."  /  "13.66 fl. oz. cans, 6 pk."
    "(\d+)\s*-?\s*$cnt\b[^\d]{0,14}(\d[\d.]*|\.\d+)\s*-?\s*$unit\b"    # "4 ct., 32.4 oz."
  )) {
    $m = [regex]::Match($n, $pat)
    if (-not $m.Success) { continue }
    if ($pat -like '*ct|count*pk*' -and $false) { }
    # group order differs between the two patterns; detect by which group holds the unit token
    if ($m.Groups[2].Value -match "^$unit$") { $val = $m.Groups[1].Value; $uu = $m.Groups[2].Value; $c = $m.Groups[3].Value }
    else { $c = $m.Groups[1].Value; $val = $m.Groups[2].Value; $uu = $m.Groups[3].Value }
    $val = $val.TrimEnd('.')
    if ($val -notmatch '^\d+(\.\d+)?$' -or $c -notmatch '^\d+$') { continue }
    $uu = ($uu -replace '\.','' -replace '\s+',' ')     # "fl. oz." -> "fl oz"
    if ($uu -match '^(lbs|pounds|pound)$') { $uu = 'lb' }
    if ($uu -eq 'floz') { $uu = 'fl oz' }
    return @{ count = [double]$c; measure = ($val + ' ' + $uu) }
  }
  return $null
}

function Format-Qty([double]$q) {
  if ([math]::Abs($q - [math]::Round($q)) -lt 0.0005) { return ([string][int][math]::Round($q)) }
  return ('{0:0.###}' -f $q)
}

# Build ONE engine-shaped row from a raw capture row. Returns @{row=..; err=..}
function Build-Row($raw) {
  $lpm = [regex]::Match(("" + $raw.lp), '\$\s*([\d,]+(?:\.\d{1,2})?)')
  if (-not $lpm.Success) { return @{ err='no linePrice' } }

  # WALMART PRICES CHEAP UNITS IN CENTS: "24.9 c/oz", not "$0.249/oz". Sam's never does - this parser was
  # lifted from build-sams-deals - so a dollars-only regex silently rejected EVERY cent-denominated row as
  # "no unitPrice". On 2026-07-29 that was 927 of 1,199 unit prices (707 of them c/oz), and the capture built
  # 184 priced rows instead of ~1,350. It reads as "the pull came back thin" and gets blamed on the bot wall.
  # Which notation you get depends on where the price was read: priceInfo.unitPrice gives dollars, the
  # priceDetails.priceLines UNIT_PRICE fallback gives cents. Accept both.
  # CORRECTED 2026-08-26: the cent sign no longer arrives mangled. The capture sink used to decode every
  # POST body as cp1252, so this field read as A-circumflex + cent (U+00C2 U+00A2, not A-cedilla as this
  # comment said); the sink now decodes UTF-8 and a bare U+00A2 arrives. The pattern still matches on the
  # DIGITS + slash shape rather than the glyph, which covers both spellings for free - captures inside the
  # carry window predate the fix. Note the {1,3} run: a DOUBLE-mangled cent is 4 glyphs and drops the row
  # as 'no unitPrice' rather than mispricing it, which is the right failure but a silent one.
  $upRaw = ("" + $raw.up)
  $upm = [regex]::Match($upRaw, '\$\s*([\d,]+(?:\.\d{1,3})?)\s*/\s*(.+)$')
  if ($upm.Success) {
    $up = [double]($upm.Groups[1].Value -replace ',','')
  } else {
    # cents form: "<number> <cent-glyph>/<unit>"  ->  dollars
    $cm = [regex]::Match($upRaw, '^\s*([\d,]+(?:\.\d{1,3})?)\s*[^\d/\s]{1,3}\s*/\s*(.+)$')
    if (-not $cm.Success) { return @{ err='no unitPrice' } }
    $up = [double]($cm.Groups[1].Value -replace ',','') / 100.0
    $upm = $cm
  }
  $lp = [double]($lpm.Groups[1].Value -replace ',','')
  if ($lp -le 0 -or $up -le 0) { return @{ err='zero price' } }
  # A QUANTIFIED DENOMINATOR MEANS "PRICE PER N UNITS" (2026-07-31). Walmart quotes count goods per 100:
  # the unit price on a pack of plates arrives as "$5.58/100 ct", not "$0.0558/ct". Resolve-Unit anchors on
  # a BARE unit (^(ea|each|ct|count)$), so "100 ct" fell straight through to the unknown-unit reject and the
  # whole class was silently unpriceable - measured on the 2026-07-31 at-risk capture, 194 of 205 unit-price
  # strings carried a count denominator and 152 of 154 rejects were exactly this. That removes every paper
  # plate, napkin, dryer sheet and tea bag from any batch capture, which is why four commodities could not be
  # refreshed off the expiring 07-18 pull no matter how deep the search went.
  # Dividing is right in general, not just for counts: "$2.00/12 fl oz" is $0.1667/fl oz, and a denominator of
  # "1 lb" divides by 1 and changes nothing. Verified against a known-good board value - Great Value 8.5"
  # plates quote "$5.58/100 ct" and the board's existing per-each for that cell is 0.0558.
  $denom = $upm.Groups[2].Value
  $dm = [regex]::Match(($denom + '').Trim(), '^([\d,]+(?:\.\d+)?)\s+(.+)$')
  if ($dm.Success) {
    $dq = [double]($dm.Groups[1].Value -replace ',','')
    if ($dq -gt 0) { $up = $up / $dq; $denom = $dm.Groups[2].Value }
  }
  $u = Resolve-Unit $denom
  if (-not $u) { return @{ err=('unknown unit "' + $denom + '"') } }

  # unitPrice is rounded to the cent, so lp/up is only as good as that rounding: a $0.09/ea item can be off by
  # 0.005/0.09 = 5.6% before anything is wrong, and at $0.01/ea it is off by up to 50%.
  $roundErr = (0.005 / $up)

  # WHICH QUANTITY TO BELIEVE - the name's, or lp/up?
  # Do NOT compare them by "percent drift": the quotient's own error explodes as up gets small, so no drift
  # threshold can be right for both a $2.88/lb steak and a $0.01/ea cotton swab. Sam's prints Q-tips at
  # "$0.01/ea" because it ROUNDS 0.0053 up, so lp/up derived 888 swabs for a box the name correctly calls
  # 1665 ct - an 87% "drift" that a 51% threshold rejected, publishing $0.01/swab for a $0.0053 swab. Guard 4
  # caught it by comparing the board to the product link.
  # The exact test instead: does the name's quantity REPRODUCE the unit price Sam's actually displays? If
  # lp/nameQty rounds to up, the name is consistent with Sam's own arithmetic and is the precise value (the
  # quotient is merely the rounded one). If it does not, the name is describing something else and we keep
  # Sam's arithmetic.
  $derived = $lp / $up
  $qty = $derived
  $basis = 'derived lp/up'
  $cands = Get-NameQtyCandidates $raw.n $u.tok
  $best = $null; $bestErr = [double]::MaxValue
  foreach ($c in $cands) {
    if ($c -le 0) { continue }
    $err = [math]::Abs(($lp / $c) - $up)
    if ($err -le 0.005001 -and $err -lt $bestErr) { $best = $c; $bestErr = $err }   # would display as Walmart's up
  }
  if ($best) { $qty = $best; $basis = 'name (reproduces Walmart''s unit price)' }
  elseif ($cands.Count) {
    # A PRINTED WEIGHT OR VOLUME THE UNIT PRICE DENIES IS NOT PUBLISHABLE (2026-09-05).
    # This branch used to keep lp/up and write the disagreement into qty_basis as prose. That is how
    # 'Knorr Select Vegetable Base, Shelf Stable Granulated Bouillon, 1.82 pounds' shipped as 10.891 lb -
    # $17.97 divided by Walmart's own "$1.65/lb" attribute - and held the bouillon CROWN at $0.0813/oz
    # against a real $0.6169/oz. The memo grocery-method-walmart records that Walmart's unit price is
    # provably wrong sometimes, so the attribute cannot be the tie-breaker against the printed quantity;
    # and this file's own doctrine for the SHAPE question, five hundred lines down, is already
    # "A row where neither shape does is rejected, never published".
    # Census over walmart-regular 2026-08-22..09-05 (14,126 rows): 2,146 rows derive lp/up, 337 agree with
    # the name, 1,134 state no quantity at all, 379 disagree by a multiple a pack token explains, and 176
    # disagree with nothing to explain them (50 of those by more than 1.5x; the Knorr row by 5.98x).
    #
    # SCOPED TO WEIGHT AND VOLUME, DELIBERATELY. For a COUNT the two numbers are the same kind of thing and
    # the estate has already ruled the other way: case 8 below ('Bogus Beans, 99 ct.' -> trust lp/up) is a
    # frozen fixture for exactly that, and 8f already rejects the one count shape that is unprovable. For a
    # weight or a volume the name states the CONTENTS and lp/up states an inference from an attribute we
    # know can be wrong, so a disagreement neither a pack count nor a rounding explains has no defensible
    # answer. Refusing loses the row; publishing loses the number, and a wrong number outranks a real one.
    # SAME-FAMILY EVIDENCE ONLY. UnitFamily deliberately maps a bare "oz" into the FL OZ family, because a
    # store prints "16 oz" on a bottle and means fluid ounces - that mapping is right for the SNAP, where a
    # reading only wins if it reproduces Walmart's number. It is not evidence of a CONTRADICTION: "Some
    # Sauce, 32 oz Jar" priced at 10.0 cents per FL OZ is a weight on the label and a volume on the shelf
    # tag, and import-walmart-batch has a frozen fixture ruling exactly that cross-family pair must NOT
    # override Walmart's arithmetic (it publishes at the derived 64 fl oz). A refusal built on the blended
    # candidate list fires on that row, which is the fixture catching this rule being too broad.
    $packMult = Get-NamePackMultipliers $raw.n
    $strict = @(Get-SameFamilyNameQty $raw.n $u.tok)
    $explained = $false
    foreach ($c in $strict) {
      if ($c -le 0) { continue }
      foreach ($m in $packMult) {
        if ($m -le 0) { continue }
        $ratio = ($c * $m) / $derived
        if ($ratio -ge 0.92 -and $ratio -le 1.08) { $explained = $true; break }
      }
      if ($explained) { break }
    }
    if ($u.tok -ne 'ct' -and $strict.Count -and -not $explained) {
      return @{ err = ('REFUSED: name quantity disagrees with unit price, no pack count - the name states ' +
                       (($strict | Select-Object -First 4) -join ', ') + ' ' + $u.tok + " but Walmart's " +
                       $upm.Groups[0].Value.Trim() + ' derives ' + (Format-Qty $derived) + ' ' + $u.tok) }
    }
    $basis = ('derived lp/up; no name quantity (' + (($cands | Select-Object -First 4) -join ', ') + ') reproduces Walmart''s ' + $up)
    if ($explained) { $basis = ($basis + '; a pack count in the name explains the multiple') }
  }
  # A COUNT MUST BE A WHOLE NUMBER. You cannot buy 210.889 trash bags, and a fractional count is not merely
  # untidy - compare-deals' Get-PackCount regex reads the digits immediately before "ct", so size "210.889 ct"
  # is parsed as a pack of EIGHT HUNDRED EIGHTY-NINE and the price comes out 4x low. (The invariant check
  # caught exactly this.) Weights and volumes are genuinely fractional and are left alone.
  if ($u.tok -eq 'ct') {
    $qty = [math]::Round($qty)
    if ($qty -lt 1) { $qty = 1 }
  }
  if ($qty -le 0) { return @{ err='bad qty' } }

  # A "/ea" DENOMINATOR THAT IS NOT AN EACH (2026-07-31). Walmart's own unit-price LABEL lies on weight-priced
  # multipacks. "Chef Merito Achiote ... Paste, 3.5 oz, (Pack of 12)" at $16.24 quotes "38.7 c/ea", and
  # 16.24/0.387 = 42 - which is 12 x 3.5 OUNCES, not 42 jars. Stamped "42 ct" the row is internally consistent
  # for a COUNT commodity and catastrophically wrong for a WEIGHT one: the engine, handed a ct size on an oz
  # commodity, falls back to the NAME's single-jar "3.5 oz" while keeping the whole 12-pack price, and
  # publishes $4.64/oz for a $0.3867/oz paste - 12x over. It held the CROWN on that cell (sole store).
  # This is the fish-sauce rule one level down: the store's own unit price is evidence, not gospel, and the
  # product NAME wins. We do not prefer one reading, we PROVE the denominator by the name's arithmetic:
  #   derived ~= N              -> the count is real, keep ct       (GV Paper Plates, Pack of 50 -> 50 ct)
  #   derived ~= N x unit-size  -> denominator is the NAME's UNIT   (achiote: 42 = 12 x 3.5 -> 42 oz)
  #   neither                   -> the store contradicts itself     (Almond Breeze: 33 vs 12 vs 384 -> REJECT)
  # The restamped quantity is the NAME's product (12 x 3.5), not the rounded quotient: lp/up is only as good
  # as Walmart's cent rounding, and the name's arithmetic reproduces the displayed unit price exactly.
  # Measured 2026-07-31 over all 4,864 rows of the live capture: exactly 4 rows carry this shape, and they are
  # one of each branch plus the beef broth (385 -> 384 oz, a loser either way).
  if ($u.tok -eq 'ct' -and $qty -gt 1) {
    $mpN = [regex]::Match(([string]$raw.n), '(?i)\bpacks?\s+of\s+(\d+)\b')
    $mpS = [regex]::Matches(([string]$raw.n), '(?i)(\d+(?:\.\d+)?|\.\d+)\s*(fl\s*\.?\s*oz|floz|oz|lbs?)\b')
    if ($mpN.Success -and $mpS.Count -gt 0) {
      $mpCount = [double]$mpN.Groups[1].Value
      $mpLast  = $mpS[$mpS.Count - 1]                       # the size conventionally trails the name
      $mpEach  = [double]$mpLast.Groups[1].Value
      $mpUnit  = Resolve-Unit ($mpLast.Groups[2].Value -replace '\s+','')
      $mpTotal = $mpCount * $mpEach
      if ($mpCount -gt 1 -and $mpEach -gt 0 -and $mpUnit) {
        if ([math]::Abs($qty - $mpCount) -le 1.0) {
          # the derived quantity IS the stated pack count - a true count row, nothing to restamp
        }
        elseif ([math]::Abs($qty - $mpTotal) / $mpTotal -le 0.02) {
          $u     = $mpUnit
          $qty   = $mpTotal
          $basis = ($basis + '; denominator proven by name arithmetic (' + (Format-Qty $mpCount) + ' x ' +
                    (Format-Qty $mpEach) + ' ' + $mpUnit.tok + ' = ' + (Format-Qty $mpTotal) +
                    ') - Walmart labelled this per-' + $u.unit + ' price "/ea"')
        }
        else {
          return @{ err = ("name/unit-price divergence: Walmart's unit price " + $upm.Groups[0].Value.Trim() +
                    ' derives ' + (Format-Qty $qty) + ' but the name states ' + (Format-Qty $mpCount) + ' x ' +
                    (Format-Qty $mpEach) + ' ' + $mpUnit.tok + ' (= ' + (Format-Qty $mpTotal) +
                    ', neither reading) - the store contradicts itself, verify by hand (fish-sauce class 2026-07-27)') }
        }
      }
    }
  }

  # size = the quantity + its unit. qty 1 -> the bare unit token, which the engine reads as "priced per that unit".
  $bare = if ($u.tok -eq 'ct') { 'each' } else { $u.tok }
  $pkgSize = if ([math]::Abs($qty - 1) -lt 0.0005) { $bare } else { (Format-Qty $qty) + ' ' + $u.tok }
  # When Sam's prices per EACH but the name states the per-item measure right beside the count, carry BOTH
  # into the size so the row prices correctly for a count-commodity AND a weight-commodity (see Get-NamePack).
  # Only pair when that stated count is the count we actually settled on - otherwise the measure belongs to
  # some other number in the name and pairing it would invent a size.
  if ($u.tok -eq 'ct' -and $qty -gt 1) {
    $np = Get-NamePack $raw.n
    if ($np -and [math]::Abs($np.count - $qty) -lt 0.5) { $pkgSize = (Format-Qty $qty) + ' ct ' + $np.measure }
  }

  # unitPrice is rounded to the cent, so the invariant can only be as tight as that rounding allows: a
  # $0.16/ea item carries up to 0.005/0.16 = 3.1% of pure rounding error. Scale the tolerance to it, or cheap
  # per-unit items get rejected for being correct. (A real basis error - a tray price read as a per-lb price -
  # is off by hundreds of percent and is still caught.)
  $tol = [math]::Max(0.02, $roundErr + 0.005)

  # TWO CANDIDATE SHAPES, in preference order:
  #  1. PACKAGE  - ad_price = linePrice, size = the pack quantity. Unit-agnostic; what every other feed means.
  #  2. PER-UNIT - ad_price = unitPrice,  size = the bare unit. Required when the NAME carries a per-lb /
  #     per-each marker ("...priced per pound"): Get-ItemPrice scans priceText+nameText, so that marker makes
  #     the engine read whatever ad_price is AS the per-lb price. With the package shape that publishes a
  #     ~4 lb tray at $10.35/LB instead of $2.88/lb - a real, correctly-dated, completely false number.
  # We do not guess which applies: we ask the REAL engine and keep the shape that reproduces Walmart's own
  # unitPrice. A row where neither shape does is rejected, never published.
  $tries = @(
    @{ ad=('${0:N2}' -f $lp); size=$pkgSize; shape='package' },
    @{ ad=('${0:N2}' -f $up); size=$bare;    shape='per-unit' }
  )
  $errs = @()
  foreach ($t in $tries) {
    $d = [pscustomobject]@{ price_text=$t.ad; name=[string]$raw.n; size_text=$t.size; regular=$null }
    $got = Get-UnitPrice $d ([pscustomobject]@{ unit=$u.unit })
    if ($null -eq $got) { $errs += ($t.shape + ": engine returned null (size='" + $t.size + "')"); continue }
    $diff = [math]::Abs($got.unit_price - $up) / $up
    if ($diff -gt $tol) { $errs += ($t.shape + ": engine " + [math]::Round($got.unit_price,4) + " vs Walmart's " + $up + ' (' + [math]::Round($diff*100) + '% off)'); continue }
    return @{ row = [pscustomobject]@{
      store     = "Walmart"
      item      = [string]$raw.n
      ad_price  = $t.ad
      size      = $t.size
      regular   = $null
      source_ad = 'everyday shelf price'
      price_type = 'everyday'
      # THE current_price CONTRACT (guard 10), added 2026-07-23: what the store CHARGES, in the SAME BASIS as
      # ad_price. Here that is the same store-sourced number ad_price was built from (lp/up straight off
      # Walmart's own priceLines - the emit invariant above already proves ad_price reproduces it through the
      # real engine), so guard 10's ad==current check is a FILE-INTEGRITY invariant for these rows: any
      # post-build edit, bad merge, or corruption that moves ad_price without current_price now hard-fails the
      # gate instead of publishing. The independent store-truth check remains the builder's reproduce-invariant
      # at capture time (same division of labor as Baker's guard 11 raw-capture check).
      current_price = $t.ad
      # Preserve the actual checkout total independently from the legacy engine-shaped ad/current basis.
      # A small minority of rows must use the per-unit shape to make the legacy engine reproduce Walmart's
      # posted unit price. V3 must still bind the normalized observation to the linePrice captured in Chrome.
      source_checkout_price = ('${0:N2}' -f $lp)
      # PER-ROW as_of (2026-08-07). Walmart rows shipped with NO date at all - 11,092 of them - so the only
      # freshness signal was the FILENAME, and compare-deals unions captures across 14 days. Guard 9 reads
      # file age, the file is rewritten daily, so it passed every run while individual prices aged for weeks
      # underneath. Same shape as the feed assert that stamped its own date and could not detect the failure
      # it existed for.
      # This is the CAPTURE date ($Date, the -Date parameter naming the capture being built), never the
      # build date: stamping "today" onto a row lifted from a 14-day-old capture would be the exact
      # dates-written-not-measured lie the stamp exists to end.
      as_of         = $script:CaptureDate
      wm_unit_price = $upm.Groups[0].Value.Trim()   # kept for audit; the engine ignores unknown fields
      item_id       = [string]$raw.id
      found_by_term = [string]$raw.q
      qty_basis     = ($t.shape + '; qty ' + $basis)
      engine_check  = ('' + [math]::Round($got.unit_price,4) + '/' + $u.unit + ' [' + $got.basis + ']')
      taxonomy_path = [string]$raw.taxonomy_path
      link_url      = [string]$raw.url
      image_url     = [string]$raw.image_url
      # THE SHELF SIGNAL (2026-08-29, design\BRIEF-marketplace-shelf-signal-2026-08-29.md).
      # Three generations of per-product rulings failed to converge on the marketplace-bulk class -
      # Frontier Co-op 16 oz bags, then 27 Peaks 12-19 oz bottles, then Badia 16 oz / 24 Mantra /
      # Spice Hut - because a ruling names a PRODUCT and the defect is a LISTING KIND. curry-powder was
      # blocked at Frontier's $0.7669/oz and came back at 27 Peaks' $0.7775/oz, one cent dearer.
      # Every proxy tried stands in for one fact: is this listing purchasable at the L St store, or does
      # it only ship? That fact is on the page and was never in our data. It is carried here so a rule can
      # eventually read it instead of guessing from brand or size.
      # EMPTY IS UNKNOWN, NEVER "SHIPPED". Captures written before the SKILL emitted these columns have no
      # sel/ff at all, and the 90-day union keeps them until they roll off. Anything downstream must treat
      # '' as no-information and admit the row; refusing on absence would drop most of the union overnight.
      seller        = [string]$raw.sel
      fulfillment   = ([string]$raw.ff).ToUpper()
    } }
  }
  return @{ err=("INVARIANT: no shape reproduces Walmart's " + $up + '/' + $u.tok + ' -> ' + ($errs -join ' | ')) }
}
