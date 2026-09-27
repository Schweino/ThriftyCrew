# WAREHOUSE STORES ARE JUDGED AGAINST THE WAREHOUSE FLOOR of a derived band (derived-band-lib.ps1, stores.json reference_group).
function Test-Band($id, $up, $store = '') { if (-not $BANDS.ContainsKey($id)) { return $true }; $grp = if ($store -and $BAND_GROUPS.ContainsKey([string]$store)) { [string]$BAND_GROUPS[[string]$store] } else { 'retail' }; return (Test-TcInBand $BANDS[$id] ([double]$up) $grp) }
# UNIVERSAL IMPLAUSIBILITY FLOOR (2026-07-27, overhaul-1): only 29 of 503 commodities carry a hand-tuned
# band, so 474 have NO low-end floor - a dropped decimal / unit-confusion parse ships unchecked (the
# $0.0023/oz grits price that sat live for days was exactly this, on a band-less commodity). These per-unit
# floors are ~1/4 of the cheapest REAL staple observed in each unit (oz salt $0.0304, floz vinegar $0.0234,
# lb litter $0.2796, gal milk $2.99, dozen eggs $1.426), so no real cell is at risk but any decimal-drop is
# caught. 'each' is deliberately unfloored (a 500-ct swab box is legitimately ~$0.004 each). Units absent
# from this table are simply not floored (no false blocks on exotic units).
$FLOOR = @{ oz=0.008; floz=0.006; lb=0.07; gallon=0.75; dozen=0.35 }
function Test-Floor($unit, $up) { $u=[string]$unit; if (-not $FLOOR.ContainsKey($u)) { return $true }; return ([double]$up -ge [double]$FLOOR[$u]) }
# PACK-FORM CAP (2026-08-08, Brad's "packet means packet" ruling from the accuracy sample).
# Some commodities are defined by their PACK FORM, not just their contents: "Taco Seasoning (packet)" and
# "Ranch Seasoning Mix (packet)" are the single-use packet a shopper actually buys. The board was filling both
# with the BULK CANISTER - McCormick 8.5 oz on taco seasoning, Great Value 8 oz Canister on ranch - which is a
# different product at a different per-oz rate, so the published number is not what a packet buyer pays.
# A price band cannot express this (both forms sit inside the same per-oz band) and neither can a name regex,
# because the size is not reliably in the name. So the constraint is declared where it belongs: on the
# commodity, in the same shape as pack_is_package. A commodity without the field is completely unaffected.
$MAXPACK = @{}
foreach ($c in $commodities) { if ($c.PSObject.Properties['max_pack_oz']) { $MAXPACK[[string]$c.id] = [double]$c.max_pack_oz } }
# min_pack_oz - THE PACK FORM FLOOR, the mirror of max_pack_oz above (2026-09-06).
# The founding rows are rotisserie-chicken's, and they are the reason this is a SIZE rule and not a list of
# excludes. That commodity means a whole bird, its include is the bare word `rotisserie`, and the aisle is
# full of other things wearing it: Land O'Frost Rotisserie Seasoned Turkey Breast 8 oz, Aldi's Lunch Mate
# Rotisserie Chicken 16 oz (deli slices), Tyson Rotisserie Seasoned Crispy Wings 20 oz, Smithfield 7 oz,
# Soules Kitchen 8 oz. Every one was invisible while the rows were unpriceable; weight_is_one_unit prices
# them, and Land O'Frost's 8 oz lunch meat took Family Fare's cell off a real $7.99 whole chicken.
# WHY NOT EXCLUDES: "Lunch Mate Rotisserie Chicken 16 OZ" says nothing but the brand - there is no word in
# it to exclude on. Blocking the brand hands the cell to the next deli packer, which is the wrong-product
# class this estate has paid for repeatedly. What separates them is not who sells it but HOW BIG IT IS: a
# whole rotisserie chicken is at least 2 lb, and a resealable tub of pulled meat never is.
# THE THREE RULES max_pack_oz ALREADY SETTLED, kept identical here: an UNREADABLE size is not a violation
# (or every store that omits sizes loses the cell - and the real whole-bird rows are exactly the ones that
# say only "each"), an undeclared commodity is untouched, and the bound is inclusive.
$MINPACK = @{}
foreach ($c in $commodities) { if ($c.PSObject.Properties['min_pack_oz']) { $MINPACK[[string]$c.id] = [double]$c.min_pack_oz } }
# min_piece_oz - HOW BIG ONE PIECE HAS TO BE (2026-09-06, Brad's T2 ruling).
# THE RULE BRAD RATIFIED: for a commodity compared per EACH, the word "each" silently asserts the pieces
# are interchangeable, so a mini / single-serve / snack format is a DIFFERENT PRODUCT, not a cheaper one.
# For a commodity compared by weight or volume the format is irrelevant and this never applies (bacon ends
# at $2.398/lb really is cheaper bacon). This is that rule as a MEASUREMENT rather than as taste, which is
# the whole point: it can be checked, it applies to rows nobody has looked at yet, and it says what it means.
#
# THE PIECE, NOT THE PACKAGE - and that distinction is the entire mechanism. min_pack_oz above asks how
# heavy the BOX is; this divides by the count the engine actually priced on, so Totino's "42 oz, 4 Count"
# is measured as four 10.5 oz party pizzas and not as one 42 oz pizza. That is why Get-UnitPrice reports
# `pieces` back: a rule that could only see the box would admit every multipack of minis ever made.
#
# WHY THIS AND NOT 26 LEDGER ENTRIES: the frozen-pizza rows alone are 26, across 5 stores and 8 brands.
# A ledger list of them is brand-shaped, and blocking Totino's simply hands the cell to the next maker of
# snack pizzas - the wrong-product class this estate has paid for repeatedly. What is actually wrong with
# those rows is not who made them, it is that a 10.2 oz party pizza is not the 21 oz pizza the cell claims.
#
# UNREADABLE SIZE IS NOT A VIOLATION, same as both pack rules. That twin is load-bearing here, not a
# formality: most real frozen-pizza rows state only "each" (Fareway's whole column, Walmart's Red Baron,
# Aldi's Mama Cozzi thin crust), so a floor that condemned a sizeless row would empty the commodity it
# was written to protect and leave only the minis it was written to refuse.
$MINPIECE = @{}
foreach ($c in $commodities) { if ($c.PSObject.Properties['min_piece_oz']) { $MINPIECE[[string]$c.id] = [double]$c.min_piece_oz } }
function Get-PackOz([string]$size, [string]$name) {
  # Total package weight in ounces, ONLY when the size string states one plainly. Returns $null otherwise -
  # an unknown size must never be treated as a violation, or every store that omits sizes loses the cell.
  $t = (("" + $size + " " + $name)).ToLower()
  $m = [regex]::Match($t, '(\d+(?:\.\d+)?)\s*(?:fl\s*)?oz\b')
  if ($m.Success) { return [double]$m.Groups[1].Value }
  $m = [regex]::Match($t, '(\d+(?:\.\d+)?)\s*(?:lbs?|pounds?)\b')
  if ($m.Success) { return ([double]$m.Groups[1].Value * 16) }
  return $null
}
function Test-PackSize($id, $size, $name) {
  if (-not $MAXPACK.ContainsKey([string]$id)) { return $true }
  $oz = Get-PackOz $size $name
  if ($null -eq $oz -or $oz -le 0) { return $true }
  return ($oz -le $MAXPACK[[string]$id])
}
function Test-PieceSize($id, $size, $name, $pieces) {
  if (-not $MINPIECE.ContainsKey([string]$id)) { return $true }
  # WHEN THE SIZE ALREADY STATES THE PIECE, DO NOT DIVIDE IT AGAIN. Several feeds write the count-first
  # idiom "<count> pk <per-item size>" - Baker's "16 pk 2.63 oz" is sixteen 2.63 oz corn dogs, NOT a 2.63 oz
  # box. Get-PackOz is deliberately naive (it takes the first oz number, which is right for the cap it was
  # written for), so dividing its answer by 16 here would call a real 2.63 oz corn dog a 0.16 oz crumb and
  # refuse the cell. Same grammar Get-SizeAmount's multipack branch reads; this is the third reader of it and
  # the parity is what keeps them honest.
  $ps = (('' + $size + ' ' + $name)).ToLower()
  $mm = [regex]::Match($ps, '(\d+)\s*[- ]?\s*(?:pk|packs?|ct|count)\b\D{0,4}?(\d+(?:\.\d+)?|\.\d+)\s*(?:fl\s*)?oz\b')
  if ($mm.Success) { return ([double]$mm.Groups[2].Value -ge $MINPIECE[[string]$id]) }
  # A SIZE RANGE MEANS CHOOSE-YOUR-SIZE, AND THE LARGER ONE IS REAL. Get-SizeAmount has read grocery-ad
  # ranges that way since the frozen regression ("in grocery ads this means CHOOSE YOUR SIZE at one price,
  # so the LARGER size is genuinely purchasable"), but Get-PackOz below is deliberately naive and takes the
  # FIRST number - so Hy-Vee's "garlic bread, 8 to 11.25 oz., $2.48" would be measured as an 8 oz piece and
  # refused, losing a real cell to a disagreement between two readers of one string. Read here rather than
  # in Get-PackOz so the max_pack_oz CAP, which has always read the first number, is not silently retuned.
  $rg = [regex]::Match($ps, '(\d+(?:\.\d+)?)\s*(?:to|or|-|thru)\s*(\d+(?:\.\d+)?)\s*(?:fl\s*)?oz\b')
  if ($rg.Success -and ([double]$rg.Groups[2].Value -gt [double]$rg.Groups[1].Value)) {
    return ([double]$rg.Groups[2].Value -ge $MINPIECE[[string]$id])
  }
  $oz = Get-PackOz $size $name
  if ($null -eq $oz -or $oz -le 0) { return $true }
  $n = if ($pieces -and [double]$pieces -ge 1) { [double]$pieces } else { 1 }
  return (($oz / $n) -ge $MINPIECE[[string]$id])
}
# THE ORDER OF THE REFUSALS IS A RULE: DEFINITION BEFORE SANITY (2026-09-18, queue 2026-09-18-f90ba6).
# A row can fail more than one check, and flagged-*.json records only the FIRST one that refuses it, so the
# order decides what the refusal is CALLED. Until today the price band ran first and the piece rule last, so
# a 4-count box of 10.2 oz party pizzas at $1.49 each was filed as '1.5-14' (a price censored by the band)
# instead of 'min_piece_oz>=12' (not the product, Brad's T2 ruling). audit-band-censorship reads only min-max
# band labels, so it counted definitional refusals as price censorship, and its ratchet broke (29 -> 32) on
# 09-17 when a PEER's sale moved frozen-pizza's median, with nothing new refused. Measured over
# flagged-2026-09-17: 21 price-banded rows on the two min_piece commodities, 14 of them fail the piece rule.
# The piece rule is definitional (what the commodity IS), the band and the floor are sanity nets (what a
# price may plausibly be), so a row that fails the definition is labelled by it whatever its price. The pack
# rules keep their old place after the band: nothing measured them, and this change moves only what was.
# Returned as a word so the self-test can reach the ORDER itself; the engine loop keeps every side effect.
#
# IDENTITY OUTRANKS BOTH (2026-09-18, queue 2026-09-18-b1d8e3). The same rule one step further up. A
# known-wrong ruling is an IDENTITY refusal (Brad's T1: this is not the product), and it used to run only
# AFTER this loop and only over PRICED rows, so a ruled row that the band had already refused was filed under
# the band and audit-band-censorship counted it as a censored bargain. Measured on the 15:14 report over
# flagged-2026-09-17: 3 of its 50 findings, 3 of its 31 cells, were rows a ruling already names (the Hy-Vee
# corn tortilla on the flour cell, a Dole fruit-bowl cup on Walmart pineapple, an AriZona Arnold Palmer on
# Walmart half-and-half), and 8 min-max rows in the whole flagged file. So a row that any check here refuses
# AND a ruling names is labelled 'known-wrong'. A ruled row that no check refuses is untouched here and still
# leaves at the known-wrong drop after the loop, exactly as before: this changes what a refusal is CALLED,
# never whether a row is refused, so no cell can move. The ruling lookup is a hashtable probe, so asking it
# only when something refused costs nothing measurable.
function Get-FirstRefusal($id, $unit, $up, $size, $name, $pieces, $store = '', $KwBlocks = $null) {
  $r = ''
  if (-not (Test-PieceSize $id $size $name $pieces)) { $r = 'piece' }
  # COUNT-CONFLICT is a BASIS refusal (queue 2026-09-22-8d2ad5): the size field's count disagrees with the name's own
  # count, or is a sub-unit (sheets, slices). It runs ahead of the band, because a wrong basis is what the band would
  # otherwise be CALLED on, and inside the band nothing read it at all (Get-EachCountConflict, pricing-math-lib).
  elseif ($unit -eq 'each' -and (Get-EachCountConflict ([string]$size) ([string]$name) $pieces)) { $r = 'count-conflict' }
  elseif (-not (Test-Band $id $up $store)) { $r = 'band' }
  elseif (-not (Test-Floor $unit $up)) { $r = 'floor' }
  elseif (-not (Test-PackSize $id $size $name)) { $r = 'pack-cap' }
  elseif (-not (Test-PackSizeFloor $id $size $name)) { $r = 'pack-floor' }
  if ($r -and $KwBlocks -and $KwBlocks.Count -and (Test-KnownWrong -Blocks $KwBlocks -CommodityId ([string]$id) -Store ([string]$store) -ProductName ([string]$name))) { return 'known-wrong' }
  return $r
}
function Test-PackSizeFloor($id, $size, $name) {
  if (-not $MINPACK.ContainsKey([string]$id)) { return $true }
  $oz = Get-PackOz $size $name
  if ($null -eq $oz -or $oz -le 0) { return $true }
  return ($oz -ge $MINPACK[[string]$id])
}
