<#
  pu-lib.ps1 - THE single per-unit implementation. Dot-source it; never re-type it.

  WHY THIS FILE EXISTS: there were two of these. build-deals-page / generate-board-overrides /
  audit-board-consistency computed a link's per-unit with LinkPU(); guards.ps1 / audit-everyday-mismatch /
  prune-bad-links computed it with a weaker Qty(). They disagreed, and every disagreement was invisible:

    * Qty() returned 0 for sizes LinkPU handles fine - "per lb", "dozen", a bare "lb", "24 fl oz" against an
      oz commodity, and a unit-price string like "$0.07/oz" parked in the size field. A 0 meant "cannot
      judge", and the audits SKIP what they cannot judge. So 185 of 2,156 linked everyday cells (8.6%) were
      never checked by the factor guard, while the guard reported "0 mismatches" as though it had checked
      them all. A blind spot that reports itself as a clean bill of health is worse than no guard.
    * Qty()'s number pattern was ([\d.]+), which matches a LONE ".". [double]"." throws, and guards.ps1 runs
      under $ErrorActionPreference='Stop', so one such size would have aborted the whole gate.
    * Earlier the same split made prune-bad-links drop 268 links where the audit only judged 254 bad.

  A gate judged by different arithmetic than the page it is gating is not a gate. One function, one answer.
  Returns $null when the size genuinely carries no unit basis - callers must treat $null as "unknown",
  never as zero.
#>

