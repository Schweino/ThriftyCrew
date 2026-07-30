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
$root = if ($PSScriptRoot) { $PSScriptRoot } else { 'C:\Codex\income\grocery' }
# WHO AM I. This file is a fork of build-sams-deals.ps1 (capture-lib.ps1:14-19) and inherited that name in
# every operator-facing string, so a Walmart failure sent you to the Sam's builder and the Sam's capture.
# Read the name off the file itself so the next fork renames itself. Captured ONCE at script scope on
# purpose: inside a function $MyInvocation.MyCommand.Name returns the FUNCTION name, not the file.
$Me = $MyInvocation.MyCommand.Name
. (Join-Path $root 'capture-lib.ps1')   # UTF-8 capture read + mojibake repair, shared by every builder

# ---- lift the REAL pricing math out of the engine (it runs a pipeline on load, so we can't dot-source it) ----
$engineSrc = Get-Content (Join-Path $root 'compare-deals.ps1') -Raw
foreach ($fn in @('ConvertTo-DigitNumerals','Get-ItemPrice','Get-PackCount','Get-UnitPrice','Get-SizeAmount','Convert-ToUnit')) {
  $m = [regex]::Match($engineSrc, "(?ms)^function\s+$([regex]::Escape($fn))\s*\(.*?^\}")
  if (-not $m.Success) { throw "${Me}: could not lift $fn from compare-deals.ps1" }
  Invoke-Expression $m.Value
}

# unit token as Sam's prints it -> (engine size token, engine category unit for the invariant check)
# Sam's abbreviates FLUID OUNCE as "foz" ("$0.16/foz"). Missing that silently drops every liquid in the
# catalog - ~190 rows in a full pull - so it is spelled out here rather than left to a generic oz match,
# which would price a fluid ounce as a WEIGHT ounce.
# Units we deliberately do NOT map: "sft" (square foot - Reynolds foil, paper towels). We track those
# commodities per EACH/roll, and there is no honest conversion from square feet to rolls, so those rows are
# rejected by name rather than guessed at.
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
  # NOTE the cent sign arrives mangled (UTF-8 read as Latin-1) as "A-cedilla cent", so match on the DIGITS +
  # slash shape and any non-digit run before the slash rather than on the glyph itself.
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
  $u = Resolve-Unit $upm.Groups[2].Value
  if (-not $u) { return @{ err=('unknown unit "' + $upm.Groups[2].Value + '"') } }

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
  elseif ($cands.Count) { $basis = ('derived lp/up; no name quantity (' + (($cands | Select-Object -First 4) -join ', ') + ') reproduces Walmart''s ' + $up) }
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
      wm_unit_price = $upm.Groups[0].Value.Trim()   # kept for audit; the engine ignores unknown fields
      item_id       = [string]$raw.id
      qty_basis     = ($t.shape + '; qty ' + $basis)
      engine_check  = ('' + [math]::Round($got.unit_price,4) + '/' + $u.unit + ' [' + $got.basis + ']')
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

  if ($fail -eq 0) { Write-Output 'SELF-TEST PASS' ; exit 0 } else { Write-Output "SELF-TEST FAIL: $fail case(s)"; exit 1 }
}

# ---------------------------------------------------------------- build
if (-not $In -or -not (Test-Path $In)) { throw "${Me}: -In not found: $In" }
if (-not $Date) { $Date = (Get-Date).ToString('yyyy-MM-dd') }
$raw = Import-CaptureCsv -Path $In -Delimiter '|'   # UTF-8 + repairs names mangled by an upstream ANSI read
if ($script:CaptureRepairCount -gt 0) { Write-Output ("  repaired $($script:CaptureRepairCount) mangled product name(s) on ingest (UTF-8 read as ANSI upstream)") }
$rows = New-Object System.Collections.Generic.List[object]
$rejects = New-Object System.Collections.Generic.List[object]
foreach ($r in $raw) {
  $b = Build-Row $r
  if ($b.row) { $rows.Add($b.row) } else { $rejects.Add([pscustomobject]@{ name=$r.n; lp=$r.lp; up=$r.up; reason=$b.err }) }
}
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

