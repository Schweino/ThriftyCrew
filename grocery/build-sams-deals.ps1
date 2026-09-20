<#
  build-sams-deals.ps1 - turn a RAW Sam's browser capture into out\sams\sams-deals-<date>.json.

  Input CSV (pipe-delimited, from the in-page pull): q|n|lp|up|id|was|ful, opened by a #tc-store line
     q  = the search term        n  = product name
     lp = priceInfo.linePrice    ("$3.27")  - the price of the whole pack
     up = priceInfo.unitPrice    ("$1.09/ea") - Sam's OWN price per unit of measure
     id = usItemId
     was = the strikethrough price, when there is one (rollback TTL)
     ful = the item's fulfillmentSummary as fulfillment@storeId (2026-09-19; see Get-SamsChannel). Optional:
           a capture older than it has no column and every row's channel is '' (unknown).

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
  checked against the REAL Get-UnitPrice, from the pricing-math-lib.ps1 the engine itself dot-sources: engine(row) must equal Sam's own
  unitPrice. A row that fails is NOT published - it is written to the .rejects.json beside the output. This is
  what the quarantined capture had no way to detect.

  Usage: .\build-sams-deals.ps1 -In <capture.csv> -Date 2026-07-17
         .\build-sams-deals.ps1 -SelfTest
#>
param(
  [string]$In = "",
  [string]$Date = "",
  [switch]$SelfTest,
  # -OutDir and -NoCursor exist for the self-test's end-to-end child ONLY (case 11): it builds a fixture capture
  # into a temp directory, and must neither write out\sams nor advance the live Sam's rotation cursor.
  [string]$OutDir = "",
  [switch]$NoCursor,
  # -LedgerRoot is the same kind of parameter (2026-09-19): the directory holding rollback-first-seen.json. It
  # defaults to this folder, the live ledger. The self-test child points it at a temp directory, because -OutDir
  # never moved the ledger and a fixture row with a was-price would otherwise write the LIVE rollback ledger.
  [string]$LedgerRoot = "",
  # -WaiveMissingStoreLine (2026-09-18, backlog I124) is for RE-BUILDING a capture written BEFORE the #tc-store line
  # existed, and nothing else. It waives the no-store-line refusal only: a store line that is present and wrong
  # (another city, UNRECORDED, two clubs, unparseable) is refused exactly as without it. The file it writes says
  # the club was NOT RECORDED, never a club. The daily build never passes it.
  [switch]$WaiveMissingStoreLine
)
$ErrorActionPreference = 'Stop'
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\ThriftyCrew\grocery' }
. (Join-Path $root 'capture-lib.ps1')   # UTF-8 capture read + mojibake repair, shared by every builder

# ---- the REAL pricing math: the same library compare-deals.ps1 dot-sources ----
. (Join-Path $root 'pricing-math-lib.ps1')   # I82: the pricing math is a LIBRARY now, not a
# regex cut out of compare-deals.ps1's source. The hand-maintained name list this replaced had
# one failure mode that had already fired: add a function Get-UnitPrice calls, forget to list it
# here, and the lifted copy calls something that does not exist - at RUN time. A dot-source
# cannot have that bug, because the file arrives whole. compare-deals.ps1 -SelfTest (section 30)
# asserts this file dot-sources the library and that the library calls nothing outside itself.
# ENCODING: PS 5.1 decodes a BOM-less script as the ANSI codepage. The library is pure ASCII
# (0 non-ASCII bytes on 2026-09-10), so that costs nothing today; a non-ASCII literal added to it
# needs a BOM or a code-point escape.

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
# The same refusal and the same reasoning live in build-walmart-deals.ps1; both builders lift the same
# engine, so a change to this decision must land in both or the two stores will disagree about a unit.
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
# one that reproduces Sam's own unit price - we do not guess here.
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
  # (\d[\d.]*|\.\d+): Sam's prints leading-dot decimals ("Variety Pack, .98 oz., 46 pk.") and a
  # leading-digit-only pattern reads ".98" as "98" - which turned a 45-oz grits case into a 4,508-oz one
  # and published $0.0023/oz (caught by the sanity band 2026-07-25).
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

# A HUMAN-READ NET SIZE, KEYED AND VERIFIED AGAINST SAM'S OWN ARITHMETIC (2026-09-11, queue 2026-09-10-c8eb72).
# When Sam's prices by a unit its NAME does not state, this builder back-solves the pack size as
# linePrice / unitPrice - and unitPrice is rounded to the cent, so that size is only good to 0.005/unitPrice
# (7.1% at $0.07/oz). For a WEIGHT commodity there is no name-based substitute, because a gallon's weight
# depends on what is in it: "Sweet Baby Ray's Original Barbecue Sauce, 1 gal." is a 1.3 g/ml sauce and is NOT
# 128 oz. The only honest source is somebody reading the label or the PDP specifications, so this file gives
# that reading a keyed home - and the builder refuses a reading that does not reproduce Sam's own printed unit
# price, so a mistyped or mis-unit number cannot ship. No size is ever invented here; an empty file changes
# nothing.
$script:SamsSizeHints = $null
$script:SamsHintNotes = New-Object System.Collections.Generic.List[object]
function Get-SamsSizeHints($rootDir) {
  if ($null -ne $script:SamsSizeHints) { return ,$script:SamsSizeHints }
  $script:SamsSizeHints = @()
  $p = Join-Path $rootDir 'sams-size-hints.json'
  if (Test-Path $p) {
    try {
      # Read explicitly as UTF-8 rather than through Read-JsonFile: this script dot-sources no json-io,
      # and PS 5.1's Get-Content would decode a BOM-less file with the ANSI codepage. ReadAllText with an
      # explicit encoding honours a BOM when there is one and assumes UTF-8 when there is not, which is what
      # every writer of this file produces.
      $doc = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json
      # NO @() AROUND THE READ: in PS 5.1 @($null) counts ONE, so an absent 'hints' key would become a
      # single $null entry and every lookup below would compare against it (ps51-json-array-traps).
      $h = $doc.hints
      if ($null -ne $h) { $script:SamsSizeHints = @($h) }
    } catch { Write-Warning ('build-sams-deals: sams-size-hints.json unreadable (' + $_.Exception.Message + ') - every derived size keeps its quotient') }
  }
  return ,$script:SamsSizeHints
}
# Which hint field belongs to which priced unit. A hint stated in a unit Sam's did not price by cannot be
# checked against Sam's arithmetic at all, so it is reported rather than silently ignored.
$script:SamsHintFieldUnit = @{ 'net_oz' = 'oz'; 'net_floz' = 'fl oz'; 'net_lb' = 'lb'; 'net_ct' = 'ct' }
# ---- HOW THE ROW CAN BE BOUGHT AT THE CLUB (2026-09-19, PLAN-board-accuracy-2026-09-19 section 4e) -------------
# The founding bug: Sam's captures recorded NO fulfilment at all, so ship-only products held in-club board cells -
# Member's Mark Foodservice Honey Mustard 128 oz, Member's Mark White Sesame Seed 20.5 oz, Magnolia Sweetened
# Condensed Milk 6 pk and Gerber 2nd Foods 30 ct were each "pickup NOT_AVAILABLE" at the Omaha club on 2026-09-19.
# The `ful` column is the search payload's item.fulfillmentSummary reduced to fulfillment@storeId, in payload order
# (pull-sams-instore.js samsFulfillment, which records the live values seen). The ruling, per row:
#   any PICKUP@<club>                     -> channel 'in-store',  fulfillment 'STORE'
#   every entry SHIPPING@<node>           -> channel 'ship-only', fulfillment 'FC'
#   anything else                         -> channel '' (unknown), no fulfillment field
# "Anything else" is: no column (a capture older than the field), '' (the item carried no summary), 'NONE' (an empty
# summary - every one seen was OUT_OF_STOCK), and DELIVERY without PICKUP (club delivery, which proves a club source
# but not a shopper's in-club purchase; never seen on its own in the 24-item sample, so not ruled on).
# WHY `fulfillment` TOO: it is the word compare-deals' channel gate (instore-lib.ps1 Get-ChannelVerdict) already
# reads for every store - STORE admits, any other word refuses - so a ship-only Sam's row is refused on the board by
# the gate that refuses Walmart's FC rows, with no engine change. 'FC' because that is the gate's word for "shipped
# from a fulfilment centre", which is what SHIPPING@6279 is. A row with channel '' gets NO fulfillment field, so a
# capture older than `ful` stays exactly as it was (the gate's NO-SIGNAL); inside a capture that DOES carry the
# field, the gate refuses a blank as BLANK-IN-FIELD-BEARING-CAPTURE, which for an out-of-stock row is the truth.
# The raw summary rides on the row as sams_fulfillment, so the evidence behind every verdict stays on disk.
function Get-SamsChannel([string]$ful) {
  $f = ('' + $ful).Trim()
  $none = @{ channel = ''; fulfillment = '' }
  if (-not $f -or [string]::Equals($f, 'NONE', [StringComparison]::Ordinal)) { return $none }
  $kinds = @()
  foreach ($tok in ($f -split ',')) {
    $k = (($tok -split '@')[0]).Trim().ToUpperInvariant()
    if ($k) { $kinds += $k }
  }
  if ($kinds.Count -eq 0) { return $none }
  if ($kinds -contains 'PICKUP') { return @{ channel = 'in-store'; fulfillment = 'STORE' } }
  $allShip = $true
  foreach ($k in $kinds) { if ($k -ne 'SHIPPING') { $allShip = $false } }
  if ($allShip) { return @{ channel = 'ship-only'; fulfillment = 'FC' } }
  return $none
}

# ---- A TOTAL COUNT THE NAME STATES OUTRIGHT (2026-09-19) --------------------------------------------------------
# The founding row: "Clorox Disinfecting Cleaning Wipes ... Pack of 5, 425 Wipes Total" at $18.78, $0.04/ea was
# sized 470 ct. "Pack of 5" is not a count Get-NameQtyCandidates reads and "425 Wipes Total" names its unit as a
# product word, so the name looked SILENT and the cent-rounded quotient 18.78/0.04 = 469.5 stood. A name that says
# "<N> <word> Total" (or "<N> ct total", "<N> total") is stating the pack's total count outright, so for a
# count-priced row it is the ONLY candidate: it still has to reproduce Sam's own unit price (18.78/425 = 0.0442,
# which displays as $0.04), and a total that does not is a NAME CONFLICT reject like any other, never published.
# A measure word before "total" ("64 oz total") is a weight, not a count, and is ignored here. And "total" must END
# the phrase: "Similac 360 Total Care" is a brand. Over the 3,632 distinct names in the 34 sams-deals files on disk
# on 2026-09-19 the unanchored form matched 9: the Clorox founding row, two Kleenex "... 867 Tissues total" (sized
# 999 ct from the rounded $0.02/ea; 19.98/867 displays as $0.02, so 867 is the better reading) and six Similac
# "360 Total Care" names. The anchor keeps the first three and drops the six (all six are priced per oz, so the
# count-only rule would not have reached them today; a per-each Similac listing would have been a false reject).
function Get-NameStatedTotal([string]$name) {
  if (-not $name) { return $null }
  $m = [regex]::Match($name.ToLowerInvariant(), '(?<![\d.])(\d[\d,]*)\s*(?:(?:ct|count)\.?|(?!(?:fl|oz|ounces?|lbs?|pounds?|gal|gallons?|ml|l|liters?|g|grams?|kg|pk|packs?|qt|pt)\b)[a-z][a-z''-]*)?\s+total\b(?!\s*[a-z0-9&])')
  if (-not $m.Success) { return $null }
  $v = 0.0
  if (-not [double]::TryParse(($m.Groups[1].Value -replace ',', ''), [ref]$v) -or $v -le 0) { return $null }
  return $v
}