function Get-LinkPerUnit {
  param([string]$size, [string]$unit, [double]$price, [string]$name = '')

  $s = ([string]$size).ToLower().Trim()

  # 1. an explicit unit price already in the size field ("$0.07/oz", "0.12 / lb") wins outright
  $up = [regex]::Match($s, '\$?\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*(fl\s*oz|floz|oz|lb|ea|each|ct|count)')
  if ($up.Success) {
    $v = [double]$up.Groups[1].Value
    $un = ($up.Groups[2].Value -replace '\s','') -replace 'fl',''
    switch ($unit) {
      'lb'    { if ($un -eq 'lb') { return $v }; if ($un -eq 'oz') { return $v * 16 } }
      'oz'    { if ($un -eq 'oz') { return $v }; if ($un -eq 'lb') { return $v / 16 } }
      'floz'  { if ($un -match 'oz') { return $v }; if ($un -eq 'lb') { return $v / 16 } }
      'each'  { if ($un -match '^(ea|each|ct|count)$') { return $v }; return $price }
      'dozen' { if ($un -match '^(ea|each|ct|count)$') { return $v * 12 }; return $price }
    }
  }

  if ($price -le 0) { return $null }

  $n = $null; $un = ''; $mpDone = $false

  # 2. multipack stated PACK-FIRST as "N pk/pack M <weight>" ("6 pk 4 oz", "2 pk 48 fl oz", "2 pk 1 gal"):
  #    the TOTAL is N*M in the weight/volume unit. This MUST be tried before the generic quantity match
  #    below, which lists 'pk' as a unit and so greedily reads "N pk" as the quantity, loses the per-item
  #    weight, and returns null - the exact reason 17 real multipack cells (applesauce 6pk, lemon-juice
  #    2pk, ...) sat unverified. Pack-first is fully resolved here; the weight-first multiply in step 4 is
  #    then skipped so we never multiply the pack count in twice.
  #    ONLY for weight/volume commodities. For an 'each'/'dozen' commodity, "4 pk 4 oz" means 4 ITEMS, not
  #    16 oz - collapsing it to a per-ounce number the 'each' switch then drops was a regression the
  #    differential test caught (fruit-cups, pudding-cups, microwave-popcorn). Those fall through to the
  #    generic match, which reads "N pk" as the count ($un='pk' -> price/N) exactly as before.
  #    'x' is the SAME form with a different spelling ("12 x 12 fl oz"), and it was not handled: the generic
  #    match below cannot read "12" followed by "x", so it slid to the SECOND number and returned 12 fl oz for
  #    a 144 fl oz case - a live 12x error on soda|Hy-Vee ($0.3933/floz published against a true $0.0328).
  #    Same bug family as the "6-pack 12 fl oz" hyphen case; only the separator differs.
  #    'ct' AND 'count' ARE THE SAME FORM AND WERE MISSING (2026-09-22, queue 2026-09-22-a09096). The ENGINE's
  #    own size reader, Get-SizeAmount in pricing-math-lib.ps1, has read '24 ct 16.9 oz' as count-times-size
  #    since it was written; this list said pk|pack|x only. Two implementations of one rule, and nothing proved
  #    they agreed - the estate's number one root cause ([[same-fact-published-twice]], [[two-copies-of-a-rule]]).
  #    Measured over comparison-2026-09-22 before the change: 26 board cells carry a size of this shape, pu-lib
  #    returned $null for all 26, and the engine priced every one. A $null here is not a wrong number, it is a
  #    BLIND SPOT - the same blind spot this file's header was written about ("185 of 2,156 linked everyday cells
  #    were never checked by the factor guard, while the guard reported 0 mismatches"). It surfaced as a wrong
  #    VERDICT rather than a wrong price: verify-price-flags asks pu-lib for the store's own readings, got none
  #    from the size field, fell back to a name reading that dropped the pack count, and condemned Sam's hummus
  #    ($5.58 / 16 x 2.5 oz = $0.1395/oz, exactly what we publish) as wrong-price. The cell was quarantined.
  #    ops\audit-size-parser-parity.ps1 is what now keeps the two readers agreeing.
  if ($unit -in @('oz','floz','lb','gallon')) {
    $mp = [regex]::Match($s, '([0-9]+)\s*-?\s*(?:ct|count|pk|packs?|x|\u00d7)\s*-?\s*([0-9]+(?:\.[0-9]+)?|\.[0-9]+)\s*(fl\s*oz|floz|oz|lbs?|pound|gal|gallon|qt|quart|ml|ltr|liters?|litres?|l)\b')
    if ($mp.Success) {
      $n = [double]$mp.Groups[1].Value * [double]$mp.Groups[2].Value
      $un = ($mp.Groups[3].Value -replace '\s','') -replace 'fl','' -replace '^gallon$','gal' -replace '^quart$','qt' -replace '^pound$','lb' -replace '^(ltr|liters?|litres?)$','l'
      $mpDone = $true
    }
  } elseif ($unit -in @('each','dozen')) {
    # PACK-FIRST on a COUNT commodity: "N pk X oz" is N items (each) / N-of-12 (dozen). For 'each' the
    # generic match below already lands on the same answer (un='pk' -> price/N); 'dozen' had NO pk handling
    # at all, so eggs shaped "12 pk 2 oz" (the Kroger-API canonical multipack form, 2026-07-24) returned
    # null and the cell went unpriced. Resolved here, in the one block that owns pack-first semantics.
    # The trailing weight is REQUIRED by the regex, so a bare "2 pk" (two CARTONS, count-per-carton unknown)
    # can never match - that shape stays with the generic rules exactly as before.
    # ct|count added 2026-09-22 with the branch above, so ONE token list answers both. On an 'each' commodity
    # this lands on the answer the generic match already gave ($un='ct' -> price/N); on 'dozen' it closes the
    # same gap 'pk' was added to close, and agrees with Convert-ToUnit's dozen branch in pricing-math-lib.
    $mp = [regex]::Match($s, '([0-9]+)\s*-?\s*(?:ct|count|pk|packs?|x|\u00d7)\s*-?\s*([0-9]+(?:\.[0-9]+)?|\.[0-9]+)\s*(fl\s*oz|floz|oz|lbs?|pound|gal|gallon|qt|quart|ml|ltr|liters?|litres?|l)\b')
    if ($mp.Success) {
      $cnt = [double]$mp.Groups[1].Value
      if ($cnt -gt 0) {
        if ($unit -eq 'each') { return $price / $cnt }
        return $price / ($cnt / 12.0)
      }
    }
  }

  if (-not $mpDone) {
    # 2b. a quantity + unit anywhere in the size. NOTE the number pattern: (\d+(?:\.\d+)?), NOT ([\d.]+) -
    #     the latter matches a bare "." and [double]"." throws.
    # 'ltr'/'liter'/'litre' must be listed AFTER 'ml' (so "12 ml" still reads as ml) and BEFORE the bare 'l'.
    # The converter below has always known litres - it was the SIZE pattern that did not: the bare 'l\b' cannot
    # match "2 ltr" because a 't' follows the 'l', so soda came back unpriceable rather than wrong. A parse gap
    # that returns $null is the safe failure mode, but it is still a gap; 2 real cells sat unverifiable on it.
    # FRACTIONAL SIZE ("1/2 gal", "3/4 lb") MUST BE TESTED BEFORE THE PLAIN-NUMBER MATCH. Without this the
    # pattern below finds the "2" in "1/2 gal" and reads it as TWO gallons - 4x the real 64 fl oz - so a link
    # priced a $4.99 half gallon at $0.0195/fl oz against the board's correct $0.078 and guards.ps1 hard-failed
    # three Baker's cells at exactly 0.25x (buttermilk, half-and-half, almondmilk) on 2026-07-29.
    # compare-deals fixed this long ago; pu-lib never got the fix - two copies of the same math, one of them
    # wrong, which is precisely the class board-data-integrity warns about. Keep the rules identical.
    # A FRACTION HAS THE SMALLER NUMBER ON TOP. "6/4 oz" is not six-quarters of an ounce, it is the count/size
    # pack idiom (6 cups of 4 oz = 24 oz), so numerator >= denominator means MULTIPLY, not divide.
    $n = $null; $un = $null
    $mf = [regex]::Match($s, '(\d+)\s*/\s*(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|lbs?|pound|gal|gallon|qt|quart|pt|pint|ml|ltr|liters?|litres?|l)\b')
    if ($mf.Success) {
      $num = [double]$mf.Groups[1].Value; $den = [double]$mf.Groups[2].Value
      if ($den -gt 0) {
        $n = if ($num -lt $den) { $num / $den } else { $num * $den }
        $un = (($mf.Groups[3].Value -replace '\s','') -replace 'fl','') -replace '^(ltr|liters?|litres?)$','l'
      }
    }
    # A SIZE RANGE READS ITS SMALLER END (2026-09-25, queue 2026-09-22-a09096). "13-16 oz", "10 to 12 oz", "9 or 12 oz"
    # name two sizes at one price. Get-SizeAmount, which prices the board, reads the SMALLER one since plan-2026-09-22-5
    # (the laundry crown: the least favourable reading, so the per-unit is the most a shopper pays). This reader went on
    # landing on the unit-adjacent LARGER number, so over comparison-2026-09-23 audit-size-parser-parity -Board read 8
    # disagreements, every one this shape ('13-16 oz' at lb $3.88: 3.8800 here, 4.7754 on the board). ASCENDING pairs
    # only, as in the engine: "24-12 oz" is the count-x-size idiom and falls through. Resolved like the engine's early
    # return, so neither pack multiplier below touches it.
    $rngDone = $false
    if ($null -eq $n) {
      $rg = [regex]::Match($s, '(\d+(?:\.\d+)?)\s*(?:to|or|-|&ndash;|thru)\s*(\d+(?:\.\d+)?)\s*(fl\s*oz|floz|oz|lbs?|pound|gallon|gal|quart|qt|ml|ltr|liters?|litres?|l|grams?|g|count|ct)\b')
      if ($rg.Success -and ([double]$rg.Groups[1].Value -lt [double]$rg.Groups[2].Value)) {
        $n = [double]$rg.Groups[1].Value
        $un = (($rg.Groups[3].Value -replace '\s','') -replace 'fl','') -replace '^gallon$','gal' -replace '^quart$','qt' -replace '^(ltr|liters?|litres?)$','l' -replace '^grams?$','g'
        $rngDone = $true
      }
    }
    $q = if ($null -eq $n) { [regex]::Match($s, '(\d+(?:\.\d+)?|\.\d+)\s*(fl\s*oz|floz|oz|lbs?|pound|ct|count|ea|pk|gal|gallon|qt|quart|dozen|doz|ml|ltr|liters?|litres?|l|sq\.?\s*ft|kg|grams?|g)\b') } else { $null }
    if ($null -ne $n) {
      # already resolved by the fractional or the range branch
    } elseif ($q.Success) {
      $n = [double]$q.Groups[1].Value
      $un = (($q.Groups[2].Value -replace '\s','') -replace 'fl','') -replace '^(ltr|liters?|litres?)$','l' -replace '^sq\.?ft$','sqft' -replace '^grams?$','g'
      # PARITY WITH THE ENGINE (2026-09-22, queue 2026-09-22-43e8c0): kg and g read as grams, as Get-SizeAmount does.
      if ($un -eq 'kg') { $n = $n * 1000; $un = 'g' }
    } else {
      # 3. a BARE unit with no number ("lb", "per lb", "each", "dozen", "gal") means one of it.
      #
      # `bunch` ADDED 2026-08-31, and it is a real dropped cell rather than tidiness. Hy-Vee sells
      # green onions by the bunch and priced them "$1.49 / bunch"; green-onions is an `each` commodity,
      # this token was unknown, so the row had NO per-unit and the cell left the board entirely -
      # reported as a cell-drop with nothing to explain it. The row was there and matched its
      # commodity fine; only the size word was unreadable.
      #
      # SAFE ON A WEIGHT COMMODITY, which is why it normalises to `ea` rather than to 1 of whatever
      # the row is: a bunch tells you the purchase COUNT and says nothing about weight, so on an oz or
      # lb commodity `ea` matches no branch below and the row stays uncomputable - which is the honest
      # answer, not a guessed ounce count. Only 6 rows in the current captures use it; it is rare, not
      # absent, and a rare unreadable size is exactly the kind that goes unnoticed.
      # A BARE 'oz' IS ONE OUNCE (2026-09-22, queue 2026-09-22-43e8c0): Get-SizeAmount, which prices the board, has always
      # read it that way (a per-ounce shelf price), and this reader returned $null, so two cells were priced and unauditable.
      $bu = [regex]::Match($s, '\b(lbs?|pound|gal|gallon|dozen|doz|each|ea|bunch|oz)\b')
      if ($bu.Success) {
        $n = 1
        $un = $bu.Groups[1].Value -replace '^gallon$','gal' -replace '^doz$','dozen' -replace '^pound$','lb' -replace '^bunch$','ea'
      }
    }
  }
  if ($null -eq $n) { return $null }

  # 4. multipack in the SIZE stated WEIGHT-FIRST ("16 oz 6 pk") multiplies a weight. Skipped when the
  #    pack-first branch already ran, so "6 pk 16 oz" is not multiplied by the pack count twice.
  #    LITRE / ML / QUART JOINED 2026-08-22: "2 l 6 pk" multiplied only oz/lb/gal, so a six-pack of 2-litre
  #    bottles priced as ONE bottle (6x over). compare-deals' weight-first branch carries the same addition.
  if ((-not $mpDone) -and (-not $rngDone)) {
    $pk = [regex]::Match($s, '([0-9]+)\s*-?\s*(pk|pack)\b')
    if ($pk.Success -and $n -and ($un -match '^(oz|lbs?|gal|l|ml|qt)$')) { $n = $n * [double]$pk.Groups[1].Value }
  }

  # 5. multipack in the NAME. A link whose size is just "each" but whose NAME says "24 Pack" is 24 items, not
  #    1 - without this the whole pack price publishes as the per-item price (Fareway bottled water went out
  #    at $3.87 EACH). Only for 'each' commodities, and only when the size itself carries no count.
  if ($unit -eq 'each' -and $name -and (-not $rngDone) -and (($null -eq $n) -or ($n -eq 1))) {
    $pn = [regex]::Match(([string]$name).ToLower(), '([0-9]+)\s*-?\s*(?:pk\b|pack\b|ct\b|count\b)')
    if ($pn.Success) {
      $cnt = [double]$pn.Groups[1].Value
      if ($cnt -gt 1) { return $price / $cnt }
    }
  }

  switch ($unit) {
    'lb'     { if ($un -match '^(lbs?|pound)$' -and $n) { return $price / $n }
               if ($un -eq 'oz' -and $n) { return $price / ($n / 16) }
               return $null }
    # an oz commodity linked to a product sized in FL OZ: our fl-oz sizes are stripped to 'oz' above, so this
    # resolves rather than silently scoring 0 the way the old Qty() did.
    'oz'     { if ($un -eq 'oz' -and $n) { return $price / $n }
               if ($un -match '^(lbs?|pound)$' -and $n) { return $price / (16 * $n) }
               if ($un -eq 'g' -and $n) { return $price / ($n * 0.035274) }
               if ($un -eq 'gal' -and $n) { return $price / (128 * $n) }
               if ($un -eq 'qt' -and $n) { return $price / (32 * $n) }
               return $null }
    'floz'   { if ($un -match 'oz' -and $n) { return $price / $n }
               if ($un -eq 'gal' -and $n) { return $price / (128 * $n) }
               if ($un -eq 'qt' -and $n) { return $price / (32 * $n) }
               if ($un -eq 'l' -and $n) { return $price / ($n * 33.814) }
               if ($un -eq 'ml' -and $n) { return $price / ($n * 0.033814) }
               return $null }
    'each'   { if ($un -match '^(ct|count|ea|pk)$' -and $n) { return $price / $n }
               if ($un -match '^(dozen|doz)$') { if ($n) { return $price / (12 * $n) }; return $price / 12 }
               if ($n -eq 1) { return $price }
               return $null }
    # N DOZEN IS N DOZEN (2026-09-22, queue 2026-09-22-43e8c0): Sam's '15 dozen' eggs at $29.56 read as ONE dozen here
    # (29.56/dozen) while the engine priced the board at 1.9707. The count was read and then ignored.
    'dozen'  { if ($un -match '^(dozen|doz)$') { if ($n) { return $price / $n }; return $price }
               if ($un -match '^(ct|count|ea)$' -and $n) { return $price / ($n / 12) }
               if ($n -eq 1) { return $price }
               return $null }
    # sq_ft (2026-09-22, queue 2026-09-22-43e8c0): foil and wrap are priced per square foot by the engine; this reader had no arm.
    'sq_ft'  { if ($un -eq 'sqft' -and $n) { return $price / $n }
               return $null }
    'gallon' { if ($un -eq 'gal' -and $n) { return $price / $n }
               if ($un -match '^(floz|oz)$' -and $n) { return $price / ($n / 128) }
               if ($n -eq 1) { return $price }
               return $null }
    default  { return $null }
  }
  return $null
}

