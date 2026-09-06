<#
  build-walmart-deals.ps1 - turn a RAW Walmart capture into out\walmart-regular-<date>.json. (Header previously said build-sams-deals - copy-paste error, fixed 2026-07-26.)

  Input CSV (pipe-delimited, from the in-page pull): q|n|lp|up|id
     q  = the search term        n  = product name
     lp = priceInfo.linePrice    ("$3.27")  - the price of the whole pack
     up = priceInfo.unitPrice    ("$1.09/ea") - Walmart's OWN price per unit of measure
     id = usItemId

  *** WHY THIS SCRIPT EXISTS ***
  The 2026-07-15 capture was QUARANTINED (see out\sams\quarantine\README.md). It wrote Sam's per-unit price
  as ad_price with a BARE unit in size ("$1.09" + size:"each"). Every other feed writes a PACKAGE price with a
  pack size. The conventions collide in compare-deals' Get-UnitPrice, which for unit='each' divides by a pack
  count read out of the product NAME:

        if ($plain -and $pk) { return $pr.per_item / $pk }      # compare-deals.ps1 ~line 301

  So "Seedless English Cucumbers, 3 ct." at $1.09 PER EACH became $0.3633/each - wrong by 3x. That divide is
  CORRECT for every other feed (size='each' + "24 Pack" in the name really does mean divide-by-24, asserted in
  guards.ps1 guard 0), so it cannot be changed. The ambiguity has to die at INGEST - here.

  *** THE RULE (from import-sams-prices.ps1, unchanged) ***
        ad_price = (price per commodity-unit) x (the quantity `size` represents)
  i.e. ad_price is the price of ONE `size`. We therefore emit the PACKAGE shape - ad_price = linePrice, and
  size = the real pack quantity - which is what every other feed means and what the engine already reads
  correctly for ANY commodity unit. Emitting a bare per-unit basis instead would be unit-fragile: for a
  commodity measured in `each` whose Sam's unitPrice is per-OZ (ramen, bottled water), the engine would divide
  a per-ounce price by the pack count and publish a number ~50x too low.

  *** WHERE THE PACK QUANTITY COMES FROM ***
  Not from guessing - from Sam's own arithmetic:  qty = linePrice / unitPrice.
  That is exact by construction, but unitPrice is ROUNDED to cents, so for a cheap per-unit item the quotient
  drifts (110-ct trash bags at $0.11/ea derive as 163). So we SNAP to the quantity stated in the name when the
  two agree within 5% - the same 5% pack cross-check import-sams-prices.ps1 already prescribes - and fall back
  to the derived value when the name states nothing.

  *** THE INVARIANT ***
  Because ad_price = lp and size = lp/up, the engine MUST compute lp/(lp/up) = up. So every emitted row is
  checked against the REAL Get-UnitPrice lifted out of compare-deals.ps1: engine(row) must equal Sam's own
  unitPrice. A row that fails is NOT published - it is written to the .rejects.json beside the output. This is
  what the quarantined capture had no way to detect.

  *** THE FISH-SAUCE NAME-OVERRIDE IS DELIBERATELY *NOT* PORTED HERE (decided 2026-07-30) ***
  import-walmart-batch.ps1 carries a rule that lets the product NAME beat Walmart's own unitPrice when the two
  diverge >10%, added 2026-07-27 after a 6.8 fl oz bottle listed at 28.4 c/fl oz backed out to 10 fl oz.
  Backlog item 27 proposed porting it into this builder. IT WAS MEASURED AND REFUSED, and the measurement is
  the point: lifting Build-Row plus the six engine functions and running the override across the full live
  capture (out\captures\walmart-capture-2026-07-29.csv, 4,626 rows, 3,444 built) fires it 74 times and APPLIES
  it 74 times - zero rejections. Its "re-verify the overridden shape through the real engine" step is
  CIRCULAR: for a plain "N unit" size on an lb/oz/floz commodity, Get-UnitPrice returns price/N, which is
  exactly lp/nameQty, which is exactly the value being checked against. The only path that could disagree
  (Get-PackCount) is excluded by Parse-NameSize's own pack guard, a strict subset of Get-PackCount's regex.
  So the check cannot fail, and porting it would replace this builder's REAL invariant - engine output must
  reproduce the store's own published unit price - with a rule that always says yes. That is a gate that can
  never arm, on the one path in this file that decides a published size.
  If it is ever ported, the re-verification must come from something the override does not derive from
  (the store page, a second capture, a cross-store plausibility rail) - not from the name it just trusted.

  Usage: .\build-walmart-deals.ps1 -In <capture.csv> -Date 2026-07-17
         .\build-walmart-deals.ps1 -SelfTest