# Build ONE engine-shaped row from a raw capture row. Returns @{row=..; err=..}
# $Club is the club the capture's #tc-store line says the rows were read at (Read-SamsCapture); '' only under
# -WaiveMissingStoreLine. It names the row's store_id and source_ad - never a literal (2026-09-19).
function Build-Row($raw, [string]$Club = '') {
  $lpm = [regex]::Match(("" + $raw.lp), '\$\s*([\d,]+(?:\.\d{1,2})?)')
  if (-not $lpm.Success) { return @{ err='no linePrice' } }

  # SAM'S PRINTS A SUB-DOLLAR UNIT PRICE IN CENTS SINCE 2026-09-20: "92.8 c/lb", not "$0.93/lb". A
  # dollars-only regex here rejected every one of them as 'no unitPrice' - and upstream the capture agent's
  # row contract threw on the shape, so 6 of 8 terms that day never reached this file at all. Projected
  # onto the last full sweep, the cents form is 5,264 of 7,410 priced rows (71.0%).
  # ONE COPY OF THE ARITHMETIC: pricing-math-lib owns the reading, because compare-deals must read the same
  # string the same way when it recomputes the rounding band on the way onto the board.
  # $upRead.halfUlp is the ROUNDING BOUND THIS PARTICULAR NUMBER WAS PRINTED TO, not a constant. It is
  # 0.005 for the two-decimal dollar form every historical row uses, and 0.0005 for the one-decimal cents
  # form - and it must be carried, because every use of it below is a window inside which a size is
  # believed. See the long note in pricing-math-lib.ps1.
  $upRead = Get-SamsUnitPriceReading ("" + $raw.up)
  if ($null -eq $upRead) { return @{ err='no unitPrice' } }
  $lp = [double]($lpm.Groups[1].Value -replace ',','')
  $up = [double]$upRead.value
  if ($lp -le 0 -or $up -le 0) { return @{ err='zero price' } }
  $u = Resolve-Unit $upRead.unit
  if (-not $u) { return @{ err=('unknown unit "' + $upRead.unit + '"') } }

  # The unit price is rounded to its last printed digit, so lp/up is only as good as that rounding: a
  # $0.09/ea item can be off by 0.005/0.09 = 5.6% before anything is wrong, and at $0.01/ea it is off by up
  # to 50%. A cents-form price is printed a digit finer, so its bound is a tenth of that.
  $roundErr = ($upRead.halfUlp / $up)
  # The absolute window a candidate size's implied unit price must land inside to "display as" the unit
  # price Sam's printed. The +0.000001 is the epsilon the hard-coded 0.005001 carried; keeping it means the
  # two-decimal dollar form compares against exactly 0.005001, byte for byte what it did before.
  $upDisplayTol = $upRead.halfUlp + 0.000001

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
  # A KEYED, HUMAN-READ SIZE OUTRANKS THE QUOTIENT - IF IT REPRODUCES SAM'S OWN UNIT PRICE. Keyed on the exact
  # item id AND the exact name, because Sam's re-uses neither loosely and a hint that has drifted off its
  # product must stop applying rather than quietly re-size a different jug. The test is the same one the name
  # candidates face above: lp / hint must display as the unitPrice Sam's printed. A hint that fails it is NOT
  # a reason to reject the row - the row is exactly as good as it was - so it keeps the derived size and the
  # bad reading is reported in the rejects file where a human will see it.
  $hintQty = $null
  foreach ($h in (Get-SamsSizeHints $root)) {
    if ($null -eq $h) { continue }
    if (([string]$h.sams_item_id) -ne ([string]$raw.id)) { continue }
    if (([string]$h.name) -ne ([string]$raw.n)) { continue }
    $hf = @($script:SamsHintFieldUnit.Keys | Where-Object { $null -ne $h.$_ -and ([string]$h.$_) -ne '' })
    if ($hf.Count -ne 1) {
      [void]$script:SamsHintNotes.Add([pscustomobject]@{ name=[string]$raw.n; lp=[string]$raw.lp; up=[string]$raw.up; reason=('BAD HINT: entry for ' + [string]$raw.id + ' states ' + $hf.Count + ' size field(s); exactly one of ' + (($script:SamsHintFieldUnit.Keys | Sort-Object) -join ', ') + ' is required') })
      break
    }
    $want = $script:SamsHintFieldUnit[$hf[0]]
    if ($want -ne [string]$u.tok) {
      [void]$script:SamsHintNotes.Add([pscustomobject]@{ name=[string]$raw.n; lp=[string]$raw.lp; up=[string]$raw.up; reason=('BAD HINT: ' + $hf[0] + ' is a ' + $want + ' reading but Sam''s prices this row by ' + [string]$u.tok + ' - it cannot be checked against Sam''s arithmetic') })
      break
    }
    $hv = 0.0
    if (-not [double]::TryParse(([string]$h.$($hf[0])), [ref]$hv) -or $hv -le 0) {
      [void]$script:SamsHintNotes.Add([pscustomobject]@{ name=[string]$raw.n; lp=[string]$raw.lp; up=[string]$raw.up; reason=('BAD HINT: ' + $hf[0] + "='" + [string]$h.$($hf[0]) + "' is not a positive number") })
      break
    }
    $hErr = [math]::Abs(($lp / $hv) - $up)
    if ($hErr -le $upDisplayTol) { $hintQty = $hv }
    else {
      [void]$script:SamsHintNotes.Add([pscustomobject]@{ name=[string]$raw.n; lp=[string]$raw.lp; up=[string]$raw.up; reason=('BAD HINT: ' + $hf[0] + '=' + $hv + ' gives ' + [math]::Round($lp / $hv, 4) + '/' + [string]$u.tok + ", which does not display as Sam's " + $up + ' - keeping the derived size ' + (Format-Qty $derived)) })
    }
    break
  }
  if ($null -ne $hintQty) {
    $qty = $hintQty
    $basis = 'name hint (reproduces Sam''s unit price)'
  }
  $cands = if ($null -ne $hintQty) { @() } else { Get-NameQtyCandidates $raw.n $u.tok }
  # A stated total ("425 Wipes Total") replaces every other count reading for a count-priced row (see
  # Get-NameStatedTotal). Assigned, then wrapped: the function returns a bare double or $null.
  $statedTotal = $null
  if ($null -eq $hintQty -and $u.tok -eq 'ct') { $statedTotal = Get-NameStatedTotal ([string]$raw.n) }
  if ($null -ne $statedTotal) { $cands = @($statedTotal) }
  $best = $null; $bestErr = [double]::MaxValue
  foreach ($c in $cands) {
    if ($c -le 0) { continue }
    $err = [math]::Abs(($lp / $c) - $up)
    # would display as Sam's up - to the precision Sam's actually PRINTED it to, which is a tenth of a cent
    # on the cents form. A cent-wide window there would accept a size ten times further out than the printed
    # number can justify, and publish a per-unit price off by that much.
    if ($err -le $upDisplayTol -and $err -lt $bestErr) { $best = $c; $bestErr = $err }
  }
  if ($best -and $null -ne $statedTotal) { $qty = $best; $basis = 'name stated total (reproduces Sam''s unit price)' }
  elseif ($best) { $qty = $best; $basis = 'name (reproduces Sam''s unit price)' }
  elseif ($cands.Count) {
    # THE SAZON RULE (2026-07-29). The name STATES a quantity in the very unit Sam's priced by, and NO reading
    # of it reproduces Sam's own unit price. One of the two store numbers is wrong and we cannot tell which:
    # back-solving lp/up published Goya Sazon (a 6.3 oz box of 36 packets) as size 65.429 oz -> $0.07/oz, 8x
    # under every other store, CROWNED the commodity and banked a record low. When the name is SILENT in the
    # priced unit, lp/up is the only measure of the pack and stays trusted (the bulk class - Q-tips, trash
    # bags - where Sam's arithmetic is right); when the name SPEAKS in that unit and disagrees, the row is
    # ambiguous and is REJECTED, never published.
    return @{ err=('NAME CONFLICT: name states ' + (($cands | Select-Object -First 4) -join ', ') + ' ' + $u.tok + ' but none reproduces Sam''s ' + $up + '/' + $u.tok + ' (lp/up derives ' + (Format-Qty $derived) + ')') }
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
  # $roundErr already scales to the precision the unit price was printed to, so the cents form tightens this
  # too. The 0.02 floor is unchanged and dominates for anything but a very cheap per-unit row.
  $tol = [math]::Max(0.02, $roundErr + 0.005)

  # THE NAME'S VOLUME, DECLARED AT INGEST (2026-09-10, queue 2026-09-10-d9e085). A derived row whose name
  # states a gallon / quart / pint / litre that Sam's did not price by ("Member's Mark Ranch Dressing, 1 gal."
  # at "$0.09/oz") carries size = lp/up, a quotient with Sam's cent rounding in it. size and qty_basis stay
  # exactly as they are - they are what reproduces Sam's own unit price, which is this builder's invariant -
  # and the name's volume rides beside them so the engine's preference for it is declared here rather than
  # only re-parsed downstream. Gated on the oz / fl oz tokens: a count-priced row ("Hefty ... 13 Gallon"
  # trash bags at $/ea) names a bag CAPACITY, not contents, and must never gain the field.
  $nameVolFloz = $null
  if ($basis -eq 'derived lp/up' -and -not $cands.Count -and (@('oz', 'fl oz') -contains [string]$u.tok)) { $nameVolFloz = Get-NameVolumeFloz ([string]$raw.n) }

  # TWO CANDIDATE SHAPES, in preference order:
  #  1. PACKAGE  - ad_price = linePrice, size = the pack quantity. Unit-agnostic; what every other feed means.
  #  2. PER-UNIT - ad_price = unitPrice,  size = the bare unit. Required when the NAME carries a per-lb /
  #     per-each marker ("...priced per pound"): Get-ItemPrice scans priceText+nameText, so that marker makes
  #     the engine read whatever ad_price is AS the per-lb price. With the package shape that publishes a
  #     ~4 lb tray at $10.35/LB instead of $2.88/lb - a real, correctly-dated, completely false number.
  # We do not guess which applies: we ask the REAL engine and keep the shape that reproduces Sam's own
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
    if ($diff -gt $tol) { $errs += ($t.shape + ": engine " + [math]::Round($got.unit_price,4) + " vs Sam's " + $up + ' (' + [math]::Round($diff*100) + '% off)'); continue }
    # size_rounding_pct: BELT AND BRACES AT INGEST (2026-09-11, queue 2026-09-10-c8eb72). compare-deals
    # computes the same number from qty_basis + sams_unit_price on the way onto the board, which is what makes
    # the CARRIED 2026-09-01 row work without rewriting a capture. Stamping it here too means every capture
    # written from now on states its own error bar, so anything reading these files directly can see it
    # without re-deriving the rule. ONE copy of the arithmetic: pricing-math-lib owns it.
    # Absent on a row whose size is not a quotient - a name-stated or hinted size has no rounding in it.
    # The unit price AS SAM'S PRINTED IT, cents spelling and all - Get-DerivedRoundingPct reads the notation
    # to know the precision, so normalising it to dollars here would throw away the very thing it needs.
    $szRound = Get-DerivedRoundingPct ($t.shape + '; qty ' + $basis) (("" + $raw.up).Trim())
    $chan = Get-SamsChannel ([string]$raw.ful)
    return @{ row = [pscustomobject]@{
      store     = "Sam's Club"
      item      = [string]$raw.n
      ad_price  = $t.ad
      size      = $t.size
      regular   = $null
      # THE CLUB THE ROW WAS READ AT, never a literal (2026-09-19). This said 'everyday club price (Omaha 68137)'
      # on every row from a literal while the session sat at another club; nothing reads the value, but it is the
      # provenance a reader of the file sees first.
      source_ad = $(if ($Club) { 'everyday club price (' + $Club + ')' } else { 'everyday club price (club NOT RECORDED)' })
      store_id  = $Club
      # HOW IT CAN BE BOUGHT AT THAT CLUB - see Get-SamsChannel. '' is unknown, never in-store.
      channel   = [string]$chan.channel
      sams_fulfillment = [string]$raw.ful
      # PER-ROW as_of (2026-08-07). Sam's rows shipped with no date at all - 1,808 of them - so the whole
      # store opted out of every staleness check silently: the FILE was rewritten each pull while the rows
      # inside aged independently, and audit-row-age.ps1 could not measure a single one. The header's
      # `captured` field is not a substitute, because compare-deals unions slices across 14 days and the
      # merged set then carries one date for prices captured on different days.
      as_of     = $Date
      # THE current_price CONTRACT (guard 10), added 2026-07-23: what the store CHARGES, same basis as
      # ad_price - here the same store-sourced number ad_price was built from (Sam's own lp/up; the emit
      # invariant above proves ad_price reproduces it through the real engine). Guard 10's ad==current check
      # becomes a file-integrity invariant for Sam's rows: an edit/merge/corruption that moves ad_price
      # without current_price hard-fails the gate. Store-truth stays with the capture-time reproduce-invariant.
      current_price = $t.ad
      # Preserve the actual club checkout total independently from the legacy engine-shaped ad/current basis.
      # Per-unit fallback rows still need to bind to Chrome's captured linePrice in the V3 observation model.
      source_checkout_price = ('${0:N2}' -f $lp)
      # Kept for audit; the engine ignores unknown fields. VERBATIM, in the notation Sam's used - this is
      # the field compare-deals re-reads to recompute the rounding band, and the notation IS the precision.
      sams_unit_price = ("" + $raw.up).Trim()
      sams_item_id    = [string]$raw.id
      found_by_term   = [string]$raw.q
      qty_basis       = ($t.shape + '; qty ' + $basis)
      engine_check    = ('' + [math]::Round($got.unit_price,4) + '/' + $u.unit + ' [' + $got.basis + ']')
      taxonomy_path   = [string]$raw.taxonomy_path
      link_url        = [string]$raw.url
      image_url       = [string]$raw.image_url
    } | ForEach-Object { if ($chan.fulfillment) { Add-Member -InputObject $_ -NotePropertyName 'fulfillment' -NotePropertyValue ([string]$chan.fulfillment) }; if ($null -ne $nameVolFloz) { Add-Member -InputObject $_ -NotePropertyName 'name_volume_floz' -NotePropertyValue ([math]::Round([double]$nameVolFloz, 3)) }; if ($null -ne $szRound) { Add-Member -InputObject $_ -NotePropertyName 'size_rounding_pct' -NotePropertyValue ([double]$szRound) }; $_ } }   # name_volume_floz: see THE NAME'S VOLUME above; size_rounding_pct: see BELT AND BRACES above
  }
  return @{ err=("INVARIANT: no shape reproduces Sam's " + $up + '/' + $u.tok + ' -> ' + ($errs -join ' | ')) }
}