# WHICH KIND OF QUANTITY A SIZE STRING NAMES, READ THE WAY Get-LinkPerUnit DIVIDES IT (2026-09-25, queue
# 2026-09-23-92e552, plan-2026-09-25-4). A store writes a bare "oz" on a liquid all the time: on
# comparison-2026-09-23, 71 cells on the floz commodities carried one ('Venom Energy Drink, Black Mamba 16 Oz'
# as "16 oz", 'Aldi Coconut Milk 13.66 FL OZ' as "13.66 oz", 'Goldhen Liquid Egg Whites 32 FL OZ' as "32 oz"),
# and not one of the 71 named a second weight unit. The 'floz' arm above divides a bare oz as fluid ounces.
# audit-unit-basis-outlier read the same string as WEIGHT, so whether a bare-oz cell was accused depended only
# on how its shelf-mates happened to be labelled: Venom (0.0625/floz, 2 for $2) and Queen Helene lotion
# "32 oz" (0.1244) were condemned and each cell held an older DEARER price, while 12 other bare-oz crowns on
# floz rows passed because their peers were bare oz too. One reading now: on a volume commodity (floz or
# gallon) a bare oz is volume, as it is priced. A size that ALSO names a weight unit ("32 oz (907 g)",
# "2 lb 4 oz") is a weight label and stays weight, so the guard still accuses it when it takes a crown.
# The kind regexes live here and nowhere else; the audit's Get-MeasureKind calls this.
$script:PuVolumeKindRx = '\bfl\.?\s*oz|\bfluid\b|\bml\b|\blitre|\bliter\b|\bgal(lon)?\b|\bqt\b|\bquart\b|\bpt\b|\bpint\b'
$script:PuWeightKindRx = '\boz\b|\bounce|\blb\b|\bpound|\bg\b|\bgram|\bkg\b'
$script:PuCountKindRx  = '\bct\b|\bcount\b|\beach\b|\bea\b|\bpk\b|\bpack\b|\broll'
# a weight unit OTHER than oz: grams (also glued to the number, "907g"), kilograms, pounds
$script:PuNonOzWeightRx = '(?<![a-z])(g|grams?|kg|lbs?|pounds?)\b'
function Get-SizeMeasureKind {
  param([string]$Size, [string]$Unit = '')
  if (-not $Size) { return 'unknown' }
  if ($Size -imatch $script:PuVolumeKindRx) { return 'volume' }
  if ($Size -imatch $script:PuWeightKindRx) {
    $volumeUnit = ($Unit -imatch '^\s*(floz|fl\.?\s*oz|gallon)\s*$')
    if ($volumeUnit -and ($Size -imatch '\boz\b|\bounce') -and ($Size -inotmatch $script:PuNonOzWeightRx)) { return 'volume' }
    return 'weight'
  }
  if ($Size -imatch $script:PuCountKindRx) { return 'count' }
  return 'unknown'
}