#>
param(
  [string]$In = "",
  [string]$Date = "",
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
# WHO AM I. This file is a fork of build-sams-deals.ps1 (capture-lib.ps1:14-19) and inherited that name in
# every operator-facing string, so a Walmart failure sent you to the Sam's builder and the Sam's capture.
# Read the name off the file itself so the next fork renames itself. Captured ONCE at script scope on
# purpose: inside a function $MyInvocation.MyCommand.Name returns the FUNCTION name, not the file.
$Me = $MyInvocation.MyCommand.Name
# The CAPTURE date every emitted row is stamped with. Script-scoped for the same reason $Me is: the row
# builder is a function and cannot see the param block's $Date. Falls back to the date in the input
# filename, then to today - in that order, because the filename is evidence and today is a guess.
$script:CaptureDate = $Date
if (-not $script:CaptureDate -and $In) { $m = [regex]::Match($In, '\d{4}-\d{2}-\d{2}'); if ($m.Success) { $script:CaptureDate = $m.Value } }
if (-not $script:CaptureDate) { $script:CaptureDate = (Get-Date).ToString('yyyy-MM-dd') }
. (Join-Path $root 'capture-lib.ps1')   # UTF-8 capture read + mojibake repair, shared by every builder

# ---- lift the REAL pricing math out of the engine (it runs a pipeline on load, so we can't dot-source it) ----
# -Encoding UTF8 is NOT optional here. These functions are lifted as SOURCE TEXT and re-parsed, so
# their non-ASCII regex literals have to survive the read. compare-deals.ps1 carries a BOM today and
# Get-Content would honour it - but that leaves the whole pricing engine depending on a byte order
# mark nothing asserts. Name the encoding and the dependency is gone.
$engineSrc = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw -Encoding UTF8
# THIS LIST IS A DEPENDENCY GRAPH, AND IT IS HAND-MAINTAINED (2026-08-29). Adding a helper that
# Get-UnitPrice calls without naming it here lifts a function whose callee does not exist, and the failure
# lands at RUN time as "not recognized as the name of a cmdlet" - which is what happened the day
# Test-NameOffersTwoSizes was added to refuse either/or ad rows. The guard caught it (the walmart-deals
# self-test is a hard invariant), so nothing shipped, but the trap is worth naming: if you add a function
# to compare-deals.ps1 and any lifted function calls it, it belongs in this list too.
foreach ($fn in @('ConvertTo-DigitNumerals','Get-ItemPrice','Get-PackCount','Test-NameOffersTwoSizes','Get-UnitPrice','Get-SizeAmount','Convert-ToUnit','Get-TcEachCountTokens','Get-TcWholePurchaseTokens')) {
  $m = [regex]::Match($engineSrc, "(?ms)^function\s+$([regex]::Escape($fn))\s*\(.*?^\}")
  if (-not $m.Success) { throw "${Me}: could not lift $fn from compare-deals.ps1" }
  Invoke-Expression $m.Value
}

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
  # The unit lists and the pattern live INSIDE the function on purpose. import-walmart-batch.ps1 lifts this
  # file's functions by AST and separately lifts $script:UnitFamily by name, so any new script-scope variable
  # a lifted function reads is a second thing to remember - and the failure is a function that quietly reads
  # $null and returns an empty result rather than throwing. Keeping them local means the lift carries
  # everything the function needs. .NET caches compiled patterns, so the literal costs nothing per call.
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

# ---- multipack pre-filter: reject exactly what guards.ps1 guard 5 would reject, so the board never sees it ----
# 2026-07-23: a broadened Walmart pull dragged in bulk multipacks ("(4 pack) Domino Sugar, 10 lb" = 40 lb) and
# ice-cream novelties whose name states only the pack TOTAL. All 32 hard-failed guard 5 and blocked the whole
# nightly publish, firing ~20 alert emails. These are never a normal shopper's single-buy unit, so they do not
# belong on the board. The arithmetic is ONE shared function (multipack-lib.ps1, dot-sourced by guards.ps1 too),
# so builder and gate can never drift apart - a row this rejects is a row the guard would have hard-failed,
# BY CONSTRUCTION, not by two hand-synced copies. (Defined ABOVE the self-test so -SelfTest proves it.)
. (Join-Path $root 'multipack-lib.ps1')
$bwAllow = Get-MpAllowKeys $root
function BW-IsMultipackReject($item, $size) {
  return ((Test-MpClassify 'Walmart' ([string]$item) ([string]$size) $script:bwAllow) -eq 'reject')
}

if ($SelfTest) {
  $fail = 0
  function _R($n,$lp,$up) { [pscustomobject]@{ q='t'; n=$n; lp=$lp; up=$up; id='1' } }
  function _Chk($label,$raw,$wantSize,$wantAd) {
    $r = Build-Row $raw
    if ($r.err) { Write-Output "FAIL  $label -> $($r.err)"; $script:fail++; return }
    if ($r.row.size -eq $wantSize -and $r.row.ad_price -eq $wantAd) { Write-Output "ok    $label -> ad=$($r.row.ad_price) size='$($r.row.size)'" }
    else { Write-Output "FAIL  $label -> got ad=$($r.row.ad_price) size='$($r.row.size)' want ad=$wantAd size='$wantSize'"; $script:fail++ }
  }
  # 1. THE REGRESSION: the row that got 07-15 quarantined. Package shape -> engine divides 3.27/3 = 1.09.
  _Chk 'cucumbers 3 ct'        (_R 'Seedless English Cucumbers, 3 ct.' '$3.27' '$1.09/ea')      '3 ct'   '$3.27'
  # 2. per-lb bag: qty from name agrees with lp/up
  _Chk 'mini cucumbers 2 lbs'  (_R 'Mini Cucumbers, 2 lbs.' '$3.96' '$1.98/lb')                 '2 lb'   '$3.96'
  # 3. single item, no count in the name -> bare 'each'
  _Chk 'watermelon each'       (_R 'Whole Seedless Watermelon' '$4.98' '$4.98/ea')              'each'   '$4.98'
  # 4. BY-WEIGHT TRAY: the name says "priced per pound", which trips the engine's per-lb marker and makes it
  #    read ad_price AS the per-lb price. The package shape would publish the $10.35 TRAY at $10.35/LB, so the
  #    per-unit shape must win here. This is the exact failure import-sams-prices.ps1 documents.
  _Chk 'chicken breast tray'   (_R "Member's Mark Boneless Skinless Chicken Breast, priced per pound" '$10.35' '$2.88/lb') 'lb' '$2.88'
  # 5. multipack stated size-then-count ("16.9 fl oz, 40 pk") - the ORDER the engine's multipack regex cannot
  #    read. We emit the TOTAL (40 x 16.9 = 676), so order never matters.
  #    This is also the clearest case for the rounding-aware snap: at $0.01/foz the cent-rounding is +/-50%,
  #    so lp/up derives a meaningless 498. The name's 676 is the true size (4.98/676 = $0.0074 -> prints as
  #    the $0.01 Sam's shows). A flat 5% snap would have published the 498.
  _Chk 'water 40 pk 16.9 floz' (_R "Member's Mark Purified Water, 16.9 fl oz, 40 pk" '$4.98' '$0.01/fl oz') '676 fl oz' '$4.98'
  # 6. cheap per-each where the rounded unitPrice derives a WRONG count (163) - the name (110) must win
  _Chk 'trash bags 110 ct'     (_R 'Glad ForceFlex Tall Kitchen Trash Bags, 13 Gallon, 110 ct.' '$17.98' '$0.16/ea') '110 ct' '$17.98'
  # 7. oz block
  _Chk 'cheddar 32 oz'         (_R "Member's Mark Sharp Cheddar, 32 oz." '$15.04' '$0.47/oz')   '32 oz'  '$15.04'
  # 7b. Sam's spells fluid ounce "foz". If this mapping is ever lost, every liquid silently leaves the board.
  _Chk 'foz = fluid ounce'     (_R 'Mr. Clean Multi-Surface Cleaner, 128 fl oz' '$20.48' '$0.16/foz') '128 fl oz' '$20.48'
  # 7c. ...and dozen "dz", which is EGGS - a headline commodity.
  _Chk 'dz = dozen (eggs)'     (_R "Member's Mark Cage Free Grade A Large White Eggs, 2 dozen" '$4.62' '$2.31/dz') '2 dozen' '$4.62'
  # 7d. A COUNT MUST BE A WHOLE NUMBER. Real row: 200-ct bags at a cent-rounded $0.09/ea derive as 210.9. A
  #     fractional "210.889 ct" makes Get-PackCount read the pack as 889 and prices the bags 4x low.
  _Chk 'trash bags 200 ct (rounding-aware snap)' (_R "Member's Mark Power Flex 13-Gallon Tall Kitchen Trash Bags, Fresh Scent, 200 ct." '$18.98' '$0.09/ea') '200 ct' '$18.98'
  # 7e. no count anywhere in the name -> the count is derived, and must still be a whole number
  $r7e = Build-Row (_R 'Member''s Mark Unnamed Count Bags' '$18.98' '$0.09/ea')
  if ($r7e.row -and $r7e.row.size -notmatch '\.') { Write-Output "ok    derived count is a whole number -> size='$($r7e.row.size)'" }
  else { Write-Output "FAIL  derived count not integral: $($r7e.row.size)$($r7e.err)"; $fail++ }

  # 7j. THE COTTON-SWAB CASE (caught by guard 4 against the product link, not by any check in here).
  #     Sam's prints "$0.01/ea" for a 1665-ct box because it rounds 0.0053 UP. lp/up then derives 888, an 87%
  #     "drift" from the true 1665 - so a drift threshold generous enough to accept it would accept anything.
  #     The name wins because 8.88/1665 = $0.0053 rounds to the $0.01 Sam's shows.
  #     The REAL row also carries TWO counts in the opposite order to Pampers below, so no fixed
  #     first/last rule works: 9.34/1750 = $0.0053 (rounds to $0.01, and matches the product link exactly),
  #     while 3 and 5250 do not.
  _Chk 'q-tips 1750 ct 3 pk (rounded $0.01/ea)' (_R 'Q-tips Cotton Swabs, 1750 ct., 3 pk.' '$9.34' '$0.01/ea') '1750 ct' '$9.34'
  #     ...and the opposite order must still take the LAST count. One rule, both names.
  _Chk 'pampers 13 pk., 728 ct.' (_R 'Pampers Aqua Pure Baby Wipes, 13 pk., 728 ct.' '$30.98' '$0.04/ea') '728 ct' '$30.98'

  # 7k. LEADING-DOT DECIMALS (ported from build-sams-deals 2026-07-30): ".98 oz., 46 pk." must read 0.98,
  #     not 98. MUST-FIRE: the old pattern gave name candidates [98, 4508]; neither reproduces $0.23/oz, so
  #     the builder shipped a fractional lp/up-derived '44.696 oz' where the true 45.08 (0.98 x 46) was
  #     invisible. (The sams grits case, alive in the walmart parser until today.)
  _Chk 'grits .98 oz 46 pk (leading-dot)' (_R 'Quaker Instant Grits, Variety Pack, .98 oz., 46 pk.' '$10.28' '$0.23/oz') '45.08 oz' '$10.28'
  #     clean twin: plain leading-dot single item - the name's 0.59 reproduces the unit price exactly
  _Chk 'parsley .59 oz (leading-dot)' (_R 'Watkins Gourmet Organic Spice Jar, Parsley Flakes, .59 oz' '$7.70' '$13.05/oz') '0.59 oz' '$7.70'

  # 7g. THE NAME'S UNIT NEED NOT BE SAM'S UNIT. Milk is sold as "1 gal." but priced per fluid ounce, where a
  #     cent of rounding is +/-16% - lp/up derives 124 fl oz and publishes $3.84/gal for milk that costs
  #     $3.72. Converting the name's gallon into fl oz lets the exact 128 win.
  _Chk 'milk 1 gal priced per foz' (_R "Member's Mark 2% Reduced Fat Milk 1 gal." '$3.72' '$0.03/foz') '128 fl oz' '$3.72'
  # 7h. a name unit from ANOTHER family must be ignored, never converted
  $r7h = Build-Row (_R 'Mystery Item 12 ct' '$6.00' '$0.50/lb')
  if ($r7h.row -and $r7h.row.size -eq '12 lb') { Write-Output "ok    foreign name-unit ignored -> size='$($r7h.row.size)'" }
  else { Write-Output "FAIL  foreign name-unit: $($r7h.row.size)$($r7h.err)"; $fail++ }

  # 7i. Sam's punctuates "fl. oz." and slips a word between the measure and the count. Both broke the pairing,
  #     so this canned coconut milk fell back to a bare "6 ct", which a per-FL-OZ commodity cannot convert -
  #     the engine then read the per-CAN 13.66 fl oz off the name and priced it 6x high, out of band, gone.
  $r7i = (Build-Row (_R 'Thai Kitchen Unsweetened Coconut Milk 13.66 fl. oz. cans, 6 pk.' '$11.24' '$1.87/ea')).row
  if ($r7i -and $r7i.size -eq '6 ct 13.66 fl oz') {
    $fz = Get-UnitPrice ([pscustomobject]@{price_text=$r7i.ad_price;name=$r7i.item;size_text=$r7i.size;regular=$null}) ([pscustomobject]@{unit='floz'})
    if ([math]::Abs($fz.unit_price - 0.1371) -lt 0.005) { Write-Output ("ok    'fl. oz.' + word gap paired -> " + [math]::Round($fz.unit_price,4) + '/floz') }
    else { Write-Output "FAIL  coconut floz = $($fz.unit_price)"; $fail++ }
  } else { Write-Output "FAIL  coconut size='$($r7i.size)' want '6 ct 13.66 fl oz'"; $fail++ }

  # 7f. THE CROSS-UNIT TRAP. Sam's prices these per POUCH, but our applesauce commodity is measured in OZ.
  #     A size of "32 ct" alone has no weight, so the engine falls back to the NAME and finds the per-pouch
  #     "3.2 oz" -> $4.99/oz instead of $0.156/oz. The full descriptor must satisfy BOTH readings.
  $r7f = (Build-Row (_R 'GoGo SqueeZ Applesauce Pouches, Apple Apple, 3.2 oz., 32 ct.' '$15.98' '$0.50/ea')).row
  if ($r7f -and $r7f.size -eq '32 ct 3.2 oz') {
    $asEach = Get-UnitPrice ([pscustomobject]@{price_text=$r7f.ad_price;name=$r7f.item;size_text=$r7f.size;regular=$null}) ([pscustomobject]@{unit='each'})
    $asOz   = Get-UnitPrice ([pscustomobject]@{price_text=$r7f.ad_price;name=$r7f.item;size_text=$r7f.size;regular=$null}) ([pscustomobject]@{unit='oz'})
    if ([math]::Abs($asEach.unit_price - 0.4994) -lt 0.01 -and [math]::Abs($asOz.unit_price - 0.1561) -lt 0.01) {
      Write-Output ("ok    cross-unit: '32 ct 3.2 oz' -> " + [math]::Round($asEach.unit_price,4) + '/each AND ' + [math]::Round($asOz.unit_price,4) + '/oz')
    } else { Write-Output "FAIL  cross-unit: each=$($asEach.unit_price) oz=$($asOz.unit_price)"; $fail++ }
  } else { Write-Output "FAIL  cross-unit size = '$($r7f.size)' want '32 ct 3.2 oz'"; $fail++ }

  # 8. a row whose name lies about the pack by >5% must fall back to Sam's arithmetic, never publish the lie
  $r8 = Build-Row (_R 'Bogus Beans, 99 ct.' '$3.27' '$1.09/ea')
  if ($r8.row -and $r8.row.size -eq '3 ct' -and $r8.row.qty_basis -match 'no name quantity') { Write-Output "ok    name-vs-arithmetic conflict -> trusts lp/up ($($r8.row.qty_basis))" }
  else { Write-Output "FAIL  conflict row: $($r8.err)$($r8.row.size)"; $fail++ }
  # MUST-FIRE (2026-07-30). qty_basis is the provenance a human reads when a Walmart price looks wrong, and it
  # shipped on 2,531 of 2,784 rows crediting "Sam's" arithmetic - the noun this builder inherited when it was
  # forked from build-sams-deals.ps1 - pointing the investigation at the wrong store's method doc. BOTH emitting
  # branches are pinned, because they are separate literals: $r8 above takes the derived-fallback branch (205 of
  # today's rows) and $r7f above takes the name-snap branch (2,326 rows), so asserting on only one would leave
  # the other free to revert green. CLEAN TWIN: the mirrored assertion in build-sams-deals.ps1, which must keep
  # saying Sam's - proving this is a store-specific fix and not "delete the word Sam's everywhere".
  if ($r8.row -and $r8.row.qty_basis -match 'Walmart' -and $r8.row.qty_basis -notmatch 'Sam') { Write-Output 'ok    derived-fallback qty_basis credits Walmart, not the store this builder was forked from' }
  else { Write-Output "FAIL  derived-fallback qty_basis names the wrong store: $($r8.row.qty_basis)"; $fail++ }
  if ($r7f -and $r7f.qty_basis -match 'Walmart' -and $r7f.qty_basis -notmatch 'Sam') { Write-Output 'ok    name-snap qty_basis credits Walmart, not the store this builder was forked from' }
  else { Write-Output "FAIL  name-snap qty_basis names the wrong store: $($r7f.qty_basis)"; $fail++ }

  # 8b. THE "/ea" DENOMINATOR THAT IS NOT AN EACH (2026-07-31). All three rows are FROZEN from the live
  #     2026-07-31 Walmart capture (name / linePrice / unitPrice copied verbatim), one per branch.
  #     MUST-FIRE: the achiote row held the CROWN on achiote-paste at $4.64/oz - 12x its real $0.3867/oz -
  #     because "38.7 c/ea" is per OUNCE and the derived 42 was stamped as a COUNT. Drop the branch and this
  #     goes back to '42 ct', which is exactly how the bug shipped.
  $r8d = (Build-Row (_R 'Chef Merito Achiote Condimentado Spiced Annatto Seed Paste, 3.5 oz, (Pack of 12)' '$16.24' ('38.7 ' + [string][char]0x00A2 + '/ea'))).row
  if ($r8d -and $r8d.size -eq '42 oz' -and $r8d.ad_price -eq '$16.24' -and $r8d.qty_basis -match 'proven by name arithmetic') {
    $achOz = Get-UnitPrice ([pscustomobject]@{price_text=$r8d.ad_price;name=$r8d.item;size_text=$r8d.size;regular=$null}) ([pscustomobject]@{unit='oz'})
    if ([math]::Abs($achOz.unit_price - 0.3867) -lt 0.001) { Write-Output ("ok    pack-of-N '/ea' proven to be OUNCES: 12 x 3.5 = 42 oz -> " + [math]::Round($achOz.unit_price,4) + '/oz (shipped as $4.64/oz)') }
    else { Write-Output "FAIL  achiote restamped but prices $($achOz.unit_price)/oz, want 0.3867"; $fail++ }
  } else { Write-Output "FAIL  achiote MUST-FIRE: size='$($r8d.size)' basis='$($r8d.qty_basis)' - want '42 oz' proven by name arithmetic"; $fail++ }
  # CLEAN TWIN: derived 50 equals the stated Pack of 50, so the count is REAL and ct must survive. If the
  # branch were written as "a pack of N is never a count", this row would break.
  $r8e = (Build-Row (_R 'Great Value Uncoated White Paper Plates, 6 Inch, Pack of 50' '$2.12' '$4.24/100 ct')).row
  if ($r8e -and $r8e.size -eq '50 ct' -and $r8e.qty_basis -notmatch 'proven by name arithmetic') { Write-Output "ok    clean twin: derived 50 = Pack of 50, the count is real -> '50 ct' untouched" }
  else { Write-Output "FAIL  paper plates clean twin: size='$($r8e.size)' basis='$($r8e.qty_basis)' - want '50 ct', no restamp"; $fail++ }
  # REJECT: 33 is neither the 12-pack count nor the 384 oz pack total. The store contradicts itself and
  # neither number is publishable - quarantine beats guessing (build-aldi-regular's rule).
  $r8f = Build-Row (_R 'Almond Breeze Almondmilk, Unsweetened Original 32 oz (Pack of 12)' '$54.47' '$1.65/ea')
  if ($r8f.err -and $r8f.err -match 'name/unit-price divergence') { Write-Output "ok    rejects an unprovable pack denominator -> $($r8f.err)" }
  else { Write-Output "FAIL  almond breeze should have been rejected, got size='$($r8f.row.size)'"; $fail++ }

  # 8g. MUST FIRE - A PRINTED WEIGHT THE UNIT PRICE DENIES (2026-09-05). FROZEN from walmart-regular-2026-08-31
  #     (name / linePrice / unitPrice verbatim, item_id 198431752). The name says 1.82 pounds; $17.97 over
  #     Walmart's own "$1.65/lb" derives 10.891 lb, 5.98x more, and nothing in the name is a pack. Published,
  #     this row held the bouillon CROWN at $0.0813/oz against a real $0.6169/oz. It must be refused outright.
  $r8g = Build-Row (_R 'Knorr Select Vegetable Base, Shelf Stable Granulated Bouillon, 1.82 pounds' '$17.97' '$1.65/lb')
  if ($r8g.err -and $r8g.err -match 'REFUSED: name quantity disagrees with unit price, no pack count') {
    Write-Output "ok    refuses a printed weight the unit price denies -> $($r8g.err)"
  } else { Write-Output "FAIL  Knorr Select should have been REFUSED, got size='$($r8g.row.size)' basis='$($r8g.row.qty_basis)'"; $fail++ }
  #     CLEAN TWIN 1: the disagreement IS explained by a pack the name states in a wording the snap parser
  #     never had ("Pack of 24"). 24 x 16.9 = 405.6, which is the derived 405.5 to within rounding, so the
  #     row publishes exactly as it did before. If the refusal were written without the pack test, every
  #     multipack whose count is spelled this way would leave the board.
  $r8h = (Build-Row (_R '(Pack of 24) Sample Spring Water, 16.9 fl oz' '$8.11' '$0.02/fl oz')).row
  if ($r8h -and $r8h.qty_basis -match 'a pack count in the name explains the multiple') {
    Write-Output "ok    clean twin: 'Pack of 24' explains the multiple -> size='$($r8h.size)'"
  } else { Write-Output "FAIL  Pack-of-24 twin was refused or unexplained: size='$($r8h.size)' basis='$($r8h.qty_basis)' $($r8h.err)"; $fail++ }
  #     CLEAN TWIN 2: the name is SILENT in the priced unit, so there is no disagreement to refuse and the
  #     derived quantity is all we have. This is the 7e shape at a weight unit (Hefty's "13 Gallon" bags).
  $r8i = (Build-Row (_R 'Great Value Boneless Skinless Chicken Thighs, Value Pack' '$10.00' '$2.00/lb')).row
  if ($r8i -and $r8i.size -eq '5 lb') { Write-Output "ok    clean twin: a name silent in the priced unit still publishes on lp/up -> '5 lb'" }
  else { Write-Output "FAIL  silent-name weight row: size='$($r8i.size)'"; $fail++ }
  #     CLEAN TWIN 3: the name agrees to within Walmart's cent rounding but not to the strict snap. 10.5 vs
  #     a derived 10.866 is 3.4% - rounding, not a contradiction - and must publish, or the refusal deletes
  #     correct rows for being imprecise.
  $r8j = (Build-Row (_R 'Sample Harissa Paste, 10.5 oz' '$8.91' '$0.82/oz')).row
  if ($r8j -and $r8j.ad_price -eq '$8.91') { Write-Output "ok    clean twin: a name within rounding of lp/up still publishes -> size='$($r8j.size)'" }
  else { Write-Output "FAIL  rounding twin refused: $($r8j.size)"; $fail++ }
  #     CLEAN TWIN 4: THE COUNT PATH IS UNTOUCHED. Case 8 above ('Bogus Beans, 99 ct.') is a frozen fixture
  #     ruling that a count the arithmetic denies falls back to lp/up. This scoping note is here so that a
  #     later reader does not "finish the job" by extending the refusal to counts and silently retire it.
  $r8k = Build-Row (_R 'Bogus Beans, 99 ct.' '$3.27' '$1.09/ea')
  if ($r8k.row -and $r8k.row.size -eq '3 ct') { Write-Output 'ok    clean twin: the COUNT path still trusts lp/up (case 8 unchanged)' }
  else { Write-Output "FAIL  the refusal leaked into the count path: $($r8k.err)"; $fail++ }

  # 9. rows the engine cannot price are REJECTED, not published
  foreach ($bad in @(@{r=(_R 'No Unit Price Item' '$5.00' ''); l='missing unitPrice'},
                     @{r=(_R 'Weird Unit' '$5.00' '$1.00/sqft'); l='unknown unit'})) {
    $x = Build-Row $bad.r
    if ($x.err) { Write-Output "ok    rejected $($bad.l) -> $($x.err)" } else { Write-Output "FAIL  $($bad.l) should have been rejected"; $fail++ }
  }

  # 10. THE POINT OF THE WHOLE SCRIPT: prove the emitted cucumber row prices to 1.09/each, and that the
  #     OLD (quarantined) shape prices the same product to 0.3633.
  $good = (Build-Row (_R 'Seedless English Cucumbers, 3 ct.' '$3.27' '$1.09/ea')).row
  $ge = Get-UnitPrice ([pscustomobject]@{ price_text=$good.ad_price; name=$good.item; size_text=$good.size; regular=$null }) ([pscustomobject]@{ unit='each' })
  $old = Get-UnitPrice ([pscustomobject]@{ price_text='$1.09'; name='Seedless English Cucumbers, 3 ct.'; size_text='each'; regular=$null }) ([pscustomobject]@{ unit='each' })
  if ([math]::Abs($ge.unit_price - 1.09) -lt 0.005) { Write-Output ("ok    emitted row prices to " + [math]::Round($ge.unit_price,4) + "/each [" + $ge.basis + "]  (quarantined shape gave " + [math]::Round($old.unit_price,4) + " [" + $old.basis + "])") }
  else { Write-Output "FAIL  emitted cucumber row -> $($ge.unit_price)"; $fail++ }

  # 11. THE 2026-07-23 MULTIPACK FILTER. The exact junk that flooded the inbox must be REJECTED, and a real
  #     single-buy unit must be KEPT. This is what stops the builder from producing what guard 5 blocks.
  $mpReject = @(
    @{ n='(4 pack) Domino Premium Pure Cane Granulated Sugar, 10 lb'; s='640 oz' }  # 40 lb bulk case
    @{ n='(8 pack) Gold Medal All Purpose Flour, 5 lb Bag';           s='640 oz' }  # 40 lb bulk case
    @{ n="Great Value Vanilla Ice Cream Sandwiches, 42 fl oz, 12 Pack"; s='42 fl oz' }  # novelty multipack
  )
  foreach ($m in $mpReject) {
    if (BW-IsMultipackReject $m.n $m.s) { Write-Output "ok    rejects bulk multipack: $($m.n.Substring(0,[Math]::Min(38,$m.n.Length)))" }
    else { Write-Output "FAIL  did NOT reject multipack '$($m.n)' - the 2026-07-23 junk would ship"; $fail++ }
  }
  $mpKeep = @(
    @{ n='Great Value Granulated Sugar, 4 lb'; s='4 lb' }                              # real single unit
    @{ n='(12 pack) Great Northern Beans, 15.5 oz'; s='186 oz' }                       # size IS the arithmetic pack total -> keep
  )
  foreach ($m in $mpKeep) {
    if (-not (BW-IsMultipackReject $m.n $m.s)) { Write-Output "ok    keeps legit unit: $($m.n.Substring(0,[Math]::Min(38,$m.n.Length)))" }
    else { Write-Output "FAIL  wrongly rejected '$($m.n)' - real product would vanish"; $fail++ }
  }

  # ---- THE SHELF SIGNAL carries through, and ABSENCE IS UNKNOWN (2026-08-29).
  # The whole safety property of adding sel/ff is that a capture written before the SKILL emitted them
  # must behave EXACTLY as it did yesterday. The 90-day union is full of those, so if absence read as
  # "shipped" the board would lose most of its Walmart cells the moment anything gated on it.
  $csvNew = Join-Path $env:TEMP ('bw-shelf-new-' + [Guid]::NewGuid().ToString('N') + '.csv')
  $csvOld = Join-Path $env:TEMP ('bw-shelf-old-' + [Guid]::NewGuid().ToString('N') + '.csv')
  try {
    # 9-column shape (post-2026-08-29 SKILL) and the 7-column shape that predates it, same product.
    @('q|n|lp|up|id|was|rb|sel|ff',
      'oregano|Frontier Co-op Oregano Leaf Organic, 16 oz|$15.12|94.5 c/oz|111|||Walmart.com|SHIP') |
      Set-Content -LiteralPath $csvNew -Encoding UTF8
    @('q|n|lp|up|id|was|rb',
      'oregano|Frontier Co-op Oregano Leaf Organic, 16 oz|$15.12|94.5 c/oz|111||') |
      Set-Content -LiteralPath $csvOld -Encoding UTF8
    $rowsNew = @(Import-CaptureCsv -Path $csvNew)
    $rowsOld = @(Import-CaptureCsv -Path $csvOld)
    if ([string]$rowsNew[0].sel -eq 'Walmart.com' -and ([string]$rowsNew[0].ff).ToUpper() -eq 'SHIP') {
      Write-Output 'ok    a 9-column capture carries seller + fulfillment through the reader'
    } else { Write-Output "FAIL  9-column capture lost sel/ff (sel='$($rowsNew[0].sel)' ff='$($rowsNew[0].ff)')"; $fail++ }
    if ([string]$rowsOld[0].sel -eq '' -and [string]$rowsOld[0].ff -eq '') {
      Write-Output 'ok    a 7-column capture reads sel/ff as EMPTY, which downstream must treat as unknown - not as shipped'
    } else { Write-Output "FAIL  7-column capture invented sel/ff (sel='$($rowsOld[0].sel)' ff='$($rowsOld[0].ff)')"; $fail++ }
    # And the ROW must carry them, because the reader seeing them is worth nothing if the builder drops them.
    $src2 = Get-Content $PSCommandPath -Raw
    if ($src2 -match '(?m)^\s*seller\s*=\s*\[string\]\$raw\.sel' -and $src2 -match '(?m)^\s*fulfillment\s*=') {
      Write-Output 'ok    the emitted row carries seller + fulfillment'
    } else { Write-Output 'FAIL  the row object does not carry seller/fulfillment - the signal stops at the reader'; $fail++ }
  } finally {
    foreach ($t in @($csvNew, $csvOld)) { if (Test-Path $t) { Remove-Item $t -Force -ErrorAction SilentlyContinue } }
  }

  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS' ; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

# ---------------------------------------------------------------- build
if (-not $In -or -not (Test-Path $In)) { throw "${Me}: -In not found: $In" }
if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
$raw = Import-CaptureCsv -Path $In -Delimiter '|'   # UTF-8 + repairs names mangled by an upstream ANSI read
if ($script:CaptureRepairCount -gt 0) { Write-Output ("  repaired $($script:CaptureRepairCount) mangled field(s) on ingest (UTF-8 read as ANSI upstream)") }
$rows = New-Object System.Collections.Generic.List[object]
$rejects = New-Object System.Collections.Generic.List[object]
# THE ROLLBACK WINDOW (2026-08-21). Brad: a rollback gets "a 30 day TTL from when we first detect".
# Walmart publishes no end date for one - measured on a live search, the ROLLBACK badge carries six keys
# and not one is temporal, promoData is Affirm financing, promoDiscount null - so the window is ours to
# anchor, and the anchor MUST be the first sighting. A rollback is re-observed on every capture covering
# its term, so re-stamping today+30 each time would push the expiry forward forever: a 30-day rule that
# silently means never. rollback-ttl-lib owns that rule and refuses to re-anchor one it has seen before.
# Inert until the capture actually carries a was-price, so an older CSV is unaffected.
. (Join-Path $root 'rollback-ttl-lib.ps1')
$rollbacks = 0
foreach ($r in $raw) {
  $b = Build-Row $r
  if ($b.row) {
    # ONE implementation, three callers (rollback-ttl-lib). This was ten inline lines here and ten more in
    # build-sams-deals; import-walmart-batch is the third caller and got none of it.
    if (Set-RollbackFields -Row $b.row -Was $r.was -Store 'Walmart' -ItemId ([string]$r.id) -Date $script:CaptureDate -Root $root) { $rollbacks++ }
    $rows.Add($b.row)
  } else { $rejects.Add([pscustomobject]@{ name=$r.n; lp=$r.lp; up=$r.up; reason=$b.err }) }
}
[void](Save-RollbackLedger $root)
if ($rollbacks -gt 0) { Write-Output ("${Me}: $rollbacks rollback(s) dated from first detection (" + (Get-RollbackTtlDays) + "-day TTL; Walmart publishes no end date)") }
# de-dupe identical products (the same SKU is returned by several search terms)
$seen = @{}; $ded = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) { $k = $r.item + '|' + $r.ad_price + '|' + $r.size; if (-not $seen.ContainsKey($k)) { $seen[$k]=$true; $ded.Add($r) } }

# drop bulk multipacks / novelties the board should never carry (guard-5 lockstep, above)
$kept = New-Object System.Collections.Generic.List[object]
foreach ($r in $ded) {
  if (BW-IsMultipackReject $r.item $r.size) {
    $rejects.Add([pscustomobject]@{ name=$r.item; lp=$r.ad_price; up=$r.wm_unit_price; reason='multipack: pack priced as a single board unit (guard 5) - not a shopper single-buy unit' })
  } else { $kept.Add($r) }
}
$ded = $kept

$outDir = Join-Path $root 'out\regular'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$outFile = Join-Path $outDir ("walmart-regular-$Date.json")
[ordered]@{
  store      = "Walmart"
  week_of    = $Date
  price_type = 'everyday'
  source     = 'walmart.com in-page __NEXT_DATA__ priceDetails.priceLines (Omaha L St Supercenter 68137); built by build-walmart-deals.ps1, every row verified to reproduce Walmart''s own unitPrice through compare-deals'' real Get-UnitPrice.'
  captured   = $Date
  # HOW COMPREHENSIVE was this pull? Distinct search terms in the raw capture. A full worklist pull runs ~400+
  # terms (commodity-search.json holds 447); a PerimeterX-throttled partial runs ~50. Deal COUNT cannot tell
  # them apart (the 2026-07-23 partial had 1329 deals vs the full pull's 886 - deep on few commodities), so the
  # term count is the machine-readable partial/full marker that audit-walmart-fullpull.ps1 watches. Without it,
  # a string of partials silently ages the last full capture toward the union window's 14-day cliff.
  pull_terms = @($raw | Select-Object -ExpandProperty q -Unique).Count
  deals      = $ded
} | ConvertTo-Json -Depth 6 | Set-Content $outFile -Encoding UTF8

if ($rejects.Count) {
  # NOT "sams-deals-*.rejects.json": compare-deals globs out\sams\sams-deals-*.json to find captures. Today it
  # skips this file only because its BaseName does not end in a date - one refactor of that check away from
  # feeding rejected rows back into the board. Keep the name outside the glob entirely.
  $rj = Join-Path $root ("out\walmart-rejects-$Date.json")
  $rejects | ConvertTo-Json -Depth 4 | Set-Content $rj -Encoding UTF8
}
Write-Output ("${Me}: {0} raw -> {1} priced ({2} after de-dupe), {3} rejected -> {4}" -f $raw.Count, $rows.Count, $ded.Count, $rejects.Count, (Split-Path $outFile -Leaf))
if ($rejects.Count) {
  Write-Output "  reject reasons:"
  $rejects | Group-Object { ($_.reason -split ':')[0] -replace '\d+','N' } | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { Write-Output ("   {0,4}x {1}" -f $_.Count, $_.Name) }
}


# ---------------------------------------------------------------------------
# ADVANCE THE QUARTERLY ROTATION CURSOR (2026-08-21).
# The capture only counts once it has become a priced file, so the commit belongs
# here rather than in the browser agent that fetched it - the same placement rule
# the placeholder-name guard follows. Step-CaptureCursor re-checks that the file
# really landed and holds rows, so this cannot advance on an empty build.
# Never fatal: a cursor that fails to move costs one repeated slice tomorrow,
# while a builder that dies after writing its rows costs the rows.
if (-not $SelfTest) {
  try {
  & (Join-Path $PSScriptRoot 'commit-capture-cursor.ps1') -Store 'Walmart' -Date $Date | Write-Output
  } catch { Write-Warning ("cursor commit skipped: " + $_.Exception.Message) }
}