# ---- THE CLUB A CAPTURE WAS READ AT (2026-09-18, backlog I124) -------------------------------------------------
# Sam's prices are per-club. samsIdentity() in pull-sams-instore.js has always READ the club off the page and nothing
# kept it, so this file stamped every sams-deals file club="Omaha Sam's Club, 13130 L St, 68137" from a LITERAL -
# while the session had moved to 15429 Blackwell Dr on 2026-08-15 (pull-browser-stores.py's seed_hint). The feed
# declared a club it never read, the aldi-store-is-ola-42 shape, and nothing on disk could say which club a price
# came from. samsSweepToCsv now opens the capture with one line per distinct club the rows were read at:
#     #tc-store store="15429 Blackwell Dr, Omaha, NE 68116" read="page" rows=152
# and this is the one place that line is ruled on. The capture is REFUSED, and nothing is written, when it has:
#   no store line                 it cannot say which club it read (unless -WaiveMissingStoreLine, see param)
#   a store line that won't parse a club we cannot read is a club we did not read
#   store="UNRECORDED"            some rows were persisted by an agent that did not keep the club
#   a store without "Omaha"       another city's club
#   more than one store           one file names one club, and a sweep that straddled two cannot
# THE CLUB IS NEVER PINNED. There are two Omaha clubs and no ruling names one, so the club is RECORDED, which is the
# whole point, and never required - the same call build-aldi-regular makes about the OLA number. Walmart's store is
# pinned because Brad RULED one; Sam's has no ruling, and pinning prose here would refuse a correct capture.
# The read is page text: samsIdentity() falls back to any "Omaha..." line when no street number renders, so a club
# that reads only "Omaha, NE" is recorded as exactly that and names no specific club. That is honest and weaker.
# WHY REFUSE RATHER THAN BUILD AND FLAG: compare-deals unions Sam's slices across 14 days and the cursor advances only
# on a written file, so a refused capture costs one repeated slice; a file written anyway carries a club nobody read.
# Both copies of the line's text live in this file and in pull-sams-instore.js, and test-pull-agent-lib.ps1 pins the
# emitter's exact bytes while this file's self-test pins the parser.
function Split-SamsCaptureStore {
  param([string[]]$Lines)
  $cols = 'q|n|lp|up|id|was'
  $kept   = New-Object System.Collections.ArrayList
  $stores = New-Object System.Collections.ArrayList
  $bad    = New-Object System.Collections.ArrayList
  $sawColumns = $false
  foreach ($ln in $Lines) {
    $s = [string]$ln
    if ($s -match '^\s*#tc-store\b') {
      $m = [regex]::Match($s, '^\s*#tc-store\s+store="([^"]*)"\s+read="([^"]*)"\s+rows=(\d+)\s*$')
      if ($m.Success) { [void]$stores.Add([pscustomobject]@{ store = $m.Groups[1].Value.Trim(); read = $m.Groups[2].Value.Trim(); rows = [int]$m.Groups[3].Value }) }
      else { [void]$bad.Add($s.Trim()) }
      continue
    }
    # A same-day rescue appends a second sweep's output to a copy of the morning capture, header and all
    # ([[same-day-rescue-rebuilds-per-store]]). The second header is not a record. Both the six-column header and the
    # older five-column one are recognised; only an EXACT copy of the first header seen is dropped.
    $t = $s.Trim()
    # 'q|n|lp|up|id|was|ful' is the seven-column header samsSweepToCsv writes since 2026-09-19 (the `ful` channel).
    if ([string]::Equals($t, 'q|n|lp|up|id|was|ful', [StringComparison]::Ordinal) -or [string]::Equals($t, $cols, [StringComparison]::Ordinal) -or [string]::Equals($t, 'q|n|lp|up|id', [StringComparison]::Ordinal)) {
      if ($sawColumns) { continue }
      $sawColumns = $true
    }
    [void]$kept.Add($s)
  }
  # ORDINAL throughout: this text arrived from a web page (ops-and-gates.md, -ne ignores NUL).
  $distinct = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  $total = 0
  $unrec = New-Object System.Collections.ArrayList
  $notOmaha = New-Object System.Collections.ArrayList
  foreach ($x in $stores) {
    [void]$distinct.Add($x.store)
    $total += $x.rows
    if (-not $x.store -or [string]::Equals($x.store, 'UNRECORDED', [StringComparison]::Ordinal)) { [void]$unrec.Add($x) }
    elseif ($x.store -notmatch '(?i)\bOmaha\b') { [void]$notOmaha.Add($x) }
  }
  $why = ''
  if ($bad.Count) {
    $why = ('a store line does not parse: [' + $bad[0] + '] - a club we cannot read is a club we did not read.')
  } elseif ($stores.Count -eq 0) {
    $why = 'the capture carries no #tc-store line, so it cannot say which Sam''s Club it read. Re-capture through samsSweepToCsv in pull-sams-instore.js, which writes one; never hand-assemble this file.'
  } elseif ($unrec.Count) {
    $n = 0; foreach ($x in $unrec) { $n += $x.rows }
    $why = ('{0} row(s) were captured with no club read (store="UNRECORDED"), so they cannot be attributed to any club.' -f $n)
  } elseif ($notOmaha.Count) {
    $why = ('club "{0}" is not an Omaha club.' -f $notOmaha[0].store)
  } elseif ($distinct.Count -gt 1) {
    $why = ('the sweep straddles {0} clubs ({1}) - one file names one club.' -f $distinct.Count, (@($distinct) -join '; '))
  }
  $store = ''; $read = ''
  if (-not $why) { $store = $stores[0].store; $read = $stores[0].read }
  return @{ lines = $kept.ToArray(); store = $store; read = $read; rows = $total; refuse = $why }
}