# ONE READER FOR "CAN THIS CELL BE COMPARED AGAINST ITS STORED LINK", because the estate asked that
# question in two files on the same day and got it wrong in both. Get-LinkPerUnit already taught this
# lesson here - it lived in two files and they disagreed on 13 of 3,342 links, the private copy wrong
# on every one - so the rule lives once and both callers read it.
function Test-CellComparableToEverydayLink {
  <#
    Can this board cell's price be compared against the everyday price stored on its product link?

    Only when the cell is `everyday`. product-urls.json stores a shelf snapshot, so on a promotional
    cell the gap between the two IS the discount, and reading it as evidence turns every deep sale
    into something indistinguishable from a wrong product. Measured on the 2026-08-31 worklist: 39 of
    94 mismatch chips sat on sale cells, and two of the four WORST-looking chips in the list were
    exactly this - pears at 291% and sports-drinks at 119%, both hand-triaged, both correct links at
    their shelf price.

    source_ad WAS TRIED AS THE DISCRIMINATOR ON 2026-09-01 AND MEASURED WRONG. The argument was that
    only a printed WEEKLY AD is incomparable, because `type` says `sale` on cells whose price was read
    off a live shelf too (Walmart's 10 lb ground beef is type=sale with source_ad "everyday shelf
    price"). Widening audit-everyday-mismatch that way raised its examined count from 2598 to 2975 and
    surfaced 26 new findings - and 19 of the 21 landing on newly-included cells had the board CHEAPER
    than the link, the shape of a discount. Across the whole board, sale cells that differ from their
    link at the 15% worklist tolerance are board-cheaper 75% of the time.

    THE DISTINCTION WORTH KEEPING: source_ad is PROVENANCE - where the number was read. `type` is the
    board's own statement about WHAT the number is. A price can be read off a live shelf and still be
    a promotion, which is what those 19 were. Provenance is not semantics, and this needs semantics.

    A COST THIS ACCEPTS ON PURPOSE: a wrong link on a sale cell cannot be caught by price here, so it
    is not caught here at all. It stays reachable through `missing` and `stale`, which compare a board
    against its own snapshot rather than against a link, and are valid on every cell.
  #>
  param([string]$CellType)
  return ([string]$CellType) -eq 'everyday'
}