# The capture exactly as the build consumes it: the store line ruled on FIRST, then the rows read through capture-lib
# from a per-run temp copy holding only the kept lines. One function, so the self-test drives the path the build runs.
# Returns data and prints NOTHING (Import-CaptureCsv's rule); a refusal comes back in .refuse with no row read.
function Read-SamsCapture {
  param([string]$Path, [switch]$WaiveMissingStoreLine)
  $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
  $cs = Split-SamsCaptureStore $lines
  # Waives the MISSING line only, and only when there is no store line at all to disagree with. The text it keys on
  # is pinned by this file's own self-test ('carries no #tc-store line').
  $waived = [bool]($WaiveMissingStoreLine -and $cs.refuse -and $cs.rows -eq 0 -and $cs.refuse.Contains('carries no #tc-store line'))
  if ($cs.refuse -and -not $waived) { return @{ refuse = $cs.refuse; cs = $cs; raw = @(); waived = $false } }
  $tmp = Join-Path $env:TEMP ('sams-capture-clean-' + [guid]::NewGuid().ToString('N') + '.csv')
  try {
    [IO.File]::WriteAllText($tmp, (($cs.lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    $read = Import-CaptureCsv -Path $tmp -Delimiter '|'
  } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  $raw = @($read)
  return @{ refuse = ''; cs = $cs; raw = $raw; waived = $waived }
}

# What the doc-level `club` says. The club READ when there is one; an explicit NOT RECORDED under the waiver.
function Get-SamsClubLabel($cs, [bool]$waived) {
  if ($waived) { return 'club NOT RECORDED in the capture - it predates the #tc-store line, built under -WaiveMissingStoreLine, so the basis of these rows rests on whoever captured them' }
  return [string]$cs.store
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

  # 8. THE SAZON MUST-FIRE (real row, 2026-07-29): the name states 6.3 oz / 36 ct (-> 226.8 oz) in the unit
  #    Sam's priced by and NEITHER reading reproduces Sam's $0.07/oz, so back-solving lp/up invented a
  #    65.429 oz package and published $0.07/oz - 8x under Aldi's $0.5633/oz - crowning the commodity and
  #    banking a record low. Such a row must now REJECT, never publish.
  $r8 = Build-Row (_R 'Goya Sazon Seasoning 6.3 oz., 36 ct.' '$4.58' '$0.07/oz')
  if ($r8.err -and $r8.err -match 'NAME CONFLICT') { Write-Output "ok    sazon conflict rejected -> $($r8.err)" }
  else { Write-Output "FAIL  sazon must reject, got ad=$($r8.row.ad_price) size='$($r8.row.size)'"; $fail++ }
  # 8b. the count flavor of the same conflict (before the Sazon rule this published via the lp/up fallback)
  $r8b = Build-Row (_R 'Bogus Beans, 99 ct.' '$3.27' '$1.09/ea')
  if ($r8b.err -and $r8b.err -match 'NAME CONFLICT') { Write-Output "ok    lying count rejected -> $($r8b.err)" }
  else { Write-Output "FAIL  lying-count row must reject: $($r8b.row.size)"; $fail++ }
  # 8c. KEEP-SIDE TWIN (the bulk class the fallback exists FOR): "13 Gallon" is bag CAPACITY, not a count -
  #     the name states NO quantity in the priced unit (ea), so Sam's own lp/up arithmetic still stands
  #     (18.98/0.09 -> 211 ct) and the row still publishes.
  $r8c = Build-Row (_R 'Hefty Ultra Strong 13 Gallon Kitchen Drawstring Trash Bags' '$18.98' '$0.09/ea')
  if ($r8c.row -and $r8c.row.size -eq '211 ct' -and $r8c.row.qty_basis -match 'derived lp/up') { Write-Output "ok    keep-side: name silent in priced unit -> derived 211 ct kept ($($r8c.row.qty_basis))" }
  else { Write-Output "FAIL  keep-side fallback lost: $($r8c.err)$($r8c.row.size)"; $fail++ }
  # 8d. THE NAME'S VOLUME RIDES BESIDE A DERIVED SIZE (2026-09-10, queue 2026-09-10-d9e085). The founding row,
  #     verbatim from out\sams\sams-deals-2026-09-10.json: Sam's priced the 1-gal. jug per OZ, so the name's
  #     gallon is not a candidate in Sam's unit family and the size is derived (10.98 / 0.09 = 122). The size and
  #     qty_basis must NOT change - they are what reproduces Sam's unit price - and the name's 128 fl oz rides along.
  $r8d = Build-Row (_R "Member's Mark Ranch Dressing, 1 gal." '$10.98' '$0.09/oz')
  if ($r8d.row -and $r8d.row.size -eq '122 oz' -and $r8d.row.qty_basis -match 'derived lp/up' -and $r8d.row.PSObject.Properties['name_volume_floz'] -and ([double]$r8d.row.name_volume_floz -eq 128)) { Write-Output ("ok    MUST FIRE  ranch 1 gal. keeps size '122 oz' and gains name_volume_floz " + $r8d.row.name_volume_floz) }
  else { Write-Output ("FAIL  ranch name volume: err='" + $r8d.err + "' size='" + $r8d.row.size + "' name_volume_floz='" + $r8d.row.name_volume_floz + "'"); $fail++ }
  #     CLEAN TWIN: the Hefty 13 Gallon bags are priced per EACH, so '13 Gallon' is a bag capacity and the field never appears.
  if ($r8c.row -and ($r8c.row.size -eq '211 ct') -and -not $r8c.row.PSObject.Properties['name_volume_floz']) { Write-Output 'ok    CLEAN TWIN  the per-each Hefty 13 Gallon row keeps 211 ct and carries no name_volume_floz' }
  else { Write-Output 'FAIL  a count-priced row gained name_volume_floz from a bag capacity'; $fail++ }
  #     CLEAN TWIN: a name that REPRODUCES Sam's unit price (milk 1 gal. per foz) is name-based, not derived, and carries no field.
  $r8e = Build-Row (_R "Member's Mark 2% Reduced Fat Milk 1 gal." '$3.72' '$0.03/foz')
  if ($r8e.row -and ($r8e.row.size -eq '128 fl oz') -and -not $r8e.row.PSObject.Properties['name_volume_floz']) { Write-Output 'ok    CLEAN TWIN  the milk gallon priced per foz snaps to 128 fl oz from the name and needs no extra field' }
  else { Write-Output ("FAIL  milk 1 gal. size='" + $r8e.row.size + "'"); $fail++ }

  # 8h. SAM'S PRINTS A SUB-DOLLAR UNIT PRICE IN CENTS SINCE 2026-09-20 ------------------------------------
  # "$0.93/lb" became "92.8 c/lb". The capture agent's row contract threw on the shape, so 6 of 8 terms that
  # day settled UNUSABLE; this builder, reached with the rows anyway, rejected every one of them as
  # 'no unitPrice'. Both halves had to move. These are the REAL 2026-09-20 rows.
  # The cent sign is built from its codepoint: a literal glyph in this .ps1 is a non-ASCII byte in a file
  # PS 5.1 reads as ANSI, and the script then fails to PARSE.
  $CentSign = [string][char]0x00A2
  $r8h1 = Build-Row (_R 'Sweet Onions, 6 lbs.' '$5.57' ('92.8 ' + $CentSign + '/lb'))
  if ($r8h1.row -and $r8h1.row.size -eq '6 lb' -and $r8h1.row.ad_price -eq '$5.57') { Write-Output "ok    8h MUST FIRE  the cents form prices at all: sweet onions -> 6 lb (was 'no unitPrice')" }
  else { Write-Output ("FAIL  8h cents form still rejected: err='" + $r8h1.err + "' size='" + $r8h1.row.size + "'"); $fail++ }
  # The unit price is kept VERBATIM, in Sam's own notation - compare-deals re-reads this field to recompute
  # the rounding band, and the notation IS the precision. Normalising it here would throw that away.
  if ($r8h1.row -and $r8h1.row.sams_unit_price -eq ('92.8 ' + $CentSign + '/lb')) { Write-Output 'ok    8h the row keeps the printed unit price verbatim, cents spelling and all' }
  else { Write-Output ("FAIL  8h sams_unit_price was rewritten: '" + $r8h1.row.sams_unit_price + "'"); $fail++ }
  # MUST FIRE on the quiet half. A cents-form unit price used to return NO rounding band at all from
  # Get-DerivedRoundingPct - not a wide one, NONE - which makes Get-CellRoundingPct null, Get-RoundingBandTies
  # empty, and THE CROWN TEST silently skipped: the board would rank a back-solved size as an exact number.
  # 0.0005/0.452 = 0.11%, where the old hard-coded cent would have claimed 1.11%.
  $r8h2 = Build-Row (_R "Member's Mark by FujiSan Cucumber Avocado Roll, 15 pcs." '$5.74' ('45.2 ' + $CentSign + '/oz'))
  $h2pct = if ($r8h2.row) { $r8h2.row.size_rounding_pct } else { $null }
  if ($r8h2.row -and $r8h2.row.qty_basis -match 'derived lp/up' -and $null -ne $h2pct -and [math]::Abs([double]$h2pct - 0.11) -lt 0.005) {
    Write-Output ("ok    8h MUST FIRE  a DERIVED cents row states its rounding band (" + $h2pct + "%), so the crown test is not skipped")
  } else { Write-Output ("FAIL  8h derived cents row band: err='" + $r8h2.err + "' basis='" + $r8h2.row.qty_basis + "' pct='" + $h2pct + "'"); $fail++ }
  # CLEAN TWIN: the same row printed the OLD way keeps the cent-wide band it always had. This is what proves
  # the precision is read from the NOTATION rather than applied to everything.
  $r8h3 = Build-Row (_R "Member's Mark by FujiSan Cucumber Avocado Roll, 15 pcs." '$5.74' '$0.45/oz')
  $h3pct = if ($r8h3.row) { $r8h3.row.size_rounding_pct } else { $null }
  if ($null -ne $h3pct -and [math]::Abs([double]$h3pct - 1.11) -lt 0.005) { Write-Output ("ok    8h CLEAN TWIN  the dollar form still carries its cent-wide band (" + $h3pct + "%)") }
  else { Write-Output ("FAIL  8h dollar-form band moved: pct='" + $h3pct + "'"); $fail++ }

  # 8i. THE BAR ITSELF, AND ONE STEP PAST IT (Brad's ruling, 2026-09-19, backlog I196) ----------------------
  # The bar is "does the name's size reproduce the unit price Sam's PRINTED, to the precision it printed it
  # to" - half of the last printed digit, which is 0.0005 for a one-decimal cents price and 0.005 for the
  # two-decimal dollar form. A threshold detector's suite owes a case exactly AT the bar and one a step PAST
  # it, and names the bar in the case text.
  # ALL THREE CASES ARE ONE REAL ROW off the 2026-09-20 capture - Taylor Farms Sweet Kale Chopped Salad Kit,
  # 12 oz. at $2.97 - with nothing changing but the NOTATION Sam's printed its unit price in. That is what
  # makes the trio a statement about the rule rather than about three unrelated fixtures.
  # The numbers land exactly, which the same ruling insists on after a case that failed by 8e-16: 2.97/12 is
  # 0.2475, and 0.2475 sits EXACTLY HALFWAY between the two printable tenth-cent values 24.7 and 24.8, so
  # the miss against either is exactly 0.0005 - the bar - and the +0.000001 epsilon leaves 1e-6 of headroom
  # against a double error of order 1e-17.
  $kaleName = 'Taylor Farms Sweet Kale Chopped Salad Kit, 12 oz.'
  $r8i1 = Build-Row (_R $kaleName '$2.97' ('24.8 ' + $CentSign + '/oz'))
  if ($r8i1.row -and $r8i1.row.size -eq '12 oz' -and $r8i1.row.qty_basis -match 'name') { Write-Output 'ok    8i AT THE BAR  2.97/12 = 0.2475 misses the printed 0.248 by exactly 0.0005 = the bar: ACCEPTED' }
  else { Write-Output ("FAIL  8i at-the-bar case: err='" + $r8i1.err + "' size='" + $r8i1.row.size + "' basis='" + $r8i1.row.qty_basis + "'"); $fail++ }
  # ONE STEP PAST, where the step is one unit of the comparison's own resolution - one tenth of a cent on the
  # printed value. 24.9 puts the miss at 0.0015. The name states a size in the priced unit and no reading of
  # it reproduces Sam's number, so the Sazon rule applies: REJECTED, never published on an ambiguous size.
  $r8i2 = Build-Row (_R $kaleName '$2.97' ('24.9 ' + $CentSign + '/oz'))
  if (-not $r8i2.row -and ([string]$r8i2.err) -match 'NAME CONFLICT') { Write-Output 'ok    8i A STEP PAST  one tenth-cent further out, the miss is 0.0015 > 0.0005: refused as a NAME CONFLICT' }
  else { Write-Output ("FAIL  8i step-past case was accepted: err='" + $r8i2.err + "' size='" + $r8i2.row.size + "'"); $fail++ }
  # AND THE BAR FOLLOWS THE NOTATION, WHICH IS THE WHOLE RULE. Printed the OLD way the very same row misses
  # by 0.0025 - FIVE times the cents-form bar - and is accepted, because a two-decimal dollar price only
  # claims to be right to the cent. Without this case a revert to the hard-coded 0.005 would leave the
  # at-the-bar case green and redden only the step-past one, which reads as a bad fixture rather than a
  # lost rule.
  $r8i3 = Build-Row (_R $kaleName '$2.97' '$0.25/oz')
  if ($r8i3.row -and $r8i3.row.size -eq '12 oz' -and $r8i3.row.qty_basis -match 'name') { Write-Output 'ok    8i CLEAN TWIN  the SAME row printed as $0.25/oz misses by 0.0025 and is accepted: the bar is the notation''s' }
  else { Write-Output ("FAIL  8i dollar-form bar tightened: err='" + $r8i3.err + "' basis='" + $r8i3.row.qty_basis + "'"); $fail++ }

  # 8j. A SHAPE WE CANNOT READ IS A PER-ROW REJECT, NEVER A GUESS -------------------------------------------
  # walmart-row-lib.ps1 accepts any 1-3 non-digit characters where the cent sign goes, which would read this
  # as $0.0020/oz - a silent hundredfold basis error on a live paid board. Refusing costs one row.
  $r8j = Build-Row (_R 'Fixture Thing, 1 ct.' '$1.00' '0.20 USD/oz')
  if (-not $r8j.row -and ([string]$r8j.err) -eq 'no unitPrice') { Write-Output 'ok    8j MUST FIRE  an unknown currency token is rejected per-row, never divided by 100' }
  else { Write-Output ("FAIL  8j unknown currency token was priced: err='" + $r8j.err + "' size='" + $r8j.row.size + "'"); $fail++ }
  # CLEAN TWIN: a blank unit price is still the ordinary per-row reject it always was, unchanged.
  $r8k = Build-Row (_R 'Fixture Thing, 1 ct.' '$1.00' '')
  if (-not $r8k.row -and ([string]$r8k.err) -eq 'no unitPrice') { Write-Output 'ok    8j CLEAN TWIN  a blank unit price is still the same per-row reject' }
  else { Write-Output ("FAIL  8j blank up changed behaviour: err='" + $r8k.err + "'"); $fail++ }

  # CLEAN TWIN of build-walmart-deals.ps1's wrong-store assertion (2026-07-30). The Walmart fork inherited this
  # file's store noun into its published qty_basis; the fix there was to name Walmart. This proves the correction
  # is store-specific rather than a blanket scrub - THIS builder must go on crediting Sam's. $r7f (above) is the
  # name-snap row, the ONLY branch that still stamps a store noun here since the Sazon rule turned the derived
  # fallback into a reject, so a future fork that copies the Walmart wording back over this file fails here
  # instead of shipping silently. ($r8c takes the derived branch and stamps no store at all, so asserting on it
  # would pass either way - a gate that could never arm.)
  if ($r7f -and $r7f.qty_basis -match "Sam" -and $r7f.qty_basis -notmatch 'Walmart') { Write-Output "ok    qty_basis still credits Sam's, not the store this builder was forked TO ($($r7f.qty_basis))" }
  else { Write-Output "FAIL  qty_basis names the wrong store: $($r7f.qty_basis)"; $fail++ }

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

  # ---- case 8f/8g/8h: THE DERIVED SIZE'S ERROR BAR, AND THE VERIFIED SIZE HINT ----------------------
  # (2026-09-11, queue 2026-09-10-c8eb72.) Frozen by hand from the real carried Sam's row that holds the
  # bbq-sauce crown on comparison-2026-09-11. $script:SamsSizeHints is set directly so these cases never read
  # the live sams-size-hints.json: a fixture that read the shipping file would pass by finding nothing the day
  # somebody empties it.
  $rawSBR = [pscustomobject]@{ n="Sweet Baby Ray's Original Barbecue Sauce, 1 gal."; lp='$11.98'; up='$0.07/oz'; id='4W2VMU21D4SI'; q='bbq sauce' }
  # 8f MUST FIRE: no hint. 11.98 / 0.07 = 171.143, and the row must SAY that the size is a quotient good to
  # 0.005/0.07 = 7.14% - the error bar that is wider than the 6% margin this row wins its crown by.
  $script:SamsSizeHints = @(); $script:SamsHintNotes.Clear()
  $r8f = Build-Row $rawSBR
  if ($r8f.row -and [string]$r8f.row.size -eq '171.143 oz' -and [string]$r8f.row.qty_basis -eq 'package; qty derived lp/up' -and $null -ne $r8f.row.size_rounding_pct -and [math]::Abs([double]$r8f.row.size_rounding_pct - 7.14) -lt 0.005) {
    Write-Output 'ok    8f SBR derived size 171.143 oz carries size_rounding_pct 7.14'
  } else { Write-Output ("FAIL  8f SBR derived: err='" + $r8f.err + "' size='" + $r8f.row.size + "' basis='" + $r8f.row.qty_basis + "' pct='" + $r8f.row.size_rounding_pct + "'"); $fail++ }
  # 8g MUST FIRE: a human-read 160 oz REPRODUCES Sam's printed $0.07/oz (11.98/160 = 0.0749, which displays as
  # $0.07), so it replaces the quotient, the row says where the size came from, and the rounding field is GONE
  # because a read size has no rounding in it.
  $script:SamsSizeHints = @([pscustomobject]@{ sams_item_id='4W2VMU21D4SI'; name="Sweet Baby Ray's Original Barbecue Sauce, 1 gal."; net_oz=160; source='label'; reviewed='2026-09-11' })
  $script:SamsHintNotes.Clear()
  $r8g = Build-Row $rawSBR
  $g8size  = [string]$r8g.row.size
  $g8basis = [string]$r8g.row.qty_basis
  $g8eng   = [string]$r8g.row.engine_check
  $g8pct   = $r8g.row.size_rounding_pct
  $g8notes = $script:SamsHintNotes.Count
  $g8ok = ($null -ne $r8g.row) -and ($g8size -eq '160 oz') -and ($g8basis -eq 'package; qty name hint (reproduces Sam''s unit price)')
  $g8ok = $g8ok -and ($null -eq $g8pct) -and ($g8eng -like '*0.0749*') -and ($g8notes -eq 0)
  if ($g8ok) { Write-Output 'ok    8g SBR hint 160 oz replaces the quotient, no rounding field, engine 0.0749/oz' }
  else { Write-Output ("FAIL  8g SBR hint: err='" + $r8g.err + "' size='" + $g8size + "' basis='" + $g8basis + "' pct='" + $g8pct + "' engine='" + $g8eng + "' notes=" + $g8notes); $fail++ }
  # 8h MUST FIRE: 128 oz is the WRONG reading (that is a gallon of water, not of a 1.3 g/ml sauce). 11.98/128
  # displays as $0.09, not Sam's $0.07, so the hint is refused, reported, and the derived size stands. This is
  # the case that makes a hint safe to accept at all.
  $script:SamsSizeHints = @([pscustomobject]@{ sams_item_id='4W2VMU21D4SI'; name="Sweet Baby Ray's Original Barbecue Sauce, 1 gal."; net_oz=128; source='guess'; reviewed='2026-09-11' })
  $script:SamsHintNotes.Clear()
  $r8h = Build-Row $rawSBR
  $note8h = @() + $script:SamsHintNotes.ToArray()
  if ($r8h.row -and [string]$r8h.row.size -eq '171.143 oz' -and $note8h.Count -eq 1 -and ([string]$note8h[0].reason) -match '^BAD HINT') {
    Write-Output 'ok    8h SBR hint 128 oz does not reproduce $0.07/oz - refused, reported, derived size kept'
  } else { Write-Output ("FAIL  8h SBR bad hint: size='" + $r8h.row.size + "' notes=" + $note8h.Count + " reason='" + $(if ($note8h.Count) { $note8h[0].reason }) + "'"); $fail++ }
  # 8i MUST NOT FIRE: a hint keyed to ANOTHER item id must not touch this row. A hint that has drifted off its
  # product has to stop applying rather than quietly re-size a different jug.
  $script:SamsSizeHints = @([pscustomobject]@{ sams_item_id='SOMEOTHERID'; name="Sweet Baby Ray's Original Barbecue Sauce, 1 gal."; net_oz=160; source='label'; reviewed='2026-09-11' })
  $script:SamsHintNotes.Clear()
  $r8i = Build-Row $rawSBR
  if ($r8i.row -and [string]$r8i.row.size -eq '171.143 oz' -and $script:SamsHintNotes.Count -eq 0) { Write-Output 'ok    8i a hint on another item id is ignored silently' }
  else { Write-Output ("FAIL  8i foreign hint applied: size='" + $r8i.row.size + "' notes=" + $script:SamsHintNotes.Count); $fail++ }
  # 8j CLEAN TWIN: case 8d's ranch row still keeps size '122 oz' and name_volume_floz 128 - the 2026-09-10
  # gallon-jug path is untouched - and now also states its own 5.56% band.
  $script:SamsSizeHints = @(); $script:SamsHintNotes.Clear()
  $r8j = Build-Row ([pscustomobject]@{ n="Member's Mark Ranch Dressing, 1 gal."; lp='$10.98'; up='$0.09/oz'; id='RANCH1'; q='ranch dressing' })
  if ($r8j.row -and [string]$r8j.row.size -eq '122 oz' -and [double]$r8j.row.name_volume_floz -eq 128 -and $null -ne $r8j.row.size_rounding_pct -and [math]::Abs([double]$r8j.row.size_rounding_pct - 5.56) -lt 0.005) {
    Write-Output 'ok    8j ranch keeps 122 oz + name_volume_floz 128 and gains size_rounding_pct 5.56'
  } else { Write-Output ("FAIL  8j ranch: err='" + $r8j.err + "' size='" + $r8j.row.size + "' nv='" + $r8j.row.name_volume_floz + "' pct='" + $r8j.row.size_rounding_pct + "'"); $fail++ }
  $script:SamsSizeHints = $null; $script:SamsHintNotes.Clear()

  # ---- case 11: THE BUILD ITSELF, END TO END, AS A CHILD ----------------------------------------------
  # (2026-09-17.) Every case above calls Build-Row, and none ran the code BELOW this block, so from 9c44c3a37
  # (2026-09-12) every real build with at least one reject died at the rejects-file merge with "Argument types
  # do not match" (`@(List[object]) + @(...)` under PS 5.1): the deals file was already written, but the rejects
  # file, the summary line and the cursor advance never ran, and the Sam's cursor sat still for six days.
  # The child writes to a per-run temp -OutDir and -LedgerRoot and passes -NoCursor, so it touches neither out\sams,
  # the live rollback ledger nor the live cursor. The fixture date 1999-01-01 is one no real capture carries, and the live path for it is asserted absent.
  . (Join-Path $root 'native-lib.ps1')
  $bsdT = Join-Path $env:TEMP ('bsd-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $bsdT -ErrorAction Stop | Out-Null
  try {
    $bsdHead = 'q|n|lp|up|id'
    $bsdGood = 'cucumber|Seedless English Cucumbers, 3 ct.|$3.27|$1.09/ea|FIXTURE1'
    $bsdBad  = 'beans|Bogus Beans, 99 ct.|$3.27|$1.09/ea|FIXTURE2'
    # Every capture below opens with the club line samsSweepToCsv writes (backlog I124), because a capture without
    # one is refused; case 12 is where that refusal is proven.
    $bsdClub = 'Fixture Club 99999, Omaha, NE 68000'
    $bsdStore = '#tc-store store="' + $bsdClub + '" read="page" rows=2'
    # An ABSENCE probe: the live path is only ever handed to Test-Path, so nothing here reads live content.
    $bsdLiveDeals = Join-Path $root 'out\sams\sams-deals-1999-01-01.json'
    # THE ROLLBACK LEDGER GOES TO TEMP TOO (2026-09-19). -OutDir never moved it, so until then every child ran with
    # the LIVE rollback-first-seen.json as its ledger, and case 11c hashed that live file before and after. That hash
    # made the verdict rest on a file the Walmart builder saves at any moment (a concurrent save read as "the fixture
    # wrote live state"), and ops\audit-fixture-inputs.ps1 flagged it. Every child now passes -LedgerRoot, and case
    # 11d proves the redirect by making a child WRITE a ledger and finding it in temp.
    $bsdLedgerT = Join-Path $bsdT 'ledger'
    New-Item -ItemType Directory -Path $bsdLedgerT -ErrorAction Stop | Out-Null
    # 11a MUST FIRE: one priced row and one reject. The build must reach its summary line, write the rejects file
    # holding exactly that reject, and exit 0.
    $csvA = Join-Path $bsdT 'sams-capture-a.csv'
    [IO.File]::WriteAllText($csvA, ($bsdStore + "`n" + $bsdHead + "`n" + $bsdGood + "`n" + $bsdBad + "`n"), (New-Object Text.UTF8Encoding($false)))
    $outA = Join-Path $bsdT 'a'
    $runA = Invoke-NativeScript $PSCommandPath '-In' $csvA '-Date' '1999-01-01' '-OutDir' $outA '-NoCursor' '-LedgerRoot' $bsdLedgerT
    $linesA = @($runA.Lines | ForEach-Object { [string]$_ })
    $sumA = @($linesA | Where-Object { $_ -match '^build-sams-deals: 2 raw -> 1 priced \(1 after de-dupe\), 1 rejected -> sams-deals-1999-01-01\.json$' }).Count
    $rjA = Join-Path $outA 'sams-rejects-1999-01-01.json'
    $rjNames = @()
    if (Test-Path -LiteralPath $rjA) { $rjDoc = Get-Content -LiteralPath $rjA -Raw -Encoding UTF8 | ConvertFrom-Json; $rjNames = @($rjDoc | ForEach-Object { [string]$_.name }) }
    $okA = ($runA.ExitCode -eq 0) -and ($sumA -eq 1) -and ($rjNames.Count -eq 1) -and ($rjNames[0] -eq 'Bogus Beans, 99 ct.') -and (Test-Path -LiteralPath (Join-Path $outA 'sams-deals-1999-01-01.json'))
    if ($okA) { Write-Output 'ok    11a MUST FIRE  a build with one reject reaches its summary line, writes the rejects file and exits 0' }
    else { Write-Output ("FAIL  11a build with a reject: exit=" + $runA.ExitCode + " summary_lines=" + $sumA + " reject_names=" + ($rjNames -join ';') + " | " + (($linesA | Select-Object -Last 4) -join ' / ')); $fail++ }
    # 11b CLEAN TWIN: the same build with no reject still reaches its summary line, exits 0 and writes no rejects file.
    $csvB = Join-Path $bsdT 'sams-capture-b.csv'
    [IO.File]::WriteAllText($csvB, ($bsdStore + "`n" + $bsdHead + "`n" + $bsdGood + "`n"), (New-Object Text.UTF8Encoding($false)))
    $outB = Join-Path $bsdT 'b'
    $runB = Invoke-NativeScript $PSCommandPath '-In' $csvB '-Date' '1999-01-01' '-OutDir' $outB '-NoCursor' '-LedgerRoot' $bsdLedgerT
    $linesB = @($runB.Lines | ForEach-Object { [string]$_ })
    $sumB = @($linesB | Where-Object { $_ -match '^build-sams-deals: 1 raw -> 1 priced \(1 after de-dupe\), 0 rejected -> sams-deals-1999-01-01\.json$' }).Count
    if ($runB.ExitCode -eq 0 -and $sumB -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $outB 'sams-rejects-1999-01-01.json'))) { Write-Output 'ok    11b CLEAN TWIN  a build with no reject reaches its summary line, exits 0 and writes no rejects file' }
    else { Write-Output ("FAIL  11b clean build: exit=" + $runB.ExitCode + " summary_lines=" + $sumB + " | " + (($linesB | Select-Object -Last 4) -join ' / ')); $fail++ }
    # 11c MUST NOT FIRE: the fixture children wrote nothing into the live out\sams, and with no was-price in either
    # capture they wrote no ledger either, so the temp ledger directory is still empty.
    $bsdLedgerFileT = Join-Path $bsdLedgerT 'rollback-first-seen.json'
    if (-not (Test-Path -LiteralPath $bsdLiveDeals) -and -not (Test-Path -LiteralPath $bsdLedgerFileT)) { Write-Output 'ok    11c MUST NOT FIRE  the fixture builds left out\sams alone and, with no was-price, wrote no ledger' }
    else { Write-Output ('FAIL  11c a fixture build wrote state: live_deals_present=' + (Test-Path -LiteralPath $bsdLiveDeals) + ' temp_ledger_present=' + (Test-Path -LiteralPath $bsdLedgerFileT)); $fail++ }
    # 11d MUST FIRE: a capture row WITH a was-price above its price is a rollback, so the child must date it and save
    # the ledger - and the ledger it saves must be the one under -LedgerRoot. Asserted positively, in temp, so the
    # verdict never reads the live ledger: without the redirect this entry lands in grocery\rollback-first-seen.json
    # and the temp file is absent.
    $csvD = Join-Path $bsdT 'sams-capture-d.csv'
    [IO.File]::WriteAllText($csvD, ($bsdStore + "`n" + 'q|n|lp|up|id|was' + "`n" +'cucumber|Seedless English Cucumbers, 3 ct.|$3.27|$1.09/ea|FIXTURE3|$3.98' + "`n"), (New-Object Text.UTF8Encoding($false)))
    $outD = Join-Path $bsdT 'd'
    $runD = Invoke-NativeScript $PSCommandPath '-In' $csvD '-Date' '1999-01-01' '-OutDir' $outD '-NoCursor' '-LedgerRoot' $bsdLedgerT
    $linesD = @($runD.Lines | ForEach-Object { [string]$_ })
    $rbLineD = @($linesD | Where-Object { $_ -match '^build-sams-deals: 1 rollback\(s\) dated from first detection' }).Count
    $keysD = @()
    if (Test-Path -LiteralPath $bsdLedgerFileT) { $ldD = Get-Content -LiteralPath $bsdLedgerFileT -Raw -Encoding UTF8 | ConvertFrom-Json; $keysD = @($ldD.entries | ForEach-Object { [string]$_.key }) }
    if ($runD.ExitCode -eq 0 -and $rbLineD -eq 1 -and $keysD.Count -eq 1 -and $keysD[0] -eq "Sam's Club|FIXTURE3") { Write-Output 'ok    11d MUST FIRE  a was-price row is dated and its ledger entry lands under -LedgerRoot, not the live ledger' }
    else { Write-Output ("FAIL  11d ledger redirect: exit=" + $runD.ExitCode + " rollback_lines=" + $rbLineD + " temp_ledger_keys=" + ($keysD -join ';') + " | " + (($linesD | Select-Object -Last 4) -join ' / ')); $fail++ }

    # ---- case 12: THE CLUB A CAPTURE WAS READ AT (2026-09-18, backlog I124) -----------------------------------
    # The founding defect: every sams-deals file said club "13130 L St" from a literal while the session read 15429
    # Blackwell Dr. 12a is that defect as a MUST FIRE, run through the real build as a child: a capture read at a
    # club that is NOT the old literal must write the club it was read at, on the file and on every row.
    $csvE = Join-Path $bsdT 'sams-capture-e.csv'
    $blk  = '15429 Blackwell Dr, Omaha, NE 68116'
    [IO.File]::WriteAllText($csvE, ('#tc-store store="' + $blk + '" read="page" rows=1' + "`n" + 'q|n|lp|up|id|was' + "`n" + $bsdGood + '|' + "`n"), (New-Object Text.UTF8Encoding($false)))
    $outE = Join-Path $bsdT 'e'
    $runE = Invoke-NativeScript $PSCommandPath '-In' $csvE '-Date' '1999-01-01' '-OutDir' $outE '-NoCursor' '-LedgerRoot' $bsdLedgerT
    $docE = $null
    $fE = Join-Path $outE 'sams-deals-1999-01-01.json'
    if (Test-Path -LiteralPath $fE) { $docE = Get-Content -LiteralPath $fE -Raw -Encoding UTF8 | ConvertFrom-Json }
    $eClub = if ($docE) { [string]$docE.club } else { '<no file>' }
    $eRead = if ($docE) { [string]$docE.club_read } else { '' }
    $eRows = @(); if ($docE) { $eRows = @($docE.deals) }
    $eStamped = @($eRows | Where-Object { [string]::Equals([string]$_.store_location, $blk, [StringComparison]::Ordinal) }).Count
    if ($runE.ExitCode -eq 0 -and [string]::Equals($eClub, $blk, [StringComparison]::Ordinal) -and $eRead -eq 'page' -and $eRows.Count -eq 1 -and $eStamped -eq 1) {
      Write-Output 'ok    12a MUST FIRE  a capture read at Blackwell Dr writes club "15429 Blackwell Dr..." (not the old 13130 L St literal) and stamps it on every row'
    } else { Write-Output ("FAIL  12a club read: exit=" + $runE.ExitCode + " club='" + $eClub + "' read='" + $eRead + "' rows=" + $eRows.Count + " stamped=" + $eStamped + " | " + (($runE.Lines | Select-Object -Last 3) -join ' / ')); $fail++ }

    # 12b CLEAN TWIN: the stamp is ADDITIVE. Built through Build-Row alone, the same raw row carries every priced
    # field the build wrote, byte for byte - the club touches nothing the engine reads.
    $bare12 = (Build-Row ([pscustomobject]@{ q='cucumber'; n='Seedless English Cucumbers, 3 ct.'; lp='$3.27'; up='$1.09/ea'; id='FIXTURE1' }) $blk).row
    $pricedSame = ($null -ne $bare12) -and ($eRows.Count -eq 1)
    if ($pricedSame) {
      foreach ($pn in @('ad_price', 'size', 'current_price', 'source_checkout_price', 'sams_unit_price', 'qty_basis', 'engine_check', 'source_ad', 'store')) {
        if (-not [string]::Equals([string]$bare12.$pn, [string]$eRows[0].$pn, [StringComparison]::Ordinal)) { $pricedSame = $false }
      }
    }
    if ($pricedSame) { Write-Output 'ok    12b CLEAN TWIN  the club-stamped row carries every priced field exactly as Build-Row writes it' }
    else { Write-Output ('FAIL  12b the club stamp moved a priced field: built=' + ($eRows | ConvertTo-Json -Compress -Depth 3) + ' bare=' + ($bare12 | ConvertTo-Json -Compress -Depth 3)); $fail++ }

    # 12c MUST FIRE, the whole refusal table, through Split-SamsCaptureStore (the function the build path runs).
    $S12 = '#tc-store store="' + $blk + '" read="page" rows=2'
    $C12 = 'q|n|lp|up|id|was'
    $R12 = $bsdGood + '|'
    # Each concatenated line is its own variable: inside @(...) the comma binds tighter than +, so an inline
    # concatenation becomes ONE string holding every line (ops-and-gates.md; this table hit it on first run).
    $S12one = '#tc-store store="' + $blk + '" read="page" rows=1'
    $S12lst = '#tc-store store="13130 L St, Omaha, NE 68137" read="page" rows=1'
    $tbl12 = @(
      @{ l = 'MUST FIRE  a capture with NO store line is refused';                     lines = @($C12, $R12); want = 'carries no #tc-store line' },
      @{ l = 'MUST FIRE  a non-Omaha club is refused';                                 lines = @('#tc-store store="4550 N 27th St, Lincoln, NE 68521" read="page" rows=1', $C12, $R12); want = 'not an Omaha club' },
      @{ l = 'MUST FIRE  rows with no club read are refused, never folded into the club beside them'; lines = @($S12one, '#tc-store store="UNRECORDED" read="UNRECORDED" rows=1', $C12, $R12); want = 'no club read' },
      @{ l = 'MUST FIRE  a sweep that straddled two Omaha clubs is refused';           lines = @($S12one, $S12lst, $C12, $R12); want = 'straddles 2 clubs' },
      @{ l = 'MUST FIRE  a store line that does not parse is refused';                 lines = @('#tc-store 15429 Blackwell Dr, Omaha', $C12, $R12); want = 'does not parse' },
      @{ l = 'MUST NOT FIRE  a rescue: the same club twice and a second header is one club'; lines = @($S12, $C12, $R12, $S12, $C12, $R12); want = '' }
    )
    foreach ($c in $tbl12) {
      $cs12 = Split-SamsCaptureStore $c.lines
      $ok12 = if ($c.want) { [bool]$cs12.refuse -and $cs12.refuse.Contains($c.want) } else { (-not $cs12.refuse) -and ($cs12.lines.Count -eq 3) -and [string]::Equals([string]$cs12.store, $blk, [StringComparison]::Ordinal) }
      if ($ok12) { Write-Output ('ok    12c ' + $c.l) }
      else { Write-Output ('FAIL  12c ' + $c.l + ' - refusal was: ' + $(if ($cs12.refuse) { $cs12.refuse } else { '<none>' }) + ' kept=' + $cs12.lines.Count); $fail++ }
    }

    # 12d MUST FIRE through the build itself: a store-less capture exits non-zero and writes nothing at all.
    $csvF = Join-Path $bsdT 'sams-capture-f.csv'
    [IO.File]::WriteAllText($csvF, ($bsdHead + "`n" + $bsdGood + "`n"), (New-Object Text.UTF8Encoding($false)))
    $outF = Join-Path $bsdT 'f'
    $runF = Invoke-NativeScript $PSCommandPath '-In' $csvF '-Date' '1999-01-01' '-OutDir' $outF '-NoCursor' '-LedgerRoot' $bsdLedgerT
    $fWrote = Test-Path -LiteralPath (Join-Path $outF 'sams-deals-1999-01-01.json')
    $fSaid = @($runF.Lines | Where-Object { ([string]$_) -match 'REFUSING .* carries no #tc-store line' }).Count
    if ($runF.ExitCode -ne 0 -and -not $fWrote -and $fSaid -ge 1) { Write-Output 'ok    12d MUST FIRE  the build refuses a store-less capture, exits non-zero and writes no deals file' }
    else { Write-Output ("FAIL  12d store-less build: exit=" + $runF.ExitCode + " wrote=" + $fWrote + " refusal_lines=" + $fSaid + " | " + (($runF.Lines | Select-Object -Last 3) -join ' / ')); $fail++ }

    # 12e CLEAN TWIN: -WaiveMissingStoreLine re-builds that same capture, says the club was NOT RECORDED and stamps
    # no row with a club nobody read.
    $outG = Join-Path $bsdT 'g'
    $runG = Invoke-NativeScript $PSCommandPath '-In' $csvF '-Date' '1999-01-01' '-OutDir' $outG '-NoCursor' '-LedgerRoot' $bsdLedgerT '-WaiveMissingStoreLine'
    $docG = $null
    $fG = Join-Path $outG 'sams-deals-1999-01-01.json'
    if (Test-Path -LiteralPath $fG) { $docG = Get-Content -LiteralPath $fG -Raw -Encoding UTF8 | ConvertFrom-Json }
    $gRows = @(); if ($docG) { $gRows = @($docG.deals) }
    $gStamped = @($gRows | Where-Object { $_.PSObject.Properties['store_location'] }).Count
    if ($runG.ExitCode -eq 0 -and $docG -and ([string]$docG.club) -like 'club NOT RECORDED*' -and ([string]$docG.club_read) -eq 'NOT RECORDED' -and $gRows.Count -eq 1 -and $gStamped -eq 0) {
      Write-Output 'ok    12e CLEAN TWIN  -WaiveMissingStoreLine builds a store-less capture and says the club was NOT RECORDED'
    } else { Write-Output ("FAIL  12e waived build: exit=" + $runG.ExitCode + " club='" + $(if ($docG) { $docG.club }) + "' rows=" + $gRows.Count + " stamped=" + $gStamped); $fail++ }

    # 12f MUST FIRE: the waiver waives the MISSING line only - a line naming another city is refused with it too.
    $capW = Join-Path $bsdT 'sams-capture-w.csv'
    [IO.File]::WriteAllText($capW, ('#tc-store store="4550 N 27th St, Lincoln, NE 68521" read="page" rows=1' + "`n" + $C12 + "`n" + $R12 + "`n"), (New-Object Text.UTF8Encoding($false)))
    $rdW = Read-SamsCapture -Path $capW -WaiveMissingStoreLine
    if ($rdW.refuse -and $rdW.refuse.Contains('not an Omaha club') -and @($rdW.raw).Count -eq 0) { Write-Output 'ok    12f MUST FIRE  -WaiveMissingStoreLine still refuses a store line that names another city' }
    else { Write-Output ('FAIL  12f the waiver waived a non-Omaha club: rows=' + @($rdW.raw).Count + ' refusal [' + $rdW.refuse + ']'); $fail++ }

    # 12g MUST FIRE: a row pasted under a club line that did not count it (a hand-rolled rescue) is said out loud -
    # FLAGGED, never refused, so the build still exits 0 and writes its file.
    $csvH = Join-Path $bsdT 'sams-capture-h.csv'
    $H1 = '#tc-store store="' + $blk + '" read="page" rows=1'
    $H2 = 'beans|Bush''s Best Black Beans, 15 oz., 8 pk.|$7.48|$0.06/oz|FIXTURE4|'
    [IO.File]::WriteAllText($csvH, (($H1, $C12, $R12, $H2) -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
    $runH = Invoke-NativeScript $PSCommandPath '-In' $csvH '-Date' '1999-01-01' '-OutDir' (Join-Path $bsdT 'h') '-NoCursor' '-LedgerRoot' $bsdLedgerT
    $hWarn = @($runH.Lines | Where-Object { ([string]$_) -match '^build-sams-deals: WARNING the #tc-store line\(s\) count 1 row\(s\) but the capture holds 2' }).Count
    if ($runH.ExitCode -eq 0 -and $hWarn -eq 1) { Write-Output 'ok    12g MUST FIRE  a row the club line did not count is flagged, and the build still completes' }
    else { Write-Output ("FAIL  12g uncounted row: exit=" + $runH.ExitCode + " warnings=" + $hWarn + " | " + (($runH.Lines | Select-Object -Last 3) -join ' / ')); $fail++ }
    # ...MUST NOT FIRE: case 12a's line counted its one row exactly, so it printed no such warning.
    $eWarn = @($runE.Lines | Where-Object { ([string]$_) -match 'WARNING the #tc-store line' }).Count
    if ($eWarn -eq 0) { Write-Output 'ok    12g MUST NOT FIRE  a capture whose club line counts its rows exactly prints no row-count warning' }
    else { Write-Output ('FAIL  12g a matching count still warned ' + $eWarn + ' time(s)'); $fail++ }

    # ---- case 13: CHANNEL, CLUB STAMP AND STATED TOTAL (2026-09-19, PLAN-board-accuracy-2026-09-19 section 4e) ----
    # 13a MUST FIRE, through the build as a child: a row whose payload says SHIPPING only is 'ship-only' and carries
    # the channel gate's refusal word, and the in-club row beside it is 'in-store'. Names are the founding products;
    # the prices are illustrative (the verification recorded channel, not price), and the ful values are the ones read
    # live on 2026-09-19 (pull-sams-instore.js samsFulfillment).
    $csvJ = Join-Path $bsdT 'sams-capture-j.csv'
    $J0 = '#tc-store store="' + $blk + '" read="page" rows=3'
    $J1 = 'q|n|lp|up|id|was|ful'
    $J2 = 'honey mustard|Member''s Mark Foodservice Honey Mustard, 128 oz.|$10.98|$0.09/oz|FIXTURE5||SHIPPING@6279'
    $J3 = 'eggs|Member''s Mark Cage Free Grade AA Large White Eggs, 2 dozen|$4.82|$2.41/dz|FIXTURE6||PICKUP@8146,DELIVERY@8146'
    $J4 = 'cucumber|Seedless English Cucumbers, 3 ct.|$3.27|$1.09/ea|FIXTURE1||PICKUP@8146,DELIVERY@8146,SHIPPING@6279'
    [IO.File]::WriteAllText($csvJ, (($J0, $J1, $J2, $J3, $J4) -join "`n") + "`n", (New-Object Text.UTF8Encoding($false)))
    $runJ = Invoke-NativeScript $PSCommandPath '-In' $csvJ '-Date' '1999-01-01' '-OutDir' (Join-Path $bsdT 'j') '-NoCursor' '-LedgerRoot' $bsdLedgerT
    $fJ = Join-Path $bsdT 'j\sams-deals-1999-01-01.json'
    $jRows = @()
    if (Test-Path -LiteralPath $fJ) { $jDoc = Get-Content -LiteralPath $fJ -Raw -Encoding UTF8 | ConvertFrom-Json; $jRows = @($jDoc.deals) }
    $jHm = @($jRows | Where-Object { [string]$_.sams_item_id -eq 'FIXTURE5' })
    $jEg = @($jRows | Where-Object { [string]$_.sams_item_id -eq 'FIXTURE6' })
    $jCu = @($jRows | Where-Object { [string]$_.sams_item_id -eq 'FIXTURE1' })
    if ($runJ.ExitCode -eq 0 -and $jHm.Count -eq 1 -and [string]$jHm[0].channel -eq 'ship-only' -and [string]$jHm[0].fulfillment -eq 'FC' -and [string]$jHm[0].sams_fulfillment -eq 'SHIPPING@6279') {
      Write-Output 'ok    13a MUST FIRE  a SHIPPING@6279-only row (honey mustard 128 oz) is channel ship-only with fulfillment FC'
    } else { Write-Output ('FAIL  13a ship-only row: exit=' + $runJ.ExitCode + ' rows=' + $jRows.Count + ' got=' + ($jHm | ConvertTo-Json -Compress -Depth 3) + ' | ' + (($runJ.Lines | Select-Object -Last 3) -join ' / ')); $fail++ }
    # 13b MUST NOT FIRE: an in-club row (PICKUP at the club) is in-store, never refused.
    if ($jEg.Count -eq 1 -and [string]$jEg[0].channel -eq 'in-store' -and [string]$jEg[0].fulfillment -eq 'STORE') { Write-Output 'ok    13b MUST NOT FIRE  a PICKUP@8146 row (eggs 2 dozen) is channel in-store with fulfillment STORE' }
    else { Write-Output ('FAIL  13b in-club row: ' + ($jEg | ConvertTo-Json -Compress -Depth 3)); $fail++ }
    # 13c MUST FIRE, on the MECHANISM the board uses: compare-deals' channel gate (instore-lib.ps1) refuses the built
    # ship-only row and admits the built in-club row, read from the files the child wrote.
    . (Join-Path $root 'instore-lib.ps1')
    $vHm = if ($jHm.Count) { Get-ChannelVerdict -Index $null -Store "Sam's Club" -SrcFile 'sams-deals-1999-01-01' -ItemId '' -Fulfillment $jHm[0].fulfillment } else { $null }
    $vEg = if ($jEg.Count) { Get-ChannelVerdict -Index $null -Store "Sam's Club" -SrcFile 'sams-deals-1999-01-01' -ItemId '' -Fulfillment $jEg[0].fulfillment } else { $null }
    if ($vHm -and -not $vHm.in_store -and $vEg -and $vEg.in_store) { Write-Output ('ok    13c MUST FIRE  the board''s channel gate refuses the ship-only row (' + $vHm.why + ') and admits the in-club row (' + $vEg.why + ')') }
    else { Write-Output ('FAIL  13c channel gate: ship-only=' + ($vHm | ConvertTo-Json -Compress) + ' in-club=' + ($vEg | ConvertTo-Json -Compress)); $fail++ }
    # 13d MUST NOT FIRE: every shape that proves nothing is channel '' and carries NO fulfillment field, so a capture
    # older than `ful` builds exactly as before. Includes the empty summary (out of stock) and delivery alone.
    $unk = @(@{ f = ''; l = 'no ful column value' }, @{ f = 'NONE'; l = 'an empty summary (NONE)' }, @{ f = 'DELIVERY@8146'; l = 'club delivery without pickup' }, @{ f = 'SHIPPING@6279,?@'; l = 'a shipping entry beside an unreadable one' })
    foreach ($x in $unk) {
      $ru = (Build-Row ([pscustomobject]@{ q='t'; n='Seedless English Cucumbers, 3 ct.'; lp='$3.27'; up='$1.09/ea'; id='U'; ful=$x.f }) $blk).row
      if ($ru -and [string]$ru.channel -eq '' -and -not $ru.PSObject.Properties['fulfillment']) { Write-Output ('ok    13d MUST NOT FIRE  ' + $x.l + ' -> channel unknown, no fulfillment field') }
      else { Write-Output ('FAIL  13d ' + $x.l + ' -> ' + ($ru | ConvertTo-Json -Compress -Depth 3)); $fail++ }
    }
    # 13e MUST FIRE: every row carries the club its capture was READ at as store_id and in source_ad - and the old
    # literal "Omaha 68137" appears on none of them. Case 12a's child read Blackwell Dr; case 13a's did too.
    $clubRows = @($eRows) + @($jRows)
    $clubOk = @($clubRows | Where-Object { [string]::Equals([string]$_.store_id, $blk, [StringComparison]::Ordinal) -and [string]::Equals([string]$_.source_ad, ('everyday club price (' + $blk + ')'), [StringComparison]::Ordinal) }).Count
    $lit = @($clubRows | Where-Object { ([string]$_.source_ad).Contains('Omaha 68137') }).Count
    if ($clubRows.Count -eq 4 -and $clubOk -eq 4 -and $lit -eq 0) { Write-Output 'ok    13e MUST FIRE  4 of 4 built rows name the club read (store_id and source_ad), none the "Omaha 68137" literal' }
    else { Write-Output ('FAIL  13e club stamp: rows=' + $clubRows.Count + ' stamped=' + $clubOk + ' literal=' + $lit); $fail++ }
    #     ...CLEAN TWIN: the waived build (12e) names no club rather than inventing one.
    if ($gRows.Count -eq 1 -and [string]$gRows[0].store_id -eq '' -and [string]$gRows[0].source_ad -eq 'everyday club price (club NOT RECORDED)') { Write-Output 'ok    13e CLEAN TWIN  a -WaiveMissingStoreLine row says club NOT RECORDED and has an empty store_id' }
    else { Write-Output ('FAIL  13e waived club: ' + ($gRows | ConvertTo-Json -Compress -Depth 3)); $fail++ }
    # 13f MUST FIRE: the founding Clorox row, in both spellings. "Pack of 5, 425 Wipes Total" derived 470 ct from the
    # cent-rounded $0.04/ea; "5 pk., 425 Wipes Total" (the live spelling on 2026-09-19) had no reading of 5 that
    # reproduced $0.04 and was rejected as a NAME CONFLICT. The stated total wins in both, and still reproduces Sam's price.
    foreach ($cn in @('Clorox Disinfecting Cleaning Wipes, Bleach Free, Fresh Scent and Crisp Lemon, Pack of 5, 425 Wipes Total', 'Clorox Disinfecting Cleaning Wipes, Bleach Free, Fresh Scent and Crisp Lemon, 5 pk., 425 Wipes Total')) {
      $rc = Build-Row ([pscustomobject]@{ q='clorox wipes'; n=$cn; lp='$18.78'; up='$0.04/ea'; id='CLX' }) $blk
      if ($rc.row -and [string]$rc.row.size -eq '425 ct' -and ([string]$rc.row.qty_basis) -like '*name stated total*') { Write-Output ('ok    13f MUST FIRE  "' + $cn.Substring(76) + '" sizes 425 ct (' + $rc.row.qty_basis + ')') }
      else { Write-Output ('FAIL  13f clorox "' + $cn + '": err=' + $rc.err + ' size=' + $rc.row.size); $fail++ }
    }
    #     ...MUST FIRE: the second real name the scan found, lower-case "total" after three counts (was 999 ct).
    $rck = Build-Row ([pscustomobject]@{ q='tissues'; n='Kleenex Ultra Soft Tissues Combo Pack, 3 Snap N'' Go packs, 11 boxes, 867 Tissues total'; lp='$19.98'; up='$0.02/ea'; id='KLX' }) $blk
    if ($rck.row -and [string]$rck.row.size -eq '867 ct') { Write-Output 'ok    13f MUST FIRE  "11 boxes, 867 Tissues total" sizes 867 ct, not the derived 999' }
    else { Write-Output ('FAIL  13f kleenex: err=' + $rck.err + ' size=' + $rck.row.size); $fail++ }
    #     ...MUST FIRE: a stated total that does NOT reproduce Sam's unit price is a reject, never a published guess.
    $rcx = Build-Row ([pscustomobject]@{ q='t'; n='Bogus Wipes, 900 Wipes Total'; lp='$18.78'; up='$0.04/ea'; id='CLY' }) $blk
    if ($rcx.err -and $rcx.err -match 'NAME CONFLICT') { Write-Output 'ok    13f MUST FIRE  a stated total that does not reproduce $0.04/ea is rejected' }
    else { Write-Output ('FAIL  13f lying total published size=' + $rcx.row.size); $fail++ }
    # 13g MUST NOT FIRE: a measure before "total" is not a count, a count with no "total" is not a stated total, and a
    # total with no number is nothing.
    foreach ($nt in @('Similac 360 Total Care Infant Formula, Ready to Feed, 8 fl. oz., 24 ct.', 'Gatorade Thirst Quencher Variety Pack, 20 fl. oz., 24 pk., 480 oz Total','Q-tips Cotton Swabs, 1750 ct., 3 pk.', 'Total Cereal, 18 oz.', 'Kirkland Paper Towels, 12 rolls')) {
      $gt = Get-NameStatedTotal $nt
      if ($null -eq $gt) { Write-Output ('ok    13g MUST NOT FIRE  no stated total in "' + $nt + '"') }
      else { Write-Output ('FAIL  13g read a stated total ' + $gt + ' from "' + $nt + '"'); $fail++ }
    }
    # 13h CLEAN TWIN: an ordinary row still builds byte-identically in every field the channel and club work did not
    # set. The expected values are FROZEN from the committed builder (blob of HEAD before this change) run as a child
    # on the same cucumber row on 2026-09-19; only source_ad was meant to move, and it is asserted in 13e.
    $frozen = [ordered]@{ store="Sam's Club"; item='Seedless English Cucumbers, 3 ct.'; ad_price='$3.27'; size='3 ct'; regular=$null; as_of='1999-01-01'; current_price='$3.27'; source_checkout_price='$3.27'; sams_unit_price='$1.09/ea'; sams_item_id='FIXTURE1'; found_by_term='cucumber'; qty_basis='package; qty name (reproduces Sam''s unit price)'; engine_check='1.09/each [per-3-pack]'; taxonomy_path=''; link_url=''; image_url=''; store_location=$blk }
    $twinBad = @()
    foreach ($tr in @(@{ l = 'no ful (12a)'; r = $eRows }, @{ l = 'ful PICKUP (13a)'; r = $jCu })) {
      if (@($tr.r).Count -ne 1) { $twinBad += ($tr.l + ': rows=' + @($tr.r).Count); continue }
      foreach ($k in $frozen.Keys) {
        $got = @($tr.r)[0].$k
        if (-not [string]::Equals([string]$got, [string]$frozen[$k], [StringComparison]::Ordinal) -or (($null -eq $got) -ne ($null -eq $frozen[$k]))) { $twinBad += ($tr.l + ' ' + $k + '=' + [string]$got) }
      }
    }
    if ($twinBad.Count -eq 0) { Write-Output 'ok    13h CLEAN TWIN  the ordinary cucumber row keeps all 17 pre-change fields byte-identical, with and without a ful column' }
    else { Write-Output ('FAIL  13h fields moved: ' + ($twinBad -join '; ')); $fail++ }
  } finally { Remove-Item -LiteralPath $bsdT -Recurse -Force -ErrorAction SilentlyContinue }

  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS' ; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

# ---------------------------------------------------------------- build
if (-not $In -or -not (Test-Path $In)) { throw "build-sams-deals: -In not found: $In" }
# PREFER THE CAPTURE'S OWN DATE over today's. Falling straight to (Get-Date) stamps the day the BUILDER ran
# onto prices the browser captured days earlier - the dates-written-not-measured class, which surfaces as a
# wrong PRICE rather than a wrong date because compare-deals unions slices across a 14-day window and an
# over-fresh stamp keeps a stale slice alive past its cliff. Same order build-walmart-deals.ps1 uses.
if (-not $Date -and $In) { $m = [regex]::Match($In, '\d{4}-\d{2}-\d{2}'); if ($m.Success) { $Date = $m.Value } }
if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
# THE CLUB IS RULED ON BEFORE A SINGLE ROW IS READ (backlog I124; see Split-SamsCaptureStore).
$cap = Read-SamsCapture -Path $In -WaiveMissingStoreLine:$WaiveMissingStoreLine
if ($cap.refuse) {
  throw ('build-sams-deals: REFUSING ' + (Split-Path $In -Leaf) + ' - ' + $cap.refuse + ' Nothing was written and the cursor did not advance, so the older Sam''s slices stand.')
}
if ($cap.waived) { Write-Warning 'build-sams-deals: -WaiveMissingStoreLine - this capture names no club, and the file will say so rather than name one.' }
# FLAGGED, NOT REFUSED: the store line counts the rows the emitter wrote under it. Rows appended by hand below a line
# they were not counted in (a hand-rolled rescue sweep pasted under the morning capture) would otherwise ride on that
# club silently, so a mismatch is said out loud. Not a refusal: a blank or duplicate line moves the count too.
$capHeld = @($cap.raw).Count + [int]$script:CapturePlaceholderCount   # a placeholder row dropped at ingest was still counted by the emitter
if (-not $cap.waived -and $capHeld -ne [int]$cap.cs.rows) {
  Write-Output ("build-sams-deals: WARNING the #tc-store line(s) count {0} row(s) but the capture holds {1} - rows added outside samsSweepToCsv are attributed to '{2}' without having been read there" -f $cap.cs.rows, $capHeld, $cap.cs.store)
}
$clubLabel = Get-SamsClubLabel $cap.cs ([bool]$cap.waived)
$storeLocation = if ($cap.waived) { '' } else { [string]$cap.cs.store }
# Read-SamsCapture reads through Import-CaptureCsv (UTF-8 + repairs names mangled by an upstream ANSI read), so the
# repair and placeholder counters below are that call's. Assign, THEN wrap: a one-row capture comes back as a lone
# PSCustomObject, which under PS 5.1 has no .Count, so the summary line printed " raw" with no number (self-test 11b).
$raw = $cap.raw
$raw = @($raw)
if ($script:CaptureRepairCount -gt 0) { Write-Output ("  repaired $($script:CaptureRepairCount) mangled field(s) on ingest (UTF-8 read as ANSI upstream)") }
if ($script:CapturePlaceholderCount -gt 0) { Write-Output ("  dropped $($script:CapturePlaceholderCount) vendor placeholder row(s) at ingest ($($script:CapturePlaceholderPct)% of what was read)") }
if ($script:CaptureIngestWarning) { Write-Output ("  " + $script:CaptureIngestWarning) }
$rows = New-Object System.Collections.Generic.List[object]
$rejects = New-Object System.Collections.Generic.List[object]
# THE ROLLBACK / INSTANT-SAVINGS WINDOW (2026-08-21). Same rule and same reason as Walmart: Brad's
# "30 day TTL from when we first detect". Sam's publishes no end date either - measured on a live
# search, the payload contains ZERO date-shaped values and every /Expir/ key is session, cache or
# consent related - so the anchor is the first sighting, and rollback-ttl-lib refuses to move it.
# Inert until the capture carries a was-price, so an older CSV is unaffected.
. (Join-Path $root 'rollback-ttl-lib.ps1')
$ledgerRoot = if ($LedgerRoot) { $LedgerRoot } else { $root }
$rollbacks = 0
foreach ($r in $raw) {
  $b = Build-Row $r $storeLocation
  if ($b.row) {
    # ONE implementation, three callers (rollback-ttl-lib). The inline copy that used to live here read
    # $script:CaptureDate, which this file never assigns - see that function's header for what it cost.
    if (Set-RollbackFields -Row $b.row -Was $r.was -Store "Sam's Club" -ItemId ([string]$r.id) -Date $Date -Root $ledgerRoot) { $rollbacks++ }
    # The club each row was READ at (backlog I124), the field build-aldi-regular stamps. Added AFTER Build-Row, so
    # every priced field is exactly what it was; compare-deals reads no field of this name. A waived build stamps none.
    if ($storeLocation) { Add-Member -InputObject $b.row -NotePropertyName 'store_location' -NotePropertyValue $storeLocation -Force }
    $rows.Add($b.row)
  } else { $rejects.Add([pscustomobject]@{ name=$r.n; lp=$r.lp; up=$r.up; reason=$b.err }) }
}
# A BAD HINT IS A NOTE, NOT A REJECTION (2026-09-11, queue 2026-09-10-c8eb72). A human-read size that does not
# reproduce Sam's own unit price is refused - it never touches a published number - but the ROW is exactly as
# good as it was without the hint, so it ships with its derived size and the bad reading is reported here.
# Counted apart from the rejects so "N rejected" keeps meaning "N rows not published".
$hintNotes = @() + $script:SamsHintNotes.ToArray()
if ($hintNotes.Count) { Write-Output ("build-sams-deals: $($hintNotes.Count) BAD HINT note(s) in sams-size-hints.json - the row kept its derived size, see the rejects file") }
# NEVER FATAL (2026-09-11). This save runs BEFORE the rows below are written, and it can now refuse - the ledger lock
# not free within its budget, or a ledger on disk it cannot read and will not overwrite - so an uncaught throw here
# would cost the whole capture over one ledger.
try { [void](Save-RollbackLedger $ledgerRoot) } catch { Write-Warning ("build-sams-deals: rollback ledger NOT saved (" + $_.Exception.Message + ") - the first sightings this build dated are not recorded, and the next build that sees them anchors them to its own later capture") }
if ($rollbacks -gt 0) { Write-Output ("build-sams-deals: $rollbacks rollback(s) dated from first detection (" + (Get-RollbackTtlDays) + "-day TTL; Sam's publishes no end date)") }
# de-dupe identical products (the same SKU is returned by several search terms)
$seen = @{}; $ded = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) { $k = $r.item + '|' + $r.ad_price + '|' + $r.size; if (-not $seen.ContainsKey($k)) { $seen[$k]=$true; $ded.Add($r) } }

$outDir = if ($OutDir) { $OutDir } else { Join-Path $root 'out\sams' }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$outFile = Join-Path $outDir ("sams-deals-$Date.json")
[ordered]@{
  store      = "Sam's Club"
  price_type = 'everyday'
  # READ from the capture's #tc-store line (backlog I124). Until 2026-09-18 this was the literal
  # "Omaha Sam's Club, 13130 L St, 68137", a club the session had left on 2026-08-15. No script reads this key.
  club       = $clubLabel
  club_read  = $(if ($cap.waived) { 'NOT RECORDED' } else { [string]$cap.cs.read })
  captured   = $Date
  shape      = 'PACKAGE price + pack size (ad_price = price of ONE size). Built by build-sams-deals.ps1; every row verified to reproduce Sam''s own unitPrice through compare-deals'' real Get-UnitPrice.'
  # HOW COMPREHENSIVE was this slice? Sam's is CAPTCHA-walled and pulled in slices; compare-deals unions every
  # slice in its 14-day window, so a slice keeps the file dates fresh while the OLDER slices quietly carry most
  # of the coverage toward the window's cliff (the exact masking that hid the 2026-07-23 Walmart aging risk).
  # Distinct search terms is the machine-readable slice-vs-comprehensive marker audit-walmart-fullpull watches.
  pull_terms = @($raw | Select-Object -ExpandProperty q -Unique).Count
  deals      = $ded
} | ConvertTo-Json -Depth 6 | Set-Content $outFile -Encoding UTF8

if ($rejects.Count -or $hintNotes.Count) {
  # NOT "sams-deals-*.rejects.json": compare-deals globs out\sams\sams-deals-*.json to find captures. Today it
  # skips this file only because its BaseName does not end in a date - one refactor of that check away from
  # feeding rejected rows back into the board. Keep the name outside the glob entirely.
  $rj = Join-Path $outDir ("sams-rejects-$Date.json")
  # BAD HINT notes ride in the same file (their rows WERE published - see the note above), so a human has one
  # place to look for "what did this build refuse to believe".
  # .ToArray(), NOT @($rejects): under PS 5.1 `@(List[object]) + @(...)` throws "Argument types do not match".
  # From 9c44c3a37 (2026-09-12) until 2026-09-17 that killed every build with a reject right here, after the deals
  # file was written, so no rejects file, no summary line and no cursor advance. Self-test case 11 is the gate.
  $rjRows = @($rejects.ToArray()) + @($hintNotes)
  $rjRows | ConvertTo-Json -Depth 4 | Set-Content $rj -Encoding UTF8
}
Write-Output ("build-sams-deals: {0} raw -> {1} priced ({2} after de-dupe), {3} rejected -> {4}" -f $raw.Count, $rows.Count, $ded.Count, $rejects.Count, (Split-Path $outFile -Leaf))
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
if (-not $SelfTest -and -not $NoCursor) {
  try {
  & (Join-Path $PSScriptRoot 'commit-capture-cursor.ps1') -Store 'Sam''s Club' -Date $Date | Write-Output
  } catch { Write-Warning ("cursor commit skipped: " + $_.Exception.Message) }
}
